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
declare -a ROW_URL ROW_CWD ROW_PANE ROW_STATUS ROW_KIND
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
# TSV: number, title, ci, pr-state, merge, review, comment-count
fetch_pr() {
  local url="$1" out="$2"
  gh pr view "$url" --json number,title,state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,comments,reviews,author,reviewRequests 2>/dev/null \
  | jq -r '[(.number // "?"), (.title // ""),
            ([.statusCheckRollup[]?.conclusion // .statusCheckRollup[]?.state] | map(select(.!=null))
             | if length==0 then "-"
               elif any(.=="FAILURE" or .=="ERROR" or .=="TIMED_OUT") then "FAIL"
               elif any(.=="PENDING" or .=="IN_PROGRESS" or .=="QUEUED") then "..."
               else "ok" end),
            (if .state=="MERGED" then "merged"      # PR lifecycle: draft vs published for review
             elif .state=="CLOSED" then "closed"
             elif .isDraft then "draft"
             else "ready" end),
            (if .mergeStateStatus=="DIRTY" or .mergeable=="CONFLICTING" then "confl"   # pure mergeability, independent of draft-ness
             elif .mergeStateStatus=="BEHIND" then "behind"
             elif .mergeable=="MERGEABLE" then "ok"
             elif .mergeable=="UNKNOWN" then "?"
             else "no" end),
            (if .reviewDecision=="APPROVED" then "appr"
             elif .reviewDecision=="CHANGES_REQUESTED" then "me"      # comments to address -> waiting on me
             elif .reviewDecision=="REVIEW_REQUIRED" then "them"      # waiting on reviewers
             else "-" end),
            ((.comments|length) + ([.reviews[]? | select(.body != "")] | length)),
            (.author.login // "-"),
            # pending reviewers: users have .login, teams have .name/.slug
            ([.reviewRequests[]? | .login // .slug // .name // empty] | join(","))
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
mrg_col() { case "$1" in ok) printf %s "$C_GRN";; confl|no) printf %s "$C_RED";; behind) printf %s "$C_YEL";; esac; }
st_col()  { case "$1" in ready) printf %s "$C_GRN";; draft) printf %s "$C_YEL";; merged) printf %s "$C_MAG";; closed) printf %s "$C_DIM";; esac; }
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
  local -a R_AGENT=() R_STATUS=() R_URL=() R_CWD=() R_PANE=() R_KIND=()
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
    n=$((n+1)); R_AGENT[$n]="${A_AGENT[$i]}"; R_STATUS[$n]="${A_STATUS[$i]}"; R_URL[$n]="$url"; R_CWD[$n]="${A_CWD[$i]}"; R_PANE[$n]="$pane"; R_KIND[$n]="sess"; WANT["$url"]=1
  done

  local u2
  local -A SEEN=()
  for ((i=1; i<=n; i++)); do SEEN["${R_URL[$i]}"]=1; done

  # pass 1c: PRs waiting for YOUR review (review requested from you, directly
  # or via a team) — shown right after the session rows, before your other
  # PRs. 'cr' conducts the review; 'fin' takes the PR over when the author is
  # away. Dependabot PRs are excluded — the 'd' sweep owns those.
  if [ "$SCOPE" = all ]; then
    while IFS= read -r u2; do
      [ -z "$u2" ] && continue
      [ -n "${SEEN[$u2]:-}" ] && continue
      SEEN["$u2"]=1
      n=$((n+1)); R_AGENT[$n]="-"; R_STATUS[$n]="-"; R_URL[$n]="$u2"; R_CWD[$n]=""; R_PANE[$n]=""; R_KIND[$n]="rev"; WANT["$u2"]=1
    done < <(gh search prs --review-requested=@me --state=open --sort=updated --limit 20 --json url --jq '.[].url' -- -author:app/dependabot 2>/dev/null)
  fi

  # pass 1d: your other open PRs (no claude session) — authored by you or
  # assigned to you — newest activity first, appended after the session rows;
  # 'cc' can attach a session to them.
  # Opt-in per machine: touch "$STATE_DIR/show-authored" to enable.
  if [ "$SCOPE" = all ] && [ -f "$STATE_DIR/show-authored" ]; then
    while IFS= read -r u2; do
      [ -z "$u2" ] && continue
      [ -n "${SEEN[$u2]:-}" ] && continue
      SEEN["$u2"]=1
      n=$((n+1)); R_AGENT[$n]="-"; R_STATUS[$n]="-"; R_URL[$n]="$u2"; R_CWD[$n]=""; R_PANE[$n]=""; R_KIND[$n]="mine"; WANT["$u2"]=1
    done < <({ gh search prs --author=@me --state=open --sort=updated --limit 20 --json url --jq '.[].url'
               gh search prs --assignee=@me --state=open --sort=updated --limit 20 --json url --jq '.[].url'; } 2>/dev/null)
  fi

  # pass 2: fetch all PR states in parallel, deduped — wall time = one gh call
  local u
  for u in "${!WANT[@]}"; do
    fetch_pr "$u" "$cache/${u//[:\/]/_}" &
  done
  wait

  # pass 3: assemble off-screen, then draw in one shot (no flicker)
  ROW_URL=(); ROW_CWD=(); ROW_PANE=(); ROW_STATUS=(); ROW_KIND=()
  local line
  for ((idx=1; idx<=n; idx++)); do
    # section separator when entering the review-requested block
    if [ "${R_KIND[$idx]:-}" = rev ] && [ "${R_KIND[$((idx-1))]:-}" != rev ]; then
      out+="  ${C_DIM}— waiting for your review (cr review · fin take over) —${C_RST}"$'\n'
    fi
    # ...and when it ends: your authored/assigned PRs are NOT waiting for your review
    if [ "${R_KIND[$idx]:-}" = mine ] && [ "${R_KIND[$((idx-1))]:-}" != mine ]; then
      out+="  ${C_DIM}— your other open PRs —${C_RST}"$'\n'
    fi
    url="${R_URL[$idx]}"; ROW_URL[$idx]="$url"; ROW_CWD[$idx]="${R_CWD[$idx]}"; ROW_PANE[$idx]="${R_PANE[$idx]}"; ROW_STATUS[$idx]="${R_STATUS[$idx]}"; ROW_KIND[$idx]="${R_KIND[$idx]:-}"
    local st mrg rev cmts author reviewers rname revd
    IFS=$'\t' read -r num title checks st mrg rev cmts author reviewers < "$cache/${url//[:\/]/_}" 2>/dev/null || true
    rname="${url#https://github.com/}"; rname="${rname#*/}"; rname="${rname%%/pull/*}"
    # REVIEW shows WHO it waits on: →<first pending reviewer> instead of →them
    revd="$(rev_sym "${rev:--}")"
    [ "$rev" = them ] && [ -n "${reviewers:-}" ] && revd="→${reviewers%%,*}"
    printf -v line '  %-16.16s %s%-9s%s %3s  #%-6s %-14.14s %s%s%s %s%-6s%s %s%s%s %s%s%s %-12.12s %3s  %.32s\n' \
      "${R_AGENT[$idx]}" "$(sts_col "${R_STATUS[$idx]}")" "${R_STATUS[$idx]}" "$C_RST" "$idx" "${num:-?}" "$rname" \
      "$(ci_col "${checks:--}")"  "$(pad "$(ci_sym "${checks:--}")" 3)"  "$C_RST" \
      "$(st_col "${st:-?}")"      "${st:-?}"                             "$C_RST" \
      "$(mrg_col "${mrg:-?}")"    "$(pad "$(mrg_sym "${mrg:-?}")" 8)"    "$C_RST" \
      "$(rev_col "${rev:--}")"    "$(pad "${revd:0:10}" 10)"             "$C_RST" \
      "${author:--}" "${cmts:-0}" "${title:-}"
    out+="$line"
  done
  [ "$n" -eq 0 ] && out+="  (no PRs found)"$'\n'
  [ "$hidden" -gt 0 ] && out+=$'\n'"  ${C_DIM}$n PR row(s) shown · $hidden session(s) have no PR and are hidden (r rediscovers)${C_RST}"$'\n'

  [ -n "${QUIET:-}" ] && return   # headless --triage: collect rows, draw nothing
  clear
  printf '%s  Claude PR Tracker%s [%s]  %s(number+Enter open · : cmdline "1,2c,3m" · t triage · d deps · ? help · r refresh · c checkout · m merge · p plan · w scope · q quit)%s\n' \
    "$C_BLD" "$C_RST" \
    "$( [ "$SCOPE" = ws ] && echo "workspace ${HERDR_WORKSPACE_ID:-?}" || echo "all sessions" )" \
    "$C_DIM" "$C_RST"
  # surface the loaded custom verbs so ":1pr,2ar" possibilities are discoverable
  if [ ${#CMDS[@]} -gt 0 ]; then
    printf '  %sverbs: o c m p cc + %s  (? shows templates)%s\n' "$C_DIM" \
      "$(printf '%s\n' "${!CMDS[@]}" | sort | tr '\n' ' ')" "$C_RST"
  else
    printf '  %sno custom verbs — add them to %s (? for help)%s\n' "$C_DIM" "$CMDS_FILE" "$C_RST"
  fi
  printf '%s  %-16s %-9s %3s  %-7s %-14s %-3s %-6s %-8s %-10s %-12s %3s  %s%s\n' "$C_CYN$C_BLD" "AGENT" "STATUS" "N" "PR" "REPO" "CI" "ST" "MERGE" "REVIEW" "AUTHOR" "C" "TITLE" "$C_RST"
  printf '  %s%s%s\n' "$C_DIM" "--------------------------------------------------------------------------------------------------------------" "$C_RST"
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
      local repo="${url#https://github.com/}"; repo="${repo%%/pull/*}"
      tmpl="${tmpl//\{url\}/$url}"
      tmpl="${tmpl//\{num\}/${url##*/}}"
      tmpl="${tmpl//\{cwd\}/$cwd}"
      tmpl="${tmpl//\{repo\}/$repo}"
      if [[ "$tmpl" == @* ]]; then
        # '@' templates are typed INTO the PR's own claude session (visible in
        # its pane, uses its context) instead of running here.
        local pane="${ROW_PANE[$n]:-}" sts="${ROW_STATUS[$n]:-}"
        [ -z "$pane" ] && { printf '  row %s: no claude session — use ":%scc%s" to spawn one\n' "$n" "$n" "${verb#cmd:}"; return; }
        if [ "$sts" = working ]; then
          printf '  row %s: session is busy (working) — skipped, retry when idle\n' "$n"; return
        fi
        "$HERDR" pane run "$pane" "${tmpl#@}" >/dev/null 2>&1 \
          && printf '  row %s: sent to session %s\n' "$n" "$pane" \
          || printf '  row %s: failed to send to %s\n' "$n" "$pane"
      else
        (cd "${cwd:-.}" && bash -c "$tmpl")
      fi ;;
    spawn:*)  spawn_cc "$n" "${verb#spawn:}" ;;
  esac
}

