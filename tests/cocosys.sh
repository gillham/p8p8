#!/bin/sh
# The file routines of the coco2 target (diskio: Disk BASIC's files through its sector
# routine), run in XRoar with a disk image: tests/cocosys/files.p8 writes, reads,
# renames and deletes files and reads one that toolshed's decb put on the disk.  What it
# prints is compared with tests/cocosys/expected.txt; then decb reads the disk: its
# directory, and the files' bytes.
#
# Usage: tests/cocosys.sh <p8c>      (needs lwasm, XRoar with the Color Computer 2's and
#                                     Disk BASIC's ROMs, and decb of toolshed)
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_cocosys.XXXXXX")
trap 'rm -rf "$work"' EXIT
if ! "$p8c" -lib "$lib" -srcdirs "$lib/targets/coco2" -target "$here/m6809/xroar-coco2.properties" -out "$work" "$here/cocosys/files.p8" > "$work/files.log" 2>&1; then
    echo "not built: files: $(grep -v warning "$work/files.log" | head -1)"; exit 1
fi
decb dskini "$work/t.dsk" > /dev/null || exit 1
printf 'from the host\rsecond line\r' > "$work/host.txt"
decb copy -1 -a "$work/host.txt" "$work/t.dsk,HOST.TXT" > /dev/null || exit 1
{
    COCO_OPTIONS="-load-fd0 $work/t.dsk" "$here/cocorun.sh" "$work/files.bin"
    # what another program finds on the disk afterwards
    decb dir "$work/t.dsk," | grep -v '^Directory' | grep -v '^$' | tr -s ' '
    decb copy "$work/t.dsk,LINES.TXT" "$work/lines.out" > /dev/null && wc -c < "$work/lines.out" | tr -d ' '
    decb copy "$work/t.dsk,BIG.DAT" "$work/big.out" > /dev/null && cksum < "$work/big.out"
    decb copy "$work/t.dsk,EMPTY" "$work/empty.out" > /dev/null && wc -c < "$work/empty.out" | tr -d ' '
} > "$work/printed.txt" 2>&1
if diff -u "$here/cocosys/expected.txt" "$work/printed.txt"; then
    echo "files on the Color Computer: as expected"
else
    exit 1
fi
