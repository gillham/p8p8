#!/bin/sh
# The Atari ST target: each program is built for the host (llvm64) and for atarist,
# the first run as it is and the second in Hatari (tests/strun.sh), and what they
# print is compared.  The ST's lines end with a carriage return and a line feed, and
# the system may print empty lines before the program starts: neither counts.
#
# Where the two differ and P8P8_VAMOS names vamos, the program is built for the
# Amiga 500 too (the same processor and code generator, another system) and run
# there: a line that depends on the byte order is the same on those two, and every
# line must be the host's or the Amiga's.
#
# A program that reads or writes a word or a long at an odd address is stopped by a
# 68000 (an address error; a struct's fields are packed, and keeping them even is
# the program's own business, as upstream's manual says).  Hatari's trace shows it,
# and such a program is counted apart: vamos and the later processors let it pass.
#
# A program that cannot be built (floats: the ST has no FPU) is counted apart.
# Where tests/atarist/<name>.out exists, that is what the program must print.
#
# Usage: tests/stcmp.sh <p8c> <program.p8>...
#        (needs clang, vasmm68k_mot and hatari; see tests/strun.sh for the variables)
p8c=$1
shift
lib=${P8P8_LIB:-lib}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_stcmp.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/host" "$work/st" "$work/amiga"
clean() {
    tr -d '\r' | awk 'started || $0 != "" { started = 1; print }'
}
tosname=EmuTOS
[ -n "$ST_TOS" ] && tosname=$(basename "$ST_TOS")
agree() {
    # agree <a> <b> <c>: has c as many lines as a and b, and is every line of it that of a or of b?
    [ "$(wc -l < "$1")" -eq "$(wc -l < "$3")" ] && [ "$(wc -l < "$2")" -eq "$(wc -l < "$3")" ] &&
        paste -d '\001' "$1" "$2" "$3" | awk -F '\001' '$3 != $1 && $3 != $2 { bad = 1 } END { exit bad }'
}
odd=0; same=0; differ=0; unbuilt=0; skipped=0; order=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    if [ -f "$here/atarist/$name.out" ]; then
        clean < "$here/atarist/$name.out" > "$work/host/$name.out"
    elif ! "$p8c" -lib "$lib" -target llvm64 -o "$work/host/$name" "$f" > "$work/host.err" 2>&1; then
        skipped=$((skipped + 1))
        continue
    else
        (cd "$work/host" && timeout 10 "./$name" < /dev/null 2>&1 | clean > "$name.out"; exit 0)
    fi
    if ! "$p8c" -lib "$lib" -target atarist -out "$work/st" "$f" > "$work/st.err" 2>&1 || [ ! -f "$work/st/$name.tos" ]; then
        unbuilt=$((unbuilt + 1))
        echo "not built: $f: $(grep -v warning "$work/st.err" | head -1 | cut -c1-110)"
        continue
    fi
    ST_TRACE="$work/trace" "$here/strun.sh" "$work/st/$name.tos" | clean > "$work/st/$name.out"
    if cmp -s "$work/host/$name.out" "$work/st/$name.out"; then
        same=$((same + 1))
        echo "ok: $f"
    elif grep -q 'cpu exception 3 ' "$work/trace"; then
        odd=$((odd + 1))
        echo "not for a 68000 (a word or a long at an odd address, which stops it): $f"
    elif [ -n "$P8P8_VAMOS" ] && "$p8c" -lib "$lib" -target amiga500 -out "$work/amiga" "$f" > /dev/null 2>&1 &&
            (cd "$work/amiga" && timeout 20 "$P8P8_VAMOS" -C 68000 "$name" < /dev/null 2> /dev/null | clean > "$name.out"; exit 0) &&
            agree "$work/host/$name.out" "$work/amiga/$name.out" "$work/st/$name.out"; then
        same=$((same + 1))
        order=$((order + 1))
        echo "ok (lines as the Amiga 500's program prints them, where the host's differ): $f"
    else
        differ=$((differ + 1))
        echo "DIFFERENT: $f"
        diff "$work/host/$name.out" "$work/st/$name.out" | head -4
    fi
done
echo "Atari ST comparison (Hatari, $tosname, against the host): $same the same ($order of them as on the Amiga 500), $differ different, $unbuilt not built, $odd not for a 68000, $skipped not for the host"
[ "$differ" -eq 0 ]
