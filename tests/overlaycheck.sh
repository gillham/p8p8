#!/bin/sh
# Overlays on the Commander X16: tests/overlay/*.p8 are built with p8c (a loader, and a
# file with the main program and the overlays in it) and run in x16emu from the
# directory they were built in, as 65C02 code and as 65816 code (x16emu -c816 runs
# both); what they print is printed.  Then two of them for the C64 and the C128, where
# the overlays are in a RAM Expansion Unit (x64sc and x128 with one, the directory as
# drive 8), and for the MEGA65, where they are in far memory (xmega65, the file on a
# disk image).  overlays.p8 is also built for the PET, which has no overlays: one program.
# The Makefile compares with tests/expected/overlaycheck.txt.
#
# Usage: tests/overlaycheck.sh <p8c>         (needs 64tass, x16emu, x64sc, x128, xmega65 and c1541 in the path)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
seconds=${OVERLAYCHECK_SECONDS:-8}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_overlay.XXXXXX")
trap 'rm -rf "$work"' EXIT

for cpu in 65c02 65816; do
    for program in overlays banks words subs listed; do
        echo "-- $program, $cpu"
        rm -rf "$work/$program"
        mkdir -p "$work/$program"
        "$p8c" -lib "$lib" -target cx16 -cpu $cpu -out "$work/$program" tests/overlay/$program.p8 || exit 1
        ls "$work/$program" | grep -E '\.(prg|non)$'
        (cd "$work/$program" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy x16emu -c816 -prg $program.prg -run -warp -echo iso \
            > screen.txt 2>&1 < /dev/null) &
        emulator=$!
        n=0
        while [ $n -lt "$seconds" ]; do n=$((n + 1)); /bin/sleep 1; done
        pkill -P $emulator 2> /dev/null     # (an emulator that is started by a script of its own)
        kill $emulator 2> /dev/null
        wait $emulator 2> /dev/null
        tr -d '\000\r' < "$work/$program/screen.txt" | sed 's/\\X[0-9A-F][0-9A-F]//g' \
            | grep -a '^[A-Z0-9-][A-Z0-9 -]*$' | grep -a -v '^LOADING\|^READY\|^RUN'
    done
done
# the C64 and the C128: overlays in a RAM Expansion Unit, the directory as drive 8
for machine in c64 c128; do
    emulator_name=x64sc
    [ $machine = c128 ] && emulator_name=x128
    for program in overlays words subs listed; do
        echo "-- $program, $machine with an REU"
        rm -rf "$work/$program"
        mkdir -p "$work/$program"
        "$p8c" -lib "$lib" -target $machine -out "$work/$program" tests/overlay/$program.p8 || exit 1
        ls "$work/$program" | grep -E '\.(prg|non)$'
        address=$(awk '$3 == ".p8_sys_startup:cleanup_at_exit" { print $2 }' "$work/$program/$program.vice-mon-list")
        printf 'break %s\ncommand 1 "bsave \\"screen.bin\\" 0 0400 07e7"\n' "$address" > "$work/$program/mon.txt"
        (cd "$work/$program" && exec $emulator_name -console -warp -reu -reusize 512 -devicebackend8 1 -fs8 "$PWD" \
            +drive8truedrive -trapdevice8 -limitcycles 600000000 -moncommands mon.txt \
            -autostartprgmode 1 -autostart $program.prg > vice.log 2>&1 < /dev/null) &
        emulator=$!
        n=0
        while [ $n -lt 60 ] && [ ! -s "$work/$program/screen.bin" ]; do n=$((n + 1)); /bin/sleep 1; done
        pkill -P $emulator 2> /dev/null     # (an emulator that is started by a script of its own)
        kill $emulator 2> /dev/null
        wait $emulator 2> /dev/null
        python3 - "$work/$program/screen.bin" <<'PY'
import os, sys
if not os.path.exists(sys.argv[1]):
    print("(the program did not end)")
    sys.exit(0)
data = open(sys.argv[1], 'rb').read()
for row in range(0, len(data), 40):
    line = ''.join(chr((c & 0x7f) + 0x40) if (c & 0x7f) < 0x20 else chr(c & 0x7f) for c in data[row:row + 40]).rstrip()
    if line and (line[0].isdigit() or line.startswith(('MAIN', 'HELLO', 'LISTED', '?'))):
        print(line)
PY
    done
done
# the MEGA65: overlays in memory beyond 64 KB, brought in by DMA; the file on a disk image
for cpu in 45gs02 6502; do
    for program in overlays words subs listed; do
        echo "-- $program, mega65, $cpu"
        rm -rf "$work/$program"
        mkdir -p "$work/$program"
        "$p8c" -lib "$lib" -target mega65 -cpu $cpu -out "$work/$program" tests/overlay/$program.p8 || exit 1
        ls "$work/$program" | grep -E '\.(prg|non)$'
        (cd "$work/$program" && c1541 -format "overlays,p8" d81 disk.d81 -write $program.non $program.non > c1541.log 2>&1 \
            && timeout 90 xmega65 -headless -sleepless -besure -8 disk.d81 -prg $program.prg -prgexit -dumpscreen screen.txt \
            > run.log 2>&1 < /dev/null)
        sed -n '/ RUN:/,$p' "$work/$program/screen.txt" | grep '^[0-9MHL?]'
    done
done
# the GameTank: overlays are banks of the cartridge, and p8c writes the whole of it.
# (No emulator is run here: which banks hold something, the data that is in one of
# them beside its code, and where the machine starts.)
echo "-- cartridge, gametank: the banks of the cartridge"
mkdir -p "$work/gt"
"$p8c" -lib "$lib" -target gametank -varsgolden -out "$work/gt" tests/overlay/cartridge.p8 || exit 1
ls "$work/gt" | grep -E '\.(gtr|bin|non)$'
python3 - "$work/gt/cartridge.gtr" <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
print(len(data), "bytes")
for bank in range(128, 256):
    part = data[(bank - 128) * 0x4000:(bank - 127) * 0x4000]
    if part.strip(b'\xff').strip(b'\x00'):
        print("bank", bank, "has something in it")
print("bank 129 begins with", data[0x4000:0x4004].hex())
print("the reset vector is", hex(data[-4] | data[-3] << 8))
PY
echo "-- overlays, for the X16 with -nooverlays: one program"
mkdir -p "$work/off"
"$p8c" -lib "$lib" -target cx16 -nooverlays -out "$work/off" tests/overlay/overlays.p8 || exit 1
ls "$work/off" | grep -E '\.(prg|non)$'
(cd "$work/off" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy x16emu -prg overlays.prg -run -warp -echo iso \
    > screen.txt 2>&1 < /dev/null) &
emulator=$!
n=0
while [ $n -lt "$seconds" ]; do n=$((n + 1)); /bin/sleep 1; done
pkill -P $emulator 2> /dev/null
kill $emulator 2> /dev/null
wait $emulator 2> /dev/null
tr -d '\000\r' < "$work/off/screen.txt" | sed 's/\\X[0-9A-F][0-9A-F]//g' \
    | grep -a '^[A-Z0-9-][A-Z0-9 -]*$' | grep -a -v '^LOADING\|^READY\|^RUN'
echo "-- overlays, for a machine without them (pet32): one program"
mkdir -p "$work/flat"
"$p8c" -lib "$lib" -target pet32 -out "$work/flat" tests/overlay/overlays.p8 || exit 1
ls "$work/flat" | grep -E '\.(prg|non)$'
