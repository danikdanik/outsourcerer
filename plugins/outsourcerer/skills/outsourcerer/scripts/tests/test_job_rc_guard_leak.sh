#!/usr/bin/env bash
# test_job_rc_guard_leak.sh — a supervised job's exit code must be the delegate's, and a devin
# non-interactive reject must read as permission-blocked, not failed or done?.
#
# The recorded failure (fixtures/devin-rc7): two devin bg jobs ended status=failed, exit=7,
# reason=exit-nonzero:rc=7. Devin itself exited 0 in both. The 7 came from the blind-turn guard,
# which ran at the end of the job's OWN child process (run_job re-enters the script as `<verb> ...`)
# and returned 7 because unrelated fleet state needed attention. One job had a complete review as
# its deliverable; the other had landed its edits and then been refused a verification command.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../outsourcerer.sh"; export SRC
FIX="$HERE/fixtures/devin-rc7"
[ -f "$SRC" ] || { echo "FAIL: cannot find $SRC"; exit 1; }
bash -n "$SRC" || { echo "FAIL: bash -n failed"; exit 1; }

FIXTURE="$(mktemp -d "$PWD/.test-rc-guard.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
export OSRC_HOME="$FIXTURE/home"
mkdir -p "$OSRC_HOME"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

set --; . "$SRC" >/dev/null 2>&1

# Fill the fixture's placeholder with the real warning at runtime (see fixtures/devin-rc7/README.md).
mkdir -p "$FIXTURE/fix"
cp "$FIX/readonly-review.delegate.txt" "$FIXTURE/fix/"
sed "s|@@DEVIN_REJECT@@|$(_noninteractive_reject_needle)|" "$FIX/edit-reject.delegate.txt" > "$FIXTURE/fix/edit-reject.delegate.txt"
grep -qF "$(_noninteractive_reject_needle)" "$FIXTURE/fix/edit-reject.delegate.txt" || { echo "FAIL: fixture placeholder not filled"; exit 1; }
FIX="$FIXTURE/fix"

# A fresh fleet snapshot with one delegate that needs attention, so the guard WILL refuse wherever
# it runs. This is the state the recorded jobs launched into.
blocked='{"owner":"managed","job_id":"other-job","session_id":null,"state":"unresponsive?","state_label":"Maybe stuck","waiting_for":null,"display_name":"unrelated","cwd":"/repo"}'
( umask 077; jq -cn --argjson it "$blocked" '{schema_version:"1",generation:"g",captured_at:(now|todateiso8601),items:[$it]}' > "$OSRC_FLEET_SNAPSHOT" )

# The job's child, as run_job launches it: this script re-entered as `run ...`, with the dispatch
# stubbed to replay a recorded delegate transcript and exit with devin's real code.
child() { # <transcript> <delegate-rc> [fd: 1=stdout (default), 2=stderr like devin's warning]
  OSRC_HEARTBEAT_DISABLED=1 OUTSOURCERER_DEPTH=0 bash -c '
    S="$1"; T="$2"; R="$3"; FD="$4"; set --; . "$S" >/dev/null 2>&1
    route_delegate() { if [ "$FD" = 2 ]; then cat "$T" >&2; else cat "$T"; fi; return "$R"; }
    main run "x"
  ' _ "$SRC" "$1" "$2" "${3:-1}"
}
newjob() { # <name> [cwd] [lane]
  local jd="$OSRC_JOBS/$1"; mkdir -p -m 700 "$jd"
  jq -cn --arg id "$1" --arg cwd "${2:-}" --arg lane "${3:-dv}" '{id:$id,provider:"devin",verb:"run",model:"swe-2-high",lane:$lane} + (if $cwd=="" then {} else {cwd:$cwd} end)' > "$jd/meta.json"
  : > "$jd/.startmark"; : > "$jd/.fsmark"
  printf '%s' "$jd"
}

# --- control: outside a job, a delegating command still refuses to end blind (rc=7). This is the
# guard working as designed, and it proves the fixture state is enough to trigger it. ---
out="$(child "$FIX/readonly-review.delegate.txt" 0 2>&1)"; rc=$?
[ "$rc" = 7 ] && printf '%s' "$out" | grep -q 'blind-turn guard' \
  && ok "control: an orchestrator-level run still gets the guard's rc=7" \
  || bad "control: expected rc=7 + guard notice outside a job (rc=$rc)"

# --- recorded job 1: read-only review, devin exit 0, complete deliverable, no OSRC::DONE ---
jd="$(newjob review)"
OSRC_JOB_DIR="$jd" OSRC_POLL=1 _supervise "$jd" 30 60 120 -- bash -c "$(declare -f child); child '$FIX/readonly-review.delegate.txt' 0" >/dev/null 2>&1
rc=$?
st="$(cat "$jd/status")"; rsn="$(cat "$jd/reason" 2>/dev/null)"
[ "$st" = "done?" ] && [ "$rc" = 2 ] \
  && ok "review job: status done? (exit 2), not failed/rc=7" \
  || bad "review job: status=$st rc=$rc reason=$rsn (expected done? / 2)"
