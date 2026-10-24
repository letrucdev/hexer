#!/bin/sh
# Prints the GitHub release notes of VERSION: Distribution/release-notes.md with VERSION's section
# of CHANGELOG.md in place of @CHANGES@ and, given the previous tag, a link to every change since.
# Fails when CHANGELOG.md has no section for VERSION, so a release always says what changed.
#
#   Scripts/release_notes.sh 0.1.1 v0.1 > build/release-notes.md
cd "$(dirname "$0")/.."
VERSION=$1
PREVIOUS=$2
if [ -z "$VERSION" ]; then
    echo "usage: $0 VERSION [PREVIOUS_TAG]" >&2
    exit 2
fi

# The lines under "## VERSION" (a date may follow), up to the next "## " heading, without the
# leading blank lines. Its "### " subheadings become "## " ones, like the installation notes.
SECTION=$(awk -v version="$VERSION" '
    /^## / { if (found) exit; split($0, words, " "); found = (words[2] == version); next }
    found && (started || NF) { started = 1; sub(/^### /, "## "); print }' CHANGELOG.md)
if [ -z "$SECTION" ]; then
    echo "error: CHANGELOG.md has no section \"## $VERSION\"; add one before tagging v$VERSION" >&2
    exit 1
fi

SECTION=$SECTION awk -v version="$VERSION" '
    $0 == "@CHANGES@" { print ENVIRON["SECTION"]; next }
    { gsub(/@VERSION@/, version); print }' Distribution/release-notes.md
# The template ends with a blank line; keep one after the link too, for what the workflow appends.
if [ -n "$PREVIOUS" ]; then
    printf '**Full changelog:** https://github.com/letrucdev/hexer/compare/%s...v%s\n\n' "$PREVIOUS" "$VERSION"
fi
