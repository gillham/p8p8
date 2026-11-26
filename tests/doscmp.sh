#!/bin/sh
# The 8086 code generator, on MS-DOS: each program is built for the host (llvm64) and
# for the dos target, the first run as it is and the second in DOSBox-X, and what they
# print is compared.  The generator is new: a program that it cannot build yet is
# counted, with the first thing it says, and is not a failure.
#
# DOSBox-X is started once for all programs (they are P001.COM, P002.COM ... in one
# directory, run by a batch file with their output in files); one that does not end
# stops the emulator at the time limit, is counted as different, and the rest is run
# again without it.  Where a program's output is tests/dos/<name>.out, that is right
# too (a program with 8086 assembly, which the host cannot build), and
# tests/dos/<name>.args is the command line it is started with.
#
# With DOSCMP_TARGET=dosexe the programs are built for the dosexe target: .EXE files.
#
# Usage: tests/doscmp.sh <p8c> <program.p8>...
#        (needs clang, nasm and dosbox-x; DOSCMP_TIME is the seconds one start of the
#        emulator may take, 120 when it is not set)
p8c=$1
shift
lib=${P8P8_LIB:-lib}
here=$(cd "$(dirname "$0")" && pwd)
limit=${DOSCMP_TIME:-120}
# (DOSCMP_TARGET=dosexe: the same programs as .EXE files, with code and data apart)
machine=${DOSCMP_TARGET:-dos}
ext=com
[ "$machine" = dosexe ] && ext=exe
EXT=$(echo $ext | tr a-z A-Z)
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_doscmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/host" "$work/dos" "$work/c"
same=0; differ=0; unbuilt=0; skipped=0
n=0
: > "$work/list"
for f in "$@"; do
    name=$(basename "$f" .p8)
    if ! "$p8c" -lib "$lib" -target llvm64 -o "$work/host/$name" "$f" > "$work/host.err" 2>&1; then
        # (a program for the 8086 alone, with assembly: what it must print is beside it)
        if [ ! -f "${f%.p8}.out" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        cp "${f%.p8}.out" "$work/host/$name.out"
    else
        (cd "$work/host" && timeout 10 "./$name" < /dev/null > "$name.out" 2>&1)
        if [ $? -ge 124 ]; then
            skipped=$((skipped + 1))    # (it does not end on the host, or it is for a machine's memory)
            continue
        fi
    fi
    "$p8c" -lib "$lib" -target "$machine" -out "$work/dos" "$f" > "$work/dos.err" 2>&1
    if [ $? -ne 0 ] || [ ! -f "$work/dos/$name.$ext" ]; then
        unbuilt=$((unbuilt + 1))
        echo "not built yet: $f: $(grep -v warning "$work/dos.err" | head -1 | cut -c1-110)"
        continue
    fi
    n=$((n + 1))
    short=$(printf 'P%03d' $n)
    cp "$work/dos/$name.$ext" "$work/c/$short.$EXT"
    echo "$short $name $f" >> "$work/list"
done
# the emulator, as often as a program stops it
while :; do
    : > "$work/c/RUN.BAT"
    left=0
    while read -r short name f; do
        [ -f "$work/c/$short.END" ] && continue
        # (the program's command line, when it has one: tests/dos/<name>.args)
        args=
        [ -f "${f%.p8}.args" ] && args=" $(cat "${f%.p8}.args")"
        printf '%s.%s%s > %s.OUT\r\nECHO done > %s.END\r\n' "$short" "$EXT" "$args" "$short" "$short" >> "$work/c/RUN.BAT"
        left=$((left + 1))
    done < "$work/list"
    [ $left -eq 0 ] && break
    (cd "$work/c" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout -s KILL "$limit" dosbox-x -silent -fastlaunch -nogui -nomenu -exit \
        -set "cpu cycles=max" -c "mount c ." -c "c:" -c "call RUN.BAT" -c "exit" > /dev/null 2>&1 < /dev/null)
    # (the first one without its mark is the one that did not end)
    while read -r short name f; do
        if [ ! -f "$work/c/$short.END" ]; then
            echo "did not end" >> "$work/c/$short.OUT"
            : > "$work/c/$short.END"
            break
        fi
    done < "$work/list"
done
while read -r short name f; do
    tr -d '\r' < "$work/c/$short.OUT" > "$work/dos/$name.out"
    if cmp -s "$work/host/$name.out" "$work/dos/$name.out" ||
            { [ -f "$here/dos/$name.out" ] && cmp -s "$here/dos/$name.out" "$work/dos/$name.out"; }; then
        same=$((same + 1))
        echo "ok: $f"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/host/$name.out" "$work/dos/$name.out" | head -4
    fi
done < "$work/list"
echo "8086 comparison (MS-DOS in DOSBox-X, target $machine, against the host): $same the same, $differ different, $unbuilt not built yet, $skipped not for the host"
[ "$differ" -eq 0 ]
