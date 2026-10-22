;;; agent-notes-github.el --- Post notes to a GitHub pull request -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Part of agent-notes; see agent-notes.el.  This file talks to the
;; GitHub CLI (`gh') to post a note as a comment on a pull request.
;; It only runs when you ask for it; the agent never posts anything.
;; The command itself, `agent-notes-post-to-github', is in
;; agent-notes.el because it uses the compose buffer.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'agent-notes-core)
(require 'agent-notes-diff)

;;;; Running gh

(defun agent-notes--gh (args)
  "Run the GitHub CLI with ARGS, a list of strings, in the repository.
Return a plist with :code (the exit code), :out and :err.  ARGS are
passed as they are, without a shell."
  (unless (executable-find agent-notes-gh-program)
    (user-error "GitHub CLI not found: install it (https://cli.github.com) \
or set `agent-notes-gh-program'"))
  (let ((default-directory (or (plist-get agent-notes--review :root) default-directory))
        (process-environment (append '("GH_PROMPT_DISABLED=1" "NO_COLOR=1" "GH_PAGER=cat")
                                     process-environment))
        (errfile (make-temp-file "agent-notes-gh")))
    (unwind-protect
        (with-temp-buffer
          (let* ((coding-system-for-read 'utf-8)
                 (coding-system-for-write 'utf-8)
                 (code (apply #'process-file agent-notes-gh-program nil
                              (list t errfile) nil args)))
            (list :code code :out (buffer-string) :err (agent-notes--read-file errfile))))
      (delete-file errfile))))

(defun agent-notes--gh-auth-problem-p (result)
  "Return non-nil if the failed RESULT of `agent-notes--gh' is about logging in."
  (string-match-p "auth login\\|not logged in\\|GH_TOKEN\\|authentication"
                  (concat (plist-get result :err) (plist-get result :out))))

(defun agent-notes--gh-error (result)
  "Return a one-line description of the failed RESULT of `agent-notes--gh'."
  (let* ((text (string-trim (if (string-blank-p (plist-get result :err))
                                (plist-get result :out)
                              (plist-get result :err))))
         (line (car (split-string text "\n")))
         (line (if (string-empty-p line)
                   (format "exit code %s" (plist-get result :code))
                 line)))
    (if (agent-notes--gh-auth-problem-p result)
        (format "%s (run `gh auth login' in a terminal)" line)
      line)))

(defun agent-notes--gh! (args)
  "Run the GitHub CLI with ARGS and return its output, or signal a `user-error'."
  (let ((result (agent-notes--gh args)))
    (unless (eql (plist-get result :code) 0)
      (user-error "gh %s failed: %s" (string-join (seq-take args 2) " ")
                  (agent-notes--gh-error result)))
    (plist-get result :out)))

;;;; The pull request

(defun agent-notes--gh-pr (ref)
  "Return the pull request REF as a plist, or nil if there is none.
REF is a number or a URL; nil means the pull request of the current
branch.  The plist has :number, :url, :title and :headRefOid."
  (let ((result (agent-notes--gh `("pr" "view" ,@(and ref (list ref))
                                   "--json" "number,url,title,headRefOid"))))
    (cond ((eql (plist-get result :code) 0)
           (json-parse-string (plist-get result :out) :object-type 'plist))
          ((agent-notes--gh-auth-problem-p result)
           (user-error "gh pr view failed: %s" (agent-notes--gh-error result))))))

(defun agent-notes--gh-read-ref (stored prompt)
  "Read the number or URL of a pull request, starting from STORED.
PROMPT is shown before the question."
  (let ((ref (string-trim (read-string (concat prompt "Pull request (number or URL): ")
                                       stored))))
    (when (string-empty-p ref) (user-error "No pull request given"))
    ref))

(defun agent-notes--gh-resolve-pr (choose)
  "Return the pull request to post to, as in `agent-notes--gh-pr'.
That is the one you chose last time for this review, else the one of
the current branch; if there is none, ask for it.  With CHOOSE, ask
first.  A pull request you typed is remembered in the review."
  (let* ((stored (plist-get agent-notes--review :pr))
         (ref (if choose (agent-notes--gh-read-ref stored "") stored))
         (pr (agent-notes--gh-pr ref)))
    (when (and (not pr) (not ref))
      (setq ref (agent-notes--gh-read-ref nil "No pull request for the current branch.  ")
            pr (agent-notes--gh-pr ref)))
    (unless pr (user-error "Could not find the pull request %s" ref))
    (when (and ref (not (equal (plist-get pr :url) stored)))
      (setq agent-notes--review (plist-put agent-notes--review :pr (plist-get pr :url)))
      (agent-notes--save))
    pr))

(defun agent-notes--gh-repo (pr)
  "Return (HOST . OWNER/REPO) for the pull request PR."
  (let ((url (plist-get pr :url)))
    (unless (string-match "\\`https?://\\([^/]+\\)/\\([^/]+/[^/]+\\)/pull/" url)
      (user-error "Cannot tell the repository from %s" url))
    (cons (match-string 1 url) (match-string 2 url))))

;;;; Inline or general

(defun agent-notes--gh-plan (note pr)
  "Decide how to post NOTE to the pull request PR.
Return (:line N) when it can be a comment on line N of the file in
the pull request's head commit, which is the case when that commit
has NOTE's code on the same line.  Otherwise return (:reason WHY) with
the reason it will be a general comment, or nil for a general note."
  (let ((path (plist-get note :path))
        (line (plist-get note :line))
        (text (plist-get note :text))
        (oid (plist-get pr :headRefOid)))
    (cond
     ((agent-notes--general-p note) nil)
     ((not (equal (plist-get note :side) "new"))
      (list :reason "the code was removed in this change"))
     ((not (and text oid (> line 0)))
      (list :reason "the note is not on a line of the diff"))
     (t
      (let* ((default-directory (or (plist-get agent-notes--review :root) default-directory))
             (content (agent-notes--git-call '(0) (list "show" (format "%s:%s" oid path)))))
        (cond ((not content)
               (list :reason "the pull request's head commit does not have this file; \
try git fetch"))
              ((not (equal (string-trim-right
                            (or (nth (1- line) (agent-notes--split-lines content)) ""))
                           (string-trim-right text)))
               (list :reason "the code differs from the pull request's head commit"))
              (t (list :line line))))))))

(defun agent-notes--gh-describe-plan (note pr plan)
  "Describe where the post of NOTE to PR will go, according to PLAN."
  (format "PR #%d, %s" (plist-get pr :number)
          (cond ((plist-get plan :line)
                 (format "inline on %s:%d" (plist-get note :path) (plist-get plan :line)))
                ((plist-get plan :reason)
                 (format "general comment, because %s" (plist-get plan :reason)))
                (t "general comment"))))

;;;; Posting

(defun agent-notes--gh-inline-args (note pr text)
  "Return the arguments of `gh' that post TEXT inline on NOTE's line of PR."
  (pcase-let ((`(,host . ,repo) (agent-notes--gh-repo pr)))
    `("api" "--method" "POST"
      ,@(unless (equal host "github.com") (list "--hostname" host))
      ,(format "repos/%s/pulls/%d/comments" repo (plist-get pr :number))
      "-f" ,(concat "body=" text)
      "-f" ,(concat "commit_id=" (plist-get pr :headRefOid))
      "-f" ,(concat "path=" (plist-get note :path))
      "-F" ,(format "line=%d" (plist-get note :line))
      "-f" "side=RIGHT"
      "--jq" ".html_url")))

(defun agent-notes--gh-general-body (note text)
  "Return TEXT for a general comment, saying which code NOTE is about."
  (if (agent-notes--general-p note)
      text
    (format "`%s:%d`%s\n\n```\n%s\n```\n\n%s"
            (plist-get note :path) (plist-get note :line)
            (if (equal (plist-get note :side) "old") " (before the change)" "")
            (or (plist-get note :text) "")
            text)))

(defun agent-notes--gh-post (note pr plan text)
  "Post TEXT about NOTE to the pull request PR as PLAN says.
Return (URL . INLINE), where INLINE is non-nil for a comment on a line.
When GitHub refuses the comment on the line, offer to post it as a
general comment instead."
  (let ((url nil))
    (when (plist-get plan :line)
      (let ((result (agent-notes--gh (agent-notes--gh-inline-args note pr text))))
        (if (eql (plist-get result :code) 0)
            (setq url (string-trim (plist-get result :out)))
          (unless (y-or-n-p (format "GitHub refused the comment on the line (%s).  \
Post it as a general comment? " (agent-notes--gh-error result)))
            (user-error "Not posted")))))
    (if url
        (cons url t)
      (let ((out (string-trim
                  (agent-notes--gh! (list "pr" "comment" (plist-get pr :url)
                                          "--body" (agent-notes--gh-general-body note text))))))
        (cons (if (string-empty-p out) (plist-get pr :url) out) nil)))))

(provide 'agent-notes-github)

;;; agent-notes-github.el ends here
