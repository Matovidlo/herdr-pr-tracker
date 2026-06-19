#!/usr/bin/env bash
# Claude PR Tracker board. Polls herdr agent sessions, finds the GitHub PR each
# one produced (by scraping pane output, falling back to the branch), shows gh
# state, and exposes a few actions. Pure CLI: herdr + gh + jq. No socket code.
set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-pr-tracker}"
PLANS_DIR="$STATE_DIR/plans"
mkdir -p "$PLANS_DIR"
PR_URL_RE='https://github\.com/[^[:space:]]+/pull/[0-9]+'

for bin in gh jq; do
  command -v "$bin" >/dev/null || { echo "herdr-pr-tracker: '$bin' not found on PATH"; sleep 5; exit 1; }
done

# rows[] is filled each cycle: "pane_id<TAB>agent<TAB>status<TAB>branch<TAB>pr_url"
declare -a ROW_URL

# Find the PR url for one agent: first scrape recent pane text, then fall back to
# `gh pr list --head <branch>` using the pane's working directory.
find_pr() {
  local pane_id="$1" cwd="$2" url branch
  url="$("$HERDR" pane read "$pane_id" --source recent --lines 4000 2>/dev/null \
        | grep -oiE "$PR_URL_RE" | tail -1)"
  if [ -z "$url" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
    branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    [ -n "$branch" ] && url="$(gh pr list --head "$branch" --json url --jq '.[0].url // empty' 2>/dev/null)"
  fi
  printf '%s' "$url"
}

render() {
  clear
  printf '\033[1m  Claude PR Tracker\033[0m   (r refresh · 1-9 open in browser · c checkout · m merge · p plan · q quit)\n'
  printf '  %-18s %-9s %-9s %-7s %s\n' "AGENT" "STATUS" "PR" "CHECKS" "TITLE"
  printf '  %s\n' "------------------------------------------------------------------------------"
  ROW_URL=()
  local agents idx=0
  agents="$("$HERDR" agent list 2>/dev/null | jq -c '.result.agents[]?' 2>/dev/null)"
  if [ -z "$agents" ]; then
    printf '  (no active agent sessions)\n'
    return
  fi
  while IFS= read -r a; do
    [ -z "$a" ] && continue
    local pane agent status cwd url pr_json num title state checks branch
    pane="$(jq -r '.pane_id' <<<"$a")"
    agent="$(jq -r '.agent // .display_agent // "agent"' <<<"$a")"
    status="$(jq -r '.agent_status' <<<"$a" | tr 'A-Z' 'a-z')"
    cwd="$(jq -r '.foreground_cwd // .cwd // ""' <<<"$a")"
    url="$(find_pr "$pane" "$cwd")"
    if [ -n "$url" ]; then
      pr_json="$(gh pr view "$url" --json number,title,state,reviewDecision,statusCheckRollup 2>/dev/null)"
      num="$(jq -r '.number // "?"' <<<"$pr_json")"
      title="$(jq -r '.title // ""' <<<"$pr_json")"
      state="$(jq -r '(.state // "?") + (if .reviewDecision then " "+.reviewDecision else "" end)' <<<"$pr_json")"
      # checks: pass/fail/pending rollup
      checks="$(jq -r '[.statusCheckRollup[]?.conclusion // .statusCheckRollup[]?.state] | map(select(.!=null))
                       | if length==0 then "-"
                         elif any(.=="FAILURE" or .=="ERROR" or .=="TIMED_OUT") then "FAIL"
                         elif any(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED") then "..."
                         else "ok" end' <<<"$pr_json")"
      idx=$((idx+1)); ROW_URL[$idx]="$url"
      printf '  %-18.18s %-9s #%-8s %-7s %.40s\n' "$idx) $agent" "$status" "$num" "$checks" "$title"
    else
      branch="$( [ -d "$cwd" ] && git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null || true )"
      printf '  %-18.18s %-9s %-9s %-7s %s\n' "$agent" "$status" "(no PR)" "-" "${branch:-$cwd}"
    fi
  done <<<"$agents"
}

action_for() {
  local n="$1" verb="$2" url="${ROW_URL[$n]:-}"
  [ -z "$url" ] && return
  case "$verb" in
    open)     gh pr view "$url" --web ;;
    checkout) gh pr checkout "$url" ;;
    merge)    gh pr merge "$url" ;;            # interactive; uses repo defaults
    plan)     local f="$PLANS_DIR/$(basename "$url").md"; ${EDITOR:-vi} "$f" </dev/tty >/dev/tty 2>&1 ;;
  esac
}

PENDING_VERB="open"
while :; do
  render
  # refresh every 10s, or act on a keypress
  if IFS= read -rsn1 -t 10 key </dev/tty; then
    case "$key" in
      q) clear; exit 0 ;;
      r) : ;;
      c) PENDING_VERB="checkout" ;;
      m) PENDING_VERB="merge" ;;
      p) PENDING_VERB="plan" ;;
      [1-9]) action_for "$key" "$PENDING_VERB"; PENDING_VERB="open" ;;
      *) : ;;
    esac
  fi
done
