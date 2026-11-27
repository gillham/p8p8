# Building for the classic Macintosh and testing in MAME

What a program built with `p8c -target macplus` is, how to get it onto a
Macintosh or into an emulator, and how p8p8's own tests run such programs on
a Macintosh Plus in [MAME](https://www.mamedev.org/) with no window and no
hands.

Tried with MAME 0.289, the Macintosh Plus's third ROM, System 4.2 (the
"System 5.0" disks) and System 6.0.8.

## Building

```
p8c -target macplus prog.p8              # writes prog.bin
p8c -target macplus -out build prog.p8   # into a directory
p8c -target macplus -map prog.p8         # and prog.p8map, for p8size
p8c -target macplus -asm prog.p8         # only the assembly, prog.asm
```

It needs `vasmm68k_mot` in the PATH.  `prog.bin` is a MacBinary II file: a
Macintosh file has two forks and a type, which other systems' files have no
place for, and MacBinary is the form that carries them.  The application in
it is named `prog`, has the type `APPL` and three resources: `CODE` 0 and 1
and `SIZE` -1.

## What the program is

- **Any 68000 Macintosh from the Plus on**, System 4.1 or later.  The code
  is for a 68000 and relocates itself when it starts, so it runs wherever
  the system loads it.  The memory it asks for under MultiFinder and System
  7 is its own size and 128 KB, and 128 KB more if there is.
- **The text is in a window**: 80 columns and 25 lines in Monaco 9, black
  on white, in the middle of the screen's width.  `txt.rvs_on()` gives
  white on black.  There are no colours.  The window can be moved by its
  title bar.
- **A menu bar**: the Apple menu with the desk accessories, and File with
  Quit.  It is what lets the Finder's Shut Down end the program, and what
  shows MultiFinder's and System 7's application menu.
- **Quit, command-Q and command-period end the program** whenever it prints,
  waits (`sys.wait`) or reads a key.  A program that computes for a long
  time without doing any of these does not look at the keyboard:
  `macos.poll()` does.
- **At the program's end the window stays**, with "Finished: press a key or
  click" as its title, until that is done.  `macos.quit_at_end = true`
  makes the end immediate.
- **Keys**: `txt.chrin()` waits for one (the place of the cursor is black
  meanwhile); return and enter are `'\n'`, delete is 8, the arrows 28 to 31.
- **Floats** are p8p8's routines for a 68000 (singles).
- **Files**: `diskio`, through the File Manager.  A name alone is a file in
  the current folder, which is the application's when the program starts;
  `:Folder:name` goes down, `Disk:Folder:name` starts at the disk, and
  `diskio.chdir("..")` goes up.  Only data forks are read and written.  A
  new file is a TeachText text file unless `diskio.file_type` and
  `diskio.file_creator` say otherwise.  `diskio.status_code()` is the
  system's error without its sign (43: file not found).
- **Not there yet**: `coroutines`, menus of the program's own, anything
  drawn.
- **In assembly, leave a5 alone.**  It is the system's: QuickDraw finds its
  variables through it.  The Toolbox's calls are the A-line words
  (`dc.w $a9f4`); they change d0-d2 and a0-a1, and Prog8's code wants d2
  kept.  The block `macos` in the target's `syslib.p8` has examples.

**What has been tried.**  The tests run on a Macintosh Plus with System 4.2
and with System 6.0.8, and read keys there (`txt.chrin`,
`txt.input_chars`).  Moving the window, command-Q, command-period, the
arrows and the delete key were tried by hand in Mini vMac, and the test
programs ran there under System 7.0.1, 7.1 and 7.5.5 too, and on an
emulated Macintosh II (a 68020, a colour screen) under 6.0.8 and those
three.  Under MultiFinder they run beside other applications and can be
switched between, the Finder's Shut Down ends them, and Quit and the desk
accessories work from the menus; `diskio`'s test ran there too.

## Getting it onto a disk

