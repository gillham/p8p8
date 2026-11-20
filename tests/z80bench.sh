#!/bin/sh
# The size and the running time of tests/z80bench/bench.p8 as a CP/M program in tnylpo,
# with the pass over the assembly and without it (-noopt).  The time is the host's, the
# best of three runs: a measure for comparing one build of the compiler with another on
# the same machine, not a count of the Z80's cycles.
#
# Usage: tests/z80bench.sh <p8c>      (needs z88dk-z80asm (Z88DK) and tnylpo)
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_z80bench.XXXXXX")
trap 'rm -rf "$work"' EXIT
for how in "" "-noopt"; do
    rm -rf "$work/o"; mkdir "$work/o"
    if ! "$p8c" -lib "$lib" -target cpm $how -out "$work/o" "$here/z80bench/bench.p8" > "$work/log" 2>&1; then
        echo "not built: $(grep -v warning "$work/log" | head -1)"; exit 1
    fi
    cp "$work/o/bench.com" "$work/o/b.com"
    best=999
    for run in 1 2 3; do
        t=$( { /usr/bin/time -p tnylpo "$work/o/b.com" > "$work/out.txt"; } 2>&1 | awk '/real/{print $2}')
        best=$(echo "$t $best" | awk '{print ($1 < $2) ? $1 : $2}')
    done
    echo "bench${how:+ ($how)}: $(wc -c < "$work/o/bench.com" | tr -d ' ') bytes, $best s, prints $(tr -d '\r' < "$work/out.txt")"
done