# 'cc' verb: attach a fresh claude session to a PR in its own herdr workspace.
# Clones the repo into a per-PR checkout dir (reused on later calls), checks
# out the PR branch, spawns workspace + claude, and optionally types a
# follow-up verb's template into the new session (":10ccar").
spawn_cc() {
  local n="$1" follow="$2"
  local url="${ROW_URL[$n]:-}" num repo dir out wsid pane root
  [ -z "$url" ] && return
  num="${url##*/}"
  repo="${url#https://github.com/}"; repo="${repo%%/pull/*}"
  # ponytail: full clone per PR — simple and isolated; switch to shared clone
  # + worktrees if big repos make this too slow
  dir="$STATE_DIR/checkouts/${repo//\//_}-pr$num"
  if [ ! -d "$dir/.git" ]; then
    printf '  row %s: cloning %s … ' "$n" "$repo"
    gh repo clone "$repo" "$dir" -- --quiet >/dev/null 2>&1 || { printf 'clone failed\n'; return; }
    printf 'ok\n'
  fi
  (cd "$dir" && gh pr checkout "$url" >/dev/null 2>&1) || { printf '  row %s: gh pr checkout failed in %s\n' "$n" "$dir"; return; }
  out="$("$HERDR" workspace create --cwd "$dir" --label "PR #$num" --no-focus 2>/dev/null)"
  wsid="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out" 2>/dev/null)"
  root="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out" 2>/dev/null)"
  [ -z "$wsid" ] && { printf '  row %s: workspace create failed\n' "$n"; return; }
  # agent names are unique server-wide — a second cc with the name "claude"
  # would die with agent_name_taken, so key the name to the workspace
  out="$("$HERDR" agent start "claude-$wsid" --workspace "$wsid" --cwd "$dir" --focus -- claude 2>/dev/null)"
  pane="$(jq -r '.result.agent.pane_id // empty' <<<"$out" 2>/dev/null)"
  if [ -z "$pane" ]; then
    printf '  row %s: agent start failed: %s\n' "$n" "$(jq -r '.error.message // "unknown error"' <<<"$out" 2>/dev/null)"
    "$HERDR" workspace close "$wsid" >/dev/null 2>&1
    return
  fi
  # workspace create spawns a root shell pane and agent start adds its own,
  # leaving a 2-pane split — close the shell so only the claude pane remains
  [ -n "$root" ] && "$HERDR" pane close "$root" >/dev/null 2>&1
  printf '  row %s: claude started in workspace %s (%s)\n' "$n" "$wsid" "$dir"
  [ -z "$follow" ] && return
  local tmpl="${CMDS[$follow]:-}"
  tmpl="${tmpl//\{url\}/$url}"
  tmpl="${tmpl//\{num\}/$num}"
  tmpl="${tmpl//\{cwd\}/$dir}"
  tmpl="${tmpl//\{repo\}/$repo}"
  if [[ "$tmpl" == @* ]]; then
    [ -z "$pane" ] && { printf '  row %s: no pane id — run "%s" manually\n' "$n" "$follow"; return; }
    # let claude boot before typing the prompt
    "$HERDR" agent wait "$pane" --status idle --timeout 90000 >/dev/null 2>&1
    "$HERDR" pane run "$pane" "${tmpl#@}" >/dev/null 2>&1 \
      && printf '  row %s: sent %s to the new session\n' "$n" "$follow" \
      || printf '  row %s: failed to send %s\n' "$n" "$follow"
  else
    (cd "$dir" && bash -c "$tmpl")
  fi
}

