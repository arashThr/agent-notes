;;; agent-notes-agent.el --- Talking to the agent CLI for agent-notes -*- lexical-binding: t; -*-

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

;; Part of agent-notes; see agent-notes.el.  This file builds the
;; prompts, runs the agent CLI (Copilot, Claude Code or Codex) in the
;; review's session, applies its JSON answer, notices which files it
;; changed, and applies the code changes it suggests in notes.

;;; Code:

(require 'agent-notes-core)
(require 'agent-notes-diff)
(require 'agent-notes-render)
(require 'agent-notes-log)

(declare-function agent-notes--get-buffer "agent-notes" (file))
(declare-function treesit-parser-list "treesit.c" (&optional buffer language tag))
(declare-function treesit-buffer-root-node "treesit" (&optional language tag))
(declare-function treesit-node-check "treesit.c" (node property))

(defvar-local agent-notes--ticker nil
  "Timer that updates the elapsed time while the agent works.")

;;;; Prompts

(defconst agent-notes--note-spec
  "Each note is anchored to one line of the diff:
- \"path\": file path relative to the repository root, without a/ or b/ prefixes.
- \"side\": \"new\" for added (+) or unchanged context lines, with the line number in the new version of the file; \"old\" for removed (-) lines, with the line number in the old version.
- \"line\": the line number, as an integer.
- \"severity\": one of \"issue\", \"warning\", \"suggestion\", \"question\", \"nit\", or \"info\" for explanations that are not problems.
- \"body\": the note in Markdown. Be specific and concise.
- \"suggestion\" (optional, only for \"side\": \"new\"): when you know the exact fix, the replacement code, as one string with \\n between lines and the original indentation. Leave it out when unsure or when the fix spans several places.
- \"original\" (required with \"suggestion\"): the exact lines of the current file that \"suggestion\" replaces, copied verbatim as whole lines with their indentation, as one string. The editor finds this text near \"line\" and replaces it with \"suggestion\", like search and replace, when the user presses one key. Both must cover the same whole lines: if \"suggestion\" repeats a line for context (for example the function's signature), \"original\" must include that line too, or it ends up twice in the file. After the replacement the file must still be valid code: brackets and strings balanced, indentation consistent, no line duplicated or lost.
To comment on the change as a whole rather than a line, use \"path\": \"\" and \"line\": 0."
  "Description of the note format given to the agent.")

(defun agent-notes--permissions-prompt ()
  "Return the part of the prompt that says what the agent may do."
  (if agent-notes-allow-edits
      (concat "You may read any file in the repository and run read-only git commands for context. "
              "You can also edit files in the repository, but only when the user asks you to "
              "change something. Never commit, stage, stash or reset, and do not touch the "
              "review files described above.\n")
    (concat "You may read any file in the repository and run read-only git commands for context. "
            "You cannot modify files in this session: when the user asks for a change, "
            "describe it and show the code instead.\n")))

(defun agent-notes--scope-prompt (review)
  "Return a description of REVIEW's scope for the agent."
  (let ((base-rev (plist-get review :base_rev))
        (head (plist-get review :head_rev)))
    (pcase (plist-get review :scope)
      ("branch"
       (format "all changes on the current branch since it diverged from %s (merge-base %s)%s"
               (plist-get review :base) base-rev
               (if agent-notes-branch-include-uncommitted
                   ", including uncommitted and untracked files" "")))
      ("staged"
       (format "the staged changes (the index) compared to HEAD (%s); unstaged and untracked \
changes are not part of the review" base-rev))
      ("commit"
       (format "the changes made by commit %s%s, compared to its first parent %s"
               head (let ((subject (plist-get review :subject)))
                      (if subject (format " (\"%s\")" subject) ""))
               base-rev))
      ("range"
       (format "the changes of the range %s: from %s to %s" (plist-get review :base) base-rev head))
      (_ (format "uncommitted changes (staged, unstaged and untracked files) compared to HEAD (%s)"
                 base-rev)))))

(defun agent-notes--new-side-prompt (review)
  "Return what the agent must know when REVIEW's diff is not the working tree."
  (if (agent-notes--shows-working-tree-p review)
      ""
    (let ((spec (if (equal (plist-get review :scope) "staged")
                    ":PATH"
                  (concat (plist-get review :head_rev) ":PATH"))))
      (format "The new side of this diff is %s, not the files in the working tree, which may \
differ from it.  To read a file as it is in the diff, run `git show %s`.  Edits you make go \
to the working tree, and suggested changes are applied there too, so copy \"original\" \
from the file in the working tree.\n"
              (if (equal (plist-get review :scope) "staged")
                  "the index (the staged version of each file)"
                (format "commit %s" (plist-get review :head_rev)))
              spec))))

(defun agent-notes--context-prompt (&optional include-diff)
  "Return the part of the prompt describing the review.
It lists the changed files.  If INCLUDE-DIFF, it also has the diff
when it is small enough; see `agent-notes-inline-diff-limit'."
  (let ((review agent-notes--review))
    (concat
     "You are helping the user go through code changes in a git repository, inside their editor. "
     "Your notes are shown inline in the diff, and the user can reply to them.\n"
     "Repository: " (plist-get review :root) "\n"
     "Scope: " (agent-notes--scope-prompt review)
     ".\nThe exact unified diff under review, which all line numbers refer to, is saved at:\n  "
     (agent-notes--diff-file agent-notes--file) "\n"
     (agent-notes--new-side-prompt review)
     "The review itself is stored in " (file-name-directory agent-notes--file) ".\n"
     (agent-notes--permissions-prompt)
     "\n" (agent-notes--files-prompt)
     (if include-diff (agent-notes--diff-prompt) ""))))

(defun agent-notes--files-prompt ()
  "Return the list of changed files with the size of their changes."
  (let ((files (agent-notes--file-tree agent-notes--records)))
    (if (null files)
        "The diff is empty.\n"
      (concat
       (format "Changed files (%s):\n" (agent-notes--diff-stats agent-notes--records))
       (mapconcat
        (lambda (file)
          (let* ((rec (car file))
                 (status (plist-get rec :status))
                 (lines (apply #'append (mapcar #'cdr (cdr file)))))
            (format "- %s  +%d -%d%s\n" (plist-get rec :path)
                    (cl-count 'added lines :key (lambda (r) (plist-get r :kind)))
                    (cl-count 'removed lines :key (lambda (r) (plist-get r :kind)))
                    (cond ((plist-get rec :from)
                           (format " (renamed from %s)" (plist-get rec :from)))
                          ((equal status "modified") "")
                          (t (format " (%s)" status))))))
        files "")))))

(defun agent-notes--fence-for (text)
  "Return a code fence of backticks that does not occur in TEXT."
  (let ((fence "```"))
    (while (string-match-p (concat "^[ \t+-]*" (regexp-quote fence)) text)
      (setq fence (concat fence "`")))
    fence))

(defun agent-notes--diff-prompt ()
  "Return the diff for the prompt, or how to read it if it is large."
  (let ((diff (string-trim-right (or (agent-notes--stored-diff) ""))))
    (if (and agent-notes-inline-diff-limit
             (<= (length diff) agent-notes-inline-diff-limit))
        (let ((fence (agent-notes--fence-for diff)))
          (concat "\nThe full diff (the same as the diff file):\n"
                  fence "diff\n" diff "\n" fence "\n"))
      (format "\nThe diff is large (%d lines), so it is not included here.  Read the \
diff file in parts until you have read all of it, and do not skip any of the \
files listed above.\n"
              (1+ (cl-count ?\n diff))))))

(defun agent-notes--json-instructions (example)
  "Return the instructions for the final JSON block, showing EXAMPLE."
  (concat "Your final message must end with exactly one fenced ```json code block "
          "and nothing after it, with this shape:\n```json\n" example "\n```\n"))

(defun agent-notes--existing-notes-prompt ()
  "Return the list of existing notes, so the agent does not repeat them."
  (let ((notes (agent-notes--notes)))
    (if (null notes)
        ""
      (concat "\nThese notes already exist on this diff; do not repeat them:\n"
              (mapconcat (lambda (note)
                           (format "- #%d %s: %s\n" (plist-get note :id)
                                   (agent-notes--location note)
                                   (agent-notes--first-line note 100)))
                         notes "")))))

(defun agent-notes--diagram-format ()
  "Return the format of diagrams: `graphviz' or `text'."
  (pcase agent-notes-diagram-format
    ('auto (if (executable-find agent-notes-dot-program) 'graphviz 'text))
    (format format)))

(defun agent-notes--diagram-prompt ()
  "Return the instructions for drawing diagrams."
  (if (eq (agent-notes--diagram-format) 'graphviz)
      (concat "When you draw a diagram, write it in Graphviz DOT in a ```dot fenced block; "
              "the editor renders it as an image. Use one digraph with rankdir=TB (or LR "
              "when that is clearer), node [shape=box], short labels and at most about 15 "
              "nodes. Do not set colors, fonts or sizes, and do not use HTML labels. Mark "
              "new parts with style=bold and changed parts with style=dashed.")
    (concat "When you draw a diagram, draw it as plain text with Unicode box-drawing "
            "characters and arrows, in a ```text fenced block at most 78 columns wide.")))

(defun agent-notes--task-prompt (task)
  "Return the prompt asking the agent to do TASK, a (NAME . INSTRUCTIONS)."
  (concat
   (agent-notes--context-prompt t)
   "\nBefore you start, read the whole diff, and open the changed files wherever "
   "you need more context than the diff shows. Your task:\n" (cdr task) "\n"
   (if agent-notes-extra-instructions
       (concat "\nAdditional instructions from the user:\n" agent-notes-extra-instructions "\n")
     "")
   (agent-notes--existing-notes-prompt)
   "\nDo not modify any files for this task unless the task explicitly asks you to.\n"
   "The summary is shown as Markdown in a plain-text editor: use short paragraphs, "
   "bullet points and fenced code blocks, but no tables, images or HTML.\n"
   (agent-notes--diagram-prompt) "\n\n"
   agent-notes--note-spec "\n\n"
   (agent-notes--json-instructions
    (concat "{\"summary\": \"...\",\n"
            " \"notes\": [{\"path\": \"src/example.py\", \"line\": 42, \"side\": \"new\", "
            "\"severity\": \"warning\", \"body\": \"...\"}]}"))))

(defun agent-notes--hunk-excerpt (rec)
  "Return the code around the diff line REC in its hunk, as text.
Up to `agent-notes-thread-context-lines' lines before and after REC
are included, each with its old and new line numbers; REC's line is
marked with >>.  Return nil if REC is not a line of the diff."
  (let* ((records (vconcat agent-notes--records))
         (i (cl-position rec records :test #'eq)))
    (when i
      (cl-flet ((code-p (j) (memq (plist-get (aref records j) :kind)
                                  '(context added removed meta))))
        (let ((start i)
              (end i)
              (radius (max 0 agent-notes-thread-context-lines)))
          (while (and (> start 0) (code-p (1- start))) (cl-decf start))
          (while (and (< (1+ end) (length records)) (code-p (1+ end))) (cl-incf end))
          (let ((from (max start (- i radius)))
                (to (min end (+ i radius)))
                (header (and (> start 0) (aref records (1- start)))))
            (concat
             "The thread's line in the diff (marked >>), with the old and new line numbers:\n"
             (if (eq (plist-get header :kind) 'hunk)
                 (concat "   " (plist-get header :text) "\n")
               "")
             (if (> from start) "   ...\n" "")
             (mapconcat
              (lambda (j)
                (let* ((r (aref records j))
                       (kind (plist-get r :kind)))
                  (format "%s %5s %5s %s\n" (if (= j i) ">>" "  ")
                          (if (memq kind '(added meta)) "" (plist-get r :old))
                          (if (memq kind '(removed meta)) "" (plist-get r :new))
                          (plist-get r :text))))
              (number-sequence from to) "")
             (if (< to end) "   ...\n" ""))))))))

(defun agent-notes--format-thread (note new-ids)
  "Return NOTE as text for the agent; comments in NEW-IDS are marked NEW."
  (let ((rec (agent-notes--exact-record note)))
    (concat
     (format "--- Thread #%d · %s · started by %s%s · status: %s\n"
             (plist-get note :id)
             (if (agent-notes--general-p note)
                 "about the whole change"
               (format "%s %s line %s" (plist-get note :path) (plist-get note :side)
                       (plist-get note :line)))
             (if (equal (plist-get note :author) "agent") "you (the agent)" "the user")
             (let ((s (plist-get note :severity)))
               (if (and s (not (string-empty-p s))) (format " · severity: %s" s) ""))
             (plist-get note :status))
     (cond ((plist-get note :outdated)
            (format "The code this thread was about has changed; it was: %s\n"
                    (plist-get note :text)))
           (rec (or (agent-notes--hunk-excerpt rec)
                    (format "Diff line: %s\n" (plist-get rec :text))))
           (t ""))
     (let ((suggestion (plist-get note :suggestion)))
       (if (not (stringp suggestion))
           ""
         (format "Your suggested change (%s) replaces:\n%s\nwith:\n%s\n"
                 (if (plist-get note :applied) "the user applied it" "not applied")
                 (or (plist-get note :original) "")
                 suggestion)))
     (mapconcat (lambda (c)
                  (format "[%s%s]\n%s\n"
                          (if (equal (plist-get c :author) "agent") "agent" "user")
                          (if (memq (plist-get c :id) new-ids) ", NEW" "")
                          (plist-get c :body)))
                (plist-get note :comments) "")
     "\n")))

(defun agent-notes--reply-prompt (notes new-ids)
  "Return the prompt sending the user's comments in NEW-IDS on NOTES."
  (concat
   "The user has gone through the notes on the diff and responded.\n"
   (agent-notes--context-prompt)
   "\nBelow are the threads with new messages from the user (marked NEW). "
   "Threads started by the user are new comments or questions for you. "
   "Answer every thread that has NEW messages. Be direct and concise; if the user is right, say so. "
   "Set \"resolve\" to true only when the thread's concern is settled. "
   "If the discussion reveals other problems, you may add new notes.\n"
   (if agent-notes-allow-edits
       (concat "When a message asks you to change the code, make the change by editing the "
               "files, then say in your reply which files and lines you changed. Do not change "
               "anything the user did not ask for. "
               (if (agent-notes--shows-working-tree-p agent-notes--review)
                   "The diff is refreshed after you finish and the notes move with the code. "
                 ""))
     "")
   "When a message asks for a suggestion rather than a change, add \"suggestion\" and "
   "\"original\" to your reply instead, with the same meaning as in a note; the user can "
   "then apply it with one key.\n"
   "When a message asks you to post or leave a comment on GitHub (the pull request), do NOT "
   "run gh or any other command to do it. Put the comment in \"github\" in your reply: "
   "the text as it should appear on GitHub, in Markdown. Readers there cannot see this "
   "thread, so make it self-contained and name the file and the code it is about. The user "
   "reads and confirms it in Emacs before anything is posted. Use \"github\" only when a "
   "message asks for it; still answer in \"body\" as usual.\n"
   (agent-notes--diagram-prompt) "\n\n"
   (mapconcat (lambda (note) (agent-notes--format-thread note new-ids)) notes "")
   agent-notes--note-spec "\n\n"
   (agent-notes--json-instructions
    "{\"replies\": [{\"note\": 3, \"body\": \"...\", \"resolve\": false}],\n \"notes\": []}")))

;;;; Applying the answer

(defun agent-notes--extract-json (text)
  "Return the last JSON object in TEXT, preferring fenced code blocks."
  (let (blocks current in-block)
    (dolist (line (split-string text "\n"))
      (cond ((string-match-p "\\`[ \t]*```" line)
             (if in-block
                 (progn (push (string-join (nreverse current) "\n") blocks)
                        (setq in-block nil current nil))
               (setq in-block t current nil)))
            (in-block (push line current))))
    (cl-flet ((parse (s) (let ((v (ignore-errors (agent-notes--json-parse s))))
                           (and (consp v) (keywordp (car v)) v))))
      (or (cl-some #'parse blocks)
          (let ((beg (string-search "{" text))
                (end (cl-position ?} text :from-end t)))
            (and beg end (< beg end) (parse (substring text beg (1+ end)))))
          (error "Could not find a JSON object in the agent's answer")))))

(defvar agent-notes--dropped-suggestions nil
  "Ids of the notes whose suggested change was dropped.
Bound while applying an answer of the agent.")

(defun agent-notes--absorb-context (lines start span new)
  "Widen the lines START to START+SPAN-1 of LINES to the context in NEW.
LINES is the file and NEW the suggested code, as lists of lines.
When NEW begins with the lines just above that region, or ends with
the lines just below it, the agent repeated them for context: they
are added to the region, so that they are not duplicated.  Return
\(START . SPAN) of the widened region."
  (let* ((file (vconcat lines))
         (new (vconcat new))
         (n (length new))
         (above 0)
         (below 0))
    (cl-flet ((same (a b) (agent-notes--same-line-p a b))
              ;; Whether new lines FROM..FROM+K-1 equal the file's lines
              ;; from AT, and are not all blank.
              (repeats (from k at)
                (and (cl-loop for j below k
                              always (agent-notes--same-line-p (aref new (+ from j))
                                                               (aref file (+ at j))))
                     (cl-loop for j below k
                              thereis (not (string-blank-p (aref new (+ from j))))))))
      ;; START and the region are 1-based; the vectors are 0-based.
      (unless (same (aref new 0) (aref file (1- start)))
        (cl-loop for k from 1 to (min (1- n) (1- start))
                 when (repeats 0 k (- start 1 k))
                 do (setq above k)))
      (let ((after (+ start span -1)))
        (unless (same (aref new (1- n)) (aref file (1- after)))
          (cl-loop for k from 1 to (min (- n above 1) (- (length file) after))
                   when (repeats (- n k) k after)
                   do (setq below k)))))
    (cons (- start above) (+ span above below))))

(defun agent-notes--set-suggestion (note suggestion original &optional end-line)
  "Attach SUGGESTION, the code that replaces ORIGINAL, to NOTE.
ORIGINAL is the text the agent says it replaces; it is looked up in
the file, nearest to the note's line.  Without ORIGINAL, the note's
line through END-LINE is replaced, widened by the context lines that
SUGGESTION repeats.  Return non-nil if the suggestion was attached.
When the code to replace is not in the file, the suggestion is
dropped and the note's id is added to
`agent-notes--dropped-suggestions'."
  (when (and (stringp suggestion)
             (not (string-blank-p suggestion))
             (equal (plist-get note :side) "new")
             (not (agent-notes--general-p note))
             (> (plist-get note :line) 0))
    (let* ((line (plist-get note :line))
           (lines (agent-notes--read-lines (plist-get note :path)))
           (new (agent-notes--split-lines suggestion))
           (region
            (cond ((null lines) nil)
                  ((and (stringp original) (not (string-blank-p original)))
                   (let* ((target (agent-notes--split-lines original))
                          (start (agent-notes--locate-lines lines target line)))
                     (and start (cons start (length target)))))
                  (t
                   (let* ((end (if end-line (agent-notes--as-int end-line) line))
                          (span (max 1 (min 500 (1+ (- end line))))))
                     (and (<= (+ line span -1) (length lines))
                          (agent-notes--absorb-context lines line span new)))))))
      (if (not region)
          (progn (push (plist-get note :id) agent-notes--dropped-suggestions)
                 nil)
        (plist-put note :suggestion (string-remove-suffix "\n" suggestion))
        (plist-put note :span (cdr region))
        ;; The exact code it replaces, looked up again when applied.
        (plist-put note :original
                   (string-join (seq-subseq lines (1- (car region))
                                            (+ (car region) (cdr region) -1))
                                "\n"))
        (plist-put note :applied nil)
        t))))

(defun agent-notes--describe-dropped ()
  "Describe `agent-notes--dropped-suggestions' for the log."
  (if (null agent-notes--dropped-suggestions)
      ""
    (format "\nIgnored the suggested change of %s: the code it replaces is not in the file."
            (mapconcat (lambda (id) (format "#%d" id))
                       (reverse agent-notes--dropped-suggestions) ", "))))

(defun agent-notes--add-agent-note (spec)
  "Add the note described by the agent's JSON SPEC; return it or nil."
  (let ((body (plist-get spec :body))
        (severity (plist-get spec :severity)))
    (when (and (stringp body) (not (string-blank-p body)))
      (let ((note (agent-notes--add-note
                   "agent"
                   (agent-notes--normalize-path (plist-get spec :path))
                   (if (equal (plist-get spec :side) "old") "old" "new")
                   (agent-notes--as-int (plist-get spec :line))
                   (if (stringp severity) severity "suggestion")
                   body "sent")))
        (agent-notes--set-suggestion note (plist-get spec :suggestion) (plist-get spec :original)
                                     (plist-get spec :end_line))
        note))))

(defun agent-notes--describe-new-notes (notes)
  "Describe the new NOTES for the log, or return nil if there are none."
  (when notes
    (let ((suggestions (cl-count-if (lambda (n) (plist-get n :suggestion)) notes)))
      (concat "added " (agent-notes--plural (length notes) "note")
              (if (> suggestions 0)
                  (format " (%d with a suggested change)" suggestions)
                "")))))

(defun agent-notes--apply-review (data task-name)
  "Store the result DATA of the task TASK-NAME returned by the agent.
Return a description of what changed."
  (unless (or (plist-member data :notes) (plist-member data :summary))
    (error "The agent's answer has no \"notes\""))
  (let* ((agent-notes--dropped-suggestions nil)
         (summary (plist-get data :summary))
         (added (delq nil (mapcar #'agent-notes--add-agent-note (plist-get data :notes))))
         (has-summary nil))
    (when (and (stringp summary) (not (string-blank-p summary)))
      (setq has-summary t)
      (setq agent-notes--review
            (plist-put agent-notes--review :summaries
                       (append (plist-get agent-notes--review :summaries)
                               (list (list :task task-name :text summary
                                           :time (format-time-string "%F %R")))))))
    (concat (agent-notes--capitalize-first
             (or (agent-notes--describe-new-notes added) "added no notes"))
            (if has-summary " and a summary" "")
            "."
            (agent-notes--describe-dropped))))

(defun agent-notes--capitalize-first (string)
  "Return STRING with its first letter in upper case."
  (if (string-empty-p string) string
    (concat (upcase (substring string 0 1)) (substring string 1))))

(defun agent-notes--apply-replies (data in-flight)
  "Store the agent's reply DATA to the comments IN-FLIGHT.
Return a description of what changed."
  (unless (or (plist-member data :replies) (plist-member data :notes))
    (error "The agent's answer has no \"replies\""))
  (dolist (note (agent-notes--notes))
    (dolist (comment (plist-get note :comments))
      (when (memq (plist-get comment :id) in-flight)
        (plist-put comment :state "sent"))))
  (let ((agent-notes--dropped-suggestions nil)
        (answered 0) (resolved 0) (suggested 0) (drafted 0) (unknown nil))
    (dolist (reply (plist-get data :replies))
      (let ((note (agent-notes--note (agent-notes--as-int (plist-get reply :note))))
            (body (plist-get reply :body)))
        (if (not note)
            (push (format "%S" (plist-get reply :note)) unknown)
          (when (and (stringp body) (not (string-blank-p body)))
            (cl-incf answered)
            (plist-put note :comments
                       (append (plist-get note :comments)
                               (list (agent-notes--make-comment "agent" body "sent")))))
          (when (agent-notes--set-suggestion note (plist-get reply :suggestion)
                                             (plist-get reply :original)
                                             (plist-get reply :end_line))
            (cl-incf suggested))
          (let ((github (plist-get reply :github)))
            (when (and (stringp github) (not (string-blank-p github)))
              (cl-incf drafted)
              (plist-put note :github_draft (string-trim github))))
          (when (and (plist-get reply :resolve) (not (agent-notes--resolved-p note)))
            (cl-incf resolved)
            (plist-put note :status "resolved")))))
    (let ((added (delq nil (mapcar #'agent-notes--add-agent-note (plist-get data :notes)))))
      (concat (format "Answered %s" (agent-notes--plural answered "thread"))
              (if (> resolved 0) (format ", resolved %d" resolved) "")
              (if (> suggested 0) (format ", suggested %s" (agent-notes--plural suggested "change")) "")
              (if (> drafted 0)
                  (format ", drafted %s (press G on %s to review and post)"
                          (agent-notes--plural drafted "GitHub comment")
                          (if (= drafted 1) "the note" "each note"))
                "")
              (if added (concat ", " (agent-notes--describe-new-notes added)) "")
              "."
              (if unknown
                  (format "\nIgnored replies to notes that don't exist: %s."
                          (string-join (nreverse unknown) ", "))
                "")
              (agent-notes--describe-dropped)))))

;;;; Running the agent

(defun agent-notes--copilot-args (request)
  "Return the Copilot arguments for REQUEST; see `agent-notes-agents'.
Copilot creates or resumes the session given by --session-id."
  (let ((allowed (if agent-notes-allow-edits
                     (append agent-notes-allowed-tools '("write"))
                   agent-notes-allowed-tools))
        (denied (if agent-notes-allow-edits
                    (remove "write" agent-notes-denied-tools)
                  (cl-adjoin "write" agent-notes-denied-tools :test #'equal))))
    (append (list "-s" "--session-id" (plist-get request :session)
                  (concat "--add-dir=" (file-name-directory agent-notes--file)))
            (mapcar (lambda (tool) (concat "--allow-tool=" tool)) allowed)
            (mapcar (lambda (tool) (concat "--deny-tool=" tool)) denied)
            agent-notes-copilot-extra-args
            (list "-p" (plist-get request :prompt)))))

(defconst agent-notes--claude-edit-tools '("Edit" "Write" "MultiEdit" "NotebookEdit")
  "The Claude Code tools that change files.")

(defun agent-notes--claude-tool (pattern)
  "Turn the Copilot permission PATTERN into a Claude Code one, or nil."
  (cond ((string-match "\\`shell(\\(.*\\))\\'" pattern)
         (format "Bash(%s:*)" (match-string 1 pattern)))
        ((equal pattern "shell") "Bash")
        ((equal pattern "write") nil)
        (t pattern)))

(defun agent-notes--claude-session-p (session)
  "Return non-nil if Claude Code has stored the conversation SESSION."
  (let ((dir (expand-file-name "projects" (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude"))))
    (and (stringp session) (file-directory-p dir)
         (file-expand-wildcards (expand-file-name (concat "*/" session ".jsonl") dir)))))

(defun agent-notes--claude-args (request)
  "Return the Claude Code arguments for REQUEST; see `agent-notes-agents'.
The prompt goes to standard input.  The first request creates the
session with --session-id; later ones continue it with --resume."
  (let* ((session (plist-get request :session))
         (allowed (delq nil (mapcar #'agent-notes--claude-tool agent-notes-allowed-tools)))
         (denied (append (delq nil (mapcar #'agent-notes--claude-tool agent-notes-denied-tools))
                         (unless agent-notes-allow-edits agent-notes--claude-edit-tools))))
    (append (list "-p" "--output-format" "text")
            (if (or (plist-get request :resume) (agent-notes--claude-session-p session))
                (list "--resume" session)
              (list "--session-id" session))
            (list "--permission-mode" (if agent-notes-allow-edits "acceptEdits" "default")
                  "--add-dir" (file-name-directory agent-notes--file))
            ;; These options take several values, so each list ends at the next option.
            (and allowed (cons "--allowedTools" allowed))
            (and denied (cons "--disallowedTools" denied))
            agent-notes-claude-extra-args)))

(defun agent-notes--grok-session-p (session)
  "Return non-nil if Grok has stored the conversation SESSION."
  (let ((dir (expand-file-name "sessions" (or (getenv "GROK_HOME") "~/.grok"))))
    (and (stringp session) (file-directory-p dir)
         (file-expand-wildcards (expand-file-name (concat "*/" session) dir)))))

(defun agent-notes--grok-args (request)
  "Return the Grok arguments for REQUEST; see `agent-notes-agents'.
The first request creates the session with --session-id; later ones
continue it with --resume.  Grok reads permission rules in the
Claude Code syntax, and refuses --add-dir together with --resume, so
the review's folder is added only when the session is created."
  (let* ((session (plist-get request :session))
         (resume (or (plist-get request :resume) (agent-notes--grok-session-p session)))
         (allowed (delq nil (mapcar #'agent-notes--claude-tool agent-notes-allowed-tools)))
         (denied (append (delq nil (mapcar #'agent-notes--claude-tool agent-notes-denied-tools))
                         (unless agent-notes-allow-edits agent-notes--claude-edit-tools))))
    (append (list "--output-format" "plain")
            (if resume
                (list "--resume" session)
              (list "--session-id" session
                    "--add-dir" (file-name-directory agent-notes--file)))
            (list "--permission-mode" (if agent-notes-allow-edits "acceptEdits" "default"))
            (apply #'append (mapcar (lambda (rule) (list "--allow" rule)) allowed))
            (apply #'append (mapcar (lambda (rule) (list "--deny" rule)) denied))
            agent-notes-grok-extra-args
            (list "-p" (plist-get request :prompt)))))

(defun agent-notes--codex-args (request)
  "Return the Codex arguments for REQUEST; see `agent-notes-agents'.
Codex runs in its sandbox, read-only unless `agent-notes-allow-edits'.
It chooses the session id, which is found in its output."
  (append (list "exec" "--skip-git-repo-check"
                "--sandbox" (if agent-notes-allow-edits "workspace-write" "read-only")
                "--output-last-message" (plist-get request :output-file))
          agent-notes-codex-extra-args
          (and (plist-get request :resume) (list "resume" (plist-get request :session)))
          (list (plist-get request :prompt))))

(defun agent-notes--use-agent (agent)
  "Make the session of the current review belong to AGENT.
When the review used another agent, start a new session and log it."
  (let* ((name (symbol-name (car agent)))
         (review agent-notes--review)
         (owner (or (plist-get review :agent) "copilot")))
    (unless (equal owner name)
      (when (or (plist-get review :summaries) (plist-get review :notes)
                (plist-get review :session_used))
        (agent-notes--log
         "You" (format "Switched from %s to %s.  %s starts a new session: it does not \
remember the earlier requests, but every reply still includes its whole thread."
                       (agent-notes--agent-name (or (ignore-errors (agent-notes--agent owner))
                                                    (list (intern owner))))
                       (agent-notes--agent-name agent) (agent-notes--agent-name agent))))
      (setq review (plist-put review :agent name))
      (setq review (plist-put review :session (agent-notes--uuid)))
      (setq agent-notes--review (plist-put review :session_used nil))
      (agent-notes--save))))

(defun agent-notes--remember-session (agent output ok)
  "Remember that the review's session with AGENT can be resumed.
OUTPUT is what the agent printed; OK is non-nil if it succeeded."
  (when (equal (plist-get agent-notes--review :agent) (symbol-name (car agent)))
    (let ((regexp (plist-get (cdr agent) :session-regexp)))
      (cond ((and regexp (string-match regexp output))
             (setq agent-notes--review
                   (plist-put agent-notes--review :session (match-string 1 output)))
             (setq agent-notes--review (plist-put agent-notes--review :session_used t))
             (agent-notes--save))
            ((and ok (not regexp) (not (plist-get agent-notes--review :session_used)))
             (setq agent-notes--review (plist-put agent-notes--review :session_used t))
             (agent-notes--save))))))

(defun agent-notes--stop-ticker ()
  "Stop updating the elapsed time."
  (when (timerp agent-notes--ticker)
    (cancel-timer agent-notes--ticker))
  (setq agent-notes--ticker nil))

(defun agent-notes--run (label prompt on-success &optional in-flight what)
  "Run the agent of `agent-notes-agent' with PROMPT in the review session.
LABEL names the request in the header.  WHAT describes it for the
log.  On success, call ON-SUCCESS with the parsed JSON answer and
IN-FLIGHT, the ids of the comments sent; it returns a description
of what changed."
  (let* ((agent (agent-notes--agent))
         (name (agent-notes--agent-name agent))
         (program (agent-notes--agent-program agent)))
    (unless (and (stringp program) (executable-find program))
      (user-error "Cannot find %s (`%s'); see `agent-notes-agent' and `agent-notes-agents'"
                  name program))
    (agent-notes--use-agent agent)
    (let* ((file agent-notes--file)
           (review agent-notes--review)
           (default-directory (plist-get review :root))
           ;; To tell which files the agent changes; a clean tree gives nil.
           (before (condition-case nil (agent-notes--edit-fingerprints review)
                     (error :unknown)))
           (output-file (and (plist-get (cdr agent) :output-file)
                             (make-temp-file "agent-notes-answer")))
           (stdin (plist-get (cdr agent) :stdin))
           (args (funcall (plist-get (cdr agent) :args)
                          (list :prompt prompt :session (plist-get review :session)
                                :resume (plist-get review :session_used)
                                :output-file output-file))))
      (agent-notes--log
       "Sent" (concat (or what (format "Asked the agent: %s." label))
                      (format "\n%s reads the diff and the code it needs, then answers; " name)
                      "this often takes a minute or two.")
       (list "Prompt" prompt)
       (list "Command" (concat program " "
                               (mapconcat (lambda (arg)
                                            (if (eq arg prompt) "<prompt>" (shell-quote-argument arg)))
                                          args " ")
                               (if stdin " < <prompt>" ""))))
      (setq agent-notes--in-flight in-flight
            agent-notes--changes nil
            agent-notes--status (concat label "…")
            agent-notes--started (float-time)
            agent-notes--process
            (make-process
             :name "agent-notes"
             :buffer (generate-new-buffer " *agent-notes-output*")
             :command (cons program args)
             :connection-type 'pipe
             :coding 'utf-8
             :noquery t
             :sentinel (lambda (proc _event)
                         (agent-notes--sentinel proc file label on-success in-flight before
                                                agent output-file))))
      ;; Agents that take the prompt as an argument get an empty input.
      (when stdin
        (process-send-string agent-notes--process prompt))
      (process-send-eof agent-notes--process)
      (agent-notes--stop-ticker)
      (setq agent-notes--ticker (run-at-time 1 1 #'force-mode-line-update t))
      (agent-notes--render))))

(defun agent-notes--revert-file-buffers (paths)
  "Revert the unmodified buffers visiting PATHS; return the modified ones."
  (let ((root (plist-get agent-notes--review :root))
        (conflicts nil))
    (dolist (path paths)
      (let ((buf (find-buffer-visiting (expand-file-name path root))))
        (when buf
          (if (buffer-modified-p buf)
              (push path conflicts)
            (with-current-buffer buf
              (ignore-errors (revert-buffer t t t)))))))
    (nreverse conflicts)))

(defun agent-notes--detect-changes (before)
  "Find the files changed since BEFORE and refresh the diff if needed.
BEFORE is the result of `agent-notes--edit-fingerprints' when the
agent started, or :unknown.  Log what happened and return a short
message, or nil."
  (let* ((review agent-notes--review)
         (snapshot (agent-notes--snapshot-diff review))
         (diff (car snapshot))
         (after (agent-notes--edit-fingerprints review snapshot))
         (stale (not (equal diff (agent-notes--stored-diff))))
         (changed nil))
    (unless (eq before :unknown)
      (dolist (entry (append before after))
        (let ((path (car entry)))
          (unless (or (member path changed)
                      (equal (cdr (assoc path before)) (cdr (assoc path after))))
            (push path changed))))
      (setq agent-notes--changes (nreverse changed)))
    (let ((conflicts (agent-notes--revert-file-buffers agent-notes--changes)))
      (when conflicts
        (agent-notes--log "Changes" (format "The agent changed %s, which you have unsaved \
changes to.  Check those buffers before saving." (string-join conflicts ", ")))))
    (cond
     (stale
      (let ((what (if agent-notes--changes
                      (format "the agent changed %s" (string-join agent-notes--changes ", "))
                    "the code changed while the agent worked")))
        (if (not agent-notes-auto-refresh)
            (let ((msg (format "%s; press g to refresh the diff" what)))
              (agent-notes--log "Changes" (concat (agent-notes--capitalize-first msg) "."))
              msg)
          (let ((msg (format "%s; diff refreshed, %s" what
                             (agent-notes--describe-moves (agent-notes--resnapshot snapshot)))))
            (agent-notes--log "Changes" (concat (agent-notes--capitalize-first msg) "."))
            msg))))
     (agent-notes--changes
      (let ((msg (format "the agent changed %s in the working tree"
                         (string-join agent-notes--changes ", "))))
        (agent-notes--log "Changes" (format "%s.  This review shows %s, so these changes \
are not in its diff; see them in Magit."
                                            (agent-notes--capitalize-first msg)
                                            (agent-notes--scope-label review)))
        msg)))))

(defun agent-notes--last-lines (text n)
  "Return the last N non-empty lines of TEXT."
  (string-join (last (split-string text "\n" t "[ \t\r]+") n) "\n"))

(defun agent-notes--read-answer (output-file)
  "Return the contents of OUTPUT-FILE and delete it, or nil if it is empty."
  (when (and output-file (file-exists-p output-file))
    (prog1 (let ((text (agent-notes--read-file output-file)))
             (and (not (string-blank-p text)) text))
      (delete-file output-file))))

(declare-function notifications-notify "notifications" (&rest params))

(defvar agent-notes--bundle-id nil
  "The macOS bundle identifier of the running Emacs, once found.")

(defun agent-notes--macos-bundle-id ()
  "Return the macOS bundle identifier of the running Emacs."
  (or agent-notes--bundle-id
      (setq agent-notes--bundle-id
            (or (ignore-errors
                  (let ((plist (expand-file-name "../Info" invocation-directory)))
                    (and (file-exists-p (concat plist ".plist"))
                         (with-temp-buffer
                           (call-process "defaults" nil t nil "read" plist "CFBundleIdentifier")
                           (let ((id (string-trim (buffer-string))))
                             (and (string-match-p "\\`[[:alnum:].-]+\\'" id) id))))))
                "org.gnu.Emacs"))))

(defun agent-notes--run-notifier (program &rest args)
  "Run the notification PROGRAM with ARGS, without waiting for it."
  (apply #'call-process program nil 0 nil args))

(defun agent-notes-notify-default (title body)
  "Show a desktop notification with TITLE and BODY.
On macOS, use `terminal-notifier' when it is installed, because
clicking its notification brings Emacs to the front.  Without it,
use `osascript', whose notifications open Script Editor when clicked.
Elsewhere use D-Bus (`notifications-notify') where it is available."
  (cond
   ((and (eq system-type 'darwin) (executable-find "terminal-notifier"))
    (agent-notes--run-notifier "terminal-notifier"
                               "-title" title "-message" body
                               "-activate" (agent-notes--macos-bundle-id)
                               "-group" "agent-notes"))
   ((and (eq system-type 'darwin) (executable-find "osascript"))
    ;; The text goes in as arguments, so it needs no quoting.
    (agent-notes--run-notifier "osascript"
                               "-e" "on run {t, b}"
                               "-e" "display notification b with title t"
                               "-e" "end run"
                               title body))
   ((and (featurep 'dbusbind) (require 'notifications nil t))
    (notifications-notify :title title :body body :app-name "Emacs"))))

(defun agent-notes--emacs-focused-p ()
  "Return non-nil if one of the Emacs frames has the focus."
  (cl-some (lambda (frame) (eq (frame-focus-state frame) t)) (frame-list)))

(defun agent-notes--notify (title body)
  "Notify the user that TITLE happened, with the details BODY.
See `agent-notes-notify'.  A notification that cannot be sent is
never an error."
  (when (and agent-notes-notify
             (or (eq agent-notes-notify 'always)
                 (not (agent-notes--emacs-focused-p))))
    (condition-case err
        (funcall agent-notes-notify-function title
                 (truncate-string-to-width
                  (replace-regexp-in-string "[ \t\n]+" " " body) 200 nil nil "…"))
      (error (message "Agent Notes: could not send a notification: %s"
                      (error-message-string err))))))

(defun agent-notes--sentinel (proc file label on-success in-flight before
                                   &optional agent output-file)
  "Handle the end of the agent PROC for the review FILE.
LABEL, ON-SUCCESS and IN-FLIGHT are as in `agent-notes--run'.
BEFORE is as in `agent-notes--detect-changes'.  AGENT is the agent
that ran, and OUTPUT-FILE the file of its answer, if any."
  (when (memq (process-status proc) '(exit signal))
    (let* ((agent (or agent (agent-notes--agent)))
           (name (agent-notes--agent-name agent))
           (output (with-current-buffer (process-buffer proc) (buffer-string)))
           (answer (or (agent-notes--read-answer output-file) output))
           (code (process-exit-status proc))
           (aborted (eq (process-status proc) 'signal))
           (ok (and (not aborted) (zerop code)))
           (changes nil))
      (kill-buffer (process-buffer proc))
      (with-current-buffer (agent-notes--get-buffer file)
        (let ((elapsed (or (agent-notes--elapsed) "?")))
          (agent-notes--stop-ticker)
          (setq agent-notes--process nil
                agent-notes--status nil
                agent-notes--started nil
                agent-notes--in-flight nil)
          (agent-notes--remember-session agent output ok)
          (cond
           (aborted
            (agent-notes--log "Stopped" (format "The request (%s) was aborted after %s." label elapsed)
                              (list "Output so far" output)))
           (ok
            (apply #'agent-notes--log "Done" (format "%s answered after %s." name elapsed)
                   (list "Raw answer" answer)
                   (unless (eq answer output) (list (list "Output" output)))))
           (t
            (agent-notes--log "Failed" (format "%s exited with code %s after %s:\n%s"
                                               name code elapsed (agent-notes--last-lines output 6))
                              (list "Full output" output))))
          ;; Refresh first, so new notes are anchored to the code as it is now.
          (condition-case err
              (setq changes (agent-notes--detect-changes before))
            (error (agent-notes--log "Failed" (format "Could not check whether files changed: %s"
                                                      (error-message-string err)))))
          (if (not ok)
              (progn
                (message "Agent Notes: %s %s%s (press $ for the log)" label
                         (if aborted "aborted" "failed")
                         (if changes (concat "; " changes) ""))
                (unless aborted
                  (agent-notes--notify
                   (format "Agent Notes: %s failed" label)
                   (format "%s exited with code %s; see the log." name code))))
            (condition-case err
                (let ((result (funcall on-success (agent-notes--extract-json answer) in-flight)))
                  (agent-notes--save)
                  (agent-notes--log "Applied" (or result "Applied the answer."))
                  (message "Agent Notes: %s done%s" label (if changes (concat "; " changes) ""))
                  (agent-notes--notify
                   (format "Agent Notes: %s done" label)
                   (format "%s answered after %s. %s" name elapsed (or result ""))))
              (error
               (agent-notes--log "Failed" (format "Could not use the agent's answer: %s.  \
Your comments stay unsent; you can send them again."
                                                  (error-message-string err)))
               (message "Agent Notes: %s failed: %s (press $ for the log)"
                        label (error-message-string err))
               (agent-notes--notify
                (format "Agent Notes: %s failed" label)
                (format "Could not use the answer: %s" (error-message-string err))))))
          (agent-notes--render))))))

;;;; Suggested changes

(defun agent-notes--code-state ()
  "Return the state of the code in the current buffer, for sanity checks."
  (let ((ppss (save-excursion (syntax-ppss (point-max)))))
    (list :depth (nth 0 ppss)
          :open (and (or (nth 3 ppss) (nth 4 ppss)) t)
          :parse-error
          (ignore-errors
            (and (fboundp 'treesit-parser-list)
                 (treesit-parser-list)
                 (treesit-node-check (treesit-buffer-root-node) 'has-error))))))

(defun agent-notes--line-at (n)
  "Return line N of the current buffer, or nil if there is none."
  (save-excursion
    (goto-char (point-min))
    (when (and (> n 0) (zerop (forward-line (1- n))) (not (eobp)))
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun agent-notes--replacement-problems (before start old new)
  "Return what may be wrong after replacing the lines OLD with NEW.
The replacement starts at line START of the current buffer.  OLD and
NEW are lists of lines; BEFORE is `agent-notes--code-state' before."
  (let* ((after (agent-notes--code-state))
         (above (agent-notes--line-at (1- start)))
         (below (agent-notes--line-at (+ start (length new))))
         (problems nil))
    (cl-flet ((twice (line neighbor old-edge)
                (and (not (string-blank-p line))
                     (agent-notes--same-line-p line neighbor)
                     (not (agent-notes--same-line-p old-edge neighbor)))))
      (unless (equal (plist-get before :depth) (plist-get after :depth))
        (push "the brackets no longer balance" problems))
      (when (and (plist-get after :open) (not (plist-get before :open)))
        (push "a string or comment is left open" problems))
      (when (and (plist-get after :parse-error) (not (plist-get before :parse-error)))
        (push "the parser now finds a syntax error" problems))
      (when (twice (car new) above (car old))
        (push (format "line %d would appear twice: %s" (1- start) (string-trim above))
              problems))
      (when (twice (car (last new)) below (car (last old)))
        (push (format "line %d would appear twice: %s" (+ start (length new))
                      (string-trim below))
              problems)))
    (nreverse problems)))

(defun agent-notes-apply-suggestion ()
  "Apply the change suggested in the note at point and resolve the note.
The code the suggestion replaces is looked up in the file, near the
note.  If the result looks broken (unbalanced brackets, a syntax
error, a duplicated line), you are asked whether to keep it.  The
file is then saved; undo in its buffer if needed.  The diff is
refreshed."
  (interactive)
  (agent-notes--ensure-idle)
  (let* ((note (agent-notes--require-note))
         (id (plist-get note :id))
         (suggestion (or (plist-get note :suggestion)
                         (user-error "Note #%d has no suggested change" id)))
         (path (plist-get note :path))
         (line (plist-get note :line))
         (original (or (plist-get note :original)
                       (user-error "The suggestion of #%d does not say what it replaces; \
ask the agent for a new one" id)))
         (file (expand-file-name path (plist-get agent-notes--review :root)))
         (start nil))
    (when (plist-get note :applied)
      (user-error "The suggestion of #%d is already applied" id))
    (when (plist-get note :outdated)
      (user-error "The code of #%d has changed; ask the agent for a new suggestion" id))
    (unless (file-exists-p file)
      (user-error "%s does not exist in the working tree" path))
    (with-current-buffer (find-file-noselect file)
      (when (buffer-modified-p)
        (user-error "%s has unsaved changes; save it first" path))
      (save-excursion
        (save-restriction
          (widen)
          (let* ((old (agent-notes--split-lines original))
                 (new (agent-notes--split-lines suggestion))
                 (before (agent-notes--code-state))
                 beg end old-text problems)
            (setq start (or (agent-notes--locate-lines
                             (split-string (buffer-substring-no-properties (point-min) (point-max))
                                           "\n")
                             old line)
                            (user-error "%s no longer has the code the suggestion of #%d \
replaces; press g to refresh the diff" path id)))
            (goto-char (point-min))
            (forward-line (1- start))
            (setq beg (point))
            (forward-line (1- (length old)))
            (setq end (line-end-position)
                  old-text (buffer-substring beg end))
            (delete-region beg end)
            (goto-char beg)
            (insert suggestion)
            (setq problems (agent-notes--replacement-problems before start old new))
            (when (and problems
                       (not (y-or-n-p (format "The suggestion of #%d may break the code (%s).  \
Keep it? " id (string-join problems "; ")))))
              (delete-region beg (point))
              (goto-char beg)
              (insert old-text)
              (set-buffer-modified-p nil)
              (user-error "Left %s unchanged" path)))))
      (save-buffer))
    (plist-put note :applied t)
    (plist-put note :status "resolved")
    (agent-notes--save)
    (let ((moves (condition-case err
                     (format "diff refreshed, %s"
                             (agent-notes--describe-moves (agent-notes--resnapshot)))
                   (error (format "could not refresh the diff: %s" (error-message-string err))))))
      (agent-notes--log "You" (format "Applied the suggestion of #%d to %s:%d and resolved it; %s."
                                      id path start moves)))
    (agent-notes--render)
    (let ((section (agent-notes--note-section id)))
      (when section (magit-section-hide section)))
    (message "Applied the suggestion of #%d to %s (undo in that file's buffer)" id path)))

(provide 'agent-notes-agent)
;;; agent-notes-agent.el ends here
