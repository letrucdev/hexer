#!/bin/sh
# Runs the swift-testing suites (the Command Line Tools have no XCTest), hiding build chatter.
#
# A run still going after $TEST_TIMEOUT seconds (default 900, the build included) is stopped and
# fails with error lines (which Scripts/ci_run.sh turns into annotations, readable without logging
# in): the tools the tests were still waiting for, and where in Hexer's code the test runner was.
# swift-testing prints nothing until a run ends when its output isn't a terminal, so these are all
# a hang in CI leaves.
cd "$(dirname "$0")/.."
LOG=$(mktemp -t hexer-test)
trap 'rm -f "$LOG" "$LOG.hang" "$LOG.sample"' EXIT
swift test --disable-xctest "$@" >"$LOG" 2>&1 &
PID=$!
LIMIT=${TEST_TIMEOUT:-900}
waited=0
while kill -0 "$PID" 2>/dev/null && [ "$waited" -lt "$LIMIT" ]; do
    sleep 1
    waited=$((waited + 1))
done
if kill -0 "$PID" 2>/dev/null; then
    # swift test runs the test bundles in child processes.
    tree() {
        echo "$1"
        for child in $(pgrep -P "$1"); do tree "$child"; done
    }
    PIDS=$(tree "$PID")
    for p in $PIDS; do
        ps -o etime=,command= -p "$p" 2>/dev/null | cut -c1-200 | sed 's/^ */error: still running: /' >>"$LOG.hang"
    done
    for p in $(pgrep -f "Tests.xctest|HexerPackageTests" | grep -xF "$PIDS"); do
        sample "$p" 2 -file "$LOG.sample" >/dev/null 2>&1
        grep -oE "(Hexer[A-Za-z]*|UpdateStaging|MountedDiskImage|Subprocess)[A-Za-z]*[.(][^ ]{0,120}" "$LOG.sample" |
            sort | uniq -c | sort -rn | head -12 | sed 's/^ */error: stack of the test runner: /' >>"$LOG.hang"
    done
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    wait "$PID" 2>/dev/null
    STATUS=124
else
    wait "$PID"
    STATUS=$?
fi
grep -vE "^\[[0-9]+/[0-9]+\]|^(Compiling|Emitting|Linking|Write|Planning|Building)|ld: warning" "$LOG"
if [ "$STATUS" -eq 124 ]; then
    started=$(sed -n 's/^.*◇ Test \(.*\) started\.$/\1/p' "$LOG" | sort -u)
    finished=$(sed -nE 's/^.*[✔✘] Test (.*) (passed|failed) after .*$/\1/p' "$LOG" | sort -u)
    running=$(printf '%s\n' "$started" | grep -vxF "$finished" | tr '\n' ' ')
    echo "error: tests still running after $LIMIT seconds, stopped: ${running:-names unknown (output is printed at the end)}"
    cat "$LOG.hang" 2>/dev/null
fi
exit $STATUS
