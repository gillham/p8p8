#!/bin/sh
# Round trip test: for every file given, dump the AST, print the AST back as
# source, parse that and dump again; the two dumps must be identical.
# Usage: tests/roundtrip.sh <p8p8> file.p8 ...
p8p8=$1
shift
tmp=${TMPDIR:-/tmp}/p8p8_roundtrip.$$
mkdir -p "$tmp"
failed=0
total=0
for f in "$@"; do
    total=$((total + 1))
    if ! "$p8p8" -parse -ast -nopos "$f" > "$tmp/a.txt" 2> "$tmp/err.txt"; then
        echo "parse failed: $f"; head -3 "$tmp/err.txt"; failed=$((failed + 1)); continue
    fi
    "$p8p8" -print "$f" > "$tmp/printed.p8"
    if ! "$p8p8" -parse -ast -nopos "$tmp/printed.p8" > "$tmp/b.txt" 2> "$tmp/err.txt"; then
        echo "reparse failed: $f"; head -3 "$tmp/err.txt"; failed=$((failed + 1)); continue
    fi
    if ! cmp -s "$tmp/a.txt" "$tmp/b.txt"; then
        echo "round trip differs: $f"
        diff "$tmp/a.txt" "$tmp/b.txt" | head -6
        failed=$((failed + 1))
    fi
done
rm -rf "$tmp"
echo "round trip: $total files, $failed failed"
[ "$failed" -eq 0 ]
