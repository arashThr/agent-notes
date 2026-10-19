;;; agent-notes.el --- Review git changes with an AI agent using inline notes -*- lexical-binding: t; -*-

;; Version: 0.4.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7"))
;; Keywords: tools, vc, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Agent Notes lets you go through the changes in a git repository
;; together with an AI agent (GitHub Copilot CLI, Claude Code or the
;; Codex CLI; see `agent-notes-agent'), using notes attached to lines
;; of a read-only diff.
;;
;; - M-x agent-notes-review   Snapshot the changes (the working tree,
;;                            the staged changes, the current branch vs.
;;                            a base branch, a commit or a range) and
;;                            give the agent a task: a bug review, an
;;                            overview of the important changes, a
;;                            diagram, or your own instructions.  Its
;;                            notes appear inline.
;; - M-x agent-notes-open     Reopen a previous review.
;; - M-x agent-notes-menu     All of the above in a menu.  In Magit it is
;;                            on `@', and in `magit-dispatch'.
;;
;; The review buffer is built on `magit-section': files, hunks and
;; notes fold with TAB, and the diff can be shown unified or side by
;; side (`v'), with syntax highlighting.  You can navigate between open
;; notes, add your own notes, reply to the agent, edit or delete your
;; unsent comments and resolve threads.  Your comments are queued;
;; press `s' to send all of them to the agent in one go.  The agent
;; answers in the same session, so it remembers the review.
;; When you ask it to change code, it edits the files and the diff is
;; refreshed, with the notes moving along with the code.  The same
;; happens when you edit and save a file yourself.  Press `?' for all
;; commands and `$' for a log of what happened.
;;
;; Reviews live in .git/agent-notes/ and are never committed.
;;
;; The code is split into:
;; - agent-notes-core.el    options, faces, buffer state, storage
;; - agent-notes-diff.el    git, diff parsing, anchoring, syntax highlighting
;; - agent-notes-render.el  drawing the review buffer
;; - agent-notes-log.el     the log of a review
;; - agent-notes-agent.el   prompts, running the agent, applying answers
;; - agent-notes-magit.el   Magit integration, loaded with Magit
;; - agent-notes.el         the mode, commands, menus and entry points

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'subr-x)
(require 'magit-section)
(require 'transient)
(require 'agent-notes-core)
(require 'agent-notes-diff)
(require 'agent-notes-render)
(require 'agent-notes-log)
(require 'agent-notes-agent)

;; Introduced in magit-section 4.3.6.
(defvar magit-section-highlight-current)

(defvar agent-notes--task-history nil "History of tasks given to the agent.")

(defvar-local agent-notes--refresh-timer nil
  "Timer that refreshes the diff after you save a file.")

;;;; Buffers

(defun agent-notes--buffer-for (file)
  "Return the live review buffer showing FILE, or nil."
  (cl-find-if (lambda (buf) (equal (buffer-local-value 'agent-notes--file buf) file))
              (buffer-list)))

(defun agent-notes--reload ()
  "Load the review of the current buffer from disk and redraw it."
  (setq agent-notes--review
        (agent-notes--migrate (agent-notes--json-parse (agent-notes--read-file agent-notes--file))))
  (agent-notes--set-diff (agent-notes--stored-diff))
  ;; Notes from older versions don't record their code yet.
  (dolist (note (agent-notes--notes))
    (unless (plist-get note :text)
      (let ((rec (agent-notes--exact-record note)))
        (when rec (plist-put note :text (agent-notes--content rec))))))
  (setq default-directory (plist-get agent-notes--review :root))
  (agent-notes--render))

(defun agent-notes--revert (&rest _)
  "Refresh the diff of the review."
  (agent-notes-refresh))

(defun agent-notes--get-buffer (file)
  "Return a review buffer for FILE, creating it if needed."
  (or (agent-notes--buffer-for file)
      (let* ((review (agent-notes--json-parse (agent-notes--read-file file)))
             (buf (generate-new-buffer
                   (format "*agent-notes: %s %s*" (agent-notes--repo-name review)
                           (plist-get review :id)))))
        (with-current-buffer buf
          (agent-notes-mode)
          (setq agent-notes--file file)
          (agent-notes--reload))
        buf)))

(defun agent-notes--cleanup ()
  "Cancel the timers of the review buffer being killed."
  (agent-notes--stop-ticker)
  (when (timerp agent-notes--refresh-timer)
    (cancel-timer agent-notes--refresh-timer)))

;;;; Refreshing the diff

(defun agent-notes--refresh-diff ()
  "Snapshot the changes again if they differ from the stored diff.
Return (MOVED . OUTDATED) if the diff changed, or nil."
  (let ((snapshot (agent-notes--snapshot-diff agent-notes--review)))
    (unless (equal (car snapshot) (agent-notes--stored-diff))
      (agent-notes--resnapshot snapshot))))

(defun agent-notes-refresh ()
  "Snapshot the changes again and move the notes along with their code.
The scope and base of the review stay the same."
  (interactive)
  (agent-notes--ensure-idle)
  (let ((result (agent-notes--refresh-diff)))
    (if (not result)
        (progn (agent-notes--reload)
               (message "No changes since the last snapshot"))
      (let ((msg (format "Diff refreshed: %s" (agent-notes--describe-moves result))))
        (agent-notes--log "You" (concat msg "."))
        (agent-notes--render)
        (message "%s" msg)))))

(defun agent-notes--refresh-after-save (buffer path)
  "Refresh the review in BUFFER after you saved PATH."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-notes--refresh-timer nil)
      (unless (process-live-p agent-notes--process)
        (condition-case err
            (let ((result (agent-notes--refresh-diff)))
              (when result
                (agent-notes--log "You" (format "You saved %s; diff refreshed, %s."
                                                path (agent-notes--describe-moves result)))
                (agent-notes--render)))
          (error (agent-notes--log "Failed" (format "Could not refresh the diff after saving %s: %s"
                                                    path (error-message-string err)))))))))

(defun agent-notes--after-save ()
  "Schedule a refresh of the reviews of the repository of the saved file."
  (when (and agent-notes-refresh-on-save buffer-file-name)
    (let ((file (file-truename buffer-file-name)))
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (when (and (derived-mode-p 'agent-notes-mode)
                     agent-notes--review
                     (not (process-live-p agent-notes--process)))
            (let ((root (file-truename (plist-get agent-notes--review :root))))
              (when (and (string-prefix-p root file)
                         (not (string-prefix-p (expand-file-name ".git/" root) file)))
                (when (timerp agent-notes--refresh-timer)
                  (cancel-timer agent-notes--refresh-timer))
                (setq agent-notes--refresh-timer
                      (run-with-idle-timer 0.5 nil #'agent-notes--refresh-after-save
                                           buf (file-relative-name file root)))))))))))

;;;; Compose buffer

(defvar-local agent-notes--compose-callback nil)
(defvar-local agent-notes--compose-origin nil)

(defvar-keymap agent-notes-compose-mode-map
  "C-c C-c" #'agent-notes-compose-finish
  "C-c C-k" #'agent-notes-compose-cancel)

(define-derived-mode agent-notes-compose-mode text-mode "Agent-Notes-Compose"
  "Major mode for writing a note or reply.
\\{agent-notes-compose-mode-map}")

(defun agent-notes--compose (title initial callback)
  "Pop up a buffer titled TITLE to write text, prefilled with INITIAL.
When done, call CALLBACK with the text in the review buffer."
  (let ((origin (current-buffer))
        (buf (generate-new-buffer "*agent-notes compose*")))
    (with-current-buffer buf
      (agent-notes-compose-mode)
      (setq agent-notes--compose-callback callback
            agent-notes--compose-origin origin
            header-line-format
            (concat " " title "  ·  "
                    (substitute-command-keys
                     "\\[agent-notes-compose-finish] save  \\[agent-notes-compose-cancel] cancel"
                     t)))
      (when initial
        (insert initial)
        (goto-char (point-min))))
    (pop-to-buffer buf '((display-buffer-below-selected) (window-height . 12)))))

(defun agent-notes-compose-finish ()
  "Save the text being composed."
  (interactive)
  (let ((text (string-trim (buffer-substring-no-properties (point-min) (point-max))))
        (callback agent-notes--compose-callback)
        (origin agent-notes--compose-origin))
    (when (string-empty-p text)
      (user-error "Nothing written; use C-c C-k to cancel"))
    (unless (buffer-live-p origin)
      (user-error "The review buffer no longer exists"))
    (quit-window t)
    (let ((win (get-buffer-window origin)))
      (if win (select-window win) (pop-to-buffer origin)))
    (with-current-buffer origin
      (funcall callback text))))

(defun agent-notes-compose-cancel ()
  "Discard the text being composed."
  (interactive)
  (quit-window t))

;;;; Navigation

(defun agent-notes--goto-section (section)
  "Move point to SECTION, unfolding the sections that contain it."
  (let ((parent (oref section parent)))
    (when parent (magit-section-reveal parent)))
  (goto-char (oref section start))
  (let ((win (get-buffer-window (current-buffer))))
    (when win (set-window-point win (point)))))

(defun agent-notes--goto-note (id &optional comment-id)
  "Move point to the note ID, or to its comment COMMENT-ID."
  (let ((section (agent-notes--note-section id)))
    (when section
      (agent-notes--goto-section section)
      (when comment-id
        (magit-section-show section)
        (let ((pos (agent-notes--find-prop 'agent-notes-comment comment-id)))
          (when pos
            (goto-char pos)
            (let ((win (get-buffer-window (current-buffer))))
              (when win (set-window-point win pos)))))))))

(defun agent-notes--jump (type forward what &optional pred hint)
  "Move to the next section of TYPE; backward unless FORWARD.
PRED filters the sections.  WHAT names them in messages.  HINT is
added to the error when there are none."
  (let* ((targets (agent-notes--sections type pred))
         (bol (line-beginning-position))
         (eol (line-end-position))
         (target (if forward
                     (cl-find-if (lambda (s) (> (oref s start) eol)) targets)
                   (cl-find-if (lambda (s) (< (oref s start) bol)) (reverse targets)))))
    (unless targets (user-error "No %s%s" what (or hint "")))
    (unless target
      (setq target (if forward (car targets) (car (last targets))))
      (message "Wrapped around"))
    (agent-notes--goto-section target)
    (when (eq type 'agent-notes-note)
      (message "Note #%d (%d of %d %s)" (oref target value)
               (1+ (cl-position target targets)) (length targets) what))))

(defun agent-notes--note-filter (all agent-only)
  "Return a predicate on note sections.
Unless ALL, it rejects resolved notes; with AGENT-ONLY, notes you wrote."
  (lambda (section)
    (let ((note (agent-notes--note (oref section value))))
      (and (or all (not (agent-notes--resolved-p note)))
           (or (not agent-only) (equal (plist-get note :author) "agent"))))))

(defun agent-notes--jump-note (forward all agent-only)
  "Move to the next note, or the previous one unless FORWARD.
See `agent-notes--note-filter' for ALL and AGENT-ONLY."
  (agent-notes--jump 'agent-notes-note forward
                     (concat (if all "" "open ") (if agent-only "agent notes" "notes"))
                     (agent-notes--note-filter all agent-only)
                     (unless all "; with C-u, resolved notes are included")))

