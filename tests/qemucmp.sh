#!/bin/sh
# Builds each program for qemu68k with prog8c-llvm (from the source, its own 68000 code
# generator) and with p8p8's 68000 code generator, runs both in QEMU and compares what
# they print.  Needs vasmm68k_mot, vlink and qemu-system-m68k.
#
# QEMUCMP_TARGET=amiga1200 or amiga500: Amiga programs, run in vamos (P8P8_VAMOS names it when it
# is not in the PATH), which runs programs that only use the console.
# With QEMUCMP_COPPERLINE=1 they run in the Copperline emulator instead, which is slower
# to start and has an FPU: the way to compare programs with floats.
#
# Where the two differ, upstream's llvm64 build of the program is asked as well: when
# every line of p8p8's output is the line of one of the two, it is upstream's 68000
# program that is off (its llvm64 program alone will not do: some lines depend on the
# byte order).
#
# QEMUCMP_CODEGEN=upstream: p8p8 writes the IR and prog8c-llvm's 68000 back end builds the
# program from it (p8c -codegen upstream), which tests p8p8's front end apart from its
# own code generator.
#
# A program that p8p8's generator cannot build yet is counted apart, not as a failure:
# the generator is new, and the list of what it lacks is what this prints.
# QEMUCMP_STRICT=1 makes those failures too.
#
# Usage: tests/qemucmp.sh <p8p8> <file.p8>...
p8p8=$1
shift
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_qemucmp.$$
mkdir -p "$work/up" "$work/p8"
target=${QEMUCMP_TARGET:-qemu68k}
codegen=
generator="own code generator"
if [ "${QEMUCMP_CODEGEN:-own}" = upstream ]; then
    codegen="-codegen upstream"
    generator="p8p8's IR, upstream's code generator"
fi
vamos=${P8P8_VAMOS:-vamos}
cpu=68020
[ "$target" = amiga500 ] && cpu=68000
machine="--model A1200 --cpu 68020 --fpu"
[ "$target" = amiga500 ] && machine="--model A500 --cpu 68000 --slow 512K"
run() {
    # run <dir> <name>: the program's output
    if [ "$target" = qemu68k ]; then
        (cd "$1" && timeout "${QEMUCMP_TIMEOUT:-20}" qemu-system-m68k -M virt -cpu m68020 -m 1M -nographic \
            -kernel "$2.elf" < /dev/null 2>&1)
    elif [ -n "$QEMUCMP_COPPERLINE" ]; then
        # an Amiga program in the Copperline emulator: a whole machine (an FPU on the 1200),
        # its bundled AROS unless COPPERCMP_ROM names a Kickstart; the CLI sends what the
        # program prints to a file in its directory
        : > "$1/out.log"
        (cd "$1" && timeout 300 copperline --factory $machine ${COPPERCMP_ROM:+"$COPPERCMP_ROM"} --run "$2" \
            --run-args ">out.log" --exit-on-return > copperline.log 2>&1 < /dev/null)
        cat "$1/out.log"
    else
        # an Amiga program that only uses the console: vamos (its own messages go to stderr)
        (cd "$1" && timeout "${QEMUCMP_TIMEOUT:-20}" "$vamos" -C $cpu "$2" < /dev/null 2> /dev/null)
    fi
}
agree() {
    # agree <a> <b> <c>: has c as many lines as a and b, and is every line of it that of a or of b?
    # (a line that depends on the byte order is upstream's 68000 line, one its 68000 code
    # gets wrong is the llvm64 line)
    [ "$(wc -l < "$1")" -eq "$(wc -l < "$3")" ] && [ "$(wc -l < "$2")" -eq "$(wc -l < "$3")" ] &&
        paste -d '\001' "$1" "$2" "$3" | awk -F '\001' '$3 != $1 && $3 != $2 { bad = 1 } END { exit bad }'
}
failed=0
total=0
lacking=0
other=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    if ! prog8c-llvm -target $target -plaintext -quiet -out "$work/up" "$f" > /dev/null 2>&1; then
        echo "skipped (upstream rejects): $f"
        continue
    fi
    total=$((total + 1))
    if ! "$p8p8" -target $target -lib "$lib" $codegen -build -out "$work/p8" "$f" > "$work/p8.err" 2>&1; then
        if grep -q "not supported" "$work/p8.err"; then
            echo "not yet ($(grep -m1 "not supported" "$work/p8.err" | sed 's/^68000 code generator: //')): $f"
            lacking=$((lacking + 1))
        else
            echo "failed (p8p8 does not build it): $f"
            head -4 "$work/p8.err"
            failed=$((failed + 1))
        fi
        continue
    fi
    run "$work/up" "$name" > "$work/up.out"
    if [ $? -eq 124 ]; then
        echo "skipped (upstream's program does not end): $f"
        total=$((total - 1))
        continue
    fi
    if [ ! -s "$work/up.out" ]; then
        echo "skipped (upstream's program prints nothing here): $f"
        total=$((total - 1))
        continue
    fi
    run "$work/p8" "$name" > "$work/p8.out"
    if cmp -s "$work/up.out" "$work/p8.out"; then
        echo "ok: $f"
    elif prog8c-llvm -target llvm64 -plaintext -quiet -o "$work/native" "$f" > /dev/null 2>&1 &&
            timeout 60 "$work/native" < /dev/null > "$work/native.out" 2>&1 &&
            agree "$work/up.out" "$work/native.out" "$work/p8.out"; then
        # a second opinion: the same program as upstream builds it for this machine
        echo "ok (lines as upstream's llvm64 program prints them, where its 68000 program differs): $f"
        other=$((other + 1))
    else
        echo "failed (output differs): $f"
        diff "$work/up.out" "$work/p8.out" | head -10
        failed=$((failed + 1))
    fi
done
rm -rf "$work"
echo "68000 comparison ($target, $generator): $total programs, $failed failed, $lacking not built yet, $other where upstream's 68000 program is the odd one"
[ "$failed" -eq 0 ] && { [ -z "$QEMUCMP_STRICT" ] || [ "$lacking" -eq 0 ]; }
