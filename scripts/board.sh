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
STALE_SECS=600   # PR state + search results are reused within this window; 'r' forces a live refetch
FORCE_REFRESH=""
# true if $1 exists, is non-empty, and is younger than STALE_SECS (skipped when FORCE_REFRESH is set)
fresh_enough() {
  [ -n "$FORCE_REFRESH" ] && return 1
  local f="$1" mtime
  [ -s "$f" ] || return 1
  mtime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" || return 1
  (( $(date +%s) - mtime < STALE_SECS ))
}
declare -A URL_CACHE

# Find the PR url for one agent: first scrape recent pane text, then fall back to
# `gh pr list --head <branch>` using the pane's working directory.
find_pr() {
  local pane_id="$1" cwd="$2" url branch
  url="$("$HERDR" pane read "$pane_id" --source recent --lines 4000 2>/dev/null \
        | grep -oiE "$PR_URL_RE" | tail -1)"
  if [ -z "$url" ] && [ -n "$cwd" ] && [ -d "$cwd" ]; then
    branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)"
    # gh resolves the repo from $PWD — must run in the pane's cwd, not ours.
    # --state all: a session whose PR already merged/closed still gets its row
    # (shown as M/C) instead of silently hiding; open PRs win when both exist.
    [ -n "$branch" ] && url="$(cd "$cwd" && gh pr list --head "$branch" --state all --limit 10 --json url,state \
      --jq '(map(select(.state=="OPEN")) + .) | .[0].url // empty' 2>/dev/null)"
  fi
  printf '%s' "$url"
}

SCOPE="all"   # all | ws ('w' toggles); PR rows get numbers 1-9, others are just listed
MY_LOGIN="$(gh api user --jq .login 2>/dev/null)"   # fetched once; used to flag "does MY review still block this"

# fetch one PR's display fields into a cache file (used in parallel)
# TSV: number, title, ci, pr-state, merge, review, comment-count, author,
#      pending-human-reviewers, my-review-state, human-reviewer-detail,
#      approved-count, bot-reviewer-detail, pending-bots
# Bot accounts (login ending "[bot]") are split out everywhere: a bot can
# comment/request-changes but will never supply the human approval a repo's
# branch protection actually wants, so lumping it into "waiting on them" is
# misleading — it's tracked separately and never blocks the review verdict.
fetch_pr() {
  local url="$1" out="$2"
  gh pr view "$url" --json number,title,state,isDraft,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,comments,reviews,author,reviewRequests,latestReviews 2>/dev/null \
  | jq -r --arg login "$MY_LOGIN" '
            # ponytail: gh CLI flattens review authors to a bare login with no
            # type info, so bot detection is pattern-matching, not a real
            # "__typename==Bot" check (that needs a raw GraphQL call per PR).
            # Known offenders that do not follow the "[bot]" convention are
            # listed explicitly; upgrade to GraphQL author.__typename if more
            # show up.
            def is_bot: (. // "") | (endswith("[bot]") or endswith("-bot")
                         or . == "copilot-pull-request-reviewer");
            (.author.login) as $prauthor |
            # the PR author replying in their own thread is not third-party
            # review feedback and must not count toward "waiting on them"
            (.reviews // [] | map(select(.author.login != $prauthor))) as $revs |
            # a reviewer displayed state must match reviewDecision own logic:
            # GitHub keeps CHANGES_REQUESTED/APPROVED standing until that reviewer
            # submits another formal verdict; extra COMMENTED-only reviews (a
            # follow-up pass, inline replies) do not clear it. Taking the bare
            # last review here would show COMMENTED while reviewDecision still
            # says CHANGES_REQUESTED, exactly the mismatch we are fixing.
            def formal_state: (map(select(.state=="APPROVED" or .state=="CHANGES_REQUESTED"))) as $f
                               | if ($f|length) > 0 then $f[-1].state else .[-1].state end;
            ($revs | map(select(.author.login | is_bot | not))
                   | group_by(.author.login) | map({login: .[0].author.login, state: (formal_state)})) as $human |
            ($revs | map(select(.author.login | is_bot))
                   | group_by(.author.login) | map({login: .[0].author.login, state: (last.state)})) as $bots |
            [(.number // "?"), (.title // ""),
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
            # pending reviewers, humans only: users have .login, teams have .name/.slug
            ([.reviewRequests[]? | ((.login // .slug // .name // empty)) | select((.|is_bot) | not)] | join(",")),
            # my own latest review state (empty if I never reviewed, or login unknown)
            (if $login=="" then "" else ([.latestReviews[]? | select(.author.login==$login) | .state] | .[0] // "") end),
            ($human | map("\(.login):\(.state)") | join(",")),
            ($human | map(select(.state=="APPROVED")) | length),
            ($bots | map("\(.login):\(.state)") | join(",")),
            ([.reviewRequests[]? | ((.login // .slug // .name // empty)) | select(.|is_bot)] | join(","))
           ] | @tsv' | tr $'\t' $'\x1f' > "$out" 2>/dev/null
  # bash `read` treats tab as IFS-whitespace no matter how IFS is set, so
  # consecutive tabs (an empty middle field, e.g. myrev when you have not
  # reviewed) collapse and shift every field after it. @tsv still does the
  # jq-side escaping of embedded tabs/newlines within a field; only the
  # delimiter itself is swapped to a byte bash will not treat as whitespace.
}

# count open High/Critical security findings for one repo (owner/name), summed
# across Dependabot, code scanning, and secret scanning. Secret-scanning alerts
# carry no severity field (GitHub doesn't grade them) — any live leak counts,
# since a found secret is inherently critical.
# Each source is queried independently: a source this token can't see (missing
# security_events scope, GHAS not enabled, 403/404) just contributes 0 rather
# than voiding the whole count — only when ALL THREE are unreadable do we fall
# back to "?", since that likely means the token has no security_events scope
# at all (same convention as dep_scan's al/crit/high fields).
fetch_sec() {
  local repo="$1" out="$2" dep cs ss
  dep="$(gh api "repos/$repo/dependabot/alerts?state=open&per_page=100" \
    --jq '[.[].security_advisory.severity] | map(select(.=="critical" or .=="high")) | length' 2>/dev/null)"
  cs="$(gh api "repos/$repo/code-scanning/alerts?state=open&per_page=100" \
    --jq '[.[].rule.security_severity_level] | map(select(.=="critical" or .=="high")) | length' 2>/dev/null)"
  ss="$(gh api "repos/$repo/secret-scanning/alerts?state=open&per_page=100" \
    --jq 'length' 2>/dev/null)"
  [[ "$dep" =~ ^[0-9]+$ ]] || dep=""
  [[ "$cs"  =~ ^[0-9]+$ ]] || cs=""
  [[ "$ss"  =~ ^[0-9]+$ ]] || ss=""
  if [ -z "$dep$cs$ss" ]; then
    printf '?' > "$out"
  else
    printf '%s' "$(( ${dep:-0} + ${cs:-0} + ${ss:-0} ))" > "$out"
  fi
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

# number of comma-separated items in a possibly-empty CSV string
count_csv() { [ -z "$1" ] && { echo 0; return; }; local IFS=','; local -a a=($1); echo "${#a[@]}"; }

# symbol maps for the indicator columns
ci_sym()  { case "$1" in ok) echo "✓";; FAIL) echo "✗";; ...) echo "…";; *) echo "-";; esac; }
mrg_sym() { case "$1" in ok) echo "✓";; confl) echo "✗confl";; behind) echo "↓behind";; no) echo "✗";; *) echo "$1";; esac; }
rev_sym() { case "$1" in appr) echo "✓";; me) echo "←me";; them) echo "→them";; *) echo "-";; esac; }
sec_sym() { case "$1" in 0) echo "-";; *) echo "$1";; esac; }   # "$1" is a count, "?" (no scope), or 0
# one colored letter for PR lifecycle: D draft, R ready, M merged, C closed
st_sym()  { case "$1" in ready) echo "R";; draft) echo "D";; merged) echo "M";; closed) echo "C";; *) echo "?";; esac; }
rtm_sym() { case "$1" in yes) echo "✓";; no) echo "✗";; *) echo "-";; esac; }   # ready-to-merge verdict

