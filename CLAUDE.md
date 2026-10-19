# CLAUDE.md

Guidance for AI agents working on this repository.

## What this is

`agent-notes` is an Emacs package for reviewing git changes together with an
AI agent CLI (GitHub Copilot, Claude Code or Codex), integrated with Magit.
The agent leaves notes on diff lines; the user navigates them, replies,
creates notes, edits or deletes unsent comments, resolves threads, and sends
queued comments in one batch. The agent can edit the working tree when asked,
and its suggestions can be applied with one key. See `README.md` for the
user-facing description and key bindings.

## Layout

Load order follows the dependencies (each file requires the ones above it):

| File                        | Responsibility                                                                                                                              |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `agent-notes-core.el`       | Options, faces, buffer-local state, agent registry (`agent-notes-agents`), JSON storage, review-data helpers, scope labels                  |
| `agent-notes-diff.el`       | Running git, building diffs per scope (worktree, staged, branch, commit, range), parsing hunks, anchoring notes to lines, edit fingerprints |
| `agent-notes-render.el`     | Drawing the review buffer with `magit-section`: unified and side-by-side diffs, note boxes, syntax highlighting                             |
| `agent-notes-log.el`        | The human-readable activity log buffer                                                                                                      |
| `agent-notes-agent.el`      | Prompts, building CLI arguments per agent, running the process, parsing answers, applying suggestions, detecting agent edits                |
| `agent-notes-magit.el`      | Magit integration (optional; loaded from Magit buffers)                                                                                     |
| `agent-notes.el`            | Entry point: major mode, commands, key maps, transient menus                                                                                |
| `test/agent-notes-tests.el` | ERT tests                                                                                                                                   |
| `test/integ.el`             | Batch integration check with Magit against a scratch repo (no agent requests)                                                               |
| `test/e2e.el`               | Manual end-to-end check against the real Copilot CLI (costs requests)                                                                       |

The package files stay at the root so a clone works with `:load-path` or
`package-vc-install`; everything else that is not part of the package goes
in `test/`.

Reviews are stored per repository in `.git/agent-notes/` as `ID.json` plus an
`ID.diff` snapshot. They are local and never pushed.

## Commands

Run these from the project root. Emacs is
`/Applications/Emacs.app/Contents/MacOS/Emacs`; packages (Magit, transient)
come from `~/.config/emacs/elpa`.

Tests:

```sh
/Applications/Emacs.app/Contents/MacOS/Emacs -Q --batch --eval '(progn (setq package-user-dir (expand-file-name "~/.config/emacs/elpa")) (package-initialize))' -L . -l test/agent-notes-tests.el -f ert-run-tests-batch-and-exit
```

Strict compile (warnings are errors), then remove the `.elc` files so they
don't shadow the sources:

```sh
/Applications/Emacs.app/Contents/MacOS/Emacs -Q --batch --eval '(progn (setq package-user-dir (expand-file-name "~/.config/emacs/elpa")) (package-initialize))' --eval "(setq byte-compile-error-on-warn t)" -L . -f batch-byte-compile agent-notes-core.el agent-notes-diff.el agent-notes-render.el agent-notes-log.el agent-notes-agent.el agent-notes-magit.el agent-notes.el test/agent-notes-tests.el && echo COMPILE-OK; rm -f *.elc test/*.elc
```

Integration (needs a scratch repo with uncommitted changes to `stats.py` and at
least one review, e.g. `/tmp/an-demo4/`):

```sh
/Applications/Emacs.app/Contents/MacOS/Emacs -Q --batch --eval '(progn (setq package-user-dir (expand-file-name "~/.config/emacs/elpa")) (package-initialize))' -L . --eval '(setq default-directory "/tmp/an-demo4/")' -l test/integ.el
```

## Working rules

- After every change: strict compile and run the tests. Add or update tests
  for new behaviour.
- Keep `README.md` in sync with user-visible changes (commands, keys, options).
- Commit only when the user asks.
- Real agent runs cost the user requests. Ask before running `test/e2e.el` or any
  real Copilot, Claude Code or Codex call; tests use fake scripts instead.
- Keep changes focused and in the style of the surrounding code. Answers to
  the user should be concise.

## Conventions and pitfalls

- Every file uses `lexical-binding: t`. Private names use `agent-notes--`.
- Docstring lines must be at most 80 columns (the compiler warns).
- Use `declare-function` for optional libraries (Magit in non-Magit files,
  graphviz, etc.) so the strict compile stays clean.
- Never put `default` in a face list: it resets the note background. Build
  face lists with `agent-notes--faces`.
- `magit-insert-heading` must produce a single line.
- `json-serialize` turns nil into `{}`; drop nil values with
  `agent-notes--compact` before serializing.
- Tests that create real repos need the git identity environment variables
  and `commit.gpgsign=false`.
- Claude Code's variadic options (`--allowedTools`, `--add-dir`, ...) swallow
  the following positional arguments. The prompt goes on stdin, and each
  variadic list must be followed by another option.
- In `agent-notes--detect-changes`, a `before` fingerprint of `:unknown` means
  it could not be computed; nil means a clean tree. Don't conflate them.
- Adding an agent: add an entry to `agent-notes-agents` (`:name`, `:program`,
  `:args`, `:stdin`, `:output-file`, `:session-regexp`), an args function
  taking the request plist (`:prompt`, `:session`, `:resume`, `:output-file`),
  options for the program and extra args, and tests with a fake script.
- Codex support is untested against the real CLI; Claude Code was checked
  against `claude --help` (2.1.117) but only exercised with a fake script.
