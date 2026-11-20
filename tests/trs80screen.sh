#!/bin/sh
# The screen routines of the TRS-80 targets (tests/z80screen/screen.p8) on a Model I, a
# Model III and a Model 4 in trs80gp: each must print "X 10 5 ok".
#
# Usage: tests/trs80screen.sh <p8c>      (needs z88dk and trs80gp: Z88DK, TRS80GP)
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_trs80screen.XXXXXX")
trap 'rm -rf "$work"' EXIT
bad=0
for model in -m1 -m3 -m4; do
    target=trs80; variant=trs80gp
    [ "$model" = -m4 ] && target=trs80m4 && variant=trs80gp-m4
    if ! "$p8c" -lib "$lib" -srcdirs "$lib/targets/$target" -target "$here/z80/$variant.properties" \
            -out "$work" "$here/z80screen/screen.p8" > "$work/build.log" 2>&1; then
        echo "not built for $model: $(grep -v warning "$work/build.log" | head -1)"; bad=1; continue
    fi
    printed=$(TRS80_MODEL=$model "$here/trs80run.sh" "$work/screen.cmd" | tr -d '\r')
    if [ "$printed" = "X 10 5 ok" ]; then
        echo "ok: the screen routines on $model"
    else
        echo "WRONG on $model: $printed"; bad=1
    fi
done
exit $bad