# user-defined verbs: "<verb> = <command template>" lines in commands.conf.
# Templates get {url} {num} {cwd} substituted and run in the session's cwd.
CMDS_FILE="$STATE_DIR/commands.conf"
declare -A CMDS
# Built-in default verbs — generic, no personal skills required. Any line in
# commands.conf with the same verb name overrides the default.
declare -A DEFAULT_CMDS=(
  [pr]='@Review PR {url}: review only the changed code (the diff), rank findings by severity with exact file:line, be concrete about fixes, and present a findings table — do not post to GitHub without approval.'
  [ar]='@Address the review comments on PR {url}: read all unresolved review and bot comments, implement the fixes, push, and reply to each comment.'
  [r]='@Rebase PR {url} on its base branch, resolve any conflicts, and push with --force-with-lease.'
  [rs]='@CI on PR {url} is failing: analyze the failing checks, fix them, push, and repeat until every check is green.'
  [s]='@/simplify'
  [pub]='gh pr ready {url}'
  [cr]='@Conduct a code review of PR {url} as the requested reviewer: study the full diff, check correctness, tests, and maintainability, rank findings by severity with exact file:line, and present a findings table — do not submit the review to GitHub without approval.'
  [fin]='@Take over PR {url} and finish it: read the discussion and unresolved review comments, address them, fix any failing CI, rebase on the base branch if needed, and push until the PR is green and ready to merge.'
  [dep]='@Wrap up dependabot and security compliance for {repo}: list all open dependabot PRs and open dependabot alerts (critical/high first), merge or combine the safe bumps, fix what the alerts require, and report anything that needs manual attention.'
)
load_cmds() {
  CMDS=()
  local v verb tmpl
  for v in "${!DEFAULT_CMDS[@]}"; do CMDS["$v"]="${DEFAULT_CMDS[$v]}"; done
  [ -f "$CMDS_FILE" ] || return 0
  while IFS='=' read -r verb tmpl; do
    verb="${verb//[[:space:]]/}"
    tmpl="${tmpl#"${tmpl%%[![:space:]]*}"}"   # ltrim
    [[ "$verb" =~ ^[a-z]+$ ]] && [ -n "$tmpl" ] && CMDS["$verb"]="$tmpl"
  done < <(grep -v '^[[:space:]]*#' "$CMDS_FILE" 2>/dev/null)
}
[ -f "$CMDS_FILE" ] || cat > "$CMDS_FILE" <<'EOF'
# herdr-pr-tracker custom verbs, used from the ':' command line, e.g. ":1pr,2r".
# This file is per-machine state (never part of the plugin repo). Defaults for
# pr/ar/r/rs/s/pub are built into the plugin; a line here with the same verb
# name overrides the default. '?' on the board lists the effective set.
#
# <verb> = <command template>; runs in the PR's session cwd.
# Prefix the template with '@' to type it into the PR's own claude session
# instead (skipped while that session is working).
# Placeholders: {url} {num} {cwd} {repo}
# pr  = @/prreview {url}
# ar  = @/pr-comment-response {url}
# r   = @/pr-rebase {url}
# rs  = @/goal CI on {url} is failing: analyze the failing checks, fix them, push, and repeat until every check is green
EOF
load_cmds

