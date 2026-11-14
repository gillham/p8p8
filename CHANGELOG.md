# Changes

## Unreleased

Nothing yet.

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
