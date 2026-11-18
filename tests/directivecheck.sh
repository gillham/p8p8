#!/bin/sh
# What the directives that place things leave in a program for the X16, for make test:
#   %zpallowed, %zpreserved, %varsaddress, %breakpoint   (tests/programs/directives.p8)
#   %output library and %jmptable                        (tests/library.p8)
#   %assert                                              (tests/assertfail.p8)
# Prints the lines that show them; the Makefile compares with tests/expected/directives.txt.
#
# Usage: tests/directivecheck.sh <p8c> <output directory>
p8c=$1
out=$2
lib=${P8P8_LIB:-lib}
"$p8c" -lib "$lib" -target cx16 -out "$out" tests/programs/directives.p8 || exit 1
echo "-- the zero page variables, and where the others begin"
grep 'p8v_pointer[12] = ' "$out/directives.asm"
grep '^  \* = \$4' "$out/directives.asm"
echo "-- the breakpoint, for VICE's monitor (its address left out)"
tail -4 "$out/directives.vice-mon-list" | sed 's/break \$[0-9a-f]*/break $ADDRESS/'
"$p8c" -lib "$lib" -target cx16 -out "$out" tests/library.p8 || exit 1
echo "-- a library begins with a jump to main.start, and main with its jump table"
grep -A1 '^prog8_program_start' "$out/library.asm"
grep -A4 '^p8b_main  .proc' "$out/library.asm"
echo "-- assertions that do not hold"
"$p8c" -lib "$lib" -target cx16 -check tests/assertfail.p8 2>&1
exit 0