# ANSI palette; colors wrap the already-padded field so escape codes (zero
# display width) never enter pad()'s byte math.
C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YEL=$'\033[33m' C_MAG=$'\033[35m'
C_CYN=$'\033[36m' C_DIM=$'\033[2m'  C_BLD=$'\033[1m'  C_RST=$'\033[0m'
ci_col()  { case "$1" in ok) printf %s "$C_GRN";; FAIL) printf %s "$C_RED";; ...) printf %s "$C_YEL";; esac; }
mrg_col() { case "$1" in ok) printf %s "$C_GRN";; confl|no) printf %s "$C_RED";; behind) printf %s "$C_YEL";; esac; }
st_col()  { case "$1" in ready) printf %s "$C_GRN";; draft) printf %s "$C_YEL";; merged) printf %s "$C_MAG";; closed) printf %s "$C_DIM";; esac; }
rev_col() { case "$1" in appr) printf %s "$C_GRN";; me) printf %s "$C_RED";; them) printf %s "$C_YEL";; esac; }
sec_col() { case "$1" in 0|'?') printf %s "$C_DIM";; *) printf %s "$C_RED";; esac; }   # any high/critical alert -> red
sts_col() { case "$1" in working) printf %s "$C_GRN";; blocked) printf %s "$C_RED";; idle|done) printf %s "$C_DIM";; esac; }
rtm_col() { case "$1" in yes) printf %s "$C_GRN";; no) printf %s "$C_RED";; *) printf %s "$C_DIM";; esac; }