(defun agent-notes-next-note (&optional all)
  "Move to the next open note.
With prefix argument ALL, include resolved ones."
  (interactive "P")
  (agent-notes--jump-note t all nil))

(defun agent-notes-previous-note (&optional all)
  "Move to the previous open note.
With prefix argument ALL, include resolved ones."
  (interactive "P")
  (agent-notes--jump-note nil all nil))

(defun agent-notes-next-agent-note (&optional all)
  "Move to the next open note by the agent.
With prefix argument ALL, include resolved ones."
  (interactive "P")
  (agent-notes--jump-note t all t))

(defun agent-notes-previous-agent-note (&optional all)
  "Move to the previous open note by the agent.
With prefix argument ALL, include resolved ones."
  (interactive "P")
  (agent-notes--jump-note nil all t))

(defun agent-notes-next-hunk ()
  "Move to the next hunk, in this file or the next one."
  (interactive)
  (agent-notes--jump 'agent-notes-hunk t "hunks"))

(defun agent-notes-previous-hunk ()
  "Move to the previous hunk, in this file or the previous one."
  (interactive)
  (agent-notes--jump 'agent-notes-hunk nil "hunks"))

(defun agent-notes-next-file ()
  "Move to the next file."
  (interactive)
  (agent-notes--jump 'agent-notes-file t "files"))

(defun agent-notes-previous-file ()
  "Move to the previous file."
  (interactive)
  (agent-notes--jump 'agent-notes-file nil "files"))

(defun agent-notes--describe-note (note)
  "Return a one-line description of NOTE."
  (format "#%-3d %-6s %-10s %-8s %s  %s"
          (plist-get note :id) (plist-get note :author)
          (or (plist-get note :severity) "") (plist-get note :status)
          (agent-notes--location note)
          (agent-notes--first-line note 60)))

(defun agent-notes--completion-table (candidates)
  "Return a completion table for CANDIDATES that keeps their order."
  (lambda (string pred action)
    (if (eq action 'metadata)
        '(metadata (display-sort-function . identity))
      (complete-with-action action candidates string pred))))

(defun agent-notes-list ()
  "Jump to a note chosen from a list of all notes, resolved ones included."
  (interactive)
  (let ((candidates (mapcar (lambda (note) (cons (agent-notes--describe-note note)
                                                 (plist-get note :id)))
                            (agent-notes--notes))))
    (unless candidates (user-error "No notes"))
    (agent-notes--goto-note
     (cdr (assoc (completing-read "Note: " (agent-notes--completion-table candidates) nil t)
                 candidates)))))

(defun agent-notes-visit ()
  "Open the file of the line or note at point, at that line.
The file can be edited; when you save it, the review is refreshed
\(see `agent-notes-refresh-on-save').  On a diagram, open its
Graphviz source instead."
  (interactive)
  (let ((diagram (get-text-property (point) 'agent-notes-diagram)))
    (if diagram
        (agent-notes--open-diagram diagram)
      (agent-notes--visit-code))))

(declare-function graphviz-dot-mode "graphviz-dot-mode" ())

(defun agent-notes--open-diagram (source)
  "Show the Graphviz SOURCE of a diagram in another window."
  (with-current-buffer (get-buffer-create "*agent-notes diagram*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert source "\n"))
    (if (fboundp 'graphviz-dot-mode) (graphviz-dot-mode) (fundamental-mode))
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (pop-to-buffer (current-buffer))))

(defun agent-notes--visit-code ()
  "Open the file of the line or note at point, at that line.
When the file no longer has the line's code at that line number, for
example in a review of an older commit, go to the nearest line that
has it."
  (let* ((note (and (get-text-property (point) 'agent-notes-note) (agent-notes--note-at-point)))
         (rec (if note
                  (gethash (plist-get note :id) agent-notes--placement)
                (get-text-property (point) 'agent-notes-loc)))
         (path (if note (plist-get note :path) (plist-get rec :path)))
         (line (cond ((and note (equal (plist-get note :side) "new")) (plist-get note :line))
                     (rec (plist-get rec :new))))
         (text (and rec line (memq (plist-get rec :kind) '(context added))
                    (eql (plist-get rec :new) line)
                    (agent-notes--content rec)))
         (file (and path (not (string-empty-p path))
                    (expand-file-name path (plist-get agent-notes--review :root)))))
    (unless file (user-error "Nothing to visit here"))
    (unless (file-exists-p file) (user-error "%s does not exist in the working tree" path))
    (find-file-other-window file)
    (when (and line (> line 0))
      (widen)
      (when (and text (not (string-blank-p text)))
        (setq line (or (agent-notes--locate-lines
                        (agent-notes--split-lines
                         (buffer-substring-no-properties (point-min) (point-max)))
                        (list text) line)
                       line)))
      (goto-char (point-min))
      (forward-line (1- line)))))

;;;; Notes

(defun agent-notes--compose-new-note (title path side line)
  "Compose a note titled TITLE at LINE on SIDE of PATH."
  (agent-notes--compose
   title nil
   (lambda (body)
     (let ((note (agent-notes--add-note "you" path side line "" body "pending")))
       (agent-notes--save)
       (agent-notes--render)
       (agent-notes--goto-note (plist-get note :id))))))

(defun agent-notes-new-note ()
  "Write a new note on the line of code at point.
Elsewhere, offer to write a general note about the whole change."
  (interactive)
  (let ((rec (and (not (get-text-property (point) 'agent-notes-note))
                  (get-text-property (point) 'agent-notes-loc))))
    (if (and rec (agent-notes--code-p rec))
        (let* ((side (agent-notes--rec-side rec))
               (line (agent-notes--rec-line rec side))
               (path (plist-get rec :path)))
          (agent-notes--compose-new-note (format "New note on %s:%d" path line) path side line))
      (when (y-or-n-p "Point is not on a line of code.  Write a general note? ")
        (agent-notes--compose-new-note "New general note" "" "new" 0)))))

(defun agent-notes-reply ()
  "Reply to the note at point.  The reply is sent with \\[agent-notes-send]."
  (interactive)
  (let ((id (plist-get (agent-notes--require-note) :id)))
    (agent-notes--compose
     (format "Reply to #%d" id) nil
     (lambda (body)
       (let ((note (or (agent-notes--note id) (user-error "Note #%d no longer exists" id)))
             (comment (agent-notes--make-comment "you" body "pending")))
         (plist-put note :comments (append (plist-get note :comments) (list comment)))
         (agent-notes--save)
         (agent-notes--render)
         (agent-notes--goto-note id (plist-get comment :id)))))))

(defun agent-notes--editable-comment-at-point ()
  "Return (NOTE . COMMENT) for your unsent comment at point."
  (let* ((note (agent-notes--require-note))
         (comments (plist-get note :comments))
         (cid (get-text-property (point) 'agent-notes-comment))
         (comment (if cid
                      (cl-find cid comments :key (lambda (c) (plist-get c :id)))
                    (car (last (cl-remove-if-not #'agent-notes--editable-p comments))))))
    (unless (and comment (agent-notes--editable-p comment))
      (user-error "Only your unsent comments can be changed"))
    (cons note comment)))

(defun agent-notes-edit ()
  "Edit your unsent comment at point."
  (interactive)
  (pcase-let* ((`(,note . ,comment) (agent-notes--editable-comment-at-point))
               (id (plist-get note :id))
               (cid (plist-get comment :id)))
    (agent-notes--compose
     (format "Edit comment on #%d" id) (plist-get comment :body)
     (lambda (body)
       (let ((comment (cl-find cid (plist-get (agent-notes--note id) :comments)
                               :key (lambda (c) (plist-get c :id)))))
         (unless (and comment (agent-notes--editable-p comment))
           (user-error "That comment can no longer be edited"))
         (plist-put comment :body body)
         (plist-put comment :time (agent-notes--now))
         (agent-notes--save)
         (agent-notes--render))))))

(defun agent-notes-delete ()
  "Delete your unsent comment at point.
Deleting the first comment of your own note deletes the whole note."
  (interactive)
  (pcase-let ((`(,note . ,comment) (agent-notes--editable-comment-at-point)))
    (if (eq comment (car (plist-get note :comments)))
        (when (yes-or-no-p (format "Delete note #%d? " (plist-get note :id)))
          (setq agent-notes--review
                (plist-put agent-notes--review :notes (delq note (agent-notes--notes)))))
      (when (y-or-n-p "Delete this comment? ")
        (plist-put note :comments (delq comment (plist-get note :comments)))))
    (agent-notes--save)
    (agent-notes--render)))

(defun agent-notes-toggle-resolved ()
  "Resolve the note at point, or reopen it if it is resolved.
Resolved notes are folded and skipped by \\[agent-notes-next-note]
and \\[agent-notes-previous-note]."
  (interactive)
  (let* ((note (agent-notes--require-note))
         (id (plist-get note :id))
         (resolved (not (agent-notes--resolved-p note))))
    (plist-put note :status (if resolved "resolved" "open"))
    (agent-notes--save)
    (agent-notes--render)
    (let ((section (agent-notes--note-section id)))
      (when section
        (if resolved (magit-section-hide section) (magit-section-show section))))
    (if (agent-notes--all-resolved-p)
        (message "Note #%d resolved; all notes are resolved.  Commit with Magit when ready" id)
      (message "Note #%d %s" id (plist-get note :status)))))

;;;; View

(defun agent-notes-toggle-view ()
  "Switch between the unified and the side-by-side diff."
  (interactive)
  (setq agent-notes--view (if (eq agent-notes--view 'split) 'unified 'split))
  (agent-notes--render)
  (message "%s view" (if (eq agent-notes--view 'split) "Side-by-side" "Unified")))

(defun agent-notes-toggle-line-numbers ()
  "Show or hide the line numbers next to the diff."
  (interactive)
  (setq agent-notes--line-numbers (not agent-notes--line-numbers))
  (agent-notes--render)
  (message "Line numbers %s" (if agent-notes--line-numbers "shown" "hidden")))

;;;; Agent commands

(defun agent-notes-send ()
  "Send all your unsent comments to the agent and wait for its answers."
  (interactive)
  (agent-notes--ensure-idle)
  (let* ((ids (agent-notes--pending-comments))
         (notes (cl-remove-if-not
                 (lambda (note) (cl-some (lambda (c) (memq (plist-get c :id) ids))
                                         (plist-get note :comments)))
                 (agent-notes--notes)))
         (what (format "%s in %s" (agent-notes--plural (length ids) "comment")
                       (agent-notes--plural (length notes) "thread"))))
    (unless ids (user-error "Nothing to send"))
    (when (y-or-n-p (format "Send %s to the agent? " what))
      (agent-notes--run "replying" (agent-notes--reply-prompt notes ids)
                        #'agent-notes--apply-replies ids
                        (format "Sent your %s (%s) to the agent."
                                what (mapconcat (lambda (n) (format "#%d" (plist-get n :id)))
                                                notes ", "))))))

(defconst agent-notes--custom-task "Custom instructions…"
  "Completion candidate for typing your own instructions.")

(defun agent-notes--read-task ()
  "Read a task for the agent; return (NAME . INSTRUCTIONS).
Text that is not the name of a task in `agent-notes-tasks' is used
as the instructions."
  (let* ((names (mapcar #'car agent-notes-tasks))
         (choice (string-trim
                  (completing-read (format-prompt "Task (or type instructions)" (car names))
                                   (append names (list agent-notes--custom-task))
                                   nil nil nil 'agent-notes--task-history (car names)))))
    (when (equal choice agent-notes--custom-task)
      (setq choice (string-trim (read-string "Instructions for the agent: "))))
    (when (string-empty-p choice)
      (user-error "No task given"))
    (or (assoc choice agent-notes-tasks)
        (cons (truncate-string-to-width (car (split-string choice "\n")) 40 nil nil "…")
              choice))))

(defun agent-notes--start-task (task)
  "Ask the agent to do TASK, a (NAME . INSTRUCTIONS), on the current review."
  (let ((name (car task)))
    (agent-notes--run name (agent-notes--task-prompt task)
                      (lambda (data _) (agent-notes--apply-review data name))
                      nil
                      (format "Asked the agent to do the task \"%s\" on the diff." name))))

(defun agent-notes-request-review (task)
  "Give the agent TASK on this diff; its notes are added to the existing ones.
Interactively, choose a task from `agent-notes-tasks' or type your
own instructions."
  (interactive (progn (agent-notes--ensure-idle) (list (agent-notes--read-task))))
  (agent-notes--ensure-idle)
  (agent-notes--start-task task))

(defun agent-notes-abort ()
  "Stop the running agent request."
  (interactive)
  (if (process-live-p agent-notes--process)
      (kill-process agent-notes--process)
    (user-error "The agent is not running")))

(defun agent-notes-choose-agent (agent)
  "Use AGENT, a key of `agent-notes-agents', for the next requests.
This sets `agent-notes-agent' for this Emacs session; customize it
to keep the choice.  A review that used another agent starts a new
session with AGENT."
  (interactive
   (let* ((candidates (mapcar (lambda (agent)
                                (cons (format "%s (%s)" (agent-notes--agent-name agent)
                                              (agent-notes--agent-program agent))
                                      (car agent)))
                              agent-notes-agents))
          (current (car (rassq agent-notes-agent candidates))))
     (list (cdr (assoc (completing-read (format-prompt "Agent" current)
                                        (agent-notes--completion-table candidates)
                                        nil t nil nil current)
                       candidates)))))
  (setq agent-notes-agent agent)
  (message "Agent Notes now uses %s" (agent-notes--agent-name)))

(defun agent-notes--choose-agent-description ()
  "Describe `agent-notes-choose-agent' in menus."
  (format "Agent: %s" (propertize (agent-notes--agent-name) 'face 'transient-value)))

;;;; Menus

(transient-define-prefix agent-notes-dispatch ()
  "Show the commands of the review buffer."
  [["Move"
    ("n" "Next open note" agent-notes-next-note)
    ("p" "Previous open note" agent-notes-previous-note)
    ("N" "Next open agent note" agent-notes-next-agent-note)
    ("P" "Previous open agent note" agent-notes-previous-agent-note)
    ("M-n" "Next hunk" agent-notes-next-hunk)
    ("M-p" "Previous hunk" agent-notes-previous-hunk)
    ("}" "Next file" agent-notes-next-file)
    ("{" "Previous file" agent-notes-previous-file)
    ("l" "Jump to any note…" agent-notes-list)]
   ["Notes"
    ("c" "New note" agent-notes-new-note)
    ("R" "Reply" agent-notes-reply)
    ("e" "Edit unsent comment" agent-notes-edit)
    ("k" "Delete unsent comment" agent-notes-delete)
    ("r" "Resolve / reopen" agent-notes-toggle-resolved)
    ("a" "Apply suggested change" agent-notes-apply-suggestion)]
   ["Agent"
    ("s" "Send unsent comments" agent-notes-send)
    ("A" "Give a task…" agent-notes-request-review)
    ("@" agent-notes-choose-agent :description agent-notes--choose-agent-description)
    ("x" "Abort" agent-notes-abort)
    ("$" "What is happening (log)" agent-notes-show-log)]
   ["View"
    ("v" "Unified / side by side" agent-notes-toggle-view)
    ("#" "Line numbers" agent-notes-toggle-line-numbers)
    ("g" "Refresh diff" agent-notes-refresh)
    ("o" "Visit file to edit" agent-notes-visit)
    (:info "TAB  fold section")
    (:info "C-u n  include resolved")
    (:info "^    parent section")
    (:info "1-4  show levels")]])

;;;###autoload (autoload 'agent-notes-menu "agent-notes" nil t)
(transient-define-prefix agent-notes-menu ()
  "Review the changes in the current repository with an agent."
  [["Review"
    ("w" "Working tree…" agent-notes-review-working-tree)
    ("s" "Staged changes…" agent-notes-review-staged)
    ("b" "Branch…" agent-notes-review-branch)
    ("c" "Commit or range…" agent-notes-review-commit)]
   ["Open"
    ("l" "Latest review" agent-notes-open-latest)
    ("o" "A review…" agent-notes-open)]
   ["Agent"
    ("a" agent-notes-choose-agent :description agent-notes--choose-agent-description)]])

;;;; Mode

(defvar-keymap agent-notes-mode-map
  :doc "Keymap for `agent-notes-mode'."
  :parent magit-section-mode-map
  "n" #'agent-notes-next-note
  "p" #'agent-notes-previous-note
  "N" #'agent-notes-next-agent-note
  "P" #'agent-notes-previous-agent-note
  "M-n" #'agent-notes-next-hunk
  "M-p" #'agent-notes-previous-hunk
  "}" #'agent-notes-next-file
  "{" #'agent-notes-previous-file
  "c" #'agent-notes-new-note
  "R" #'agent-notes-reply
  "e" #'agent-notes-edit
  "k" #'agent-notes-delete
  "r" #'agent-notes-toggle-resolved
  "a" #'agent-notes-apply-suggestion
  "s" #'agent-notes-send
  "l" #'agent-notes-list
  "RET" #'agent-notes-visit
  "o" #'agent-notes-visit
  "A" #'agent-notes-request-review
  "v" #'agent-notes-toggle-view
  "#" #'agent-notes-toggle-line-numbers
  "g" #'agent-notes-refresh
  "$" #'agent-notes-show-log
  "@" #'agent-notes-choose-agent
  "x" #'agent-notes-abort
  "C-c C-k" #'agent-notes-abort
  "?" #'agent-notes-dispatch
  "h" #'agent-notes-dispatch)

(put 'agent-notes-dispatch :advertised-binding "?")

(define-derived-mode agent-notes-mode magit-section-mode "Agent-Notes"
  "Major mode for going through a diff together with an AI agent.

Your notes and replies are queued as \"unsent\" until you send them
all with \\[agent-notes-send].  Press \\[agent-notes-dispatch] for a menu of all commands.

\\{agent-notes-mode-map}"
  :interactive nil
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  ;; Highlighting the current section would hide the diff colors.
  (setq-local magit-section-highlight-current nil)
  (setq-local revert-buffer-function #'agent-notes--revert)
  (setq-local header-line-format '(:eval (agent-notes--header-line)))
  (setq agent-notes--view agent-notes-default-view
        agent-notes--line-numbers agent-notes-show-line-numbers)
  (add-hook 'window-size-change-functions #'agent-notes--on-window-size-change nil t)
  (add-hook 'kill-buffer-hook #'agent-notes--cleanup nil t)
  (add-hook 'after-save-hook #'agent-notes--after-save))

;;;; Entry points

(defun agent-notes--read-base ()
  "Read the base branch of a branch review."
  (let ((default (agent-notes--default-base)))
    (completing-read (format-prompt "Base branch" default)
                     (agent-notes--branches) nil nil nil nil default)))

(declare-function magit-commit-at-point "magit-git" ())

(defvar agent-notes--rev-history nil
  "History of commits and ranges given to `agent-notes-review-commit'.")

(defun agent-notes--rev-at-point ()
  "Return the commit at point, or a range of the commits in the region.
This works in Magit buffers such as the log; elsewhere return nil."
  (let ((revs (ignore-errors (magit-region-values '(commit) t))))
    (cond ((cdr revs)
           (deactivate-mark)
           ;; Magit lists the newest first; include the oldest commit too.
           (format "%s^..%s" (car (last revs)) (car revs)))
          (revs (car revs))
          ((fboundp 'magit-commit-at-point)
           (ignore-errors (magit-commit-at-point))))))

(defun agent-notes--read-commit-or-range ()
  "Read a commit, or a range A..B or A...B."
  (let* ((default (or (agent-notes--rev-at-point) "HEAD"))
         (rev (string-trim
               (completing-read (format-prompt "Commit, or range A..B or A...B" default)
                                (agent-notes--branches) nil nil nil
                                'agent-notes--rev-history default))))
    (if (string-empty-p rev) default rev)))

(defun agent-notes--commit-scope (rev)
  "Return (SCOPE BASE) for REV, a commit or a range."
  (list (if (agent-notes--parse-range rev) "range" "commit") rev))

(defun agent-notes--read-scope ()
  "Read the scope of a new review; return (SCOPE BASE)."
  (let* ((choices '(("Working tree: uncommitted changes vs HEAD" . "working")
                    ("Staged: the staged changes vs HEAD" . "staged")
                    ("Branch: all changes since a base branch" . "branch")
                    ("Commit or range: a commit, or A..B" . "commit")))
         (choice (completing-read "Review: " (agent-notes--completion-table choices)
                                  nil t nil nil (caar choices))))
    (pcase (cdr (assoc choice choices))
      ("branch" (list "branch" (agent-notes--read-base)))
      ("commit" (agent-notes--commit-scope (agent-notes--read-commit-or-range)))
      (scope (list scope nil)))))

(defun agent-notes--create-review (scope base)
  "Snapshot the changes in SCOPE and BASE as a new review.
Return its review buffer."
  (let* ((default-directory (agent-notes--root))
         (root default-directory))
    (pcase-let ((`(,diff ,base-label ,base-rev ,head) (agent-notes--make-diff scope base)))
      (when (string-blank-p diff)
        (user-error "No changes to review"))
      (let* ((dir (agent-notes--directory))
             (id (let* ((stamp (format-time-string "%Y%m%d-%H%M%S"))
                        (id stamp)
                        (n 1))
                   (while (file-exists-p (expand-file-name (concat id ".json") dir))
                     (setq n (1+ n) id (format "%s-%d" stamp n)))
                   id))
             (file (expand-file-name (concat id ".json") dir))
             (review (list :version 2 :id id :root root :scope scope
                           :base base-label :base_rev base-rev :head_rev head
                           :subject (and (equal scope "commit")
                                         (agent-notes--git-try "log" "-1" "--format=%s" head))
                           :created (format-time-string "%F %R")
                           :agent (symbol-name agent-notes-agent)
                           :session (agent-notes--uuid)
                           :next_note 1 :next_comment 1 :summaries nil :notes nil)))
        (make-directory dir t)
        (agent-notes--write-file (agent-notes--diff-file file) diff)
        (agent-notes--write-file file (agent-notes--serialize review))
        (let ((buf (agent-notes--get-buffer file)))
          (with-current-buffer buf
            (agent-notes--log "Started"
                              (format "New review, %s: %s.\nThe diff was saved in %s."
                                      (agent-notes--scope-label review)
                                      (agent-notes--diff-stats agent-notes--records)
                                      (agent-notes--diff-file file))))
          buf)))))

;;;###autoload
(defun agent-notes-review (scope &optional base task)
  "Snapshot the changes in SCOPE and give the agent TASK on them.
SCOPE is \"working\" for uncommitted changes against HEAD, \"staged\"
for the staged changes, \"branch\" for everything since the current
branch forked from BASE, \"commit\" for the commit BASE, or \"range\"
for the range BASE (A..B or A...B).  TASK is a (NAME . INSTRUCTIONS);
it defaults to the first entry of `agent-notes-tasks'."
  (interactive (let ((default-directory (agent-notes--root)))
                 (append (agent-notes--read-scope) (list (agent-notes--read-task)))))
  (let* ((task (or task (car agent-notes-tasks)
                   (user-error "No task given; see `agent-notes-tasks'")))
         (buf (agent-notes--create-review scope base)))
    (pop-to-buffer-same-window buf)
    (with-current-buffer buf
      (agent-notes--start-task task))))

;;;###autoload
(defun agent-notes-review-working-tree (task)
  "Give the agent TASK on the uncommitted changes of the repository."
  (interactive (progn (agent-notes--root) (list (agent-notes--read-task))))
  (agent-notes-review "working" nil task))

;;;###autoload
(defun agent-notes-review-staged (task)
  "Give the agent TASK on the staged changes of the repository."
  (interactive (progn (agent-notes--root) (list (agent-notes--read-task))))
  (agent-notes-review "staged" nil task))

;;;###autoload
(defun agent-notes-review-branch (base task)
  "Give the agent TASK on all changes since the current branch forked from BASE."
  (interactive (let ((default-directory (agent-notes--root)))
                 (list (agent-notes--read-base) (agent-notes--read-task))))
  (agent-notes-review "branch" base task))

;;;###autoload
(defun agent-notes-review-commit (rev task)
  "Give the agent TASK on the changes of the commit REV.
REV may also be a range: A..B for the changes from A to B, or A...B
for the changes on B since it forked from A.  In a Magit log, the
default is the commit at point, or the commits in the region.
The agent edits the working tree, which may differ from REV."
  (interactive (let ((default-directory (agent-notes--root)))
                 (list (agent-notes--read-commit-or-range) (agent-notes--read-task))))
  (apply #'agent-notes-review (append (agent-notes--commit-scope rev) (list task))))

;;;###autoload
(defun agent-notes-open ()
  "Open a previous review of the current repository."
  (interactive)
  (let* ((default-directory (agent-notes--root))
         (candidates
          (mapcar (lambda (file)
                    (let* ((review (agent-notes--json-parse (agent-notes--read-file file)))
                           (notes (plist-get review :notes)))
                      (cons (format "%s  %-24s  %d open / %d notes"
                                    (plist-get review :created)
                                    (agent-notes--scope-label review)
                                    (cl-count-if-not #'agent-notes--resolved-p notes)
                                    (length notes))
                            file)))
                  (agent-notes--review-files))))
    (unless candidates (user-error "No reviews yet; use M-x agent-notes-review"))
    (pop-to-buffer-same-window
     (agent-notes--get-buffer
      (cdr (assoc (completing-read "Open review: " (agent-notes--completion-table candidates)
                                   nil t)
                  candidates))))))

;;;###autoload
(defun agent-notes-open-latest ()
  "Open the most recent review of the current repository."
  (interactive)
  (let* ((default-directory (agent-notes--root))
         (file (car (agent-notes--review-files))))
    (unless file (user-error "No reviews yet; use M-x agent-notes-review"))
    (pop-to-buffer-same-window (agent-notes--get-buffer file))))

(provide 'agent-notes)

(with-eval-after-load 'magit
  (require 'agent-notes-magit))

;;; agent-notes.el ends here
