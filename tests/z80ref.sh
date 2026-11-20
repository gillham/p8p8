#!/bin/sh
# The Z80 code generator against prog8c-llvm on the same machine: each program is built
# for CP/M by prog8c-llvm (llvm16 with the z80-cpm triple: llvm-z80 and z88dk) and by
# p8c (the cpm target), both are run in tnylpo, and what they print is compared.  This
# is the comparison for floats, which are 32 bits on the Z80 and 64 on the host.
#
# Usage: tests/z80ref.sh <p8c> <program.p8>...
#        (needs prog8c-llvm with LLVM_Z80 and Z88DK set, and tnylpo)
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); shift
lib=$(cd "$(dirname "$0")/.." && pwd)/lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_z80ref.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ref" "$work/own"
same=0; differ=0; unbuilt=0; skipped=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    # (a CP/M file name is eight characters and three: every program is t here)
    rm -f "$work/ref/t."* "$work/own/t."*
    cp "$f" "$work/ref/t.p8"
    cp "$f" "$work/own/t.p8"
    (cd "$work/ref" && prog8c-llvm -target llvm16 -triple z80-cpm -quiet -emu -out . t.p8 > build.log 2>&1)
    if [ ! -f "$work/ref/t.com" ]; then
        skipped=$((skipped + 1))    # (prog8c-llvm does not build it for CP/M)
        continue
    fi
    if ! (cd "$work/own" && "$p8c" -lib "$lib" -target cpm -out . t.p8 > build.log 2>&1) || [ ! -f "$work/own/t.com" ]; then
        unbuilt=$((unbuilt + 1))
        echo "not built: $f: $(grep -v warning "$work/own/build.log" | head -1 | cut -c1-110)"
        continue
    fi
    (cd "$work/ref" && timeout 20 tnylpo t.com < /dev/null > out.txt 2>&1)
    if [ $? -ge 124 ]; then
        skipped=$((skipped + 1))    # (it does not end)
        continue
    fi
    (cd "$work/own" && timeout 20 tnylpo t.com < /dev/null > out.txt 2>&1)
    if [ "$name" = addrconst ]; then
        # addrconst: prog8c-llvm gets the address of a memory-mapped array's element
        # wrong for CP/M (p8c's is what the host prints).
        skipped=$((skipped + 1))
    elif cmp -s "$work/ref/out.txt" "$work/own/out.txt"; then
        same=$((same + 1))
        echo "ok: $f"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/ref/out.txt" "$work/own/out.txt" | tr -d '\r' | head -4
    fi
done
echo "Z80 against prog8c-llvm (CP/M in tnylpo): $same the same, $differ different, $unbuilt not built by p8c, $skipped left out (not built by prog8c-llvm, without an end, or known to differ)"
[ "$differ" -eq 0 ] && [ "$unbuilt" -eq 0 ]
