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
declare -a ROW_URL ROW_CWD ROW_PANE ROW_STATUS
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

# ANSI palette; colors wrap the already-padded field so escape codes (zero
# display width) never enter pad()'s byte math.
C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_MAG=$'\033[35m'
C_CYN=$'\033[36m' C_DIM=$'\033[2m'  C_BLD=$'\033[1m'  C_RST=$'\033[0m'
ci_col()  { case "$1" in ok) printf %s "$C_GRN";; FAIL) printf %s "$C_RED";; ...) printf %s "$C_YEL";; esac; }
mrg_col() { case "$1" in ok) printf %s "$C_GRN";; confl|no) printf %s "$C_RED";; behind) printf %s "$C_YEL";; merged) printf %s "$C_MAG";; draft|closed) printf %s "$C_DIM";; esac; }
rev_col() { case "$1" in appr) printf %s "$C_GRN";; me) printf %s "$C_RED";; them) printf %s "$C_YEL";; esac; }
sts_col() { case "$1" in working) printf %s "$C_GRN";; blocked) printf %s "$C_RED";; idle|done) printf %s "$C_DIM";; esac; }

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
  local -a R_AGENT=() R_STATUS=() R_URL=() R_CWD=() R_PANE=()
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
    n=$((n+1)); R_AGENT[$n]="${A_AGENT[$i]}"; R_STATUS[$n]="${A_STATUS[$i]}"; R_URL[$n]="$url"; R_CWD[$n]="${A_CWD[$i]}"; R_PANE[$n]="$pane"; WANT["$url"]=1
  done

  # pass 2: fetch all PR states in parallel, deduped — wall time = one gh call
  local u
  for u in "${!WANT[@]}"; do
    fetch_pr "$u" "$cache/${u//[:\/]/_}" &
  done
  wait

  # pass 3: assemble off-screen, then draw in one shot (no flicker)
  ROW_URL=(); ROW_CWD=(); ROW_PANE=(); ROW_STATUS=()
  local line
  for ((idx=1; idx<=n; idx++)); do
    url="${R_URL[$idx]}"; ROW_URL[$idx]="$url"; ROW_CWD[$idx]="${R_CWD[$idx]}"; ROW_PANE[$idx]="${R_PANE[$idx]}"; ROW_STATUS[$idx]="${R_STATUS[$idx]}"
    local mrg rev cmts
    IFS=$'\t' read -r num title checks mrg rev cmts < "$cache/${url//[:\/]/_}" 2>/dev/null || true
    printf -v line '  %-16.16s %s%-9s%s %3s  #%-6s %s%s%s %s%s%s %s%s%s %3s  %.32s\n' \
      "${R_AGENT[$idx]}" "$(sts_col "${R_STATUS[$idx]}")" "${R_STATUS[$idx]}" "$C_RST" "$idx" "${num:-?}" \
      "$(ci_col "${checks:--}")"  "$(pad "$(ci_sym "${checks:--}")" 3)"  "$C_RST" \
      "$(mrg_col "${mrg:-?}")"    "$(pad "$(mrg_sym "${mrg:-?}")" 8)"    "$C_RST" \
      "$(rev_col "${rev:--}")"    "$(pad "$(rev_sym "${rev:--}")" 6)"    "$C_RST" \
      "${cmts:-0}" "${title:-}"
    out+="$line"
  done
  [ "$n" -eq 0 ] && out+="  (no PRs found)"$'\n'
  [ "$hidden" -gt 0 ] && out+=$'\n'"  ${C_DIM}$n PR row(s) shown · $hidden session(s) have no PR and are hidden (r rediscovers)${C_RST}"$'\n'

  [ -n "${QUIET:-}" ] && return   # headless --triage: collect rows, draw nothing
  clear
  printf '%s  Claude PR Tracker%s [%s]  %s(number+Enter open · : cmdline "1,2c,3m" · t triage · r refresh · c checkout · m merge · p plan · w scope · q quit)%s\n' \
    "$C_BLD" "$C_RST" \
    "$( [ "$SCOPE" = ws ] && echo "workspace ${HERDR_WORKSPACE_ID:-?}" || echo "all sessions" )" \
    "$C_DIM" "$C_RST"
  printf '%s  %-16s %-9s %3s  %-7s %-3s %-8s %-6s %3s  %s%s\n' "$C_CYN$C_BLD" "AGENT" "STATUS" "N" "PR" "CI" "MERGE" "REVIEW" "C" "TITLE" "$C_RST"
  printf '  %s%s%s\n' "$C_DIM" "------------------------------------------------------------------------------" "$C_RST"
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
    cmd:*)    # user-defined verb from commands.conf
      local tmpl="${CMDS[${verb#cmd:}]:-}"
      [ -z "$tmpl" ] && return
      tmpl="${tmpl//\{url\}/$url}"
      tmpl="${tmpl//\{num\}/${url##*/}}"
      tmpl="${tmpl//\{cwd\}/$cwd}"
      if [[ "$tmpl" == @* ]]; then
        # '@' templates are typed INTO the PR's own claude session (visible in
        # its pane, uses its context) instead of running here.
        local pane="${ROW_PANE[$n]:-}" sts="${ROW_STATUS[$n]:-}"
        [ -z "$pane" ] && { printf '  row %s: no pane to send to\n' "$n"; return; }
        if [ "$sts" = working ]; then
          printf '  row %s: session is busy (working) — skipped, retry when idle\n' "$n"; return
        fi
        "$HERDR" pane run "$pane" "${tmpl#@}" >/dev/null 2>&1 \
          && printf '  row %s: sent to session %s\n' "$n" "$pane" \
          || printf '  row %s: failed to send to %s\n' "$n" "$pane"
      else
        (cd "${cwd:-.}" && bash -c "$tmpl")
      fi ;;
  esac
}

