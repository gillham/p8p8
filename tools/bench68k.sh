#!/bin/sh
# How long the programs in tests/bench68k take on an Amiga 500, built by prog8c-llvm and
# by p8p8's 68000 code generator: emulated seconds in the Copperline emulator (its bundled
# AROS), from "program returned" in its log, less the time an empty program takes (the
# boot).  Also the size of each program file, and whether the two print the same.
#
# BENCH_TARGET=amiga1200 times the 68020 code on an Amiga 1200 instead.
#
# Usage: tools/bench68k.sh [<p8c>]        (default build/llvm64/p8c; run from the repository)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_bench68k.$$
mkdir -p "$work/up" "$work/p8"
target=${BENCH_TARGET:-amiga500}
machine="--model A500 --cpu 68000 --slow 512K"
[ "$target" = amiga1200 ] && machine="--model A1200 --cpu 68020"
seconds() {
    # seconds <dir> <name>: the emulated time at which the program returned; its output in out.log
    (cd "$1" && : > out.log && timeout 900 copperline --factory $machine --run "$2" --run-args ">out.log" \
        --exit-on-return > cl.log 2>&1 < /dev/null)
    grep -o 'returned 0 at [0-9.]*' "$1/cl.log" | grep -o '[0-9.]*$'
}
printf 'main {\n    sub start() {\n    }\n}\n' > "$work/empty.p8"
prog8c-llvm -target $target -quiet -plaintext -out "$work/up" "$work/empty.p8" > /dev/null 2>&1
boot=$(seconds "$work/up" empty)
for f in tests/bench68k/*.p8; do
    n=$(basename "$f" .p8)
    prog8c-llvm -target $target -quiet -plaintext -out "$work/up" "$f" > /dev/null 2>&1
    "$p8c" -lib "$lib" -target $target -build -out "$work/p8" "$f" > /dev/null 2>&1 || echo "p8p8 does not build $n" >&2
    tu=$(seconds "$work/up" "$n")
    tp=$(seconds "$work/p8" "$n")
    same=
    cmp -s "$work/up/out.log" "$work/p8/out.log" || same="  OUTPUT DIFFERS"
    echo "$n $tu $tp $boot $(wc -c < "$work/up/$n") $(wc -c < "$work/p8/$n")$same"
done | awk '{ u = $2 - $4; p = $3 - $4
    printf "%-8s upstream %5.2f s %5d bytes   p8p8 %5.2f s %5d bytes   x%.2f%s\n", $1, u, $5, p, $6, p / u, ($7 != "" ? "  OUTPUT DIFFERS" : "") }'