render() {
  local idx=0 hidden=0 discarded=0 agents pane agent status cwd url num title state checks out=""
  # discarded PRs: locally hidden from the board only ('x' to discard, 'u' to
  # undiscard all) — never touches GitHub, just a "stop showing me this" list
  local discf="$STATE_DIR/discarded"
  local -A DISCARD=()
  if [ -f "$discf" ]; then
    while IFS= read -r url; do [ -n "$url" ] && DISCARD["$url"]=1; done < "$discf"
  fi
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

  # kick off the review-requested/authored/assigned searches now so they run
  # concurrently with the per-pane scrape below instead of serially after it —
  # these were the two biggest chunks of first-render latency. Skipped
  # entirely when the cached result is still fresh (STALE_SECS / 'r').
  local revreq_f="$cache/_revreq" mine_f="$cache/_mine"
  [ -f "$revreq_f" ] || : > "$revreq_f"
  [ -f "$mine_f" ] || : > "$mine_f"
  if [ "$SCOPE" = all ]; then
    if ! fresh_enough "$revreq_f"; then
      gh search prs --review-requested=@me --state=open --sort=updated --limit 20 --json url --jq '.[].url' -- -author:app/dependabot > "$revreq_f" 2>/dev/null &
    fi
    if [ -f "$STATE_DIR/show-authored" ] && ! fresh_enough "$mine_f"; then
      { gh search prs --author=@me --state=open --sort=updated --limit 20 --json url --jq '.[].url'
        gh search prs --assignee=@me --state=open --sort=updated --limit 20 --json url --jq '.[].url'; } > "$mine_f" 2>/dev/null &
    fi
  fi

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
  local -A WANT=() SEEN=()
  local n=0
  for ((i=1; i<=m; i++)); do
    pane="${A_PANE[$i]}"
    url="${URL_CACHE[$pane]:-}"
    if [ -z "$url" ]; then
      url="$(cat "$cache/url_${pane//:/_}" 2>/dev/null)"
      URL_CACHE[$pane]="${url:--}"
    fi
    if [ "$url" = "-" ] || [ -z "$url" ]; then hidden=$((hidden+1)); continue; fi
    if [ -n "${DISCARD[$url]:-}" ]; then discarded=$((discarded+1)); SEEN["$url"]=1; continue; fi
    n=$((n+1)); R_AGENT[$n]="${A_AGENT[$i]}"; R_STATUS[$n]="${A_STATUS[$i]}"; R_URL[$n]="$url"; R_CWD[$n]="${A_CWD[$i]}"; R_PANE[$n]="$pane"; R_KIND[$n]="sess"; WANT["$url"]=1
    SEEN["$url"]=1
  done

  local u2

  # pass 1c: PRs waiting for YOUR review (review requested from you, directly
  # or via a team) — shown right after the session rows, before your other
  # PRs. 'cr' conducts the review; 'fin' takes the PR over when the author is
  # away. Dependabot PRs are excluded — the 'd' sweep owns those.
  if [ "$SCOPE" = all ]; then
    while IFS= read -r u2; do
      [ -z "$u2" ] && continue
      [ -n "${SEEN[$u2]:-}" ] && continue
      SEEN["$u2"]=1
      if [ -n "${DISCARD[$u2]:-}" ]; then discarded=$((discarded+1)); continue; fi
      n=$((n+1)); R_AGENT[$n]="-"; R_STATUS[$n]="-"; R_URL[$n]="$u2"; R_CWD[$n]=""; R_PANE[$n]=""; R_KIND[$n]="rev"; WANT["$u2"]=1
    done < "$revreq_f"
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
      if [ -n "${DISCARD[$u2]:-}" ]; then discarded=$((discarded+1)); continue; fi
      n=$((n+1)); R_AGENT[$n]="-"; R_STATUS[$n]="-"; R_URL[$n]="$u2"; R_CWD[$n]=""; R_PANE[$n]=""; R_KIND[$n]="mine"; WANT["$u2"]=1
    done < "$mine_f"
  fi

  # pass 2: fetch PR states in parallel, deduped, skipping anything still fresh —
  # this is what made every render (not just the first) pay for N gh calls.
  local u
  for u in "${!WANT[@]}"; do
    fresh_enough "$cache/${u//[:\/]/_}" || fetch_pr "$u" "$cache/${u//[:\/]/_}" &
  done
  # one Dependabot-alert lookup per distinct repo on the board, not per PR
  local -A WANT_REPO=()
  local repo
  for u in "${!WANT[@]}"; do
    repo="${u#https://github.com/}"; repo="${repo%%/pull/*}"
    WANT_REPO["$repo"]=1
  done
  for repo in "${!WANT_REPO[@]}"; do
    fresh_enough "$cache/sec_${repo//\//_}" || fetch_sec "$repo" "$cache/sec_${repo//\//_}" &
  done
  wait
  FORCE_REFRESH=""

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
    local st mrg rev cmts author reviewers myrev revdetail apprcnt botdetail botpending rname revd revcol repo secn rtm
    IFS=$'\x1f' read -r num title checks st mrg rev cmts author reviewers myrev revdetail apprcnt botdetail botpending < "$cache/${url//[:\/]/_}" 2>/dev/null || true
    rname="${url#https://github.com/}"; repo="${rname%%/pull/*}"; rname="${rname#*/}"; rname="${rname%%/pull/*}"
    secn="$(cat "$cache/sec_${repo//\//_}" 2>/dev/null)"
    [[ "$secn" =~ ^[0-9]+$ ]] || secn='?'
    # REVIEW shows WHO/WHAT it waits on. Single pending human reviewer -> their
    # name; multiple humans involved (pending + already-reviewed) -> N/M
    # approval count so "1 approved, 1 still out" is visible at a glance.
    # Bot reviewers/requests never factor in here (filtered out in fetch_pr).
    revd="$(rev_sym "${rev:--}")"
    revcol="$rev"
    if [ "$rev" = them ]; then
      local pend_n hum_n tot_n
      pend_n="$(count_csv "$reviewers")"
      hum_n="$(count_csv "$revdetail")"
      tot_n=$((pend_n + hum_n))
      if [ "$tot_n" -gt 1 ]; then
        revd="→${apprcnt:-0}/${tot_n}"
      elif [ "$pend_n" -ge 1 ]; then
        revd="→${reviewers%%,*}"
      fi
    fi
    # reviewDecision=CHANGES_REQUESTED sticks until that reviewer submits a
    # fresh APPROVE/CHANGES_REQUESTED — GitHub doesn't clear it on a re-request
    # or on later COMMENTED-only reviews. But once you've re-requested review
    # from the very person who's blocking it, the ball is on them, not you —
    # surface that instead of leaving a stale "←me".
    if [ "$rev" = me ] && [ -n "$revdetail" ] && [ -n "$reviewers" ]; then
      local entry rlogin rstate
      IFS=',' read -ra _rd <<<"$revdetail"
      for entry in "${_rd[@]}"; do
        rlogin="${entry%%:*}"; rstate="${entry#*:}"
        [ "$rstate" = CHANGES_REQUESTED ] || continue
        case ",$reviewers," in
          *",$rlogin,"*) revd="→${rlogin}"; revcol=them; break ;;
        esac
      done
    fi
    # "waiting for your review" rows: overall reviewDecision (appr/them) can't tell
    # you whether YOUR review specifically still blocks it — repos with multiple
    # required approvers can show REVIEW_REQUIRED even after you've approved.
    if [ "${R_KIND[$idx]:-}" = rev ]; then
      case "$myrev" in
        APPROVED)
          if [ "$rev" = appr ]; then revd="✓done"; revcol=appr
          else revd="✓+more"; revcol=them; fi ;;   # you approved; other required reviewers still pending
        CHANGES_REQUESTED) revd="✗mine"; revcol=me ;;   # your own changes-requested still stands
        *) revd="→need"; revcol=them ;;                 # you haven't reviewed yet
      esac
    fi
    # RTM: the single "can I actually hit merge right now" verdict — mergeable,
    # checks green (or none configured), not blocked on outstanding review, and
    # published (not a draft). Merged/closed/draft PRs just show "-" (see ST).
    rtm="-"
    if [ "$st" = ready ]; then
      if [ "$mrg" = ok ] && { [ "${checks:--}" = ok ] || [ "${checks:--}" = - ]; } && { [ "$rev" = appr ] || [ "$rev" = "-" ]; }; then
        rtm=yes
      else
        rtm=no
      fi
    fi
    printf -v line '  %-16.16s %s%-9s%s %3s  #%-6s %-14.14s %s%s%s %s%-2s%s %s%s%s %s%s%s %s%s%s %s%s%s %-12.12s %3s  %.32s\n' \
      "${R_AGENT[$idx]}" "$(sts_col "${R_STATUS[$idx]}")" "${R_STATUS[$idx]}" "$C_RST" "$idx" "${num:-?}" "$rname" \
      "$(ci_col "${checks:--}")"  "$(pad "$(ci_sym "${checks:--}")" 3)"  "$C_RST" \
      "$(st_col "${st:-?}")"      "$(st_sym "${st:-?}")"                 "$C_RST" \
      "$(mrg_col "${mrg:-?}")"    "$(pad "$(mrg_sym "${mrg:-?}")" 8)"    "$C_RST" \
      "$(rev_col "${revcol:--}")" "$(pad "${revd:0:14}" 14)"             "$C_RST" \
      "$(rtm_col "$rtm")"         "$(pad "$(rtm_sym "$rtm")" 3)"         "$C_RST" \
      "$(sec_col "$secn")"        "$(pad "$(sec_sym "$secn")" 3)"        "$C_RST" \
      "${author:--}" "${cmts:-0}" "${title:-}"
    out+="$line"
  done
  [ "$n" -eq 0 ] && out+="  (no PRs found)"$'\n'
  [ "$hidden" -gt 0 ] && out+=$'\n'"  ${C_DIM}$n PR row(s) shown · $hidden session(s) have no PR and are hidden (r rediscovers)${C_RST}"$'\n'
  [ "$discarded" -gt 0 ] && out+="  ${C_DIM}$discarded PR(s) discarded (u undiscards all)${C_RST}"$'\n'

  [ -n "${QUIET:-}" ] && return   # headless --triage: collect rows, draw nothing
  clear
  printf '%s  PR Tracker%s [%s]  %s(number+Enter open · : cmdline "1,2c,3m" · t triage · d deps · ? help · r refresh · c checkout · m merge · p plan · x discard · v review · u undiscard · w scope · q quit)%s\n' \
    "$C_BLD" "$C_RST" \
    "$( [ "$SCOPE" = ws ] && echo "workspace ${HERDR_WORKSPACE_ID:-?}" || echo "all sessions" )" \
    "$C_DIM" "$C_RST"
  # surface the loaded custom verbs so ":1pr,2ar" possibilities are discoverable
  if [ ${#CMDS[@]} -gt 0 ]; then
    printf '  %sverbs: o c m p cc co cccocr + %s  (? shows templates)%s\n' "$C_DIM" \
      "$(printf '%s\n' "${!CMDS[@]}" | sort | tr '\n' ' ')" "$C_RST"
  else
    printf '  %sno custom verbs — add them to %s (? for help)%s\n' "$C_DIM" "$CMDS_FILE" "$C_RST"
  fi
  printf '%s  %-16s %-9s %3s  %-7s %-14s %-3s %-2s %-8s %-14s %-3s %-3s %-12s %3s  %s%s\n' "$C_CYN$C_BLD" "AGENT" "STATUS" "N" "PR" "REPO" "CI" "ST" "MERGE" "REVIEW" "RTM" "SEC" "AUTHOR" "C" "TITLE" "$C_RST"
  printf '  %s%s%s\n' "$C_DIM" "---------------------------------------------------------------------------------------------------------------------" "$C_RST"
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
    review)   show_review_detail "$n" ;;   # who's approved/pending/commented, bots called out separately
    discard)  # local-only "stop showing me this PR" — never touches GitHub; 'u' undoes
      printf '%s\n' "$url" >> "$STATE_DIR/discarded"
      sort -u "$STATE_DIR/discarded" -o "$STATE_DIR/discarded" ;;
    cmd:*)    # user-defined verb from commands.conf
      local tmpl="${CMDS[${verb#cmd:}]:-}"
      [ -z "$tmpl" ] && return
      local repo="${url#https://github.com/}"; repo="${repo%%/pull/*}"
      tmpl="${tmpl//\{url\}/$url}"
      tmpl="${tmpl//\{num\}/${url##*/}}"
      tmpl="${tmpl//\{cwd\}/$cwd}"
      tmpl="${tmpl//\{repo\}/$repo}"
      if [[ "$tmpl" == @* ]]; then
        # '@' templates are typed INTO the PR's own coding-agent session (visible in
        # its pane, uses its context) instead of running here.
        local pane="${ROW_PANE[$n]:-}" sts="${ROW_STATUS[$n]:-}"
        [ -z "$pane" ] && { printf '  row %s: no session — use ":%sco%s" (Codex), ":%scc%s" (Claude Code), or ":%scccocr" (both reviewers)\n' "$n" "$n" "${verb#cmd:}" "$n" "${verb#cmd:}" "$n"; return; }
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
    spawn-codex:*) spawn_coc "$n" "${verb#spawn-codex:}" ;;
    spawn-both-review) spawn_review_pair "$n" ;;
  esac
}

