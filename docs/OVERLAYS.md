# Overlays

An overlay is a part of a program's code that is kept outside main memory and
is only there while it runs.  With overlays a program can be larger than the
memory its machine gives it at once.

Overlays are p8p8's own: Prog8's reference compiler has no such thing.  This
page is for writing programs with them.  How the compiler does it is in
[DESIGN.md](DESIGN.md), "Overlays".

## A program with overlays

```prog8
%import textio
%zeropage basicsafe

main {
    sub start() {
        txt.print_uw(report.total(3, 4))
        txt.nl()
        editor.run()
    }
}

report {
    %overlay 1

    uword calls                 ; in main memory, like every variable

    sub total(uword a, uword b) -> uword {
        calls++
        return a + b
    }
}

editor {
    %overlay 2

    sub run() {
        txt.print("editing, after ")
        txt.print_uw(report.calls)
        txt.print(" call")
        txt.nl()
    }
}
```

`%overlay n` in a block puts the code of that block into overlay n.  Nothing
else changes: the block's subroutines are called as before, from the main
program, from other overlays and from the overlay itself, and they call
whatever they like.  The compiler writes what a call needs to get there and
back.

Several blocks may share a number; they are then in the same overlay and
call each other at no extra cost.  The `main` block cannot be in an overlay.

## Building and running

```
p8c -target cx16 -out build game.p8
```

writes two files that belong together: `game.prg` and `game.non`.  Put both
on the same disk or in the same directory and run `game.prg`.

`-meminfo` prints what the main program and each overlay take and what is
left:

```
memory of game (cx16):
  main program  $0801-$0d70   1392 bytes, 37263 free below $9f00
  overlay   1   $a000-$a029     42 bytes, 8150 free of 8192
  overlay   2   $a000-$a07e    127 bytes, 8065 free of 8192
  files: game.prg (the loader) 290 bytes, game.non 1543 bytes
```

An overlay that does not fit is an error from the assembler that names it:
"overlay 2 is too large by 131 bytes".  Move a subroutine to another block.

## The machines

| Machine | Where the overlays are | Where one runs | An overlay holds |
|---|---|---|---|
| Commander X16 (`-target cx16`, also `-cpu 65816`) | RAM bank n of high memory | $a000-$bfff, by choosing the bank | 8 KB |
| C64 (`-target c64`) | a RAM Expansion Unit | $c000-$cfdf, copied in | 4 KB |
| C128 (`-target c128`) | a RAM Expansion Unit | $b000-$bfff, copied in | 4 KB |
| MEGA65 (`-target mega65`) | memory from $40000 on (banks 4 and 5) | $a000-$bfff, copied in by DMA | 8 KB |

On every other machine `%overlay` is ignored and the program is built in one
piece, if it fits.  That is also a way to try a program on the host
(`-target llvm64`) or to compare.

**Commander X16.**  Overlay n is RAM bank n, so the numbers choose the
banks: `%overlay 10` and `%overlay 11` leave banks 1 to 9 alone.  `game.prg` is a small loader:
it reads `game.non`, which has the main program and all overlays in it, and
starts the program.  The banks above the last overlay are the program's.

**C64 and C128.**  `game.prg` is the program itself.  The first time it
calls into an overlay it reads `game.non` from the disk it was loaded from
and puts the overlays into the REU; after that the disk is not needed.  The
overlays take the REU from its start, $1000 bytes each; what the program
keeps there itself belongs behind the last one.  The main program ends
below the window: it has up to $c000 on the C64 and up to $b000 on the
C128.

On the C64 and the C128 a program whose overlays are numbered from 1 uses
the REU from its start; a gap in the numbers is a gap there.

**MEGA65.**  As on the C64, with the machine's own memory in place of an
REU: `game.prg` is the program, and the first call into an overlay reads
`game.non` from drive 8.  Nothing is banked or mapped, so the ROM is where
it always is.  The main program has up to $a000.  Sixteen overlays fit in
banks 4 and 5; a program that keeps data of its own there has to stay clear
of them.

## What is where

**Code is in the overlay; data is not.**  The variables of an overlay block,
its strings and its arrays are in main memory with all the others.  So

- a variable keeps its value whichever overlay is running, and any code may
  use it;
- a string or an array of an overlay block can be passed to any subroutine;
- an overlay does not make a program's data smaller, only its code.

**The library is in main memory.**  `textio`, `diskio` and the rest are
there for every overlay, and are not counted against one.

**The address of a subroutine in an overlay** can be taken, kept and called
(`call(pointer)`) like any other.

## What to keep out of an overlay

- **Interrupt handlers.**  An interrupt comes whatever is in the window.
- **Code that works on banked data, on the X16.**  An overlay runs in the
  window at $a000, so it cannot look at another bank there.  The
  subroutines that read and write a program's own banks (the text of an
  editor, say) belong in a block without `%overlay`; overlays call them.
  The bank a program has chosen is the same after a call into an overlay.
- **Inner loops across two overlays.**  A call into another overlay costs
  more than a plain call (see below).  Put what calls each other often into
  the same overlay, or into the main program.
- **Assembly that jumps into another overlay by its label.**  The compiler
  writes the way into an overlay for calls in Prog8 code; a `jsr` in an
  `%asm` block goes where it says, and what is at that address depends on
  the overlay that is in.

## What a call costs

Within an overlay, and from an overlay into the main program or the library:
nothing more than any call.

Into an overlay from outside it:

- on the X16, a dozen instructions that choose the bank, call, and put back
  the bank that was there: about twice a plain call;
- on the C64, the C128 and the MEGA65, about twice a plain call when the
  overlay is in the window already, and a copy of the overlay's code (as
  many bytes as it has) when another one is.  After the call the caller's
  overlay is brought back if the caller was in one.

Measured, 20,000 calls of a subroutine that adds one to a byte, in jiffies:

| | plain call | into an overlay that is there | 4,000 calls, two overlays in turn |
|---|---|---|---|
| X16 | 8 | 15 | 3 |
| C64 with an REU | 76 | 150 | 72 |
| C128 with an REU | 77 | 156 | 74 |

## When it does not work

| What you see | What it means |
|---|---|
| `?cannot load the program's file` (X16) | the loader did not find `name.non` on drive 8 beside `name.prg` |
| `?cannot load the program's overlays` (C64, C128, MEGA65) | the same, at the first call into an overlay |
| `?overlays need a ram expansion unit` (C64, C128) | no REU answers |
| "overlay n is too large by ... bytes" when building | more code than the window holds |
| "Program too long" when building | the main program reaches the window; on the C64, C128 and MEGA65 it ends below it |

## Trying it in an emulator

The emulator has to find `name.non` as a file on drive 8.

```
cd build
x16emu -prg game.prg -run

x64sc -reu -reusize 512 -devicebackend8 1 -fs8 . +drive8truedrive -trapdevice8 game.prg

c1541 -format "game,p8" d81 game.d81 -write game.non game.non
xmega65 -8 game.d81 -prg game.prg
```

(`x128` takes the same options as `x64sc`.)

## What is not there yet

- An overlay larger than its window, and a window of another size than the
  target file gives.
- Library code in an overlay.
- A check that the REU is large enough for the number of overlays (the
  MEGA65 has room for sixteen, and a higher number is an error).
- Another drive than 8 on the X16 and the MEGA65.
- Overlays in an IR file (`-ir` does not write the directive).
