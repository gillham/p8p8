#!/bin/sh
# The Z80 code generator, on CP/M: each program is built for the host (llvm64) and for
# the cpm target, the first run as it is and the second in tnylpo, and
# what they print is compared.  The generator is new: a program that it cannot build yet
# is counted, with the first thing it says, and is not a failure.
#
# With Z80CMP_MACHINE=trs80 the second is built for the TRS-80 Model I instead (the
# trs80 target as tests/z80/trs80gp.properties has it) and run in trs80gp by
# tests/trs80run.sh, which opens a window for each program.
#
# Usage: tests/z80cmp.sh <p8c> <program.p8>...
#        (needs clang, z88dk-z80asm (Z88DK names z88dk's directory) and tnylpo,
#         or trs80gp (TRS80GP names it) for the TRS-80)
p8c=$1
shift
lib=${P8P8_LIB:-lib}
here=$(cd "$(dirname "$0")" && pwd)
machine=${Z80CMP_MACHINE:-cpm}
where="CP/M in tnylpo"
[ "$machine" = trs80 ] && where="TRS-80 Model I in trs80gp"
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_z80cmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/host" "$work/z80"
same=0; differ=0; unbuilt=0; skipped=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    rm -f "$work/host/$name" "$work/z80/$name.com"
    if ! "$p8c" -lib "$lib" -target llvm64 -o "$work/host/$name" "$f" > "$work/host.err" 2>&1; then
        skipped=$((skipped + 1))
        continue
    fi
    if [ "$machine" = trs80 ]; then
        "$p8c" -lib "$lib" -srcdirs "$lib/targets/trs80" -target "$here/z80/trs80gp.properties" -out "$work/z80" "$f" > "$work/z80.err" 2>&1
        built="$work/z80/$name.cmd"
    else
        "$p8c" -lib "$lib" -target cpm -out "$work/z80" "$f" > "$work/z80.err" 2>&1
        built="$work/z80/$name.com"
    fi
    if [ $? -ne 0 ] || [ ! -f "$built" ]; then
        unbuilt=$((unbuilt + 1))
        echo "not built yet: $f: $(grep -v warning "$work/z80.err" | head -1 | cut -c1-110)"
        continue
    fi
    (cd "$work/host" && timeout 10 "./$name" < /dev/null > "$name.out" 2>&1)
    if [ $? -ge 124 ]; then
        skipped=$((skipped + 1))    # (it does not end on the host, or it is for a machine's memory)
        continue
    fi
    # (a CP/M file name is eight characters and three)
    if [ "$machine" = trs80 ]; then
        "$here/trs80run.sh" "$built" > "$work/z80/$name.out" 2>&1
    else
        (cd "$work/z80" && cp "$name.com" t.com && timeout 20 tnylpo t.com < /dev/null > "$name.out" 2>&1)
    fi
    # (CP/M ends its lines with CR LF)
    tr -d '\r' < "$work/z80/$name.out" > "$work/z80/$name.txt"
    if [ "$name" = floatchains ]; then
        # (digits of floats: 32 bits here, 64 on the host; make z80ref compares these)
        skipped=$((skipped + 1))
    elif [ "$name" = ownlocals ]; then
        # (a subroutine that runs again inside its own call: its variables are on the stack
        # on the host and in fixed places here, as on the 6502, so it prints other numbers)
        skipped=$((skipped + 1))
    elif cmp -s "$work/host/$name.out" "$work/z80/$name.txt"; then
        same=$((same + 1))
        echo "ok: $f"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/host/$name.out" "$work/z80/$name.txt" | head -4
    fi
done
echo "Z80 comparison ($where, against the host): $same the same, $differ different, $unbuilt not built yet, $skipped not for the host"
[ "$differ" -eq 0 ]
