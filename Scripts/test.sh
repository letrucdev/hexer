#!/bin/sh
# Runs the swift-testing suites (the Command Line Tools have no XCTest), hiding build chatter.
cd "$(dirname "$0")/.."
LOG=$(mktemp -t hexer-test)
trap 'rm -f "$LOG"' EXIT
swift test --disable-xctest "$@" >"$LOG" 2>&1
STATUS=$?
grep -vE "^\[[0-9]+/[0-9]+\]|^(Compiling|Emitting|Linking|Write|Planning|Building)|ld: warning" "$LOG"
exit $STATUS
