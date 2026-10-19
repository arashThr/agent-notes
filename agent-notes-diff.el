;;; agent-notes-diff.el --- Git diffs, parsing and note anchoring for agent-notes -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el.  This file runs git,
;; parses unified diffs into line records, anchors notes to those
;; records (and moves them when the diff changes), and syntax
;; highlights the code of hunks.

;;; Code:

(require 'agent-notes-core)

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

(defun agent-notes--review-files ()
  "Return the review files of the current repository, newest first."
  (let ((dir (agent-notes--directory)))
    (and (file-directory-p dir)
         (reverse (directory-files dir t "\\.json\\'")))))

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

(defun agent-notes--stored-diff ()
  "Return the diff snapshot of the current review."
  (agent-notes--read-file (agent-notes--diff-file agent-notes--file)))

;;;; Parsing

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

(defun agent-notes--diff-stats (records)
  "Describe the size of the diff RECORDS, like \"3 files, +40 −12\"."
  (format "%s, +%d −%d"
          (agent-notes--plural (cl-count 'file records :key (lambda (r) (plist-get r :kind)))
                               "file")
          (cl-count 'added records :key (lambda (r) (plist-get r :kind)))
          (cl-count 'removed records :key (lambda (r) (plist-get r :kind)))))

;;;; Anchoring notes

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

(defun agent-notes--file-lines (path line count)
  "Return COUNT lines of PATH in the working tree, starting at LINE.
Return nil if the file does not have those lines."
  (let ((file (expand-file-name path (plist-get agent-notes--review :root))))
    (when (and (> line 0) (file-readable-p file) (not (file-directory-p file)))
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file))
        (goto-char (point-min))
        (when (and (zerop (forward-line (1- line))) (not (eobp)))
          (let ((beg (point)))
            (when (zerop (forward-line (1- count)))
              (buffer-substring-no-properties beg (line-end-position)))))))))

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
        agent-notes--index (agent-notes--index-records agent-notes--records)
        agent-notes--syntax-cache nil))

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

(defun agent-notes--describe-moves (result)
  "Describe RESULT, a (MOVED . OUTDATED) from `agent-notes--resnapshot'."
  (format "%s moved, %d outdated"
          (agent-notes--plural (car result) "note") (cdr result)))

;;;; Syntax highlighting

(defun agent-notes--face-list (face)
  "Return FACE, a face spec from a `face' property, as a list of faces."
  (cond ((null face) nil)
        ((and (consp face) (not (keywordp (car face)))) face)
        (t (list face))))

(defun agent-notes--fontify-text (file text)
  "Return TEXT with `face' properties, highlighted as the contents of FILE.
Return nil if FILE has no major mode with highlighting."
  (with-temp-buffer
    (insert text)
    ;; Like `diff-syntax-fontify-props': choose the mode by file name
    ;; without running mode hooks, so no language server is started.
    ;; Modes may guess settings from the text and say so; keep quiet.
    (let ((enable-local-variables nil)
          (buffer-file-name file)
          (inhibit-message t)
          (message-log-max nil))
      (delay-mode-hooks (set-auto-mode)))
    (unless (eq major-mode 'fundamental-mode)
      (let ((font-lock-defaults (or font-lock-defaults '(nil t)))
            (inhibit-message t)
            (message-log-max nil))
        (font-lock-ensure))
      (let ((out (buffer-substring-no-properties (point-min) (point-max)))
            (pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-single-property-change pos 'face nil (point-max)))
                (face (get-text-property pos 'face)))
            (when face
              (put-text-property (1- pos) (1- next) 'face face out))
            (setq pos next)))
        out))))

(defun agent-notes--fontify-code (path text)
  "Return TEXT highlighted as code of PATH, or nil; cached per buffer."
  (unless agent-notes--syntax-cache
    (setq agent-notes--syntax-cache (make-hash-table :test #'equal)))
  (let* ((key (concat path "\0" (md5 text)))
         (hit (gethash key agent-notes--syntax-cache 'none)))
    (if (not (eq hit 'none))
        hit
      (puthash key
               (ignore-errors
                 (agent-notes--fontify-text
                  (expand-file-name path (or (plist-get agent-notes--review :root)
                                             default-directory))
                  text))
               agent-notes--syntax-cache))))

(defun agent-notes--hunk-syntax (path lines)
  "Return a table from the code records in LINES to their highlighted code.
The old and the new side of the hunk are highlighted separately, as
code of PATH.  Return nil if highlighting is off."
  (when agent-notes-syntax-highlighting
    (let ((table (make-hash-table :test #'eq)))
      (dolist (kinds '((context added) (context removed)))
        (let* ((recs (cl-remove-if-not (lambda (r) (memq (plist-get r :kind) kinds)) lines))
               (code (and recs (agent-notes--fontify-code
                                path (mapconcat (lambda (r) (concat (agent-notes--content r) "\n"))
                                                recs ""))))
               (start 0))
          (when code
            (dolist (rec recs)
              (let ((end (or (string-search "\n" code start) (length code))))
                (unless (gethash rec table)
                  (puthash rec (substring code start end) table))
                (setq start (min (length code) (1+ end))))))))
      table)))

(provide 'agent-notes-diff)
;;; agent-notes-diff.el ends here
