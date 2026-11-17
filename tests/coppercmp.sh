#!/bin/sh
# Builds each Amiga program with prog8c-llvm and with p8p8's 68000 code generator, runs
# both in the Copperline emulator (no window; its bundled AROS unless COPPERCMP_ROM
# names a Kickstart file) and compares the screen after a number of emulated seconds.
# For programs that open screens and draw, which vamos cannot run.
#
# A program whose picture depends on time or on random numbers differs from run to
# run; such a program is found by running upstream's twice, and is not counted.
# Neither is one whose screen is blank (one colour all over) from upstream's build: it
# did not come up, and two blank screens are no agreement.
#
# COPPERCMP_TARGET=amiga500 (the default) or amiga1200; COPPERCMP_SECONDS (default 15).
# Usage: tests/coppercmp.sh <p8p8> <file.p8>...
p8p8=$1
shift
lib=${P8P8_LIB:-lib}
target=${COPPERCMP_TARGET:-amiga500}
seconds=${COPPERCMP_SECONDS:-15}
work=${TMPDIR:-/tmp}/p8p8_coppercmp.$$
mkdir -p "$work/up" "$work/p8"
if [ "$target" = amiga500 ]; then
    machine="--model A500 --cpu 68000 --slow 512K"
else
    machine="--model A1200 --cpu 68020 --fpu"
fi
shot() {
    # shot <dir> <name> <png>: the screen of the program after $seconds
    rm -f "$3"
    timeout 300 copperline --factory $machine ${COPPERCMP_ROM:+"$COPPERCMP_ROM"} --run "$1/$2" \
        --screenshot-after "$seconds" "$3" > "$1/copperline.log" 2>&1 < /dev/null
    [ -s "$3" ]
}
blank() {
    # blank <png>: is the picture one colour all over (needs ImageMagick; without it: no)
    command -v magick > /dev/null 2>&1 || return 1
    [ "$(magick identify -format '%k' "$1" 2> /dev/null)" = 1 ]
}
failed=0
total=0
same=0
lacking=0
unsteady=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    dir=$(dirname "$f")
    if ! prog8c-llvm -target $target -srcdirs "$dir" -plaintext -quiet -out "$work/up" "$f" > /dev/null 2>&1; then
        echo "skipped (upstream rejects): $f"
        continue
    fi
    total=$((total + 1))
    if ! "$p8p8" -target $target -lib "$lib" -srcdirs "$dir" -build -out "$work/p8" "$f" > "$work/p8.err" 2>&1; then
        echo "not built ($(grep -v '^$' "$work/p8.err" | head -1)): $f"
        lacking=$((lacking + 1))
        continue
    fi
    if ! shot "$work/up" "$name" "$work/up1.png" || ! shot "$work/up" "$name" "$work/up2.png"; then
        echo "skipped (no picture of upstream's program): $f"
        total=$((total - 1))
        continue
    fi
    if blank "$work/up1.png"; then
        # nothing came up: two blank screens being the same says nothing about the programs
        echo "cannot tell (upstream's program shows a blank screen: does it run on this ROM?): $f"
        unsteady=$((unsteady + 1))
        continue
    fi
    if ! cmp -s "$work/up1.png" "$work/up2.png"; then
        echo "cannot tell (upstream's program does not show the same twice): $f"
        unsteady=$((unsteady + 1))
        continue
    fi
    if shot "$work/p8" "$name" "$work/p8.png" && cmp -s "$work/up1.png" "$work/p8.png"; then
        echo "ok: $f"
        same=$((same + 1))
    else
        echo "failed (the screens differ): $f"
        failed=$((failed + 1))
        if [ -n "$COPPERCMP_KEEP" ]; then
            mkdir -p "$COPPERCMP_KEEP"
            cp "$work/up1.png" "$COPPERCMP_KEEP/$name-upstream.png"
            cp "$work/p8.png" "$COPPERCMP_KEEP/$name-p8p8.png" 2> /dev/null
        fi
    fi
done
rm -rf "$work"
echo "Copperline comparison ($target, own code generator): $total programs, $same the same, $failed different, $lacking not built, $unsteady cannot be compared this way"
[ "$failed" -eq 0 ]
