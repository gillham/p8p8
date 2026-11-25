#!/bin/sh
# The Atari target.  Each program is built twice for it: by the reference compiler
# (prog8c-llvm, from source) and by p8p8 with its own code generator.  Both run in
# atari800 without a window (SDL's dummy video), an Atari 800XL without BASIC; the
# emulator stops where the program ends, and the text screens they left are compared.
#
# Usage: tests/ataricmp.sh <p8c> <program.p8>...
#        tests/ataricmp.sh -screen <p8c> <program.p8>     (print the screen it leaves)
#        (needs prog8c-llvm, 64tass, python3 and atari800 with its ROMs in the path)
# ATARICMP_SECONDS: how long a program may run, in seconds of this machine (20).
here=$(cd "$(dirname "$0")" && pwd)
show=
if [ "$1" = -screen ]; then
    show=1
    shift
fi
p8c=$1
shift
lib=${P8P8_LIB:-lib}
seconds=${ATARICMP_SECONDS:-20}
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_ataricmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ref" "$work/at"
# the reference compiler is told where the machine's modules are by the target file
libdir=$(cd "$lib/targets/atari" && pwd)
cp "$libdir/target.properties" "$work/atari.properties"
echo "library = $libdir" >> "$work/atari.properties"
run() {
    # The emulator's monitor comes up at the program's end (a breakpoint at
    # p8_sys_startup.cleanup_at_exit, whose address the assembler's label file has),
    # writes the screen's memory to a file and quits.  Its output is thrown away: at
    # the end of its input the monitor repeats its last command for ever.
    rm -f "$1/$2.scr"
    at=$(sed -n 's/^al \([0-9A-Fa-f]*\) \.p8_sys_startup:cleanup_at_exit$/\1/p' "$1/$2.vice-mon-list")
    [ -n "$at" ] || return
    (cd "$1" && printf 'write bc40 bfff %s.scr\nquit\nquit\n' "$2" | \
        SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout -s KILL "$seconds" \
        atari800 -xl -nobasic -nosound -turbo -bpc "$at" -run "$2.xex" > /dev/null 2>&1) 2> /dev/null
}
if [ -n "$show" ]; then
    name=$(basename "$1" .p8)
    "$p8c" -lib "$lib" -target atari -out "$work/at" "$1" > "$work/at.err" 2>&1 || cat "$work/at.err"
    run "$work/at" "$name"
    if [ -f "$work/at/$name.scr" ]; then
        python3 "$here/../tools/atscreen.py" -i "$work/at/$name.scr" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
    else
        echo "(no screen: the program did not end)"
    fi
    exit 0
fi
same=0; differ=0; unbuilt=0; skipped=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    rm -f "$work/ref/$name.xex" "$work/at/$name.xex"
    if ! prog8c-llvm -target "$work/atari.properties" -out "$work/ref" "$f" > "$work/ref.err" 2>&1 || [ ! -f "$work/ref/$name.xex" ]; then
        skipped=$((skipped + 1))    # (not a program for this machine: floats, another machine's modules)
        [ -n "$ATARICMP_VERBOSE" ] && echo "skipped: $f: $(grep -i error "$work/ref.err" | head -1 | cut -c1-120)"
        continue
    fi
    if [ "$name" = localzero ] || [ "$name" = variables ]; then
        # (they print @dirty variables: what the machine's memory held)
        skipped=$((skipped + 1))
        continue
    fi
    # The reference's file has no run address, and the emulator then starts the first
    # part of the file, which is not the program's start when it has data in a section
    # of its own: the part that p8c's file ends with ($02e0-$02e1 = $2000) is added.
    printf '\340\002\341\002\000\040' >> "$work/ref/$name.xex"
    "$p8c" -lib "$lib" -target atari -out "$work/at" "$f" > "$work/at.err" 2>&1
    if [ $? -ne 0 ] || [ ! -f "$work/at/$name.xex" ]; then
        unbuilt=$((unbuilt + 1))
        echo "NOT BUILT: $f: $(grep -v warning "$work/at.err" | head -1 | cut -c1-110)"
        continue
    fi
    run "$work/ref" "$name"
    run "$work/at" "$name"
    if [ ! -f "$work/ref/$name.scr" ]; then
        skipped=$((skipped + 1))    # (the reference's program does not end here)
        [ -n "$ATARICMP_VERBOSE" ] && echo "skipped: $f: the reference's program did not end"
    elif [ -f "$work/at/$name.scr" ] && cmp -s "$work/ref/$name.scr" "$work/at/$name.scr"; then
        same=$((same + 1))
        echo "ok: $f ($(wc -c < "$work/ref/$name.xex" | tr -d ' ') and $(wc -c < "$work/at/$name.xex" | tr -d ' ') bytes)"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        if [ -f "$work/at/$name.scr" ]; then
            python3 "$here/../tools/atscreen.py" "$work/ref/$name.scr" > "$work/ref.txt"
            python3 "$here/../tools/atscreen.py" "$work/at/$name.scr" > "$work/at.txt"
            diff "$work/ref.txt" "$work/at.txt" | head -4 | cut -c1-150
        else
            echo "(p8c's program did not end)"
        fi
    fi
done
echo "Atari comparison (atari800, against the reference compiler): $same the same, $differ different, $unbuilt not built, $skipped not for this machine"
[ "$differ" -eq 0 ] && [ "$unbuilt" -eq 0 ]
