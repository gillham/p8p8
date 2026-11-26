# Building for the Atari ST and testing in Hatari

How p8p8's own tests build Atari ST programs and run them in
[Hatari](https://www.hatari-emu.org/) with no window and no hands, and how
to find out why a program stops.  It is written so that the same recipes
work for any project built with `p8c -target atarist`.

Tried with Hatari 2.6.1, TOS 1.04 and the EmuTOS that comes with Hatari.

## Building

```
p8c -target atarist prog.p8              # writes prog.tos
p8c -target atarist -out build prog.p8   # into a directory
p8c -target atarist -map prog.p8         # and prog.p8map, for p8size
p8c -target atarist -asm prog.p8         # only the assembly, prog.asm
```

It needs `vasmm68k_mot` in the PATH (the program file is written by its
`-Ftos`; there is no linker).  The assembly stays beside the program as
`prog.asm`.  A listing with the address of every line, which is what you
want when a crash gives you an address:

```
vasmm68k_mot -m68000 -Ftos -ldots -spaces -quiet -o /dev/null -L prog.lst -Lnf prog.asm
```

Its first lines say how long the sections are; every code line has its
offset in the text section (`00:00000554 ...`).

## Running by hand

Hatari shows a directory of the host as the ST's drive C:, and starts a
program that it is told to:

```
hatari --machine st --memsize 4 --monitor rgb --tos TOS_104.IMG \
       --fast-boot true --harddrive build/ --auto 'C:\PROG.TOS'
```

- Without `--tos` Hatari runs EmuTOS, which is in its package: nothing else
  is needed to try a program.
- `--monitor rgb` starts in the low resolution (40 columns, 16 colours);
  add `--tos-res med` for the medium one (80 columns, 4 colours);
  `--monitor mono` is the high one (80 columns, black and white).
- The directory is the real one: what the program writes there is written
  on the host (`--protect-hd on` forbids it).  GEMDOS's names are 8.3 and
  capitals; a host file with a longer name is not seen as it is called.
- `p8c -target atarist -run prog.p8` starts `${P8P8_HATARI:-hatari}` with
  the program, so `P8P8_HATARI` can hold the options above.

## Running unattended

This is `tests/strun.sh`; the whole of it is:

```
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout -s KILL 30 hatari \
    --machine st --memsize 4 --monitor rgb --tos "$ST_TOS" --fast-boot true \
    --harddrive "$dir" --sound off --fast-forward true --confirm-quit false \
    --conout 2 --log-level fatal --parse debug.ini --auto 'C:\P.TOS' \
    2> hatari.err < /dev/null
```

What each part is for:

| Part | Why |
|---|---|
| `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy` | no window, no sound device |
| `--fast-boot true --fast-forward true --sound off` | a run takes 0.2 to 0.5 seconds |
| `--harddrive "$dir"` and `--auto 'C:\P.TOS'` | the program is started as soon as the desktop is there |
| `--conout 2` | what the program prints on the console comes out of Hatari's stdout |
| `--parse debug.ini` | debugger commands: the breakpoint that ends the run (below) |
| `--confirm-quit false --log-level fatal` | no question at the end, no chatter |
| `timeout -s KILL 30` | a program that waits for a key, or hangs, would never end |

Hatari does not end when the program does: the desktop comes back.  The
debugger ends it.  `debug.ini`:

```
b GemdosOpcode = 0x4c :trace :file quit.ini
b GemdosOpcode = 0 :trace :file quit.ini
```

and `quit.ini`:

```
quit
```

`GemdosOpcode` is the number of the GEMDOS call that is about to be made:
$4c is Pterm (how a p8p8 program ends, also through `sys.exit`), 0 is
Pterm0.  `:trace` keeps the debugger from stopping for a prompt, `:file`
runs the commands of a file when the breakpoint is hit.  Give the files'
full paths: Hatari changes directory while it reads them.

Things that went wrong before this worked:

- **Do not pipe Hatari into `head`.**  When the pipe closes, Hatari is
  ended before the program is.  Write to a file, or pipe into something
  that reads everything.
- **The console text is not the screen.**  `--conout` gives the characters;
  the VT-52 escape codes are swallowed or become newlines, and what goes
  to the screen another way (BIOS device 5, anything drawn) is not there.
  Lines end with CR LF, and EmuTOS prints a few empty lines before the
  program starts.  For comparing: `tr -d '\r'` and drop the empty lines at
  the start.
- **A program that starts another** (Pexec) would end the run at the
  child's Pterm.  The tests have the parent end with Pterm0 and set only
  that breakpoint (`ST_PARENT=1` in `tests/strun.sh`).  A hit count on the
  breakpoint (`:3`) did not end Hatari.
- **Keys cannot be typed this way.**  A program that waits for one runs
  into the time limit.  (Hatari has `--cmd-fifo` and `--control-socket`
  for sending key events; not tried here.)
- **Command line arguments**: `--auto` has no place for them.  The tests
  start the program from a small parent program with Pexec and a command
  tail (`tests/atarist/argsrun.p8`).

## Looking at the screen

A screenshot can be taken when the program ends, from `quit.ini`:

```
screenshot /full/path/shot.png
quit
```

Under `--fast-forward` the picture is a few frames old: the last things
the program drew may be missing.  The screen's memory is always right.  On
the 4 MB machine it is the last 32 KB:

```
savebin /full/path/screen.bin $3f8000 32000
quit
```

`tools/stscreen.py screen.bin <mode>` (mode 0, 1 or 2 for low, medium,
high) prints it as text with the colours that are not the usual ones.  It
knows the characters' pictures from the program itself, which must have
printed the characters 32 to 126 in the screen's last rows
(`tests/atarist/screen.p8` shows how), so it works with any TOS and font.

## When a program stops

Add a trace to the run:

```
--trace gemdos,cpu_exception --trace-file trace.txt
```

`gemdos` lists every GEMDOS call with its arguments, so the end of the
file shows how far the program came: its `Pexec`, the `Mshrink` of the
startup code, its file calls with their names and results.  `cpu_exception`
lists the processor's exceptions:

```
GEMDOS 0x4A Mshrink(0xF096, 0x499A) at PC 0xF638
cpu exception 3 currpc f252 buspc f24e ... fault_e3 f9db op_e3 3183 ...
```

- **Exception 3 is an address error**: a word or a long at an odd address
  (`fault_e3` is the address, `op_e3` the instruction's first word).  A
  68000 does not allow that.  The usual cause in Prog8 is a struct: fields
  are packed, so a `uword` after one `ubyte` is at an odd offset, and so
  is everything in the second element of an array of structs of odd
  size.  Order the fields so that words and longs are at even offsets and
  the struct's size is even.  `pokew` and `peekw` at an odd address do it
  too.  vamos (for the Amiga builds) does not raise this error, and a
  68020 allows the access: the same program can pass there.
- **Exception 2 is a bus error**: an address where nothing is.  TOS 1.04
  makes one of its own while it starts (at `$ffff8a00`, looking for a
  blitter): only what comes after the program's `Pexec` counts.
- Exceptions 11, 28, 30, 33, 34, 45 and 46 are the system's own business
  (line-F calls of TOS 1.04's AES, interrupts, traps).

From the fault to the source: the `Mshrink` line of the startup code has
the base page's address as its first argument; the program's text starts
$100 after it.  `currpc` minus that is the offset in the text section, and
the listing (see Building) has the line.  In the example: $f24e - $f196 =
$b8.

The debugger's other commands work from the same files (`help` in a
`--parse` file lists them): `r` for the registers, `m <address>` for
memory, `d <address>` to disassemble.  A breakpoint on an address with a
file of such commands prints the state there and goes on:

```
b pc = $f24e :trace :file show.ini
```

## The test suites

| Command | What it does |
|---|---|
| `make stcmp` | builds each test program for the host and for `atarist`, runs the second in Hatari and compares what they print |
| `make stscreen` | the text screen in the three resolutions, read back from the screen's memory |
| `make stargs` | the command line, through a parent program |

`ST_TOS=<image>` runs them under that TOS; without it they run under
Hatari's EmuTOS.  `P8P8_HATARI` names Hatari when it is not `hatari` in the
PATH.  The variables that `tests/strun.sh` takes are in its first lines:
`ST_TRACE`, `ST_SCREEN`, `ST_EXTRA`, `ST_PARENT`, `ST_TIME`.

To run one program of your own the same way:

```
ST_TOS=TOS_104.IMG tests/strun.sh build/prog.tos
ST_TOS=TOS_104.IMG ST_TRACE=trace.txt tests/strun.sh build/prog.tos --tos-res med
```

(what follows the program's name goes to Hatari as it is).