# full help: keys, batch syntax, built-in verbs, and every loaded custom verb
show_help() {
  printf '\n%s  keys%s      <n>+Enter open in browser · c/m/p then <n>+Enter checkout/merge/plan · : batch · t triage · d dependabot/security sweep · r refresh · w scope · q quit\n' "$C_BLD" "$C_RST"
  printf '%s  batch%s     :<row><verb>[,<row><verb>…]  e.g. ":1pr,2m,3r,4ar" — no verb = open, so ":1,2" opens two tabs\n' "$C_BLD" "$C_RST"
  printf '%s  built-in%s  o open · c checkout · m merge · p plan · cc new workspace+claude on the PR (combine: ":10ccar" = cc, then run ar there)\n' "$C_BLD" "$C_RST"
  printf '%s  verbs%s     '"'"'@'"'"' = typed into the PR'"'"'s claude session · override defaults in %s:\n' "$C_BLD" "$C_RST" "$CMDS_FILE"
  local v tag
  while IFS= read -r v; do
    tag="custom "
    [ "${DEFAULT_CMDS[$v]:-}" = "${CMDS[$v]}" ] && tag="default"
    printf '    %-5s %s%s%s = %s\n' "$v" "$C_DIM" "$tag" "$C_RST" "${CMDS[$v]}"
  done < <(printf '%s\n' "${!CMDS[@]}" | sort)
  printf '\n  press any key to return '
  IFS= read -rsn1 -t 60 _ || true
}

