#!/bin/sh
# Builds the Hexer film (VIDEO.md): a 30-second 4K commercial cut from real recordings of the app.
#
#   Scripts/film/make.sh                  edit, score and mux the recorded takes → build/film/hexer-film.mp4
#   Scripts/film/make.sh record           record every take first (the mouse moves by itself, ~3 minutes)
#   Scripts/film/make.sh record macro     record only these takes first
#   Scripts/film/make.sh stills 5.5,17    draft stills (1080p) in build/film/stills
#
# Needs build/Hexer.app (Scripts/bundle.sh), and Accessibility and Screen Recording permission for
# the terminal when recording. Everything is written to build/film/ (not committed).
set -e
cd "$(dirname "$0")/../.."
mkdir -p build/film/bin
for tool in record render score; do
    if [ ! -x "build/film/bin/$tool" ] || [ "Scripts/film/$tool.swift" -nt "build/film/bin/$tool" ]; then
        echo "building $tool"
        swiftc -O -suppress-warnings "Scripts/film/$tool.swift" -o "build/film/bin/$tool"
    fi
done
case "$1" in
    record) shift; build/film/bin/record "$@" ;;
    stills) build/film/bin/render --size 1920x1080 --stills "$2"; exit 0 ;;
esac
build/film/bin/render
build/film/bin/score
build/film/bin/render --mux
