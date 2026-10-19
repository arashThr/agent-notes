;;; agent-notes-tests.el --- Tests for agent-notes -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with (magit-section and transient must be on the load path):
;;   emacs -Q --batch \
;;     --eval '(progn (setq package-user-dir "~/.config/emacs/elpa") (package-initialize))' \
;;     -L . -l agent-notes-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-notes)

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
    (agent-notes-toggle-view)
    (should (eq agent-notes--view 'unified))))

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
      (should (member "--allow-tool=write" (agent-notes--copilot-args "x")))
      (should-not (member "--deny-tool=write" (agent-notes--copilot-args "x")))
      (should (string-search "edit files" (agent-notes--reply-prompt nil nil))))
    (let ((agent-notes-allow-edits nil))
      (should (member "--deny-tool=write" (agent-notes--copilot-args "x")))
      (should-not (member "--allow-tool=write" (agent-notes--copilot-args "x")))
      (should (string-search "cannot modify files" (agent-notes--reply-prompt nil nil))))
    (should (equal (last (agent-notes--copilot-args "the prompt") 2) '("-p" "the prompt")))))

(ert-deftest agent-notes-test-general-note ()
  (agent-notes-tests--with-review nil
    (agent-notes--add-note "you" "" "new" 0 "" "Overall question" "pending")
    (agent-notes--render)
    (should (eq (oref (oref (agent-notes--note-section 1) parent) type) 'agent-notes-general))
    (should (string-search "about the whole change"
                           (agent-notes--reply-prompt (agent-notes--notes)
                                                      (agent-notes--pending-comments))))))

(provide 'agent-notes-tests)
;;; agent-notes-tests.el ends here
