#!/bin/sh
# Runs a Macintosh application (the MacBinary file that p8c -target macplus writes)
# on a Macintosh Plus in MAME, with no window, and prints what it writes as text.
#
# A Macintosh starts from a disk with its System, and has no console that could be
# listened to.  So: a copy of a system disk gets the application, which is named in
# the disk's boot blocks as the program to start in place of the Finder, and an empty
# file "p8p8.out" beside it: p8p8's library copies the text there when that file
# exists, and says in the system's Scratch8 when the program has ended.  A script of
# MAME's watches for that, and the file is read back from the disk.
#
# Usage: tests/macrun.sh <program.bin>
#        MAC_ROMS    a directory with MAME's ROM files for macplus (tools/macrom.py
#                    makes them of a ROM file)
#        MAC_SYSTEM  a system disk: an 800 KB image that a Macintosh Plus starts
#                    from, with room for the application (it is only read)
#        P8P8_MAME   names MAME when it is not in the PATH
#        MAC_TIME    the limit in seconds of the machine's time (120), counted from
#                    its start; MAC_SCREEN names a file that gets a picture of the
#                    screen at the end (.png); MAC_TRACE one that gets the system
#                    error's number when the program is stopped by one;
#        MAC_EXTRA   more files for the disk (NAME=file, with blanks between them)
#        MAC_KEYS    what is typed once the program runs (\n is the return key); it
#                    needs the keyboard's ROM among MAME's files (341-0332-a.bin),
#                    without MAC_KEYS the machine has no keyboard
# Needs hfsutils (hmount, hcopy) and MAME.
prog=$1
if [ -z "$MAC_ROMS" ] || [ -z "$MAC_SYSTEM" ]; then
    echo "macrun.sh: MAC_ROMS and MAC_SYSTEM must name MAME's ROM directory and a system disk" >&2
    exit 2
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/p8p8_macrun.XXXXXX")
trap 'rm -rf "$work"' EXIT
# (hfsutils keeps the disk that is in use in a file of the home directory: its own here)
hfs() { HOME="$work" "$@"; }
head -c 819200 "$MAC_SYSTEM" > "$work/boot.dsk" || exit 1
: > "$work/p8p8.out"
hfs hmount "$work/boot.dsk" > /dev/null || exit 1
folder=$(hfs hls -a | grep -i '^System' | head -1)
[ -n "$folder" ] || folder="System Folder"
hfs hcopy -m "$prog" ":$folder:" || exit 1
name=$(dd if="$prog" bs=1 skip=2 count="$(dd if="$prog" bs=1 skip=1 count=1 2> /dev/null | od -An -tu1 | tr -d ' ')" 2> /dev/null)
hfs hrename ":$folder:$name" ":$folder:P8P8App" || exit 1
hfs hcopy -r "$work/p8p8.out" ":$folder:p8p8.out" || exit 1
for extra in $MAC_EXTRA; do
    hfs hcopy -r "${extra#*=}" ":$folder:${extra%%=*}" || exit 1
done
hfs humount
# (the boot blocks: the name of the program that is the shell, 16 bytes at 26)
printf '\007P8P8App        ' | dd of="$work/boot.dsk" bs=1 seek=26 conv=notrunc 2> /dev/null
cat > "$work/run.lua" <<LUA
local screen = manager.machine.screens[":screen"]
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local frames = 0
local started = false
local errors = 0
local typing = nil
local function finish(what)
    if what then
        local f = io.open("$work/trace", "w"); f:write(what, "\n"); f:close()
    end
    if "$MAC_SCREEN" ~= "" then screen:snapshot("screen.png") end
    manager.machine:exit()
end
emu.register_frame_done(function()
    frames = frames + 1
    if not started then
        -- CurApName: the application has been started
        if mem:read_u32(0x910) == 0x07503850 and mem:read_u32(0x914) == 0x38417070 then
            started = true
            errors = mem:read_u16(0xaf0)
            typing = frames + 60
        end
    elseif mem:read_u32(0x9fa) == 0x50385038 and mem:read_u32(0x9fe) == 0x444f4e45 then
        finish(nil)
    elseif mem:read_u16(0xaf0) ~= errors then
        -- DSErrCode: the system's last error (it is cleared when a program starts)
        errors = mem:read_u16(0xaf0)
        if errors ~= 0 then finish("system error " .. errors) end
    end
    if typing and frames >= typing then
        typing = nil
        if "$MAC_KEYS" ~= "" then manager.machine.natkeyboard:post("$MAC_KEYS") end
    end
    if frames >= ${MAC_TIME:-120} * 60 then
        finish(started and "time limit" or "not started")
    end
end)
LUA
(cd "$work" && SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout -s KILL 300 "${P8P8_MAME:-mame}" macplus \
    -rompath "$MAC_ROMS" -kbd "${MAC_KEYS:+usp}" -flop1 boot.dsk -video none -sound none -nothrottle -skip_gameinfo \
    -snapshot_directory . -autoboot_script run.lua -cfg_directory cfg -nvram_directory nvram \
    > mame.out 2>&1 < /dev/null) 2> /dev/null
[ -n "$MAC_SCREEN" ] && [ -f "$work/screen.png" ] && cp "$work/screen.png" "$MAC_SCREEN"
if [ -f "$work/trace" ]; then
    [ -n "$MAC_TRACE" ] && cp "$work/trace" "$MAC_TRACE"
    echo "macrun.sh: $(cat "$work/trace")" >&2
fi
hfs hmount "$work/boot.dsk" > /dev/null || exit 1
hfs hcopy -r ":$folder:p8p8.out" "$work/out.txt" 2> /dev/null
hfs humount
[ -f "$work/out.txt" ] && tr '\r' '\n' < "$work/out.txt"
exit 0