case "$rsn" in exit-nonzero:rc=7) bad "review job: guard rc leaked into reason ($rsn)" ;; *) ok "review job: no exit-nonzero:rc=7 reason" ;; esac
grep -q 'blind-turn guard' "$jd/out.log" \
  && bad "review job: the guard notice ran inside the job child" \
  || ok "review job: the guard does not run inside the job child"
cp "$jd/out.log" "$jd/last.txt"
[ "$(_classify_job review)" = "$(printf 'REUSE-OUTPUT\tcompleted-unverified')" ] \
  && ok "review job: classify agrees (REUSE-OUTPUT completed-unverified)" \
  || bad "review job: classify said '$(_classify_job review)'"

# --- recorded job 2: edit landed, then devin refused the verification exec and exited 0. The
# warning is replayed on STDERR, where devin writes it, to prove it reaches out.log. ---
W="$FIXTURE/work"; mkdir -p "$W"
jd="$(newjob edit "$W")"
OSRC_JOB_DIR="$jd" OSRC_POLL=1 _supervise "$jd" 30 60 120 -- bash -c "$(declare -f child); date > '$W/parser.ts'; child '$FIX/edit-reject.delegate.txt' 0 2" >/dev/null 2>&1
rc=$?
st="$(cat "$jd/status")"; rsn="$(cat "$jd/reason" 2>/dev/null)"
[ "$st" = "permission-blocked" ] && [ "$rc" = 3 ] && [ "$(cat "$jd/exit")" = 3 ] \
  && ok "edit job: devin non-interactive reject is permission-blocked (exit 3)" \
  || bad "edit job: status=$st rc=$rc exit=$(cat "$jd/exit") (expected permission-blocked / 3)"
[ "$rsn" = "permission-blocked:noninteractive-reject" ] \
  && ok "edit job: reason names the non-interactive reject" \
  || bad "edit job: reason=$rsn"
cp "$jd/out.log" "$jd/last.txt"
# Label only: whether the write or the transcript is seen first depends on mtime granularity.
[ "$(_classify_job edit | cut -f1)" = "REUSE-OUTPUT" ] \
  && ok "edit job: classify keeps the landed work (REUSE-OUTPUT)" \
  || bad "edit job: classify said '$(_classify_job edit)'"

# --- the reject is judged on the log TAIL, and a signed-off DONE wins ---
jd="$(newjob mid)"
OSRC_POLL=1 _supervise "$jd" 30 60 120 -- bash -c "cat '$FIX/edit-reject.delegate.txt'; for i in \$(seq 1 40); do echo \"later work \$i\"; done" >/dev/null 2>&1
[ "$(cat "$jd/status")" = "done?" ] \
  && ok "a reject line pushed out of the tail does not flip the verdict" \
  || bad "mid-log reject line changed status to $(cat "$jd/status")"
jd="$(newjob signed)"
OSRC_POLL=1 _supervise "$jd" 30 60 120 -- bash -c "cat '$FIX/edit-reject.delegate.txt'; echo 'OSRC::DONE finished after running checks another way'" >/dev/null 2>&1
[ "$(cat "$jd/status")" = "done" ] \
  && ok "a delegate that ends on OSRC::DONE after the reject stays done" \
  || bad "OSRC::DONE after reject gave status $(cat "$jd/status")"
jd="$(newjob otherlane "" cc)"
OSRC_POLL=1 _supervise "$jd" 30 60 120 -- cat "$FIX/edit-reject.delegate.txt" >/dev/null 2>&1
[ "$(cat "$jd/status")" = "done?" ] \
  && ok "another lane quoting devin's warning is not mapped to permission-blocked" \
  || bad "non-devin lane quoting the warning gave status $(cat "$jd/status")"
jd="$(newjob optout)"
OSRC_NO_PRINTMODE_ABORT=1 OSRC_POLL=1 _supervise "$jd" 30 60 120 -- cat "$FIX/edit-reject.delegate.txt" >/dev/null 2>&1
[ "$(cat "$jd/status")" = "done?" ] \
  && ok "OSRC_NO_PRINTMODE_ABORT=1 also opts out of the post-exit reject mapping" \
  || bad "opt-out ignored: status $(cat "$jd/status")"

# --- the needle is assembled, never verbatim in the script (reading the script must not trip it) ---
grep -aqF "$(_noninteractive_reject_needle)" "$SRC" \
  && bad "the non-interactive reject needle is verbatim in outsourcerer.sh" \
  || ok "the non-interactive reject needle is absent from outsourcerer.sh"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
