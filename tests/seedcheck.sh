#!/bin/sh
# The compiler built from the seed and the one built by prog8c-llvm must be the same
# compiler: each compiles p8p8's sources to LLVM IR, and the test programs to 6502
# assembly, and what the two write must be identical.
# (A compiler that only ever builds itself could carry a mistake along from seed to
# seed; the second way in shows it.)
# Usage: tests/seedcheck.sh <seed.ll.gz> "<prog8c command and arguments>" "<p8c arguments>" <main.p8>
seed=$1
pcc=$2
p8cargs=$3
main=$4
work=${TMPDIR:-/tmp}/p8p8_seedcheck.$$
mkdir -p "$work/seed" "$work/ref" "$work/a" "$work/b"
status=1
echo "clang builds the compiler from the seed"
gzip -dc "$seed" > "$work/seed/p8c.ll" &&
${CLANG:-clang} -O2 -Wno-override-module "$work/seed/p8c.ll" -o "$work/seed/p8c" -lm &&
echo "prog8c-llvm builds the compiler from the sources" &&
$pcc -quiet -o "$work/ref/p8c" "$main" > "$work/ref.log" 2>&1 &&
echo "both compile $main" &&
"$work/seed/p8c" $p8cargs -llvm -out "$work/a" "$main" &&
"$work/ref/p8c" $p8cargs -llvm -out "$work/b" "$main" && {
    name=$(basename "$main" .p8)
    if cmp -s "$work/a/$name.ll" "$work/b/$name.ll"; then
        echo "seed check: the two compilers write identical LLVM IR ($(wc -c < "$work/a/$name.ll" | tr -d ' ') bytes)"
        status=0
        # The 6502 code generator is not part of compiling the compiler itself, so it is
        # tried on its own: the test programs, by both compilers, for both CPUs.
        programs=0
        for target in c64 cx16; do
            for f in tests/hello.p8 tests/programs/*.p8; do
                n=$(basename "$f" .p8)
                rm -f "$work/a/$n.asm" "$work/b/$n.asm"
                "$work/seed/p8c" -lib "${P8P8_LIB:-lib}" -target $target -codegen own -ir -out "$work/a" "$f" > /dev/null 2>&1
                "$work/ref/p8c" -lib "${P8P8_LIB:-lib}" -target $target -codegen own -ir -out "$work/b" "$f" > /dev/null 2>&1
                programs=$((programs + 1))
                if [ ! -f "$work/a/$n.asm" ] || ! cmp -s "$work/a/$n.asm" "$work/b/$n.asm"; then
                    echo "seed check FAILED: the two compilers write different assembly for $f ($target)"
                    status=1
                fi
            done
        done
        [ $status -eq 0 ] && echo "seed check: and identical 6502 assembly for $programs programs"
    else
        echo "seed check FAILED: the compiler from the seed and the one from prog8c-llvm differ"
        diff "$work/a/$name.ll" "$work/b/$name.ll" | head -10
    fi
}
[ $status -ne 0 ] && tail -3 "$work/ref.log" 2>/dev/null
rm -rf "$work"
exit $status