# 'v': per-row breakdown of who's approved/pending/commented, so "them" with
# multiple reviewers stops being a mystery. Bots are listed last and labeled
# non-blocking — they can comment/request-changes but never satisfy a
# required-approval branch rule.
show_review_detail() {
  local n="$1" url="${ROW_URL[$n]:-}" cache="$STATE_DIR/prcache"
  [ -z "$url" ] && { printf '  row %s: no PR\n' "$n"; return; }
  local num title checks st mrg rev cmts author reviewers myrev revdetail apprcnt botdetail botpending
  IFS=$'\x1f' read -r num title checks st mrg rev cmts author reviewers myrev revdetail apprcnt botdetail botpending \
    < "$cache/${url//[:\/]/_}" 2>/dev/null
  printf '\n%s  review detail — #%s %s%s\n' "$C_BLD" "${num:-?}" "${title:-}" "$C_RST"
  local any=0 entry login state col
  if [ -n "$revdetail" ]; then
    IFS=',' read -ra _e <<<"$revdetail"
    for entry in "${_e[@]}"; do
      login="${entry%%:*}"; state="${entry#*:}"; any=1
      case "$state" in APPROVED) col=appr;; CHANGES_REQUESTED) col=me;; *) col=-;; esac
      printf '    %s%-20s%s %s\n' "$(rev_col "$col")" "$login" "$C_RST" "$state"
    done
  fi
  if [ -n "$reviewers" ]; then
    IFS=',' read -ra _p <<<"$reviewers"
    for login in "${_p[@]}"; do
      any=1
      printf '    %s%-20s%s %s\n' "$C_YEL" "$login" "$C_RST" "PENDING"
    done
  fi
  if [ -n "$botdetail" ]; then
    IFS=',' read -ra _b <<<"$botdetail"
    for entry in "${_b[@]}"; do
      login="${entry%%:*}"; state="${entry#*:}"; any=1
      printf '    %s%-20s%s %s (bot — informational, does not block)%s\n' "$C_DIM" "$login" "$state" "$C_RST"
    done
  fi
  if [ -n "$botpending" ]; then
    IFS=',' read -ra _bp <<<"$botpending"
    for login in "${_bp[@]}"; do
      any=1
      printf '    %s%-20s%s PENDING (bot — will never approve, does not block)%s\n' "$C_DIM" "$login" "$C_RST"
    done
  fi
  [ "$any" = 0 ] && printf '    (no reviewers requested or submitted)\n'
  printf '  %s%s human approval(s) · reviewDecision=%s%s\n' "$C_DIM" "${apprcnt:-0}" "${rev:-?}" "$C_RST"
  printf '\n  press any key to return '
  IFS= read -rsn1 -t 60 _ || true
}

