;;; agent-notes-agent.el --- Talking to the Copilot CLI for agent-notes -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el.  This file builds the
;; prompts, runs the Copilot CLI in the review's session, applies its
;; JSON answer, notices which files it changed, and applies the code
;; changes it suggests in notes.

;;; Code:

(require 'agent-notes-core)
(require 'agent-notes-diff)
(require 'agent-notes-render)
(require 'agent-notes-log)

(declare-function agent-notes--get-buffer "agent-notes" (file))

(defvar-local agent-notes--ticker nil
  "Timer that updates the elapsed time while the agent works.")

;;;; Prompts

(defconst agent-notes--note-spec
  "Each note is anchored to one line of the diff:
- \"path\": file path relative to the repository root, without a/ or b/ prefixes.
- \"side\": \"new\" for added (+) or unchanged context lines, with the line number in the new version of the file; \"old\" for removed (-) lines, with the line number in the old version.
- \"line\": the line number, as an integer.
- \"severity\": one of \"issue\", \"warning\", \"suggestion\", \"question\", \"nit\", or \"info\" for explanations that are not problems.
- \"body\": the note in Markdown. Be specific and concise.
- \"suggestion\" (optional, only for \"side\": \"new\"): when you know the exact fix, the complete replacement for lines \"line\" through \"end_line\" of the new version of the file, as one string with \\n between lines and the original indentation. The user can apply it with one key, so it must be correct, complete code. Leave it out when unsure or when the fix spans several places.
- \"end_line\" (optional): the last line replaced by \"suggestion\"; defaults to \"line\".
To comment on the change as a whole rather than a line, use \"path\": \"\" and \"line\": 0."
  "Description of the note format given to the agent.")

(defun agent-notes--permissions-prompt ()
  "Return the part of the prompt that says what the agent may do."
  (if agent-notes-allow-edits
      (concat "You may read any file in the repository and run read-only git commands for context. "
              "You can also edit files in the repository, but only when the user asks you to "
              "change something. Never commit, stage, stash or reset, and do not touch the "
              "review files described above.\n")
    (concat "You may read any file in the repository and run read-only git commands for context. "
            "You cannot modify files in this session: when the user asks for a change, "
            "describe it and show the code instead.\n")))

(defun agent-notes--context-prompt ()
  "Return the part of the prompt describing the review."
  (let* ((review agent-notes--review)
         (base-rev (plist-get review :base_rev)))
    (concat
     "You are helping the user go through code changes in a git repository, inside their editor. "
     "Your notes are shown inline in the diff, and the user can reply to them.\n"
     "Repository: " (plist-get review :root) "\n"
     "Scope: "
     (if (equal (plist-get review :scope) "branch")
         (format "all changes on the current branch since it diverged from %s (merge-base %s)%s"
                 (plist-get review :base) base-rev
                 (if agent-notes-branch-include-uncommitted
                     ", including uncommitted and untracked files" ""))
       (format "uncommitted changes (staged, unstaged and untracked files) compared to HEAD (%s)"
               base-rev))
     ".\nThe exact unified diff under review, which all line numbers refer to, is saved at:\n  "
     (agent-notes--diff-file agent-notes--file) "\n"
     "The review itself is stored in " (file-name-directory agent-notes--file) ".\n"
     (agent-notes--permissions-prompt))))

(defun agent-notes--json-instructions (example)
  "Return the instructions for the final JSON block, showing EXAMPLE."
  (concat "Your final message must end with exactly one fenced ```json code block "
          "and nothing after it, with this shape:\n```json\n" example "\n```\n"))

(defun agent-notes--existing-notes-prompt ()
  "Return the list of existing notes, so the agent does not repeat them."
  (let ((notes (agent-notes--notes)))
    (if (null notes)
        ""
      (concat "\nThese notes already exist on this diff; do not repeat them:\n"
              (mapconcat (lambda (note)
                           (format "- #%d %s: %s\n" (plist-get note :id)
                                   (agent-notes--location note)
                                   (agent-notes--first-line note 100)))
                         notes "")))))

(defun agent-notes--task-prompt (task)
  "Return the prompt asking the agent to do TASK, a (NAME . INSTRUCTIONS)."
  (concat
   (agent-notes--context-prompt)
   "\nRead the diff file first. Your task:\n" (cdr task) "\n"
   (if agent-notes-extra-instructions
       (concat "\nAdditional instructions from the user:\n" agent-notes-extra-instructions "\n")
     "")
   (agent-notes--existing-notes-prompt)
   "\nDo not modify any files for this task unless the task explicitly asks you to.\n"
   "The summary is shown as Markdown in a plain-text editor: use short paragraphs, "
   "bullet points and fenced code blocks, but no tables, images or HTML.\n\n"
   agent-notes--note-spec "\n\n"
   (agent-notes--json-instructions
    (concat "{\"summary\": \"...\",\n"
            " \"notes\": [{\"path\": \"src/example.py\", \"line\": 42, \"side\": \"new\", "
            "\"severity\": \"warning\", \"body\": \"...\"}]}"))))

(defun agent-notes--format-thread (note new-ids)
  "Return NOTE as text for the agent; comments in NEW-IDS are marked NEW."
  (let ((rec (agent-notes--exact-record note)))
    (concat
     (format "--- Thread #%d · %s · started by %s%s · status: %s\n"
             (plist-get note :id)
             (if (agent-notes--general-p note)
                 "about the whole change"
               (format "%s %s line %s" (plist-get note :path) (plist-get note :side)
                       (plist-get note :line)))
             (if (equal (plist-get note :author) "agent") "you (the agent)" "the user")
             (let ((s (plist-get note :severity)))
               (if (and s (not (string-empty-p s))) (format " · severity: %s" s) ""))
             (plist-get note :status))
     (cond ((plist-get note :outdated)
            (format "The code this thread was about has changed; it was: %s\n"
                    (plist-get note :text)))
           (rec (format "Diff line: %s\n" (plist-get rec :text)))
           (t ""))
     (let ((suggestion (plist-get note :suggestion)))
       (if (not (stringp suggestion))
           ""
         (format "Your suggested replacement for %s (%s):\n%s\n"
                 (agent-notes--plural (or (plist-get note :span) 1) "line")
                 (if (plist-get note :applied) "the user applied it" "not applied")
                 suggestion)))
     (mapconcat (lambda (c)
                  (format "[%s%s]\n%s\n"
                          (if (equal (plist-get c :author) "agent") "agent" "user")
                          (if (memq (plist-get c :id) new-ids) ", NEW" "")
                          (plist-get c :body)))
                (plist-get note :comments) "")
     "\n")))

(defun agent-notes--reply-prompt (notes new-ids)
  "Return the prompt sending the user's comments in NEW-IDS on NOTES."
  (concat
   "The user has gone through the notes on the diff and responded.\n"
   (agent-notes--context-prompt)
   "\nBelow are the threads with new messages from the user (marked NEW). "
   "Threads started by the user are new comments or questions for you. "
   "Answer every thread that has NEW messages. Be direct and concise; if the user is right, say so. "
   "Set \"resolve\" to true only when the thread's concern is settled. "
   "If the discussion reveals other problems, you may add new notes.\n"
   (if agent-notes-allow-edits
       (concat "When a message asks you to change the code, make the change by editing the "
               "files, then say in your reply which files and lines you changed. Do not change "
               "anything the user did not ask for. The diff is refreshed after you finish and "
               "the notes move with the code. ")
     "")
   "When a message asks for a suggestion rather than a change, add \"suggestion\" and "
   "\"end_line\" to your reply instead, with the same meaning as in a note, counted from "
   "the thread's line; the user can then apply it with one key.\n\n"
   (mapconcat (lambda (note) (agent-notes--format-thread note new-ids)) notes "")
   agent-notes--note-spec "\n\n"
   (agent-notes--json-instructions
    "{\"replies\": [{\"note\": 3, \"body\": \"...\", \"resolve\": false}],\n \"notes\": []}")))

;;;; Applying the answer

(defun agent-notes--extract-json (text)
  "Return the last JSON object in TEXT, preferring fenced code blocks."
  (let (blocks current in-block)
    (dolist (line (split-string text "\n"))
      (cond ((string-match-p "\\`[ \t]*```" line)
             (if in-block
                 (progn (push (string-join (nreverse current) "\n") blocks)
                        (setq in-block nil current nil))
               (setq in-block t current nil)))
            (in-block (push line current))))
    (cl-flet ((parse (s) (let ((v (ignore-errors (agent-notes--json-parse s))))
                           (and (consp v) (keywordp (car v)) v))))
      (or (cl-some #'parse blocks)
          (let ((beg (string-search "{" text))
                (end (cl-position ?} text :from-end t)))
            (and beg end (< beg end) (parse (substring text beg (1+ end)))))
          (error "Could not find a JSON object in the agent's answer")))))

(defun agent-notes--set-suggestion (note suggestion end-line)
  "Attach SUGGESTION to NOTE, replacing its line through END-LINE.
Return non-nil if NOTE can take a suggestion and SUGGESTION is one."
  (when (and (stringp suggestion)
             (not (string-blank-p suggestion))
             (equal (plist-get note :side) "new")
             (not (agent-notes--general-p note))
             (> (plist-get note :line) 0))
    (let* ((line (plist-get note :line))
           (end (if end-line (agent-notes--as-int end-line) line))
           (span (max 1 (min 500 (1+ (- end line))))))
      (plist-put note :suggestion (string-remove-suffix "\n" suggestion))
      (plist-put note :span span)
      ;; The code it replaces, to check that it is still there when applied.
      (plist-put note :original (agent-notes--file-lines (plist-get note :path) line span))
      (plist-put note :applied nil)
      t)))

(defun agent-notes--add-agent-note (spec)
  "Add the note described by the agent's JSON SPEC; return it or nil."
  (let ((body (plist-get spec :body))
        (severity (plist-get spec :severity)))
    (when (and (stringp body) (not (string-blank-p body)))
      (let ((note (agent-notes--add-note
                   "agent"
                   (agent-notes--normalize-path (plist-get spec :path))
                   (if (equal (plist-get spec :side) "old") "old" "new")
                   (agent-notes--as-int (plist-get spec :line))
                   (if (stringp severity) severity "suggestion")
                   body "sent")))
        (agent-notes--set-suggestion note (plist-get spec :suggestion) (plist-get spec :end_line))
        note))))

(defun agent-notes--describe-new-notes (notes)
  "Describe the new NOTES for the log, or return nil if there are none."
  (when notes
    (let ((suggestions (cl-count-if (lambda (n) (plist-get n :suggestion)) notes)))
      (concat "added " (agent-notes--plural (length notes) "note")
              (if (> suggestions 0)
                  (format " (%d with a suggested change)" suggestions)
                "")))))

(defun agent-notes--apply-review (data task-name)
  "Store the result DATA of the task TASK-NAME returned by the agent.
Return a description of what changed."
  (unless (or (plist-member data :notes) (plist-member data :summary))
    (error "The agent's answer has no \"notes\""))
  (let ((summary (plist-get data :summary))
        (added (delq nil (mapcar #'agent-notes--add-agent-note (plist-get data :notes))))
        (has-summary nil))
    (when (and (stringp summary) (not (string-blank-p summary)))
      (setq has-summary t)
      (setq agent-notes--review
            (plist-put agent-notes--review :summaries
                       (append (plist-get agent-notes--review :summaries)
                               (list (list :task task-name :text summary
                                           :time (format-time-string "%F %R")))))))
    (concat (agent-notes--capitalize-first
             (or (agent-notes--describe-new-notes added) "added no notes"))
            (if has-summary " and a summary" "")
            ".")))

(defun agent-notes--capitalize-first (string)
  "Return STRING with its first letter in upper case."
  (if (string-empty-p string) string
    (concat (upcase (substring string 0 1)) (substring string 1))))

(defun agent-notes--apply-replies (data in-flight)
  "Store the agent's reply DATA to the comments IN-FLIGHT.
Return a description of what changed."
  (unless (or (plist-member data :replies) (plist-member data :notes))
    (error "The agent's answer has no \"replies\""))
  (dolist (note (agent-notes--notes))
    (dolist (comment (plist-get note :comments))
      (when (memq (plist-get comment :id) in-flight)
        (plist-put comment :state "sent"))))
  (let ((answered 0) (resolved 0) (suggested 0) (unknown nil))
    (dolist (reply (plist-get data :replies))
      (let ((note (agent-notes--note (agent-notes--as-int (plist-get reply :note))))
            (body (plist-get reply :body)))
        (if (not note)
            (push (format "%S" (plist-get reply :note)) unknown)
          (when (and (stringp body) (not (string-blank-p body)))
            (cl-incf answered)
            (plist-put note :comments
                       (append (plist-get note :comments)
                               (list (agent-notes--make-comment "agent" body "sent")))))
          (when (agent-notes--set-suggestion note (plist-get reply :suggestion)
                                             (plist-get reply :end_line))
            (cl-incf suggested))
          (when (and (plist-get reply :resolve) (not (agent-notes--resolved-p note)))
            (cl-incf resolved)
            (plist-put note :status "resolved")))))
    (let ((added (delq nil (mapcar #'agent-notes--add-agent-note (plist-get data :notes)))))
      (concat (format "Answered %s" (agent-notes--plural answered "thread"))
              (if (> resolved 0) (format ", resolved %d" resolved) "")
              (if (> suggested 0) (format ", suggested %s" (agent-notes--plural suggested "change")) "")
              (if added (concat ", " (agent-notes--describe-new-notes added)) "")
              "."
              (if unknown
                  (format "\nIgnored replies to notes that don't exist: %s."
                          (string-join (nreverse unknown) ", "))
                "")))))

;;;; Running Copilot

(defun agent-notes--copilot-args (prompt)
  "Return the Copilot arguments to run PROMPT in the review session."
  (let ((allowed (if agent-notes-allow-edits
                     (append agent-notes-allowed-tools '("write"))
                   agent-notes-allowed-tools))
        (denied (if agent-notes-allow-edits
                    (remove "write" agent-notes-denied-tools)
                  (cl-adjoin "write" agent-notes-denied-tools :test #'equal))))
    (append (list "-s" "--session-id" (plist-get agent-notes--review :session)
                  (concat "--add-dir=" (file-name-directory agent-notes--file)))
            (mapcar (lambda (tool) (concat "--allow-tool=" tool)) allowed)
            (mapcar (lambda (tool) (concat "--deny-tool=" tool)) denied)
            agent-notes-copilot-extra-args
            (list "-p" prompt))))

(defun agent-notes--stop-ticker ()
  "Stop updating the elapsed time."
  (when (timerp agent-notes--ticker)
    (cancel-timer agent-notes--ticker))
  (setq agent-notes--ticker nil))

(defun agent-notes--run (label prompt on-success &optional in-flight what)
  "Run Copilot with PROMPT in the review session.
LABEL names the request in the header.  WHAT describes it for the
log.  On success, call ON-SUCCESS with the parsed JSON answer and
IN-FLIGHT, the ids of the comments sent; it returns a description
of what changed."
  (unless (executable-find agent-notes-copilot-program)
    (user-error "Cannot find `%s'; customize `agent-notes-copilot-program'"
                agent-notes-copilot-program))
  (let* ((file agent-notes--file)
         (default-directory (plist-get agent-notes--review :root))
         ;; To tell which files the agent changes.
         (before (ignore-errors
                   (agent-notes--fingerprints (car (agent-notes--snapshot-diff agent-notes--review)))))
         (args (agent-notes--copilot-args prompt)))
    (agent-notes--log
     "Sent" (concat (or what (format "Asked the agent: %s." label))
                    "\nCopilot reads the diff and the code it needs, then answers; "
                    "this often takes a minute or two.")
     (list "Prompt" prompt)
     (list "Command" (concat agent-notes-copilot-program " "
                             (mapconcat #'shell-quote-argument (butlast args 2) " ")
                             " -p <prompt>")))
    (setq agent-notes--in-flight in-flight
          agent-notes--changes nil
          agent-notes--status (concat label "…")
          agent-notes--started (float-time)
          agent-notes--process
          (make-process
           :name "agent-notes"
           :buffer (generate-new-buffer " *agent-notes-output*")
           :command (cons agent-notes-copilot-program args)
           :connection-type 'pipe
           :coding 'utf-8
           :noquery t
           :sentinel (lambda (proc _event)
                       (agent-notes--sentinel proc file label on-success in-flight before))))
    (agent-notes--stop-ticker)
    (setq agent-notes--ticker (run-at-time 1 1 #'force-mode-line-update t))
    (agent-notes--render)))

(defun agent-notes--revert-file-buffers (paths)
  "Revert the unmodified buffers visiting PATHS; return the modified ones."
  (let ((root (plist-get agent-notes--review :root))
        (conflicts nil))
    (dolist (path paths)
      (let ((buf (find-buffer-visiting (expand-file-name path root))))
        (when buf
          (if (buffer-modified-p buf)
              (push path conflicts)
            (with-current-buffer buf
              (ignore-errors (revert-buffer t t t)))))))
    (nreverse conflicts)))

(defun agent-notes--detect-changes (before)
  "Find the files changed since BEFORE and refresh the diff if needed.
BEFORE is the result of `agent-notes--fingerprints' when the agent
started.  Log what happened and return a short message, or nil."
  (let* ((snapshot (agent-notes--snapshot-diff agent-notes--review))
         (diff (car snapshot))
         (after (agent-notes--fingerprints diff))
         (stale (not (equal diff (agent-notes--stored-diff))))
         (changed nil))
    (when before
      (dolist (entry (append before after))
        (let ((path (car entry)))
          (unless (or (member path changed)
                      (equal (cdr (assoc path before)) (cdr (assoc path after))))
            (push path changed))))
      (setq agent-notes--changes (nreverse changed)))
    (let ((conflicts (agent-notes--revert-file-buffers agent-notes--changes)))
      (when conflicts
        (agent-notes--log "Changes" (format "The agent changed %s, which you have unsaved \
changes to.  Check those buffers before saving." (string-join conflicts ", ")))))
    (when stale
      (let ((what (if agent-notes--changes
                      (format "the agent changed %s" (string-join agent-notes--changes ", "))
                    "the code changed while the agent worked")))
        (if (not agent-notes-auto-refresh)
            (let ((msg (format "%s; press g to refresh the diff" what)))
              (agent-notes--log "Changes" (concat (agent-notes--capitalize-first msg) "."))
              msg)
          (let ((msg (format "%s; diff refreshed, %s" what
                             (agent-notes--describe-moves (agent-notes--resnapshot snapshot)))))
            (agent-notes--log "Changes" (concat (agent-notes--capitalize-first msg) "."))
            msg))))))

(defun agent-notes--last-lines (text n)
  "Return the last N non-empty lines of TEXT."
  (string-join (last (split-string text "\n" t "[ \t\r]+") n) "\n"))

(defun agent-notes--sentinel (proc file label on-success in-flight before)
  "Handle the end of the Copilot PROC for the review FILE.
LABEL, ON-SUCCESS and IN-FLIGHT are as in `agent-notes--run'.
BEFORE is as in `agent-notes--detect-changes'."
  (when (memq (process-status proc) '(exit signal))
    (let* ((output (with-current-buffer (process-buffer proc) (buffer-string)))
           (code (process-exit-status proc))
           (aborted (eq (process-status proc) 'signal))
           (ok (and (not aborted) (zerop code)))
           (changes nil))
      (kill-buffer (process-buffer proc))
      (with-current-buffer (agent-notes--get-buffer file)
        (let ((elapsed (or (agent-notes--elapsed) "?")))
          (agent-notes--stop-ticker)
          (setq agent-notes--process nil
                agent-notes--status nil
                agent-notes--started nil
                agent-notes--in-flight nil)
          (cond
           (aborted
            (agent-notes--log "Stopped" (format "The request (%s) was aborted after %s." label elapsed)
                              (list "Output so far" output)))
           (ok
            (agent-notes--log "Done" (format "Copilot answered after %s." elapsed)
                              (list "Raw answer" output)))
           (t
            (agent-notes--log "Failed" (format "Copilot exited with code %s after %s:\n%s"
                                               code elapsed (agent-notes--last-lines output 6))
                              (list "Full output" output))))
          ;; Refresh first, so new notes are anchored to the code as it is now.
          (condition-case err
              (setq changes (agent-notes--detect-changes before))
            (error (agent-notes--log "Failed" (format "Could not check whether files changed: %s"
                                                      (error-message-string err)))))
          (if (not ok)
              (message "Agent Notes: %s %s%s (press $ for the log)" label
                       (if aborted "aborted" "failed")
                       (if changes (concat "; " changes) ""))
            (condition-case err
                (let ((result (funcall on-success (agent-notes--extract-json output) in-flight)))
                  (agent-notes--save)
                  (agent-notes--log "Applied" (or result "Applied the answer."))
                  (message "Agent Notes: %s done%s" label (if changes (concat "; " changes) "")))
              (error
               (agent-notes--log "Failed" (format "Could not use the agent's answer: %s.  \
Your comments stay unsent; you can send them again."
                                                  (error-message-string err)))
               (message "Agent Notes: %s failed: %s (press $ for the log)"
                        label (error-message-string err)))))
          (agent-notes--render))))))

;;;; Suggested changes

(defun agent-notes-apply-suggestion ()
  "Apply the change suggested in the note at point and resolve the note.
The file is changed and saved; undo in its buffer if needed.  The
diff is then refreshed."
  (interactive)
  (agent-notes--ensure-idle)
  (let* ((note (agent-notes--require-note))
         (id (plist-get note :id))
         (suggestion (or (plist-get note :suggestion)
                         (user-error "Note #%d has no suggested change" id)))
         (path (plist-get note :path))
         (line (plist-get note :line))
         (span (or (plist-get note :span) 1))
         (original (plist-get note :original))
         (file (expand-file-name path (plist-get agent-notes--review :root))))
    (when (plist-get note :applied)
      (user-error "The suggestion of #%d is already applied" id))
    (when (plist-get note :outdated)
      (user-error "The code of #%d has changed; ask the agent for a new suggestion" id))
    (unless (file-exists-p file)
      (user-error "%s does not exist in the working tree" path))
    (with-current-buffer (find-file-noselect file)
      (when (buffer-modified-p)
        (user-error "%s has unsaved changes; save it first" path))
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (unless (and (zerop (forward-line (1- line))) (not (eobp)))
            (user-error "%s has no line %d; press g to refresh the diff" path line))
          (let* ((beg (point))
                 (end (progn (forward-line (1- span)) (line-end-position)))
                 (current (buffer-substring-no-properties beg end)))
            (unless (if original
                        (equal current original)
                      (equal (car (split-string current "\n")) (plist-get note :text)))
              (user-error "Lines %d-%d of %s are not the code the suggestion is for; \
press g to refresh the diff" line (+ line span -1) path))
            (delete-region beg end)
            (goto-char beg)
            (insert suggestion))))
      (save-buffer))
    (plist-put note :applied t)
    (plist-put note :status "resolved")
    (agent-notes--save)
    (let ((moves (condition-case err
                     (format "diff refreshed, %s"
                             (agent-notes--describe-moves (agent-notes--resnapshot)))
                   (error (format "could not refresh the diff: %s" (error-message-string err))))))
      (agent-notes--log "You" (format "Applied the suggestion of #%d to %s:%d and resolved it; %s."
                                      id path line moves)))
    (agent-notes--render)
    (let ((section (agent-notes--note-section id)))
      (when section (magit-section-hide section)))
    (message "Applied the suggestion of #%d to %s (undo in that file's buffer)" id path)))

(provide 'agent-notes-agent)
;;; agent-notes-agent.el ends here
