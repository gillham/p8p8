#!/bin/sh
# Runs an Atari ST program (.TOS) in Hatari, with no window, and prints what it
# writes to the console (Hatari's --conout: the text as it is sent, the VT-52 codes
# as characters).  The program is the only file of a directory that Hatari shows as
# the ST's hard disk; Hatari ends when the program does (a breakpoint on GEMDOS's
# Pterm and Pterm0), or at the time limit.
#
# Usage: tests/strun.sh <program.tos> [hatari options]...
#        P8P8_HATARI names Hatari when it is not in the PATH; ST_TOS names a TOS image
#        (without it Hatari runs the EmuTOS that comes with it); ST_TIME is the limit
#        in seconds (30); ST_TRACE names a file that gets the processor's exceptions,
#        ST_EXTRA more files for the disk (NAME=file, with blanks between them),
#        ST_PARENT=1 for a program that starts others and ends with Pterm0 itself,
#        ST_SCREEN one that gets the screen's memory when the program ends
prog=$1
shift
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_strun.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/c"
cp "$prog" "$work/c/P.TOS" || exit 1
# (ST_EXTRA: more files for the disk, each as NAME=file)
for extra in $ST_EXTRA; do
    cp "${extra#*=}" "$work/c/${extra%%=*}" || exit 1
done
# (the screen's memory is the last 32 KB of the 4 MB)
[ -n "$ST_SCREEN" ] && echo "savebin $ST_SCREEN \$3f8000 32000" > "$work/quit.ini"
echo quit >> "$work/quit.ini"
if [ -n "$ST_PARENT" ]; then
    # (a program that starts others, which end with Pterm: it ends with Pterm0 itself)
    printf 'b GemdosOpcode = 0 :trace :file %s\n' "$work/quit.ini" > "$work/debug.ini"
else
    printf 'b GemdosOpcode = 0x4c :trace :file %s\nb GemdosOpcode = 0 :trace :file %s\n' "$work/quit.ini" "$work/quit.ini" > "$work/debug.ini"
fi
# (in a subshell: the shell's note of a run that the time limit ended is not wanted)
(SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout -s KILL "${ST_TIME:-30}" "${P8P8_HATARI:-hatari}" \
    --machine st --memsize 4 --monitor rgb ${ST_TOS:+--tos "$ST_TOS"} --fast-boot true \
    --harddrive "$work/c" --sound off --fast-forward true --confirm-quit false \
    --conout 2 --log-level fatal ${ST_TRACE:+--trace cpu_exception --trace-file "$ST_TRACE"} --parse "$work/debug.ini" "$@" --auto 'C:\P.TOS' 2> "$work/err" < /dev/null) 2> /dev/null
