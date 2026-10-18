# agent-notes

Review the changes in a git repository with an AI agent (GitHub Copilot CLI), inside Emacs.

The diff is shown in a read-only buffer. The agent's notes appear under the lines they refer to. You can reply, add your own notes, and resolve threads. Your comments are queued, and nothing goes to the agent until you send them all with `s`.

```
 stats.py
@@ -3,3 +3,8 @@ def average(xs):
    5     5      return total / len(xs)
          8 +def median(xs):
          9 +    s = sorted(xs)
         10 +    return s[len(s) // 2]
            ┌ #1  agent  issue  open
            │ `s[len(s) // 2]` is wrong for even-length lists. `median([1,2,3,4])` returns 3 instead of 2.5.
            │
            │ ↳ you  unsent
            │   Is this really a problem? Callers never pass an empty list.
            └
```

## Requirements

- Emacs 29.1 or newer
- The [GitHub Copilot CLI](https://github.com/github/copilot-cli) (`copilot`), installed and signed in

## Setup

```elisp
(add-to-list 'load-path "/path/to/agent-notes")
(require 'agent-notes)
(global-set-key (kbd "C-c r r") #'agent-notes-review)
(global-set-key (kbd "C-c r o") #'agent-notes-open)
```

## Usage

- `M-x agent-notes-review` asks what to review:
  - **Working tree**: uncommitted changes (staged, unstaged and untracked) compared to `HEAD`.
  - **Branch**: everything since the current branch forked from a base branch (default `origin/HEAD`, then `main`/`master`). Uncommitted work is included unless `agent-notes-branch-include-uncommitted` is nil.

  Emacs saves a snapshot of the diff, opens the review buffer and asks the agent for a review in the background. The notes show up when it is done, usually after a few seconds to a minute.
- `M-x agent-notes-open` reopens a previous review.

### Keys in the review buffer

| Key | Action |
|---|---|
| `n` / `p` | Next / previous note |
| `N` / `P` | Next / previous note written by the agent |
| `}` / `{` | Next / previous file |
| `l` | Jump to a note from a list |
| `TAB` | Fold / unfold a note (resolved notes are folded) |
| `c` | New note on the line at point |
| `r` | Reply to the note at point |
| `e` | Edit your unsent comment at point |
| `k` | Delete your unsent comment (or your whole unsent note) |
| `R` | Resolve / reopen the note at point |
| `s` | Send all unsent comments to the agent |
| `A` | Ask the agent to review again (adds notes) |
| `RET` | Open the file at that line, read-only |
| `$` | Show the log of prompts and raw agent answers |
| `C-c C-k` | Abort the running agent request |
| `g` | Reload from disk |
| `?` | Help |

In the compose buffer, `C-c C-c` saves and `C-c C-k` cancels.

## How it works

- Every review is stored in `.git/agent-notes/<id>.json`, with the diff snapshot next to it in `<id>.diff`. Nothing is committed. The code under review is never touched.
- Each review has its own Copilot session (`copilot --session-id <uuid>`), so when you send replies the agent remembers the review.
- Copilot runs non-interactively (`copilot -p`). It may only read files and run the read-only commands in `agent-notes-allowed-tools`. File writes are denied (`agent-notes-denied-tools`). It answers with a JSON block, and only Emacs writes the review files.
- Notes are anchored to a file, a side (`new`/`old`) and a line number. Because the snapshot never changes, notes always stay on the right line. A note on a line outside the diff is shown under the nearest line and marked "not in diff".

## Customization

`M-x customize-group RET agent-notes`. Useful options:

- `agent-notes-copilot-extra-args`: for example `'("--model" "gpt-5")`
- `agent-notes-review-instructions`: extra guidance for every review, such as the project's conventions
- `agent-notes-base-branch`: the default base branch for branch reviews

## Development

```sh
emacs -Q --batch -L . -l agent-notes-tests.el -f ert-run-tests-batch-and-exit
```

`e2e.el` runs a real review and reply against Copilot (see the comment at the top).
