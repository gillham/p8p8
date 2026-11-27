#!/bin/sh
# sys.entropy() (p8p8's own) must be there on every target: a program that calls it
# is turned into assembly for each (-asm: no assembler is needed).  The two Amigas are
# not in the list: their syslib is upstream's file, which has no such routine.
#
# Usage: tests/entropycheck.sh <p8c>
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_entropy.XXXXXX")
trap 'rm -rf "$work"' EXIT
good=0
bad=0
for target in c64 c128 cx16 pet32 mega65 vic20 vic20plus3 vic20plus8 vic20plus24 plus4 \
    atari appleii prodos gametank sim6502 mc64 f256 rp6502 w65c816sxb cx16os \
    atarist macplus qemu68k dos dosexe cpm trs80 trs80m4 \
    coco2 coco3 coco2ram coco3ram dragon32 dragon64 sim6809 llvm64 llvm32 virtual; do
    mkdir "$work/$target"
    asm=-asm
    case $target in llvm*|virtual) asm= ;; esac     # (LLVM IR, the VM's IR: no assembly)
    if "$p8c" -lib "$here/../lib" -target $target $asm -out "$work/$target" "$here/entropy_all.p8" > "$work/$target/log" 2>&1; then
        good=$((good + 1))
    else
        echo "$target: $(grep -v warning "$work/$target/log" | head -1)"; bad=$((bad + 1))
    fi
done
echo "sys.entropy: $good targets have it, $bad do not"
[ $bad -eq 0 ]
