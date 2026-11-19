#!/bin/sh
# Overlays on the Commander X16: tests/overlay/*.p8 are built with p8c (a loader, and a
# file with the main program and the overlays in it) and run in x16emu from the
# directory they were built in, as 65C02 code and as 65816 code (x16emu -c816 runs
# both); what they print is printed.  overlays.p8 is also built
# for the C64, which has no overlays: one program.
# The Makefile compares with tests/expected/overlaycheck.txt.
#
# Usage: tests/overlaycheck.sh <p8c>         (needs 64tass and x16emu in the path)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
seconds=${OVERLAYCHECK_SECONDS:-8}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_overlay.XXXXXX")
trap 'rm -rf "$work"' EXIT

for cpu in 65c02 65816; do
    for program in overlays banks words; do
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
        kill $emulator 2> /dev/null
        wait $emulator 2> /dev/null
        tr -d '\000\r' < "$work/$program/screen.txt" | sed 's/\\X[0-9A-F][0-9A-F]//g' \
            | grep -a '^[A-Z0-9-][A-Z0-9 -]*$' | grep -a -v '^LOADING\|^READY\|^RUN'
    done
done
echo "-- overlays, for a machine without them (c64): one program"
mkdir -p "$work/flat"
"$p8c" -lib "$lib" -target c64 -out "$work/flat" tests/overlay/overlays.p8 || exit 1
ls "$work/flat" | grep -E '\.(prg|non)$'
