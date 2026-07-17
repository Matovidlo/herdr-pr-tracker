# herdr-pr-tracker

A [herdr](https://herdr.dev) plugin that tracks the GitHub PR each Claude Code
session produces, in its own herdr window — with live `gh` state and a few actions.

It polls `herdr agent list`, finds the PR for each session (scrapes the pane's
recent output for a `…/pull/N` URL, falling back to `gh pr list --head <branch>`),
and renders a board with per-PR indicators:

- **CI** — `✓` passing / `✗` failing / `…` running / `-` none
- **ST** — PR lifecycle: `draft` · `ready` (published for review) · `merged` · `closed`
- **MERGE** — pure mergeability, independent of draft-ness: `✓` mergeable · `✗confl` conflicts (rebase needed) · `↓behind` behind base
- **REVIEW** — `←me` changes requested (waiting on you) · `→them` review requested (waiting on reviewers) · `✓` approved
- **C** — comment count (issue comments + review comments)

## Requirements
`herdr` ≥ 0.7.0, plus `gh` (authenticated) and `jq` on PATH.

## Install
```sh
# from GitHub once published (repo topic: herdr-plugin)
herdr plugin install <you>/herdr-pr-tracker
# or for local development
herdr plugin link /path/to/herdr-pr-tracker
```

## Open the board
```sh
herdr plugin pane open --plugin martinv.pr-tracker --entrypoint pr-board
```
Or bind a key in `~/.config/herdr/config.toml`:
```toml
[[keys.command]]
key = "prefix+t"            # pick any chord that doesn't collide with your bindings
type = "plugin_action"
command = "martinv.pr-tracker.open-board"   # dot-notation: <plugin_id>.<action_id>
description = "open PR tracker board"
```

## Board keys
Type a row number + `Enter` to open that PR in the browser · `c`/`m`/`p` then
number + `Enter` = checkout / merge / edit plan note · `r` full refresh ·
`w` toggle current-workspace-only ⇄ all sessions · `q` quit.

`:` opens a **command line** for batch actions — comma-separated
`<row><verb>` tokens run in order:

```
:1,2c,3m     # open PR 1 in the browser, checkout PR 2, merge PR 3
```

Verbs: *(none)*/`o` open · `c` checkout · `m` merge · `p` plan. Plain numbers
open browser tabs, so `1,2` opens two PRs at once.

### Custom verbs (your own skills/commands)
Define extra verbs in `$HERDR_PLUGIN_STATE_DIR/commands.conf` (an example file
is created on first run). One `verb = command template` per line; placeholders
`{url}` `{num}` `{cwd}` are substituted and the command runs in that PR's
session working directory:

```conf
pr  = @/prreview {url}
ar  = @/pr-comment-response {url}
pub = gh pr ready {url}
r   = gh pr checkout {url} && git fetch origin master && git rebase origin/master && git push --force-with-lease
```

Then `:1pr,2r` reviews PR 1 with your skill and rebases PR 2. Built-in verbs
win over config; `r` re-reads the file.

Templates starting with **`@`** are not run locally — the text after `@` is
typed **into the claude session that owns the PR** (via `herdr pane run`), so
skills execute with that session's context, visibly in its pane. Sessions with
status `working` are skipped (a half-typed prompt would corrupt their turn);
retry when idle.

### Triage
`t` inspects every row's indicators and suggests one batch: conflicts/behind →
`r` (your rebase verb), review comments waiting on you or failing CI → `ar`,
green **draft** → `pub` (publish for review — drafts are never merged),
green + approved + `ready` → `m`, no review yet → `pr`. Merged/closed PRs are
skipped. Skill verbs are only suggested when defined in `commands.conf`. Press `Enter` to run the suggested batch,
any other key to cancel (or type your own with `:`).

For a daily routine, run it headless from cron:

```cron
0 9 * * 1-5  bash <plugin_root>/scripts/board.sh --triage             # print + herdr notification
0 9 * * 1-5  bash <plugin_root>/scripts/board.sh --triage --execute   # also run the suggested batch
```

`--execute` runs the batch unattended (busy sessions are still skipped), so
enable it only once you trust your verbs — `m` merges PRs.

Sessions from the board's own workspace sort first; sessions with no PR are
hidden behind a `+N session(s) without a PR` footer.

Plan notes live under `$HERDR_PLUGIN_STATE_DIR/plans/` — one markdown file per PR,
so each change keeps its own plan separate from the PR state.

## How it works (no socket code)
Everything is the `herdr` CLI: `agent list`, `pane read`, `pane.agent_detected`
event hook. PR data is `gh pr view --json`. See `scripts/board.sh`.

License: MIT (interacts with herdr only as a subprocess).
