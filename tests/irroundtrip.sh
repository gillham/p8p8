#!/bin/sh
# The IR file as input, for make irroundtrip.  For each program and target: the IR that
# p8c writes (-ir), read and written again, must be the same text, and the assembly
# (the LLVM IR for an llvm target) made from the IR file must be what the program gives
# when it is compiled directly.
#
# Usage: tests/irroundtrip.sh <p8c> <target> <file.p8> ...
p8c=$1; target=$2; shift 2
lib=${P8P8_LIB:-lib}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_irrt.XXXXXX")
trap 'rm -rf "$work"' EXIT
ext=asm; mode=""
case $target in llvm*) ext=ll; mode="-llvm";; esac
total=0; failed=0; skipped=0
for f in "$@"; do
    b=$(basename "$f" .p8)
    rm -rf "$work/direct" "$work/ir" "$work/again" "$work/from"
    mkdir -p "$work/direct" "$work/ir" "$work/again" "$work/from"
    if ! "$p8c" -lib "$lib" -target "$target" $mode -out "$work/direct" "$f" > /dev/null 2>&1 || [ ! -f "$work/direct/$b.$ext" ]; then
        skipped=$((skipped + 1))        # (not a program for this target)
        continue
    fi
    total=$((total + 1))
    if ! "$p8c" -lib "$lib" -target "$target" -ir -out "$work/ir" "$f" > "$work/log" 2>&1 ||
       ! "$p8c" -lib "$lib" -ir -out "$work/again" "$work/ir/$b.p8ir" >> "$work/log" 2>&1 ||
       ! "$p8c" -lib "$lib" -target "$target" $mode -out "$work/from" "$work/ir/$b.p8ir" >> "$work/log" 2>&1; then
        echo "failed: $f: $(head -1 "$work/log")"
        failed=$((failed + 1))
    elif ! cmp -s "$work/ir/$b.p8ir" "$work/again/$b.p8ir"; then
        echo "failed (the IR text changes when it is read and written): $f"
        failed=$((failed + 1))
    elif ! cmp -s "$work/direct/$b.$ext" "$work/from/$b.$ext"; then
        echo "failed (the .$ext from the IR file differs): $f"
        failed=$((failed + 1))
    fi
done
echo "IR round trip ($target): $total programs, $failed failed, $skipped not for this target"
[ $failed -eq 0 ]
