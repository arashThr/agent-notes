;;; e2e.el --- Manual end-to-end check against the real Copilot CLI -*- lexical-binding: t; -*-
;; Runs the "Overview" task, then sends a note asking for a code change and
;; checks that the agent edited the file and the diff was refreshed.
;; Uses 2 Copilot requests.  Usage, from this directory, against a scratch
;; repo with uncommitted changes (the agent WILL edit its files):
;;   emacs -Q --batch \
;;     --eval '(progn (setq package-user-dir "~/.config/emacs/elpa") (package-initialize))' \
;;     -L . --eval '(setq default-directory "/path/to/repo/")' -l ./e2e.el

(require 'agent-notes)

(defun e2e-wait (buf)
  (with-current-buffer buf
    (let ((start (float-time)))
      (while (and (process-live-p agent-notes--process) (< (- (float-time) start) 600))
        (accept-process-output nil 1)))
    ;; Let the sentinel run.
    (accept-process-output nil 0.5)))

(defun e2e-show (title)
  (princ (format "\n===== %s =====\n" title))
  (princ (buffer-substring-no-properties (point-min) (point-max))))

(agent-notes-review "working" nil (assoc "Overview" agent-notes-tasks))
(let ((buf (current-buffer)))
  (e2e-wait buf)
  (with-current-buffer buf
    (e2e-show "AFTER OVERVIEW")
    ;; Ask for a change on the first added line of the first file.
    (let* ((rec (cl-find-if (lambda (r) (eq (plist-get r :kind) 'added)) agent-notes--records))
           (note (agent-notes--add-note
                  "you" (plist-get rec :path) "new" (plist-get rec :new) ""
                  "Please add a short comment above this line explaining it. Edit the file."
                  "pending"))
           (ids (agent-notes--pending-comments)))
      (princ (format "\nAsked for a change at %s:%s\n" (plist-get note :path) (plist-get note :line)))
      (agent-notes--run "replying" (agent-notes--reply-prompt (list note) ids)
                        #'agent-notes--apply-replies ids)))
  (e2e-wait buf)
  (with-current-buffer buf
    (e2e-show "AFTER REPLY")
    (princ (format "\nChanged by the agent: %S\n" agent-notes--changes))))
(princ "\n===== LOG (tail) =====\n")
(princ (with-current-buffer agent-notes--log-buffer
         (buffer-substring-no-properties (max (point-min) (- (point-max) 3000)) (point-max))))
