;;; agent-notes-render.el --- Drawing the review buffer for agent-notes -*- lexical-binding: t; -*-

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

;; Part of agent-notes; see agent-notes.el.  This file draws a review:
;; the header with the summaries, then each file, hunk and note as a
;; `magit-section', in the unified or the side-by-side view.

;;; Code:

(require 'eieio)
(require 'color)
(require 'text-property-search)
(require 'diff-mode)
(require 'magit-section)
(require 'agent-notes-core)
(require 'agent-notes-diff)

;;;; Faces for parts of the diff and notes

(defun agent-notes--severity-face (severity)
  "Return the face for SEVERITY."
  (pcase severity
    ((or "issue" "bug" "error" "critical") 'error)
    ("warning" 'warning)
    ("question" 'font-lock-builtin-face)
    ("info" 'agent-notes-info)
    ("nit" 'shadow)
    (_ 'success)))

(defun agent-notes--author-face (author)
  "Return the face for AUTHOR."
  (if (equal author "agent") 'agent-notes-agent 'agent-notes-you))

(defun agent-notes--line-face (kind)
  "Return the face for diff lines of KIND without syntax highlighting."
  (pcase kind
    ('added 'agent-notes-added)
    ('removed 'agent-notes-removed)
    (_ 'agent-notes-context)))

(defun agent-notes--bg-face (kind)
  "Return the background face for syntax highlighted lines of KIND, or nil."
  (pcase kind
    ('added 'agent-notes-added-bg)
    ('removed 'agent-notes-removed-bg)))

(defun agent-notes--decorate (code kind)
  "Return CODE, highlighted with `face' properties, as a diff line of KIND.
