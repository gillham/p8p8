#!/bin/sh
# Programs for ROM (%option romable), for make test.  Prints, and the Makefile compares
# with tests/expected/romable.txt:
#   - what is asked of such a program (its variables moved to RAM), in upstream's words
#   - that an ordinary one builds, with the guard's checks in it (tests/romable/romok.p8,
#     for the 65C02 and the 65816), and one that uses the library's ROM routines
#   - that the assembler stops a write into the program: to an array with values, and
#     by a library routine that changes its own code
#   - a cartridge's layout: nothing of the compiler's lies where the main block's header
#     and its "*= $8017" put theirs
#
# Usage: tests/romcheck.sh <p8c> <output directory>
p8c=$1
out=$2
lib=${P8P8_LIB:-lib}
first() { sed 's/^.*error: //; s/^6502 code generator: //' | head -1 | cut -c1-100; }
echo "-- without a place for the variables"
"$p8c" -lib "$lib" -target cx16 -out "$out" tests/romable/romok.p8 2>&1 | first
for cpu in 65c02 65816; do
    echo "-- an ordinary program, $cpu"
    "$p8c" -lib "$lib" -target cx16 -cpu $cpu -varsgolden -out "$out" tests/romable/romok.p8 2>&1 | first
    [ "$(grep -c 'cerror.*ROMable' "$out/romok.asm")" -gt 100 ] && echo "built, its writes checked"
done
echo "-- the library's routines for ROM"
"$p8c" -lib "$lib" -target cx16 -varsgolden -out "$out" tests/romable/romrnd.p8 2>&1 | first
echo "-- a write to an array with values"
"$p8c" -lib "$lib" -target cx16 -varsgolden -out "$out" tests/romable/romwrite.p8 2>&1 | grep 'error:' | first
echo "-- a library routine that changes its own code"
"$p8c" -lib "$lib" -target cx16 -varsgolden -out "$out" tests/romable/romselfmod.p8 2>&1 | grep 'error:' | first
echo "-- a cartridge"
"$p8c" -lib "$lib" -target c64 -varshigh 1 -out "$out" tests/romable/cartridge.p8 2>&1 | first
# the addresses of the labels, from the assembler's list for VICE: after the startup
# code comes the main block (its payload at $8017), and the compiler's own code for the
# initial values only after all of that
at() { awk -v n=".$1" '$3 == n { print $2 }' "$out/cartridge.vice-mon-list"; }
echo "startup code $(at prog8_program_start), payload $(at p8b_main:p8l_payload) to $(at p8b_main:p8l_payload_end), main.start $(at p8b_main:p8s_start)"
if [ $((0x$(at run_global_inits))) -gt $((0x$(at p8b_main:p8s_start))) ]; then
    echo "the code for the initial values comes after the main block"
else
    echo "the code for the initial values is at $(at run_global_inits): in the way"
fi
exit 0
