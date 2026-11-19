#!/bin/sh
# The 45GS02, on the MEGA65.  No other compiler writes code for that CPU, so the
# reference is p8p8's own 6502 code for the same machine (which the other suites
# compare with the reference compiler's on the C64 and the X16): each program is built
# for the mega65 target with -cpu 6502 and as 45GS02 code (the target's CPU), both run in xmega65 (Xemu)
# without a window, and the text screens they leave are compared.
#
# Usage: tests/emucmp65.sh <p8c> <file.p8>...
# Needs 64tass and xmega65 in the path.  EMUCMP65_SECONDS: how long a program may run (20).
p8c=$1
shift
lib=${P8P8_LIB:-lib}
seconds=${EMUCMP65_SECONDS:-20}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_emucmp65.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/6502" "$work/45gs02"
run() {
    # the screen from the line of the RUN on, when the program has come back to BASIC
    (cd "$1" && timeout "$seconds" xmega65 -headless -sleepless -besure -prg "$2.prg" -prgexit \
        -dumpscreen "$2.scr" > "$2.log" 2>&1 < /dev/null)
    if [ -f "$1/$2.scr" ]; then
        # (without the cursor, which is in the dump or not as it happens to blink)
        sed -n '/ RUN:/,$p' "$1/$2.scr" | sed 's/{\$A0}//g' | grep -v '^ *$' > "$1/$2.out"
    else
        echo "(no screen: the program did not come back)" > "$1/$2.out"
    fi
}
total=0
failed=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    rm -f "$work/6502/$name.prg" "$work/45gs02/$name.prg"
    if ! "$p8c" -target mega65 -D "prog8_exit_noreset:=1" -lib "$lib" -cpu 6502 -out "$work/6502" "$f" > "$work/6502.err" 2>&1 || [ ! -f "$work/6502/$name.prg" ]; then
        echo "skipped (not a program for the mega65): $f"
        continue
    fi
    total=$((total + 1))
    if ! "$p8c" -target mega65 -D "prog8_exit_noreset:=1" -lib "$lib" -cpu 45gs02 -out "$work/45gs02" "$f" > "$work/45.err" 2>&1 || [ ! -f "$work/45gs02/$name.prg" ]; then
        echo "failed (no 45GS02 program): $f"
        grep -v '^$' "$work/45.err" | head -4 | cut -c1-200
        failed=$((failed + 1))
        continue
    fi
    run "$work/6502" "$name"
    run "$work/45gs02" "$name"
    if [ "$(grep -vc '^ *$' "$work/6502/$name.out")" -le 2 ]; then
        echo "skipped (the 6502 program prints nothing here): $f"
        total=$((total - 1))
    elif cmp -s "$work/6502/$name.out" "$work/45gs02/$name.out"; then
        echo "ok: $f ($(wc -c < "$work/6502/$name.prg" | tr -d ' ') and $(wc -c < "$work/45gs02/$name.prg" | tr -d ' ') bytes)"
    else
        echo "failed (output differs): $f"
        diff "$work/6502/$name.out" "$work/45gs02/$name.out" | head -8 | cut -c1-160
        failed=$((failed + 1))
    fi
done
echo "emulator comparison (mega65, 6502 code against 45GS02 code): $total programs, $failed failed"
[ $failed -eq 0 ]
