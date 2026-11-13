#!/bin/sh
# Compares what programs draw.  Each program is built for the cx16 by prog8c-llvm's
# default code generator (the reference) and by p8p8 (-build); both run headless in
# x16emu for a few seconds while it records its video, and tools/gifcmp.py compares the
# recordings: the final picture of a program that settles, the sequence of distinct
# frames of one that does not.
#
# A program that draws at its own pace, not locked to the frame, gives different
# frames in two builds of different speed without anything being wrong: that is
# "cannot tell".  "different picture" is a real difference.
#
# Usage: tests/gfxcmp.sh <p8p8> <reference dir> <file.p8>...
# Needs x16emu, 64tass and Python with Pillow.  GFXCMP_SECONDS (default 8) per run.
# GFXCMP_CODEGEN=own builds p8p8's side with its own 6502 code generator.
p8p8=$1
ref=$2
shift 2
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_gfxcmp.$$
seconds=${GFXCMP_SECONDS:-8}
own=
codegen="-codegen upstream"
if [ "${GFXCMP_CODEGEN:-}" = own ]; then
    own=yes
    codegen="-codegen own"
fi
mkdir -p "$work/up" "$work/p8"
same=0
different=0
unknown=0
total=0
record() {
    (cd "$1" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout "$seconds" x16emu -prg "$2.prg" -run -warp -gif "$2.gif" > emu.log 2>&1 < /dev/null)
}
for f in "$@"; do
    name=$(basename "$f" .p8)
    if [ -n "$own" ] && [ "$name" = sortingbench ]; then
        # it prints how many cycles each sort took: that is the code generator's speed
        echo "skipped (it prints its own timings): $f"
        continue
    fi
    if ! prog8c-llvm -target cx16 -quiet -out "$work/up" "$f" > /dev/null 2>&1 || [ ! -f "$work/up/$name.prg" ]; then
        echo "skipped (the reference does not build): $f"
        continue
    fi
    total=$((total + 1))
    if ! "$p8p8" -target cx16 -lib "$lib" $codegen -out "$work/p8" -build "$f" > "$work/p8.err" 2>&1 || [ ! -f "$work/p8/$name.prg" ]; then
        echo "failed (p8p8 does not build it): $f"
        different=$((different + 1))
        continue
    fi
    record "$work/up" "$name"
    record "$work/p8" "$name"
    result=$(python3 tools/gifcmp.py "$work/up/$name.gif" "$work/p8/$name.gif" 2>&1 | tail -1)
    echo "$result: $f"
    case "$result" in
    same*) same=$((same + 1)) ;;
    different*) different=$((different + 1)) ;;
    *) unknown=$((unknown + 1)) ;;
    esac
    rm -f "$work/up/$name.gif" "$work/p8/$name.gif"
done
rm -rf "$work"
echo "graphics comparison${own:+ (own code generator)}: $total programs, $same the same, $different different, $unknown cannot be compared this way"
[ "$different" -eq 0 ]
