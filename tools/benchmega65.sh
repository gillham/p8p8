#!/bin/sh
# Longs on the MEGA65: tests/mega65/longbench.p8 as 6502 code and as 45GS02 code, run
# in xmega65 (Xemu) without a window.  The program times four loops by the VIC-IV's
# frame counter ($d7fa, 8 bits: the loops are short enough not to wrap it; the jiffy
# clock stands still in the emulator).  Fewer frames is faster.  The times are the
# emulator's, not a real machine's.
#
# Usage: tools/benchmega65.sh [p8c]        (needs 64tass and xmega65 in the path)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_benchmega65.XXXXXX")
trap 'rm -rf "$work"' EXIT
for cpu in 6502 45gs02; do
    mkdir -p "$work/$cpu"
    opt=
    [ $cpu = 45gs02 ] && opt="-cpu 45gs02"
    "$p8c" -target mega65 -lib "$lib" $opt -out "$work/$cpu" tests/mega65/longbench.p8 || exit 1
    (cd "$work/$cpu" && timeout 300 xmega65 -headless -sleepless -besure -prg longbench.prg -prgexit \
        -dumpscreen screen.txt > log.txt 2>&1 < /dev/null)
    echo "== $cpu code, $(wc -c < "$work/$cpu/longbench.prg" | tr -d ' ') bytes"
    sed -n '/ RUN:/,$p' "$work/$cpu/screen.txt" | grep 'FRAMES'
done
