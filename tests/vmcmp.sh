#!/bin/sh
# Compiles each program with prog8c-llvm and with p8p8 for the virtual target,
# runs both in prog8c-llvm's virtual machine and compares the output.
# Usage: tests/vmcmp.sh <p8p8> <reference dir> <file.p8>...
p8p8=$1
ref=$2
shift 2
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_vmcmp.$$
mkdir -p "$work/up" "$work/p8"
failed=0
total=0
for f in "$@"; do
    total=$((total + 1))
    name=$(basename "$f" .p8)
    if ! prog8c-llvm -target virtual -plaintext -quiet -out "$work/up" "$f" > /dev/null 2>&1; then
        echo "skipped (upstream rejects): $f"
        total=$((total - 1))
        continue
    fi
    if ! "$p8p8" -target virtual -lib "$lib" -ir -out "$work/p8" "$f" > "$work/p8.err" 2>&1; then
        echo "failed (p8p8 rejects): $f"
        head -3 "$work/p8.err"
        failed=$((failed + 1))
        continue
    fi
    # a program that keeps running (graphics, input) is cut off after a while
    timeout 60 prog8c-llvm -vm "$work/up/$name.p8ir" 2>&1 | grep -v "^Program exit\|^Prerelease\|^This software\|^LLVM version\|^Report issues" > "$work/up.out"
    timeout 60 prog8c-llvm -vm "$work/p8/$name.p8ir" 2>&1 | grep -v "^Program exit\|^Prerelease\|^This software\|^LLVM version\|^Report issues" > "$work/p8.out"
    if cmp -s "$work/up.out" "$work/p8.out"; then
        echo "ok: $f"
    else
        echo "failed (output differs): $f"
        diff "$work/up.out" "$work/p8.out" | head -10
        failed=$((failed + 1))
    fi
done
rm -rf "$work"
echo "vm comparison: $total programs, $failed failed"
[ "$failed" -eq 0 ]
