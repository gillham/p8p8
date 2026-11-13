#!/bin/sh
# Compiles each program with prog8c-llvm and with p8p8 -llvm, builds both LLVM IR files
# with clang, runs the two executables and compares their output.
#
# llvm64 (the default): a native executable of this machine.
# llvm32 (NATIVECMP_TARGET=llvm32): WebAssembly with WASI, run with wasmtime.  Needs a
# clang that has the wasm32 target (NATIVECMP_CLANG, default Homebrew's llvm), wasm-ld
# and the wasi-libc sysroot (WASI_SYSROOT, default Homebrew's wasi-libc).
#
# llvm16 (NATIVECMP_TARGET=llvm16): a 6502 program built with the llvm-mos SDK and run in
# its simulator mos-sim.  LLVM_MOS names the SDK directory (default ~/.local/llvm-mos).
#
# llvm16 with NATIVECMP_TRIPLE=mos-c64: a Commodore 64 program, built with the SDK's
# mos-c64-clang and upstream's support source (NATIVECMP_SUPPORT), run in VICE (x64sc,
# headless).  Such a program does not return to BASIC, so the screen is still when it is
# done: the emulator stops after NATIVECMP_CYCLES cycles and its last frame is compared.
#
# Usage: tests/nativecmp.sh <p8p8> <reference dir> <file.p8>...
p8p8=$1
ref=$2
shift 2
lib=${P8P8_LIB:-lib}
work=${TMPDIR:-/tmp}/p8p8_nativecmp.$$
target=${NATIVECMP_TARGET:-llvm64}
triple=${NATIVECMP_TRIPLE:-}
tripleopt=
cycles=${NATIVECMP_CYCLES:-100000000}
if [ "$target" = llvm32 ]; then
    cc="${NATIVECMP_CLANG:-/opt/homebrew/opt/llvm/bin/clang} --target=wasm32-wasip1 --sysroot=${WASI_SYSROOT:-/opt/homebrew/opt/wasi-libc/share/wasi-sysroot} -Wl,--fatal-warnings"
    ext=.wasm
elif [ "$target" = llvm16 ]; then
    LLVM_MOS=${LLVM_MOS:-$HOME/.local/llvm-mos}
    export LLVM_MOS
    cc="$LLVM_MOS/bin/mos-sim-clang"
    ext=.sim
    if [ "$triple" = mos-c64 ]; then
        cc="$LLVM_MOS/bin/mos-c64-clang ${NATIVECMP_SUPPORT:-runtime/mos-c64-support.c}"
        ext=.prg
        tripleopt="-triple mos-c64"
    fi
else
    cc=clang
    ext=
fi
opt=-O2
[ "$target" = llvm16 ] && opt=-Oz
run() {
    # run <dir> <name>: the program's output
    if [ "$target" = llvm32 ]; then
        timeout 60 wasmtime --dir=. "$1/$2$ext" < /dev/null 2>&1
    elif [ "$triple" = mos-c64 ]; then
        rm -f "$1/screen.png"
        (cd "$1" && timeout 300 x64sc -console -warp -limitcycles "$cycles" -exitscreenshot screen.png \
            -autostartprgmode 1 -autostart "$2$ext" > vice.log 2>&1 < /dev/null)
        cat "$1/screen.png"
    elif [ "$target" = llvm16 ]; then
        timeout 120 "$LLVM_MOS/bin/mos-sim" "$1/$2$ext" < /dev/null 2>&1
    else
        timeout 60 "$1/$2" < /dev/null 2>&1
    fi
}
mkdir -p "$work/up" "$work/p8"
failed=0
total=0
for f in "$@"; do
    total=$((total + 1))
    name=$(basename "$f" .p8)
    if ! prog8c-llvm -target $target $tripleopt -plaintext -quiet -out "$work/up" "$f" > /dev/null 2>&1; then
        echo "skipped (upstream rejects): $f"
        total=$((total - 1))
        continue
    fi
    if ! $cc $opt -Wno-override-module "$work/up/$name.ll" -o "$work/up/$name$ext" > /dev/null 2>&1; then
        echo "skipped (clang rejects upstream's LLVM IR): $f"
        total=$((total - 1))
        continue
    fi
    if ! "$p8p8" -target $target $tripleopt -lib "$lib" -llvm -out "$work/p8" "$f" > "$work/p8.err" 2>&1; then
        echo "failed (p8p8 rejects): $f"
        head -3 "$work/p8.err"
        failed=$((failed + 1))
        continue
    fi
    if ! $cc $opt -Wno-override-module "$work/p8/$name.ll" -o "$work/p8/$name$ext" > "$work/clang.err" 2>&1; then
        echo "failed (clang rejects p8p8's LLVM IR): $f"
        head -4 "$work/clang.err"
        failed=$((failed + 1))
        continue
    fi
    run "$work/up" "$name" > "$work/up.out"
    run "$work/p8" "$name" > "$work/p8.out"
    if ! cmp -s "$work/up.out" "$work/p8.out"; then
        # once more: a program that prints the time differs when the two runs are in different seconds,
        # which the slow first start of a new executable makes likely
        run "$work/up" "$name" > "$work/up.out"
        run "$work/p8" "$name" > "$work/p8.out"
    fi
    if cmp -s "$work/up.out" "$work/p8.out"; then
        echo "ok: $f"
    else
        echo "failed (output differs): $f"
        if [ "$triple" = mos-c64 ]; then
            cmp "$work/up.out" "$work/p8.out" | head -1
        else
            diff "$work/up.out" "$work/p8.out" | head -10
        fi
        failed=$((failed + 1))
    fi
done
rm -rf "$work"
echo "native comparison ($target${triple:+ $triple}): $total programs, $failed failed"
[ "$failed" -eq 0 ]