With [hfsutils](https://www.mars.org/home/rob/proj/hfs/), into a disk image
that has an HFS volume:

```
hmount disk.dsk
hcopy -m prog.bin :
humount
```

`-m` unpacks the MacBinary file: the application arrives with its resource
fork and its type, and can be started with a double click.  On a Macintosh
itself, a file that came over a serial line or a network as `prog.bin` is
unpacked by any MacBinary tool (StuffIt Expander does it).

## Running unattended

A Macintosh starts from a disk with a System and has no console whose
output an emulator could hand over.  Three things make it work:

1. **The application takes the Finder's place** on the copy of the system
   disk: the Finder is renamed and the application is put into the System
   Folder as `Finder`, which is the program that a Macintosh starts.  (The
   boot blocks have the name of that program, 16 bytes at offset 26, and
   System 4.2 starts what is named there; System 6 starts `Finder`
   whatever they say.)
2. **A file `p8p8.out` beside the application** gets a copy of everything
   the program prints as text (lines end with a carriage return, as a
   Macintosh's text files have it), and makes the program end without
   waiting for a key.  The library looks for the file when the program
   starts; without it nothing is different.
3. **The program says that it is done**: in that unattended mode it writes
   `P8P8DONE` to the system's Scratch8 (the eight bytes at $09FA) before
   it ends.  A script of MAME's sees it and ends the emulator.  The same
   script sees a system error (the bomb): the system keeps its number in
   the word at $0AF0.

`tests/macrun.sh` does all of it and prints the text:

```
MAC_ROMS=roms MAC_SYSTEM=System.dsk tests/macrun.sh build/prog.bin
```

- `MAC_ROMS` is a directory with MAME's ROM files for `macplus`.  MAME
  wants the two chips, not the one file of 128 KB that a Plus's ROM is
  usually kept as: `tools/macrom.py <rom file> <directory>` writes them.
- `MAC_SYSTEM` is a system disk: an image of an 800 KB disk that a Plus
  starts from, with room for the application.  It is only read: the run
  works on a copy.
- `MAC_SCREEN=shot.png` gets a picture of the screen at the end,
  `MAC_TRACE=file` the system error's number, `MAC_TIME` is the limit in
  seconds of the machine's time (120), `MAC_EXTRA` more files for the disk.

The MAME line is

```
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy mame macplus -rompath "$MAC_ROMS" \
    -kbd "" -flop1 boot.dsk -video none -sound none -nothrottle -skip_gameinfo \
    -autoboot_script run.lua -cfg_directory cfg -nvram_directory nvram
```

| Part | Why |
|---|---|
| `SDL_VIDEODRIVER=dummy`, `-video none -sound none` | no window, no sound device |
| `-nothrottle` | as fast as it goes: some 30 times a real Plus, a run takes two to three seconds, most of it the machine's start |
| `-kbd ""` | no keyboard, unless keys are to be typed: MAME's Plus keyboard needs a ROM of its own |
| `-flop1 boot.dsk` | the disk; MAME writes what the machine wrote back into the image when it ends |
| `-autoboot_script run.lua` | the script that watches the memory and ends MAME |
| `-cfg_directory`, `-nvram_directory` | MAME's own files, kept out of the way |

Things to know:

- **Command keys**: `MAC_COMMAND=q` presses that key with the command key,
  four seconds after `MAC_KEYS` was typed.
- **Keys**: `MAC_KEYS='some text\nq'` types that once the program runs
  (MAME's `natkeyboard:post`).  It needs the keyboard's ROM beside the
  machine's (`341-0332-a.bin`); without `MAC_KEYS` the machine is run
  without a keyboard (`-kbd ""`) and does not need it.  A program that
  waits for a key that never comes runs into the time limit.
- **System errors**: 1 is a bus error, 2 an address error (a word or a long
  at an odd address, which a 68000 does not allow: in Prog8 usually a
  struct with a `uword` after one `ubyte`), 3 an illegal instruction, 4 a
  division by zero, 25 and 28 no memory and the stack in the heap.
- **Text that was printed just before a system error is lost**: the copy is
  written in pieces of 256 characters.
- A picture of the screen (`MAC_SCREEN`) is the way to see what a program
  drew; the copy in the file is only what went through `txt.chrout`.

## The test suite

`make maccmp` builds each test program for the host and for `macplus`, runs
the second with `tests/macrun.sh` and compares what they print.  It needs
`MAC_ROMS` and `MAC_SYSTEM`, and with `P8P8_VAMOS` set it takes lines that
depend on the byte order as the Amiga 500's program prints them.
