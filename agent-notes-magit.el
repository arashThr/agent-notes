;;; agent-notes-magit.el --- Magit integration for agent-notes -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Copyright (C) 2026 ArashThr

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el.  The global minor mode
;; `agent-notes-magit-mode' binds `@' in Magit buffers and in
;; `magit-dispatch' to `agent-notes-menu', and shows the latest review
;; in the Magit status buffer.  Enable it in your init file with
;;
;;   (with-eval-after-load \='magit (agent-notes-magit-mode 1))
;;
;; This file does not load agent-notes.el, so that enabling the mode
;; from Magit's load hook is safe even while agent-notes.el loads Magit.

;;; Code:

(require 'eieio)
(require 'magit)
(require 'agent-notes-core)
(require 'agent-notes-diff)

(declare-function agent-notes--get-buffer "agent-notes" (file))
(autoload 'agent-notes-menu "agent-notes" nil t)

(defun agent-notes-open-at-point ()
  "Open the review of the Agent Notes section at point."
  (interactive)
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'agent-notes-status-section))
      (user-error "No review here"))
    (require 'agent-notes)
    (pop-to-buffer-same-window (agent-notes--get-buffer (oref section value)))))

(defvar-keymap agent-notes-status-section-map
  :doc "Keymap for the Agent Notes section in the Magit status buffer."
  "RET" #'agent-notes-open-at-point
  "<remap> <magit-visit-thing>" #'agent-notes-open-at-point)

(defclass agent-notes-status-section (magit-section)
  ((keymap :initform 'agent-notes-status-section-map))
  "The line about the latest review in the Magit status buffer.")

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
          (magit-insert-section (agent-notes-status-section file)
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

;;;###autoload
(define-minor-mode agent-notes-magit-mode
  "Add Agent Notes to Magit.
Bind `@' in Magit buffers and in `magit-dispatch' to
`agent-notes-menu', and show the latest review in the Magit status
buffer; see `agent-notes-magit-status-section'."
  :global t
  :group 'agent-notes
  (if agent-notes-magit-mode
      (progn
        (keymap-set magit-mode-map "@" #'agent-notes-menu)
        (condition-case err
            (unless (ignore-errors (transient-get-suffix 'magit-dispatch "@"))
              (transient-append-suffix 'magit-dispatch "!"
                '("@" "Agent notes" agent-notes-menu)))
          (error (message "agent-notes: could not extend `magit-dispatch': %s"
                          (error-message-string err))))
        (if (memq 'magit-insert-untracked-files
                  (default-value 'magit-status-sections-hook))
            (magit-add-section-hook 'magit-status-sections-hook
                                    #'agent-notes-insert-status-section
                                    'magit-insert-untracked-files)
          (magit-add-section-hook 'magit-status-sections-hook
                                  #'agent-notes-insert-status-section nil t)))
    (when (eq (keymap-lookup magit-mode-map "@") #'agent-notes-menu)
      (keymap-unset magit-mode-map "@" t))
    (when (ignore-errors (transient-get-suffix 'magit-dispatch "@"))
      (ignore-errors (transient-remove-suffix 'magit-dispatch "@")))
    (remove-hook 'magit-status-sections-hook #'agent-notes-insert-status-section)))

(provide 'agent-notes-magit)
;;; agent-notes-magit.el ends here
