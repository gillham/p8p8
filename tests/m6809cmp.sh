#!/bin/sh
# The 6809 code generator, on a bare 6809: each program is built for the host (llvm64)
# and for the sim6809 target, the first run as it is and the second in usim09batch, and
# what they print is compared.  The generator is new: a program that it cannot build yet
# is counted, with the first thing it says, and is not a failure.
#
# The 6809 has the high byte of a word first, and a few lines show that (a word poked
# and its bytes peeked).  Where a program's output is tests/m6809/<name>.out, that is
# right too: the host's output with those lines as the 6809 must have them.
#
# With M6809CMP_MACHINE=coco2 the second is built for the Color Computer 2 instead (the
# coco2 target as tests/m6809/xroar-coco2.properties has it) and run in XRoar by
# tests/cocorun.sh, unattended; COCO_MACHINE=coco3 makes it XRoar's Color Computer 3.
# M6809CMP_MACHINE=coco3 is the coco3 target on that machine, on its 32 column screen,
# and coco3w the same on its 80 column screen; dragon32 and dragon64 are the dragon32
# target on XRoar's Dragons.
#
# A program with floats prints them as the machine's BASIC does (its floats are the
# ROM's): there tests/floatsame.py compares, number by number, to seven digits.
#
# Usage: tests/m6809cmp.sh <p8c> <program.p8>...
#        (needs clang, lwasm (lwtools) and usim09batch, or XRoar with the machine's ROMs)
p8c=$1
shift
lib=${P8P8_LIB:-lib}
here=$(cd "$(dirname "$0")" && pwd)
machine=${M6809CMP_MACHINE:-sim6809}
where="usim09batch"
[ "$machine" = coco2 ] && where="Color Computer in XRoar, ${COCO_MACHINE:-coco2bus}"
# (the coco3 target, on its 32 column screen or, as coco3w, on its 80 column one)
variant=xroar-coco2
if [ "$machine" = coco3 ] || [ "$machine" = coco3w ]; then
    variant=xroar-coco3
    [ "$machine" = coco3w ] && variant=xroar-coco3-80
    where="Color Computer 3 in XRoar, target coco3 ($variant)"
    COCO_MACHINE=coco3
    export COCO_MACHINE
    machine=coco2
    targetdir=coco3
fi
# (the coco2ram target: the program with the ROMs switched out, on a 64 KB machine)
if [ "$machine" = coco2ram ]; then
    variant=xroar-coco2ram
    where="Color Computer 2 in XRoar, target coco2ram (the ROMs switched out)"
    machine=coco2
    targetdir=coco2ram
fi
# (the dragon32 target, on XRoar's Dragon 32 or Dragon 64)
if [ "$machine" = dragon32 ] || [ "$machine" = dragon64 ]; then
    variant=xroar-dragon32
    where="Dragon in XRoar, $machine"
    COCO_MACHINE=$machine
    export COCO_MACHINE
    machine=coco2
    targetdir=dragon32
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_m6809cmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/host" "$work/m6809"
same=0; differ=0; unbuilt=0; skipped=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    rm -f "$work/host/$name" "$work/m6809/$name.hex" "$work/m6809/$name.bin"
    onhost=yes
    if ! "$p8c" -lib "$lib" -target llvm64 -o "$work/host/$name" "$f" > "$work/host.err" 2>&1; then
        # (a program for the 6809 alone, with assembly: what it must print is beside it)
        if [ ! -f "${f%.p8}.out" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        onhost=no
        cp "${f%.p8}.out" "$work/host/$name.out"
    fi
    if [ "$machine" = coco2 ]; then
        "$p8c" -lib "$lib" -srcdirs "$lib/targets/${targetdir:-coco2}" -target "$here/m6809/$variant.properties" -out "$work/m6809" "$f" > "$work/m6809.err" 2>&1
        built="$work/m6809/$name.bin"
    else
        "$p8c" -lib "$lib" -target sim6809 -out "$work/m6809" "$f" > "$work/m6809.err" 2>&1
        built="$work/m6809/$name.hex"
    fi
    if [ $? -ne 0 ] || [ ! -f "$built" ]; then
        unbuilt=$((unbuilt + 1))
        echo "not built yet: $f: $(grep -v warning "$work/m6809.err" | head -1 | cut -c1-110)"
        continue
    fi
    ran=0
    if [ "$onhost" = yes ]; then
        (cd "$work/host" && timeout 10 "./$name" < /dev/null > "$name.out" 2>&1)
        ran=$?
    fi
    if [ $ran -ge 124 ]; then
        skipped=$((skipped + 1))    # (it does not end on the host, or it is for a machine's memory)
        continue
    fi
    # (the simulator's timeout counts instructions)
    if [ "$machine" = coco2 ]; then
        "$here/cocorun.sh" "$built" > "$work/m6809/$name.out" 2>&1
    else
        usim09batch --timeout=400000000 "$built" < /dev/null > "$work/m6809/$name.out" 2>&1
    fi
    if cmp -s "$work/host/$name.out" "$work/m6809/$name.out" ||
            { [ -f "$here/m6809/$name.out" ] && cmp -s "$here/m6809/$name.out" "$work/m6809/$name.out"; } ||
            { grep -q '^%import floats' "$f" && python3 "$here/floatsame.py" "$work/host/$name.out" "$work/m6809/$name.out"; }; then
        same=$((same + 1))
        echo "ok: $f"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/host/$name.out" "$work/m6809/$name.out" | head -4
    fi
done
echo "6809 comparison ($where, against the host): $same the same, $differ different, $unbuilt not built yet, $skipped not for the host"
[ "$differ" -eq 0 ]
