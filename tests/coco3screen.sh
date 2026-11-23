#!/bin/sh
# The Color Computer 3's 80 column screen (the coco3 target's textio), in XRoar:
# tests/coco3/screen.p8 writes to it, and what is in the screen's memory afterwards
# (block $36 of the machine's memory, out of XRoar's snapshot) is compared with
# tests/coco3/screen.txt.
#
# Usage: tests/coco3screen.sh <p8c>      (needs lwasm, and XRoar with the Color Computer 3's ROM)
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_coco3.XXXXXX")
trap 'rm -rf "$work"' EXIT
if ! "$p8c" -lib "$lib" -srcdirs "$lib/targets/coco3" -target "$here/m6809/xroar-coco3.properties" -out "$work" "$here/coco3/screen.p8" > "$work/screen.log" 2>&1; then
    echo "not built: screen: $(grep -v warning "$work/screen.log" | head -1)"; exit 1
fi
# (3586 is $0e02, where the tests' variant of the target ends)
(cd "$work" && timeout 120 "${XROAR:-xroar}" -q -ui null -ao null -no-ratelimit -machine coco3 \
    -run screen.bin -trap pc=3586 -trap-snap snap.sna -trap-timeout 1 -timeout 300 < /dev/null > /dev/null 2>&1)
[ -f "$work/snap.sna" ] || { echo "the program did not end"; exit 1; }
python3 - "$work/snap.sna" > "$work/screen.txt" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
# the program's mark is at $0e04 of block $38, which is at $70000 of the machine's memory
at = d.find(b'P8P8TEST')
if at < 0:
    sys.exit(1)
base = at - 0x70e04
screen = d[base + 0x6c000:base + 0x6c000 + 80 * 24 * 2]
for row in range(24):
    cells = screen[row * 160:row * 160 + 160:2]
    print(''.join(chr(c) if 32 <= c < 127 else '?' for c in cells).rstrip())
PY
if diff -u "$here/coco3/screen.txt" "$work/screen.txt"; then
    echo "the Color Computer 3's 80 column screen: as expected"
else
    exit 1
fi
