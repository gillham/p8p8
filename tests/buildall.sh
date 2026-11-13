#!/bin/sh
# Every example program must come out of p8p8 as a program file: p8p8 generates the IR
# and prog8c-llvm's back end assembles it (p8p8 -build).  This catches a check that
# rejects a valid program, and IR the back end cannot take; it does not run anything.
# Usage: tests/buildall.sh <p8p8> <reference dir> <target> <file.p8>...
p8p8=$1
ref=$2
target=$3
shift 3
lib=${P8P8_LIB:-lib}
# BUILDALL_CODEGEN=own: with p8p8's own 6502 code generator and 64tass
codegen="-codegen upstream"
[ "${BUILDALL_CODEGEN:-}" = own ] && codegen="-codegen own"
work=${TMPDIR:-/tmp}/p8p8_buildall.$$
mkdir -p "$work"
failed=0
total=0
for f in "$@"; do
    total=$((total + 1))
    name=$(basename "$f" .p8)
    if ! "$p8p8" -target "$target" -lib "$lib" $codegen -out "$work" -build "$f" > "$work/err" 2>&1 || [ ! -f "$work/$name.prg" ]; then
        echo "failed: $f"
        sed 's/\x1b\[[0-9;]*m//g' "$work/err" | grep -i 'error\|code generator' | sort | uniq -c | sort -rn | head -3 | cut -c1-200
        failed=$((failed + 1))
    fi
    rm -f "$work/$name".*
done
rm -rf "$work"
echo "build all ($target): $total programs, $failed failed"
[ "$failed" -eq 0 ]
