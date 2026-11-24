#!/bin/sh
# The system calls of the TRS-80 targets beyond the console: the command line and the
# directory (tests/trs80sys/args.p8) and files (tests/trs80sys/files.p8), run in trs80gp
# on the Model I and III with TRSDOS, the Model III with LDOS and the Model 4.  What
# they print is compared with tests/trs80sys/expected.txt.  On the Model 4 also the
# clock (tests/trs80sys/clock.p8, expected_m4.txt).
# (The Model I with LDOS is left out: trs80gp's boot disk for it has no room for a file.)
#
# Usage: tests/trs80sys.sh <p8c>      (needs z88dk and trs80gp: Z88DK, TRS80GP)
p8c=$1
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_trs80sys.XXXXXX")
trap 'rm -rf "$work"' EXIT
bad=0
for machine in "-m1" "-m3" "-m3 -ld" "-m4"; do
    target=trs80; variant=trs80gp
    [ "$machine" = -m4 ] && target=trs80m4 && variant=trs80gp-m4
    rm -rf "$work/o"; mkdir "$work/o"
    : > "$work/printed.txt"
    for name in args files; do
        if ! "$p8c" -lib "$lib" -srcdirs "$lib/targets/$target" -target "$here/z80/$variant.properties" \
                -out "$work/o" "$here/trs80sys/$name.p8" > "$work/o/$name.log" 2>&1; then
            echo "not built for $machine: $name: $(grep -v warning "$work/o/$name.log" | head -1)"; bad=1; continue
        fi
        TRS80_MODEL="$machine" "$here/trs80run.sh" "$work/o/$name.cmd" | tr -d '\r' >> "$work/printed.txt"
    done
    if diff -u "$here/trs80sys/expected.txt" "$work/printed.txt" > "$work/diff.txt"; then
        echo "ok: system calls on the TRS-80 ($machine)"
    else
        echo "WRONG on $machine:"; head -12 "$work/diff.txt"; bad=1
    fi
    # the Model 4 has a clock (tests/trs80sys/clock.p8)
    if [ "$machine" = -m4 ]; then
        "$p8c" -lib "$lib" -srcdirs "$lib/targets/$target" -target "$here/z80/$variant.properties" \
                -out "$work/o" "$here/trs80sys/clock.p8" > "$work/o/clock.log" 2>&1 &&
            TRS80_MODEL="$machine" "$here/trs80run.sh" "$work/o/clock.cmd" | tr -d '\r' > "$work/clock.txt"
        if diff -u "$here/trs80sys/expected_m4.txt" "$work/clock.txt" > "$work/diff.txt"; then
            echo "ok: the clock on the TRS-80 ($machine)"
        else
            echo "WRONG on $machine (the clock):"; head -12 "$work/diff.txt"; bad=1
        fi
    fi
done
exit $bad
