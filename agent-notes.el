;;; agent-notes.el --- Review git changes with an AI agent using inline notes -*- lexical-binding: t; -*-

;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1") (magit-section "4.0") (transient "0.7"))
;; Keywords: tools, vc, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Agent Notes lets you go through the changes in a git repository
;; together with an AI agent (GitHub Copilot CLI), using notes attached
;; to lines of a read-only diff.
;;
;; - M-x agent-notes-review   Snapshot the working tree (or the current
;;                            branch vs. a base branch) and give the
;;                            agent a task: a bug review, an overview of
;;                            the important changes, or your own
;;                            instructions.  Its notes appear inline.
;; - M-x agent-notes-open     Reopen a previous review.
;; - M-x agent-notes-menu     All of the above in a menu.  In Magit it is
;;                            on `@', and in `magit-dispatch'.
;;
;; The review buffer is built on `magit-section': files, hunks and
;; notes fold with TAB, and the diff can be shown unified or side by
;; side (`v').  You can navigate between notes, add your own notes,
;; reply to the agent, edit or delete your unsent comments and resolve
;; threads.  Your comments are queued; press `s' to send all of them to
;; the agent in one go.  The agent answers in the same Copilot session,
;; so it remembers the review.  When you ask it to change code, it
;; edits the files and the diff is refreshed, with the notes moving
;; along with the code.  Press `?' for all commands.
;;
;; Reviews live in .git/agent-notes/ and are never committed.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'subr-x)
(require 'diff-mode)
(require 'json)
(require 'text-property-search)
(require 'magit-section)
(require 'transient)

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

(defcustom agent-notes-allow-edits t
  "When non-nil, the agent may edit files in the repository.
It is told to change code only when you ask for it in a comment.
After each request the diff is checked for changes; see
`agent-notes-auto-refresh'.  When nil, file writes are denied and
the agent describes changes instead of making them."
  :type 'boolean)

(defcustom agent-notes-allowed-tools
  '("shell(git diff)" "shell(git log)" "shell(git show)" "shell(git blame)"
    "shell(git status)" "shell(git grep)" "shell(git ls-files)"
    "shell(rg)" "shell(grep)" "shell(ls)" "shell(cat)" "shell(head)"
    "shell(tail)" "shell(wc)")
  "Copilot permission patterns the agent may use without asking.
Each entry is passed as --allow-tool.  File writes are controlled
separately by `agent-notes-allow-edits'."
  :type '(repeat string))

(defcustom agent-notes-denied-tools nil
  "Copilot permission patterns the agent is never allowed to use.
Each entry is passed as --deny-tool.  \"write\" is added or removed
according to `agent-notes-allow-edits'."
  :type '(repeat string))

(defcustom agent-notes-auto-refresh t
  "When non-nil, refresh the diff after the agent changes files.
The notes are moved to the lines that now hold their code.  When
nil, only report the changes; refresh with \\[agent-notes-refresh]."
  :type 'boolean)

(defcustom agent-notes-base-branch nil
  "Default base branch for branch reviews.
When nil, use origin/HEAD, then main or master."
  :type '(choice (const :tag "Auto-detect" nil) string))

(defcustom agent-notes-branch-include-uncommitted t
  "When non-nil, branch reviews also include uncommitted changes."
  :type 'boolean)

(defcustom agent-notes-default-view 'unified
  "How the diff is shown in new review buffers."
  :type '(choice (const :tag "Unified" unified)
                 (const :tag "Side by side" split)))

(defcustom agent-notes-tasks
  '(("Review" . "You are a meticulous senior engineer reviewing these changes. \
Look for bugs, incorrect logic, unhandled edge cases, security problems, \
poor error handling, performance issues, unclear code and missing tests. \
Prefer a few high-signal notes over many trivial ones, and do not leave \
notes that only praise.  In the summary, give your overall assessment in \
two or three sentences.")
    ("Overview" . "Help the user understand these changes quickly.  Focus \
only on the most important parts; skip boilerplate, formatting, renames and \
other mechanical edits.  In the summary, explain what changed and why, in \
the order the user should read it (a short paragraph or a few bullet \
points).  Then leave about 3 to 8 notes with severity \"info\" on the key \
lines, each explaining what that part does and how it fits into the whole.  \
Do not hunt for bugs, but mention anything that is clearly broken."))
  "Tasks you can give the agent, as an alist of (NAME . INSTRUCTIONS).
When starting a review or pressing \\<agent-notes-mode-map>\\[agent-notes-request-review], you choose a task by
NAME, or type your own instructions instead.  The agent always
receives the context of the review (repository, scope, diff) and
the format for notes; INSTRUCTIONS say what to do with them."
  :type '(alist :key-type (string :tag "Name")
                :value-type (string :tag "Instructions")))

(define-obsolete-variable-alias 'agent-notes-review-instructions
  'agent-notes-extra-instructions "0.2.0")

(defcustom agent-notes-extra-instructions nil
  "Extra instructions added to every task, or nil.
For example, the conventions of your project."
  :type '(choice (const :tag "None" nil) string))

(defcustom agent-notes-magit-status-section t
  "When non-nil, show the latest review in the Magit status buffer."
  :type 'boolean)

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
  "Face for the frame drawn around notes and between diff columns.")

(defface agent-notes-agent '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the agent's name.")

(defface agent-notes-you '((t :inherit font-lock-string-face :weight bold))
  "Face for your name.")

(defface agent-notes-pending '((t :inherit warning :slant italic :weight normal))
  "Face for unsent comments and work in progress.")

(defface agent-notes-resolved '((t :inherit shadow))
  "Face for resolved notes.")

(defface agent-notes-info '((t :inherit font-lock-function-name-face))
  "Face for the severity \"info\", used for explanations.")

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

(defface agent-notes-added '((t :inherit diff-added))
  "Face for added lines.")

(defface agent-notes-removed '((t :inherit diff-removed))
  "Face for removed lines.")

(defface agent-notes-context '((t :inherit diff-context))
  "Face for unchanged lines.")

;;;; Internal state

(defconst agent-notes--empty-tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  "Git's empty tree, used as the base when the repository has no commits.")

(defconst agent-notes--log-buffer "*agent-notes-log*")

(defvar-local agent-notes--file nil "JSON file of the review in this buffer.")
(defvar-local agent-notes--review nil "The review plist.")
(defvar-local agent-notes--records nil "Parsed diff line records.")
(defvar-local agent-notes--index nil "Map from location key to diff record.")
(defvar-local agent-notes--placement nil "Map from note id to the record it is shown under.")
(defvar-local agent-notes--process nil "Running Copilot process, if any.")
(defvar-local agent-notes--status nil "What the agent is doing, or nil when idle.")
(defvar-local agent-notes--in-flight nil "Ids of comments currently being sent.")
(defvar-local agent-notes--changes nil "Files the agent changed in its last request.")
(defvar-local agent-notes--view 'unified "Either `unified' or `split' (side by side).")
(defvar-local agent-notes--width nil "Window width the buffer was last rendered for.")
(defvar-local agent-notes--half 80 "Width of each column in the side-by-side view.")
(defvar-local agent-notes--gutter 5 "Width of the line-number gutter in the side-by-side view.")
(defvar-local agent-notes--pad (make-string 12 ?\s) "Indentation of notes.")

(defvar agent-notes--task-history nil "History of tasks given to the agent.")

;; Introduced in magit-section 4.3.6.
(defvar magit-section-highlight-current)

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

(declare-function magit-gitdir "magit-git" (&optional directory common))

(defun agent-notes--directory ()
  "Return the directory that stores reviews for the current repository."
  (expand-file-name agent-notes-directory-name
                    (or (and (fboundp 'magit-gitdir) (ignore-errors (magit-gitdir)))
                        (agent-notes--git-try "rev-parse" "--absolute-git-dir")
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

(defun agent-notes--snapshot-diff (review)
  "Return (DIFF BASE-LABEL BASE-REV HEAD-REV) for the scope of REVIEW, now."
  (let ((default-directory (plist-get review :root)))
    (agent-notes--make-diff (plist-get review :scope) (plist-get review :base))))

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
`added', `removed' or `meta'), :text, :path and, for code lines
and hunks, :old and :new line numbers."
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
        (push (list :kind 'hunk :text line :path (plist-get file :path) :old old :new new)
              records))
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

(defun agent-notes--code-p (rec)
  "Return non-nil if REC is a line of code."
  (memq (plist-get rec :kind) '(context added removed)))

(defun agent-notes--content (rec)
  "Return the code of the line REC, without the diff prefix."
  (substring (plist-get rec :text) 1))

(defun agent-notes--rec-side (rec &optional context-side)
  "Return the side of REC: \"old\" or \"new\".
Context lines are on both sides; return CONTEXT-SIDE or \"new\"."
  (pcase (plist-get rec :kind)
    ('removed "old")
    ('added "new")
    (_ (or context-side "new"))))

(defun agent-notes--rec-line (rec side)
  "Return the line number of REC on SIDE."
  (plist-get rec (if (equal side "old") :old :new)))

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

(defun agent-notes--file-tree (records)
  "Group RECORDS into a list of (FILE-REC . HUNKS).
Each element of HUNKS is (HUNK-REC . LINE-RECS)."
  (let (files)
    (dolist (rec records)
      (pcase (plist-get rec :kind)
        ('file (push (list rec) files))
        ('hunk (when files
                 (setcdr (car files) (cons (list rec) (cdr (car files))))))
        (_ (let ((hunk (cadr (car files))))
             (when hunk (setcdr hunk (cons rec (cdr hunk))))))))
    (mapcar (lambda (file)
              (cons (car file)
                    (mapcar (lambda (hunk) (cons (car hunk) (reverse (cdr hunk))))
                            (reverse (cdr file)))))
            (nreverse files))))

(defun agent-notes--fingerprints (diff)
  "Return an alist (PATH . MD5) with a hash of each file's part of DIFF."
  (mapcar (lambda (chunk)
            (let ((chunk (concat "diff --git " chunk)))
              (cons (plist-get (car (agent-notes--parse-diff chunk)) :path) (md5 chunk))))
          (split-string diff "^diff --git " t)))

(defun agent-notes--exact-record (note)
  "Return the diff record exactly matching NOTE's location, or nil."
  (gethash (agent-notes--loc-key (plist-get note :path) (plist-get note :side)
                                 (plist-get note :line))
           agent-notes--index))

(defun agent-notes--anchor-record (note)
  "Return the record NOTE should be displayed under, or nil.
Falls back to the nearest line of the same file, then to the file
header.  Notes without a file are not anchored."
  (let ((path (plist-get note :path))
        (key (if (equal (plist-get note :side) "old") :old :new))
        (line (plist-get note :line)))
    (and (not (string-empty-p path))
         (or (agent-notes--exact-record note)
             (let (best best-dist)
               (dolist (rec agent-notes--records)
                 (let ((l (plist-get rec key)))
                   (when (and l (equal (plist-get rec :path) path) (agent-notes--code-p rec))
                     (let ((dist (abs (- l line))))
                       (when (or (null best) (< dist best-dist))
                         (setq best rec best-dist dist))))))
               best)
             (cl-find-if (lambda (rec) (and (eq (plist-get rec :kind) 'file)
                                            (equal (plist-get rec :path) path)))
                         agent-notes--records)))))

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

(defun agent-notes--compact (plist)
  "Return a copy of PLIST without nil values, which JSON cannot represent."
  (let (out)
    (while plist
      (when (cadr plist)
        (setq out (cons (cadr plist) (cons (car plist) out))))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun agent-notes--serialize (review)
  "Return REVIEW as pretty-printed JSON."
  (let ((data (copy-sequence review)))
    (setq data (plist-put
                data :notes
                (vconcat (mapcar (lambda (note)
                                   (agent-notes--compact
                                    (plist-put (copy-sequence note) :comments
                                               (vconcat (mapcar #'agent-notes--compact
                                                                (plist-get note :comments))))))
                                 (plist-get review :notes)))))
    (setq data (plist-put data :summaries
                          (vconcat (mapcar #'agent-notes--compact
                                           (plist-get review :summaries)))))
    (with-temp-buffer
      (insert (json-serialize (agent-notes--compact data)))
      (json-pretty-print-buffer)
      (buffer-string))))

(defun agent-notes--migrate (review)
  "Update REVIEW, as read from disk, to the current format."
  (let ((summary (plist-get review :summary)))
    (when (and (stringp summary) (not (string-empty-p summary))
               (null (plist-get review :summaries)))
      (setq review (plist-put review :summaries
                              (list (list :task "Review" :text summary
                                          :time (or (plist-get review :created) ""))))))
    (if (plist-member review :summary)
        (plist-put review :summary nil)
      review)))

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
  "Add a note by AUTHOR at LINE on SIDE of PATH and return it.
An empty PATH makes a general note about the whole change."
  (let* ((note (list :id (agent-notes--next :next_note) :author author :path path
                     :side side :line line :severity severity :status "open"
                     :comments (list (agent-notes--make-comment author body state))))
         (rec (agent-notes--exact-record note)))
    ;; Remember the code, so the note can follow it when the diff changes.
    (when rec (setq note (plist-put note :text (agent-notes--content rec))))
    (setq agent-notes--review
          (plist-put agent-notes--review :notes
                     (append (agent-notes--notes) (list note))))
    note))

(defun agent-notes--general-p (note)
  "Return non-nil if NOTE is about the whole change, not a file."
  (string-empty-p (plist-get note :path)))

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

(defun agent-notes--location (note)
  "Return a short description of where NOTE is."
  (if (agent-notes--general-p note)
      "general"
    (format "%s:%s" (plist-get note :path) (plist-get note :line))))

(defun agent-notes--first-line (note width)
  "Return the first line of NOTE's first comment, truncated to WIDTH."
  (truncate-string-to-width
   (car (split-string (plist-get (car (plist-get note :comments)) :body) "\n"))
   width nil nil "…"))

(defun agent-notes--scope-label (review)
  "Return a short description of REVIEW's scope."
  (if (equal (plist-get review :scope) "branch")
      (format "Branch vs %s" (plist-get review :base))
    "Working tree vs HEAD"))

(defun agent-notes--repo-name (review)
  "Return the name of REVIEW's repository."
  (file-name-nondirectory (directory-file-name (plist-get review :root))))

;;;; Following the code when the diff changes

(defun agent-notes--reanchor (note)
  "Move NOTE to the line that now holds its code.
Return non-nil if the note moved.  When its code is no longer in
the diff, mark the note as outdated."
  (let ((text (plist-get note :text)))
    (when (and (stringp text) (not (agent-notes--general-p note)))
      (let ((exact (agent-notes--exact-record note)))
        (if (and exact (equal (agent-notes--content exact) text))
            (progn (plist-put note :outdated nil) nil)
          (let ((path (plist-get note :path))
                (side (plist-get note :side))
                (line (plist-get note :line))
                best best-dist)
            (dolist (rec agent-notes--records)
              (when (and (agent-notes--code-p rec)
                         (equal (plist-get rec :path) path)
                         (equal (agent-notes--content rec) text))
                (let* ((s (agent-notes--rec-side rec side))
                       (l (agent-notes--rec-line rec s))
                       (dist (abs (- l line))))
                  (when (or (null best) (< dist best-dist))
                    (setq best (cons s l) best-dist dist)))))
            (if (not best)
                (progn (plist-put note :outdated t) nil)
              (plist-put note :side (car best))
              (plist-put note :line (cdr best))
              (plist-put note :outdated nil)
              t)))))))

(defun agent-notes--set-diff (diff)
  "Use DIFF as the diff of the current review."
  (setq agent-notes--records (agent-notes--parse-diff diff)
        agent-notes--index (agent-notes--index-records agent-notes--records)))

(defun agent-notes--resnapshot (&optional snapshot)
  "Replace the review's diff with SNAPSHOT, or with the current changes.
SNAPSHOT is a list (DIFF BASE-LABEL BASE-REV HEAD-REV).  Move the
notes along with their code and save.  Return (MOVED . OUTDATED)."
  (pcase-let ((`(,diff ,_label ,base-rev ,head)
               (or snapshot (agent-notes--snapshot-diff agent-notes--review)))
              (moved 0)
              (outdated 0))
    (agent-notes--write-file (agent-notes--diff-file agent-notes--file) diff)
    (setq agent-notes--review (plist-put agent-notes--review :base_rev base-rev))
    (setq agent-notes--review (plist-put agent-notes--review :head_rev head))
    (agent-notes--set-diff diff)
    (dolist (note (agent-notes--notes))
      (when (agent-notes--reanchor note) (cl-incf moved))
      (when (plist-get note :outdated) (cl-incf outdated)))
    (agent-notes--save)
    (cons moved outdated)))

;;;; Rendering

(defun agent-notes--severity-face (severity)
  "Return the face for SEVERITY."
  (pcase severity
    ((or "issue" "bug" "error" "critical") 'error)
    ("warning" 'warning)
    ("question" 'font-lock-builtin-face)
    ("info" 'agent-notes-info)
    ("nit" 'shadow)
    (_ 'success)))

(defun agent-notes--author-face (author)
  "Return the face for AUTHOR."
  (if (equal author "agent") 'agent-notes-agent 'agent-notes-you))

(defun agent-notes--line-face (kind)
  "Return the face for diff lines of KIND."
  (pcase kind
    ('added 'agent-notes-added)
    ('removed 'agent-notes-removed)
    (_ 'agent-notes-context)))

(defun agent-notes--fontify-line (line in-fence base &optional plain)
  "Return LINE of Markdown with faces; IN-FENCE means inside a code block.
BASE is the face for ordinary text.  Unless PLAIN, add the note
background."
  (let ((bg (unless plain '(agent-notes-note))))
    (if (or in-fence (string-prefix-p "```" (string-trim-left line)))
        (propertize line 'font-lock-face (append (list 'agent-notes-code base) bg))
      (let ((s (propertize line 'font-lock-face (cons base bg)))
            (start 0))
        (while (string-match "`[^`]+`\\|\\*\\*[^*]+\\*\\*" s start)
          (put-text-property (match-beginning 0) (match-end 0) 'font-lock-face
                             (append (list (if (eq (aref s (match-beginning 0)) ?`)
                                               'agent-notes-code
                                             'bold)
                                           base)
                                     bg)
                             s)
          (setq start (match-end 0)))
        s))))

(defun agent-notes--insert-markdown (text base pad &optional plain)
  "Insert TEXT, prefixed with PAD on each line, with Markdown faces.
BASE and PLAIN are as in `agent-notes--fontify-line'."
  (let ((in-fence nil))
    (dolist (line (split-string text "\n"))
      (insert pad (agent-notes--fontify-line line in-fence base plain) "\n")
      (when (string-prefix-p "```" (string-trim-left line))
        (setq in-fence (not in-fence))))))

(defun agent-notes--insert-note (note)
  "Insert NOTE as a section at point."
  (let* ((id (plist-get note :id))
         (comments (plist-get note :comments))
         (resolved (agent-notes--resolved-p note))
         (base (if resolved 'agent-notes-resolved 'default))
         (severity (or (plist-get note :severity) ""))
         (unsent (cl-count-if #'agent-notes--pending-p comments))
         (pad agent-notes--pad)
         (start (point)))
    (cl-flet ((ins (string &rest faces)
                (insert (propertize string 'font-lock-face
                                    (append faces '(agent-notes-note)))))
              (state-label (comment)
                (cond ((memq (plist-get comment :id) agent-notes--in-flight) "  sending…")
                      ((agent-notes--pending-p comment) "  unsent")
                      (t ""))))
      (magit-insert-section (agent-notes-note id resolved)
        ;; Heading: one line, also shown when the note is folded.
        (insert pad)
        (ins "┌ " 'agent-notes-border)
        (ins (format "#%d" id) 'bold base)
        (ins "  ")
        (ins (plist-get note :author) (agent-notes--author-face (plist-get note :author)))
        (unless (string-empty-p severity)
          (ins "  ")
          (ins severity (agent-notes--severity-face severity)))
        (ins "  ")
        (ins (if resolved "resolved" "open") base)
        (cond ((agent-notes--general-p note))
              ((plist-get note :outdated)
               (ins "  outdated: the code changed" 'warning))
              ((not (agent-notes--exact-record note))
               (ins (format "  %s (not in diff)" (agent-notes--location note)) 'shadow)))
        (when (> unsent 0)
          (ins (format "  %d unsent" unsent) 'agent-notes-pending))
        (when resolved
          (ins (format "  · %d comment%s · " (length comments)
                       (if (= (length comments) 1) "" "s"))
               'shadow)
          (ins (agent-notes--first-line note 50) base))
        (ins "\n")
        (magit-insert-heading)
        ;; Body: the comments.
        (let ((first t))
          (dolist (comment comments)
            (let ((cstart (point))
                  (border (propertize (concat "│ " (if first "" "  "))
                                      'font-lock-face '(agent-notes-border agent-notes-note))))
              (unless first
                (insert pad)
                (ins "│" 'agent-notes-border)
                (ins "\n")
                (insert pad)
                (ins "│ ↳ " 'agent-notes-border)
                (ins (plist-get comment :author)
                     (agent-notes--author-face (plist-get comment :author)))
                (ins (state-label comment) 'agent-notes-pending)
                (ins "\n"))
              (when (and first (memq (plist-get comment :id) agent-notes--in-flight))
                (insert pad)
                (ins "│ " 'agent-notes-border)
                (ins "(sending…)" 'agent-notes-pending)
                (ins "\n"))
              (agent-notes--insert-markdown (plist-get comment :body) base
                                            (concat pad border))
              (put-text-property cstart (point) 'agent-notes-comment (plist-get comment :id))
              (setq first nil))))
        (insert pad)
        (ins "└" 'agent-notes-border)
        (ins "\n")
        (put-text-property start (point) 'agent-notes-note id)
        (put-text-property start (point) 'wrap-prefix
                           (concat pad (propertize "│   " 'face '(agent-notes-border
                                                                  agent-notes-note))))))))

(defun agent-notes--insert-notes (rec by-record)
  "Insert the notes anchored to REC, according to BY-RECORD."
  (when rec
    (mapc #'agent-notes--insert-note (reverse (gethash rec by-record)))))

(defun agent-notes--insert-line (rec)
  "Insert the diff line REC in the unified view."
  (let ((start (point))
        (kind (plist-get rec :kind))
        (text (plist-get rec :text)))
    (if (eq kind 'meta)
        (insert agent-notes--pad (propertize (concat text "\n") 'font-lock-face 'shadow))
      (insert (propertize (format "%5s %5s " (or (and (not (eq kind 'added)) (plist-get rec :old)) "")
                                  (or (and (not (eq kind 'removed)) (plist-get rec :new)) ""))
                          'font-lock-face 'agent-notes-line-number))
      (insert (propertize (concat text "\n") 'font-lock-face (agent-notes--line-face kind))))
    (put-text-property start (point) 'agent-notes-loc rec)
    (put-text-property start (point) 'wrap-prefix agent-notes--pad)))

(defun agent-notes--expand-tabs (string)
  "Return STRING with tabs expanded to spaces."
  (if (not (string-search "\t" string))
      string
    (let ((col 0) (parts nil))
      (dolist (ch (string-to-list string))
        (if (eq ch ?\t)
            (let ((n (- tab-width (% col tab-width))))
              (push (make-string n ?\s) parts)
              (cl-incf col n))
          (push (char-to-string ch) parts)
          (cl-incf col (char-width ch))))
      (apply #'concat (nreverse parts)))))

(defun agent-notes--fit (text width)
  "Return the diff line TEXT expanded and padded or truncated to WIDTH."
  (truncate-string-to-width
   (concat (substring text 0 1) (agent-notes--expand-tabs (substring text 1)))
   width 0 ?\s "…"))

(defun agent-notes--split-rows (lines)
  "Pair the LINES of a hunk for the side-by-side view.
Return a list of (LEFT RIGHT).  Context lines are on both sides,
and each run of removed lines is paired with the added lines that
follow it.  Other lines, such as \"\\ No newline\", are (:meta REC)."
  (let (rows removed added)
    (cl-flet ((flush ()
                (setq removed (nreverse removed) added (nreverse added))
                (while (or removed added)
                  (push (list (pop removed) (pop added)) rows))))
      (dolist (rec lines)
        (pcase (plist-get rec :kind)
          ('removed (when added (flush)) (push rec removed))
          ('added (push rec added))
          ('context (flush) (push (list rec rec) rows))
          (_ (flush) (push (list :meta rec) rows))))
      (flush))
    (nreverse rows)))

(defun agent-notes--split-cell (rec key)
  "Return one half of a side-by-side row for REC, numbered by KEY."
  (if (null rec)
      (make-string agent-notes--half ?\s)
    (concat (propertize (format (format "%%%ds " (1- agent-notes--gutter)) (plist-get rec key))
                        'font-lock-face 'agent-notes-line-number)
            (propertize (agent-notes--fit (plist-get rec :text)
                                          (max 1 (- agent-notes--half agent-notes--gutter)))
                        'font-lock-face (agent-notes--line-face (plist-get rec :kind))))))

(defun agent-notes--insert-split-row (left right)
  "Insert a side-by-side row with the records LEFT and RIGHT.
Each half carries its own record, so commands act on the side at point."
  (let ((start (point)))
    (insert (agent-notes--split-cell left :old))
    (put-text-property start (point) 'agent-notes-loc (or left right))
    (setq start (point))
    (insert (propertize "│" 'font-lock-face 'agent-notes-border)
            (agent-notes--split-cell right :new)
            "\n")
    (put-text-property start (point) 'agent-notes-loc (or right left))))

(defun agent-notes--insert-hunk (hunk by-record)
  "Insert HUNK, a (HUNK-REC . LINES), with the notes from BY-RECORD."
  (let ((rec (car hunk))
        (lines (cdr hunk)))
    (magit-insert-section (agent-notes-hunk (cons (plist-get rec :path) (plist-get rec :text)))
      (let ((start (point)))
        (insert (propertize (concat (plist-get rec :text) "\n")
                            'font-lock-face 'agent-notes-hunk-header))
        (put-text-property start (point) 'agent-notes-loc rec))
      (magit-insert-heading)
      (if (eq agent-notes--view 'split)
          (dolist (row (agent-notes--split-rows lines))
            (pcase-let ((`(,left ,right) row))
              (if (eq left :meta)
                  (agent-notes--insert-line right)
                (agent-notes--insert-split-row left right)
                (agent-notes--insert-notes left by-record)
                (unless (eq left right)
                  (agent-notes--insert-notes right by-record)))))
        (dolist (line lines)
          (agent-notes--insert-line line)
          (agent-notes--insert-notes line by-record))))))

(defun agent-notes--insert-file (file by-record)
  "Insert FILE, a (FILE-REC . HUNKS), with the notes from BY-RECORD."
  (let ((rec (car file)))
    (magit-insert-section (agent-notes-file (plist-get rec :path))
      (let ((start (point)))
        (insert (propertize
                 (concat (plist-get rec :path)
                         (cond ((plist-get rec :from)
                                (format "  (renamed from %s)" (plist-get rec :from)))
                               ((equal (plist-get rec :status) "modified") "")
                               (t (format "  (%s)" (plist-get rec :status))))
                         "\n")
                 'font-lock-face 'agent-notes-file-header))
        (put-text-property start (point) 'agent-notes-loc rec))
      (magit-insert-heading)
      (agent-notes--insert-notes rec by-record)
      (dolist (hunk (cdr file))
        (agent-notes--insert-hunk hunk by-record)))))

(defun agent-notes--insert-header ()
  "Insert the title, the state of the agent and the summaries."
  (let* ((review agent-notes--review)
         (summaries (plist-get review :summaries))
         (base-rev (or (plist-get review :base_rev) "")))
    (magit-insert-section (agent-notes-header)
      (insert (propertize (format "Agent Notes · %s" (agent-notes--repo-name review))
                          'font-lock-face 'agent-notes-title)
              "\n")
      (magit-insert-heading)
      (insert (propertize (format "%s (%s) · %s\n" (agent-notes--scope-label review)
                                  (substring base-rev 0 (min 10 (length base-rev)))
                                  (plist-get review :created))
                          'font-lock-face 'shadow))
      (when agent-notes--status
        (insert (propertize (format "The agent is working: %s\n" agent-notes--status)
                            'font-lock-face 'agent-notes-pending)))
      (when agent-notes--changes
        (insert (propertize "Changed by the agent: " 'font-lock-face 'bold)
                (string-join agent-notes--changes ", ") "\n"))
      (when (and (null summaries) (null (agent-notes--notes)) (not agent-notes--status))
        (insert "No notes yet.  Press A to give the agent a task, "
                "or c on a line to write a note.\n"))
      (dolist (summary summaries)
        (magit-insert-section (agent-notes-summary (plist-get summary :time))
          (insert (propertize (format "%s summary" (plist-get summary :task))
                              'font-lock-face 'bold)
                  (propertize (format "  %s" (plist-get summary :time)) 'font-lock-face 'shadow)
                  "\n")
          (magit-insert-heading)
          (let ((start (point)))
            (agent-notes--insert-markdown (plist-get summary :text) 'default "  " t)
            (put-text-property start (point) 'wrap-prefix "  "))))
      (insert (propertize (substitute-command-keys
                           "\\<agent-notes-mode-map>\\[agent-notes-dispatch] all commands  \
\\[agent-notes-next-note]/\\[agent-notes-previous-note] notes  \\[magit-section-toggle] fold  \
\\[agent-notes-toggle-view] side by side\n")
                          'font-lock-face 'shadow))
      (insert "\n"))))

(defun agent-notes--point-anchor ()
  "Describe the position at point so it can be found after re-rendering."
  (list :comment (get-text-property (point) 'agent-notes-comment)
        :note (get-text-property (point) 'agent-notes-note)
        :rec (get-text-property (point) 'agent-notes-loc)
        :line (line-number-at-pos)
        :column (current-column)))

(defun agent-notes--find-prop (prop value &optional test)
  "Return the start of the first region whose PROP is VALUE under TEST."
  (save-excursion
    (goto-char (point-min))
    (let ((match (text-property-search-forward prop value (or test #'eq))))
      (and match (prop-match-beginning match)))))

(defun agent-notes--anchor-position (anchor)
  "Return the position described by ANCHOR in the current rendering."
  (or (and (plist-get anchor :comment)
           (agent-notes--find-prop 'agent-notes-comment (plist-get anchor :comment)))
      (let ((section (and (plist-get anchor :note)
                          (agent-notes--note-section (plist-get anchor :note)))))
        (and section (oref section start)))
      (let ((pos (and (plist-get anchor :rec)
                      (agent-notes--find-prop 'agent-notes-loc (plist-get anchor :rec) #'equal))))
        (and pos (save-excursion (goto-char pos)
                                 (move-to-column (plist-get anchor :column))
                                 (point))))
      (save-excursion (goto-char (point-min))
                      (forward-line (1- (plist-get anchor :line)))
                      (point))))

(defun agent-notes--layout (win)
  "Compute the widths used to render for the window WIN."
  (setq agent-notes--width (if (window-live-p win) (window-max-chars-per-line win) 160))
  (if (not (eq agent-notes--view 'split))
      (setq agent-notes--pad (make-string 12 ?\s))
    (let ((max-line 0))
      (dolist (rec agent-notes--records)
        (setq max-line (max max-line (or (plist-get rec :old) 0) (or (plist-get rec :new) 0))))
      (setq agent-notes--gutter (1+ (max 4 (length (number-to-string max-line))))
            ;; Two halves and a separator, leaving the last column free.
            agent-notes--half (max 20 (/ (- agent-notes--width 2) 2))
            agent-notes--pad (make-string agent-notes--gutter ?\s)))))

(defun agent-notes--render (&optional win)
  "Redraw the review buffer for WIN, keeping point on the same thing."
  (let* ((win (or win (get-buffer-window (current-buffer) t)))
         (pos (if win (window-point win) (point)))
         (anchor (save-excursion (goto-char pos) (agent-notes--point-anchor)))
         (offset (and win (count-lines (window-start win) pos)))
         (inhibit-read-only t)
         (by-record (make-hash-table :test #'eq))
         (general nil))
    (agent-notes--layout win)
    (setq agent-notes--placement (make-hash-table))
    (dolist (note (agent-notes--notes))
      (let ((rec (agent-notes--anchor-record note)))
        (if rec
            (progn (push note (gethash rec by-record))
                   (puthash (plist-get note :id) rec agent-notes--placement))
          (push note general))))
    (erase-buffer)
    (magit-insert-section (agent-notes-root)
      (agent-notes--insert-header)
      (when general
        (magit-insert-section (agent-notes-general)
          (insert (propertize "General notes\n" 'font-lock-face 'agent-notes-file-header))
          (magit-insert-heading)
          (mapc #'agent-notes--insert-note (nreverse general))))
      (dolist (file (agent-notes--file-tree agent-notes--records))
        (agent-notes--insert-file file by-record)))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (let ((new-pos (agent-notes--anchor-position anchor)))
      (goto-char new-pos)
      (when win
        (set-window-point win new-pos)
        (set-window-start win (save-excursion (forward-line (- offset)) (point)) t)))
    (force-mode-line-update)))

(defun agent-notes--on-window-size-change (win)
  "Redraw the side-by-side view when the width of WIN changes."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (when (and (derived-mode-p 'agent-notes-mode)
                 (eq agent-notes--view 'split)
                 (not (eql agent-notes--width (window-max-chars-per-line win))))
        (agent-notes--render win)))))

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
  (setq agent-notes--review
        (agent-notes--migrate (agent-notes--json-parse (agent-notes--read-file agent-notes--file))))
  (agent-notes--set-diff (agent-notes--read-file (agent-notes--diff-file agent-notes--file)))
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
- \"severity\": one of \"issue\", \"warning\", \"suggestion\", \"question\", \"nit\", or \"info\" for explanations that are not problems.
- \"body\": the note in Markdown. Be specific and concise; propose a fix when you have one.
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
   "\nDo not modify any files for this task unless the task explicitly asks you to.\n\n"
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
               "the notes move with the code.\n")
     "")
   "\n"
   (mapconcat (lambda (note) (agent-notes--format-thread note new-ids)) notes "")
   agent-notes--note-spec "\n\n"
   (agent-notes--json-instructions
    "{\"replies\": [{\"note\": 3, \"body\": \"...\", \"resolve\": false}],\n \"notes\": []}")))

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

(defun agent-notes--apply-review (data task-name)
  "Store the result DATA of the task TASK-NAME returned by the agent."
  (unless (or (plist-member data :notes) (plist-member data :summary))
    (error "The agent's answer has no \"notes\""))
  (let ((summary (plist-get data :summary)))
    (when (and (stringp summary) (not (string-blank-p summary)))
      (setq agent-notes--review
            (plist-put agent-notes--review :summaries
                       (append (plist-get agent-notes--review :summaries)
                               (list (list :task task-name :text summary
                                           :time (format-time-string "%F %R"))))))))
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

(defun agent-notes--run (label prompt on-success &optional in-flight)
  "Run Copilot with PROMPT in the review session.
LABEL describes the request.  On success, call ON-SUCCESS with the
parsed JSON answer and IN-FLIGHT, the ids of the comments sent."
  (unless (executable-find agent-notes-copilot-program)
    (user-error "Cannot find `%s'; customize `agent-notes-copilot-program'"
                agent-notes-copilot-program))
  (let* ((file agent-notes--file)
         (default-directory (plist-get agent-notes--review :root))
         ;; To tell which files the agent changes.
         (before (ignore-errors
                   (agent-notes--fingerprints (car (agent-notes--snapshot-diff agent-notes--review)))))
         (args (agent-notes--copilot-args prompt)))
    (agent-notes--log "%s: %s %s\n%s" label agent-notes-copilot-program
                      (mapconcat #'shell-quote-argument (butlast args 2) " ")
                      prompt)
    (setq agent-notes--in-flight in-flight
          agent-notes--changes nil
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
                       (agent-notes--sentinel proc file label on-success in-flight before))))
    (agent-notes--render)))

(defun agent-notes--detect-changes (before)
  "Find the files changed since BEFORE and refresh the diff if needed.
BEFORE is the result of `agent-notes--fingerprints' when the agent
started.  Return a message describing what happened, or nil."
  (let* ((snapshot (agent-notes--snapshot-diff agent-notes--review))
         (diff (car snapshot))
         (after (agent-notes--fingerprints diff))
         (stale (not (equal diff (agent-notes--read-file
                                  (agent-notes--diff-file agent-notes--file)))))
         (changed nil))
    (when before
      (dolist (entry (append before after))
        (let ((path (car entry)))
          (unless (or (member path changed)
                      (equal (cdr (assoc path before)) (cdr (assoc path after))))
            (push path changed))))
      (setq agent-notes--changes (nreverse changed)))
    (when stale
      (let ((what (if agent-notes--changes
                      (format "the agent changed %s" (string-join agent-notes--changes ", "))
                    "the code changed")))
        (if (not agent-notes-auto-refresh)
            (format "%s; press g to refresh the diff" what)
          (pcase-let ((`(,moved . ,outdated) (agent-notes--resnapshot snapshot)))
            (format "%s; diff refreshed (%d note%s moved, %d outdated)" what
                    moved (if (= moved 1) "" "s") outdated)))))))

(defun agent-notes--sentinel (proc file label on-success in-flight before)
  "Handle the end of the Copilot PROC for the review FILE.
LABEL, ON-SUCCESS and IN-FLIGHT are as in `agent-notes--run'.
BEFORE is as in `agent-notes--detect-changes'."
  (when (memq (process-status proc) '(exit signal))
    (let ((output (with-current-buffer (process-buffer proc) (buffer-string)))
          (code (process-exit-status proc))
          (ok (and (eq (process-status proc) 'exit) (zerop (process-exit-status proc))))
          (changes nil))
      (kill-buffer (process-buffer proc))
      (agent-notes--log "%s finished (exit code %s):\n%s" label code output)
      (with-current-buffer (agent-notes--get-buffer file)
        (setq agent-notes--process nil
              agent-notes--status nil
              agent-notes--in-flight nil)
        ;; Refresh first, so new notes are anchored to the code as it is now.
        (condition-case err
            (setq changes (agent-notes--detect-changes before))
          (error (agent-notes--log "Could not check for changes: %s"
                                   (error-message-string err))))
        (condition-case err
            (progn
              (unless ok (error "Copilot exited with code %s" code))
              (funcall on-success (agent-notes--extract-json output) in-flight)
              (agent-notes--save)
              (message "Agent Notes: %s done%s" label (if changes (concat "; " changes) "")))
          (error (message "Agent Notes: %s failed: %s%s (press $ for the log)"
                          label (error-message-string err)
                          (if changes (concat "; " changes) ""))))
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

(defun agent-notes--sections (type &optional pred)
  "Return the sections of TYPE that satisfy PRED, in buffer order."
  (let (result)
    (when magit-root-section
      (magit-map-sections (lambda (section)
                            (when (and (eq (oref section type) type)
                                       (or (null pred) (funcall pred section)))
                              (push section result)))))
    (sort result (lambda (a b) (< (oref a start) (oref b start))))))

(defun agent-notes--note-section (id)
  "Return the section of the note ID, or nil."
  (car (agent-notes--sections 'agent-notes-note
                              (lambda (section) (eql (oref section value) id)))))

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

(defun agent-notes--jump (type forward what &optional pred)
  "Move to the next section of TYPE; backward unless FORWARD.
PRED filters the sections.  WHAT names them in messages."
  (let* ((targets (agent-notes--sections type pred))
         (bol (line-beginning-position))
         (eol (line-end-position))
         (target (if forward
                     (cl-find-if (lambda (s) (> (oref s start) eol)) targets)
                   (cl-find-if (lambda (s) (< (oref s start) bol)) (reverse targets)))))
    (unless targets (user-error "No %s" what))
    (unless target
      (setq target (if forward (car targets) (car (last targets))))
      (message "Wrapped around"))
    (agent-notes--goto-section target)
    (when (eq type 'agent-notes-note)
      (message "Note #%d (%d of %d)" (oref target value)
               (1+ (cl-position target targets)) (length targets)))))

(defun agent-notes--agent-section-p (section)
  "Return non-nil if SECTION is a note written by the agent."
  (equal (plist-get (agent-notes--note (oref section value)) :author) "agent"))

(defun agent-notes-next-note ()
  "Move to the next note."
  (interactive)
  (agent-notes--jump 'agent-notes-note t "notes"))

(defun agent-notes-previous-note ()
  "Move to the previous note."
  (interactive)
  (agent-notes--jump 'agent-notes-note nil "notes"))

(defun agent-notes-next-agent-note ()
  "Move to the next note written by the agent."
  (interactive)
  (agent-notes--jump 'agent-notes-note t "agent notes" #'agent-notes--agent-section-p))

(defun agent-notes-previous-agent-note ()
  "Move to the previous note written by the agent."
  (interactive)
  (agent-notes--jump 'agent-notes-note nil "agent notes" #'agent-notes--agent-section-p))

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
Resolved notes are folded."
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
    (message "Note #%d %s" id (plist-get note :status))))

(defun agent-notes-toggle-view ()
  "Switch between the unified and the side-by-side diff."
  (interactive)
  (setq agent-notes--view (if (eq agent-notes--view 'split) 'unified 'split))
  (agent-notes--render)
  (message "%s view" (if (eq agent-notes--view 'split) "Side-by-side" "Unified")))

(defun agent-notes-refresh ()
  "Snapshot the changes again and move the notes along with their code.
The scope and base of the review stay the same."
  (interactive)
  (agent-notes--ensure-idle)
  (let ((snapshot (agent-notes--snapshot-diff agent-notes--review)))
    (if (equal (car snapshot) (agent-notes--read-file (agent-notes--diff-file agent-notes--file)))
        (progn (agent-notes--reload)
               (message "No changes since the last snapshot"))
      (pcase-let ((`(,moved . ,outdated) (agent-notes--resnapshot snapshot)))
        (agent-notes--render)
        (message "Diff refreshed: %d note%s moved, %d outdated"
                 moved (if (= moved 1) "" "s") outdated)))))

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
  "Jump to a note chosen from a list."
  (interactive)
  (let ((candidates (mapcar (lambda (note) (cons (agent-notes--describe-note note)
                                                 (plist-get note :id)))
                            (agent-notes--notes))))
    (unless candidates (user-error "No notes"))
    (agent-notes--goto-note
     (cdr (assoc (completing-read "Note: " (agent-notes--completion-table candidates) nil t)
                 candidates)))))

(defun agent-notes-visit ()
  "Open the file of the line or note at point, read-only."
  (interactive)
  (let* ((note (and (get-text-property (point) 'agent-notes-note) (agent-notes--note-at-point)))
         (rec (if note
                  (gethash (plist-get note :id) agent-notes--placement)
                (get-text-property (point) 'agent-notes-loc)))
         (path (if note (plist-get note :path) (plist-get rec :path)))
         (line (cond ((and note (equal (plist-get note :side) "new")) (plist-get note :line))
                     (rec (plist-get rec :new))))
         (file (and path (not (string-empty-p path))
                    (expand-file-name path (plist-get agent-notes--review :root)))))
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
                      (lambda (data _) (agent-notes--apply-review data name)))))

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

(defun agent-notes-show-log ()
  "Show the log of requests sent to the agent and its raw answers."
  (interactive)
  (let ((buf (get-buffer-create agent-notes--log-buffer)))
    (with-current-buffer buf (goto-char (point-max)))
    (display-buffer buf)))

;;;; Menus

(transient-define-prefix agent-notes-dispatch ()
  "Show the commands of the review buffer."
  [["Move"
    ("n" "Next note" agent-notes-next-note)
    ("p" "Previous note" agent-notes-previous-note)
    ("N" "Next agent note" agent-notes-next-agent-note)
    ("P" "Previous agent note" agent-notes-previous-agent-note)
    ("M-n" "Next hunk" agent-notes-next-hunk)
    ("M-p" "Previous hunk" agent-notes-previous-hunk)
    ("}" "Next file" agent-notes-next-file)
    ("{" "Previous file" agent-notes-previous-file)
    ("l" "Jump to a note…" agent-notes-list)]
   ["Notes"
    ("c" "New note" agent-notes-new-note)
    ("r" "Reply" agent-notes-reply)
    ("e" "Edit unsent comment" agent-notes-edit)
    ("k" "Delete unsent comment" agent-notes-delete)
    ("R" "Resolve / reopen" agent-notes-toggle-resolved)]
   ["Agent"
    ("s" "Send unsent comments" agent-notes-send)
    ("A" "Give a task…" agent-notes-request-review)
    ("x" "Abort" agent-notes-abort)
    ("$" "Show log" agent-notes-show-log)]
   ["View"
    ("v" "Unified / side by side" agent-notes-toggle-view)
    ("g" "Refresh diff" agent-notes-refresh)
    ("o" "Visit file" agent-notes-visit)
    (:info "TAB  fold section")
    (:info "RET  visit file")
    (:info "^    parent section")
    (:info "1-4  show levels")]])

;;;###autoload (autoload 'agent-notes-menu "agent-notes" nil t)
(transient-define-prefix agent-notes-menu ()
  "Review the changes in the current repository with an agent."
  ["Agent notes"
   ("w" "Review working tree…" agent-notes-review-working-tree)
   ("b" "Review branch…" agent-notes-review-branch)
   ("l" "Open latest review" agent-notes-open-latest)
   ("o" "Open a review…" agent-notes-open)])

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
  "r" #'agent-notes-reply
  "e" #'agent-notes-edit
  "k" #'agent-notes-delete
  "R" #'agent-notes-toggle-resolved
  "s" #'agent-notes-send
  "l" #'agent-notes-list
  "RET" #'agent-notes-visit
  "o" #'agent-notes-visit
  "A" #'agent-notes-request-review
  "v" #'agent-notes-toggle-view
  "g" #'agent-notes-refresh
  "$" #'agent-notes-show-log
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
  (setq agent-notes--view agent-notes-default-view)
  (add-hook 'window-size-change-functions #'agent-notes--on-window-size-change nil t))

;;;; Entry points

(defun agent-notes--read-base ()
  "Read the base branch of a branch review."
  (let ((default (agent-notes--default-base)))
    (completing-read (format-prompt "Base branch" default)
                     (agent-notes--branches) nil nil nil nil default)))

(defun agent-notes--read-scope ()
  "Read the scope of a new review; return (SCOPE BASE)."
  (let* ((working "Working tree: uncommitted changes vs HEAD")
         (choice (completing-read "Review: "
                                  (list working "Branch: all changes since a base branch")
                                  nil t nil nil working)))
    (if (equal choice working)
        (list "working" nil)
      (list "branch" (agent-notes--read-base)))))

;;;###autoload
(defun agent-notes-review (scope &optional base task)
  "Snapshot the changes in SCOPE and give the agent TASK on them.
SCOPE is \"working\" for uncommitted changes against HEAD, or
\"branch\" for everything since the current branch forked from BASE.
TASK is a (NAME . INSTRUCTIONS); it defaults to the first entry of
`agent-notes-tasks'."
  (interactive (let ((default-directory (agent-notes--root)))
                 (append (agent-notes--read-scope) (list (agent-notes--read-task)))))
  (let* ((default-directory (agent-notes--root))
         (root default-directory)
         (task (or task (car agent-notes-tasks)
                   (user-error "No task given; see `agent-notes-tasks'"))))
    (pcase-let ((`(,diff ,base-label ,base-rev ,head) (agent-notes--make-diff scope base)))
      (when (string-blank-p diff)
        (user-error "No changes to review"))
      (let* ((id (format-time-string "%Y%m%d-%H%M%S"))
             (dir (agent-notes--directory))
             (file (expand-file-name (concat id ".json") dir))
             (review (list :version 2 :id id :root root :scope scope
                           :base base-label :base_rev base-rev :head_rev head
                           :created (format-time-string "%F %R")
                           :session (agent-notes--uuid)
                           :next_note 1 :next_comment 1 :summaries nil :notes nil)))
        (make-directory dir t)
        (agent-notes--write-file (agent-notes--diff-file file) diff)
        (agent-notes--write-file file (agent-notes--serialize review))
        (let ((buf (agent-notes--get-buffer file)))
          (pop-to-buffer-same-window buf)
          (with-current-buffer buf
            (agent-notes--start-task task)))))))

;;;###autoload
(defun agent-notes-review-working-tree (task)
  "Give the agent TASK on the uncommitted changes of the repository."
  (interactive (progn (agent-notes--root) (list (agent-notes--read-task))))
  (agent-notes-review "working" nil task))

;;;###autoload
(defun agent-notes-review-branch (base task)
  "Give the agent TASK on all changes since the current branch forked from BASE."
  (interactive (let ((default-directory (agent-notes--root)))
                 (list (agent-notes--read-base) (agent-notes--read-task))))
  (agent-notes-review "branch" base task))

(defun agent-notes--review-files ()
  "Return the review files of the current repository, newest first."
  (let ((dir (agent-notes--directory)))
    (and (file-directory-p dir)
         (reverse (directory-files dir t "\\.json\\'")))))

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

;;;; Magit integration

(defvar magit-mode-map)
(defvar magit-status-sections-hook)

(defun agent-notes-open-at-point ()
  "Open the review of the Agent Notes section at point."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'agent-notes))
      (user-error "No review here"))
    (pop-to-buffer-same-window (agent-notes--get-buffer (oref section value)))))

;; Magit finds a section's keymap by the name `magit-TYPE-section-map'.
(defvar-keymap magit-agent-notes-section-map
  :doc "Keymap for the Agent Notes section in the Magit status buffer."
  "RET" #'agent-notes-open-at-point
  "<remap> <magit-visit-thing>" #'agent-notes-open-at-point)

(defun agent-notes-insert-status-section ()
  "Insert a line about the latest review into the Magit status buffer."
  (when agent-notes-magit-status-section
    (let* ((file (ignore-errors (car (agent-notes--review-files))))
           (review (and file (ignore-errors
                               (agent-notes--json-parse (agent-notes--read-file file))))))
      (when review
        (let* ((notes (plist-get review :notes))
               (open (cl-count-if-not #'agent-notes--resolved-p notes))
               (unsent (cl-loop for note in notes
                                sum (cl-count-if #'agent-notes--pending-p
                                                 (plist-get note :comments)))))
          (magit-insert-section (agent-notes file)
            (insert (propertize "Agent review: " 'font-lock-face 'magit-section-heading)
                    (agent-notes--scope-label review)
                    (format " · %d open" open)
                    (if (> unsent 0)
                        (propertize (format ", %d unsent" unsent)
                                    'font-lock-face 'agent-notes-pending)
                      "")
                    (propertize (format " · %s" (plist-get review :created))
                                'font-lock-face 'shadow)
                    "\n\n")))))))

(defun agent-notes--magit-setup ()
  "Add Agent Notes to Magit: `@' in Magit buffers and `magit-dispatch'.
Also add the status section; see `agent-notes-magit-status-section'."
  (keymap-set magit-mode-map "@" #'agent-notes-menu)
  (condition-case err
      (unless (ignore-errors (transient-get-suffix 'magit-dispatch "@"))
        (transient-append-suffix 'magit-dispatch "!"
          '("@" "Agent notes" agent-notes-menu)))
    (error (message "agent-notes: could not extend `magit-dispatch': %s"
                    (error-message-string err))))
  (if (memq 'magit-insert-untracked-files (default-value 'magit-status-sections-hook))
      (magit-add-section-hook 'magit-status-sections-hook
                              #'agent-notes-insert-status-section
                              'magit-insert-untracked-files)
    (magit-add-section-hook 'magit-status-sections-hook
                            #'agent-notes-insert-status-section nil t)))

(with-eval-after-load 'magit
  (agent-notes--magit-setup))

(provide 'agent-notes)
;;; agent-notes.el ends here