# repos.conf: "owner/name = /path/to/local/clone" lines. When a PR's repo is
# mapped, cc reuses that clone via `git worktree add` (instant, offline, your
# working copy untouched) instead of a fresh network clone.
REPOS_FILE="$STATE_DIR/repos.conf"
local_src() {
  [ -f "$REPOS_FILE" ] || return 0
  local repo path
  while IFS='=' read -r repo path; do
    repo="${repo//[[:space:]]/}"
    path="${path#"${path%%[![:space:]]*}"}"; path="${path%"${path##*[![:space:]]}"}"
    [ "$repo" = "$1" ] || continue
    printf '%s' "${path/#\~/$HOME}"; return
  done < <(grep -v '^[[:space:]]*#' "$REPOS_FILE" 2>/dev/null)
}
[ -f "$REPOS_FILE" ] || cat > "$REPOS_FILE" <<'EOF'
# herdr-pr-tracker repo map: "owner/name = /path/to/local/clone" per line.
# 'cc' creates the per-PR checkout as a git worktree of the mapped clone
# (fast, no network clone). Unmapped repos are cloned per PR as before.
# keboola/ui = ~/gt/kbc-ui
EOF

# 'cc'/'co' verbs: attach a fresh Claude Code or Codex session to a PR in its own herdr workspace.
# Checks out the PR into a per-PR dir (worktree of your mapped clone from
# repos.conf, else a full clone; reused on later calls), spawns workspace +
# the coding agent, and optionally types a follow-up verb's template into the new
# session (":10ccar").
spawn_agent_session() {
  local n="$1" follow="$2" agent="$3" cli="$4" checkout_tag="$5" kind="$6"
  shift 6
  local -a args=("$@")
  local url="${ROW_URL[$n]:-}" num repo dir out wsid pane root start_help start_name prompt_help process_info close_root=1
  [ -z "$url" ] && return
  num="${url##*/}"
  repo="${url#https://github.com/}"; repo="${repo%%/pull/*}"
  dir="$STATE_DIR/checkouts/${repo//\//_}-pr$num${checkout_tag:+-$checkout_tag}"
  # worktrees have a .git *file*, clones a .git dir — -e covers both
  if [ ! -e "$dir/.git" ]; then
    local src; src="$(local_src "$repo")"
    if [ -z "$src" ] || [ ! -e "$src/.git" ]; then
      # no mapped clone: keep ONE shared clone per repo under checkouts/ and
      # hang every per-PR checkout off it as a worktree (clone paid once)
      src="$STATE_DIR/checkouts/${repo//\//_}"
      if [ ! -e "$src/.git" ]; then
        printf '  row %s: cloning %s … ' "$n" "$repo"
        gh repo clone "$repo" "$src" -- --quiet >/dev/null 2>&1 || { printf 'clone failed\n'; return; }
        printf 'ok\n'
      fi
    fi
    printf '  row %s: worktree of %s … ' "$n" "$src"
    # ponytail: detached worktree; gh pr checkout below picks the PR branch.
    # Fails if the PR branch is already checked out in the source clone —
    # switch it away there and retry.
    git -C "$src" fetch --quiet >/dev/null 2>&1
    git -C "$src" worktree add --detach "$dir" >/dev/null 2>&1 || { printf 'worktree add failed\n'; return; }
    printf 'ok\n'
  fi
  local err
  if ! err="$(cd "$dir" && gh pr checkout "$url" 2>&1)"; then
    # reused worktree + force-pushed PR branch = "Not possible to fast-forward".
    # ponytail: reset to the PR head unless tracked files are dirty; old commits stay in the reflog
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
      printf '  row %s: gh pr checkout failed, %s has uncommitted changes: %s\n' "$n" "$dir" "$(tail -1 <<<"$err")"; return
    fi
    # branch already checked out in a sibling worktree (e.g. an older PR on the same branch): detach at the PR head instead
    local flag=--force; [[ "$err" == *"already checked out"* || "$err" == *"already used by worktree"* ]] && flag=--detach
    err="$(cd "$dir" && gh pr checkout "$flag" "$url" 2>&1)" || { printf '  row %s: gh pr checkout failed in %s: %s\n' "$n" "$dir" "$(tail -1 <<<"$err")"; return; }
  fi
  out="$("$HERDR" workspace create --cwd "$dir" --label "PR #$num${checkout_tag:+ $checkout_tag}" --no-focus 2>/dev/null)"
  wsid="$(jq -r '.result.workspace.workspace_id // empty' <<<"$out" 2>/dev/null)"
  root="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out" 2>/dev/null)"
  [ -z "$wsid" ] && { printf '  row %s: workspace create failed\n' "$n"; return; }
  # Herdr 0.9+ starts an agent in the workspace's existing root pane; 0.7 used
  # --workspace/--cwd and created a second pane. Keep both CLI generations
  # working because plugin users may not update Herdr alongside the plugin.
  # Workspace IDs can contain uppercase letters; Herdr agent names cannot.
  start_name="${agent}-${wsid,,}"
  start_name="${start_name//[^a-z0-9_-]/-}"
  start_help="$("$HERDR" agent start --help 2>&1)"
  if [[ "$start_help" == *"--pane"* && "$start_help" == *"--kind"* ]]; then
    # workspace create can return before the root shell reaches its prompt.
    # agent start rejects panes whose shell is not yet the foreground process.
    local try shell_ready=0
    for try in {1..60}; do
      process_info="$("$HERDR" pane process-info --pane "$root" 2>/dev/null)"
      if jq -e '.result.process_info as $p | ($p.shell_pid != null) and any($p.foreground_processes[]?; .pid == $p.shell_pid)' <<<"$process_info" >/dev/null 2>&1; then
        shell_ready=1
        break
      fi
      sleep 0.25
    done
    if [ "$shell_ready" = 0 ]; then
      printf '  row %s: workspace %s root pane never reached a shell prompt; workspace retained for inspection\n' "$n" "$wsid"
      return
    fi
    # ponytail: shell is foreground but zle may still be initializing; the first typed char got dropped ("odex"). Fixed 1s settle, poll for a prompt if it still races.
    sleep 1
    # --kind already selects the executable; only pass agent-specific args.
    out="$("$HERDR" agent start "$start_name" --kind "$kind" --pane "$root" -- "${args[@]}" 2>&1)"
    close_root=0
  elif [[ "$start_help" == *"--workspace"* ]]; then
    # Preserve stderr: it contains startup failures such as a missing CLI.
    out="$("$HERDR" agent start "$start_name" --workspace "$wsid" --cwd "$dir" --focus -- "$cli" "${args[@]}" 2>&1)"
  else
    printf '  row %s: unsupported Herdr agent start interface\n' "$n"
    "$HERDR" workspace close "$wsid" >/dev/null 2>&1
    return
  fi
  pane="$(jq -r '.result.agent.pane_id // empty' <<<"$out" 2>/dev/null)"
  if [ -z "$pane" ]; then
    local start_message
    start_message="$(jq -r '.error.message // .message // empty' <<<"$out" 2>/dev/null)"
    [ -n "$start_message" ] || start_message="${out:-unknown error}"
    printf '  row %s: agent start failed: %s (workspace %s retained for inspection)\n' "$n" "${start_message//$'\n'/; }" "$wsid"
    return
  fi
  # Older Herdr created a second pane; close its initial shell. Newer Herdr
  # replaces the root shell directly, so that pane is the agent pane.
  [ "$close_root" = 1 ] && [ -n "$root" ] && "$HERDR" pane close "$root" >/dev/null 2>&1
  printf '  row %s: %s started in workspace %s (%s)\n' "$n" "$cli" "$wsid" "$dir"
  [ -z "$follow" ] && return
  local tmpl="${CMDS[$follow]:-}"
  tmpl="${tmpl//\{url\}/$url}"
  tmpl="${tmpl//\{num\}/$num}"
  tmpl="${tmpl//\{cwd\}/$dir}"
  tmpl="${tmpl//\{repo\}/$repo}"
  if [[ "$tmpl" == @* ]]; then
    [ -z "$pane" ] && { printf '  row %s: no pane id — run "%s" manually\n' "$n" "$follow"; return; }
    # Let the coding agent boot before sending the prompt. Submit exactly once:
    # pane output is not a reliable acknowledgement, and retrying based on a
    # missing echo can submit the same prompt twice.
    "$HERDR" agent wait "$pane" --status idle --timeout 90000 >/dev/null 2>&1
    local payload="${tmpl#@}" send_ok=0
    sleep 3
    prompt_help="$("$HERDR" agent prompt --help 2>&1)"
    if [[ "$prompt_help" == *"Usage: herdr agent prompt"* ]]; then
      "$HERDR" agent prompt "$pane" "$payload" >/dev/null 2>&1 && send_ok=1
    else
      "$HERDR" pane run "$pane" "$payload" >/dev/null 2>&1 && send_ok=1
    fi
    sleep 1
    if [ "$send_ok" = 1 ]; then
      printf '  row %s: sent %s to the new session\n' "$n" "$follow"
    else
      printf '  row %s: could not submit %s — inspect the new session before retrying ":%s%s"\n' "$n" "$follow" "$n" "$follow"
    fi
  else
    (cd "$dir" && bash -c "$tmpl")
  fi
}

