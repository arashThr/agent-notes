;;; agent-notes.el --- Review git changes with an AI agent using inline notes -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, vc, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Agent Notes lets you review the changes in a git repository together
;; with an AI agent (GitHub Copilot CLI), using notes attached to lines
;; of a read-only diff.
;;
;; - M-x agent-notes-review   Snapshot the working tree (or the current
;;                            branch vs. a base branch) and ask the agent
;;                            to review it.  The agent's notes appear
;;                            inline, under the lines they refer to.
;; - M-x agent-notes-open     Reopen a previous review.
;;
;; In the review buffer you can navigate between notes, add your own
;; notes, reply to the agent, edit or delete your unsent comments and
;; resolve threads.  Your comments are queued; press `s' to send all of
;; them to the agent in one go.  The agent answers in the same Copilot
;; session, so it remembers the review.
;;
;; The agent runs with read-only permissions and returns its notes as
;; JSON; only Emacs writes the review files, which live in
;; .git/agent-notes/ (never committed).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'diff-mode)
(require 'json)
(require 'text-property-search)

;;;; Customization

(defgroup agent-notes nil
  "Review git changes with an AI agent using inline notes."
  :group 'tools
  :prefix "agent-notes-")

(defcustom agent-notes-copilot-program "copilot"
  "Name or path of the GitHub Copilot CLI executable."
  :type 'string)

(defcustom agent-notes-copilot-extra-args nil
  "Extra arguments passed to every Copilot invocation.
For example \\='(\"--model\" \"gpt-5\")."
  :type '(repeat string))

(defcustom agent-notes-allowed-tools
  '("shell(git diff)" "shell(git log)" "shell(git show)" "shell(git blame)"
    "shell(git status)" "shell(git grep)" "shell(git ls-files)"
    "shell(rg)" "shell(grep)" "shell(ls)" "shell(cat)" "shell(head)"
    "shell(tail)" "shell(wc)")
  "Copilot permission patterns the agent may use without asking.
Each entry is passed as --allow-tool.  Keep these read-only."
  :type '(repeat string))

(defcustom agent-notes-denied-tools '("write")
  "Copilot permission patterns the agent is never allowed to use.
Each entry is passed as --deny-tool."
  :type '(repeat string))

(defcustom agent-notes-base-branch nil
  "Default base branch for branch reviews.
When nil, use origin/HEAD, then main or master."
  :type '(choice (const :tag "Auto-detect" nil) string))

(defcustom agent-notes-branch-include-uncommitted t
  "When non-nil, branch reviews also include uncommitted changes."
  :type 'boolean)

(defcustom agent-notes-review-instructions nil
  "Extra instructions appended to the review prompt, or nil."
  :type '(choice (const :tag "None" nil) string))

(defcustom agent-notes-directory-name "agent-notes"
  "Name of the directory inside the git directory that stores reviews."
  :type 'string)

;;;; Faces

(defface agent-notes-note
  '((((class color) (background dark)) :background "#252a36" :extend t)
    (((class color) (background light)) :background "#f5f1e6" :extend t)
    (t :inherit highlight :extend t))
  "Background of note blocks.")

(defface agent-notes-border '((t :inherit shadow))
  "Face for the frame drawn around notes.")

(defface agent-notes-agent '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the agent's name.")

(defface agent-notes-you '((t :inherit font-lock-string-face :weight bold))
  "Face for your name.")

(defface agent-notes-pending '((t :inherit warning :slant italic :weight normal))
  "Face for unsent comments and work in progress.")

(defface agent-notes-resolved '((t :inherit shadow))
  "Face for resolved notes.")

(defface agent-notes-code '((t :inherit font-lock-constant-face))
  "Face for inline code in notes.")

(defface agent-notes-title '((t :inherit bold :height 1.2))
  "Face for the review title.")

(defface agent-notes-file-header '((t :inherit diff-file-header :extend t))
  "Face for file headers.")

(defface agent-notes-hunk-header '((t :inherit diff-hunk-header :extend t))
  "Face for hunk headers.")

(defface agent-notes-line-number '((t :inherit line-number))
  "Face for line numbers in the diff gutter.")

;;;; Internal state

(defconst agent-notes--empty-tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  "Git's empty tree, used as the base when the repository has no commits.")

(defconst agent-notes--pad (make-string 12 ?\s)
  "Indentation of notes; matches the width of the line-number gutter.")

(defconst agent-notes--log-buffer "*agent-notes-log*")

(defvar-local agent-notes--file nil "JSON file of the review in this buffer.")
(defvar-local agent-notes--review nil "The review plist.")
(defvar-local agent-notes--records nil "Parsed diff line records.")
(defvar-local agent-notes--index nil "Map from location key to diff record.")
(defvar-local agent-notes--placement nil "Map from note id to the record it is shown under.")
(defvar-local agent-notes--folded nil "Map from note id to explicit fold state.")
(defvar-local agent-notes--process nil "Running Copilot process, if any.")
(defvar-local agent-notes--status nil "What the agent is doing, or nil when idle.")
(defvar-local agent-notes--in-flight nil "Ids of comments currently being sent.")

;;;; Git

(defun agent-notes--git-call (ok-codes args)
  "Run git with ARGS; return stdout if the exit code is in OK-CODES."
  (with-temp-buffer
    (let* ((coding-system-for-read 'utf-8)
           (code (apply #'process-file "git" nil (list t nil) nil args)))
      (and (memq code ok-codes) (buffer-string)))))

(defun agent-notes--git (&rest args)
  "Run git with ARGS and return stdout, signaling an error on failure."
  (or (agent-notes--git-call '(0) args)
      (error "Command failed: git %s" (string-join args " "))))

(defun agent-notes--git-try (&rest args)
  "Run git with ARGS and return trimmed stdout, or nil on failure."
  (let ((out (agent-notes--git-call '(0) args)))
    (and out (string-trim out))))

(defun agent-notes--diff-args ()
  "Common arguments for producing a stable, parseable diff."
  '("-c" "core.quotepath=false" "diff" "--no-color" "--no-ext-diff"
    "-M" "--src-prefix=a/" "--dst-prefix=b/"))

(defun agent-notes--git-diff (&rest revs)
  "Return the diff between REVS (or REV and the working tree)."
  (apply #'agent-notes--git (append (agent-notes--diff-args) revs '("--"))))

(defun agent-notes--untracked-diff ()
  "Return a diff that adds every untracked, non-ignored file."
  (mapconcat
   (lambda (file)
     (or (agent-notes--git-call
          '(0 1) (append (agent-notes--diff-args)
                         (list "--no-index" "--" "/dev/null" file)))
         ""))
   (split-string (agent-notes--git "ls-files" "-z" "--others" "--exclude-standard")
                 "\0" t)
   ""))

(defun agent-notes--root ()
  "Return the top-level directory of the current git repository."
  (let ((top (agent-notes--git-try "rev-parse" "--show-toplevel")))
    (unless top (user-error "Not inside a git repository"))
    (file-name-as-directory top)))

(defun agent-notes--directory ()
  "Return the directory that stores reviews for the current repository."
  (expand-file-name agent-notes-directory-name
                    (or (agent-notes--git-try "rev-parse" "--absolute-git-dir")
                        (user-error "Not inside a git repository"))))

(defun agent-notes--default-base ()
  "Guess the branch to compare the current branch against."
  (or agent-notes-base-branch
      (agent-notes--git-try "symbolic-ref" "--quiet" "--short"
                            "refs/remotes/origin/HEAD")
      (cl-find-if (lambda (b) (agent-notes--git-try "rev-parse" "--verify" "--quiet" b))
                  '("main" "master" "origin/main" "origin/master"))))

(defun agent-notes--branches ()
  "Return local and remote branch names."
  (split-string (agent-notes--git "for-each-ref" "--format=%(refname:short)"
                                  "refs/heads" "refs/remotes")
                "\n" t))

(defun agent-notes--make-diff (scope base)
  "Return (DIFF BASE-LABEL BASE-REV HEAD-REV) for SCOPE and BASE."
  (let ((head (agent-notes--git-try "rev-parse" "--verify" "--quiet" "HEAD")))
    (pcase scope
      ("working"
       (let ((rev (or head agent-notes--empty-tree)))
         (list (concat (agent-notes--git-diff rev) (agent-notes--untracked-diff))
               "HEAD" rev (or head ""))))
      ("branch"
       (unless head (user-error "The repository has no commits yet"))
       (let ((mb (or (agent-notes--git-try "merge-base" base "HEAD")
                     (user-error "No common ancestor between %s and HEAD" base))))
         (list (if agent-notes-branch-include-uncommitted
                   (concat (agent-notes--git-diff mb) (agent-notes--untracked-diff))
                 (agent-notes--git-diff mb "HEAD"))
               base mb head)))
      (_ (error "Unknown scope %S" scope)))))

;;;; Diff parsing

(defun agent-notes--unquote-path (path)
  "Undo git's quoting of PATH."
  (let ((path (string-trim-right path "\t")))
    (if (string-prefix-p "\"" path)
        (condition-case nil (read path) (error path))
      path)))

(defun agent-notes--strip-prefix (path)
  "Remove a leading a/ or b/ from PATH."
  (if (string-match "\\`[ab]/" path) (substring path 2) path))

