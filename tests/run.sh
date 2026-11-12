#!/bin/sh
# Syntax-checks the addon and runs every Lua harness. Run from anywhere; needs lua5.1 and luac5.1.
set -e
cd "$(dirname "$0")/.."
for f in addon/ShuffleDetector/*.lua; do luac5.1 -p "$f"; done
for f in tests/*_harness.lua; do lua5.1 "$f" >/dev/null; echo "ok $f"; done
