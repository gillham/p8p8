#!/bin/sh
# Checks that prog8c-llvm's IR reader accepts the IR p8p8 writes for the
# 8-bit targets: each program is compiled to .p8ir by p8p8 and then handed
# to prog8c-llvm -compareir, which parses and links it.  (The instruction
# comparison that follows is not used: the two compilers number registers
# and order code differently.)
# Usage: tests/irread.sh <p8p8> <reference dir> <target> <file.p8>...
p8p8=$1
ref=$2
target=$3
shift 3
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_irread.$$
mkdir -p "$work/p8" "$work/up"
failed=0
total=0
for f in "$@"; do
    grep -Eq '^[[:space:]]*main([[:space:]]|\{)' "$f" || continue
    name=$(basename "$f" .p8)
    total=$((total + 1))
    if ! "$p8p8" -target "$target" -lib "$lib" -ir -out "$work/p8" "$f" > "$work/err" 2>&1; then
        echo "failed (p8p8 rejects): $f"
        head -2 "$work/err"
        failed=$((failed + 1))
        continue
    fi
    prog8c-llvm -target "$target" -newcodegen -quiet -compareir "$work/p8/$name.p8ir" -out "$work/up" "$f" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$work/out"
    if grep -q 'File Comparison' "$work/out"; then
        echo "ok: $f"
    elif grep -q 'Exception' "$work/out"; then
        echo "failed (reader rejects): $f"
        grep -m1 'Exception' "$work/out" | cut -c1-200
        failed=$((failed + 1))
    else
        echo "skipped (upstream does not build it): $f"
        total=$((total - 1))
    fi
done
rm -rf "$work"
echo "ir reader check ($target): $total programs, $failed failed"
[ "$failed" -eq 0 ]
