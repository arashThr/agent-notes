;;; agent-notes-log.el --- A readable log of what happens in a review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el.  Every review buffer keeps
;; a list of log entries: what was sent to the agent, how long it
;; took, what came back and what changed.  `agent-notes-show-log'
;; shows them in a buffer of their own, one line per step, with the
;; raw prompt and answer folded underneath.

;;; Code:

(require 'eieio)
(require 'magit-section)
(require 'agent-notes-core)

(defvar-local agent-notes--log-entries nil
  "Log entries of the review in this buffer, oldest first.")

(defvar-local agent-notes-log--source nil
  "The review buffer whose log this buffer shows.")

(defconst agent-notes-log--indent (make-string 20 ?\s)
  "Indentation of the lines below the first line of a log entry.")

(defun agent-notes--log-buffer-name ()
  "Return the name of the log buffer of the review in the current buffer."
  (format "*agent-notes-log: %s %s*"
          (agent-notes--repo-name agent-notes--review) (plist-get agent-notes--review :id)))

(defun agent-notes--log (stage text &rest details)
  "Add an entry to the log of the review in the current buffer.
STAGE is a short word, such as \"Sent\" or \"Failed\".  TEXT says
what happened, for a human; its first line is the entry's heading.
Each of DETAILS is (TITLE CONTENT &optional SHOW): a part shown
folded under the entry unless SHOW is non-nil."
  (when agent-notes--review
    (setq agent-notes--log-entries
          (append agent-notes--log-entries
                  (list (list :time (current-time) :stage stage :text text
                              :details (delq nil details)))))
    (let ((buf (get-buffer (agent-notes--log-buffer-name))))
      (when (buffer-live-p buf)
        (with-current-buffer buf (agent-notes-log--render))))))

(defun agent-notes-log--stage-face (stage)
  "Return the face for log entries of STAGE."
  (pcase stage
    ((or "Failed" "Stopped") 'error)
    ((or "Done" "Applied") 'success)
    ("Sent" 'agent-notes-pending)
    ("Changes" 'warning)
    ("You" 'agent-notes-you)
    (_ 'bold)))

(defun agent-notes-log--insert-indented (text &optional face)
  "Insert TEXT with each line indented, in FACE."
  (dolist (line (split-string (string-trim-right text) "\n"))
    (insert agent-notes-log--indent
            (if face (propertize line 'font-lock-face face) line)
            "\n")))

(defun agent-notes-log--insert-entry (entry n)
  "Insert ENTRY, the Nth of the log, as a section."
  (let* ((stage (plist-get entry :stage))
         (lines (split-string (plist-get entry :text) "\n"))
         (start (point)))
    (magit-insert-section (agent-notes-log-entry n)
      (insert (propertize (format-time-string "%H:%M:%S" (plist-get entry :time))
                          'font-lock-face 'shadow)
              "  "
              (propertize (format "%-9s" stage)
                          'font-lock-face (agent-notes-log--stage-face stage))
              " " (car lines) "\n")
      (magit-insert-heading)
      (when (cdr lines)
        (agent-notes-log--insert-indented (string-join (cdr lines) "\n")))
      (dolist (detail (plist-get entry :details))
        (pcase-let ((`(,title ,content ,show) detail))
          (magit-insert-section (agent-notes-log-detail (format "%d %s" n title) (not show))
            (insert agent-notes-log--indent
                    (propertize title 'font-lock-face 'magit-section-secondary-heading)
                    (propertize (format "  (%s)" (agent-notes--plural
                                                  (length (split-string content "\n"))
                                                  "line"))
                                'font-lock-face 'shadow)
                    "\n")
            (magit-insert-heading)
            (agent-notes-log--insert-indented content 'shadow)))))
    (put-text-property start (point) 'wrap-prefix agent-notes-log--indent)))

(defun agent-notes-log--render ()
  "Redraw the log buffer from the entries of its review."
  (let* ((src agent-notes-log--source)
         (win (get-buffer-window (current-buffer) t))
         (follow (or (null win) (>= (window-point win) (1- (point-max)))))
         (line (line-number-at-pos (if win (window-point win) (point))))
         (inhibit-read-only t))
    (erase-buffer)
    (if (not (buffer-live-p src))
        (insert "The review buffer of this log was closed.\n")
      (let ((review (buffer-local-value 'agent-notes--review src))
            (entries (buffer-local-value 'agent-notes--log-entries src))
            (n 0))
        (magit-insert-section (agent-notes-log-root)
          (insert (propertize (format "Agent Notes log · %s · review %s"
                                      (agent-notes--repo-name review) (plist-get review :id))
                              'font-lock-face 'agent-notes-title)
                  "\n"
                  (propertize "What happened in this review, oldest first.  TAB on an \
entry shows its details, such as the prompt and the agent's raw answer.\n\n"
                              'font-lock-face 'shadow))
          (unless entries
            (insert "Nothing has happened yet in this Emacs session.\n"))
          (dolist (entry entries)
            (agent-notes-log--insert-entry entry (cl-incf n))))
        (let ((magit-section-cache-visibility nil))
          (magit-section-show magit-root-section))))
    (if follow
        (goto-char (point-max))
      (goto-char (point-min))
      (forward-line (1- line)))
    (when win (set-window-point win (point)))))

(defun agent-notes-log--header-line ()
  "Return the header line of the log buffer."
  (let ((src agent-notes-log--source))
    (if (not (buffer-live-p src))
        " Review closed"
      (with-current-buffer src
        (if agent-notes--status
            (propertize (format " Agent: %s %s" agent-notes--status
                                (or (agent-notes--elapsed) ""))
                        'face 'agent-notes-pending)
          " Agent: idle")))))

(defun agent-notes-log-refresh ()
  "Redraw the log."
  (interactive)
  (agent-notes-log--render))

(defvar-keymap agent-notes-log-mode-map
  :doc "Keymap for `agent-notes-log-mode'."
  :parent magit-section-mode-map
  "g" #'agent-notes-log-refresh)

(define-derived-mode agent-notes-log-mode magit-section-mode "Agent-Notes-Log"
  "Major mode for the log of an Agent Notes review.

\\{agent-notes-log-mode-map}"
  :interactive nil
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local header-line-format '(:eval (agent-notes-log--header-line))))

(defun agent-notes-show-log ()
  "Show what happened in this review: requests, answers and changes."
  (interactive)
  (unless agent-notes--review (user-error "Not in a review buffer"))
  (let ((src (current-buffer))
        (buf (get-buffer-create (agent-notes--log-buffer-name))))
    (with-current-buffer buf
      (unless (derived-mode-p 'agent-notes-log-mode)
        (agent-notes-log-mode))
      (setq agent-notes-log--source src)
      (agent-notes-log--render)
      (goto-char (point-max)))
    (let ((win (display-buffer buf)))
      (when win (set-window-point win (with-current-buffer buf (point-max)))))))

(provide 'agent-notes-log)
;;; agent-notes-log.el ends here
