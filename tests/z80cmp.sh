#!/bin/sh
# The Z80 code generator, on CP/M: each program is built for the host (llvm64) and for
# llvm16 with the z80-cpm triple, the first run as it is and the second in tnylpo, and
# what they print is compared.  The generator is new: a program that it cannot build yet
# is counted, with the first thing it says, and is not a failure.
#
# Usage: tests/z80cmp.sh <p8c> <program.p8>...
#        (needs clang, z88dk-z80asm (Z88DK names z88dk's directory) and tnylpo)
p8c=$1
shift
lib=${P8P8_LIB:-lib}
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
    if ! "$p8c" -lib "$lib" -target llvm16 -triple z80-cpm -out "$work/z80" "$f" > "$work/z80.err" 2>&1 \
            || [ ! -f "$work/z80/$name.com" ]; then
        unbuilt=$((unbuilt + 1))
        echo "not built yet: $f: $(grep -v warning "$work/z80.err" | head -1 | cut -c1-110)"
        continue
    fi
    (cd "$work/host" && timeout 10 "./$name" < /dev/null > "$name.out" 2>&1)
    # (a CP/M file name is eight characters and three)
    (cd "$work/z80" && cp "$name.com" t.com && timeout 20 tnylpo t.com < /dev/null > "$name.out" 2>&1)
    # (CP/M ends its lines with CR LF)
    tr -d '\r' < "$work/z80/$name.out" > "$work/z80/$name.txt"
    if cmp -s "$work/host/$name.out" "$work/z80/$name.txt"; then
        same=$((same + 1))
        echo "ok: $f"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/host/$name.out" "$work/z80/$name.txt" | head -4
    fi
done
echo "Z80 comparison (CP/M in tnylpo, against the host): $same the same, $differ different, $unbuilt not built yet, $skipped not for the host"
[ "$differ" -eq 0 ]