spawn_cc() {
  local -a args=()
  [ -n "${HERDR_CC_CLAUDE_ARGS:-}" ] && read -r -a args <<<"$HERDR_CC_CLAUDE_ARGS"
  spawn_agent_session "$1" "$2" claude claude "" claude "${args[@]}"
}

spawn_coc() {
  local -a args=()
  [ -n "${HERDR_COC_CODEX_ARGS:-}" ] && read -r -a args <<<"$HERDR_COC_CODEX_ARGS"
  if [ "${2:-}" = cr ]; then
    load_review_models
    args+=(--model "$REVIEW_CODEX_MODEL" --config "model_reasoning_effort=$REVIEW_CODEX_EFFORT"
      --sandbox read-only --ask-for-approval never)
  fi
  spawn_agent_session "$1" "$2" codex codex "" codex "${args[@]}"
}

spawn_co() {
  spawn_coc "$1" "$2"
}

load_review_models() {
  local models_file="$STATE_DIR/review-models.conf" key value
  [ -f "$models_file" ] || cat > "$models_file" <<'EOF'
# Model IDs or aliases supported by your installed agent CLIs.
# Edit these per machine; the interactive agents can also change models later.
# Codex examples: gpt-6.1-sol, gpt-5.6. Claude aliases: sonnet, opus, haiku.
CODEX_MODEL=gpt-6.1-sol
CODEX_REASONING_EFFORT=medium
CLAUDE_MODEL=sonnet
EOF
  REVIEW_CODEX_MODEL="gpt-6.1-sol"
  REVIEW_CODEX_EFFORT="medium"
  REVIEW_CLAUDE_MODEL="sonnet"
  while IFS='=' read -r key value; do
    key="${key//[[:space:]]/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      CODEX_MODEL) [ -n "$value" ] && REVIEW_CODEX_MODEL="$value" ;;
      CODEX_REASONING_EFFORT) [ -n "$value" ] && REVIEW_CODEX_EFFORT="$value" ;;
      CLAUDE_MODEL) [ -n "$value" ] && REVIEW_CLAUDE_MODEL="$value" ;;
    esac
  done < <(grep -v '^[[:space:]]*#' "$models_file" 2>/dev/null)
}