# user-defined verbs: "<verb> = <command template>" lines in commands.conf.
# Templates get {url} {num} {cwd} substituted and run in the session's cwd.
CMDS_FILE="$STATE_DIR/commands.conf"
declare -A CMDS
load_cmds() {
  CMDS=()
  [ -f "$CMDS_FILE" ] || return 0
  local verb tmpl
  while IFS='=' read -r verb tmpl; do
    verb="${verb//[[:space:]]/}"
    tmpl="${tmpl#"${tmpl%%[![:space:]]*}"}"   # ltrim
    [[ "$verb" =~ ^[a-z]+$ ]] && [ -n "$tmpl" ] && CMDS["$verb"]="$tmpl"
  done < <(grep -v '^[[:space:]]*#' "$CMDS_FILE" 2>/dev/null)
}
[ -f "$CMDS_FILE" ] || cat > "$CMDS_FILE" <<'EOF'
# herdr-pr-tracker custom verbs, used from the ':' command line, e.g. ":1pr,2r".
# <verb> = <command template>; runs in the PR's session cwd.
# Prefix the template with '@' to type it into the PR's own claude session
# instead (skipped while that session is working).
# Placeholders: {url} {num} {cwd}
# pr = @/prreview {url}
# ar = @/pr-comment-response {url}
# r  = gh pr checkout {url} && git fetch origin master && git rebase origin/master && git push --force-with-lease
EOF
load_cmds

# resolve a short verb token to an action_for verb; empty = open.
# Built-ins win; anything else looks up commands.conf (-> "cmd:<verb>").
resolve_verb() {
  case "$1" in
    ''|o) echo open ;;
    c)    echo checkout ;;
    m)    echo merge ;;
    p)    echo plan ;;
    *)    [ -n "${CMDS[$1]:-}" ] && echo "cmd:$1" || return 1 ;;
  esac
}

# batch line: comma/space-separated "<row><verb>" tokens, e.g. "1,2c,3m".
# Plain numbers open in the browser, so "1,2" opens two tabs.
run_batch() {
  local tok n verb
  local -a toks
  IFS=', ' read -ra toks <<<"$1"
  for tok in "${toks[@]}"; do
    [ -z "$tok" ] && continue
    if [[ "$tok" =~ ^([0-9]+)([a-z]*)$ ]]; then
      n="${BASH_REMATCH[1]}"
      if ! verb="$(resolve_verb "${BASH_REMATCH[2]}")"; then
        printf '  %s: unknown verb "%s"\n' "$tok" "${BASH_REMATCH[2]}"; continue
      fi
      if [ -z "${ROW_URL[$n]:-}" ]; then
        printf '  %s: no PR on row %s (rows: 1-%s)\n' "$tok" "$n" "${#ROW_URL[@]}"; continue
      fi
      printf '  %s → %s row %s\n' "$tok" "$verb" "$n"
      action_for "$n" "$verb"
    else
      printf '  skipping unrecognized token: %s\n' "$tok"
    fi
  done
}

# map one row's indicators to a suggested verb; empty = nothing for you to do.
# Skill verbs are only suggested when defined in commands.conf.
suggest_verb() {
  local ci="$1" mrg="$2" rev="$3"
  case "$mrg" in confl|behind)
    [ -n "${CMDS[r]:-}" ] && { echo r; return; }
    echo c; return ;;   # no rebase verb defined: at least check it out
  esac
  if [ "$rev" = me ] || [ "$ci" = FAIL ]; then
    [ -n "${CMDS[ar]:-}" ] && echo ar; return
  fi
  if [ "$mrg" = ok ] && [ "$rev" = appr ] && [ "$ci" != FAIL ] && [ "$ci" != "..." ]; then
    echo m; return
  fi
  [ "$rev" = "-" ] && [ -n "${CMDS[pr]:-}" ] && echo pr
}

