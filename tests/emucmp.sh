#!/bin/sh
# The 8-bit oracle.  Each program is built twice: by prog8c-llvm -newcodegen
# from source, and by p8p8 to IR which prog8c-llvm then turns into a
# program.  Both run headless in an emulator and what they print is compared.
#
# cx16 (the default): x16emu with the KERNAL output echoed.  The emulator is
# stopped when the program has come back to BASIC; a program that never does
# is stopped after a few seconds, which is fine as long as both builds were
# given the same time.
#
# c64 (EMUCMP_TARGET=c64): VICE's x64sc.  A breakpoint at the exit routine of
# the program saves the text screen, and those 1000 bytes are compared.  A
# program that does not end is stopped after a number of cycles and its
# last frame is compared instead.
#
# EMUCMP_CODEGEN=own builds p8p8's side with its own 6502 code generator and 64tass
# instead of having prog8c-llvm finish p8p8's IR; the reference is then the default
# code generator's build, not the IR back end's.
#
# Usage: tests/emucmp.sh <p8p8> <reference dir> <file.p8>...
# Needs 64tass and x16emu or x64sc in the path.
p8p8=$1
ref=$2
shift 2
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_emucmp.$$
seconds=${EMUCMP_SECONDS:-8}
target=${EMUCMP_TARGET:-cx16}
codegen=${EMUCMP_CODEGEN:-upstream}
# EMUCMP_CPU=65816: p8p8 writes code for that CPU (-cpu 65816), and both programs run on
# it: x16emu -c816, or VICE's xscpu64 (a C64 with a SuperCPU)
cpu=${EMUCMP_CPU:-}
cpuopt=
x16cpu=
vice=x64sc
if [ "$cpu" = 65816 ]; then
    cpuopt="-cpu 65816"
    x16cpu=-c816
    vice=xscpu64