spawn_review_pair() {
  local n="$1"
  local url="${ROW_URL[$n]:-}" repo num codex_review_dir claude_review_dir common_git_dir claude_sandbox_settings
  local cr_tmpl="${CMDS[cr]:-}"
  if [[ "$cr_tmpl" != @* ]]; then
    printf '  row %s: combined review needs cr to be an @ prompt in %s\n' "$n" "$CMDS_FILE"
    return
  fi
  [ -z "$url" ] && return
  num="${url##*/}"
  repo="${url#https://github.com/}"; repo="${repo%%/pull/*}"
  codex_review_dir="$STATE_DIR/checkouts/${repo//\//_}-pr$num-review-codex"
  claude_review_dir="$STATE_DIR/checkouts/${repo//\//_}-pr$num-review-claude"
  load_review_models
  printf '  row %s: starting read-only Codex (%s, %s effort) and Claude Code (%s) reviews\n' "$n" "$REVIEW_CODEX_MODEL" "$REVIEW_CODEX_EFFORT" "$REVIEW_CLAUDE_MODEL"
  spawn_agent_session "$n" cr codex codex review-codex codex \
    --model "$REVIEW_CODEX_MODEL" --config "model_reasoning_effort=$REVIEW_CODEX_EFFORT" \
    --sandbox read-only --ask-for-approval never
  common_git_dir="$(git -C "$codex_review_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  if [ -z "$common_git_dir" ]; then
    printf '  row %s: cannot locate the shared Git directory; Claude review was not started\n' "$n"
    return
  fi
  claude_sandbox_settings="$(jq -cn --arg dir "$claude_review_dir" --arg gitdir "$common_git_dir" \
    '{sandbox:{enabled:true,allowUnsandboxedCommands:false,failIfUnavailable:true,filesystem:{denyWrite:[$dir,$gitdir]}}}')"
  spawn_agent_session "$n" cr claude claude review-claude claude \
    --model "$REVIEW_CLAUDE_MODEL" --permission-mode plan --restricted \
    --tools 'Bash,Read,Glob,Grep' \
    --settings "$claude_sandbox_settings" \
    --disallowedTools Edit Write NotebookEdit 'mcp__*' \
    'Bash(git add *)' 'Bash(git checkout *)' 'Bash(git branch *)' \
    'Bash(git cherry-pick *)' 'Bash(git clean *)' 'Bash(git commit *)' \
    'Bash(git fetch *)' 'Bash(git push *)' 'Bash(git rebase *)' \
    'Bash(git remote *)' 'Bash(git reset *)' 'Bash(git tag *)' \
    'Bash(git worktree *)' 'Bash(gh *)'
}

