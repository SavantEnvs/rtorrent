#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# rtorrent's cppunit suites (built by build.sh into mayhem/build/tests/test). Each binary prints one
# "<test> : OK" line per passing test on stdout and its own "OK (N)" / "Run: N Failure total: F" summary
# on stderr. Counts come from that summary, and must agree with the per-test lines.
TEST_DIR="$SRC/mayhem/build/tests/test"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
for suite in rtorrent_Test_Core rtorrent_Test_Rpc rtorrent_Test_Src; do
  bin="$TEST_DIR/$suite"
  if [ ! -x "$bin" ]; then
    echo "missing test binary $bin (mayhem/build.sh should have built it)" >&2
    failed=$((failed + 1))
    continue
  fi
  out="$WORK/$suite.out"
  (cd "$WORK" && timeout 900 "$bin") > "$out" 2>&1
  summary_ok="$(sed -n 's/^OK (\([0-9][0-9]*\))$/\1/p' "$out" | tail -n 1)"
  lines_ok="$(grep -c ' : OK$' "$out" || true)"
  if [ -n "$summary_ok" ]; then
    echo "$suite: OK ($summary_ok tests, $lines_ok per-test OK lines)"
    if [ "$summary_ok" -eq 0 ] || [ "$lines_ok" -ne "$summary_ok" ]; then
      failed=$((failed + 1))
    else
      passed=$((passed + summary_ok))
    fi
  else
    run="$(sed -n 's/^Run: *\([0-9][0-9]*\) .*/\1/p' "$out" | tail -n 1)"
    bad="$(grep -cE ' : (assertion|error)$' "$out" || true)"
    echo "$suite: FAILED (run=${run:-?}, failing=$bad)" >&2
    grep -E ' : (assertion|error)$' "$out" >&2 || true
    failed=$((failed + (bad > 0 ? bad : 1)))
    passed=$((passed + lines_ok))
  fi
done

emit_ctrf "rtorrent-cppunit" "$passed" "$failed" 0