# go through every row, print why each one needs (or doesn't need) attention,
# and assemble the suggested batch into TRIAGE_BATCH.
TRIAGE_BATCH=""
triage() {
  TRIAGE_BATCH=""
  local idx url num title ci mrg rev cmts verb why cache="$STATE_DIR/prcache"
  printf '\n%s  triage:%s\n' "$C_BLD" "$C_RST"
  for ((idx=1; idx<=${#ROW_URL[@]}; idx++)); do
    url="${ROW_URL[$idx]:-}"; [ -z "$url" ] && continue
    IFS=$'\t' read -r num title ci mrg rev cmts < "$cache/${url//[:\/]/_}" 2>/dev/null || continue
    verb="$(suggest_verb "${ci:--}" "${mrg:-?}" "${rev:--}")"
    why=""
    [ "$mrg" = confl ]  && why="conflicts — rebase needed"
    [ "$mrg" = behind ] && why="behind base — rebase/update"
    [ -z "$why" ] && [ "$rev" = me ] && why="review comments waiting on you"
    [ -z "$why" ] && [ "$ci" = FAIL ] && why="CI failing"
    [ -z "$why" ] && [ -n "$verb" ] && [ "$verb" = m ] && why="green and approved — mergeable"
    [ -z "$why" ] && [ -n "$verb" ] && [ "$verb" = pr ] && why="no review yet — run your review skill"
    if [ -n "$verb" ]; then
      printf '  %s%d%s%s  #%-6s %s\n' "$C_YEL" "$idx" "$verb" "$C_RST" "${num:-?}" "$why"
      TRIAGE_BATCH+="${TRIAGE_BATCH:+,}$idx$verb"
    else
      if [ -n "$why" ]; then   # attention needed but no verb defined in commands.conf
        printf '  %s%d   #%-6s %s — define a verb in commands.conf%s\n' "$C_DIM" "$idx" "${num:-?}" "$why" "$C_RST"
      else
        printf '  %s%d   #%-6s nothing to do%s\n' "$C_DIM" "$idx" "${num:-?}" "$C_RST"
      fi
    fi
  done
}

# headless daily routine: board.sh --triage [--execute]
# Prints suggestions (and a herdr notification); --execute also runs them.
# Cron example:  0 9 * * 1-5  bash .../scripts/board.sh --triage --execute
if [ "${1:-}" = "--triage" ]; then
  QUIET=1 render
  triage
  if [ -n "$TRIAGE_BATCH" ]; then
    "$HERDR" notification show "PR triage" --body "suggested: $TRIAGE_BATCH" >/dev/null 2>&1 || true
    [ "${2:-}" = "--execute" ] && run_batch "$TRIAGE_BATCH"
  fi
  exit 0
fi

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
      r) URL_CACHE=(); NUMBUF=""; load_cmds; break ;;
      t)  # triage: suggest a batch from the indicators, Enter to run it
        triage
        if [ -n "$TRIAGE_BATCH" ]; then
          printf '\n  suggested: %s%s%s — Enter to run, any other key to cancel ' "$C_BLD" "$TRIAGE_BATCH" "$C_RST"
          IFS= read -rsn1 k2 || k2=x
          if [ -z "$k2" ]; then printf '\n'; run_batch "$TRIAGE_BATCH"; printf '  (any key to refresh) '; IFS= read -rsn1 -t 30 _ || true; fi
        else
          printf '\n  nothing needs attention — press any key '
          IFS= read -rsn1 -t 30 _ || true
        fi
        NUMBUF=""; break ;;
      w) [ "$SCOPE" = ws ] && SCOPE="all" || SCOPE="ws"; NUMBUF=""; break ;;
      c) PENDING_VERB="checkout"; NUMBUF=""; printf '\r  [checkout] type row number + Enter … ' ;;
      m) PENDING_VERB="merge";    NUMBUF=""; printf '\r  [merge] type row number + Enter … '    ;;
      p) PENDING_VERB="plan";     NUMBUF=""; printf '\r  [plan] type row number + Enter … '     ;;
      :)  # command line: "1,2c,3m" + Enter runs each token in order
        printf '\r  cmd> '
        IFS= read -r cmdline || cmdline=""
        printf '\n'
        [ -n "$cmdline" ] && run_batch "$cmdline"
        NUMBUF=""; PENDING_VERB="open"
        printf '  (any key to refresh) '
        IFS= read -rsn1 -t 30 _ || true
        break ;;
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
