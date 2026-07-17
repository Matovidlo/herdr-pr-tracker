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
declare -a ROW_URL ROW_CWD
# pane_id -> PR url; scraping pane scrollback is the slowest step, do it once
# per pane and only rediscover on explicit refresh ('r').
declare -A URL_CACHE

# Find the PR url for one agent: first scrape recent pane text, then fall back to
# `gh pr list --head <branch>` using the pane's working directory.
find_pr() {
  local pane_id="$1" cwd="$2" url branch
  url="$("$HERDR" pane read "$pane_id" --source recent --lines 4000 2>/dev/null \
        | grep -oiE "$PR_URL_RE" | tail -1)"
  if [ -z "$url" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
    branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    # gh resolves the repo from $PWD — must run in the pane's cwd, not ours
    [ -n "$branch" ] && url="$(cd "$cwd" && gh pr list --head "$branch" --json url --jq '.[0].url // empty' 2>/dev/null)"
  fi
  printf '%s' "$url"
}

SCOPE="all"   # all | ws ('w' toggles); PR rows get numbers 1-9, others are just listed

# fetch one PR's display fields into a cache file (used in parallel)
# TSV: number, title, ci, merge, review, comment-count
fetch_pr() {
  local url="$1" out="$2"
  gh pr view "$url" --json number,title,state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,comments,reviews 2>/dev/null \
  | jq -r '[(.number // "?"), (.title // ""),
            ([.statusCheckRollup[]?.conclusion // .statusCheckRollup[]?.state] | map(select(.!=null))
             | if length==0 then "-"
               elif any(.=="FAILURE" or .=="ERROR" or .=="TIMED_OUT") then "FAIL"
               elif any(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED") then "..."
               else "ok" end),
            (if .state=="MERGED" then "merged"
             elif .state=="CLOSED" then "closed"
             elif .mergeStateStatus=="DIRTY" or .mergeable=="CONFLICTING" then "confl"
             elif .isDraft then "draft"
             elif .mergeStateStatus=="BEHIND" then "behind"
             elif .mergeable=="MERGEABLE" then "ok"
             elif .mergeable=="UNKNOWN" then "?"
             else "no" end),
            (if .reviewDecision=="APPROVED" then "appr"
             elif .reviewDecision=="CHANGES_REQUESTED" then "me"      # comments to address -> waiting on me
             elif .reviewDecision=="REVIEW_REQUIRED" then "them"      # waiting on reviewers
             else "-" end),
            ((.comments|length) + ([.reviews[]? | select(.body != "")] | length))
           ] | @tsv' > "$out" 2>/dev/null
}

# printf %-Ns pads by bytes, not display columns; widen the field by the
# byte/char surplus so rows with ✓/✗/… still line up.
pad() {
  # NB: ${#s} must not sit on the `local s=...` line — it expands before s is
  # assigned and dies under set -u (same pitfall as in action_for).
  local s="$1" w="$2" c b
  c=${#s}
  b=$(LC_ALL=C; echo "${#s}")
  printf '%-*s' "$((w + b - c))" "$s"
}

# symbol maps for the indicator columns
ci_sym()  { case "$1" in ok) echo "✓";; FAIL) echo "✗";; ...) echo "…";; *) echo "-";; esac; }
mrg_sym() { case "$1" in ok) echo "✓";; confl) echo "✗confl";; behind) echo "↓behind";; no) echo "✗";; *) echo "$1";; esac; }
rev_sym() { case "$1" in appr) echo "✓";; me) echo "←me";; them) echo "→them";; *) echo "-";; esac; }

