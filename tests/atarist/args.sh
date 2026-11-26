#!/bin/sh
# The command line of an Atari ST program: tests/atarist/argsrun.p8 starts
# tests/atarist/args.p8 twice, with a command line and without one, and what the two
# print is printed (make stargs compares it with tests/expected/stargs.txt).
#
# Usage: tests/atarist/args.sh <p8c>      (see tests/strun.sh for what it needs)
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_stargs.XXXXXX")
trap 'rm -rf "$work"' EXIT
for p in args argsrun; do
    "$p8c" -lib "$lib" -target atarist -out "$work" "$here/$p.p8" > "$work/err" 2>&1 || { cat "$work/err"; exit 1; }
done
ST_PARENT=1 ST_EXTRA="ARGS.TOS=$work/args.tos" "$here/../strun.sh" "$work/argsrun.tos" | tr -d '\r' |
    awk 'started || $0 != "" { started = 1; print }'
