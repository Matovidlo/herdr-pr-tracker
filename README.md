# herdr-pr-tracker

A [herdr](https://herdr.dev) plugin that tracks the GitHub PR each Claude Code
session produces, in its own herdr window — with live `gh` state and a few actions.

It polls `herdr agent list`, finds the PR for each session (scrapes the pane's
recent output for a `…/pull/N` URL, falling back to `gh pr list --head <branch>`),
and renders a board with PR number, state, review decision, and CI checks.

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

Sessions from the board's own workspace sort first; sessions with no PR are
hidden behind a `+N session(s) without a PR` footer.

Plan notes live under `$HERDR_PLUGIN_STATE_DIR/plans/` — one markdown file per PR,
so each change keeps its own plan separate from the PR state.

## How it works (no socket code)
Everything is the `herdr` CLI: `agent list`, `pane read`, `pane.agent_detected`
event hook. PR data is `gh pr view --json`. See `scripts/board.sh`.

License: MIT (interacts with herdr only as a subprocess).
