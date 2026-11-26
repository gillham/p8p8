#!/bin/sh
# The prodos target (the Apple II with ProDOS): tests/prodos/files.p8 is built and
# started with ProDOS in memory, in bobbin's line interface (no window); what it
# prints is printed (make a2prodos compares it with tests/expected/prodos.txt).
#
# Usage: A2PRODOS=<disk image> tests/prodos.sh <p8c>
#        (needs 64tass and bobbin in the path)
# The disk image is one that starts ProDOS and its BASIC.SYSTEM, with some blocks
# free (bobbin comes with one, disk/prodos242.dsk); ProDOS is Apple's and does not
# come with p8p8.  The test works on a copy.
# bobbin puts the program in memory at $2000 when BASIC.SYSTEM waits for a line, and
# jumps to it: as ProDOS starts a system program, without the file on the disk.
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_prodos.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$A2PRODOS" "$work/disk.dsk" && chmod u+w "$work/disk.dsk" || exit 1
"$p8c" -lib "$lib" -target prodos -out "$work" "$here/prodos/files.p8" > "$work/err" 2>&1 || { cat "$work/err"; exit 1; }
# (bobbin does not show what is printed on the line where it was waiting for input:
#  eight bytes at $380 end that line first: LDA #$8D, JSR COUT1, JMP $2000)
printf '\251\215\040\360\375\114\000\040' > "$work/first.bin"
(cd "$work" && timeout 300 bobbin --simple --turbo --max-runtime 1800 --disk disk.dsk --delay-until INPUT \
    --load first.bin --load-at 380 --load files.bin --load-at 2000 --jump-to 380 < /dev/null 2>&1) |
    sed -e 's/ *$//' -e '/^$/d' -e '/^bobbin:/d'
