#!/bin/sh
# The program's map (-map, name.p8map) for every CPU p8p8 writes code for: test
# programs are built for a number of targets, and tools/p8size.py --check says of
# each map whether its entries fill the program's regions to the byte (the code and
# data, the variables) with nothing of the wrong kind in them.  Then what must be in
# a map is looked for: the main block's subroutine, and its array with its 100 bytes.
# A target whose assembler is not installed is left out.
#
# Usage: tests/mapcheck.sh <p8c>      (needs python3; 64tass, lwasm, z88dk, vasm, nasm)
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
size="python3 $here/../tools/p8size.py"
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_mapcheck.XXXXXX")
trap 'rm -rf "$work"' EXIT
PATH="${Z88DK:+$Z88DK/bin:}$PATH"
good=0
bad=0
skipped=0

# one <name> <assembler> <program> <p8c options...>
one() {
    name=$1; tool=$2; source=$3; shift 3
    if ! command -v "$tool" > /dev/null 2>&1; then
        skipped=$((skipped + 1)); return
    fi
    mkdir "$work/$name"
    map=$work/$name/$(basename "$source" .p8).p8map
    if ! "$p8c" -lib "$lib" "$@" -map -out "$work/$name" "$here/$source" > "$work/$name/log" 2>&1 || [ ! -f "$map" ]; then
        echo "$name: not built: $(grep -v warning "$work/$name/log" | head -1)"; bad=$((bad + 1)); return
    fi
    if ! $size "$map" --check --map > "$work/$name/out" 2> "$work/$name/err"; then
        echo "$name: $(sed "s|$work/||" "$work/$name/err" | head -3)"; bad=$((bad + 1)); return
    fi
    case $source in
    */sizes.p8)
        if ! grep -q '^code [0-9a-f]* [0-9]* main start$' "$map" || ! grep -q '^code [0-9a-f]* [0-9]* main start.inner$' "$map" ||
           ! grep -q '^var [0-9a-f]* 100 main table$' "$map" || ! grep -q '^module main .*sizes.p8$' "$map"; then
            echo "$name: main.start, main.start.inner, main.table (100 bytes) or the module of main is not in the map"
            bad=$((bad + 1)); return
        fi ;;
    esac
    good=$((good + 1))
}

one c64 64tass mapcheck/sizes.p8 -target c64
one cx16 64tass mapcheck/sizes.p8 -target cx16
one cx16-varshigh 64tass mapcheck/sizes.p8 -target cx16 -varshigh 1
one cx16-varsgolden 64tass mapcheck/sizes.p8 -target cx16 -varsgolden
one c64-floats 64tass mapcheck/withfloats.p8 -target c64
one mega65 64tass mapcheck/sizes.p8 -target mega65
one gametank 64tass mapcheck/sizes.p8 -target gametank
one cpm z88dk-z80asm mapcheck/sizes.p8 -target cpm
one trs80m4 z88dk-z80asm mapcheck/sizes.p8 -target trs80m4
one cpm-floats zcc mapcheck/withfloats.p8 -target cpm
one coco2 lwasm mapcheck/sizes.p8 -target coco2
one coco3ram lwasm mapcheck/sizes.p8 -target coco3ram
one coco3ram-above lwasm cocosys/bigcode.p8 -target coco3ram
one amiga500 vasmm68k_mot mapcheck/sizes.p8 -target amiga500
one qemu68k vasmm68k_mot mapcheck/sizes.p8 -target qemu68k
one atarist vasmm68k_mot mapcheck/sizes.p8 -target atarist
one dos nasm mapcheck/sizes.p8 -target dos
one dosexe nasm mapcheck/sizes.p8 -target dosexe
one dos-floats nasm mapcheck/withfloats.p8 -target dos
one dosexe-floats nasm mapcheck/withfloats.p8 -target dosexe -floats soft

# the tool's other reports must at least run, and a comparison of a map with itself
# has nothing to say
if [ -f "$work/c64/sizes.p8map" ]; then
    m=$work/c64/sizes.p8map
    for options in "" "--vars" "--modules" "--json" "--block main" "--map --min-free 100"; do
        if ! $size "$m" $options > "$work/report" 2>&1; then
            echo "p8size $options: $(head -2 "$work/report")"; bad=$((bad + 1))
        fi
    done
    if [ "$($size "$m" "$m" | wc -l | tr -d ' ')" != 5 ]; then
        echo "p8size: a map compared with itself"; bad=$((bad + 1))
    fi
    if $size "$m" --map --min-free 60000 > /dev/null 2>&1; then
        echo "p8size --min-free: no error with less room than asked for"; bad=$((bad + 1))
    fi
fi

echo "program maps: $good as expected, $bad wrong, $skipped without their assembler"
[ "$bad" = 0 ]