# user-defined verbs: "<verb> = <command template>" lines in commands.conf.
# Templates get {url} {num} {cwd} substituted and run in the session's cwd.
CMDS_FILE="$STATE_DIR/commands.conf"
declare -A CMDS
# Built-in default verbs — generic, no personal skills required. Any line in
# commands.conf with the same verb name overrides the default.
declare -A DEFAULT_CMDS=(
  [pr]='@Review PR {url}: use only the checked-out branch and local git data; do not run gh, access the network, or post to GitHub. Review only the changed code (the diff), rank findings by severity with exact file:line, be concrete about fixes, and present a findings table.'
  [ar]='@Address the review comments on PR {url}: read all unresolved review and bot comments, implement the fixes, push, and reply to each comment.'
  [r]='@Rebase PR {url} on its base branch, resolve any conflicts, and push with --force-with-lease.'
  [rs]='@CI on PR {url} is failing: analyze the failing checks, fix them, push, and repeat until every check is green.'
  [s]='@/simplify'
  [pub]='gh pr ready {url}'
  [cr]='@Conduct a read-only code review of PR {url} as the requested reviewer: use only the checked-out branch and local git data. Do not run gh, access the network, run tests, change files, write a plan/scratch file, submit the review to GitHub, or depend on skills/subagents. If a requested skill or agent tool is unavailable, perform its review lens inline and label it accordingly. Study the full diff and existing tests, assess correctness, test coverage, and maintainability, rank findings by severity with exact file:line, and present a findings table.'
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
# Prefix the template with '@' to type it into the PR's own coding-agent session
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
  load_review_models
  printf '\n%s  keys%s      <n>+Enter open in browser · c/m/p/x/v then <n>+Enter checkout/merge/plan/discard/review-detail · : batch · t triage · d dependabot/security sweep · r refresh · u undiscard all · w scope · q quit\n' "$C_BLD" "$C_RST"
  printf '%s  batch%s     :<row><verb>[,<row><verb>…]  e.g. ":1pr,2m,3r,4ar" — no verb = open, so ":1,2" opens two tabs\n' "$C_BLD" "$C_RST"
  printf '%s  built-in%s  o open · c checkout · m merge · p plan · x discard · v review detail · cc Claude Code · co Codex · cccocr read-only review in both (separate worktrees)\n' "$C_BLD" "$C_RST"
  printf '%s  review models%s Codex=%s (%s effort) · Claude Code=%s (edit %s/review-models.conf)\n' "$C_BLD" "$C_RST" "$REVIEW_CODEX_MODEL" "$REVIEW_CODEX_EFFORT" "$REVIEW_CLAUDE_MODEL" "$STATE_DIR"
  printf '%s  columns%s   REVIEW → single pending reviewer by name, or approved/total when several are involved · RTM = ready to merge right now (mergeable, checks green, not blocked on review)\n' "$C_BLD" "$C_RST"
  printf '%s  verbs%s     '"'"'@'"'"' = typed into the PR'"'"'s coding-agent session · override defaults in %s:\n' "$C_BLD" "$C_RST" "$CMDS_FILE"
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
    x)    echo discard ;;   # locally hide this PR from the board; 'u' undiscards all
    v)    echo review ;;    # who's approved/pending/commented on this PR (bots called out)
    cccocr|coccr) echo spawn-both-review ;;
    coc)  echo spawn-codex: ;; # backwards-compatible Codex alias
    co*)  # spawn Codex; optional follow-up verb ("cocr" = Codex + code review)
      local f="${1#co}"
      if [ -z "$f" ] || [ -n "${CMDS[$f]:-}" ]; then echo "spawn-codex:$f"; else return 1; fi ;;
    cc*)  # spawn Claude Code in a fresh workspace; optional follow-up verb ("ccar")
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
    IFS=$'\x1f' read -r num title ci st mrg rev cmts author reviewers < "$cache/${url//[:\/]/_}" 2>/dev/null || continue
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

# reads the rest of an input line one keystroke at a time and returns it on
# stdout. herdr forwards raw keystrokes to this script's stdin rather than a
# real tty, so bash's line editing never sees them — a plain `read -r line`
# stores a backspace byte as-is instead of deleting the previous character,
# which is why one character was always left un-erasable. Backspacing past
# the first character cancels (return 1) instead of waiting for more input,
# so an emptied line drops straight back to the default board view.
# Usage: if read_editable "$seed"; then rest="$READLINE_RESULT"; else <cancelled>; fi
# Sets READLINE_RESULT rather than printing it — the per-keystroke echoes
# below must reach the terminal directly, so the result can't also go
# through stdout or a `$(...)` capture would swallow the echoes too.
READLINE_RESULT=""
read_editable() {
  local buf="$1" ch
  while IFS= read -rsn1 -t 30 ch; do
    case "$ch" in
      '') break ;;                     # Enter
      $'\177'|$'\b')                   # backspace: DEL or BS
        [ -z "$buf" ] && return 1
        buf="${buf%?}"
        printf '\b \b'
        [ -z "$buf" ] && return 1      # erased back to empty: cancel
        ;;
      *) buf+="$ch"; printf '%s' "$ch" ;;
    esac
  done
  READLINE_RESULT="$buf"
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
while :; do
  render
  # Inner key loop: verb/digit keys don't pay for a re-render; only timeout,
  # 'r', 'w', or a completed action falls through to render again.
  # herdr forwards keystrokes to the pane's stdin, not /dev/tty — read fd0.
  while IFS= read -rsn1 -t 10 key; do
    case "$key" in
      q) clear; exit 0 ;;
      r) URL_CACHE=(); FORCE_REFRESH=1; load_cmds; break ;;
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
        break ;;
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
        break ;;
      w) [ "$SCOPE" = ws ] && SCOPE="all" || SCOPE="ws"; break ;;
      u) : > "$STATE_DIR/discarded"; break ;;   # undiscard all
      '?') show_help; break ;;   # NB: quoted — bare ? is a glob matching any key
      c) PENDING_VERB="checkout"; printf '\r  [checkout] type row number + Enter … ' ;;
      m) PENDING_VERB="merge";    printf '\r  [merge] type row number + Enter … '    ;;
      p) PENDING_VERB="plan";     printf '\r  [plan] type row number + Enter … '     ;;
      x) PENDING_VERB="discard";  printf '\r  [discard] type row number + Enter … '  ;;
      v) PENDING_VERB="review";   printf '\r  [review] type row number + Enter … '   ;;
      :)  # explicit command line: "1,2c,3m" + Enter runs each token in order
        printf '\r  cmd> '
        if read_editable ""; then
          cmdline="$READLINE_RESULT"
          printf '\n'
          [ -n "$cmdline" ] && run_batch "$cmdline"
          printf '  (any key to refresh) '
          IFS= read -rsn1 -t 30 _ || true
        else
          printf '\n'   # backspaced to empty: cancelled, fall through to the board
        fi
        PENDING_VERB="open"
        break ;;
      [0-9])  # digit starts a batch line directly — no ':' needed for "1,2c,3m"
        printf '\r  %s%s' "$( [ "$PENDING_VERB" != open ] && echo "[$PENDING_VERB] " )" "$key"
        if read_editable "$key"; then
          rest="$READLINE_RESULT"
          printf '\n'
          if [ "$PENDING_VERB" != open ] && [[ "$rest" =~ ^[0-9]+$ ]]; then
            action_for "$rest" "$PENDING_VERB"   # c/m/p mode: plain row number applies that verb
          else
            run_batch "$rest"
          fi
          printf '  (any key to refresh) '
          IFS= read -rsn1 -t 30 _ || true
        else
          printf '\n'   # backspaced to empty: cancelled, fall through to the board
        fi
        PENDING_VERB="open"
        break ;;
    esac
  done
done