fi
cycles=${EMUCMP_CYCLES:-200000000}
mkdir -p "$work/up" "$work/p8"
failed=0
total=0
run_cx16() {
    # The program's output, without the emulator's own lines.  The emulator does not end
    # when the program does: it is stopped when BASIC has said READY. again, or after
    # the seconds a program gets that never comes back.  (EMUCMP_WAIT=1: always the
    # full time, as it was.)
    : > "$1/$2.echo"
    (cd "$1" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy exec x16emu $x16cpu -prg "$2.prg" -run -warp -echo iso \
        > "$2.echo" 2>&1 < /dev/null) &
    emulator=$!
    ticks=0
    while kill -0 $emulator 2> /dev/null && [ $ticks -lt $((seconds * 5)) ]; do
        if [ -z "$EMUCMP_WAIT" ] && [ "$(tr -d '\000\r' < "$1/$2.echo" | grep -v '^$' | tail -1)" = "READY." ]; then
            break
        fi
        sleep 0.2
        ticks=$((ticks + 1))
    done
    # (x16emu may be a script that starts the emulator: that one first)
    pkill -P $emulator 2> /dev/null
    kill $emulator 2> /dev/null
    wait $emulator 2> /dev/null
    grep -v '^SMC Power Off' "$1/$2.echo" > "$1/$2.out"
}
screen_saved() {
    [ -f "$1" ] && [ "$(wc -c < "$1" | tr -d ' ')" = 1000 ]
}
run_c64() {
    exit_address=$(awk '$3 == ".p8_sys_startup:cleanup_at_exit" { print $2 }' "$1/$2.vice-mon-list")
    rm -f "$1/screen.bin" "$1/screen.png"
    : > "$1/mon.txt"
    if [ -n "$exit_address" ]; then
        printf 'break %s\ncommand 1 "bsave \\"screen.bin\\" 0 0400 07e7"\n' "$exit_address" > "$1/mon.txt"
    fi
    (cd "$1" && exec $vice -console -warp -limitcycles "$cycles" -exitscreenshot screen.png -moncommands mon.txt \
        -autostartprgmode 1 -autostart "$2.prg" > vice.log 2>&1 < /dev/null) &
    emulator=$!
    # the monitor stays open after the breakpoint: wait for the screen, then stop the emulator
    while kill -0 $emulator 2> /dev/null && ! screen_saved "$1/screen.bin"; do
        sleep 0.2
    done
    kill $emulator 2> /dev/null
    wait $emulator 2> /dev/null
    if [ -f "$1/screen.bin" ]; then
        mv "$1/screen.bin" "$1/$2.out"
    else
        mv "$1/screen.png" "$1/$2.out"
    fi
}
run() {
    # run <dir> <name>: leaves what the program showed in <dir>/<name>.out
    run_$target "$1" "$2"
}
for f in "$@"; do
    name=$(basename "$f" .p8)
    if [ "$codegen" = own ] && [ "$name" = builtins ]; then
        # it prints sys.read_flags(), the status register, which depends on the instructions
        # a code generator happens to write; and it rotates a byte at $c000, which is ROM on
        # the cx16: the default code generator prints the value it still has in A
        echo "skipped (it prints the status flags): $f"
        continue
    fi
    # the reference: upstream's IR back end, or for p8p8's own generator the default code generator
    refopt=-newcodegen
    [ "$codegen" = own ] && refopt=
    if ! prog8c-llvm -target $target $refopt -quiet -out "$work/up" "$f" > "$work/up.err" 2>&1 || [ ! -f "$work/up/$name.prg" ]; then
        echo "skipped (upstream does not build it): $f"
        continue
    fi
    total=$((total + 1))
    rm -f "$work/p8/$name.prg"
    if [ "$codegen" = own ]; then
        # p8p8's own 6502 code generator, and 64tass
        if ! "$p8p8" -target $target -lib "$lib" $cpuopt -codegen own -out "$work/p8" -build "$f" > "$work/p8.err" 2>&1 || [ ! -f "$work/p8/$name.prg" ]; then
            echo "failed (p8p8 does not build it): $f"
            sed 's/\x1b\[[0-9;]*m//g' "$work/p8.err" | grep -v '^$' | sort | uniq -c | sort -rn | head -4 | cut -c1-200
            failed=$((failed + 1))
            continue
        fi
    else
        if ! "$p8p8" -target $target -lib "$lib" -ir -out "$work/p8" "$f" > "$work/p8.err" 2>&1; then
            echo "failed (p8p8 rejects): $f"
            head -3 "$work/p8.err"
            failed=$((failed + 1))
            continue
        fi
        prog8c-llvm -target $target -quiet -out "$work/p8" "$work/p8/$name.p8ir" > "$work/asm.err" 2>&1
        if [ ! -f "$work/p8/$name.prg" ]; then
            echo "failed (p8p8's IR does not build): $f"
            sed 's/\x1b\[[0-9;]*m//g' "$work/asm.err" | grep -i 'error' | head -3 | cut -c1-200
            failed=$((failed + 1))
            continue
        fi
    fi
    run "$work/up" "$name"
    run "$work/p8" "$name"
    if [ "$target" = cx16 ] && [ "$(wc -l < "$work/up/$name.out" | tr -d ' ')" -le 16 ] && [ "$(tail -n +16 "$work/up/$name.out" | wc -c | tr -d ' ')" -le 12 ]; then
        # (the emulator's own lines and nothing else: two silent programs are not a match)
        echo "failed (the reference build prints nothing): $f"
        failed=$((failed + 1))
    elif cmp -s "$work/up/$name.out" "$work/p8/$name.out"; then
        echo "ok: $f ($(wc -c < "$work/up/$name.prg" | tr -d ' ') and $(wc -c < "$work/p8/$name.prg" | tr -d ' ') bytes)"
    else
        echo "failed (output differs): $f"
        if [ "$target" = cx16 ]; then
            diff "$work/up/$name.out" "$work/p8/$name.out" | head -10 | cut -c1-160
        else
            cmp "$work/up/$name.out" "$work/p8/$name.out" | head -1
        fi
        failed=$((failed + 1))
    fi
done
rm -rf "$work"
echo "emulator comparison ($target${codegen:+, $codegen code generator}): $total programs, $failed failed"
[ "$failed" -eq 0 ]