render() {
  local idx=0 hidden=0 agents pane agent status cwd url num title state checks out=""
  # One jq pass over all agents; current workspace's sessions sort first,
  # optionally narrowed to this board's workspace only ('w').
  local ws=""
  [ "$SCOPE" = ws ] && ws="${HERDR_WORKSPACE_ID:-}"
  agents="$("$HERDR" agent list 2>/dev/null | jq -r --arg ws "$ws" --arg cur "${HERDR_WORKSPACE_ID:-}" '
    [.result.agents[]? | select($ws == "" or .workspace_id == $ws)]
    | sort_by(.workspace_id != $cur)[]
    | [.pane_id, (.agent // .display_agent // "agent"),
       ((.agent_status // "?") | ascii_downcase),
       (.foreground_cwd // .cwd // "")] | @tsv' 2>/dev/null)"

  local cache="$STATE_DIR/prcache"
  mkdir -p "$cache"

  # pass 1a: discover uncached panes' PR urls in parallel
  local -a A_PANE=() A_AGENT=() A_STATUS=() A_CWD=()
  local m=0 i
  while IFS=$'\t' read -r pane agent status cwd; do
    [ -z "$pane" ] && continue
    m=$((m+1)); A_PANE[$m]="$pane"; A_AGENT[$m]="$agent"; A_STATUS[$m]="$status"; A_CWD[$m]="$cwd"
    [ -z "${URL_CACHE[$pane]:-}" ] && find_pr "$pane" "$cwd" > "$cache/url_${pane//:/_}" &
  done <<<"$agents"
  wait
  # pass 1b: fold discoveries into the cache, build rows
  local -a R_AGENT=() R_STATUS=() R_URL=() R_CWD=()
  local -A WANT=()
  local n=0
  for ((i=1; i<=m; i++)); do
    pane="${A_PANE[$i]}"
    url="${URL_CACHE[$pane]:-}"
    if [ -z "$url" ]; then
      url="$(cat "$cache/url_${pane//:/_}" 2>/dev/null)"
      URL_CACHE[$pane]="${url:--}"
    fi
    if [ "$url" = "-" ] || [ -z "$url" ]; then hidden=$((hidden+1)); continue; fi
    n=$((n+1)); R_AGENT[$n]="${A_AGENT[$i]}"; R_STATUS[$n]="${A_STATUS[$i]}"; R_URL[$n]="$url"; R_CWD[$n]="${A_CWD[$i]}"; WANT["$url"]=1
  done

  # pass 2: fetch all PR states in parallel, deduped — wall time = one gh call
  local u
  for u in "${!WANT[@]}"; do
    fetch_pr "$u" "$cache/${u//[:\/]/_}" &
  done
  wait

  # pass 3: assemble off-screen, then draw in one shot (no flicker)
  ROW_URL=(); ROW_CWD=()
  local line
  for ((idx=1; idx<=n; idx++)); do
    url="${R_URL[$idx]}"; ROW_URL[$idx]="$url"; ROW_CWD[$idx]="${R_CWD[$idx]}"
    local mrg rev cmts
    IFS=$'\t' read -r num title checks mrg rev cmts < "$cache/${url//[:\/]/_}" 2>/dev/null || true
    printf -v line '  %-16.16s %-9s %3s  #%-6s %s %s %s %3s  %.32s\n' \
      "${R_AGENT[$idx]}" "${R_STATUS[$idx]}" "$idx" "${num:-?}" \
      "$(pad "$(ci_sym "${checks:--}")" 3)" "$(pad "$(mrg_sym "${mrg:-?}")" 8)" \
      "$(pad "$(rev_sym "${rev:--}")" 6)" "${cmts:-0}" "${title:-}"
    out+="$line"
  done
  [ "$n" -eq 0 ] && out+="  (no PRs found)"$'\n'
  [ "$hidden" -gt 0 ] && out+=$'\n'"  $n PR row(s) shown · $hidden session(s) have no PR and are hidden (r rediscovers)"$'\n'

  clear
  printf '\033[1m  Claude PR Tracker\033[0m [%s]  (number+Enter open · r refresh · c checkout · m merge · p plan · w scope · q quit)\n' \
    "$( [ "$SCOPE" = ws ] && echo "workspace ${HERDR_WORKSPACE_ID:-?}" || echo "all sessions" )"
  printf '  %-16s %-9s %3s  %-7s %-3s %-8s %-6s %3s  %s\n' "AGENT" "STATUS" "N" "PR" "CI" "MERGE" "REVIEW" "C" "TITLE"
  printf '  %s\n' "------------------------------------------------------------------------------"
  printf '%s' "$out"
}

action_for() {
  # NB: keep the array lookup on its own line — in `local a=$1 b=${arr[$a]}`
  # bash expands ${arr[$a]} before $a is assigned, which dies under set -u.
  local n="$1" verb="$2"
  local url="${ROW_URL[$n]:-}"
  local cwd="${ROW_CWD[$n]:-}"
  [ -z "$url" ] && return
  # checkout/merge must run in the session's repo, not the board's cwd
  case "$verb" in
    open)     gh pr view "$url" --web ;;
    checkout) (cd "${cwd:-.}" && gh pr checkout "$url") ;;
    merge)    (cd "${cwd:-.}" && gh pr merge "$url") ;;   # interactive; uses repo defaults
    plan)     local f="$PLANS_DIR/$(basename "$url").md"; ${EDITOR:-vi} "$f" ;;  # ponytail: pane stdout is a pipe, full-screen editors may warn; good enough
  esac
}

PENDING_VERB="open"
NUMBUF=""
while :; do
  render
  # Inner key loop: verb/digit keys don't pay for a re-render; only timeout,
  # 'r', 'w', or a completed action falls through to render again.
  # herdr forwards keystrokes to the pane's stdin, not /dev/tty — read fd0.
  while IFS= read -rsn1 -t 10 key; do
    case "$key" in
      q) clear; exit 0 ;;
      r) URL_CACHE=(); NUMBUF=""; break ;;
      w) [ "$SCOPE" = ws ] && SCOPE="all" || SCOPE="ws"; NUMBUF=""; break ;;
      c) PENDING_VERB="checkout"; NUMBUF=""; printf '\r  [checkout] type row number + Enter … ' ;;
      m) PENDING_VERB="merge";    NUMBUF=""; printf '\r  [merge] type row number + Enter … '    ;;
      p) PENDING_VERB="plan";     NUMBUF=""; printf '\r  [plan] type row number + Enter … '     ;;
      [0-9]) NUMBUF+="$key"; printf '\r  %s row: %s (Enter to run) ' "$PENDING_VERB" "$NUMBUF" ;;
      ''|$'\n'|$'\r')   # Enter — read -n1 yields '' for newline
        [ -z "$NUMBUF" ] && continue
        n="$NUMBUF"; NUMBUF=""
        if [ -z "${ROW_URL[$n]:-}" ]; then
          printf '\r  no PR on row %s (rows: 1-%s)          ' "$n" "${#ROW_URL[@]}"
          PENDING_VERB="open"
        else
          printf '\r  %s row %s … ' "$PENDING_VERB" "$n"
          action_for "$n" "$PENDING_VERB"
          printf 'done \n'
          PENDING_VERB="open"; break
        fi ;;
      *) NUMBUF="" ;;
    esac
  done
done
