#!/bin/sh
# Does the TRS-80's DOS still work after a program has ended?  A program with floats
# (linked by zcc) and one without are built for the trs80 target as it is, run on a
# Model I and on a Model III (each with its TRSDOS) in trs80gp, and DIR is typed at the
# prompt that should follow; the text of the screen is then saved by the emulator and
# must show the directory.
# (A program once left the DOS damaged in two ways: by overrunning its stack, and
# through zcc's first instructions, which wrote into the DOS's command line.)
#
# Usage: tests/trs80dos.sh <p8c>      (needs z88dk and trs80gp: Z88DK, TRS80GP)
p8c=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
here=$(cd "$(dirname "$0")" && pwd)
lib=$here/../lib
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_trs80dos.XXXXXX")
trap 'rm -rf "$work"' EXIT
bad=0
for f in "$here/hello.p8" "$here/programs/floatlong.p8"; do
    name=$(basename "$f" .p8)
    mkdir -p "$work/$name"
    if ! "$p8c" -lib "$lib" -target trs80 -out "$work/$name" "$f" > "$work/$name/build.log" 2>&1; then
        echo "not built: $f"; bad=1; continue
    fi
    cp "$work/$name/$name.cmd" "$work/$name/prog.cmd"
  for model in -m1 -m3; do
    rm -f "$work/$name/trs80-text-0.bin"
    # (what a directory has on the screen: the Model I's TRSDOS 2.3, the Model III's 1.3)
    words="FILE DIRECTORY"
    [ "$model" = -m3 ] && words="Free Granules"
    # (the options are timed: 900 frames for the DOS to start and the program to run,
    # 600 for the directory; -it saves the text of the screen, -ix ends the emulator)
    (cd "$work/$name" && timeout 90 "${TRS80GP:-trs80gp}" -batch -turbo -im wp 0 off $model prog.cmd \
        -id 900 -i 'DIR\r' -id 600 -it -ix > /dev/null 2>&1)
    # (the Model I keeps capital letters as 1 to 26 in its screen memory)
    if [ -f "$work/$name/trs80-text-0.bin" ] \
            && LC_ALL=C tr '\001-\037' 'A-Z[\\]^_' < "$work/$name/trs80-text-0.bin" | grep -q "$words"; then
        echo "ok: the DOS lists its disk after $name ($model)"
    else
        echo "WRONG: no directory on the screen after $name ($model)"; bad=1
    fi
  done
done
exit $bad
