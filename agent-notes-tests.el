;;; agent-notes-tests.el --- Tests for agent-notes -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs -Q --batch -L . -l agent-notes-tests.el -f ert-run-tests-batch-and-exit

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

(defun agent-notes-tests--records ()
  (agent-notes--parse-diff agent-notes-tests--diff))

(ert-deftest agent-notes-test-parse-line-numbers ()
  (let* ((records (agent-notes-tests--records))
         (code (cl-remove-if-not (lambda (r) (memq (plist-get r :kind) '(context added removed)))
                                 records)))
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

(ert-deftest agent-notes-test-index ()
  (let* ((records (agent-notes-tests--records))
         (index (agent-notes--index-records records)))
    (should (eq (plist-get (gethash (agent-notes--loc-key "src/auth.py" "old" 11) index) :kind)
                'removed))
    (should (eq (plist-get (gethash (agent-notes--loc-key "src/auth.py" "new" 12) index) :kind)
                'added))
    (should (eq (plist-get (gethash (agent-notes--loc-key "src/auth.py" "old" 12) index) :kind)
                'context))
    (should-not (gethash (agent-notes--loc-key "src/auth.py" "new" 99) index))))

(ert-deftest agent-notes-test-extract-json ()
  (should (equal (agent-notes--extract-json
                  "Looks good overall.\n```python\nx = 1\n```\n```json\n{\"summary\": \"ok\", \"notes\": []}\n```\n")
                 '(:summary "ok" :notes nil)))
  (should (equal (plist-get (agent-notes--extract-json "Here: {\"replies\": [{\"note\": 1, \"resolve\": true}]}")
                            :replies)
                 '((:note 1 :resolve t))))
  (should-error (agent-notes--extract-json "no json here")))

(defmacro agent-notes-tests--with-review (&rest body)
  "Run BODY in a review buffer backed by temporary files."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-notes-test" t))
          (file (expand-file-name "r.json" dir)))
     (unwind-protect
         (progn
           (agent-notes--write-file (agent-notes--diff-file file) agent-notes-tests--diff)
           (agent-notes--write-file
            file (agent-notes--serialize
                  (list :version 1 :id "r" :root (file-name-as-directory dir) :scope "working"
                        :base "HEAD" :base_rev "abc" :head_rev "abc" :created "now"
                        :session "s" :summary "" :next_note 1 :next_comment 1 :notes nil)))
           (with-current-buffer (agent-notes--get-buffer file)
             (unwind-protect (progn ,@body)
               (kill-buffer))))
       (delete-directory dir t))))

(ert-deftest agent-notes-test-review-roundtrip-and-render ()
  (agent-notes-tests--with-review
    (agent-notes--apply-review
     '(:summary "Adds a disabled check."
       :notes ((:path "b/src/auth.py" :line 11 :side "new" :severity "warning"
                :body "Returning `None` breaks callers.")
               (:path "src/auth.py" :line 99 :side "new" :severity "nit" :body "Far away")
               (:path "elsewhere.py" :line 1 :side "new" :severity "question" :body "General")))
     nil)
    (agent-notes--save)
    (agent-notes--render)
    (let ((text (buffer-string)))
      (should (string-match-p "Returning `None` breaks callers." text))
      (should (string-match-p "General notes" text))
      (should (string-match-p "src/auth.py:99 (not in diff)" text)))
    ;; The first note is shown right below the line it refers to.
    (goto-char (agent-notes--find-prop 'agent-notes-header 1))
    (forward-line -1)
    (should (equal (plist-get (get-text-property (point) 'agent-notes-loc) :text)
                   "+    if user.disabled:"))
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
    ;; Everything survives a save and reload.
    (agent-notes--save)
    (agent-notes--reload)
    (should (= (length (agent-notes--notes)) 4))
    (should (equal (plist-get agent-notes--review :summary) "Adds a disabled check."))
    (should (equal (plist-get (car (agent-notes--notes)) :path) "src/auth.py"))))

(provide 'agent-notes-tests)
;;; agent-notes-tests.el ends here
