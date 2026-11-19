#!/bin/sh
# Addresses of more than 16 bits.  First tried by hand in assembly: tests/far/modes816.p8 on a Commander X16 with a 65816
# (x16emu -c816) and on a C64 with a SuperCPU and 16 MB (VICE's xscpu64), and
# tests/far/modes45.p8 on the MEGA65 (xmega65).  Then tests/far/fardata.p8 and
# farcomputed.p8, where the compiler writes the code (memory mapped variables and arrays,
# @(), peek and poke at far addresses that are constants, and at ones the program works
# out), on the two machines that have far memory.  Prints what each program shows; the
# Makefile compares with tests/expected/farcheck.txt.  A machine whose emulator is not
# installed is left out with a line that says so.
#
# Usage: tests/farcheck.sh <p8c>
p8c=$1
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_farcheck.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/x16" "$work/c64" "$work/m65"
wait_for() {
    # wait_for <seconds> <file>: until the file has something in it
    n=0
    while [ $n -lt $(($1 * 5)) ] && [ ! -s "$2" ]; do
        sleep 0.2
        n=$((n + 1))
    done
}
echo "-- Commander X16, 65816"
if command -v x16emu > /dev/null; then
    "$p8c" -lib "$lib" -target cx16 -cpu 65816 -out "$work/x16" tests/far/modes816.p8 || exit 1
    (cd "$work/x16" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy exec x16emu -c816 -prg modes816.prg -run -warp -echo iso \
        > echo.txt 2>&1 < /dev/null) &
    emulator=$!
    n=0
    while [ $n -lt 100 ] && ! tr -d '\000\r' < "$work/x16/echo.txt" 2> /dev/null | grep -q 'BANK 2 IS'; do
        sleep 0.2
        n=$((n + 1))
    done
    pkill -P $emulator 2> /dev/null
    kill $emulator 2> /dev/null
    wait $emulator 2> /dev/null
    tr -d '\000\r' < "$work/x16/echo.txt" | sed 's/^.*\(LONG  \)/\1/' | grep -E '^(LONG|\[DP\]|BANK)'
else
    echo "(no x16emu)"
fi
echo "-- C64, SuperCPU"
if command -v xscpu64 > /dev/null; then
    "$p8c" -lib "$lib" -target c64 -cpu 65816 -out "$work/c64" tests/far/modes816.p8 || exit 1
    address=$(awk '$3 == ".p8_sys_startup:cleanup_at_exit" { print $2 }' "$work/c64/modes816.vice-mon-list")
    printf 'break %s\ncommand 1 "bsave \\"screen.bin\\" 0 0400 07e7"\n' "$address" > "$work/c64/mon.txt"
    (cd "$work/c64" && exec xscpu64 -simmsize 16 -console -warp -limitcycles 200000000 -moncommands mon.txt \
        -autostartprgmode 1 -autostart modes816.prg > vice.log 2>&1 < /dev/null) &
    emulator=$!
    wait_for 60 "$work/c64/screen.bin"
    kill $emulator 2> /dev/null
    wait $emulator 2> /dev/null
    # the screen codes as text
    python3 - "$work/c64/screen.bin" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
for row in range(0, len(data), 40):
    line = ''.join(chr((c & 0x7f) + 0x40) if (c & 0x7f) < 0x20 else chr(c & 0x7f) for c in data[row:row + 40]).rstrip()
    if line.startswith(('LONG', '[DP]', 'BANK')):
        print(line)
PY
    for program in fardata farcomputed; do
        echo "-- C64, SuperCPU: $program, where the compiler writes the code"
        "$p8c" -lib "$lib" -target c64 -cpu 65816 -out "$work/c64" tests/far/$program.p8 || exit 1
        address=$(awk '$3 == ".p8_sys_startup:cleanup_at_exit" { print $2 }' "$work/c64/$program.vice-mon-list")
        printf 'break %s\ncommand 1 "bsave \\"screen.bin\\" 0 0400 07e7"\n' "$address" > "$work/c64/mon.txt"
        rm -f "$work/c64/screen.bin"
        (cd "$work/c64" && exec xscpu64 -simmsize 16 -console -warp -limitcycles 200000000 -moncommands mon.txt \
            -autostartprgmode 1 -autostart $program.prg > vice.log 2>&1 < /dev/null) &
        emulator=$!
        wait_for 60 "$work/c64/screen.bin"
        kill $emulator 2> /dev/null
        wait $emulator 2> /dev/null
        python3 - "$work/c64/screen.bin" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
for row in range(0, len(data), 40):
    line = ''.join(chr((c & 0x7f) + 0x40) if (c & 0x7f) < 0x20 else chr(c & 0x7f) for c in data[row:row + 40]).rstrip()
    if line and (line[0].isdigit() or line[0] == '$'):
        print(line)
PY
    done
else
    echo "(no xscpu64)"
fi
echo "-- MEGA65"
if command -v xmega65 > /dev/null; then
    "$p8c" -lib "$lib" -target mega65 -out "$work/m65" tests/far/modes45.p8 || exit 1
    (cd "$work/m65" && timeout 60 xmega65 -headless -sleepless -besure -prg modes45.prg -prgexit -dumpscreen screen.txt \
        > log.txt 2>&1 < /dev/null)
    grep -E '^(\[ZP\]|LDQ|ATTIC|BANK)' "$work/m65/screen.txt"
    for program in fardata farcomputed; do
        echo "-- MEGA65: $program, where the compiler writes the code"
        "$p8c" -lib "$lib" -target mega65 -out "$work/m65" tests/far/$program.p8 || exit 1
        (cd "$work/m65" && rm -f screen.txt && timeout 60 xmega65 -headless -sleepless -besure -prg $program.prg -prgexit -dumpscreen screen.txt \
            > log.txt 2>&1 < /dev/null)
        sed -n '/ RUN:/,$p' "$work/m65/screen.txt" | grep '^[0-9$]'
    done
else
    echo "(no xmega65)"
fi
exit 0
