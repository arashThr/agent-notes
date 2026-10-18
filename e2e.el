;;; e2e.el --- Manual end-to-end check against the real Copilot CLI -*- lexical-binding: t; -*-
;; Usage (from this directory, against a repo with uncommitted changes; uses 2 Copilot requests):
;;   emacs -Q --batch -L . --eval '(setq default-directory "/path/to/repo/")' -l ./e2e.el

(require 'agent-notes)

(defun e2e-wait (buf)
  (with-current-buffer buf
    (let ((start (float-time)))
      (while (and (process-live-p agent-notes--process) (< (- (float-time) start) 600))
        (accept-process-output nil 1)))
    ;; Let the sentinel run.
    (accept-process-output nil 0.5)))

(agent-notes-review "working")
(let ((buf (current-buffer)))
  (e2e-wait buf)
  (with-current-buffer buf
    (princ "\n===== AFTER REVIEW =====\n")
    (princ (buffer-substring-no-properties (point-min) (point-max)))
    (let ((note (car (agent-notes--notes))))
      (when note
        (let ((c (agent-notes--make-comment "you" "Is this really a problem? Callers never pass an empty list." "pending")))
          (plist-put note :comments (append (plist-get note :comments) (list c))))
        (let ((ids (agent-notes--pending-comments)))
          (agent-notes--run "replying"
                            (agent-notes--reply-prompt (list note) ids)
                            #'agent-notes--apply-replies ids))))))
(e2e-wait (current-buffer))
(with-current-buffer (current-buffer)
  (princ "\n===== AFTER REPLY =====\n")
  (princ (buffer-substring-no-properties (point-min) (point-max))))
(princ "\n===== LOG =====\n")
(princ (with-current-buffer agent-notes--log-buffer (buffer-string)))
