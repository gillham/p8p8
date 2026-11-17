#!/bin/sh
# Upstream's own benchmark program (.prog8-reference/benchmark-program: ten real
# workloads, each scored by how much it gets done in a fixed time; higher is better)
# on a Commander X16 with a 65816, built three ways: by the reference compiler (65C02
# code), by p8p8 for the 65C02, and by p8p8 for the 65816.
#
# Usage: tools/benchx16.sh [<p8c>]   (from the repository; needs x16emu)
p8c=${1:-build/llvm64/p8c}
lib=${P8P8_LIB:-lib}
src=.prog8-reference/benchmark-program
work=${TMPDIR:-/tmp}/p8p8_benchx16.$$
mkdir -p "$work/up" "$work/c02" "$work/816"
prog8c-llvm -target cx16 -quiet -out "$work/up" $src/benchmark.p8 > "$work/up.log" 2>&1 ||
    { echo "prog8c-llvm does not build the benchmark: $work/up.log" >&2; exit 1; }
"$p8c" -lib "$lib" -target cx16 -srcdirs $src -out "$work/c02" $src/benchmark.p8 > "$work/c02.log" 2>&1 ||
    { echo "p8c does not build the benchmark: $work/c02.log" >&2; exit 1; }
"$p8c" -lib "$lib" -target cx16 -cpu 65816 -srcdirs $src -out "$work/816" $src/benchmark.p8 > "$work/816.log" 2>&1 ||
    { echo "p8c -cpu 65816 does not build the benchmark: $work/816.log" >&2; exit 1; }
for d in up c02 816; do
    # (the emulator does not end by itself: it is stopped when the total is printed)
    (cd "$work/$d" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy exec x16emu -c816 -prg benchmark.prg -run -warp -echo \
        > echo.txt 2>&1 < /dev/null) &
    emu=$!
    waited=0
    while [ $waited -lt "${BENCH_TIMEOUT:-600}" ] && ! tr -d '\000' < "$work/$d/echo.txt" | grep -q '^TOTAL SCORE'; do
        sleep 2
        waited=$((waited + 2))
    done
    kill $emu 2> /dev/null
    wait $emu 2> /dev/null
    tr -d '\000' < "$work/$d/echo.txt" | sed -n '/^SCORE BENCHMARK/,/^TOTAL SCORE/p' | grep -v '^SCORE' | grep '[0-9]' > "$work/$d/scores.txt"
    if ! grep -q '^TOTAL SCORE' "$work/$d/scores.txt"; then
        echo "the $d build did not finish: $work/$d" >&2
        exit 1
    fi
done
paste -d '|' "$work/up/scores.txt" "$work/c02/scores.txt" "$work/816/scores.txt" | awk -F '|' '
    # (the program prints the score and the name with nothing in between, and one name
    # begins with a digit: "5823D MODEL ROTATION" is 582 for "3D MODEL ROTATION")
    function score(s) { sub(/^TOTAL SCORE : /, "", s); sub(/^ */, "", s); sub(/3D MODEL.*/, "", s); return s + 0 }
    function name(s) { if (s ~ /^TOTAL/) return "total"; if (s ~ /3D MODEL/) return "3d model rotation"
        sub(/^ *[0-9]+/, "", s); sub(/\\X[0-9A-F][0-9A-F]/, " ", s); return tolower(s) }
    BEGIN { printf "%-34s %9s %12s %7s %12s %7s\n", "", "upstream", "p8p8 65C02", "", "p8p8 65816", "" }
    { u = score($1); c = score($2); w = score($3)
      printf "%-34s %9d %12d  x%.2f %12d  x%.2f\n", name($1), u, c, c / u, w, w / u }'
echo "bytes: upstream $(wc -c < "$work/up/benchmark.prg" | tr -d ' '), p8p8 65C02 $(wc -c < "$work/c02/benchmark.prg" | tr -d ' '), p8p8 65816 $(wc -c < "$work/816/benchmark.prg" | tr -d ' ')"
rm -rf "$work"
