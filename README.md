# agent-notes

Go through the changes in a git repository with an AI agent (GitHub Copilot CLI), inside Emacs.

The diff is shown in a Magit-style buffer, unified or side by side, with the syntax highlighting of each file's major mode. You give the agent a task, such as a bug review, an overview of the important changes, a diagram, or your own instructions. Its notes appear under the lines they refer to. You can reply, add your own notes, and resolve threads. Your comments are queued, and nothing goes to the agent until you send them all with `s`. If you ask for a change, the agent edits the code; when it suggests a change in a note, `a` applies it. You can also edit files yourself. Either way, the diff refreshes and the notes move with the code.

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

- **Review**: find bugs, risks and missing tests. Where the fix is clear, a note carries a suggested change.
- **Overview**: explain only the most important changes. The summary covers what changed and why, in reading order, with a small diagram when several parts interact. It adds about 3–8 `info` notes on the key lines.
- **Diagram**: a box-and-arrow drawing of the changed parts and how they connect, with a short explanation.

You can also pick "Custom instructions…" or type your own text, for example "explain how the caching works". In Vertico, use `M-RET` to submit text that partially matches a task name. Add your own tasks to `agent-notes-tasks`. Press `A` in a review to give the agent another task; new notes are added to the existing ones, and each task's summary is kept.

### Keys in the review buffer

Press `?` (or `h`) for a menu with all of these.

| Key             | Action                                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------------------- |
| `n` / `p`       | Next / previous open note. Resolved notes are skipped; with `C-u`, they are included.                               |
| `N` / `P`       | Next / previous open note written by the agent                                                                      |
| `M-n` / `M-p`   | Next / previous hunk, across files                                                                                  |
| `}` / `{`       | Next / previous file                                                                                                |
| `l`             | Jump to any note, resolved ones included, from a list                                                               |
| `TAB`           | Fold the file, hunk or note at point. Resolved notes start folded.                                                  |
| `^`, `1`–`4`    | Parent section, show levels (as in Magit)                                                                           |
| `v`             | Switch between unified and side-by-side views. Side by side, notes sit in the column of the side they are on.       |
| `#`             | Show / hide line numbers                                                                                            |
| `c`             | New note on the line at point. In the side-by-side view, the side at point counts. Elsewhere, write a general note. |
| `r`             | Resolve / reopen the note at point                                                                                  |
| `e` / `k`       | Edit / delete your unsent comment (or your whole unsent note)                                                       |
| `R`             | Reply to the note at point                                                                                          |
| `a`             | Apply the change suggested in the note at point                                                                     |
| `s`             | Send all unsent comments to the agent                                                                               |
| `A`             | Give the agent a task                                                                                               |
| `g`             | Refresh the diff (same scope and base) and move notes with their code                                               |
| `RET` / `o`     | Open the file at that line, to read or edit it (on a diagram: open its Graphviz source)                             |
| `$`             | Show the log: what was sent, how long it took, what came back and what changed                                      |
| `x` / `C-c C-k` | Abort the running agent request                                                                                     |

In the compose buffer, `C-c C-c` saves and `C-c C-k` cancels.

### Editing code during a review

Press `RET` on a line or note to open the file at that line, in another window. Edit it and save. The review refreshes about half a second later, and the notes move with their code. You can turn this off with `agent-notes-refresh-on-save`, and refresh by hand with `g`.

While the agent is working, saving doesn't refresh. Its changes are picked up when it finishes. Buffers of files that the agent changed are reverted if you have no unsaved edits in them; otherwise the log warns you.

### Suggested changes

When the agent knows the exact fix for a few lines, its note shows a "Suggested change" with the old lines (`-`) and the new ones (`+`). Press `a` on the note to apply it. The file is changed and saved, the note is resolved, and the diff refreshes. Undo works as usual in the file's buffer. You can also ask for a suggestion in a reply ("suggest a fix") rather than asking the agent to edit.

Applying works like search and replace, not by line numbers. The agent gives the exact lines it replaces (`original`) along with the new code, and `a` looks for those lines in the file, near the note. The `-` lines are exactly what gets replaced. If the agent repeats a neighbouring line for context, such as the function's signature, that line is part of what's replaced and does not end up in the file twice. Suggestions whose `original` is not in the file are dropped, and the log says so. If the code changed after the suggestion was made, `a` refuses instead of guessing.

Before saving, `a` checks the result. It looks for brackets or strings that no longer balance, a new syntax error (in tree-sitter modes), or a line that now appears twice. If it finds one, it asks whether to keep the change; answering `n` leaves the file as it was.

### Diagrams

The Overview and Diagram tasks can draw a diagram at the top of the summary. You can also type your own instructions, such as "draw how a request flows through the new middleware".

