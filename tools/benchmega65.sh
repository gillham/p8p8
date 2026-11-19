#!/bin/sh
# Arithmetic on the MEGA65: tests/mega65/longbench.p8, mulbench.p8 and divbench.p8 as
# 6502 code and as 45GS02 code, run in xmega65 (Xemu) without a window.  The programs
# time their loops by the VIC-IV's
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
    opt="-cpu $cpu"
    for bench in longbench mulbench divbench; do
        "$p8c" -target mega65 -D "prog8_exit_noreset:=1" -lib "$lib" $opt -out "$work/$cpu" tests/mega65/$bench.p8 || exit 1
        (cd "$work/$cpu" && rm -f screen.txt && timeout 300 xmega65 -headless -sleepless -besure -prg $bench.prg -prgexit \
            -dumpscreen screen.txt > log.txt 2>&1 < /dev/null)
        echo "== $bench, $cpu code, $(wc -c < "$work/$cpu/$bench.prg" | tr -d ' ') bytes"
        sed -n '/ RUN:/,$p' "$work/$cpu/screen.txt" | grep 'FRAMES'
    done
done
