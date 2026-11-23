#!/bin/sh
# Runs a Color Computer program (a DECB .bin) in the emulator XRoar, unattended, and
# prints what the program printed.  The program must be built with
# tests/m6809/xroar-coco2.properties: it then ends at a fixed address, where XRoar
# is told to write a snapshot and stop, and what it printed is in memory from $5000
# on, where this script reads it from the snapshot.  XRoar needs the machine's ROMs.
# COCO_MACHINE is XRoar's machine (default coco2bus); XROAR names the emulator when it
# is not "xroar" in the path (xroar-dev takes the same options).  It runs as fast as
# the host can, without a window or sound.
#
# Usage: tests/cocorun.sh <program.bin>      (the exit status is 124 when it did not end)
dir=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_coco.XXXXXX")
trap 'rm -rf "$dir"' EXIT
cp "$1" "$dir/prog.bin" || exit 2
# (3586 is $0e02, the program's place to end at; XRoar takes the address in decimal)
(cd "$dir" && timeout "${COCO_TIMEOUT:-120}" "${XROAR:-xroar}" -q -ui null -ao null -no-ratelimit -machine "${COCO_MACHINE:-coco2bus}" \
    -run prog.bin -trap pc=3586 -trap-snap snap.sna -trap-timeout 1 -timeout "${COCO_SECONDS:-300}" \
    < /dev/null > /dev/null 2>&1)
[ -f "$dir/snap.sna" ] || exit 124
python3 - "$dir/snap.sna" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
# the program's mark is at $0e04 of the machine's memory
at = d.find(b'P8P8TEST')
if at < 0:
    sys.exit(124)
base = at - 0x0e04
end = d[base + 0x4ffe] * 256 + d[base + 0x4fff]
sys.stdout.buffer.write(d[base + 0x5000:base + end])
PY
