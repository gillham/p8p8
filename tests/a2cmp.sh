#!/bin/sh
# The Apple II target.  Each program is built twice for it: by the reference compiler
# (prog8c-llvm, from source) and by p8p8 with its own code generator.  Both run in
# bobbin's line interface, which has no window, and what they print is compared.
#
# Usage: tests/a2cmp.sh <p8c> <program.p8>...
#        tests/a2cmp.sh -screen <p8c>
#        (needs prog8c-llvm, 64tass and bobbin in the path)
# A2CMP_SECONDS: how long a program may run, in seconds of the machine (600).
p8c=$1
shift
lib=${P8P8_LIB:-lib}
seconds=${A2CMP_SECONDS:-600}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_a2cmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ref" "$work/a2"
# the reference compiler is told where the machine's modules are by the target file
libdir=$(cd "$lib/targets/appleii" && pwd)
grep -v '^run_command' "$libdir/target.properties" > "$work/appleii.properties"
echo "library = $libdir" >> "$work/appleii.properties"
# bobbin does not show what is printed on the line where it was waiting for input (it
# takes that for the echo of what was typed): eight bytes at $380 end that line first
# (LDA #$8D, JSR COUT1, JMP $2000)
printf '\251\215\040\360\375\114\000\040' > "$work/first.bin"
run() {
    # (the file has DOS 3.3's four bytes of address and length before the program;
    #  at the end of the input bobbin stops, which is when the program has returned)
    (cd "$1" && timeout 300 bobbin --simple --max-runtime "$seconds" --delay-until INPUT \
        --load "$work/first.bin" --load-at 380 --load "$2.bin" --load-at 1ffc --jump-to 380 \
        < /dev/null > "$2.out" 2>&1)
}
if [ "$p8c" = -screen ]; then
    # tests/a2cmp.sh -screen <p8c>: what the screen test prints (make a2cmp compares it
    # with tests/expected/a2screen.txt)
    "$1" -lib "$lib" -target appleii -out "$work/a2" "$(dirname "$0")/a2/screen.p8" > "$work/a2.err" 2>&1 || cat "$work/a2.err"
    run "$work/a2" screen
    cat "$work/a2/screen.out"
    exit 0
fi
same=0; differ=0; unbuilt=0; skipped=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    rm -f "$work/ref/$name.bin" "$work/a2/$name.bin"
    if ! prog8c-llvm -target "$work/appleii.properties" -out "$work/ref" "$f" > "$work/ref.err" 2>&1 || [ ! -f "$work/ref/$name.bin" ]; then
        skipped=$((skipped + 1))    # (not a program for this machine: floats, another machine's modules)
        [ -n "$A2CMP_VERBOSE" ] && echo "skipped: $f: $(grep -i error "$work/ref.err" | head -1 | cut -c1-120)"
        continue
    fi
    if [ "$name" = localzero ] || [ "$name" = variables ]; then
        # (they print @dirty variables: what the machine's memory held, which bobbin
        #  fills with something else at every address)
        skipped=$((skipped + 1))
        continue
    fi
    "$p8c" -lib "$lib" -target appleii -out "$work/a2" "$f" > "$work/a2.err" 2>&1
    if [ $? -ne 0 ] || [ ! -f "$work/a2/$name.bin" ]; then
        unbuilt=$((unbuilt + 1))
        echo "NOT BUILT: $f: $(grep -v warning "$work/a2.err" | head -1 | cut -c1-110)"
        continue
    fi
    run "$work/ref" "$name"
    run "$work/a2" "$name"
    if cmp -s "$work/ref/$name.out" "$work/a2/$name.out"; then
        same=$((same + 1))
        echo "ok: $f ($(wc -c < "$work/ref/$name.bin" | tr -d ' ') and $(wc -c < "$work/a2/$name.bin" | tr -d ' ') bytes)"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/ref/$name.out" "$work/a2/$name.out" | head -4 | cut -c1-150
    fi
done
echo "Apple II comparison (bobbin, against the reference compiler): $same the same, $differ different, $unbuilt not built, $skipped not for this machine"
[ "$differ" -eq 0 ] && [ "$unbuilt" -eq 0 ]
