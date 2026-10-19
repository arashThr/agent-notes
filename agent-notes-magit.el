;;; agent-notes-magit.el --- Magit integration for agent-notes -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el, which loads this file once
;; Magit is loaded.  It binds `@' in Magit buffers and in
;; `magit-dispatch' to `agent-notes-menu', and shows the latest review
;; in the Magit status buffer.

;;; Code:

(require 'eieio)
(require 'magit)
(require 'agent-notes-core)
(require 'agent-notes-diff)

(declare-function agent-notes--get-buffer "agent-notes" (file))
(declare-function agent-notes-menu "agent-notes" ())

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
               (unsent (agent-notes--count-unsent notes)))
          (magit-insert-section (agent-notes file)
            (insert (propertize "Agent review: " 'font-lock-face 'magit-section-heading)
                    (agent-notes--scope-label review)
                    (if (and notes (= open 0) (= unsent 0))
                        (propertize " · all resolved ✓" 'font-lock-face 'success)
                      (format " · %d open" open))
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

(agent-notes--magit-setup)

(provide 'agent-notes-magit)
;;; agent-notes-magit.el ends here
