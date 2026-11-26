#!/bin/sh
# The Apple II target's file routines (diskio, DOS 3.3).  tests/a2dos/files.p8 is built,
# put on a copy of a DOS 3.3 disk and started there with BRUN, in bobbin's line
# interface (no window); what it prints is printed (make a2dos compares it with
# tests/expected/a2dos.txt).
#
# Usage: A2DOS33=<disk image> tests/a2dos.sh <p8c>
#        (needs 64tass, python3 and bobbin in the path)
# The disk image is a 140 KB one in DOS's sector order (.do, .dsk) that starts DOS 3.3
# and has room for some forty sectors; DOS is Apple's and does not come with p8p8.
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_a2dos.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$A2DOS33" "$work/disk.do" && chmod u+w "$work/disk.do" || exit 1
"$p8c" -lib "$lib" -target appleii -out "$work" "$here/a2dos/files.p8" > "$work/err" 2>&1 || { cat "$work/err"; exit 1; }
python3 "$here/../tools/a2put.py" "$work/disk.do" "$work/files.bin" P8FILES || exit 1
# (bobbin shows nothing of what is printed before the first line that is typed)
# (the line after the program: DOS and BASIC go on when the program has returned)
printf 'BRUN P8FILES\nPRINT 3+4\n' | (cd "$work" && timeout 300 bobbin --simple --turbo --max-runtime 1800 --disk disk.do 2>&1) |
    sed -e 's/ *$//' -e '/^$/d' -e '/^bobbin:/d'
