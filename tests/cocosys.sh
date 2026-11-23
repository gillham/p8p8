#!/bin/sh
# The file routines of the coco2 target (diskio: Disk BASIC's files through its sector
# routine), run in XRoar with a disk image: tests/cocosys/files.p8 writes, reads,
# renames and deletes files and reads one that toolshed's decb put on the disk.  What it
# prints is compared with tests/cocosys/expected.txt; then decb reads the disk: its
# directory, and the files' bytes.  Then tests/cocosys/upper.p8: the upper 32 KB as data
# (the highram module), on a Color Computer 2 with 64 KB and with 32 KB and on XRoar's
# Dragon 64 and Dragon 32.  Then tests/cocosys/lists.p8 (the place in a file, lists of
# files, a second drive) and tests/cocosys/blocks.p8 (the Color Computer 3's memory
# beyond its 64 KB), each with an expected file of its own.
#
# Usage: tests/cocosys.sh <p8c>      (needs lwasm, XRoar with the Color Computers', the
#                                     Dragons' and Disk BASIC's ROMs, and decb of toolshed)
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
    # the upper 32 KB as data (highram): with 64 KB, with 32 KB, and on the Dragons
    "$p8c" -lib "$lib" -srcdirs "$lib/targets/coco2" -target "$here/m6809/xroar-coco2.properties" -out "$work" "$here/cocosys/upper.p8" > "$work/upper.log" 2>&1 &&
        "$here/cocorun.sh" "$work/upper.bin" && COCO_OPTIONS="-ram 32" "$here/cocorun.sh" "$work/upper.bin"
    mkdir "$work/dragon"
    "$p8c" -lib "$lib" -srcdirs "$lib/targets/dragon32" -target "$here/m6809/xroar-dragon32.properties" -out "$work/dragon" "$here/cocosys/upper.p8" > "$work/upper.log" 2>&1 &&
        COCO_MACHINE=dragon64 "$here/cocorun.sh" "$work/dragon/upper.bin" && COCO_MACHINE=dragon32 "$here/cocorun.sh" "$work/dragon/upper.bin"
    # the coco2ram target (the program with the ROMs switched out): the clock and the
    # memory where the ROMs were, and the files again, through the ROM's sector routine
    mkdir "$work/ram"
    "$p8c" -lib "$lib" -srcdirs "$lib/targets/coco2ram" -target "$here/m6809/xroar-coco2ram.properties" -out "$work/ram" "$here/cocosys/romsout.p8" > "$work/ram.log" 2>&1 &&
        "$here/cocorun.sh" "$work/ram/romsout.bin"
    decb dskini "$work/r.dsk" > /dev/null
    decb copy -1 -a "$work/host.txt" "$work/r.dsk,HOST.TXT" > /dev/null
    "$p8c" -lib "$lib" -srcdirs "$lib/targets/coco2ram" -target "$here/m6809/xroar-coco2ram.properties" -out "$work/ram" "$here/cocosys/files.p8" > "$work/ram.log" 2>&1 &&
        COCO_OPTIONS="-load-fd0 $work/r.dsk" "$here/cocorun.sh" "$work/ram/files.bin"
} > "$work/printed.txt" 2>&1
diff -u "$here/cocosys/expected.txt" "$work/printed.txt" || exit 1
# tests/cocosys/lists.p8: the place in a file, the files of a disk listed, a second
# drive; with the disks that the files program left (in drive 0) and a disk with two
# files in drive 1, as the coco2 and as the coco2ram target
{
    for target in coco2 coco2ram; do
        mkdir "$work/l$target"
        printf '10 PRINT "ONE"\r' > "$work/one.bas"
        decb dskini "$work/u.dsk" > /dev/null
        decb copy -0 -a "$work/one.bas" "$work/u.dsk,ONE.BAS" > /dev/null
        decb copy -1 -a "$work/host.txt" "$work/u.dsk,BOARD.DAT" > /dev/null
        first=$work/t.dsk
        [ $target = coco2ram ] && first=$work/r.dsk
        "$p8c" -lib "$lib" -srcdirs "$lib/targets/$target" -target "$here/m6809/xroar-$target.properties" -out "$work/l$target" "$here/cocosys/lists.p8" > "$work/lists.log" 2>&1 &&
            COCO_OPTIONS="-load-fd0 $first -load-fd1 $work/u.dsk" "$here/cocorun.sh" "$work/l$target/lists.bin"
        decb dir "$work/u.dsk," | grep -v '^Directory' | grep -v '^$' | tr -s ' '
    done
} > "$work/lists.txt" 2>&1
diff -u "$here/cocosys/expected_lists.txt" "$work/lists.txt" || exit 1
# tests/cocosys/blocks.p8: the Color Computer 3's memory beyond its 64 KB as data (the
# coco3 target's highram), with 128 KB and with 512 KB
{
    mkdir "$work/blocks"
    "$p8c" -lib "$lib" -srcdirs "$lib/targets/coco3" -target "$here/m6809/xroar-coco3.properties" -out "$work/blocks" "$here/cocosys/blocks.p8" > "$work/blocks.log" 2>&1 &&
        COCO_MACHINE=coco3 COCO_OPTIONS="-ram 128" "$here/cocorun.sh" "$work/blocks/blocks.bin" &&
        COCO_MACHINE=coco3 COCO_OPTIONS="-ram 512" "$here/cocorun.sh" "$work/blocks/blocks.bin"
} > "$work/blocks.txt" 2>&1
if diff -u "$here/cocosys/expected_blocks.txt" "$work/blocks.txt"; then
    echo "files on the Color Computer: as expected"
else
    exit 1
fi