The syntax faces are kept and the background of KIND is added."
  (let* ((bg (agent-notes--bg-face kind))
         (out (substring-no-properties code))
         (len (length code))
         (pos 0))
    (while (< pos len)
      (let ((next (or (next-single-property-change pos 'face code) len))
            (faces (append (agent-notes--face-list (get-text-property pos 'face code))
                           (and bg (list bg)))))
        (when faces
          (put-text-property pos next 'font-lock-face faces out))
        (setq pos next)))
    out))

(defun agent-notes--code-line (rec syntax)
  "Return the diff line REC, with its sign, ready to insert.
SYNTAX is a table from `agent-notes--hunk-syntax', or nil."
  (let ((kind (plist-get rec :kind))
        (text (plist-get rec :text))
        (code (and syntax (gethash rec syntax))))
    (if (not code)
        (propertize text 'font-lock-face (agent-notes--line-face kind))
      (concat (propertize (substring text 0 1) 'font-lock-face (agent-notes--line-face kind))
              (agent-notes--decorate code kind)))))

(defun agent-notes--line-end-face (rec syntax)
  "Return the face for the space after the diff line REC.
SYNTAX is as in `agent-notes--code-line'."
  (let ((kind (plist-get rec :kind)))
    (if (and syntax (gethash rec syntax))
        (agent-notes--bg-face kind)
      (agent-notes--line-face kind))))

;;;; Markdown

(defun agent-notes--fence-p (line)
  "Return non-nil if LINE opens or closes a fenced code block."
  (string-prefix-p "```" (string-trim-left line)))

(defun agent-notes--faces (&rest faces)
  "Return FACES as a list for `font-lock-face', without nil and `default'.
The face `default' specifies every attribute, so in a list it would
hide the background of the faces after it, such as the note's."
  (cl-remove-if (lambda (face) (memq face '(nil default))) (flatten-tree faces)))

(defun agent-notes--fontify-line (line in-fence base &optional plain)
  "Return LINE of Markdown with faces; IN-FENCE means inside a code block.
BASE is the face for ordinary text, or nil.  Unless PLAIN, add the
note background."
  (let ((bg (unless plain 'agent-notes-note)))
    (cond
     ((agent-notes--fence-p line)
      (propertize line 'font-lock-face (agent-notes--faces 'agent-notes-border bg)))
     (in-fence
      (propertize line 'font-lock-face (agent-notes--faces 'agent-notes-code-block base bg)))
     (t
      (let ((s (propertize line 'font-lock-face (agent-notes--faces base bg)))
            (start 0))
        (while (string-match "`[^`]+`\\|\\*\\*[^*]+\\*\\*" s start)
          (put-text-property (match-beginning 0) (match-end 0) 'font-lock-face
                             (agent-notes--faces (if (eq (aref s (match-beginning 0)) ?`)
                                                     'agent-notes-code
                                                   'bold)
                                                 base bg)
                             s)
          (setq start (match-end 0)))
        s)))))

(defun agent-notes--insert-markdown (text base pad &optional plain fence-width)
  "Insert TEXT, prefixed with PAD on each line, with Markdown faces.
BASE and PLAIN are as in `agent-notes--fontify-line'.  When
FENCE-WIDTH is non-nil, lines in code blocks are cut at that width
instead of wrapping, which keeps diagrams intact.  Graphviz code
blocks are shown as images when possible."
  (let ((in-fence nil)
        (diagram nil))                  ; (OPENING-FENCE . REVERSED-LINES)
    (dolist (line (split-string text "\n"))
      (let ((fence (agent-notes--fence-p line)))
        (cond
         (diagram
          (if (not fence)
              (push line (cdr diagram))
            (agent-notes--insert-diagram (car diagram) (reverse (cdr diagram))
                                         base pad plain fence-width)
            (setq diagram nil)))
         ((and fence (not in-fence) (agent-notes--dot-fence-p line))
          (setq diagram (list line)))
         (t
          (insert pad (agent-notes--fontify-line
                       (agent-notes--fit-code-line line (and in-fence (not fence)) fence-width)
                       in-fence base plain)
                  "\n")
          (when fence (setq in-fence (not in-fence)))))))
    (when diagram
      (agent-notes--insert-diagram (car diagram) (reverse (cdr diagram))
                                   base pad plain fence-width))))

(defun agent-notes--fit-code-line (line in-code width)
  "Return LINE, cut at WIDTH if IN-CODE and WIDTH is non-nil."
  (if (and in-code width (> (string-width line) width))
      (truncate-string-to-width line width nil nil "…")
    line))

;;;; Diagrams

(defvar agent-notes--diagram-cache (make-hash-table :test #'equal)
  "Rendered diagrams: md5 of the color and source, to SVG or `failed'.")

(defvar agent-notes--text-width nil
  "When non-nil, the width available for the text being inserted.
Bound while inserting a note in one column of the side-by-side view.")

(defun agent-notes--dot-fence-p (line)
  "Return non-nil if LINE opens a Graphviz code block."
  (string-match-p "\\`[ \t]*```[ \t]*\\(?:dot\\|graphviz\\|gv\\)[ \t]*\\'" line))

(defun agent-notes--diagram-images-p ()
  "Return non-nil if Graphviz diagrams can be shown as images."
  (and (display-images-p)
       (image-type-available-p 'svg)
       (executable-find agent-notes-dot-program)
       t))

(defun agent-notes--diagram-color ()
  "Return the color of the text, as #RRGGBB, for drawing diagrams."
  (or (ignore-errors
        (apply #'color-rgb-to-hex
               (append (color-name-to-rgb (face-foreground 'default nil t)) '(2))))
      "black"))

(defun agent-notes--render-dot (source)
  "Return the Graphviz SOURCE rendered as SVG, or nil if that fails.
The diagram is drawn in the color of the text, on a transparent
background."
  (let* ((fg (agent-notes--diagram-color))
         (key (md5 (concat fg "\n" source)))
         (svg (gethash key agent-notes--diagram-cache)))
    (unless svg
      (setq svg (with-temp-buffer
                  (insert source)
                  (let* ((coding-system-for-read 'utf-8)
                         (coding-system-for-write 'utf-8)
                         (status
                          (ignore-errors
                            (apply #'call-process-region (point-min) (point-max)
                                   agent-notes-dot-program t '(t nil) nil
                                   "-Tsvg" "-Gbgcolor=transparent"
                                   (mapcar (lambda (option) (concat option fg))
                                           '("-Gcolor=" "-Ncolor=" "-Ecolor=" "-Gfontcolor="
                                             "-Nfontcolor=" "-Efontcolor="))))))
                    (goto-char (point-min))
                    (if (and (eql status 0) (search-forward "<svg" nil t))
                        (buffer-string)
                      'failed))))
      (puthash key svg agent-notes--diagram-cache))
    (and (stringp svg) svg)))

(defun agent-notes--insert-diagram (open lines base pad plain fence-width)
  "Insert the Graphviz code block opened by the line OPEN, with LINES.
Show it as an image when possible, or else as code.  BASE, PAD,
PLAIN and FENCE-WIDTH are as in `agent-notes--insert-markdown'."
  (let* ((source (string-join lines "\n"))
         (images (agent-notes--diagram-images-p))
         (svg (and images (agent-notes--render-dot source)))
         (start (point)))
    (if svg
        (let ((bg (unless plain 'agent-notes-note)))
          (insert pad
                  (propertize " "
                              'font-lock-face bg
                              'display
                              (create-image svg 'svg t
                                            :ascent 'center
                                            :max-width
                                            (* (max 20 (- (or agent-notes--text-width
                                                              agent-notes--width 80)
                                                          (string-width pad)))
                                               (frame-char-width))))
                  (propertize "\n" 'font-lock-face bg)))
      (insert pad (agent-notes--fontify-line open nil base plain) "\n")
      (dolist (line lines)
        (insert pad (agent-notes--fontify-line
                     (agent-notes--fit-code-line line t fence-width) t base plain)
                "\n"))
      (insert pad (agent-notes--fontify-line "```" nil base plain) "\n"
              pad (propertize
                   (substitute-command-keys
                    (cond ((not (executable-find agent-notes-dot-program))
                           "(Install Graphviz to see this diagram as an image.)")
                          ((not images)
                           "(\\<agent-notes-mode-map>\\[agent-notes-visit] opens this diagram.)")
                          (t "(Graphviz could not render this diagram; \
\\<agent-notes-mode-map>\\[agent-notes-visit] opens its source.)")))
                   'font-lock-face (if plain 'shadow '(shadow agent-notes-note)))
              "\n"))
    (put-text-property start (point) 'agent-notes-diagram source)))

;;;; Notes

(defun agent-notes--suggestion-lines (path text kind)
  "Return the lines of TEXT, code of PATH, as diff lines of KIND."
  (let* ((code (and agent-notes-syntax-highlighting
                    (agent-notes--fontify-code path (concat text "\n"))))
         (sign (propertize (if (eq kind 'added) "+" "-")
                           'font-lock-face (agent-notes--line-face kind))))
    (mapcar (lambda (line)
              (concat sign (if code
                               (agent-notes--decorate line kind)
                             (propertize line 'font-lock-face (agent-notes--line-face kind)))))
            (split-string (or code text) "\n"))))

(defun agent-notes--insert-suggestion (note pad)
  "Insert the suggested change of NOTE, if any, with PAD before each line."
  (let ((suggestion (plist-get note :suggestion))
        (border (propertize "│ " 'font-lock-face '(agent-notes-border agent-notes-note))))
    (when (stringp suggestion)
      (insert pad (propertize "│" 'font-lock-face '(agent-notes-border agent-notes-note)) "\n"
              pad border
              (propertize "Suggested change" 'font-lock-face '(bold agent-notes-note))
              (if (plist-get note :applied)
                  (propertize "  applied" 'font-lock-face '(success agent-notes-note))
                (propertize (substitute-command-keys
                             "  \\<agent-notes-mode-map>\\[agent-notes-apply-suggestion] to apply")
                            'font-lock-face '(shadow agent-notes-note)))
              "\n")
      (let ((path (plist-get note :path))
            (original (plist-get note :original)))
        (when (stringp original)
          (dolist (line (agent-notes--suggestion-lines path original 'removed))
            (insert pad border line "\n")))
        (unless (string-empty-p suggestion)
          (dolist (line (agent-notes--suggestion-lines path suggestion 'added))
            (insert pad border line "\n")))))))

(defun agent-notes--note-column (note)
  "Return the column of the side-by-side view that shows NOTE, or nil.
A note on a diff line is shown in the column of its side, `left' or
`right'; other notes, and all notes in the unified view, span the
whole width."
  (let ((rec (and agent-notes--placement
                  (gethash (plist-get note :id) agent-notes--placement))))
    (when (and (eq agent-notes--view 'split)
               (memq (plist-get rec :kind) '(added removed context)))
      (if (equal (plist-get note :side) "old") 'left 'right))))

(defun agent-notes--pane-range (&optional pane)
  "Return (PANE START END) of a side-by-side pane on the current line.
The text of each column, in code rows and in notes, has the
property `agent-notes-pane', `left' or `right'.  PANE defaults to
the pane point is in or at the end of.  Return nil if there is none."
  (let* ((bol (line-beginning-position))
         (eol (line-end-position))
         (pane (or pane
                   (get-text-property (point) 'agent-notes-pane)
                   (and (> (point) bol) (get-text-property (1- (point)) 'agent-notes-pane))))
         (start (and pane (text-property-any bol eol 'agent-notes-pane pane))))
    (when start
      (list pane start (or (text-property-not-all start eol 'agent-notes-pane pane) eol)))))

(defun agent-notes--pane-start (&optional pos)
  "Return where the text of the line at POS (default point) begins.
This is the start of the first pane on the line: after the empty
left half for a note in the right column.  On a line without
panes, it is the beginning of the line."
  (save-excursion
    (goto-char (or pos (point)))
    (let* ((bol (line-beginning-position))
           (eol (line-end-position))
           (start (if (get-text-property bol 'agent-notes-pane)
                      bol
                    (next-single-property-change bol 'agent-notes-pane nil eol))))
      (if (and start (< start eol) (get-text-property start 'agent-notes-pane))
          start
        bol))))

(defun agent-notes--continuation (line)
  "Return the start of the note LINE, to repeat on the lines it wraps to."
  (string-match "\\` *│? *" line)
  (substring line 0 (match-end 0)))

(defun agent-notes--wrap-string (string width cont)
  "Split STRING into lines at most WIDTH columns wide, breaking at spaces.
The lines after the first start with CONT."
  (when (>= (string-width cont) (/ width 2))
    (setq cont ""))
  (let ((lines nil))
    (while (> (string-width string) width)
      (let* ((fit (max 1 (length (truncate-string-to-width string width))))
             (space (cl-position ?\s string :end fit :from-end t))
             (cut (if (and space (> space (length cont))) space fit)))
        (push (substring string 0 cut) lines)
        (setq string (concat cont (string-trim-left (substring string cut) " +")))))
    (nreverse (cons string lines))))

(defun agent-notes--columnize (beg end column &optional truncate)
  "Lay out the lines from BEG to END in COLUMN of the side-by-side view.
COLUMN is `left' or `right'.  Lines wider than the column are
wrapped at spaces, or cut if TRUNCATE.  Each line gets the note
background up to the edge of the column, and the separator between
the columns continues next to it."
  (let* ((half agent-notes--half)
         (separator (propertize "│" 'font-lock-face 'agent-notes-border))
         (before (if (eq column 'right)
                     (concat (make-string half ?\s) separator)
                   ""))
         (after (if (eq column 'left) separator ""))
         (fill (propertize " " 'font-lock-face 'agent-notes-note
                           'display `(space :align-to ,(if (eq column 'left)
                                                           half
                                                         (+ half 1 half)))))
         (end (copy-marker end)))
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (let* ((lbeg (point))
               (line (buffer-substring lbeg (line-end-position)))
               (props (and (> (length line) 0)
                           (cl-loop for prop in '(agent-notes-comment agent-notes-diagram)
                                    for value = (get-text-property 0 prop line)
                                    when value append (list prop value)))))
          (delete-region lbeg (line-end-position))
          ;; The text of the column is marked, so that the cursor can stay in it;
          ;; see `agent-notes--pane-range'.
          (insert (mapconcat (lambda (piece)
                               (concat before
                                       (propertize (concat piece fill) 'agent-notes-pane column)
                                       after))
                             (if truncate
                                 (list (truncate-string-to-width line half nil nil "…"))
                               (agent-notes--wrap-string line half
                                                         (agent-notes--continuation line)))
                             "\n"))
          (when props (add-text-properties lbeg (point) props))
          ;; Keep the note's background out of the other column.
          (put-text-property (point) (min (1+ (point)) (point-max)) 'font-lock-face nil)
          (forward-line 1))))
    (set-marker end nil)))

(defun agent-notes--insert-note (note)
  "Insert NOTE as a section at point."
  (let* ((id (plist-get note :id))
         (comments (plist-get note :comments))
         (resolved (agent-notes--resolved-p note))
         (base (and resolved 'agent-notes-resolved))
         (severity (or (plist-get note :severity) ""))
         (unsent (cl-count-if #'agent-notes--pending-p comments))
         (column (agent-notes--note-column note))
         (pad (if column " " agent-notes--pad))
         (agent-notes--text-width (and column (- agent-notes--half 2)))
         (start (point)))
    (cl-flet ((ins (string &rest faces)
                (insert (propertize string 'font-lock-face
                                    (agent-notes--faces faces 'agent-notes-note))))
              (state-label (comment)
                (cond ((memq (plist-get comment :id) agent-notes--in-flight) "  sending…")
                      ((agent-notes--pending-p comment) "  unsent")
                      (t ""))))
      (magit-insert-section (agent-notes-note id resolved)
        ;; Heading: one line, also shown when the note is folded.
        (insert pad)
        (ins "┌ " 'agent-notes-border)
        (ins (format "#%d" id) 'bold base)
        (ins "  ")
        (ins (plist-get note :author) (agent-notes--author-face (plist-get note :author)))
        (unless (string-empty-p severity)
          (ins "  ")
          (ins severity (agent-notes--severity-face severity)))
        (ins "  ")
        (ins (if resolved "resolved" "open") base)
        (cond ((agent-notes--general-p note))
              ((plist-get note :applied)
               (ins "  suggestion applied" 'success))
              ((plist-get note :outdated)
               (ins "  outdated: the code changed" 'warning))
              ((not (agent-notes--exact-record note))
               (ins (format "  %s (not in diff)" (agent-notes--location note)) 'shadow)))
        (when (plist-get note :github_draft)
          (ins "  GitHub draft: press G" 'agent-notes-pending))
        (when (plist-get note :github)
          (ins "  on GitHub" 'agent-notes-info))
        (when (and (plist-get note :suggestion) (not (plist-get note :applied)) (not resolved))
          (ins "  has a suggestion" 'agent-notes-info))
        (when (> unsent 0)
          (ins (format "  %d unsent" unsent) 'agent-notes-pending))
        (when resolved
          (ins (format "  · %s · " (agent-notes--plural (length comments) "comment")) 'shadow)
          (ins (agent-notes--first-line note 50) base))
        (ins "\n")
        (when column
          (agent-notes--columnize start (point) column t))
        (magit-insert-heading)
        ;; Body: the comments.
        (let ((first t)
              (body (point)))
          (dolist (comment comments)
            (let ((cstart (point))
                  (border (propertize (concat "│ " (if first "" "  "))
                                      'font-lock-face '(agent-notes-border agent-notes-note))))
              (unless first
                (insert pad)
                (ins "│" 'agent-notes-border)
                (ins "\n")
                (insert pad)
                (ins "│ ↳ " 'agent-notes-border)
                (ins (plist-get comment :author)
                     (agent-notes--author-face (plist-get comment :author)))
                (ins (state-label comment) 'agent-notes-pending)
                (ins "\n"))
              (when (and first (memq (plist-get comment :id) agent-notes--in-flight))
                (insert pad)
                (ins "│ " 'agent-notes-border)
                (ins "(sending…)" 'agent-notes-pending)
                (ins "\n"))
              (agent-notes--insert-markdown (plist-get comment :body) base
                                            (concat pad border))
              (put-text-property cstart (point) 'agent-notes-comment (plist-get comment :id))
              (setq first nil)))
          (agent-notes--insert-suggestion note pad)
          (insert pad)
          (ins "└" 'agent-notes-border)
          (ins "\n")
          (when column
            (agent-notes--columnize body (point) column)))
        (put-text-property start (point) 'agent-notes-note id)
        (put-text-property start (point) 'wrap-prefix
                           (concat pad (propertize "│   " 'face '(agent-notes-border
                                                                  agent-notes-note))))))))

(defun agent-notes--insert-notes (rec by-record)
  "Insert the notes anchored to REC, according to BY-RECORD."
  (when rec
    (mapc #'agent-notes--insert-note (reverse (gethash rec by-record)))))

;;;; Unified view

(defun agent-notes--insert-line (rec syntax)
  "Insert the diff line REC in the unified view.
SYNTAX is as in `agent-notes--code-line'."
  (let ((start (point))
        (kind (plist-get rec :kind)))
    (if (eq kind 'meta)
        (insert agent-notes--pad
                (propertize (concat (plist-get rec :text) "\n") 'font-lock-face 'shadow))
      (when agent-notes--line-numbers
        (insert (propertize (format "%5s %5s "
                                    (or (and (not (eq kind 'added)) (plist-get rec :old)) "")
                                    (or (and (not (eq kind 'removed)) (plist-get rec :new)) ""))
                            'font-lock-face 'agent-notes-line-number)))
      (insert (agent-notes--code-line rec syntax)
              (propertize "\n" 'font-lock-face (agent-notes--line-end-face rec syntax))))
    (put-text-property start (point) 'agent-notes-loc rec)
    (put-text-property start (point) 'wrap-prefix agent-notes--pad)))

;;;; Side-by-side view

(defun agent-notes--expand-tabs (string)
  "Return STRING with tabs expanded to spaces, keeping text properties."
  (if (not (string-search "\t" string))
      string
    (let ((col 0) (parts nil))
      (dotimes (i (length string))
        (let ((ch (aref string i)))
          (if (eq ch ?\t)
              (let ((n (- tab-width (% col tab-width))))
                (push (apply #'propertize (make-string n ?\s) (text-properties-at i string))
                      parts)
                (cl-incf col n))
            (push (substring string i (1+ i)) parts)
            (cl-incf col (char-width ch)))))
      (apply #'concat (nreverse parts)))))

(defun agent-notes--fit (text width &optional pad-face)
  "Return TEXT expanded and cut or padded to WIDTH; padding gets PAD-FACE."
  (let* ((s (truncate-string-to-width (agent-notes--expand-tabs text) width nil nil "…"))
         (pad (- width (string-width s))))
    (if (> pad 0)
        (concat s (propertize (make-string pad ?\s) 'font-lock-face pad-face))
      s)))

(defun agent-notes--split-rows (lines)
  "Pair the LINES of a hunk for the side-by-side view.
Return a list of (LEFT RIGHT).  Context lines are on both sides,
and each run of removed lines is paired with the added lines that
follow it.  Other lines, such as \"\\ No newline\", are (:meta REC)."
  (let (rows removed added)
    (cl-flet ((flush ()
                (setq removed (nreverse removed) added (nreverse added))
                (while (or removed added)
                  (push (list (pop removed) (pop added)) rows))))
      (dolist (rec lines)
        (pcase (plist-get rec :kind)
          ('removed (when added (flush)) (push rec removed))
          ('added (push rec added))
          ('context (flush) (push (list rec rec) rows))
          (_ (flush) (push (list :meta rec) rows))))
      (flush))
    (nreverse rows)))

(defun agent-notes--split-cell (rec key syntax)
  "Return one half of a side-by-side row for REC, numbered by KEY.
SYNTAX is as in `agent-notes--code-line'."
  (if (null rec)
      (make-string agent-notes--half ?\s)
    (concat (if (> agent-notes--gutter 0)
                (propertize (format (format "%%%ds " (1- agent-notes--gutter)) (plist-get rec key))
                            'font-lock-face 'agent-notes-line-number)
              "")
            (agent-notes--fit (agent-notes--code-line rec syntax)
                              (max 1 (- agent-notes--half agent-notes--gutter))
                              (agent-notes--line-end-face rec syntax)))))

(defun agent-notes--insert-split-row (left right syntax)
  "Insert a side-by-side row with the records LEFT and RIGHT.
Each half carries its own record, so commands act on the side at
point.  SYNTAX is as in `agent-notes--code-line'."
  (let ((start (point)))
    (insert (agent-notes--split-cell left :old syntax))
    (put-text-property start (point) 'agent-notes-loc (or left right))
    (put-text-property start (point) 'agent-notes-pane 'left)
    (setq start (point))
    (insert (propertize "│" 'font-lock-face 'agent-notes-border))
    (let ((cell (point)))
      (insert (agent-notes--split-cell right :new syntax))
      (put-text-property cell (point) 'agent-notes-pane 'right))
    (insert "\n")
    (put-text-property start (point) 'agent-notes-loc (or right left))))

;;;; Files and hunks

(defun agent-notes--hunk-title (text)
  "Return the title shown for the hunk header TEXT.
It keeps the code context git puts after the line numbers, such as the
function name, and drops the numbers, which the line-number gutter
already shows.  A hunk without context is titled by its first line."
  (if (string-match "\\`@@ -[0-9,]+ \\+\\([0-9]+\\)\\(?:,[0-9]+\\)? @@ ?\\(.*\\)" text)
      (let ((context (string-trim (match-string 2 text))))
        (if (string-empty-p context)
            (format "@@ line %s" (match-string 1 text))
          (concat "@@ " context)))
    text))

(defun agent-notes--insert-hunk (hunk by-record)
  "Insert HUNK, a (HUNK-REC . LINES), with the notes from BY-RECORD."
  (let* ((rec (car hunk))
         (lines (cdr hunk))
         (syntax (agent-notes--hunk-syntax (plist-get rec :path) lines)))
    (magit-insert-section (agent-notes-hunk (cons (plist-get rec :path) (plist-get rec :text)))
      (let ((start (point)))
        (insert (propertize (concat (agent-notes--hunk-title (plist-get rec :text)) "\n")
                            'font-lock-face 'agent-notes-hunk-header))
        (put-text-property start (point) 'agent-notes-loc rec))
      (magit-insert-heading)
      (if (eq agent-notes--view 'split)
          (dolist (row (agent-notes--split-rows lines))
            (pcase-let ((`(,left ,right) row))
              (if (eq left :meta)
                  (agent-notes--insert-line right nil)
                (agent-notes--insert-split-row left right syntax)
                (agent-notes--insert-notes left by-record)
                (unless (eq left right)
                  (agent-notes--insert-notes right by-record)))))
        (dolist (line lines)
          (agent-notes--insert-line line syntax)
          (agent-notes--insert-notes line by-record))))))

(defun agent-notes--insert-file (file by-record)
  "Insert FILE, a (FILE-REC . HUNKS), with the notes from BY-RECORD."
  (let ((rec (car file)))
    (magit-insert-section (agent-notes-file (plist-get rec :path))
      (let ((start (point)))
        (insert (propertize
                 (concat (plist-get rec :path)
                         (cond ((plist-get rec :from)
                                (format "  (renamed from %s)" (plist-get rec :from)))
                               ((equal (plist-get rec :status) "modified") "")
                               (t (format "  (%s)" (plist-get rec :status))))
                         "\n")
                 'font-lock-face 'agent-notes-file-header))
        (put-text-property start (point) 'agent-notes-loc rec))
      (magit-insert-heading)
      (agent-notes--insert-notes rec by-record)
      (dolist (hunk (cdr file))
        (agent-notes--insert-hunk hunk by-record)))))

;;;; Header

(defun agent-notes--all-resolved-p ()
  "Return non-nil if the review has notes, all resolved, and nothing unsent."
  (let ((notes (agent-notes--notes)))
    (and notes
         (cl-every #'agent-notes--resolved-p notes)
         (null (agent-notes--pending-comments))
         (not agent-notes--status))))

(defun agent-notes--insert-header ()
  "Insert the title, the state of the agent and the summaries."
  (let* ((review agent-notes--review)
         (summaries (plist-get review :summaries))
         (base-rev (or (plist-get review :base_rev) "")))
    (magit-insert-section (agent-notes-header)
      (insert (propertize (format "Agent Notes · %s" (agent-notes--repo-name review))
                          'font-lock-face 'agent-notes-title)
              "\n")
      (magit-insert-heading)
      (insert (propertize (format "%s (%s) · %s · %s\n" (agent-notes--scope-label review)
                                  (substring base-rev 0 (min 10 (length base-rev)))
                                  (agent-notes--diff-stats agent-notes--records)
                                  (plist-get review :created))
                          'font-lock-face 'shadow))
      (when agent-notes--status
        (insert (propertize (substitute-command-keys
                             (format "The agent is working: %s  \\<agent-notes-mode-map>\
\\[agent-notes-show-log] shows what is happening, \\[agent-notes-abort] aborts\n"
                                     agent-notes--status))
                            'font-lock-face 'agent-notes-pending)))
      (when agent-notes--changes
        (insert (propertize "Changed by the agent: " 'font-lock-face 'bold)
                (string-join agent-notes--changes ", ") "\n"))
      (when (agent-notes--all-resolved-p)
        (insert (propertize "All notes are resolved. " 'font-lock-face 'success)
                "Commit with Magit when you are ready; this review stays in "
                (propertize ".git/agent-notes" 'font-lock-face 'agent-notes-code) ".\n"))
      (when (and (null summaries) (null (agent-notes--notes)) (not agent-notes--status))
        (insert "No notes yet.  Press A to give the agent a task, "
                "or c on a line to write a note.\n"))
      (dolist (summary summaries)
        (magit-insert-section (agent-notes-summary (plist-get summary :time))
          (insert (propertize (format "%s summary" (plist-get summary :task))
                              'font-lock-face 'bold)
                  (propertize (format "  %s" (plist-get summary :time)) 'font-lock-face 'shadow)
                  "\n")
          (magit-insert-heading)
          (let ((start (point)))
            (agent-notes--insert-markdown (plist-get summary :text) nil "  " t
                                          (max 20 (- (or agent-notes--width 80) 3)))
            (put-text-property start (point) 'wrap-prefix "  "))))
      (insert (propertize (substitute-command-keys
                           "\\<agent-notes-mode-map>\\[agent-notes-dispatch] all commands  \
\\[agent-notes-next-note]/\\[agent-notes-previous-note] open notes  \\[magit-section-toggle] fold  \
\\[agent-notes-toggle-view] side by side  \\[agent-notes-toggle-line-numbers] line numbers\n")
                          'font-lock-face 'shadow))
      (insert "\n"))))

(defvar-local agent-notes--current-path nil
  "The file the cursor is in, shown in the header line.")

(defun agent-notes--path-at (pos)
  "Return the path of the file section containing POS, or nil."
  (let ((section (and magit-root-section (magit-section-at pos))))
    (while (and section (not (eq (oref section type) 'agent-notes-file)))
      (setq section (oref section parent)))
    (and section (oref section value))))

(defun agent-notes--update-current-path ()
  "Update the file name in the header line after the cursor moved."
  (let ((path (ignore-errors (agent-notes--path-at (point)))))
    (unless (equal path agent-notes--current-path)
      (setq agent-notes--current-path path)
      (force-mode-line-update))))

(defun agent-notes--header-line ()
  "Return the header line of the review buffer.
It starts with the file the cursor is in, so you can tell which file
a change belongs to however far you have scrolled."
  (when agent-notes--review
    (let* ((notes (agent-notes--notes))
           (resolved (cl-count-if #'agent-notes--resolved-p notes))
           (unsent (length (agent-notes--pending-comments))))
      (concat " "
              (if agent-notes--current-path
                  (concat (propertize agent-notes--current-path 'face 'bold) "  ·  ")
                "")
              (agent-notes--scope-label agent-notes--review)
              (if (agent-notes--all-resolved-p)
                  (propertize (format "  ·  all %d resolved" resolved) 'face 'success)
                (format "  ·  %d open, %d resolved" (- (length notes) resolved) resolved))
              (if (> unsent 0)
                  (propertize (format "  ·  %d unsent (s to send)" unsent)
                              'face 'agent-notes-pending)
                "")
              (format "  ·  %s: " (agent-notes--agent-name))
              (if agent-notes--status
                  (propertize (format "%s %s" agent-notes--status (or (agent-notes--elapsed) ""))
                              'face 'agent-notes-pending)
                "idle")))))

;;;; Sections and positions

(defun agent-notes--sections (type &optional pred)
  "Return the sections of TYPE that satisfy PRED, in buffer order."
  (let (result)
    (when magit-root-section
      (magit-map-sections (lambda (section)
                            (when (and (eq (oref section type) type)
                                       (or (null pred) (funcall pred section)))
                              (push section result)))))
    (sort result (lambda (a b) (< (oref a start) (oref b start))))))

(defun agent-notes--note-section (id)
  "Return the section of the note ID, or nil."
  (car (agent-notes--sections 'agent-notes-note
                              (lambda (section) (eql (oref section value) id)))))

(defun agent-notes--note-at-point ()
  "Return the note at point, or the first note below the current line."
  (let ((id (or (get-text-property (point) 'agent-notes-note)
                (save-excursion
                  (forward-line 1)
                  (get-text-property (point) 'agent-notes-note)))))
    (and id (agent-notes--note id))))

(defun agent-notes--require-note ()
  "Return the note at point or signal an error."
  (or (agent-notes--note-at-point) (user-error "No note at point")))

(defun agent-notes--point-anchor ()
  "Describe the position at point so it can be found after re-rendering."
  (list :comment (get-text-property (point) 'agent-notes-comment)
        :note (get-text-property (point) 'agent-notes-note)
        :rec (get-text-property (point) 'agent-notes-loc)
        :line (line-number-at-pos)
        :column (current-column)))

(defun agent-notes--find-prop (prop value &optional test)
  "Return the start of the first region whose PROP is VALUE under TEST."
  (save-excursion
    (goto-char (point-min))
    (let ((match (text-property-search-forward prop value (or test #'eq))))
      (and match (prop-match-beginning match)))))

(defun agent-notes--anchor-position (anchor)
  "Return the position described by ANCHOR in the current rendering."
  (or (and (plist-get anchor :comment)
           (agent-notes--find-prop 'agent-notes-comment (plist-get anchor :comment)))
      (let ((section (and (plist-get anchor :note)
                          (agent-notes--note-section (plist-get anchor :note)))))
        (and section (oref section start)))
      (let ((pos (and (plist-get anchor :rec)
                      (agent-notes--find-prop 'agent-notes-loc (plist-get anchor :rec) #'equal))))
        (and pos (save-excursion (goto-char pos)
                                 (move-to-column (plist-get anchor :column))
                                 (point))))
      (save-excursion (goto-char (point-min))
                      (forward-line (1- (plist-get anchor :line)))
                      (point))))

;;;; Drawing

(defun agent-notes--layout (win)
  "Compute the widths used to render for the window WIN."
  (setq agent-notes--width (if (window-live-p win) (window-max-chars-per-line win) 160))
  (if (not (eq agent-notes--view 'split))
      (setq agent-notes--gutter (if agent-notes--line-numbers 12 0)
            agent-notes--pad (make-string (if agent-notes--line-numbers 12 2) ?\s))
    (let ((max-line 0))
      (dolist (rec agent-notes--records)
        (setq max-line (max max-line (or (plist-get rec :old) 0) (or (plist-get rec :new) 0))))
      (setq agent-notes--gutter (if agent-notes--line-numbers
                                    (1+ (max 4 (length (number-to-string max-line))))
                                  0)
            ;; Two halves and a separator, leaving the last column free.
            agent-notes--half (max 20 (/ (- agent-notes--width 2) 2))
            agent-notes--pad (make-string (max 2 agent-notes--gutter) ?\s)))))

(defun agent-notes--render (&optional win)
  "Redraw the review buffer for WIN, keeping point on the same thing."
  (let* ((win (or win (get-buffer-window (current-buffer) t)))
         (pos (if win (window-point win) (point)))
         (anchor (save-excursion (goto-char pos) (agent-notes--point-anchor)))
         (offset (and win (count-lines (window-start win) pos)))
         (inhibit-read-only t)
         (by-record (make-hash-table :test #'eq))
         (general nil))
    (agent-notes--layout win)
    (setq agent-notes--placement (make-hash-table))
    (dolist (note (agent-notes--notes))
      (let ((rec (agent-notes--anchor-record note)))
        (if rec
            (progn (push note (gethash rec by-record))
                   (puthash (plist-get note :id) rec agent-notes--placement))
          (push note general))))
    (erase-buffer)
    (magit-insert-section (agent-notes-root)
      (agent-notes--insert-header)
      (when general
        (magit-insert-section (agent-notes-general)
          (insert (propertize "General notes\n" 'font-lock-face 'agent-notes-file-header))
          (magit-insert-heading)
          (mapc #'agent-notes--insert-note (nreverse general))))
      (dolist (file (agent-notes--file-tree agent-notes--records))
        (agent-notes--insert-file file by-record)))
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (let ((new-pos (agent-notes--anchor-position anchor)))
      (goto-char new-pos)
      (when win
        (set-window-point win new-pos)
        (set-window-start win (save-excursion (forward-line (- offset)) (point)) t)))
    (force-mode-line-update)))

(defun agent-notes--on-window-size-change (win)
  "Redraw the side-by-side view when the width of WIN changes."
  (when (window-live-p win)
    (with-current-buffer (window-buffer win)
      (when (and (derived-mode-p 'agent-notes-mode)
                 (eq agent-notes--view 'split)
                 (not (eql agent-notes--width (window-max-chars-per-line win))))
        (agent-notes--render win)))))

(provide 'agent-notes-render)
;;; agent-notes-render.el ends here
