#!/bin/sh
# The compiler on a 32-bit host: p8c is built for llvm32 (WebAssembly with
# WASI) and run with wasmtime.  What it writes must be what the native p8c
# writes, byte for byte: its own source for llvm32 (so it reproduces itself)
# and for llvm64, and the 6502 assembly of the test programs.
# Usage: tests/wasihost.sh <p8c> <main.p8> <file.p8>...
# Needs wasmtime, and what an llvm32 build needs (see tests/nativecmp.sh).
p8c=$1
main=$2
shift 2
lib=${P8P8_LIB:-lib}
work=build/wasihost
rm -rf "$work"
mkdir -p "$work/n" "$work/w"
wasm="wasmtime --dir . $work/p8c.wasm"
echo "p8c builds itself for llvm32"
"$p8c" -lib "$lib" -target llvm32 -srcdirs src:src/wasi32:src/llvm64 -o "$work/p8c" "$main" || exit 1
failed=0
echo "the WebAssembly p8c compiles itself"
$wasm -lib "$lib" -target llvm32 -srcdirs src:src/wasi32:src/llvm64 -ir -llvm -out "$work/w" "$main" || exit 1
if cmp -s "$work/p8c.ll" "$work/w/main.ll"; then
    echo "its LLVM IR for llvm32 is the one it was built from ($(wc -c < "$work/p8c.ll") bytes)"
else
    echo "FAILED: it does not reproduce itself"
    failed=1
fi
"$p8c" -lib "$lib" -target llvm64 -triple arm64-apple-macosx -srcdirs src:src/llvm64 -ir -llvm -out "$work/n" "$main" || exit 1
$wasm -lib "$lib" -target llvm64 -triple arm64-apple-macosx -srcdirs src:src/llvm64 -ir -llvm -out "$work/w" "$main" || exit 1
for ext in p8ir ll; do
    if cmp -s "$work/n/main.$ext" "$work/w/main.$ext"; then
        echo "its $ext of the compiler for llvm64 is the native compiler's"
    else
        echo "FAILED: the $ext of the compiler for llvm64 differs"
        failed=1
    fi
done
total=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    for target in c64 cx16; do
        rm -f "$work/n/$name.asm" "$work/w/$name.asm"
        "$p8c" -lib "$lib" -target $target -codegen own -ir -out "$work/n" "$f" > "$work/n.out" 2>&1
        $wasm -lib "$lib" -target $target -codegen own -ir -out "$work/w" "$f" > "$work/w.out" 2>&1
        total=$((total + 1))
        # (a program one target refuses must be refused the same way)
        if ! cmp -s "$work/n.out" "$work/w.out"; then
            echo "FAILED: the messages differ for $f ($target)"
            failed=$((failed + 1))
        elif [ -f "$work/n/$name.asm" ] && ! cmp -s "$work/n/$name.asm" "$work/w/$name.asm"; then
            echo "FAILED: the assembly differs for $f ($target)"
            failed=$((failed + 1))
        fi
    done
done
echo "wasi host: $total 6502 builds compared, $failed failed"
[ "$failed" -eq 0 ]
