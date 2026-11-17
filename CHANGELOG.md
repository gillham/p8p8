# Changes

## Unreleased

- The compiler itself builds for llvm32 (WebAssembly with WASI) and runs
  under wasmtime, where it checks programs and writes assembly, IR and
  LLVM IR; `make wasihost` compares its output with the native compiler's.
- The compiler runs on 32-bit ARM and RISC-V Linux as well (cross-built, or
  built there from its LLVM IR); on a 32-bit machine programs are for that
  machine by default.  `-Xcompile` passes an argument to clang.
- `make cross` builds and packs the compiler for a 32-bit machine, and
  `make BOOT=p8c` builds it with a p8c that is already installed, which is
  what `make` does on a 32-bit machine.
- `-target llvm32` takes its platform from a triple profile in the library
  (`-triple`): WebAssembly as before, and 32-bit ARM and RISC-V Linux.
- For the 68000 targets (qemu68k, amiga500, amiga1200) the IR has what the
  LLVM branch's 68000 back end needs to build it: the target's options,
  register slots for D0-D7, A0-A6 and FP0-FP7, library offsets in decimal
  and the equates of extsubs.  Building such a program still needs that
  back end; p8p8 has no 68000 code generator.
- Several return values are all computed before any is put in its place.
  On the 68000 a division in a later value overwrote an earlier one.
  Floats among several return values have slots of their own (s25 on), as
  upstream numbers them.
- A first 68000 code generator: `-target qemu68k -build` (or `-o`, `-run`)
  writes assembly for vasm, links with vlink and runs in QEMU;
  `-target amiga1200` and `amiga500` write an AmigaOS program, with
  `%option amiga_chipram` blocks in chip memory.  Variables and
  temporaries live in CPU registers where they can; on six small
  benchmarks (`tools/bench68k.sh`, an Amiga 500 in Copperline) the programs
  take between 0.68 and 0.92 times as long as the reference compiler's
  (0.57 to 0.98 on an Amiga 1200) and are about 10% smaller.
- Fixed, on every target: an element of an array that is a field of a
  struct (`p.values[i]`) was read through the field's first bytes as if they
  were a pointer; `^^Thing t = []` at block level made an empty array where
  an instance belongs; and a `str` parameter compared with a string compared
  the two addresses, not the text.  On the 6502 a struct instance without
  values was not defined at all.
- Fixed in the LLVM back end: the complement (`~`) of a byte or word right
  after arithmetic on a wider type was written as invalid LLVM IR.
- `make coppercmp` compares the screens of upstream's Amiga examples in the
  Copperline emulator, `make amigacmpfloat` the float program on an Amiga
  1200 with an FPU.

## 0.1.0

The first release.  p8p8 is new: it has been run on few programs, and
[docs/DIFFERENCES.md](docs/DIFFERENCES.md) lists where it does not behave
as the reference compiler `prog8c` does.

What is in it:

- **The language** of Prog8 as upstream has it at commit e13ac65c7 (after
  14.0-BETA3): its whole grammar, and the checks of the reference compiler
  that have been ported, with its wording.
- **6502 and 65C02 machines**, with a code generator of p8p8's own that
  writes 64tass assembly: `c64`, `c128`, `cx16`, `pet32`, and the machines
  the library adds (`plus4`, `vic20` and its variants, `mega65`, `f256`,
  `gametank`, and others).  The library's README says how far each has
  been tried.  Any other machine is a properties file.
- **The host**, through LLVM and clang (`llvm64`), which is how p8p8
  compiles itself; also WebAssembly (`llvm32`) and the 6502 through
  llvm-mos (`llvm16`).  Host programs can read keys in raw mode and follow
  the terminal's size.
- **The virtual machine's IR** (`-target virtual -ir`), in upstream's
  `.p8ir` format; upstream's virtual machine runs it.
- **The command line** of `prog8c` where both have the option, and
  `-report <dir>`, which collects everything about one run for a report of
  a problem.
- **Archives** for macOS (arm64), Linux (x86-64, glibc 2.39 or newer) and
  Windows (x86-64).  clang is needed for host programs, 64tass for 6502
  programs.  p8p8 can also be built from this repository with clang alone.

What it was checked with: programs built by p8p8 and by the reference
compiler print the same in the virtual machine, as native executables, and
in emulators of the Commander X16 and the Commodore 64; all of upstream's
C64 and X16 examples build; p8p8 compiled by itself reproduces itself.

Not in it: an optimizer in the front end, the 68000 targets, the 65816 and
the 45GS02, a virtual machine, a language server.
