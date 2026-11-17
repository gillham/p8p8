#!/bin/sh
# How long the programs in tests/bench68k take on a Commander X16 with a 65816
# (x16emu -c816): built by prog8c-llvm (65C02 code; it has no other), by p8p8 for the
# 65C02, and by p8p8 for the 65816.  Each program's start routine is run three times
# between two readings of the jiffy clock (1/60 s), so the times are the program's own.
#
# A kernel that upstream does not build for this machine, or that does not come to an
# end on it (fib: a subroutine that calls itself has no fresh variables on a 6502), is
# left out with a line that says so.
#
# Usage: tools/bench65.sh [<p8c>]        (default build/llvm64/p8c; run from the repository)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_bench65.$$
mkdir -p "$work/up" "$work/c02" "$work/816"
jiffies() {
    # jiffies <dir> <name>: the last number the program prints
    (cd "$1" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 90 x16emu -c816 -prg "$2.prg" -run -warp -echo iso 2>&1 < /dev/null) |
        grep -o 'JIFFIES [0-9]*' | grep -o '[0-9]*$' | tail -1
}
for f in tests/bench68k/*.p8; do
    n=$(basename "$f" .p8)
    # the kernel's start routine becomes run(), called from a start that reads the clock
    sed 's/^    sub start() {/    sub run() {/' "$f" > "$work/$n.p8"
    cat >> "$work/$n.p8" <<'END'

timing {
    sub go() {
        uword before = cbm.RDTIM16()
        repeat 3
            main.run()
        txt.print("jiffies ")
        txt.print_uw(cbm.RDTIM16() - before)
        txt.nl()
    }
}
END
    # (main.start has to be in main: the last brace of the file closed main before the block above)
    python3 - "$work/$n.p8" <<'END'
import sys
p = sys.argv[1]
t = open(p).read()
i = t.index("\ntiming {")
head = t[:i].rstrip()
assert head.endswith("}")
head = head[:-1] + "\n    sub start() {\n        timing.go()\n    }\n}\n"
open(p, "w").write("%zeropage basicsafe\n" + head + t[i:])
END
    if ! prog8c-llvm -target cx16 -quiet -plaintext -out "$work/up" "$work/$n.p8" > "$work/up.log" 2>&1; then
        echo "$n: not for this machine (prog8c-llvm does not build it)" >&2
        continue
    fi
    "$p8c" -lib "$lib" -target cx16 -cpu 65c02 -out "$work/c02" "$work/$n.p8" > "$work/c02.log" 2>&1 || { echo "p8p8 does not build $n for the 65C02" >&2; continue; }
    "$p8c" -lib "$lib" -target cx16 -cpu 65816 -out "$work/816" "$work/$n.p8" > "$work/816.log" 2>&1 || { echo "p8p8 does not build $n for the 65816" >&2; continue; }
    ju=$(jiffies "$work/up" "$n"); jc=$(jiffies "$work/c02" "$n"); j8=$(jiffies "$work/816" "$n")
    if [ -z "$ju" ] || [ -z "$jc" ] || [ -z "$j8" ]; then
        echo "$n: a program did not finish (upstream '$ju', 65C02 '$jc', 65816 '$j8' jiffies)" >&2
        continue
    fi
    echo "$n $ju $jc $j8 $(wc -c < "$work/up/$n.prg" | tr -d ' ') $(wc -c < "$work/c02/$n.prg" | tr -d ' ') $(wc -c < "$work/816/$n.prg" | tr -d ' ')"
done | awk '{ printf "%-8s upstream %4d jiffies %5d bytes   p8p8 65C02 %4d (x%.2f) %5d bytes   p8p8 65816 %4d (x%.2f) %5d bytes\n", $1, $2, $5, $3, $3 / $2, $6, $4, $4 / $2, $7 }'
rm -rf "$work"
