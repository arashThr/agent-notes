;;; agent-notes-tests.el --- Tests for agent-notes -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with (magit-section and transient must be on the load path):
;;   emacs -Q --batch \
;;     --eval '(progn (setq package-user-dir "~/.config/emacs/elpa") (package-initialize))' \
;;     -L . -l test/agent-notes-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-notes)

;; Tests that run a fake agent must not pop up real notifications.
(setq agent-notes-notify nil)

(defconst agent-notes-tests--diff
  "diff --git a/src/auth.py b/src/auth.py
index 1111111..2222222 100644
--- a/src/auth.py
+++ b/src/auth.py
@@ -10,4 +10,5 @@ def login(user):
     token = make_token(user)
-    log(token)
+    if user.disabled:
+        return None
     return token
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+hello
")

;; The same change after two lines were inserted above it, and new.txt
;; was rewritten.
(defconst agent-notes-tests--diff-2
  "diff --git a/src/auth.py b/src/auth.py
index 1111111..4444444 100644
--- a/src/auth.py
+++ b/src/auth.py
@@ -9,4 +9,7 @@ def login(user):
 import os
+import sys
+import re
     token = make_token(user)
-    log(token)
+    if user.disabled:
+        return None
     return token
diff --git a/new.txt b/new.txt
new file mode 100644
index 0000000..5555555
--- /dev/null
+++ b/new.txt
@@ -0,0 +1 @@
+goodbye
")

(defun agent-notes-tests--records ()
  (agent-notes--parse-diff agent-notes-tests--diff))

(ert-deftest agent-notes-test-parse-line-numbers ()
  (let* ((records (agent-notes-tests--records))
         (code (cl-remove-if-not #'agent-notes--code-p records)))
    (should (equal (mapcar (lambda (r) (list (plist-get r :kind) (plist-get r :old) (plist-get r :new)))
                           code)
                   '((context 10 10) (removed 11 11) (added nil 11) (added nil 12)
                     (context 12 13) (added nil 1))))
    (should (equal (mapcar (lambda (r) (plist-get r :path)) code)
                   '("src/auth.py" "src/auth.py" "src/auth.py" "src/auth.py" "src/auth.py" "new.txt")))
    (should (equal (plist-get (cl-find-if (lambda (r) (and (eq (plist-get r :kind) 'file)
                                                           (equal (plist-get r :path) "new.txt")))
                                          records)
                              :status)
                   "added"))))

(ert-deftest agent-notes-test-index-and-tree ()
  (let* ((records (agent-notes-tests--records))
         (index (agent-notes--index-records records))
         (tree (agent-notes--file-tree records)))
    (should (eq (plist-get (gethash (agent-notes--loc-key "src/auth.py" "old" 11) index) :kind)
                'removed))
    (should (eq (plist-get (gethash (agent-notes--loc-key "src/auth.py" "new" 12) index) :kind)
                'added))
    (should (eq (plist-get (gethash (agent-notes--loc-key "src/auth.py" "old" 12) index) :kind)
                'context))
    (should-not (gethash (agent-notes--loc-key "src/auth.py" "new" 99) index))
    ;; Two files; the first has one hunk with five lines.
    (should (equal (mapcar (lambda (f) (plist-get (car f) :path)) tree) '("src/auth.py" "new.txt")))
    (should (= (length (cdr (car tree))) 1))
    (should (= (length (cdr (car (cdr (car tree))))) 5))))

(ert-deftest agent-notes-test-split-rows ()
  (let* ((lines (cdr (car (cdr (car (agent-notes--file-tree (agent-notes-tests--records)))))))
         (rows (agent-notes--split-rows lines))
         (kinds (mapcar (lambda (row) (list (plist-get (car row) :kind) (plist-get (cadr row) :kind)))
                        rows)))
    ;; The removed line is paired with the first added line.
    (should (equal kinds '((context context) (removed added) (nil added) (context context))))))

(ert-deftest agent-notes-test-fingerprints ()
  (let ((a (agent-notes--fingerprints agent-notes-tests--diff))
        (b (agent-notes--fingerprints agent-notes-tests--diff-2)))
    (should (equal (mapcar #'car a) '("src/auth.py" "new.txt")))
    (should-not (equal (cdr (assoc "new.txt" a)) (cdr (assoc "new.txt" b))))))

(ert-deftest agent-notes-test-extract-json ()
  (should (equal (agent-notes--extract-json
                  "Looks good overall.\n```python\nx = 1\n```\n```json\n{\"summary\": \"ok\", \"notes\": []}\n```\n")
                 '(:summary "ok" :notes nil)))
  (should (equal (plist-get (agent-notes--extract-json "Here: {\"replies\": [{\"note\": 1, \"resolve\": true}]}")
                            :replies)
                 '((:note 1 :resolve t))))
  (should-error (agent-notes--extract-json "no json here")))

(defmacro agent-notes-tests--with-review (review-extra &rest body)
  "Run BODY in a review buffer backed by temporary files.
REVIEW-EXTRA is a plist merged into the stored review."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "agent-notes-test" t))
          (file (expand-file-name "r.json" dir)))
     (unwind-protect
         (progn
           (agent-notes--write-file (agent-notes--diff-file file) agent-notes-tests--diff)
           (agent-notes--write-file
            file (agent-notes--serialize
                  (append ,review-extra
                          (list :version 2 :id "r" :root (file-name-as-directory dir)
                                :scope "working" :base "HEAD" :base_rev "abc" :head_rev "abc"
                                :created "now" :session "s" :next_note 1 :next_comment 1
                                :summaries nil :notes nil))))
           (with-current-buffer (agent-notes--get-buffer file)
             (unwind-protect (progn ,@body)
               (kill-buffer))))
       (delete-directory dir t))))

(defun agent-notes-tests--line-before-note (id)
  "Return the diff record on the line just above the note ID."
  (save-excursion
    (goto-char (oref (agent-notes--note-section id) start))
    (forward-line -1)
    (get-text-property (point) 'agent-notes-loc)))

(ert-deftest agent-notes-test-review-roundtrip-and-render ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:summary "Adds a disabled check."
       :notes ((:path "b/src/auth.py" :line 11 :side "new" :severity "warning"
                :body "Returning `None` breaks callers.")
               (:path "src/auth.py" :line 99 :side "new" :severity "nit" :body "Far away")
               (:path "" :line 0 :side "new" :severity "info" :body "General")))
     "Review")
    (agent-notes--save)
    (agent-notes--render)
    (let ((text (buffer-string)))
      (should (string-match-p "Returning `None` breaks callers." text))
      (should (string-match-p "General notes" text))
      (should (string-match-p "Review summary" text))
      (should (string-match-p "src/auth.py:99 (not in diff)" text)))
    ;; Notes remember their code.
    (should (equal (plist-get (agent-notes--note 1) :text) "    if user.disabled:"))
    ;; The first note is a section right below the line it refers to.
    (should (equal (plist-get (agent-notes-tests--line-before-note 1) :text)
                   "+    if user.disabled:"))
    (should (eq (oref (oref (agent-notes--note-section 1) parent) type) 'agent-notes-hunk))
    (should (eq (oref (oref (agent-notes--note-section 3) parent) type) 'agent-notes-general))
    ;; Navigation visits the notes in buffer order: general note first.
    (goto-char (point-min))
    (agent-notes-next-note)
    (should (eql (get-text-property (point) 'agent-notes-note) 3))
    (agent-notes-next-note)
    (should (eql (get-text-property (point) 'agent-notes-note) 1))
    (agent-notes-next-hunk)
    (should (eq (oref (magit-current-section) type) 'agent-notes-hunk))
    ;; A user note and a reply are queued, then answered.
    (let ((mine (agent-notes--add-note "you" "new.txt" "new" 1 "" "Why?" "pending"))
          (reply (agent-notes--make-comment "you" "Callers handle None." "pending")))
      (plist-put (agent-notes--note 1) :comments
                 (append (plist-get (agent-notes--note 1) :comments) (list reply)))
      (should (= (length (agent-notes--pending-comments)) 2))
      (should (string-match-p "NEW" (agent-notes--reply-prompt (agent-notes--notes)
                                                               (agent-notes--pending-comments))))
      (agent-notes--apply-replies
       `(:replies ((:note 1 :body "Agreed." :resolve t)
                   (:note ,(plist-get mine :id) :body "Because." :resolve nil)))
       (agent-notes--pending-comments))
      (should (null (agent-notes--pending-comments)))
      (should (agent-notes--resolved-p (agent-notes--note 1)))
      (should (= (length (plist-get (agent-notes--note (plist-get mine :id)) :comments)) 2)))
    ;; Resolved notes are folded when first shown.
    (agent-notes--render)
    (should (oref (agent-notes--note-section 1) hidden))
    ;; Everything survives a save and reload.
    (agent-notes--save)
    (agent-notes--reload)
    (should (= (length (agent-notes--notes)) 4))
    (should (equal (plist-get (car (plist-get agent-notes--review :summaries)) :text)
                   "Adds a disabled check."))
    (should (equal (plist-get (car (agent-notes--notes)) :path) "src/auth.py"))))

(ert-deftest agent-notes-test-side-by-side ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "old" :severity "issue" :body "Old side")
               (:path "src/auth.py" :line 11 :side "new" :severity "info" :body "New side")))
     "Review")
    (agent-notes-toggle-view)
    (should (eq agent-notes--view 'split))
    ;; The removed and the added line share a row, each half with its record.
    (goto-char (agent-notes--find-prop 'agent-notes-loc
                                       (agent-notes--exact-record '(:path "src/auth.py" :side "old" :line 11))))
    (let ((row-start (point)))
      (should (eq (plist-get (get-text-property row-start 'agent-notes-loc) :kind) 'removed))
      (should (eq (plist-get (get-text-property (+ row-start agent-notes--half 2) 'agent-notes-loc) :kind)
                  'added))
      ;; Rows are no wider than the window.
      (should (<= (- (line-end-position) row-start) agent-notes--width)))
    ;; Both notes are below that row.
    (should (equal (plist-get (agent-notes-tests--line-before-note 1) :kind) 'removed))
    (should (eql (save-excursion (forward-line 1) (get-text-property (point) 'agent-notes-note)) 1))
    ;; Each note sits in the column of its side, and long text wraps in it.
    (cl-flet ((note-lines (id)
                (let ((section (agent-notes--note-section id)))
                  (split-string (buffer-substring-no-properties (oref section start)
                                                                (1- (oref section end)))
                                "\n"))))
      (let ((half agent-notes--half))
        (dolist (line (note-lines 1))
          (should (string-suffix-p "│" line))
          (should (<= (string-width line) (+ half 2))))
        (dolist (line (note-lines 2))
          (should (string-prefix-p (concat (make-string half ?\s) "│") line))
          (should (<= (string-width line) (+ half 2 half))))))
    (agent-notes-tests--add-comment 2 (mapconcat #'identity (make-list 40 "word") " "))
    (agent-notes--render)
    (let ((section (agent-notes--note-section 2)))
      (should (string-search "word word" (buffer-substring (oref section start) (oref section end))))
      (dolist (line (split-string (buffer-substring-no-properties (oref section start)
                                                                  (1- (oref section end)))
                                  "\n"))
        ;; The fill is one space that is displayed up to the column's edge.
        (should (<= (string-width line) (+ agent-notes--half 2 agent-notes--half)))))
    (agent-notes-toggle-view)
    (should (eq agent-notes--view 'unified))))

(defun agent-notes-tests--add-comment (id body)
  "Add an unsent comment BODY to the note ID."
  (let ((note (agent-notes--note id)))
    (plist-put note :comments (append (plist-get note :comments)
                                      (list (agent-notes--make-comment "you" body "pending"))))))

(ert-deftest agent-notes-test-note-faces-keep-background ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :severity "info"
                :body "Text with `code` and **bold**.")))
     "Review")
    (agent-notes--render)
    (let ((section (agent-notes--note-section 1)))
      (cl-loop for pos from (oref section start) below (oref section end)
               for faces = (ensure-list (get-text-property pos 'font-lock-face))
               do (should-not (memq 'default faces))))))

(ert-deftest agent-notes-test-keys ()
  (should (eq (keymap-lookup agent-notes-mode-map "r") #'agent-notes-toggle-resolved))
  (should (eq (keymap-lookup agent-notes-mode-map "R") #'agent-notes-reply)))

(ert-deftest agent-notes-test-reanchor ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :body "Moves down")
               (:path "src/auth.py" :line 11 :side "old" :body "Old line numbers don't change")
               (:path "new.txt" :line 1 :side "new" :body "Goes away")))
     "Review")
    (pcase-let ((`(,moved . ,outdated)
                 (agent-notes--resnapshot (list agent-notes-tests--diff-2 "HEAD" "def" "def"))))
      (should (= moved 1))
      (should (= outdated 1)))
    (should (equal (plist-get (agent-notes--note 1) :line) 13))
    (should (equal (plist-get (agent-notes--note 2) :line) 11))
    (should (plist-get (agent-notes--note 3) :outdated))
    (should (equal (plist-get agent-notes--review :base_rev) "def"))
    ;; The new snapshot is on disk and the outdated flag survives a reload.
    (agent-notes--reload)
    (should (equal (plist-get (agent-notes--note 1) :line) 13))
    (should (plist-get (agent-notes--note 3) :outdated))
    (should (string-match-p "outdated" (buffer-string)))
    (should (equal (plist-get (agent-notes-tests--line-before-note 1) :text)
                   "+    if user.disabled:"))))

(ert-deftest agent-notes-test-migrate-summary ()
  (agent-notes-tests--with-review '(:summary "Old summary.")
    (should (equal (plist-get (car (plist-get agent-notes--review :summaries)) :text)
                   "Old summary."))
    (agent-notes--save)
    (should-not (string-match-p "\"summary\"" (agent-notes--read-file agent-notes--file)))))

(ert-deftest agent-notes-test-prompts-and-permissions ()
  (agent-notes-tests--with-review nil
    (let ((overview (assoc "Overview" agent-notes-tasks)))
      (should overview)
      (let ((prompt (agent-notes--task-prompt overview)))
        (should (string-search (cdr overview) prompt))
        (should (string-search "\"info\"" prompt))
        (should (string-search "```json" prompt)))
      (let ((agent-notes-extra-instructions "Use tabs."))
        (should (string-search "Use tabs." (agent-notes--task-prompt overview))))
      (let ((prompt (agent-notes--task-prompt '("Mine" . "Explain the tests only."))))
        (should (string-search "Explain the tests only." prompt))
        (should-not (string-search "meticulous" prompt))))
    (let ((agent-notes-allow-edits t))
      (should (member "--allow-tool=write" (agent-notes--copilot-args '(:prompt "x"))))
      (should-not (member "--deny-tool=write" (agent-notes--copilot-args '(:prompt "x"))))
      (should (string-search "edit files" (agent-notes--reply-prompt nil nil))))
    (let ((agent-notes-allow-edits nil))
      (should (member "--deny-tool=write" (agent-notes--copilot-args '(:prompt "x"))))
      (should-not (member "--allow-tool=write" (agent-notes--copilot-args '(:prompt "x"))))
      (should (string-search "cannot modify files" (agent-notes--reply-prompt nil nil))))
    (let ((args (agent-notes--copilot-args '(:prompt "the prompt" :session "s1"))))
      (should (equal (last args 2) '("-p" "the prompt")))
      (should (equal (cadr (member "--session-id" args)) "s1")))
    (let ((agent-notes-diagram-format 'graphviz))
      (should (string-search "```dot" (agent-notes--task-prompt '("Mine" . "x"))))
      (should (string-search "```dot" (agent-notes--reply-prompt nil nil))))
    (let ((agent-notes-diagram-format 'text))
      (should (string-search "```text" (agent-notes--task-prompt '("Mine" . "x"))))
      (should-not (string-search "```dot" (agent-notes--task-prompt '("Mine" . "x")))))
    (should (string-search "\"original\"" (agent-notes--task-prompt '("Mine" . "x"))))))

(ert-deftest agent-notes-test-prompt-context ()
  (agent-notes-tests--with-review nil
    ;; Tasks get the changed files and, when small, the whole diff.
    (let ((prompt (agent-notes--task-prompt '("Mine" . "x"))))
      (should (string-search "Changed files (2 files, +3 −1):" prompt))
      (should (string-search "- src/auth.py  +2 -1\n" prompt))
      (should (string-search "- new.txt  +1 -0 (added)\n" prompt))
      (should (string-search "```diff\ndiff --git a/src/auth.py" prompt))
      (should (string-search "+hello\n```\n" prompt)))
    (let* ((agent-notes-inline-diff-limit 10)
           (prompt (agent-notes--task-prompt '("Mine" . "x"))))
      (should-not (string-search "```diff" prompt))
      (should (string-search "The diff is large" prompt)))
    (should (equal (agent-notes--fence-for "+```elisp\n") "````"))
    ;; Replies get the files, the code around each thread, but not the diff.
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :body "Why?"))) "Review")
    (let ((prompt (agent-notes--reply-prompt (agent-notes--notes) nil)))
      (should (string-search "Changed files" prompt))
      (should-not (string-search "```diff" prompt))
      (should (string-search "   @@ -10,4 +10,5 @@ def login(user):\n" prompt))
      (should (string-search "      10    10      token = make_token(user)\n" prompt))
      (should (string-search "      11       -    log(token)\n" prompt))
      (should (string-search ">>          11 +    if user.disabled:\n" prompt))
      (should (string-search "      12    13      return token\n" prompt)))
    (let* ((agent-notes-thread-context-lines 1)
           (prompt (agent-notes--reply-prompt (agent-notes--notes) nil)))
      (should (string-search "   ...\n      11       -" prompt))
      (should (string-search "return None\n   ...\n" prompt)))))

(ert-deftest agent-notes-test-general-note ()
  (agent-notes-tests--with-review nil
    (agent-notes--add-note "you" "" "new" 0 "" "Overall question" "pending")
    (agent-notes--render)
    (should (eq (oref (oref (agent-notes--note-section 1) parent) type) 'agent-notes-general))
    (should (string-search "about the whole change"
                           (agent-notes--reply-prompt (agent-notes--notes)
                                                      (agent-notes--pending-comments))))))

(ert-deftest agent-notes-test-features ()
  (dolist (feature '(agent-notes-core agent-notes-diff agent-notes-render
                     agent-notes-log agent-notes-agent agent-notes))
    (should (featurep feature)))
  ;; The Magit part is loaded exactly when Magit is.
  (should (eq (and (featurep 'magit) t) (and (featurep 'agent-notes-magit) t))))

(ert-deftest agent-notes-test-navigation-skips-resolved ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :body "A")
               (:path "src/auth.py" :line 13 :side "new" :body "B")
               (:path "new.txt" :line 1 :side "new" :body "C")))
     "Review")
    (plist-put (agent-notes--note 2) :status "resolved")
    (agent-notes--render)
    (cl-flet ((at () (get-text-property (point) 'agent-notes-note)))
      (goto-char (point-min))
      (agent-notes-next-note)
      (should (eql (at) 1))
      (agent-notes-next-note)
      (should (eql (at) 3))
      (agent-notes-next-note)
      (should (eql (at) 1))
      ;; With a prefix argument, resolved notes count too.
      (agent-notes-next-note '(4))
      (should (eql (at) 2))
      (agent-notes-previous-note)
      (should (eql (at) 1))
      ;; The list still offers every note.
      (should (= (length (agent-notes--notes)) 3)))
    (dolist (note (agent-notes--notes))
      (plist-put note :status "resolved"))
    (agent-notes--render)
    (should-error (agent-notes-next-note) :type 'user-error)
    (should (string-search "All notes are resolved" (buffer-string)))
    (should (string-search "all 3 resolved" (agent-notes--header-line)))))

(defun agent-notes-tests--faces-at (pos)
  "Return the faces at POS as a list."
  (ensure-list (get-text-property pos 'font-lock-face)))

(ert-deftest agent-notes-test-cursor-stays-in-note-column ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :severity "info"
                :body "First line\n\nSecond line")
               (:path "src/auth.py" :line 11 :side "old" :severity "info" :body "Old")))
     "Review")
    (agent-notes-toggle-view)
    (let ((right (1+ agent-notes--half)))
      ;; A note on the right starts after the empty left half.
      (agent-notes--goto-note 1)
      (should (= (current-column) right))
      (should (= (point) (agent-notes--pane-start)))
      ;; Jumping with n lands in the same place, for both columns.
      (goto-char (point-min))
      (let ((columns (list (progn (agent-notes-next-note) (current-column))
                           (progn (agent-notes-next-note) (current-column)))))
        (should (equal (sort columns #'<) (list 0 right))))
      ;; Moving past the end of a line stays in the column, and back.
      (agent-notes--goto-note 1)
      (end-of-line)
      (let ((line (line-number-at-pos)))
        (agent-notes-forward-char)
        (should (= (line-number-at-pos) (1+ line)))
        (should (= (current-column) right))
        (agent-notes-backward-char)
        (should (= (line-number-at-pos) line))
        (should (eolp)))
      (agent-notes-beginning-of-line)
      (should (= (current-column) right))
      ;; A note on the left starts at the edge, as usual.
      (agent-notes--goto-note 2)
      (should (= (current-column) 0))
      (end-of-line)
      (agent-notes-forward-char)
      (should (= (current-column) 0)))))

(defvar agent-notes-tests--recentered nil
  "The row `recenter' was last asked for in a test.")

(ert-deftest agent-notes-test-note-is-centered ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 12 :side "new" :body "A")))
     "Review")
    (agent-notes--render)
    (save-window-excursion
      (set-window-buffer (selected-window) (current-buffer))
      (cl-letf (((symbol-function 'recenter)
                 (lambda (row &rest _) (setq agent-notes-tests--recentered row))))
        (setq agent-notes-tests--recentered nil)
        (goto-char (point-min))
        (agent-notes-next-note)
        (should (natnump agent-notes-tests--recentered))
        (setq agent-notes-tests--recentered nil)
        (let ((agent-notes-center-on-note nil))
          (agent-notes-next-note)
          (should-not agent-notes-tests--recentered))))))

(ert-deftest agent-notes-test-syntax-highlighting ()
  (agent-notes-tests--with-review nil
    (dolist (view '(unified split))
      (setq agent-notes--view view)
      (agent-notes--render)
      (goto-char (point-min))
      (search-forward "+    if user.disabled:")
      (let ((if-pos (- (point) (length "if user.disabled:"))))
        ;; Python keywords keep their color; the line is marked by a background.
        (should (memq 'font-lock-keyword-face (agent-notes-tests--faces-at if-pos)))
        (should (memq 'agent-notes-added-bg (agent-notes-tests--faces-at if-pos)))
        ;; The + sign has the usual diff face.
        (should (memq 'agent-notes-added (agent-notes-tests--faces-at (- if-pos 5)))))
      (search-forward "return token")
      (should-not (memq 'agent-notes-added-bg
                        (agent-notes-tests--faces-at (match-beginning 0)))))
    (let ((agent-notes-syntax-highlighting nil))
      (setq agent-notes--syntax-cache nil)
      (agent-notes--render)
      (goto-char (point-min))
      (search-forward "+    if user.disabled:")
      (should (equal (agent-notes-tests--faces-at (1- (point))) '(agent-notes-added))))))

(ert-deftest agent-notes-test-line-numbers ()
  (agent-notes-tests--with-review nil
    (let ((rec (agent-notes--exact-record '(:path "src/auth.py" :side "new" :line 11))))
      (cl-flet ((goto-rec () (goto-char (agent-notes--find-prop 'agent-notes-loc rec))))
        (goto-rec)
        (should (looking-at " +11 \\+    if"))
        (agent-notes-toggle-line-numbers)
        (goto-rec)
        (should (looking-at "\\+    if"))
        (should (= (length agent-notes--pad) 2))
        ;; Side by side: the row starts with the removed line, no number.
        (agent-notes-toggle-view)
        (goto-char (agent-notes--find-prop
                    'agent-notes-loc
                    (agent-notes--exact-record '(:path "src/auth.py" :side "old" :line 11))))
        (should (looking-at "-    log(token)"))
        (agent-notes-toggle-line-numbers)
        (should (> agent-notes--gutter 0))))))

(ert-deftest agent-notes-test-diagram-does-not-wrap ()
  (agent-notes-tests--with-review nil
    (agent-notes--apply-review
     `(:summary ,(concat "Overview:\n```text\n┌──┐\n" (make-string 300 ?x) "\n└──┘\n```\nDone.")
       :notes nil)
     "Diagram")
    (agent-notes--render)
    (should (string-search "┌──┐" (buffer-string)))
    (goto-char (point-min))
    (search-forward "xxx")
    (should (<= (- (line-end-position) (line-beginning-position)) agent-notes--width))
    (should (string-suffix-p "…" (buffer-substring (line-beginning-position) (line-end-position))))))

;;;; Tests with a real git repository

(defconst agent-notes-tests--auth-old
  (concat (mapconcat (lambda (i) (format "# line %d\n" i)) (number-sequence 1 9) "")
          "    token = make_token(user)\n    log(token)\n    return token\n"))

(defconst agent-notes-tests--auth-new
  (concat (mapconcat (lambda (i) (format "# line %d\n" i)) (number-sequence 1 9) "")
          "    token = make_token(user)\n    if user.disabled:\n        return None\n    return token\n"))

(defmacro agent-notes-tests--with-repo (&rest body)
  "Run BODY in a new review of a scratch git repository.
In the repository, src/auth.py is changed as in `agent-notes-tests--diff'.
BODY can use `root' and `tmp', a directory outside the repository."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "agent-notes-repo" t))))
          (tmp (file-name-as-directory (make-temp-file "agent-notes-tmp" t)))
          (default-directory root)
          (process-environment (append '("GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                                         "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                                       process-environment)))
     (unwind-protect
         (progn
           (make-directory "src")
           (agent-notes--write-file "src/auth.py" agent-notes-tests--auth-old)
           (agent-notes--git "init" "-q")
           (agent-notes--git "add" ".")
           (agent-notes--git "-c" "commit.gpgsign=false" "commit" "-q" "--no-verify" "-m" "init")
           (agent-notes--write-file "src/auth.py" agent-notes-tests--auth-new)
           (with-current-buffer (agent-notes--create-review "working" nil)
             (unwind-protect (progn ,@body)
               (let ((file-buf (find-buffer-visiting (expand-file-name "src/auth.py" root))))
                 (when file-buf
                   (with-current-buffer file-buf (set-buffer-modified-p nil))
                   (kill-buffer file-buf)))
               (when (process-live-p agent-notes--process)
                 (delete-process agent-notes--process))
               (kill-buffer))))
       (delete-directory root t)
       (delete-directory tmp t))))

(defun agent-notes-tests--fake-agent (dir answer &optional shell)
  "Write a fake Copilot to DIR and return its file name.
It runs SHELL, prints ANSWER and ignores its arguments."
  (let ((file (expand-file-name "fake-copilot" dir)))
    (agent-notes--write-file file (concat "#!/bin/sh\n" (or shell "") "\ncat <<'EOF'\n" answer "\nEOF\n"))
    (set-file-modes file #o755)
    file))

(defun agent-notes-tests--wait ()
  "Wait until the agent of the current review buffer is done."
  (let ((start (float-time)))
    (while (and agent-notes--status (< (- (float-time) start) 30))
      (accept-process-output nil 0.05))))

(defun agent-notes-tests--stages ()
  "Return the stages of the log entries of the current review."
  (mapcar (lambda (e) (plist-get e :stage)) agent-notes--log-entries))

(ert-deftest agent-notes-test-apply-suggestion ()
  (agent-notes-tests--with-repo
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :end_line 12 :side "new" :body "Locked users too"
                :suggestion "    if user.disabled or user.locked:\n        return None\n")
               (:path "src/auth.py" :line 10 :side "new" :body "Name it"
                :suggestion "    session_token = make_token(user)")
               (:path "src/auth.py" :line 11 :side "old" :body "Old side"
                :suggestion "ignored")))
     "Review")
    (agent-notes--render)
    (should (equal (plist-get (agent-notes--note 1) :original)
                   "    if user.disabled:\n        return None"))
    (should (= (plist-get (agent-notes--note 1) :span) 2))
    (should-not (plist-get (agent-notes--note 3) :suggestion))
    (should (string-search "Suggested change" (buffer-string)))
    (should (string-search "+    if user.disabled or user.locked:" (buffer-string)))
    ;; The file no longer has the code the second suggestion is for.
    (agent-notes--write-file "src/auth.py"
                             (replace-regexp-in-string "make_token" "new_token"
                                                       agent-notes-tests--auth-new))
    (agent-notes--goto-note 2)
    (should-error (agent-notes-apply-suggestion) :type 'user-error)
    (kill-buffer (find-buffer-visiting (expand-file-name "src/auth.py" root)))
    (agent-notes--write-file "src/auth.py" agent-notes-tests--auth-new)
    ;; Apply the first one.
    (agent-notes--goto-note 1)
    (agent-notes-apply-suggestion)
    (should (string-search "    token = make_token(user)\n    if user.disabled or user.locked:\n        return None\n    return token\n"
                           (agent-notes--read-file "src/auth.py")))
    (should (plist-get (agent-notes--note 1) :applied))
    (should (agent-notes--resolved-p (agent-notes--note 1)))
    (should (string-search "+    if user.disabled or user.locked:" (agent-notes--stored-diff)))
    (should (string-search "suggestion applied" (buffer-string)))
    (should (equal (car (last (agent-notes-tests--stages))) "You"))
    (agent-notes--goto-note 1)
    (should-error (agent-notes-apply-suggestion) :type 'user-error)))

(ert-deftest agent-notes-test-suggestion-with-context ()
  (agent-notes-tests--with-repo
    ;; The agent repeats line 10 for context and says so in "original";
    ;; trailing spaces in "original" don't matter.
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :body "Locked"
                :original "    token = make_token(user)  \n    if user.disabled:"
                :suggestion "    token = make_token(user)\n    if user.disabled or user.locked:")
               ;; Without "original": the repeated line 10 is absorbed.
               (:path "src/auth.py" :line 11 :end_line 12 :side "new" :body "Legacy"
                :suggestion "    token = make_token(user)\n    if user.locked:\n        return None")
               ;; Repeated lines below the region are absorbed too.
               (:path "src/auth.py" :line 11 :side "new" :body "Below"
                :suggestion "    if x:\n        return None\n    return token")))
     "Review")
    (should (equal (plist-get (agent-notes--note 1) :original)
                   "    token = make_token(user)\n    if user.disabled:"))
    (should (equal (plist-get (agent-notes--note 2) :original)
                   "    token = make_token(user)\n    if user.disabled:\n        return None"))
    (should (equal (plist-get (agent-notes--note 3) :original)
                   "    if user.disabled:\n        return None\n    return token"))
    (agent-notes--render)
    (agent-notes--goto-note 1)
    (agent-notes-apply-suggestion)
    (should (equal (agent-notes--read-file "src/auth.py")
                   (replace-regexp-in-string "user.disabled:" "user.disabled or user.locked:"
                                             agent-notes-tests--auth-new)))))

(ert-deftest agent-notes-test-suggestion-not-found ()
  (agent-notes-tests--with-repo
    (let ((result (agent-notes--apply-review
                   '(:notes ((:path "src/auth.py" :line 11 :side "new" :body "Gone"
                              :original "    if user.banned:"
                              :suggestion "    if user.banned or user.locked:")))
                   "Review")))
      (should-not (plist-get (agent-notes--note 1) :suggestion))
      (should (string-search "Ignored the suggested change of #1" result)))))

(ert-deftest agent-notes-test-suggestion-sanity-checks ()
  (agent-notes-tests--with-repo
    (agent-notes--apply-review
     '(:notes ((:path "src/auth.py" :line 11 :side "new" :body "Duplicates line 10"
                :original "    if user.disabled:"
                :suggestion "    token = make_token(user)\n    if user.locked:")
               (:path "src/auth.py" :line 11 :side "new" :body "Unbalanced"
                :original "    if user.disabled:"
                :suggestion "    if (user.disabled:")))
     "Review")
    (agent-notes--render)
    (let ((asked nil))
      ;; Refused: the file is left as it was.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) nil)))
        (agent-notes--goto-note 1)
        (should-error (agent-notes-apply-suggestion) :type 'user-error)
        (should (string-search "would appear twice" asked))
        (should (equal (agent-notes--read-file "src/auth.py") agent-notes-tests--auth-new))
        (should-not (buffer-modified-p (find-buffer-visiting (expand-file-name "src/auth.py" root))))
        (should-not (plist-get (agent-notes--note 1) :applied))
        (agent-notes--goto-note 2)
        (should-error (agent-notes-apply-suggestion) :type 'user-error)
        (should (string-search "brackets" asked)))
      ;; Accepted: applied anyway.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
        (agent-notes--goto-note 2)
        (agent-notes-apply-suggestion)
        (should (string-search "if (user.disabled:" (agent-notes--read-file "src/auth.py")))
        (should (plist-get (agent-notes--note 2) :applied))))))

(ert-deftest agent-notes-test-graphviz-diagrams ()
  (let ((text "Intro\n```dot\ndigraph { a -> b }\n```\nAfter"))
    ;; Without image support, the source is shown and RET can open it.
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-notes--diagram-images-p) #'ignore))
        (agent-notes--insert-markdown text 'default "  " t))
      (should (string-search "digraph { a -> b }" (buffer-string)))
      (should (string-search "After" (buffer-string)))
      (goto-char (point-min))
      (search-forward "digraph")
      (should (equal (get-text-property (point) 'agent-notes-diagram) "digraph { a -> b }")))
    ;; With images, the diagram is an image.
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-notes--diagram-images-p) (lambda () t))
                ((symbol-function 'agent-notes--render-dot)
                 (lambda (_source) "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")))
        (agent-notes--insert-markdown text 'default "  " t))
      (should-not (string-search "digraph" (buffer-string)))
      (goto-char (point-min))
      (let ((match (text-property-search-forward 'display nil (lambda (_ v) v))))
        (should match)
        (should (eq (car-safe (prop-match-value match)) 'image))
        (should (equal (get-text-property (prop-match-beginning match) 'agent-notes-diagram)
                       "digraph { a -> b }")))))
  (when (executable-find agent-notes-dot-program)
    (should (string-search "<svg" (agent-notes--render-dot "digraph { a -> b }")))
    (should-not (agent-notes--render-dot "this is not dot"))))

(ert-deftest agent-notes-test-fake-agent-run-and-log ()
  (agent-notes-tests--with-repo
    (let ((agent-notes-copilot-program
           (agent-notes-tests--fake-agent
            tmp (concat "I looked at it.\n```json\n"
                        "{\"summary\": \"Adds a check.\\n```text\\n[a] --> [b]\\n```\","
                        " \"notes\": [{\"path\": \"src/auth.py\", \"line\": 11, \"side\": \"new\","
                        " \"severity\": \"warning\", \"body\": \"Locked users?\","
                        " \"suggestion\": \"    if user.disabled or user.locked:\"}]}\n```"))))
      (agent-notes--start-task (assoc "Overview" agent-notes-tasks))
      (should agent-notes--status)
      (should (string-search "Overview" (agent-notes--header-line)))
      (agent-notes-tests--wait)
      (should-not agent-notes--status)
      (should (= (length (agent-notes--notes)) 1))
      (should (equal (plist-get (agent-notes--note 1) :original) "    if user.disabled:"))
      (should (string-search "[a] --> [b]" (buffer-string)))
      (should (equal (agent-notes-tests--stages) '("Started" "Sent" "Done" "Applied")))
      (should (equal (plist-get (car (last agent-notes--log-entries)) :text)
                     "Added 1 note (1 with a suggested change) and a summary."))
      ;; The log buffer shows the entries, with the details folded.
      (agent-notes-show-log)
      (with-current-buffer (agent-notes--log-buffer-name)
        (let ((text (buffer-string)))
          (should (string-search "Copilot answered after" text))
          (should (string-search "Raw answer" text)))
        (kill-buffer)))
    ;; A reply that makes the agent edit the file.
    (let ((agent-notes-copilot-program
           (agent-notes-tests--fake-agent
            tmp (concat "```json\n{\"replies\": [{\"note\": 1, \"body\": \"Done.\", \"resolve\": true},"
                        " {\"note\": 99, \"body\": \"?\"}]}\n```")
            "printf '# edited\\n' >> src/auth.py")))
      (let* ((comment (agent-notes--make-comment "you" "Please fix it." "pending"))
             (ids (list (plist-get comment :id))))
        (plist-put (agent-notes--note 1) :comments
                   (append (plist-get (agent-notes--note 1) :comments) (list comment)))
        (agent-notes--run "replying" (agent-notes--reply-prompt (agent-notes--notes) ids)
                          #'agent-notes--apply-replies ids))
      (agent-notes-tests--wait)
      (should (equal agent-notes--changes '("src/auth.py")))
      (should (string-search "+# edited" (agent-notes--stored-diff)))
      (should (agent-notes--resolved-p (agent-notes--note 1)))
      (should (null (agent-notes--pending-comments)))
      (should (member "Changes" (agent-notes-tests--stages)))
      (should (string-search "Ignored replies to notes that don't exist: 99"
                             (plist-get (car (last agent-notes--log-entries)) :text))))
    ;; A failing agent is logged with its output.
    (let ((agent-notes-copilot-program (expand-file-name "failing-copilot" tmp)))
      (agent-notes--write-file agent-notes-copilot-program
                               "#!/bin/sh\necho 'Error: not signed in' >&2\nexit 3\n")
      (set-file-modes agent-notes-copilot-program #o755)
      (agent-notes--start-task '("Mine" . "Explain."))
      (agent-notes-tests--wait)
      (let ((last (car (last agent-notes--log-entries))))
        (should (equal (plist-get last :stage) "Failed"))
        (should (string-search "code 3" (plist-get last :text)))
        (should (string-search "not signed in" (plist-get last :text)))))))

(ert-deftest agent-notes-test-cursor-stays-in-code-column ()
  (agent-notes-tests--with-review nil
    (agent-notes-toggle-view)
    (let ((right (1+ agent-notes--half)))
      ;; Right column: the end of the text, then on to the next row's right half.
      (goto-char (point-min))
      (search-forward "+    if user.disabled:")
      (agent-notes-end-of-line)
      (should (eolp))
      (let ((line (line-number-at-pos)))
        (agent-notes-forward-char)
        (should (= (line-number-at-pos) (1+ line)))
        (should (= (current-column) right))
        (should (looking-at " *[0-9]* *\\+ +return None"))
        (agent-notes-backward-char)
        (should (= (line-number-at-pos) line))
        (should (eolp))
        (agent-notes-beginning-of-line)
        (should (= (current-column) right)))
      ;; Left column: stays left, at the edge of its half.
      (goto-char (point-min))
      (search-forward "token = make_token(user)")
      (agent-notes-end-of-line)
      (should (= (current-column) agent-notes--half))
      (let ((line (line-number-at-pos)))
        (agent-notes-forward-char)
        (should (= (line-number-at-pos) (1+ line)))
        (should (= (current-column) 0))
        (should (looking-at " *[0-9]* *-    log(token)"))
        (agent-notes-backward-char)
        (should (= (line-number-at-pos) line))
        (should (= (current-column) agent-notes--half))
        (agent-notes-beginning-of-line)
        (should (= (current-column) 0)))
      ;; Inside the text, the keys are plain.
      (search-forward "make")
      (agent-notes-forward-char)
      (agent-notes-backward-char)
      (should (looking-at "_token")))))

(ert-deftest agent-notes-test-notify-default-macos ()
  (let ((system-type 'darwin)
        (agent-notes--bundle-id "org.example.Emacs")
        (installed nil)
        (calls nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program &rest _) (and (member program installed) program)))
              ((symbol-function 'agent-notes--run-notifier)
               (lambda (program &rest args) (push (cons program args) calls) 0)))
      ;; terminal-notifier: clicking brings Emacs to the front.
      (setq installed '("terminal-notifier" "osascript"))
      (agent-notes-notify-default "Title" "Body")
      (should (equal (caar calls) "terminal-notifier"))
      (should (member "org.example.Emacs" (car calls)))
      (should (member "-activate" (car calls)))
      ;; Otherwise osascript, with the text as arguments.
      (setq installed '("osascript") calls nil)
      (agent-notes-notify-default "Title" "Body \"quoted\"")
      (should (equal (caar calls) "osascript"))
      (should (equal (last (car calls) 2) '("Title" "Body \"quoted\""))))))

(ert-deftest agent-notes-test-notification ()
  (agent-notes-tests--with-repo
    (let* ((sent nil)
           (agent-notes-notify 'always)
           (agent-notes-notify-function (lambda (title body) (push (list title body) sent)))
           (agent-notes-copilot-program
            (agent-notes-tests--fake-agent
             tmp "```json\n{\"summary\": \"ok\", \"notes\": []}\n```")))
      (cl-flet ((run ()
                  (setq sent nil)
                  (agent-notes--start-task (assoc "Overview" agent-notes-tasks))
                  (agent-notes-tests--wait)))
        (run)
        (should (= (length sent) 1))
        (should (equal (car (car sent)) "Agent Notes: Overview done"))
        (should (string-search "Copilot answered after" (cadr (car sent))))
        (let ((agent-notes-notify nil))
          (run)
          (should-not sent))
        (let ((agent-notes-notify 'unfocused))
          (cl-letf (((symbol-function 'agent-notes--emacs-focused-p) (lambda () t)))
            (run)
            (should-not sent))
          (cl-letf (((symbol-function 'agent-notes--emacs-focused-p) (lambda () nil)))
            (run)
            (should (= (length sent) 1))))
        ;; Failures are announced too; a broken notifier is not an error.
        (let ((agent-notes-copilot-program (expand-file-name "failing-copilot" tmp)))
          (agent-notes--write-file agent-notes-copilot-program "#!/bin/sh\nexit 3\n")
          (set-file-modes agent-notes-copilot-program #o755)
          (run)
          (should (equal (car (car sent)) "Agent Notes: Overview failed"))
          (let ((agent-notes-notify-function (lambda (_title _body) (error "No bus"))))
            (run)
            (should-not agent-notes--status)))))))

;;;; Diff sources

(ert-deftest agent-notes-test-ranges-and-labels ()
  (should (equal (agent-notes--parse-range "main..feature") '("main" "feature" nil)))
  (should (equal (agent-notes--parse-range "main...feature") '("main" "feature" t)))
  (should (equal (agent-notes--parse-range "HEAD~3..") '("HEAD~3" "HEAD" nil)))
  (should (equal (agent-notes--parse-range "abc^..def") '("abc^" "def" nil)))
  (should-not (agent-notes--parse-range "HEAD~2"))
  (should (equal (agent-notes--commit-scope "a..b") '("range" "a..b")))
  (should (equal (agent-notes--commit-scope "HEAD") '("commit" "HEAD")))
  (should (equal (agent-notes--scope-label
                  (list :scope "commit" :base (make-string 40 ?a) :subject "Fix it"))
                 "Commit aaaaaaa Fix it"))
  (should (equal (agent-notes--scope-label '(:scope "range" :base "a..b")) "Range a..b"))
  (should (equal (agent-notes--scope-label '(:scope "staged")) "Staged vs HEAD"))
  (should (equal (agent-notes--scope-label '(:scope "working")) "Working tree vs HEAD")))

(ert-deftest agent-notes-test-diff-sources ()
  (agent-notes-tests--with-repo
    (cl-flet ((diff (scope &optional base) (car (agent-notes--make-diff scope base))))
      ;; Staged: only what is in the index.
      (should (string-empty-p (diff "staged")))
      (agent-notes--git "add" "src/auth.py")
      (should (string-search "+    if user.disabled:" (diff "staged")))
      (agent-notes--git "-c" "commit.gpgsign=false" "commit" "-q" "--no-verify"
                        "-m" "Check disabled users")
      (should (string-empty-p (diff "staged")))
      (let ((head (agent-notes--git-try "rev-parse" "HEAD"))
            (parent (agent-notes--git-try "rev-parse" "HEAD~1")))
        ;; A commit is stored by its id, so the review keeps showing it.
        (pcase-let ((`(,d ,label ,base-rev ,head-rev) (agent-notes--make-diff "commit" "HEAD")))
          (should (string-search "+    if user.disabled:" d))
          (should (equal (list label base-rev head-rev) (list head parent head))))
        ;; The first commit is compared with the empty tree.
        (should (string-search "new file mode" (diff "commit" "HEAD~1")))
        (should (equal (nth 2 (agent-notes--make-diff "commit" "HEAD~1")) agent-notes--empty-tree))
        ;; Ranges, kept as typed.
        (should (equal (diff "range" "HEAD~1..HEAD") (diff "commit" "HEAD")))
        (should (equal (diff "range" "HEAD~1...HEAD") (diff "commit" "HEAD")))
        (should (equal (cadr (agent-notes--make-diff "range" "HEAD~1..")) "HEAD~1.."))
        (should-error (diff "commit" "no-such-rev") :type 'user-error)
        ;; A review of the commit.
        (let ((buf (agent-notes--create-review "commit" "HEAD")))
          (unwind-protect
              (with-current-buffer buf
                (should (equal (agent-notes--scope-label agent-notes--review)
                               (concat "Commit " (substring head 0 7) " Check disabled users")))
                (let ((prompt (agent-notes--task-prompt '("Mine" . "x"))))
                  (should (string-search (format "the changes made by commit %s" head) prompt))
                  (should (string-search (format "git show %s:PATH" head) prompt)))
                ;; The agent's edits are noticed, although they are not in the diff.
                (let ((before (agent-notes--edit-fingerprints agent-notes--review)))
                  (agent-notes--write-file "src/auth.py"
                                           (concat "# a\n# b\n" agent-notes-tests--auth-new))
                  (should (string-search "in the working tree" (agent-notes--detect-changes before)))
                  (should (equal agent-notes--changes '("src/auth.py")))
                  (should (string-search "not in its diff"
                                         (plist-get (car (last agent-notes--log-entries)) :text)))
                  (should-not (string-search "# a" (agent-notes--stored-diff))))
                ;; Visiting finds the line, two lines lower now.
                (goto-char (agent-notes--find-prop
                            'agent-notes-loc
                            (agent-notes--exact-record '(:path "src/auth.py" :side "new" :line 11))))
                (agent-notes-visit)
                (should (= (line-number-at-pos) 13))
                (should (looking-at "    if user.disabled:")))
            (kill-buffer buf)))))))

;;;; Other agents

(ert-deftest agent-notes-test-agent-args ()
  (agent-notes-tests--with-review nil
    (cl-letf (((symbol-function 'agent-notes--claude-session-p) #'ignore))
      (let* ((agent-notes-allow-edits t)
             (agent-notes-allowed-tools '("shell(git diff)" "shell" "WebFetch"))
             (agent-notes-denied-tools nil)
             (args (agent-notes--claude-args '(:prompt "p" :session "s1"))))
        (should (equal (cadr (member "--session-id" args)) "s1"))
        (should-not (member "--resume" args))
        (should-not (member "p" args))
        (should (equal (cadr (member "--permission-mode" args)) "acceptEdits"))
        (should (equal (cdr (member "--allowedTools" args))
                       '("Bash(git diff:*)" "Bash" "WebFetch")))
        (should-not (member "--disallowedTools" args)))
      (let* ((agent-notes-allow-edits nil)
             (args (agent-notes--claude-args '(:prompt "p" :session "s1" :resume t))))
        (should (equal (cadr (member "--resume" args)) "s1"))
        (should-not (member "--session-id" args))
        (should (member "Edit" (member "--disallowedTools" args)))
        (should (equal (cadr (member "--permission-mode" args)) "default"))))
    ;; A session Claude Code has stored is resumed.
    (let* ((config (make-temp-file "agent-notes-claude" t))
           (process-environment (cons (concat "CLAUDE_CONFIG_DIR=" config) process-environment)))
      (unwind-protect
          (progn
            (should-not (agent-notes--claude-session-p "s2"))
            (make-directory (expand-file-name "projects/-tmp-repo" config) t)
            (agent-notes--write-file (expand-file-name "projects/-tmp-repo/s2.jsonl" config) "{}")
            (should (agent-notes--claude-session-p "s2"))
            (should (member "--resume" (agent-notes--claude-args '(:prompt "p" :session "s2")))))
        (delete-directory config t)))
    (let* ((agent-notes-allow-edits nil)
           (args (agent-notes--codex-args '(:prompt "p" :session "s1" :output-file "/tmp/o"))))
      (should (equal (car args) "exec"))
      (should (equal (cadr (member "--sandbox" args)) "read-only"))
      (should (equal (cadr (member "--output-last-message" args)) "/tmp/o"))
      (should-not (member "resume" args))
      (should (equal (car (last args)) "p")))
    (let* ((agent-notes-allow-edits t)
           (args (agent-notes--codex-args
                  '(:prompt "p" :session "s1" :resume t :output-file "/tmp/o"))))
      (should (equal (cadr (member "--sandbox" args)) "workspace-write"))
      (should (equal (last args 3) '("resume" "s1" "p"))))
    (let ((agent-notes-agent 'claude))
      (should (equal (agent-notes--agent-name) "Claude Code"))
      (should (string-search "Claude Code" (agent-notes--choose-agent-description)))
      (should (string-search "Claude Code: idle" (agent-notes--header-line))))
    (let ((agent-notes-agent 'nope))
      (should (equal (agent-notes--agent-name) "nope"))
      (should-error (agent-notes--agent) :type 'user-error))))

(defun agent-notes-tests--script (dir name body)
  "Write the shell script NAME with BODY to DIR and return its file name."
  (let ((file (expand-file-name name dir)))
    (agent-notes--write-file file (concat "#!/bin/sh\n" body))
    (set-file-modes file #o755)
    file))

(ert-deftest agent-notes-test-claude-and-codex-runs ()
  (agent-notes-tests--with-repo
    (cl-letf (((symbol-function 'agent-notes--claude-session-p) #'ignore))
      ;; Claude Code reads the prompt on stdin; the session is created, then resumed.
      (let ((agent-notes-agent 'claude)
            (agent-notes-claude-program
             (agent-notes-tests--script
              tmp "fake-claude"
              (concat "echo \"$@\" >> " tmp "claude-args\n"
                      "cat > " tmp "claude-stdin\n"
                      "cat <<'EOF'\n```json\n{\"summary\": \"From Claude.\", \"notes\": []}\n```\nEOF\n"))))
        (agent-notes--start-task '("Mine" . "Explain the tests."))
        (agent-notes-tests--wait)
        (let ((session (plist-get agent-notes--review :session)))
          (should (equal (plist-get agent-notes--review :agent) "claude"))
          (should (plist-get agent-notes--review :session_used))
          (should (string-search "Explain the tests."
                                 (agent-notes--read-file (concat tmp "claude-stdin"))))
          (should (string-search (concat "--session-id " session)
                                 (agent-notes--read-file (concat tmp "claude-args"))))
          (should (equal (plist-get (car (last (plist-get agent-notes--review :summaries))) :text)
                         "From Claude."))
          (should (cl-some (lambda (e) (string-search "Claude Code answered after"
                                                      (plist-get e :text)))
                           agent-notes--log-entries))
          ;; Nothing had happened in the review, so there was no switch to log.
          (should-not (cl-some (lambda (e) (string-search "Switched" (plist-get e :text)))
                               agent-notes--log-entries))
          (agent-notes--start-task '("Mine" . "Again."))
          (agent-notes-tests--wait)
          (should (string-search (concat "--resume " session)
                                 (cadr (split-string (agent-notes--read-file (concat tmp "claude-args"))
                                                     "\n"))))))
      ;; Codex: the answer comes from its output file, the session id from its output.
      (let ((agent-notes-agent 'codex)
            (agent-notes-codex-program
             (agent-notes-tests--script
              tmp "fake-codex"
              (concat "echo \"$@\" >> " tmp "codex-args\n"
                      "out=''; prev=''\n"
                      "for a in \"$@\"; do\n"
                      "  if [ \"$prev\" = --output-last-message ]; then out=\"$a\"; fi\n"
                      "  prev=\"$a\"\n"
                      "done\n"
                      "echo 'session id: 0199abcd-1234' >&2\n"
                      "printf '```json\\n{\"summary\": \"WRONG\", \"notes\": []}\\n```\\n'\n"
                      "cat > \"$out\" <<'EOF'\nDone.\n```json\n"
                      "{\"summary\": \"From Codex.\", \"notes\": []}\n```\nEOF\n"))))
        (agent-notes--start-task '("Mine" . "Explain."))
        (agent-notes-tests--wait)
        (should (cl-some (lambda (e) (string-search "Switched from Claude Code to Codex"
                                                    (plist-get e :text)))
                         agent-notes--log-entries))
        (should (equal (plist-get (car (last (plist-get agent-notes--review :summaries))) :text)
                       "From Codex."))
        (should (equal (plist-get agent-notes--review :session) "0199abcd-1234"))
        (should (plist-get agent-notes--review :session_used))
        (should-not (string-search "resume" (agent-notes--read-file (concat tmp "codex-args"))))
        (agent-notes--start-task '("Mine" . "Again."))
        (agent-notes-tests--wait)
        (should (string-search "resume 0199abcd-1234 "
                               (agent-notes--read-file (concat tmp "codex-args"))))
        ;; The session survives reopening the review.
        (should (string-search "\"agent\": \"codex\"" (agent-notes--read-file agent-notes--file)))))))

(provide 'agent-notes-tests)
;;; agent-notes-tests.el ends here
