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

### Rows without a session (your authored/assigned PRs) — opt-in
Besides the PRs of running claude sessions, the board can append **every open
PR you authored or are assigned to** (via `gh search prs --author=@me` +
`--assignee=@me`, deduped — assigned dependabot PRs show up too), sorted by
latest update, with `-` in the AGENT/STATUS columns. Use `cc` to attach a
session to one.

This is **disabled by default** (sessions-only board). Enable it per machine
by touching `show-authored` in the plugin's state dir — under herdr that is
`$HERDR_PLUGIN_STATE_DIR`, the same dir that holds `commands.conf`:

```sh
touch ~/.local/state/herdr/plugins/martinv.pr-tracker/show-authored
```

Delete the file to go back to sessions-only. Only applies in `all sessions`
scope (`w`), and the board reads it every render — no restart needed.

### `cc` — spawn a claude session for a PR
`:10cc` clones the PR's repo into `$HERDR_PLUGIN_STATE_DIR/checkouts/<repo>-pr<N>`
(reused next time), checks out the PR branch, creates a **new herdr workspace**
labeled `PR #N`, and starts claude in it. Combine it with any verb:
`:10ccar` = spawn the workspace, wait for claude to boot, then type the `ar`
template into the new session — e.g. "new workspace, claude attached to that
PR, addressing the review".

### Verbs: built-in defaults + your overrides
The plugin ships **default verbs** that work out of the box (generic prompts,
no personal skills required):

| verb | default action |
|---|---|
| `pr` | `@` review the PR's diff, findings table, no auto-post |
| `ar` | `@` address unresolved review comments, push, reply |
| `r`  | `@` rebase on base branch, resolve conflicts, force-push safely |
| `rs` | `@` analyze failing CI, fix, push, repeat until green |
| `s`  | `@/simplify` |
| `pub`| `gh pr ready {url}` (publish draft; runs locally) |

Your **personal configuration** lives in `$HERDR_PLUGIN_STATE_DIR/commands.conf`
(e.g. `~/.local/state/herdr/plugins/martinv.pr-tracker/commands.conf`). It is
per-machine **state, not part of the plugin repo** — it is never committed, so
your machine-specific skills stay yours. An example file is created on first
run. One `verb = command template` per line; a line with the same verb name
**overrides the built-in default**; new names add new verbs. Placeholders
`{url}` `{num}` `{cwd}` are substituted. `r` (refresh) re-reads the file, and
`?` shows the effective set, tagging each verb `default` or `custom`:

```conf
# override defaults with your own skills
pr = @/prreview {url}
ar = @/pr-comment-response {url}
r  = @/pr-rebase {url}
rs = @/goal CI on {url} is failing: analyze the failing checks, fix them, push, and repeat until every check is green
```

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
skipped. For rows **without a claude session**, `@` verbs are prefixed with
`cc` (e.g. `12ccar`) so a workspace + session is spawned first. Press `Enter`
to run the suggested batch, any other key to cancel (or type your own with `:`).

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
