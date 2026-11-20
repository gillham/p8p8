#!/bin/sh
# The system calls of the cpm target beyond the console: the command line, the wait and
# the clock (tests/z80sys/args.p8) and files (tests/z80sys/files.p8), run in tnylpo.
# What they print is compared with tests/z80sys/expected.txt.
#
# Usage: tests/z80sys.sh <p8c>      (needs z88dk-z80asm (Z88DK) and tnylpo)
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_z80sys.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/build" "$work/disk"
for name in args files; do
    if ! "$p8c" -lib "$lib" -target cpm -out "$work/build" "$here/z80sys/$name.p8" > "$work/build/$name.log" 2>&1; then
        echo "not built: $name: $(grep -v warning "$work/build/$name.log" | head -1)"; exit 1
    fi
done
# (the directory that the files test lists has the program and what it leaves, no more)
cp "$work/build/files.com" "$work/disk/files.com"
{
    (cd "$work/build" && tnylpo args.com one two  three < /dev/null)
    (cd "$work/build" && tnylpo args.com < /dev/null)
    # (the order of a directory is the host's: the names are sorted here)
    (cd "$work/disk" && tnylpo files.com < /dev/null) | tr -d '\r' > "$work/files.txt"
    sed -n '1,7p' "$work/files.txt"
    sed -n '8,$p' "$work/files.txt" | sort
} | tr -d '\r' > "$work/printed.txt"
if diff -u "$here/z80sys/expected.txt" "$work/printed.txt"; then
    echo "system calls on CP/M: as expected"
else
    exit 1
fi
