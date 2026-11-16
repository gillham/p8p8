#!/bin/sh
# The lines of a 68000 program's .p8ir that the m68k test compares: the target's
# options, and from the main block the calls and the moves to and from hardware
# slots, with the numbers of the virtual registers taken out.
# Usage: tools/m68kir.sh <file.p8ir>
grep '^output=\|^loadAddress=\|^memtop=' "$1"
awk '/^<BLOCK NAME="p8b_main"/ { on = 1 } /^<\/BLOCK>/ { on = 0 } on' "$1" |
    grep '^storehr\|^loadhr\|^call' | sed -E 's/f?r[0-9]+\./r./g'