(defun agent-notes--path-from-header (line)
  "Extract the file path from a `diff --git' LINE."
  (if (string-match "\\`diff --git a/\\(.*\\) b/\\(.*\\)\\'" line)
      (match-string 2 line)
    "?"))

(defun agent-notes--parse-file-meta (file line)
  "Update the FILE record from the extended header LINE."
  (cond
   ((string-prefix-p "new file mode" line) (plist-put file :status "added"))
   ((string-prefix-p "deleted file mode" line) (plist-put file :status "deleted"))
   ((string-prefix-p "rename from " line)
    (plist-put file :status "renamed")
    (plist-put file :from (agent-notes--unquote-path (substring line 12))))
   ((string-prefix-p "rename to " line)
    (plist-put file :path (agent-notes--unquote-path (substring line 10))))
   ((string-prefix-p "Binary files " line)
    (plist-put file :status (concat (plist-get file :status) ", binary")))
   ((string-prefix-p "+++ " line)
    (let ((path (agent-notes--unquote-path (substring line 4))))
      (unless (equal path "/dev/null")
        (plist-put file :path (agent-notes--strip-prefix path)))))))

(defun agent-notes--parse-diff (diff)
  "Parse the unified DIFF text into a list of line records.
Each record is a plist with :kind (`file', `hunk', `context',
`added', `removed' or `meta'), :text, :path and, for code lines,
:old and :new line numbers."
  (let (records file in-hunk (old 0) (new 0))
    (dolist (line (split-string diff "\n"))
      (cond
       ((string-prefix-p "diff --git " line)
        (setq in-hunk nil
              file (list :kind 'file :path (agent-notes--path-from-header line)
                         :status "modified" :from nil))
        (push file records))
       ((and file (string-match "\\`@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)\\(?:,[0-9]+\\)? @@"
                                line))
        (setq in-hunk t
              old (string-to-number (match-string 1 line))
              new (string-to-number (match-string 2 line)))
        (push (list :kind 'hunk :text line :path (plist-get file :path)) records))
       ((and in-hunk (> (length line) 0) (memq (aref line 0) '(?\s ?+ ?- ?\\)))
        (let ((path (plist-get file :path)))
          (pcase (aref line 0)
            (?\s (push (list :kind 'context :text line :path path :old old :new new) records)
                 (cl-incf old) (cl-incf new))
            (?- (push (list :kind 'removed :text line :path path :old old :new new) records)
                (cl-incf old))
            (?+ (push (list :kind 'added :text line :path path :old nil :new new) records)
                (cl-incf new))
            (_ (push (list :kind 'meta :text line :path path) records)))))
       ((and file (not in-hunk))
        (agent-notes--parse-file-meta file line))))
    (nreverse records)))

(defun agent-notes--loc-key (path side line)
  "Return the index key for LINE on SIDE of PATH."
  (format "%s\0%s\0%s" path side line))

(defun agent-notes--index-records (records)
  "Index the code lines in RECORDS by path, side and line number."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (rec records)
      (let ((path (plist-get rec :path)))
        (pcase (plist-get rec :kind)
          ('context
           (puthash (agent-notes--loc-key path "new" (plist-get rec :new)) rec index)
           (puthash (agent-notes--loc-key path "old" (plist-get rec :old)) rec index))
          ('added (puthash (agent-notes--loc-key path "new" (plist-get rec :new)) rec index))
          ('removed (puthash (agent-notes--loc-key path "old" (plist-get rec :old)) rec index)))))
    index))

(defun agent-notes--exact-record (note)
  "Return the diff record exactly matching NOTE's location, or nil."
  (gethash (agent-notes--loc-key (plist-get note :path) (plist-get note :side)
                                 (plist-get note :line))
           agent-notes--index))

(defun agent-notes--anchor-record (note)
  "Return the record NOTE should be displayed under, or nil.
Falls back to the nearest line of the same file, then to the file
header."
  (let ((path (plist-get note :path))
        (key (if (equal (plist-get note :side) "old") :old :new))
        (line (plist-get note :line)))
    (or (agent-notes--exact-record note)
        (let (best best-dist)
          (dolist (rec agent-notes--records)
            (let ((l (plist-get rec key)))
              (when (and l (equal (plist-get rec :path) path)
                         (memq (plist-get rec :kind) '(context added removed)))
                (let ((dist (abs (- l line))))
                  (when (or (null best) (< dist best-dist))
                    (setq best rec best-dist dist))))))
          best)
        (cl-find-if (lambda (rec) (and (eq (plist-get rec :kind) 'file)
                                       (equal (plist-get rec :path) path)))
                    agent-notes--records))))

;;;; Storage

(defun agent-notes--json-parse (string)
  "Parse the JSON STRING into plists and lists."
  (json-parse-string string :object-type 'plist :array-type 'list
                     :null-object nil :false-object nil))

(defun agent-notes--read-file (file)
  "Return the contents of FILE as a UTF-8 string."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (buffer-string)))

(defun agent-notes--write-file (file string)
  "Write STRING to FILE as UTF-8."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert string))))

(defun agent-notes--diff-file (file)
  "Return the diff snapshot file belonging to the review FILE."
  (concat (file-name-sans-extension file) ".diff"))

(defun agent-notes--serialize (review)
  "Return REVIEW as pretty-printed JSON."
  (let ((data (plist-put
               (copy-sequence review) :notes
               (vconcat (mapcar (lambda (note)
                                  (plist-put (copy-sequence note) :comments
                                             (vconcat (plist-get note :comments))))
                                (plist-get review :notes))))))
    (with-temp-buffer
      (insert (json-serialize data))
      (json-pretty-print-buffer)
      (buffer-string))))

(defun agent-notes--save ()
  "Save the review of the current buffer."
  (agent-notes--write-file agent-notes--file (agent-notes--serialize agent-notes--review)))

;;;; Model helpers

(defun agent-notes--now ()
  "Return the current time as an ISO 8601 string."
  (format-time-string "%FT%T%z"))

(defun agent-notes--uuid ()
  "Return a random UUID string."
  (let ((h (md5 (format "%S %s %s %s" (current-time) (emacs-pid) (random) (system-name)))))
    (format "%s-%s-4%s-%s%s-%s" (substring h 0 8) (substring h 8 12) (substring h 13 16)
            (nth (random 4) '("8" "9" "a" "b")) (substring h 17 20) (substring h 20 32))))

(defun agent-notes--as-int (value)
  "Coerce VALUE to an integer."
  (cond ((integerp value) value)
        ((numberp value) (truncate value))
        ((stringp value) (string-to-number value))
        (t 0)))

(defun agent-notes--notes ()
  "Return the notes of the current review."
  (plist-get agent-notes--review :notes))

(defun agent-notes--note (id)
  "Return the note with ID."
  (cl-find id (agent-notes--notes) :key (lambda (n) (plist-get n :id))))

(defun agent-notes--next (key)
  "Return the next value of the counter KEY and increment it."
  (let ((id (or (plist-get agent-notes--review key) 1)))
    (setq agent-notes--review (plist-put agent-notes--review key (1+ id)))
    id))

(defun agent-notes--make-comment (author body state)
  "Return a new comment by AUTHOR with BODY in STATE."
  (list :id (agent-notes--next :next_comment) :author author :body body
        :state state :time (agent-notes--now)))

(defun agent-notes--add-note (author path side line severity body state)
  "Add a note by AUTHOR at LINE on SIDE of PATH and return it."
  (let ((note (list :id (agent-notes--next :next_note) :author author :path path
                    :side side :line line :severity severity :status "open"
                    :comments (list (agent-notes--make-comment author body state)))))
    (setq agent-notes--review
          (plist-put agent-notes--review :notes
                     (append (agent-notes--notes) (list note))))
    note))

(defun agent-notes--resolved-p (note)
  "Return non-nil if NOTE is resolved."
  (equal (plist-get note :status) "resolved"))

(defun agent-notes--pending-p (comment)
  "Return non-nil if COMMENT has not been sent to the agent yet."
  (equal (plist-get comment :state) "pending"))

(defun agent-notes--editable-p (comment)
  "Return non-nil if COMMENT may still be edited or deleted."
  (and (equal (plist-get comment :author) "you")
       (agent-notes--pending-p comment)
       (not (memq (plist-get comment :id) agent-notes--in-flight))))

(defun agent-notes--pending-comments ()
  "Return the ids of all unsent comments that are not being sent."
  (cl-loop for note in (agent-notes--notes)
           append (cl-loop for c in (plist-get note :comments)
                           when (and (agent-notes--pending-p c)
                                     (not (memq (plist-get c :id) agent-notes--in-flight)))
                           collect (plist-get c :id))))

(defun agent-notes--known-path-p (path)
  "Return non-nil if PATH is a file in the diff."
  (cl-some (lambda (rec) (and (eq (plist-get rec :kind) 'file)
                              (equal (plist-get rec :path) path)))
           agent-notes--records))

(defun agent-notes--normalize-path (path)
  "Turn PATH, as written by the agent, into a path relative to the root."
  (let ((p (string-trim (if (stringp path) path ""))))
    (when (and (not (string-empty-p p)) (file-name-absolute-p p))
      (setq p (file-relative-name p (plist-get agent-notes--review :root))))
    (if (and (not (agent-notes--known-path-p p))
             (string-match "\\`\\(?:[ab]/\\|\\./\\)" p)
             (agent-notes--known-path-p (substring p (match-end 0))))
        (substring p (match-end 0))
      p)))

(defun agent-notes--scope-label (review)
  "Return a short description of REVIEW's scope."
  (if (equal (plist-get review :scope) "branch")
      (format "Branch vs %s" (plist-get review :base))
    "Working tree vs HEAD"))

(defun agent-notes--repo-name (review)
  "Return the name of REVIEW's repository."
  (file-name-nondirectory (directory-file-name (plist-get review :root))))

;;;; Rendering

(defun agent-notes--severity-face (severity)
  "Return the face for SEVERITY."
  (pcase severity
    ((or "issue" "bug" "error" "critical") 'error)
    ("warning" 'warning)
    ("question" 'font-lock-builtin-face)
    ("nit" 'shadow)
    (_ 'success)))

(defun agent-notes--author-face (author)
  "Return the face for AUTHOR."
  (if (equal author "agent") 'agent-notes-agent 'agent-notes-you))

(defun agent-notes--collapsed-p (note)
  "Return non-nil if NOTE is folded.  Resolved notes are folded by default."
  (let ((state (gethash (plist-get note :id) agent-notes--folded 'unset)))
    (if (eq state 'unset) (agent-notes--resolved-p note) state)))

(defun agent-notes--fontify-line (line in-fence base)
  "Return LINE of Markdown with faces; IN-FENCE means inside a code block.
BASE is the face for ordinary text."
  (if (or in-fence (string-prefix-p "```" (string-trim-left line)))
      (propertize line 'font-lock-face (list 'agent-notes-code base 'agent-notes-note))
    (let ((s (propertize line 'font-lock-face (list base 'agent-notes-note)))
          (start 0))
      (while (string-match "`[^`]+`\\|\\*\\*[^*]+\\*\\*" s start)
        (put-text-property (match-beginning 0) (match-end 0) 'font-lock-face
                           (list (if (eq (aref s (match-beginning 0)) ?`)
                                     'agent-notes-code
                                   'bold)
                                 base 'agent-notes-note)
                           s)
        (setq start (match-end 0)))
      s)))

(defun agent-notes--insert-note (note)
  "Insert NOTE as a block of text at point."
  (let* ((id (plist-get note :id))
         (start (point))
         (comments (plist-get note :comments))
         (resolved (agent-notes--resolved-p note))
         (collapsed (agent-notes--collapsed-p note))
         (base (if resolved 'agent-notes-resolved 'default))
         (severity (or (plist-get note :severity) ""))
         (unsent (cl-count-if #'agent-notes--pending-p comments)))
    (cl-flet ((ins (string &rest faces)
                (insert (propertize string 'font-lock-face
                                    (append faces '(agent-notes-note)))))
              (state-label (comment)
                (cond ((memq (plist-get comment :id) agent-notes--in-flight) "  sending…")
                      ((agent-notes--pending-p comment) "  unsent")
                      (t ""))))
      ;; Header line.
      (insert agent-notes--pad)
      (ins (if collapsed "▸ " "┌ ") 'agent-notes-border)
      (ins (format "#%d" id) 'bold base)
      (ins "  ")
      (ins (plist-get note :author) (agent-notes--author-face (plist-get note :author)))
      (unless (string-empty-p severity)
        (ins "  ")
        (ins severity (agent-notes--severity-face severity)))
      (ins "  ")
      (ins (if resolved "resolved" "open") base)
      (unless (agent-notes--exact-record note)
        (ins (format "  %s:%s (not in diff)" (plist-get note :path) (plist-get note :line))
             'shadow))
      (when (> unsent 0)
        (ins (format "  %d unsent" unsent) 'agent-notes-pending))
      (when collapsed
        (ins (format "  · %d comment%s · " (length comments)
                     (if (= (length comments) 1) "" "s"))
             'shadow)
        (ins (truncate-string-to-width
              (car (split-string (plist-get (car comments) :body) "\n"))
              60 nil nil "…")
             base))
      (ins "\n")
      (put-text-property start (point) 'agent-notes-header id)
      ;; Comments.
      (unless collapsed
        (let ((first t))
          (dolist (comment comments)
            (let ((cstart (point))
                  (indent (if first "" "  "))
                  (in-fence nil))
              (unless first
                (insert agent-notes--pad)
                (ins "│" 'agent-notes-border)
                (ins "\n")
                (insert agent-notes--pad)
                (ins "│ ↳ " 'agent-notes-border)
                (ins (plist-get comment :author)
                     (agent-notes--author-face (plist-get comment :author)))
                (ins (state-label comment) 'agent-notes-pending)
                (ins "\n"))
              (when (and first (memq (plist-get comment :id) agent-notes--in-flight))
                (insert agent-notes--pad)
                (ins "│ " 'agent-notes-border)
                (ins "(sending…)" 'agent-notes-pending)
                (ins "\n"))
              (dolist (line (split-string (plist-get comment :body) "\n"))
                (insert agent-notes--pad)
                (ins "│ " 'agent-notes-border)
                (ins indent)
                (insert (agent-notes--fontify-line line in-fence base))
                (ins "\n")
                (when (string-prefix-p "```" (string-trim-left line))
                  (setq in-fence (not in-fence))))
              (put-text-property cstart (point) 'agent-notes-comment (plist-get comment :id))
              (setq first nil))))
        (insert agent-notes--pad)
        (ins "└" 'agent-notes-border)
        (ins "\n"))
      (put-text-property start (point) 'agent-notes-note id)
      (put-text-property start (point) 'wrap-prefix
                         (concat agent-notes--pad
                                 (propertize "│   " 'face '(agent-notes-border agent-notes-note)))))))

(defun agent-notes--insert-record (rec)
  "Insert the diff line record REC at point."
  (let ((start (point))
        (kind (plist-get rec :kind))
        (text (plist-get rec :text)))
    (pcase kind
      ('file
       (insert "\n")
       (setq start (point))
       (insert (propertize
                (concat " " (plist-get rec :path)
                        (cond ((plist-get rec :from)
                               (format "  (renamed from %s)" (plist-get rec :from)))
                              ((equal (plist-get rec :status) "modified") "")
                              (t (format "  (%s)" (plist-get rec :status))))
                        "\n")
                'font-lock-face 'agent-notes-file-header))
       (put-text-property start (point) 'agent-notes-file (plist-get rec :path)))
      ('hunk
       (insert (propertize (concat text "\n") 'font-lock-face 'agent-notes-hunk-header)))
      ('meta
       (insert agent-notes--pad (propertize (concat text "\n") 'font-lock-face 'shadow)))
      (_
       (insert (propertize (format "%5s %5s " (or (and (not (eq kind 'added)) (plist-get rec :old)) "")
                                   (or (and (not (eq kind 'removed)) (plist-get rec :new)) ""))
                           'font-lock-face 'agent-notes-line-number))
       (insert (propertize (concat text "\n") 'font-lock-face
                           (pcase kind ('added 'diff-added) ('removed 'diff-removed)
                                  (_ 'diff-context))))))
    (put-text-property start (point) 'agent-notes-loc rec)
    (put-text-property start (point) 'wrap-prefix agent-notes--pad)))

(defun agent-notes--insert-header ()
  "Insert the title, summary and key hints."
  (let* ((review agent-notes--review)
         (summary (or (plist-get review :summary) ""))
         (base-rev (or (plist-get review :base_rev) ""))
         (start (point)))
    (insert (propertize (format "Agent Notes · %s\n" (agent-notes--repo-name review))
                        'font-lock-face 'agent-notes-title))
    (insert (propertize (format "%s (%s) · %s\n" (agent-notes--scope-label review)
                                (substring base-rev 0 (min 10 (length base-rev)))
                                (plist-get review :created))
                        'font-lock-face 'shadow))
    (insert "\n")
    (cond
     ((not (string-empty-p summary))
      (insert (propertize "Summary: " 'font-lock-face 'bold) summary "\n"))
     (agent-notes--status
      (insert (propertize "The agent is working; its notes will appear here when it is done.\n"
                          'font-lock-face 'agent-notes-pending)))
     ((null (agent-notes--notes))
      (insert "No notes yet. Press A to ask the agent for a review, "
              "or c on a line to add your own note.\n")))
    (insert (propertize
             (concat "n/p notes  N/P agent notes  {/} files  c new note  r reply  "
                     "e edit  k delete  R resolve  s send  TAB fold  l list  "
                     "RET visit  A review again  $ log  ? help\n")
             'font-lock-face 'shadow))
    (put-text-property start (point) 'wrap-prefix "  ")))

(defun agent-notes--point-anchor ()
  "Describe the position at point so it can be found after re-rendering."
  (list :comment (get-text-property (point) 'agent-notes-comment)
        :note (get-text-property (point) 'agent-notes-note)
        :rec (get-text-property (point) 'agent-notes-loc)
        :line (line-number-at-pos)
        :column (current-column)))

(defun agent-notes--find-prop (prop value)
  "Return the start of the first region whose PROP is VALUE."
  (save-excursion
    (goto-char (point-min))
    (let ((match (text-property-search-forward prop value #'eq)))
      (and match (prop-match-beginning match)))))

(defun agent-notes--anchor-position (anchor)
  "Return the position described by ANCHOR in the current rendering."
  (or (and (plist-get anchor :comment)
           (agent-notes--find-prop 'agent-notes-comment (plist-get anchor :comment)))
      (and (plist-get anchor :note)
           (agent-notes--find-prop 'agent-notes-header (plist-get anchor :note)))
      (let ((pos (and (plist-get anchor :rec)
                      (agent-notes--find-prop 'agent-notes-loc (plist-get anchor :rec)))))
        (and pos (save-excursion (goto-char pos)
                                 (move-to-column (plist-get anchor :column))
                                 (point))))
      (save-excursion (goto-char (point-min))
                      (forward-line (1- (plist-get anchor :line)))
                      (point))))

(defun agent-notes--render ()
  "Redraw the review buffer, keeping point on the same thing."
  (let* ((win (get-buffer-window (current-buffer) t))
         (pos (if win (window-point win) (point)))
         (anchor (save-excursion (goto-char pos) (agent-notes--point-anchor)))
         (offset (and win (count-lines (window-start win) pos)))
         (inhibit-read-only t)
         (by-record (make-hash-table :test #'eq))
         (general nil))
    (setq agent-notes--placement (make-hash-table))
    (dolist (note (agent-notes--notes))
      (let ((rec (agent-notes--anchor-record note)))
        (if rec
            (progn (push note (gethash rec by-record))
                   (puthash (plist-get note :id) rec agent-notes--placement))
          (push note general))))
    (erase-buffer)
    (agent-notes--insert-header)
    (when general
      (insert "\n" (propertize " General notes\n" 'font-lock-face 'agent-notes-file-header))
      (mapc #'agent-notes--insert-note (nreverse general)))
    (dolist (rec agent-notes--records)
      (agent-notes--insert-record rec)
      (mapc #'agent-notes--insert-note (reverse (gethash rec by-record))))
    (let ((new-pos (agent-notes--anchor-position anchor)))
      (goto-char new-pos)
      (when win
        (set-window-point win new-pos)
        (set-window-start win (save-excursion (forward-line (- offset)) (point)) t)))
    (force-mode-line-update)))

(defun agent-notes--header-line ()
  "Return the header line of the review buffer."
  (when agent-notes--review
    (let* ((notes (agent-notes--notes))
           (resolved (cl-count-if #'agent-notes--resolved-p notes))
           (unsent (length (agent-notes--pending-comments))))
      (concat " " (agent-notes--scope-label agent-notes--review)
              (format "  ·  %d open, %d resolved" (- (length notes) resolved) resolved)
              (if (> unsent 0)
                  (propertize (format "  ·  %d unsent (s to send)" unsent)
                              'face 'agent-notes-pending)
                "")
              "  ·  Agent: "
              (if agent-notes--status
                  (propertize agent-notes--status 'face 'agent-notes-pending)
                "idle")))))

;;;; Buffers

(defun agent-notes--buffer-for (file)
  "Return the live review buffer showing FILE, or nil."
  (cl-find-if (lambda (buf) (equal (buffer-local-value 'agent-notes--file buf) file))
              (buffer-list)))

(defun agent-notes--reload ()
  "Load the review of the current buffer from disk and redraw it."
  (setq agent-notes--review (agent-notes--json-parse (agent-notes--read-file agent-notes--file)))
  (setq agent-notes--records (agent-notes--parse-diff
                              (agent-notes--read-file (agent-notes--diff-file agent-notes--file))))
  (setq agent-notes--index (agent-notes--index-records agent-notes--records))
  (setq default-directory (plist-get agent-notes--review :root))
  (agent-notes--render))

(defun agent-notes--revert (&rest _)
  "Reload the review from disk."
  (agent-notes--reload))

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

(defun agent-notes--ensure-idle ()
  "Signal an error if the agent is working."
  (when (process-live-p agent-notes--process)
    (user-error "The agent is still working (C-c C-k to abort)")))

;;;; Agent

(defun agent-notes--log (format-string &rest args)
  "Append a message built from FORMAT-STRING and ARGS to the log buffer."
  (with-current-buffer (get-buffer-create agent-notes--log-buffer)
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format-time-string "\n[%F %T] ") (apply #'format format-string args) "\n"))))

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

(defconst agent-notes--note-spec
  "Each note is anchored to one line of the diff:
- \"path\": file path relative to the repository root, without a/ or b/ prefixes.
- \"side\": \"new\" for added (+) or unchanged context lines, with the line number in the new version of the file; \"old\" for removed (-) lines, with the line number in the old version.
- \"line\": the line number, as an integer.
- \"severity\": one of \"issue\", \"warning\", \"suggestion\", \"question\", \"nit\".
- \"body\": the note in Markdown. Be specific and concise; propose a fix when you have one."
  "Description of the note format given to the agent.")

(defun agent-notes--context-prompt ()
  "Return the part of the prompt describing the review."
  (let* ((review agent-notes--review)
         (base-rev (plist-get review :base_rev)))
    (concat
     "Repository: " (plist-get review :root) "\n"
     "Scope: "
     (if (equal (plist-get review :scope) "branch")
         (format "all changes on the current branch since it diverged from %s (merge-base %s)%s"
                 (plist-get review :base) base-rev
                 (if agent-notes-branch-include-uncommitted
                     ", including uncommitted and untracked files" ""))
       (format "uncommitted changes (staged, unstaged and untracked files) compared to HEAD (%s)"
               base-rev))
     ".\nThe exact unified diff under review is saved at:\n  "
     (agent-notes--diff-file agent-notes--file) "\n"
     "You may read any file in the repository and run read-only git commands for context. "
     "Do NOT modify, create or delete files, and do not run commands that change the repository.\n")))

(defun agent-notes--review-prompt ()
  "Return the prompt asking the agent to review the diff."
  (concat
   "You are a meticulous senior engineer reviewing code changes.\n"
   (agent-notes--context-prompt)
   "\nRead the diff file first. Look for bugs, incorrect logic, unhandled edge cases, "
   "security problems, poor error handling, performance issues, unclear code and missing tests. "
   "Prefer a few high-signal notes over many trivial ones, and do not leave notes that only praise.\n"
   (if agent-notes-review-instructions
       (concat "\nAdditional instructions from the user:\n" agent-notes-review-instructions "\n")
     "")
   "\n" agent-notes--note-spec "\n\n"
   "Your final message must end with exactly one fenced ```json code block and nothing after it, "
   "with this shape:\n"
   "```json\n"
   "{\"summary\": \"Two or three sentences about the change as a whole.\",\n"
   " \"notes\": [{\"path\": \"src/example.py\", \"line\": 42, \"side\": \"new\", "
   "\"severity\": \"warning\", \"body\": \"...\"}]}\n"
   "```\n"))

(defun agent-notes--format-thread (note new-ids)
  "Return NOTE as text for the agent; comments in NEW-IDS are marked NEW."
  (let ((rec (agent-notes--exact-record note)))
    (concat
     (format "--- Thread #%d · %s · %s line %s · started by %s%s · status: %s\n"
             (plist-get note :id) (plist-get note :path) (plist-get note :side)
             (plist-get note :line)
             (if (equal (plist-get note :author) "agent") "you (the agent)" "the user")
             (let ((s (plist-get note :severity)))
               (if (and s (not (string-empty-p s))) (format " · severity: %s" s) ""))
             (plist-get note :status))
     (if rec (format "Diff line: %s\n" (plist-get rec :text)) "")
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
   "The user has read the code review and responded.\n"
   (agent-notes--context-prompt)
   "The code has not changed since the review.\n\n"
   "Below are the review threads that have new messages from the user (marked NEW). "
   "Threads started by the user are new comments or questions for you. "
   "Answer every thread that has NEW messages. Be direct and concise; if the user is right, say so. "
   "Set \"resolve\" to true only when the thread's concern is settled. "
   "If the discussion reveals other problems, you may add new notes.\n\n"
   (mapconcat (lambda (note) (agent-notes--format-thread note new-ids)) notes "")
   agent-notes--note-spec "\n\n"
   "Your final message must end with exactly one fenced ```json code block and nothing after it, "
   "with this shape:\n"
   "```json\n"
   "{\"replies\": [{\"note\": 3, \"body\": \"...\", \"resolve\": false}],\n"
   " \"notes\": []}\n"
   "```\n"))

(defun agent-notes--add-agent-note (spec)
  "Add the note described by the agent's JSON SPEC."
  (let ((body (plist-get spec :body))
        (severity (plist-get spec :severity)))
    (when (and (stringp body) (not (string-blank-p body)))
      (agent-notes--add-note "agent"
                             (agent-notes--normalize-path (plist-get spec :path))
                             (if (equal (plist-get spec :side) "old") "old" "new")
                             (agent-notes--as-int (plist-get spec :line))
                             (if (stringp severity) severity "suggestion")
                             body "sent"))))

(defun agent-notes--apply-review (data _in-flight)
  "Store the review DATA returned by the agent."
  (unless (or (plist-member data :notes) (plist-member data :summary))
    (error "The agent's answer has no \"notes\""))
  (let ((summary (plist-get data :summary)))
    (when (and (stringp summary) (not (string-blank-p summary)))
      (setq agent-notes--review (plist-put agent-notes--review :summary summary))))
  (mapc #'agent-notes--add-agent-note (plist-get data :notes)))

(defun agent-notes--apply-replies (data in-flight)
  "Store the agent's reply DATA to the comments IN-FLIGHT."
  (unless (or (plist-member data :replies) (plist-member data :notes))
    (error "The agent's answer has no \"replies\""))
  (dolist (note (agent-notes--notes))
    (dolist (comment (plist-get note :comments))
      (when (memq (plist-get comment :id) in-flight)
        (plist-put comment :state "sent"))))
  (dolist (reply (plist-get data :replies))
    (let ((note (agent-notes--note (agent-notes--as-int (plist-get reply :note))))
          (body (plist-get reply :body)))
      (if (not note)
          (agent-notes--log "Ignoring reply to unknown note: %S" reply)
        (when (and (stringp body) (not (string-blank-p body)))
          (plist-put note :comments
                     (append (plist-get note :comments)
                             (list (agent-notes--make-comment "agent" body "sent")))))
        (when (plist-get reply :resolve)
          (plist-put note :status "resolved")))))
  (mapc #'agent-notes--add-agent-note (plist-get data :notes)))

(defun agent-notes--run (label prompt on-success &optional in-flight)
  "Run Copilot with PROMPT in the review session.
LABEL describes the request.  On success, call ON-SUCCESS with the
parsed JSON answer and IN-FLIGHT, the ids of the comments sent."
  (unless (executable-find agent-notes-copilot-program)
    (user-error "Cannot find `%s'; customize `agent-notes-copilot-program'"
                agent-notes-copilot-program))
  (let* ((file agent-notes--file)
         (default-directory (plist-get agent-notes--review :root))
         (args (append (list "-s" "--session-id" (plist-get agent-notes--review :session)
                             (concat "--add-dir=" (file-name-directory file)))
                       (mapcar (lambda (tool) (concat "--allow-tool=" tool))
                               agent-notes-allowed-tools)
                       (mapcar (lambda (tool) (concat "--deny-tool=" tool))
                               agent-notes-denied-tools)
                       agent-notes-copilot-extra-args
                       (list "-p" prompt))))
    (agent-notes--log "%s: %s %s\n%s" label agent-notes-copilot-program
                      (mapconcat #'shell-quote-argument (butlast args 2) " ")
                      prompt)
    (setq agent-notes--in-flight in-flight
          agent-notes--status (concat label "…")
          agent-notes--process
          (make-process
           :name "agent-notes"
           :buffer (generate-new-buffer " *agent-notes-output*")
           :command (cons agent-notes-copilot-program args)
           :connection-type 'pipe
           :coding 'utf-8
           :noquery t
           :sentinel (lambda (proc _event)
                       (agent-notes--sentinel proc file label on-success in-flight))))
    (agent-notes--render)))

(defun agent-notes--sentinel (proc file label on-success in-flight)
  "Handle the end of the Copilot PROC for the review FILE.
LABEL, ON-SUCCESS and IN-FLIGHT are as in `agent-notes--run'."
  (when (memq (process-status proc) '(exit signal))
    (let ((output (with-current-buffer (process-buffer proc) (buffer-string)))
          (code (process-exit-status proc))
          (ok (and (eq (process-status proc) 'exit) (zerop (process-exit-status proc)))))
      (kill-buffer (process-buffer proc))
      (agent-notes--log "%s finished (exit code %s):\n%s" label code output)
      (with-current-buffer (agent-notes--get-buffer file)
        (setq agent-notes--process nil
              agent-notes--status nil
              agent-notes--in-flight nil)
        (condition-case err
            (progn
              (unless ok (error "Copilot exited with code %s" code))
              (funcall on-success (agent-notes--extract-json output) in-flight)
              (agent-notes--save)
              (message "Agent Notes: %s done" label))
          (error (message "Agent Notes: %s failed: %s (press $ for the log)"
                          label (error-message-string err))))
        (agent-notes--render)))))

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

;;;; Commands

(defun agent-notes--note-at-point ()
  "Return the note at point, or the first note below the current line."
  (let ((id (or (get-text-property (point) 'agent-notes-note)
                (save-excursion
                  (forward-line 1)
                  (get-text-property (point) 'agent-notes-note)))))
    (and id (agent-notes--note id))))

(defun agent-notes--require-note ()
  "Return the note at point or signal an error."
  (or (agent-notes--note-at-point) (user-error "No note at point")))

(defun agent-notes--goto-note (id &optional comment-id)
  "Move point to the note ID, or to its comment COMMENT-ID."
  (let ((pos (or (and comment-id (agent-notes--find-prop 'agent-notes-comment comment-id))
                 (agent-notes--find-prop 'agent-notes-header id))))
    (when pos
      (goto-char pos)
      (let ((win (get-buffer-window (current-buffer))))
        (when win (set-window-point win pos))))))

(defun agent-notes--prop-starts (prop)
  "Return (POS . VALUE) for the start of every region with a non-nil PROP."
  (let ((pos (point-min)) result)
    (while (< pos (point-max))
      (let ((value (get-text-property pos prop)))
        (when value (push (cons pos value) result)))
      (setq pos (or (next-single-property-change pos prop) (point-max))))
    (nreverse result)))

(defun agent-notes--jump (prop forward &optional pred what)
  "Move to the next region with PROP; backward unless FORWARD.
PRED filters the values of PROP.  WHAT names the targets in messages."
  (let* ((targets (cl-remove-if-not (lambda (target) (or (null pred) (funcall pred (cdr target))))
                                    (agent-notes--prop-starts prop)))
         (bol (line-beginning-position))
         (eol (line-end-position))
         (target (if forward
                     (cl-find-if (lambda (target) (> (car target) eol)) targets)
                   (cl-find-if (lambda (target) (< (car target) bol)) (reverse targets)))))
    (unless targets (user-error "No %s" (or what "targets")))
    (unless target
      (setq target (if forward (car targets) (car (last targets))))
      (message "Wrapped around"))
    (goto-char (car target))
    (when (eq prop 'agent-notes-header)
      (message "Note #%d (%d of %d)" (cdr target)
               (1+ (cl-position target targets)) (length targets)))))

(defun agent-notes--agent-note-p (id)
  "Return non-nil if the note ID was written by the agent."
  (equal (plist-get (agent-notes--note id) :author) "agent"))

(defun agent-notes-next-note ()
  "Move to the next note."
  (interactive)
  (agent-notes--jump 'agent-notes-header t nil "notes"))

(defun agent-notes-previous-note ()
  "Move to the previous note."
  (interactive)
  (agent-notes--jump 'agent-notes-header nil nil "notes"))

(defun agent-notes-next-agent-note ()
  "Move to the next note written by the agent."
  (interactive)
  (agent-notes--jump 'agent-notes-header t #'agent-notes--agent-note-p "agent notes"))

(defun agent-notes-previous-agent-note ()
  "Move to the previous note written by the agent."
  (interactive)
  (agent-notes--jump 'agent-notes-header nil #'agent-notes--agent-note-p "agent notes"))

(defun agent-notes-next-file ()
  "Move to the next file."
  (interactive)
  (agent-notes--jump 'agent-notes-file t nil "files"))

(defun agent-notes-previous-file ()
  "Move to the previous file."
  (interactive)
  (agent-notes--jump 'agent-notes-file nil nil "files"))

(defun agent-notes-new-note ()
  "Write a new note on the line of code at point."
  (interactive)
  (let ((rec (get-text-property (point) 'agent-notes-loc)))
    (unless (and rec (memq (plist-get rec :kind) '(context added removed))
                 (not (get-text-property (point) 'agent-notes-note)))
      (user-error "Move point to a line of code in the diff"))
    (let* ((side (if (eq (plist-get rec :kind) 'removed) "old" "new"))
           (line (plist-get rec (if (equal side "old") :old :new)))
           (path (plist-get rec :path)))
      (agent-notes--compose
       (format "New note on %s:%d" path line) nil
       (lambda (body)
         (let ((note (agent-notes--add-note "you" path side line "" body "pending")))
           (agent-notes--save)
           (agent-notes--render)
           (agent-notes--goto-note (plist-get note :id))))))))

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
         (puthash id nil agent-notes--folded)
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
  "Resolve the note at point, or reopen it if it is resolved."
  (interactive)
  (let ((note (agent-notes--require-note)))
    (plist-put note :status (if (agent-notes--resolved-p note) "open" "resolved"))
    (remhash (plist-get note :id) agent-notes--folded)
    (agent-notes--save)
    (agent-notes--render)
    (message "Note #%d %s" (plist-get note :id) (plist-get note :status))))

(defun agent-notes-toggle-fold ()
  "Fold or unfold the note at point."
  (interactive)
  (let ((note (agent-notes--require-note)))
    (puthash (plist-get note :id) (not (agent-notes--collapsed-p note)) agent-notes--folded)
    (agent-notes--render)))

(defun agent-notes--describe-note (note)
  "Return a one-line description of NOTE."
  (format "#%-3d %-6s %-10s %-8s %s:%s  %s"
          (plist-get note :id) (plist-get note :author)
          (or (plist-get note :severity) "") (plist-get note :status)
          (plist-get note :path) (plist-get note :line)
          (truncate-string-to-width
           (car (split-string (plist-get (car (plist-get note :comments)) :body) "\n"))
           60 nil nil "…")))

(defun agent-notes-list ()
  "Jump to a note chosen from a list."
  (interactive)
  (let* ((candidates (mapcar (lambda (note) (cons (agent-notes--describe-note note)
                                                  (plist-get note :id)))
                             (agent-notes--notes)))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity))
                    (complete-with-action action candidates string pred)))))
    (unless candidates (user-error "No notes"))
    (agent-notes--goto-note (cdr (assoc (completing-read "Note: " table nil t) candidates)))))

(defun agent-notes-visit ()
  "Open the file of the line or note at point, read-only."
  (interactive)
  (let* ((note (and (get-text-property (point) 'agent-notes-note) (agent-notes--note-at-point)))
         (rec (if note
                  (gethash (plist-get note :id) agent-notes--placement)
                (get-text-property (point) 'agent-notes-loc)))
         (path (or (plist-get note :path) (plist-get rec :path)))
         (line (cond ((and note (equal (plist-get note :side) "new")) (plist-get note :line))
                     (rec (plist-get rec :new))))
         (file (and path (expand-file-name path (plist-get agent-notes--review :root)))))
    (unless file (user-error "Nothing to visit here"))
    (unless (file-exists-p file) (user-error "%s does not exist in the working tree" path))
    (find-file-read-only-other-window file)
    (when (and line (> line 0))
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun agent-notes-send ()
  "Send all your unsent comments to the agent and wait for its answers."
  (interactive)
  (agent-notes--ensure-idle)
  (let* ((ids (agent-notes--pending-comments))
         (notes (cl-remove-if-not
                 (lambda (note) (cl-some (lambda (c) (memq (plist-get c :id) ids))
                                         (plist-get note :comments)))
                 (agent-notes--notes))))
    (unless ids (user-error "Nothing to send"))
    (when (y-or-n-p (format "Send %d comment%s in %d thread%s to the agent? "
                            (length ids) (if (= (length ids) 1) "" "s")
                            (length notes) (if (= (length notes) 1) "" "s")))
      (agent-notes--run "replying" (agent-notes--reply-prompt notes ids)
                        #'agent-notes--apply-replies ids))))

(defun agent-notes-request-review ()
  "Ask the agent to review the diff.  New notes are added to existing ones."
  (interactive)
  (agent-notes--ensure-idle)
  (when (or (null (agent-notes--notes))
            (y-or-n-p "Ask the agent to review again? New notes will be added. "))
    (agent-notes--run "reviewing" (agent-notes--review-prompt) #'agent-notes--apply-review)))

(defun agent-notes-abort ()
  "Stop the running agent request."
  (interactive)
  (if (process-live-p agent-notes--process)
      (kill-process agent-notes--process)
    (user-error "The agent is not running")))

(defun agent-notes-show-log ()
  "Show the log of requests sent to the agent and its raw answers."
  (interactive)
  (let ((buf (get-buffer-create agent-notes--log-buffer)))
    (with-current-buffer buf (goto-char (point-max)))
    (display-buffer buf)))

;;;; Mode

(defvar-keymap agent-notes-mode-map
  :parent special-mode-map
  "n" #'agent-notes-next-note
  "p" #'agent-notes-previous-note
  "N" #'agent-notes-next-agent-note
  "P" #'agent-notes-previous-agent-note
  "}" #'agent-notes-next-file
  "{" #'agent-notes-previous-file
  "c" #'agent-notes-new-note
  "r" #'agent-notes-reply
  "e" #'agent-notes-edit
  "k" #'agent-notes-delete
  "R" #'agent-notes-toggle-resolved
  "s" #'agent-notes-send
  "TAB" #'agent-notes-toggle-fold
  "l" #'agent-notes-list
  "RET" #'agent-notes-visit
  "A" #'agent-notes-request-review
  "$" #'agent-notes-show-log
  "C-c C-k" #'agent-notes-abort)

(define-derived-mode agent-notes-mode special-mode "Agent-Notes"
  "Major mode for reviewing a diff together with an AI agent.

Your notes and replies are queued as \"unsent\" until you send them
all with \\[agent-notes-send].

\\{agent-notes-mode-map}"
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local revert-buffer-function #'agent-notes--revert)
  (setq-local header-line-format '(:eval (agent-notes--header-line)))
  (setq agent-notes--folded (make-hash-table)))

;;;; Entry points

(defun agent-notes--read-scope ()
  "Read the scope of a new review; return (SCOPE BASE)."
  (let* ((working "Working tree: uncommitted changes vs HEAD")
         (choice (completing-read "Review: "
                                  (list working "Branch: all changes since a base branch")
                                  nil t nil nil working)))
    (if (equal choice working)
        (list "working" nil)
      (let ((default (agent-notes--default-base)))
        (list "branch"
              (completing-read (format-prompt "Base branch" default)
                               (agent-notes--branches) nil nil nil nil default))))))

;;;###autoload
(defun agent-notes-review (scope &optional base)
  "Snapshot the changes in SCOPE and ask the agent to review them.
SCOPE is \"working\" for uncommitted changes against HEAD, or
\"branch\" for everything since the current branch forked from BASE."
  (interactive (let ((default-directory (agent-notes--root)))
                 (agent-notes--read-scope)))
  (let* ((default-directory (agent-notes--root))
         (root default-directory))
    (pcase-let ((`(,diff ,base-label ,base-rev ,head) (agent-notes--make-diff scope base)))
      (when (string-blank-p diff)
        (user-error "No changes to review"))
      (let* ((id (format-time-string "%Y%m%d-%H%M%S"))
             (dir (agent-notes--directory))
             (file (expand-file-name (concat id ".json") dir))
             (review (list :version 1 :id id :root root :scope scope
                           :base base-label :base_rev base-rev :head_rev head
                           :created (format-time-string "%F %R")
                           :session (agent-notes--uuid) :summary ""
                           :next_note 1 :next_comment 1 :notes nil)))
        (make-directory dir t)
        (agent-notes--write-file (agent-notes--diff-file file) diff)
        (agent-notes--write-file file (agent-notes--serialize review))
        (let ((buf (agent-notes--get-buffer file)))
          (pop-to-buffer-same-window buf)
          (with-current-buffer buf
            (agent-notes--run "reviewing" (agent-notes--review-prompt)
                              #'agent-notes--apply-review)))))))

;;;###autoload
(defun agent-notes-open ()
  "Open a previous review of the current repository."
  (interactive)
  (let* ((default-directory (agent-notes--root))
         (dir (agent-notes--directory))
         (files (and (file-directory-p dir)
                     (reverse (directory-files dir t "\\.json\\'"))))
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
                  files))
         (table (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity))
                    (complete-with-action action candidates string pred)))))
    (unless candidates (user-error "No reviews yet; use M-x agent-notes-review"))
    (pop-to-buffer-same-window
     (agent-notes--get-buffer (cdr (assoc (completing-read "Open review: " table nil t)
                                          candidates))))))

(provide 'agent-notes)
;;; agent-notes.el ends here
