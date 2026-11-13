#!/bin/sh
# The self-hosting test: p8p8 (stage 1, built by prog8c-llvm) compiles its own
# sources to LLVM IR, clang turns that into stage 2, and stage 2 compiles the
# same sources again (stage 3).  The IR and LLVM output of stages 2 and 3
# must be identical.
# Usage: tests/bootstrap.sh <p8p8> <reference dir> <main.p8> <srcdirs>
p8p8=$1
ref=$2
main=$3
srcdirs=$4
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_bootstrap.$$
mkdir -p "$work/stage2" "$work/stage3"
name=$(basename "$main" .p8)
echo "stage 1 compiles $main"
"$p8p8" -target llvm64 -lib "$lib" -srcdirs "$srcdirs" -ir -llvm -out "$work/stage2" "$main" || exit 1
echo "clang builds stage 2"
clang -O2 -Wno-override-module "$work/stage2/$name.ll" -o "$work/stage2/p8c" -lm || exit 1
echo "stage 2 compiles $main"
"$work/stage2/p8c" -target llvm64 -lib "$lib" -srcdirs "$srcdirs" -ir -llvm -out "$work/stage3" "$main" || exit 1
status=0
for ext in p8ir ll; do
    if cmp -s "$work/stage2/$name.$ext" "$work/stage3/$name.$ext"; then
        echo "stage 3 $ext identical to stage 2 ($(wc -c < "$work/stage2/$name.$ext") bytes)"
    else
        echo "FAILED: stage 3 $ext differs from stage 2"
        diff "$work/stage2/$name.$ext" "$work/stage3/$name.$ext" | head -20
        status=1
    fi
done
ls -l "$work/stage2/p8c" | awk '{print "stage 2 executable:", $5, "bytes"}'
rm -rf "$work"
exit $status
