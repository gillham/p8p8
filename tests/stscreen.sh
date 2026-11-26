#!/bin/sh
# The Atari ST's text screen (textio on the VT-52 console): tests/atarist/screen.p8 is
# run in Hatari in each of the three resolutions, and what is in the screen's memory
# when it ends is printed as text (tools/stscreen.py), with the places that are not
# in the usual colours.  make stscreen compares that with tests/expected/stscreen.txt.
#
# Usage: tests/stscreen.sh <p8c>      (see tests/strun.sh for what it needs)
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_stscreen.XXXXXX")
trap 'rm -rf "$work"' EXIT
"$p8c" -lib "$lib" -target atarist -out "$work" "$here/atarist/screen.p8" > "$work/err" 2>&1 || { cat "$work/err"; exit 1; }
echo "== low resolution"
ST_SCREEN="$work/screen.bin" "$here/strun.sh" "$work/screen.tos" --monitor rgb --tos-res low > /dev/null
python3 "$here/../tools/stscreen.py" "$work/screen.bin" 0
echo "== medium resolution"
ST_SCREEN="$work/screen.bin" "$here/strun.sh" "$work/screen.tos" --monitor rgb --tos-res med > /dev/null
python3 "$here/../tools/stscreen.py" "$work/screen.bin" 1
echo "== high resolution"
ST_SCREEN="$work/screen.bin" "$here/strun.sh" "$work/screen.tos" --monitor mono > /dev/null
python3 "$here/../tools/stscreen.py" "$work/screen.bin" 2