If [Graphviz](https://graphviz.org) is installed (`brew install graphviz`), the agent writes diagrams in DOT and they are shown as images in the colours of your theme. New parts are drawn **bold** and changed parts dashed. Press `RET` on a diagram to open its source, in `graphviz-dot-mode` if you have it; there, `C-c C-p` shows a zoomable preview. Without Graphviz, or in a terminal, the agent draws plain-text box-and-arrow diagrams instead. Code blocks are cut at the window edge instead of wrapping, so these drawings stay intact. `agent-notes-diagram-format` chooses between the two.

### When you are done

When every note is resolved and nothing is unsent, the review says so, and the Magit status line shows "all resolved ✓". Commit as usual with Magit. The review stays in `.git/agent-notes/` as history and can be reopened with `o` in the menu. For the next round of changes, start a new review.

### The log

`$` opens a log for the review, one line per step:

```
10:02:11  Started   New review, Working tree vs HEAD: 1 file, +9 −1.
10:02:11  Sent      Asked the agent to do the task "Overview" on the diff.
10:03:02  Done      Copilot answered after 0:51.
10:03:02  Applied   Added 5 notes (1 with a suggested change) and a summary.
10:05:40  Sent      Sent your 2 comments in 2 threads (#1, #3) to the agent.
10:06:30  Changes   The agent changed stats.py; diff refreshed, 1 note moved, 0 outdated.
10:06:30  Applied   Answered 2 threads, resolved 1.
```

`TAB` on an entry shows its details, such as the exact prompt, the command line, and the agent's raw answer. While the agent works, the header line shows how long it has been running. The log is kept for the current Emacs session.

## How it works

- **Storage.** Every review is stored in `.git/agent-notes/<id>.json`, with a snapshot of the diff in `<id>.diff`. Nothing is committed. Git never pushes anything inside `.git/`, so reviews stay on your machine: other clones don't see them, and each clone or worktree has its own.
- **Sessions.** Each review has its own Copilot session (`copilot --session-id <uuid>`), so the agent remembers the review when you reply.
- **Context.** Every prompt gives the repository, the scope (base commit), the path of the diff snapshot, and the list of changed files with their `+`/`-` counts.
  - **Tasks** also include the whole diff, if it is under `agent-notes-inline-diff-limit` characters (40000, about 10k tokens). That way no part of it gets skimmed. Larger diffs are left for the agent to read in parts, and it is told not to skip any file.
  - **Replies** include each thread with new messages, together with the code around it from the hunk: up to `agent-notes-thread-context-lines` lines on each side, with old and new line numbers.
  - **Files.** In both cases the agent can open whole files for more context.

  The log (`$`) shows every prompt in full.

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
- `agent-notes-inline-diff-limit`: the largest diff (in characters) put in a task's prompt; `nil` never includes it
- `agent-notes-thread-context-lines`: lines of code shown around each thread when replying
- `agent-notes-allow-edits`: whether the agent may edit files
- `agent-notes-default-view`: `unified` or `split`
- `agent-notes-show-line-numbers`: whether new reviews show line numbers
- `agent-notes-syntax-highlighting`: highlight code with the file's major mode (mode hooks are not run, so no language server starts). The faces `agent-notes-added-bg` and `agent-notes-removed-bg` set the backgrounds.
- `agent-notes-refresh-on-save`: refresh reviews when you save a file of the repository
- `agent-notes-copilot-extra-args`: for example `'("--model" "gpt-5")`
- `agent-notes-base-branch`: the default base branch for branch reviews
- `agent-notes-diagram-format`: `auto` (Graphviz if `dot` is installed), `graphviz` or `text`; `agent-notes-dot-program` is the Graphviz program

## Development

The code is split by concern. Each file requires the ones above it:

| File                    | Contents                                                                               |
| ----------------------- | -------------------------------------------------------------------------------------- |
| `agent-notes-core.el`   | Options, faces, the buffer-local state of a review, reading and writing reviews        |
| `agent-notes-diff.el`   | Git, diff parsing, anchoring and moving notes, syntax highlighting of hunks            |
| `agent-notes-render.el` | Drawing the review buffer: header, files, hunks, notes, both views                     |
| `agent-notes-log.el`    | The per-review log and its buffer                                                      |
| `agent-notes-agent.el`  | Prompts, running Copilot, applying its answers, detecting its edits, suggested changes |
| `agent-notes-magit.el`  | `@` in Magit and `magit-dispatch`, and the status section; loaded once Magit is loaded |
| `agent-notes.el`        | The mode, keymap, commands, menus and entry points                                     |

Tests:

```sh
emacs -Q --batch \
  --eval '(progn (setq package-user-dir "~/.config/emacs/elpa") (package-initialize))' \
  -L . -l agent-notes-tests.el -f ert-run-tests-batch-and-exit
```

Use the same Emacs that compiled your packages. On this machine that is `/Applications/Emacs.app/Contents/MacOS/Emacs` (31.1); the `emacs` on `PATH` is 30.2 and prints harmless transient warnings.

- `agent-notes-tests.el` also runs the whole request cycle against a fake `copilot` script, in a scratch git repository. It needs no Copilot requests.
- `integ.el` checks the Magit integration and simulated agent edits, without any Copilot requests.
- `e2e.el` runs a real Overview task and a code-change request against Copilot. It uses 2 requests.

See the comments at the top of each file.