# resolve a short verb token to an action_for verb; empty = open.
# Built-ins win; anything else looks up commands.conf (-> "cmd:<verb>").
resolve_verb() {
  case "$1" in
    ''|o) echo open ;;
    c)    echo checkout ;;
    m)    echo merge ;;
    p)    echo plan ;;
    cc*)  # spawn a fresh workspace+claude for the PR; optional follow-up verb ("ccar")
      local f="${1#cc}"
      if [ -z "$f" ] || [ -n "${CMDS[$f]:-}" ]; then echo "spawn:$f"; else return 1; fi ;;
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
    if [ "$tok" = "?" ] || [ "$tok" = help ]; then show_help; continue; fi
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
  local ci="$1" st="$2" mrg="$3" rev="$4" kind="${5:-}"
  case "$st" in merged|closed) return ;; esac   # done — nothing to suggest
  if [ "$kind" = rev ]; then
    # someone else's PR waiting on you: conduct the review ('fin' to take it
    # over instead is a manual call — never suggest rewriting a colleague's PR)
    [ -n "${CMDS[cr]:-}" ] && echo cr
    return
  fi
  case "$mrg" in confl|behind)
    [ -n "${CMDS[r]:-}" ] && { echo r; return; }
    echo c; return ;;   # no rebase verb defined: at least check it out
  esac
  if [ "$ci" = FAIL ] && [ -n "${CMDS[rs]:-}" ] && [ "$rev" != me ]; then
    echo rs; return   # failing CI with no review comments to address: fix-CI verb
  fi
  if [ "$rev" = me ] || [ "$ci" = FAIL ]; then
    [ -n "${CMDS[ar]:-}" ] && echo ar; return
  fi
  if [ "$mrg" = ok ] && [ "$ci" != FAIL ] && [ "$ci" != "..." ]; then
    # green draft: suggest a publish verb (e.g. pub = gh pr ready {url}); never merge a draft
    if [ "$st" = draft ]; then
      [ -n "${CMDS[pub]:-}" ] && echo pub; return
    fi
    [ "$rev" = appr ] && { echo m; return; }
  fi
  [ "$rev" = "-" ] && [ -n "${CMDS[pr]:-}" ] && echo pr
}

