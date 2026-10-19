;;; agent-notes-core.el --- Options, faces, state and storage for agent-notes -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el.  This file holds what every
;; other part needs: user options, faces, the buffer-local state of a
;; review buffer, reading and writing reviews, and helpers on the
;; review data that don't need the diff.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)

;;;; Customization

(defgroup agent-notes nil
  "Review git changes with an AI agent using inline notes."
  :group 'tools
  :prefix "agent-notes-")

(defcustom agent-notes-agent 'copilot
  "The agent CLI that does the work: a key of `agent-notes-agents'.
Each review remembers its session with an agent.  If you switch
agents during a review, the next request starts a new session: the
new agent does not remember earlier requests, but every reply still
includes its whole thread and the code around it."
  :type '(choice (const :tag "GitHub Copilot CLI" copilot)
                 (const :tag "Claude Code" claude)
                 (const :tag "OpenAI Codex CLI" codex)
                 (symbol :tag "Other agent in `agent-notes-agents'")))

(defcustom agent-notes-copilot-program "copilot"
  "Name or path of the GitHub Copilot CLI executable."
  :type 'string)

(defcustom agent-notes-copilot-extra-args nil
  "Extra arguments passed to every Copilot invocation.
For example \\='(\"--model\" \"gpt-5\")."
  :type '(repeat string))

(defcustom agent-notes-claude-program "claude"
  "Name or path of the Claude Code executable."
  :type 'string)

(defcustom agent-notes-claude-extra-args nil
  "Extra arguments passed to every Claude Code invocation.
For example \\='(\"--model\" \"opus\")."
  :type '(repeat string))

(defcustom agent-notes-codex-program "codex"
  "Name or path of the OpenAI Codex CLI executable."
  :type 'string)

(defcustom agent-notes-codex-extra-args nil
  "Extra arguments passed to every Codex invocation, after `codex exec'.
For example \\='(\"--model\" \"gpt-5-codex\")."
  :type '(repeat string))

(defcustom agent-notes-allow-edits t
  "When non-nil, the agent may edit files in the repository.
It is told to change code only when you ask for it in a comment.
After each request the diff is checked for changes; see
`agent-notes-auto-refresh'.  When nil, file writes are denied and
the agent describes changes instead of making them."
  :type 'boolean)

(defcustom agent-notes-allowed-tools
  '("shell(git diff)" "shell(git log)" "shell(git show)" "shell(git blame)"
    "shell(git status)" "shell(git grep)" "shell(git ls-files)"
    "shell(rg)" "shell(grep)" "shell(ls)" "shell(cat)" "shell(head)"
    "shell(tail)" "shell(wc)")
  "Commands the agent may run without asking, as Copilot patterns.
Copilot gets each entry as --allow-tool; Claude Code gets
shell(CMD) as Bash(CMD:*) and other entries as they are.  Codex
runs in a sandbox instead and ignores them.  File writes are
controlled separately by `agent-notes-allow-edits'."
  :type '(repeat string))

(defcustom agent-notes-denied-tools nil
  "Commands the agent is never allowed to use, as Copilot patterns.
They are translated like `agent-notes-allowed-tools'.  Writing
files is denied or allowed according to `agent-notes-allow-edits'."
  :type '(repeat string))

(defcustom agent-notes-auto-refresh t
  "When non-nil, refresh the diff after the agent changes files.
The notes are moved to the lines that now hold their code.  When
nil, only report the changes; refresh with \\[agent-notes-refresh]."
  :type 'boolean)

(defcustom agent-notes-refresh-on-save t
  "When non-nil, refresh open reviews when you save a file of their repository.
This lets you edit code during a review: visit the file with
\\<agent-notes-mode-map>\\[agent-notes-visit], change and save it, and the diff and the notes
follow.  Nothing is refreshed while the agent is working."
  :type 'boolean)

(defcustom agent-notes-base-branch nil
  "Default base branch for branch reviews.
When nil, use origin/HEAD, then main or master."
  :type '(choice (const :tag "Auto-detect" nil) string))

(defcustom agent-notes-branch-include-uncommitted t
  "When non-nil, branch reviews also include uncommitted changes."
  :type 'boolean)

(defcustom agent-notes-default-view 'unified
  "How the diff is shown in new review buffers."
  :type '(choice (const :tag "Unified" unified)
                 (const :tag "Side by side" split)))

(defcustom agent-notes-show-line-numbers t
  "Whether new review buffers show line numbers next to the diff.
Toggle them in a review with \\<agent-notes-mode-map>\\[agent-notes-toggle-line-numbers]."
  :type 'boolean)

(defcustom agent-notes-syntax-highlighting t
  "When non-nil, highlight the code in diffs with the file's major mode.
Added and removed lines are then marked by a background color
instead of a text color.  The major mode is set up without running
its hooks, so language servers and similar are not started."
  :type 'boolean)

(defcustom agent-notes-tasks
  '(("Review" . "You are a meticulous senior engineer reviewing these changes. \
Look for bugs, incorrect logic, unhandled edge cases, security problems, \
poor error handling, performance issues, unclear code and missing tests. \
Prefer a few high-signal notes over many trivial ones, and do not leave \
notes that only praise.  When you know the exact fix for a few lines, give \
it as a \"suggestion\".  In the summary, give your overall assessment in \
two or three sentences.")
    ("Overview" . "Help the user understand these changes quickly.  Focus \
only on the most important parts; skip boilerplate, formatting, renames and \
other mechanical edits.  In the summary, explain what changed and why, in \
the order the user should read it (a short paragraph or a few bullet \
points).  When the change involves several interacting parts, start the \
summary with a small diagram of them.  Then leave about 3 to 8 \
notes with severity \"info\" on the key lines, each explaining what that \
part does and how it fits into the whole.  Do not hunt for bugs, but \
mention anything that is clearly broken.")
    ("Diagram" . "Draw a diagram that explains the structure of these \
changes: the components, functions or data involved, how control or data \
flows between them, and which parts are new or changed.  Put it in the \
summary, and after it explain the diagram in two to four sentences.  \
Leave only a few \"info\" notes, on the lines where the main parts of \
the diagram are implemented."))
  "Tasks you can give the agent, as an alist of (NAME . INSTRUCTIONS).
When starting a review or pressing \\<agent-notes-mode-map>\\[agent-notes-request-review], you choose a task by
NAME, or type your own instructions instead.  The agent always
receives the context of the review (repository, scope, diff) and
the format for notes; INSTRUCTIONS say what to do with them."
  :type '(alist :key-type (string :tag "Name")
                :value-type (string :tag "Instructions")))

(define-obsolete-variable-alias 'agent-notes-review-instructions
  'agent-notes-extra-instructions "0.2.0")

(defcustom agent-notes-inline-diff-limit 40000
  "Largest diff, in characters, that is put in the prompt of a task.
The agent always gets the list of changed files and the path of the
diff; a diff up to this size is also included in full, so the
agent cannot skip parts of it.  Larger diffs, about 4 characters per
token, are left for the agent to read.  nil never includes the diff."
  :type '(choice (const :tag "Never" nil) integer))

(defcustom agent-notes-thread-context-lines 8
  "Lines of the diff shown around a thread's line when replying.
When you send comments, each thread is given to the agent with up
to this many lines of its hunk before and after its line."
  :type 'integer)

(defcustom agent-notes-extra-instructions nil
  "Extra instructions added to every task, or nil.
For example, the conventions of your project."
  :type '(choice (const :tag "None" nil) string))

(defcustom agent-notes-magit-status-section t
  "When non-nil, show the latest review in the Magit status buffer."
  :type 'boolean)

(defcustom agent-notes-diagram-format 'auto
  "How the agent draws diagrams.
`graphviz': in Graphviz DOT, shown as images (needs the `dot'
program and an Emacs that displays SVG); `text': with box-drawing
characters; `auto': `graphviz' if `dot' is installed, else `text'."
  :type '(choice (const :tag "Graphviz if installed" auto)
                 (const :tag "Graphviz" graphviz)
                 (const :tag "Plain text" text)))

(defcustom agent-notes-dot-program "dot"
  "The Graphviz program that renders diagrams."
  :type 'string)

(defcustom agent-notes-directory-name "agent-notes"
  "Name of the directory inside the git directory that stores reviews."
  :type 'string)

;;;; Faces

(defface agent-notes-note
  '((((class color) (background dark)) :background "#252a36" :extend t)
    (((class color) (background light)) :background "#f5f1e6" :extend t)
    (t :inherit highlight :extend t))
  "Background of note blocks.")

(defface agent-notes-border '((t :inherit shadow))
  "Face for the frame drawn around notes and between diff columns.")

(defface agent-notes-agent '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the agent's name.")

(defface agent-notes-you '((t :inherit font-lock-string-face :weight bold))
  "Face for your name.")

(defface agent-notes-pending '((t :inherit warning :slant italic :weight normal))
  "Face for unsent comments and work in progress.")

(defface agent-notes-resolved '((t :inherit shadow))
  "Face for resolved notes.")

(defface agent-notes-info '((t :inherit font-lock-function-name-face))
  "Face for the severity \"info\", used for explanations.")

(defface agent-notes-code '((t :inherit font-lock-constant-face))
  "Face for inline code in notes.")

(defface agent-notes-code-block '((t :inherit font-lock-constant-face))
  "Face for fenced code blocks and diagrams in notes and summaries.")

(defface agent-notes-title '((t :inherit bold :height 1.2))
  "Face for the review title.")

(defface agent-notes-file-header '((t :inherit diff-file-header :extend t))
  "Face for file headers.")

(defface agent-notes-hunk-header '((t :inherit diff-hunk-header :extend t))
  "Face for hunk headers.")

(defface agent-notes-line-number '((t :inherit line-number))
  "Face for line numbers in the diff gutter.")

(defface agent-notes-added '((t :inherit diff-added))
  "Face for added lines without syntax highlighting, and the + sign.")

(defface agent-notes-removed '((t :inherit diff-removed))
  "Face for removed lines without syntax highlighting, and the - sign.")

(defface agent-notes-context '((t :inherit diff-context))
  "Face for unchanged lines without syntax highlighting.")

(defface agent-notes-added-bg
  '((((class color) (background dark)) :background "#1d3b23" :extend t)
    (((class color) (background light)) :background "#e6ffed" :extend t)
    (t :inherit diff-added))
  "Background of added lines when the code is syntax highlighted.
Only set a background here, so the colors of the code stay visible.")

(defface agent-notes-removed-bg
  '((((class color) (background dark)) :background "#3f1d22" :extend t)
    (((class color) (background light)) :background "#ffeef0" :extend t)
    (t :inherit diff-removed))
  "Background of removed lines when the code is syntax highlighted.
Only set a background here, so the colors of the code stay visible.")

;;;; State of a review buffer

(defconst agent-notes--empty-tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  "Git's empty tree, used as the base when the repository has no commits.")

(defvar-local agent-notes--file nil "JSON file of the review in this buffer.")
(defvar-local agent-notes--review nil "The review plist.")
(defvar-local agent-notes--records nil "Parsed diff line records.")
(defvar-local agent-notes--index nil "Map from location key to diff record.")
(defvar-local agent-notes--placement nil "Map from note id to the record it is shown under.")
(defvar-local agent-notes--process nil "Running agent process, if any.")
(defvar-local agent-notes--status nil "What the agent is doing, or nil when idle.")
(defvar-local agent-notes--started nil "When the running request started, as a float time.")
(defvar-local agent-notes--in-flight nil "Ids of comments currently being sent.")
(defvar-local agent-notes--changes nil "Files the agent changed in its last request.")
(defvar-local agent-notes--view 'unified "Either `unified' or `split' (side by side).")
(defvar-local agent-notes--line-numbers t "Whether line numbers are shown.")
(defvar-local agent-notes--width nil "Window width the buffer was last rendered for.")
(defvar-local agent-notes--half 80 "Width of each column in the side-by-side view.")
(defvar-local agent-notes--gutter 5 "Width of the line-number gutter, or 0.")
(defvar-local agent-notes--pad (make-string 12 ?\s) "Indentation of notes.")
(defvar-local agent-notes--syntax-cache nil "Fontified code, by path and hash of the text.")

;;;; Files

(defun agent-notes--json-parse (string)
  "Parse the JSON STRING into plists and lists."
  (json-parse-string string :object-type 'plist :array-type 'list
                     :null-object nil :false-object nil))

(defun agent-notes--read-file (file)
  "Return the contents of FILE as a UTF-8 string."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file))
    (buffer-string)))

(defun agent-notes--write-file (file string)
  "Write STRING to FILE as UTF-8."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file (insert string))))

(defun agent-notes--diff-file (file)
  "Return the diff snapshot file belonging to the review FILE."
  (concat (file-name-sans-extension file) ".diff"))

(defun agent-notes--compact (plist)
  "Return a copy of PLIST without nil values, which JSON cannot represent."
  (let (out)
    (while plist
      (when (cadr plist)
        (setq out (cons (cadr plist) (cons (car plist) out))))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun agent-notes--serialize (review)
  "Return REVIEW as pretty-printed JSON."
  (let ((data (copy-sequence review)))
    (setq data (plist-put
                data :notes
                (vconcat (mapcar (lambda (note)
                                   (agent-notes--compact
                                    (plist-put (copy-sequence note) :comments
                                               (vconcat (mapcar #'agent-notes--compact
                                                                (plist-get note :comments))))))
                                 (plist-get review :notes)))))
    (setq data (plist-put data :summaries
                          (vconcat (mapcar #'agent-notes--compact
                                           (plist-get review :summaries)))))
    (with-temp-buffer
      (insert (json-serialize (agent-notes--compact data)))
      (json-pretty-print-buffer)
      (buffer-string))))

(defun agent-notes--migrate (review)
  "Update REVIEW, as read from disk, to the current format."
  (let ((summary (plist-get review :summary)))
    (when (and (stringp summary) (not (string-empty-p summary))
               (null (plist-get review :summaries)))
      (setq review (plist-put review :summaries
                              (list (list :task "Review" :text summary
                                          :time (or (plist-get review :created) ""))))))
    (if (plist-member review :summary)
        (plist-put review :summary nil)
      review)))

(defun agent-notes--save ()
  "Save the review of the current buffer."
  (agent-notes--write-file agent-notes--file (agent-notes--serialize agent-notes--review)))

;;;; Helpers on the review data

(defun agent-notes--now ()
  "Return the current time as an ISO 8601 string."
  (format-time-string "%FT%T%z"))

(defun agent-notes--uuid ()
  "Return a random UUID string."
  (let ((h (md5 (format "%S %s %s %s" (current-time) (emacs-pid) (random) (system-name)))))
    (format "%s-%s-4%s-%s%s-%s" (substring h 0 8) (substring h 8 12) (substring h 13 16)
            (nth (random 4) '("8" "9" "a" "b")) (substring h 17 20) (substring h 20 32))))

(defun agent-notes--as-int (value)
  "Coerce VALUE to an integer."
  (cond ((integerp value) value)
        ((numberp value) (truncate value))
        ((stringp value) (string-to-number value))
        (t 0)))

(defun agent-notes--plural (n word)
  "Return N followed by WORD, with an s unless N is 1."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun agent-notes--notes ()
  "Return the notes of the current review."
  (plist-get agent-notes--review :notes))

(defun agent-notes--note (id)
  "Return the note with ID."
  (cl-find id (agent-notes--notes) :key (lambda (n) (plist-get n :id))))

(defun agent-notes--next (key)
  "Return the next value of the counter KEY and increment it."
  (let ((id (or (plist-get agent-notes--review key) 1)))
    (setq agent-notes--review (plist-put agent-notes--review key (1+ id)))
    id))

(defun agent-notes--make-comment (author body state)
  "Return a new comment by AUTHOR with BODY in STATE."
  (list :id (agent-notes--next :next_comment) :author author :body body
        :state state :time (agent-notes--now)))

(defun agent-notes--general-p (note)
  "Return non-nil if NOTE is about the whole change, not a file."
  (string-empty-p (plist-get note :path)))

(defun agent-notes--resolved-p (note)
  "Return non-nil if NOTE is resolved."
  (equal (plist-get note :status) "resolved"))

(defun agent-notes--pending-p (comment)
  "Return non-nil if COMMENT has not been sent to the agent yet."
  (equal (plist-get comment :state) "pending"))

(defun agent-notes--editable-p (comment)
  "Return non-nil if COMMENT may still be edited or deleted."
  (and (equal (plist-get comment :author) "you")
       (agent-notes--pending-p comment)
       (not (memq (plist-get comment :id) agent-notes--in-flight))))

(defun agent-notes--pending-comments ()
  "Return the ids of all unsent comments that are not being sent."
  (cl-loop for note in (agent-notes--notes)
           append (cl-loop for c in (plist-get note :comments)
                           when (and (agent-notes--pending-p c)
                                     (not (memq (plist-get c :id) agent-notes--in-flight)))
                           collect (plist-get c :id))))

(defun agent-notes--count-unsent (notes)
  "Return the number of unsent comments in NOTES."
  (cl-loop for note in notes
           sum (cl-count-if #'agent-notes--pending-p (plist-get note :comments))))

(defun agent-notes--location (note)
  "Return a short description of where NOTE is."
  (if (agent-notes--general-p note)
      "general"
    (format "%s:%s" (plist-get note :path) (plist-get note :line))))

(defun agent-notes--first-line (note width)
  "Return the first line of NOTE's first comment, truncated to WIDTH."
  (truncate-string-to-width
   (car (split-string (plist-get (car (plist-get note :comments)) :body) "\n"))
   width nil nil "…"))

(defun agent-notes--short-rev (rev)
  "Return REV abbreviated if it is a full commit id."
  (if (and (stringp rev) (string-match-p "\\`[0-9a-f]\\{40,\\}\\'" rev))
      (substring rev 0 7)
    rev))

(defun agent-notes--scope-label (review)
  "Return a short description of REVIEW's scope."
  (pcase (plist-get review :scope)
    ("branch" (format "Branch vs %s" (plist-get review :base)))
    ("staged" "Staged vs HEAD")
    ("commit" (let ((subject (plist-get review :subject)))
                (concat "Commit " (agent-notes--short-rev (plist-get review :base))
                        (if (and subject (not (string-empty-p subject)))
                            (concat " " (truncate-string-to-width subject 40 nil nil "…"))
                          ""))))
    ("range" (format "Range %s" (plist-get review :base)))
    (_ "Working tree vs HEAD")))

(defun agent-notes--shows-working-tree-p (review)
  "Return non-nil if the new side of REVIEW's diff is the working tree."
  (pcase (plist-get review :scope)
    ("working" t)
    ("branch" agent-notes-branch-include-uncommitted)
    (_ nil)))

;;;; Agents

(defvar agent-notes-agents
  '((copilot :name "Copilot" :program agent-notes-copilot-program
             :args agent-notes--copilot-args)
    (claude :name "Claude Code" :program agent-notes-claude-program
            :args agent-notes--claude-args :stdin t)
    (codex :name "Codex" :program agent-notes-codex-program
           :args agent-notes--codex-args :output-file t
           :session-regexp "^session id: \\([-0-9a-zA-Z]+\\)"))
  "The agent CLIs that agent-notes can run, as (SYMBOL . PROPERTIES).
Choose one with `agent-notes-agent'.  PROPERTIES is a plist:

:name            the name shown in the review and the log.
:program         the executable: a string, or a variable holding it.
:args            a function called in the review buffer with a request
                 and returning the arguments of the program.  The
                 request is a plist with :prompt, :session (the session
                 id), :resume (non-nil once the session has been used)
                 and :output-file.
:stdin           if non-nil, the prompt is sent on standard input, not
                 in the arguments.
:output-file     if non-nil, :output-file is a temporary file where the
                 program writes its final answer; otherwise the answer
                 is read from what the program prints.
:session-regexp  if non-nil, the program chooses the session id itself
                 and prints it, and group 1 of this regexp finds it.
                 Otherwise agent-notes makes up a UUID for the session.")

(defun agent-notes--agent (&optional name)
  "Return (SYMBOL . PROPERTIES) of the agent NAME, a symbol or string.
NAME defaults to `agent-notes-agent'."
  (let ((name (or name agent-notes-agent)))
    (or (assq (if (stringp name) (intern name) name) agent-notes-agents)
        (user-error "Unknown agent %s; see `agent-notes-agents'" name))))

(defun agent-notes--agent-name (&optional agent)
  "Return the display name of AGENT, or of `agent-notes-agent'.
Never signal an error, so it can be used in mode lines."
  (let ((agent (or agent (ignore-errors (agent-notes--agent)))))
    (if agent
        (or (plist-get (cdr agent) :name) (symbol-name (car agent)))
      (format "%s" agent-notes-agent))))

(defun agent-notes--agent-program (agent)
  "Return the executable of AGENT."
  (let ((program (plist-get (cdr agent) :program)))
    (if (and program (symbolp program)) (symbol-value program) program)))

(defun agent-notes--repo-name (review)
  "Return the name of REVIEW's repository."
  (file-name-nondirectory (directory-file-name (plist-get review :root))))

(defun agent-notes--ensure-idle ()
  "Signal an error if the agent is working."
  (when (process-live-p agent-notes--process)
    (user-error "The agent is still working (x to abort)")))

(defun agent-notes--elapsed ()
  "Return how long the running request has taken, as M:SS, or nil."
  (when agent-notes--started
    (let ((secs (truncate (- (float-time) agent-notes--started))))
      (format "%d:%02d" (/ secs 60) (% secs 60)))))

(provide 'agent-notes-core)
;;; agent-notes-core.el ends here
