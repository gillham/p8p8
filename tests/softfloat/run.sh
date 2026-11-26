#!/bin/sh
# The float routines of the 68000 machines (lib/common/m68k_softfloat.asm) against
# Python's arithmetic: some 17000 operations with random operands, run as an Atari ST
# program in Hatari (tests/strun.sh), every result compared bit for bit.
#
# Usage: tests/softfloat/run.sh      (needs python3, vasmm68k_mot and hatari)
here=$(cd "$(dirname "$0")" && pwd)
lib=${P8P8_LIB:-$here/../../lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_softfloat.XXXXXX")
trap 'rm -rf "$work"' EXIT
python3 "$here/vectors.py" make "$work" || exit 1
vasmm68k_mot -m68000 -Ftos -quiet -I "$work" -I "$lib/common" -o "$work/t.tos" "$here/driver.s" || exit 1
ST_TIME=120 "$here/../strun.sh" "$work/t.tos" | tr -d '\r' | awk 'started || $0 != "" { started = 1; print }' > "$work/got.txt"
python3 "$here/vectors.py" check "$work" "$work/got.txt"
