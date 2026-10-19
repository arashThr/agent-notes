# agent-notes

Go through the changes in a git repository with an AI agent (GitHub Copilot CLI), inside Emacs.

The diff is shown in a read-only, Magit-style buffer, unified or side by side. You give the agent a task, such as a bug review, an overview of the important changes, or your own instructions. Its notes appear under the lines they refer to. You can reply, add your own notes, and resolve threads. Your comments are queued, and nothing goes to the agent until you send them all with `s`. If you ask for a change, the agent edits the code. The diff then refreshes, and the notes move with the code.

```
stats.py
@@ -3,3 +3,8 @@ def average(xs):
    5     5      return total / len(xs)
          8 +def median(xs):
          9 +    s = sorted(xs)
         10 +    return s[len(s) // 2]
            ┌ #1  agent  issue  open  1 unsent
            │ `s[len(s) // 2]` is wrong for even-length lists. `median([1,2,3,4])` returns 3 instead of 2.5.
            │
            │ ↳ you  unsent
            │   Please fix it.
            └
```

## Requirements

- Emacs 29.1 or newer
- `magit-section` and `transient`, which come with Magit. Magit itself is optional; it adds the integration described below.
- The [GitHub Copilot CLI](https://github.com/github/copilot-cli) (`copilot`), installed and signed in

## Setup

```elisp
(use-package agent-notes
  :ensure nil
  :load-path "/path/to/agent-notes"
  :init (with-eval-after-load 'magit (require 'agent-notes))
  :bind (("C-c g a" . agent-notes-menu)
         ("C-c g r" . agent-notes-review)
         ("C-c g o" . agent-notes-open)))
```

The `:init` line loads the package together with Magit, so `@` works in Magit right away.

## Usage

- `M-x agent-notes-menu` (or `@` in any Magit buffer, or `@` in `magit-dispatch`) offers these commands:
  - `w` review the working tree
  - `b` review the branch
  - `l` open the latest review
  - `o` open any previous review
- `M-x agent-notes-review` asks for the scope, then the task.
  - **Working tree**: uncommitted changes (staged, unstaged and untracked) compared to `HEAD`.
  - **Branch**: everything since the current branch forked from a base branch (default `origin/HEAD`, then `main`/`master`). Uncommitted work is included unless `agent-notes-branch-include-uncommitted` is nil.
- The Magit status buffer shows the latest review ("Agent review: … · 2 open, 1 unsent"). `RET` on that line opens it. Turn it off with `agent-notes-magit-status-section`.

### Tasks

The task tells the agent what to do with the diff. The built-in tasks are:

- **Review**: find bugs, risks and missing tests.
- **Overview**: explain only the most important changes. The summary covers what changed and why, in reading order, and there are about 3–8 `info` notes on the key lines.

You can also pick "Custom instructions…" or type your own text, for example "explain how the caching works". In Vertico, use `M-RET` to submit text that partially matches a task name. Add your own tasks to `agent-notes-tasks`. Press `A` in a review to give the agent another task; new notes are added to the existing ones, and each task's summary is kept.

### Keys in the review buffer

Press `?` (or `h`) for a menu with all of these.

| Key             | Action                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| `n` / `p`       | Next / previous note                                                                                                |
| `N` / `P`       | Next / previous note written by the agent                                                                           |
| `M-n` / `M-p`   | Next / previous hunk, across files                                                                                  |
| `}` / `{`       | Next / previous file                                                                                                |
| `l`             | Jump to a note from a list                                                                                          |
| `TAB`           | Fold the file, hunk or note at point. Resolved notes start folded.                                                  |
| `^`, `1`–`4`    | Parent section, show levels (as in Magit)                                                                           |
| `v`             | Switch between unified and side-by-side views                                                                       |
| `c`             | New note on the line at point. In the side-by-side view, the side at point counts. Elsewhere, write a general note. |
| `r`             | Reply to the note at point                                                                                          |
| `e` / `k`       | Edit / delete your unsent comment (or your whole unsent note)                                                       |
| `R`             | Resolve / reopen the note at point                                                                                  |
| `s`             | Send all unsent comments to the agent                                                                               |
| `A`             | Give the agent a task                                                                                               |
| `g`             | Refresh the diff (same scope and base) and move notes with their code                                               |
| `RET` / `o`     | Open the file at that line                                                                                          |
| `$`             | Show the log of prompts and raw agent answers                                                                       |
| `x` / `C-c C-k` | Abort the running agent request                                                                                     |

In the compose buffer, `C-c C-c` saves and `C-c C-k` cancels.

## How it works

- **Storage.** Every review is stored in `.git/agent-notes/<id>.json`, with a snapshot of the diff in `<id>.diff`. Nothing is committed.
- **Sessions.** Each review has its own Copilot session (`copilot --session-id <uuid>`), so the agent remembers the review when you reply.
- **Permissions.** Copilot runs non-interactively (`copilot -p`) and may:
  - read files and run the read-only commands in `agent-notes-allowed-tools`;
  - edit files (`--allow-tool=write`) when `agent-notes-allow-edits` is non-nil, which is the default. It is told to change code only when you ask.

  The agent answers with a JSON block, and only Emacs writes the review files.

- **Change detection.** After each request, Emacs compares the changes with the state before the request. The header shows which files the agent changed. If the diff changed, it is refreshed automatically; set `agent-notes-auto-refresh` to nil to refresh yourself with `g`.
- **Note anchoring.** Each note stores its file, side, line and the code on that line. When the diff is refreshed, a note moves to the nearest line with the same code. If that code is gone, the note is marked "outdated".

## Customization

`M-x customize-group RET agent-notes`. Useful options:

- `agent-notes-tasks`: the tasks offered when giving the agent work
- `agent-notes-extra-instructions`: guidance added to every task, such as the project's conventions
- `agent-notes-allow-edits`: whether the agent may edit files
- `agent-notes-default-view`: `unified` or `split`
- `agent-notes-copilot-extra-args`: for example `'("--model" "gpt-5")`
- `agent-notes-base-branch`: the default base branch for branch reviews

## Development

```sh
emacs -Q --batch \
  --eval '(progn (setq package-user-dir "~/.config/emacs/elpa") (package-initialize))' \
  -L . -l agent-notes-tests.el -f ert-run-tests-batch-and-exit
```

Use the same Emacs that compiled your packages. On this machine that is `/Applications/Emacs.app/Contents/MacOS/Emacs` (31.1); the `emacs` on `PATH` is 30.2 and prints harmless transient warnings.

- `integ.el` checks the Magit integration and simulated agent edits, without any Copilot requests.
- `e2e.el` runs a real Overview task and a code-change request against Copilot. It uses 2 requests.

See the comments at the top of each file.
