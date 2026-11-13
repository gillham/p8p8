#!/bin/sh
# Loads every example program of the reference material with its imports
# resolved, each against the library of a target it is written for.  A file
# in a target's directory uses that target; others try a few targets and
# pass when one of them loads without errors.
# Usage: tests/programs.sh <p8p8> <reference dir>
p8p8=$1
ref=$2
lib=${P8P8_LIB:-lib}
failed=0
total=0
err=${TMPDIR:-/tmp}/p8p8_programs.$$

try() {
    # try <file> <target>...: succeeds when one target loads the file cleanly
    f=$1
    shift
    for t in "$@"; do
        if "$p8p8" -check -lib "$lib" -target "$t" "$f" > /dev/null 2> "$err"; then
            return 0
        fi
    done
    echo "failed: $f (tried: $*)"
    head -3 "$err"
    return 1
}

check() {
    # a file without a main block is a module for other programs, not a program
    grep -Eq '^[[:space:]]*main([[:space:]]|\{)' "$1" || return 0
    total=$((total + 1))
    try "$@" || failed=$((failed + 1))
}

for f in $ref/examples/llvm/*.p8; do check "$f" llvm64; done
for f in $(find $ref/examples/cx16 -name '*.p8'); do check "$f" cx16; done
for f in $(find $ref/examples/c64 -name '*.p8'); do check "$f" c64; done
for f in $(find $ref/examples/pet -name '*.p8'); do check "$f" pet32; done
for f in $(find $ref/examples/amiga -name '*.p8'); do check "$f" amiga500 amiga1200; done
for f in $(find $ref/examples/qemu68k -name '*.p8'); do check "$f" qemu68k; done
for f in $(find $ref/examples/virtual -name '*.p8'); do check "$f" virtual; done
for f in $(find $ref/examples/pointers -name '*.p8'); do check "$f" cx16 virtual c64; done
for f in $ref/examples/*.p8 $ref/compiler/test/arithmetic/*.p8 $ref/compiler/test/comparisons/*.p8; do
    case $f in
        */examples/test.p8) continue ;;     # upstream's scratch file, not for every target
    esac
    check "$f" cx16 c64 virtual
done
rm -f "$err"
echo "programs: $total loaded, $failed failed"
[ "$failed" -eq 0 ]