# 'd': per-repo dependabot/security sweep over the repos on the board.
# Separate from 't' on purpose — repo-level hygiene, not per-PR triage.
# Fills DEP_BATCH ("3dep,7dep") so repos can be wrapped up all at once (Enter)
# or one by one (":3dep").
DEP_BATCH=""
dep_scan() {
  DEP_BATCH=""
  printf '\n%s  dependabot / security (repos on the board):%s\n' "$C_BLD" "$C_RST"
  local -A REPOS=()
  local idx url repo dp al crit high sev clean=0
  for ((idx=1; idx<=${#ROW_URL[@]}; idx++)); do
    url="${ROW_URL[$idx]:-}"; [ -z "$url" ] && continue
    repo="${url#https://github.com/}"; repo="${repo%%/pull/*}"
    [ -n "${REPOS[$repo]:-}" ] || REPOS[$repo]="$idx"   # first row per repo — target for the dep verb
  done
  # also repos you contributed to in the past (your authored PRs, any state) —
  # they get no row token, but their dependabot/security state is still shown
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    [ -n "${REPOS[$repo]:-}" ] || REPOS[$repo]=""
  done < <({ gh search prs --author=@me --sort=updated --limit 50 --json repository --jq '.[].repository.nameWithOwner'
             gh search prs --assignee=@me --sort=updated --limit 50 --json repository --jq '.[].repository.nameWithOwner'; } 2>/dev/null | sort -u)
  [ ${#REPOS[@]} -eq 0 ] && { printf '  (no repos)\n'; return; }
  # ponytail: sequential gh calls, ~1s per repo; parallelize via prcache files if the list grows
  while IFS= read -r repo; do
    dp="$(gh pr list --repo "$repo" --author 'app/dependabot' --state open --json number --jq length 2>/dev/null || echo '?')"
    # needs security_events scope; '?' when the token can't see alerts
    al=? crit=? high=?
    IFS=$'\t' read -r al crit high < <(gh api "repos/$repo/dependabot/alerts?state=open&per_page=100" \
      --jq '[.[].security_advisory.severity] | [length, ([.[]|select(.=="critical")]|length), ([.[]|select(.=="high")]|length)] | @tsv' 2>/dev/null) || true
    # on 403 (alerts disabled / no scope) gh prints the error JSON to stdout — treat non-numbers as unknown
    [[ "$al" =~ ^[0-9]+$ ]] || { al='?'; crit='?'; high='?'; }
    [[ "$dp" =~ ^[0-9]+$ ]] || dp='?'
    sev=""
    [ "${crit:-0}" != 0 ] && [ "$crit" != "?" ] && sev=" (${crit} critical"
    if [ "${high:-0}" != 0 ] && [ "$high" != "?" ]; then sev+="${sev:+, }"; [ -z "$sev" ] && sev=" ("; sev+="${high} high"; fi
    [ -n "$sev" ] && sev+=")"
    if { [ "$dp" != "?" ] && [ "$dp" != 0 ]; } || { [ "$al" != "?" ] && [ "$al" != 0 ]; }; then
      local hint="no PR on the board — check it out manually"
      [ -n "${REPOS[$repo]}" ] && hint="\":${REPOS[$repo]}dep\" wraps this repo up"
      printf '  %s%-30s%s %s dependabot PR(s) · %s alert(s)%s — %s\n' \
        "$( [ "${crit:-0}" != 0 ] && [ "$crit" != "?" ] && printf %s "$C_RED" || printf %s "$C_YEL" )" \
        "$repo" "$C_RST" "${dp:-?}" "${al:-?}" "$sev" "$hint"
      [ -n "${REPOS[$repo]}" ] && DEP_BATCH+="${DEP_BATCH:+,}${REPOS[$repo]}dep"
    else
      clean=$((clean+1))   # nothing to do — don't list it
    fi
  done < <(printf '%s\n' "${!REPOS[@]}" | sort)
  [ "$clean" -gt 0 ] && printf '  %s(%s clean repo(s) hidden)%s\n' "$C_DIM" "$clean" "$C_RST"
}

# go through every row, print why each one needs (or doesn't need) attention,
# and assemble the suggested batch into TRIAGE_BATCH.
TRIAGE_BATCH=""
triage() {
  TRIAGE_BATCH=""
  local idx url num title ci st mrg rev cmts author reviewers verb why cache="$STATE_DIR/prcache"
  printf '\n%s  triage:%s\n' "$C_BLD" "$C_RST"
  for ((idx=1; idx<=${#ROW_URL[@]}; idx++)); do
    url="${ROW_URL[$idx]:-}"; [ -z "$url" ] && continue
    IFS=$'\t' read -r num title ci st mrg rev cmts author reviewers < "$cache/${url//[:\/]/_}" 2>/dev/null || continue
    verb="$(suggest_verb "${ci:--}" "${st:-?}" "${mrg:-?}" "${rev:--}" "${ROW_KIND[$idx]:-}")"
    # session-less row + session-bound verb: suggest spawning a session first
    if [ -n "$verb" ] && [ -z "${ROW_PANE[$idx]:-}" ] && [[ "${CMDS[$verb]:-}" == @* ]]; then verb="cc$verb"; fi
    why=""
    if [ "${ROW_KIND[$idx]:-}" = rev ] && [ "$st" != merged ] && [ "$st" != closed ]; then
      why="by ${author:-?}, waiting for your review — conduct CR (\":${idx}fin\" takes it over if the author is away)"
    else
    case "$st" in merged|closed) why="" ;; *)
      [ "$mrg" = confl ]  && why="conflicts — rebase needed"
      [ "$mrg" = behind ] && why="behind base — rebase/update"
      [ -z "$why" ] && [ "$rev" = me ] && why="review comments waiting on you"
      [ -z "$why" ] && [ "$ci" = FAIL ] && why="CI failing"
      [ -z "$why" ] && [ "$st" = draft ] && [ "$mrg" = ok ] && why="green draft — publish for review"
      [ -z "$why" ] && [ -n "$verb" ] && [ "$verb" = m ] && why="green and approved — mergeable"
      [ -z "$why" ] && [ -n "$verb" ] && [ "$verb" = pr ] && why="no review yet — run your review skill" ;;
    esac
    fi
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
      d)  # dependabot/security sweep: Enter wraps up every flagged repo, or run one repo via ":<n>dep"
        dep_scan
        if [ -n "$DEP_BATCH" ]; then
          printf '\n  wrap up all: %s%s%s — Enter to run, any other key to cancel ' "$C_BLD" "$DEP_BATCH" "$C_RST"
          IFS= read -rsn1 k2 || k2=x
          if [ -z "$k2" ]; then printf '\n'; run_batch "$DEP_BATCH"; printf '  (any key to refresh) '; IFS= read -rsn1 -t 30 _ || true; fi
        else
          printf '\n  all repos clean — press any key '
          IFS= read -rsn1 -t 60 _ || true
        fi
        NUMBUF=""; break ;;
      w) [ "$SCOPE" = ws ] && SCOPE="all" || SCOPE="ws"; NUMBUF=""; break ;;
      '?') show_help; NUMBUF=""; break ;;   # NB: quoted — bare ? is a glob matching any key
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
