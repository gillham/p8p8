#!/bin/sh
# A real program as a benchmark: how long the vi-like editor p8vi takes for one command
# on an Amiga 500, built by prog8c-llvm and by p8p8's 68000 code generator.
#
# p8vi (https://github.com/retrodores/p8vi, BSD Zero Clause License) has a test build
# that plays the keys in keys.txt and quits.  Both compilers build it with p8vi's own
# Makefile; each build then runs in the Copperline emulator, once with keys that load
# the sample text and quit, once with the command in between.  The time is the emulated
# second at which the program returned, from Copperline's log; the difference of the
# two runs is the command.  A third run writes the text, and the files that the two
# builds write are compared.
#
# p8vi is cloned into .p8vi-reference (not part of this repository) at the commit named
# below, unless P8VI_SRC names a checkout to use; either way the build is done in a
# copy, and the checkout is left as it is.
#
# It needs a Kickstart 1.3 ROM, which is not something a repository can carry:
# COPPERCMP_ROM names the file.  (p8vi does not come up under Copperline's own AROS.)
#
# BENCH_KEYS is the command to time, as printf writes it (default ':%%s/5//g\r': every
# 5 out of every line).  P8VI_REV is the commit or tag to clone.
#
# Usage: COPPERCMP_ROM=<kickstart 1.3 rom> tools/benchp8vi.sh [<p8c>]   (from the repository)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
rev=${P8VI_REV:-c5478cc}
keys=${BENCH_KEYS:-':%%s/5//g\r'}
rom=${COPPERCMP_ROM:-}
if [ -z "$rom" ] || [ ! -f "$rom" ]; then
    echo "COPPERCMP_ROM must name a Kickstart 1.3 ROM file" >&2
    exit 2
fi
here=$(pwd)
case "$p8c" in /*) ;; *) p8c=$here/$p8c ;; esac
case "$lib" in /*) ;; *) lib=$here/$lib ;; esac
src=${P8VI_SRC:-}
if [ -z "$src" ]; then
    src=$here/.p8vi-reference
    if [ ! -d "$src/.git" ]; then
        git clone -q https://github.com/retrodores/p8vi.git "$src" || exit 2
    fi
    (cd "$src" && { git cat-file -e "$rev^{commit}" 2> /dev/null || git fetch -q origin; } && git checkout -q "$rev") || exit 2
fi
work=${TMPDIR:-/tmp}/p8p8_benchp8vi.$$
mkdir -p "$work/tree" "$work/up" "$work/p8"
# a copy of the sources, without the checkout's own build results
(cd "$src" && tar cf - --exclude ./build --exclude ./.git --exclude './build.*' .) | (cd "$work/tree" && tar xf -)
mkdir -p "$work/tree/build"
build() {
    # build <dir> <compiler command>: p8vi's test build by that compiler
    rm -f "$work/tree/build/p8vi-amigatest"
    (cd "$work/tree" && make amiga-test PCC="$2" > "$work/$1/make.log" 2>&1) &&
        cp "$work/tree/build/p8vi-amigatest" "$work/$1/p8vi.com"
}
build up "prog8c-llvm" || { echo "prog8c-llvm does not build p8vi: see $work/up/make.log" >&2; exit 1; }
build p8 "$p8c -lib $lib" || { echo "p8c does not build p8vi: see $work/p8/make.log" >&2; exit 1; }
seconds() {
    # seconds <dir> <name> <keys>: the emulated time at which p8vi returned after these keys
    run=$work/$1/$2
    mkdir -p "$run"
    cp "$work/$1/p8vi.com" "$run/p8vi.com"
    cp "$work/tree/samples/sample.txt" "$run/t.txt"
    printf "$3" > "$run/keys.txt"
    (cd "$run" && timeout 900 copperline --model A500 --run p8vi.com --run-args ">out.log" --exit-on-return "$rom" \
        > cl.log 2>&1 < /dev/null)
    grep -o 'returned [0-9]* at [0-9.]*' "$run/cl.log" | grep -o '[0-9.]*$'
}
status=0
for d in up p8; do
    base=$(seconds $d base ':e t.txt\r:q!\r')
    with=$(seconds $d command ":e t.txt\\r$keys:q!\\r")
    seconds $d write ":e t.txt\\r$keys:w\\r:q!\\r" > /dev/null
    if [ -z "$base" ] || [ -z "$with" ]; then
        echo "p8vi did not return in $work/$d (see cl.log there)" >&2
        exit 1
    fi
    eval "base_$d=$base; with_$d=$with; size_$d=$(wc -c < "$work/$d/p8vi.com" | tr -d ' ')"
done
cmp -s "$work/up/write/t.txt" "$work/p8/write/t.txt" || { echo "the two builds wrote different files: $work/up/write/t.txt $work/p8/write/t.txt"; status=1; }
cmp -s "$work/tree/samples/sample.txt" "$work/p8/write/t.txt" && echo "(the command did not change the text)"
echo "$base_up $with_up $size_up $base_p8 $with_p8 $size_p8" | awk '{
    u = $2 - $1; p = $5 - $4
    printf "p8vi  load and quit: upstream %.2f s, p8p8 %.2f s (with the boot)\n", $1, $4
    printf "p8vi  the command:   upstream %.2f s %d bytes   p8p8 %.2f s %d bytes   x%.2f\n", u, $3, p, $6, p / u }'
[ "$status" -eq 0 ] && rm -rf "$work"
exit $status
