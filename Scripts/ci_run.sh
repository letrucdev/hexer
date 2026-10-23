#!/bin/sh
# Runs a command in GitHub Actions. When it fails, its error lines (and the end of its output) are
# repeated as workflow annotations, which the run page and the public API show without the log.
#
#   Scripts/ci_run.sh Scripts/test.sh
log=$(mktemp)
{ "$@" 2>&1; echo $? >"$log.status"; } | tee "$log"
status=$(cat "$log.status")
[ "$status" -eq 0 ] && exit 0

# An annotation is one line: newlines become %0A, and % itself %25.
annotate() {
    sed -e 's/%/%25/g' -e 's/\r//g' | awk -v title="$1" '
        { lines = lines (NR > 1 ? "%0A" : "") $0 }
        END { if (NR) print "::error title=" title "::" lines }'
}
grep -E "error:|✘|FAIL|[Ff]atal|Expectation failed|failed" "$log" | grep -v "^[[:space:]]*$" | head -60 | annotate "$1: errors"
tail -40 "$log" | annotate "$1: end of output"
exit "$status"
