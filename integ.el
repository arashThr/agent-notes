;;; integ.el --- Integration check with Magit (no Copilot requests) -*- lexical-binding: t; -*-
;; Needs a scratch repo with uncommitted changes to stats.py and at least one
;; review; it edits stats.py temporarily and restores it.  Usage:
;;   emacs -Q --batch --eval '(progn (setq package-user-dir "~/.config/emacs/elpa") (package-initialize))' \
;;     -L . --eval '(setq default-directory "/path/to/repo/")' -l ./integ.el

(require 'magit)
(require 'agent-notes)

(princ (format "agent-notes-magit loaded: %S\n" (featurep 'agent-notes-magit)))
(princ (format "@ in magit-mode-map: %S\n" (keymap-lookup magit-mode-map "@")))
(princ (format "@ in magit-dispatch: %S\n"
               (ignore-errors (plist-get (cdr (transient-get-suffix 'magit-dispatch "@")) :command))))
(princ (format "status hook has section: %S\n"
               (memq 'agent-notes-insert-status-section magit-status-sections-hook)))

;; Status buffer.
(let ((buf (magit-status-setup-buffer default-directory)))
  (with-current-buffer buf
    (princ "\n===== MAGIT STATUS (top) =====\n")
    (princ (buffer-substring-no-properties (point-min) (min (point-max) 400)))
    (goto-char (point-min))
    (when (search-forward "Agent review:" nil t)
      (princ (format "\nRET there runs: %S\n" (key-binding (kbd "RET")))))))

;; Latest review, both views.
(agent-notes-open-latest)
(with-current-buffer (current-buffer)
  (princ "\n===== UNIFIED =====\n")
  (princ (buffer-substring-no-properties (point-min) (point-max)))
  (agent-notes-toggle-view)
  (princ "\n===== SIDE BY SIDE =====\n")
  (princ (buffer-substring-no-properties (point-min) (point-max)))
  (princ (format "\nkeys: ? -> %S, v -> %S, M-n -> %S, n -> %S, a -> %S, # -> %S, RET -> %S\n"
                 (key-binding "?") (key-binding "v") (key-binding (kbd "M-n")) (key-binding "n")
                 (key-binding "a") (key-binding "#") (key-binding (kbd "RET"))))
  (agent-notes-toggle-line-numbers)
  (princ "\n===== SIDE BY SIDE, NO LINE NUMBERS =====\n")
  (princ (buffer-substring-no-properties (point-min) (point-max)))
  (agent-notes-toggle-line-numbers)
  (goto-char (point-min))
  (when (search-forward "+def median(xs)" nil t)
    (princ (format "faces on +def median(xs): %S\n"
                   (delete-dups (mapcar (lambda (p) (get-text-property p 'font-lock-face))
                                        (number-sequence (match-beginning 0) (1- (point))))))))

  ;; Simulate an agent run that edits the file.
  (let* ((file (expand-file-name "stats.py" default-directory))
         (original (agent-notes--read-file file))
         (before (agent-notes--fingerprints (car (agent-notes--snapshot-diff agent-notes--review)))))
    (unwind-protect
        (progn
          (agent-notes--write-file
           file (replace-regexp-in-string
                 "def average(xs):\n" "def average(xs):\n    \"\"\"Mean of XS.\"\"\"\n"
                 (replace-regexp-in-string
                  "    return s\\[len(s) // 2\\]\n"
                  "    n = len(s)\n    mid = n // 2\n    return s[mid] if n % 2 else (s[mid - 1] + s[mid]) / 2\n"
                  original)))
          (princ (format "\ndetect-changes: %s\n" (agent-notes--detect-changes before)))
          (agent-notes-toggle-view)
          (agent-notes--render)
          (princ "\n===== AFTER AGENT EDIT (unified) =====\n")
          (princ (buffer-substring-no-properties (point-min) (point-max)))
          (princ (format "\nnotes: %S\n"
                         (mapcar (lambda (n) (list (plist-get n :id) (plist-get n :line)
                                                   (plist-get n :outdated)))
                                 (agent-notes--notes))))
          ;; g with nothing new.
          (agent-notes-refresh))
      (agent-notes--write-file file original)))
  ;; g after the file is restored.
  (agent-notes-refresh)
  (princ (format "notes after restore: %S\n"
                 (mapcar (lambda (n) (list (plist-get n :id) (plist-get n :line)
                                           (plist-get n :outdated)))
                         (agent-notes--notes))))
  ;; Window width changes re-render the side-by-side view.
  (agent-notes-toggle-view)
  (switch-to-buffer (current-buffer))
  (let ((w agent-notes--width))
    (setq agent-notes--width 1)
    (agent-notes--on-window-size-change (selected-window))
    (princ (format "width re-render: %S -> %S\n" w agent-notes--width)))
  (agent-notes-show-log)
  (princ "\n===== LOG =====\n")
  (princ (with-current-buffer (agent-notes--log-buffer-name)
           (buffer-substring-no-properties (point-min) (point-max)))))
