#!/bin/sh
# Runs a TRS-80 command file in the emulator trs80gp (a Model I with its DOS) and prints
# what the program printed.  The program must be built with tests/z80/trs80gp.properties:
# its output then goes to the printer too, which trs80gp -batch writes to a file, and it
# ends the emulator through trs80gp's extensions (-ee).  TRS80GP names the emulator when
# it is not in the path.  A window opens for each run.
#
# Usage: tests/trs80run.sh <program.cmd>      (the exit status is 124 when it did not end)
dir=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_trs80.XXXXXX")
trap 'rm -rf "$dir"' EXIT
# (the DOS gets the program under a name it can take)
cp "$1" "$dir/prog.cmd" || exit 2
# (the Model I's boot disk is write-protected; changes to trs80gp's own disks are never kept)
(cd "$dir" && timeout "${TRS80_TIMEOUT:-50}" "${TRS80GP:-trs80gp}" -ee -batch -turbo -im wp 0 off -m1 prog.cmd \
    < /dev/null > /dev/null 2>&1)
status=$?
[ -f "$dir/trs80-printer.txt" ] && cat "$dir/trs80-printer.txt"
exit $status
