# AGENTS

p8p8 is a Prog8 compiler written in Prog8.  Its command is `p8c`.  It is an
independent project: "a Prog8 compiler", never "the Prog8 compiler".  The
reference compiler and the language are upstream's
(<https://github.com/irmen/prog8>).

Read `README.md` for what the compiler does and `docs/DESIGN.md` for how it
is put together (`docs/INTERNALS.md` is the long tour, with listings and
measurements of the commit it names: when you change what it shows, bring it
up to date or say that it is behind).  `docs/TARGETS.md` describes target files and where the
library is found.  If `notes/PLAN.md` exists (it is private and not part of
the repository), it is the log of the work: every decision, with what was
tried and dropped.

## Setup check

`make` builds the compiler from `seed/p8c.ll.gz`, its own earlier output,
with clang alone (or, with `make BOOT=p8c`, by an installed p8c: the way on
a 32-bit machine, which the seed does not fit).  The comparison tests and `make BOOT=prog8c` use
`prog8c-llvm` (the LLVM branch of Prog8).  Do not use plain `prog8c`: it has
no llvm targets.

The library that programs are built with is the submodule at `lib/`
(`prog8lib/` is upstream's library and is never edited; additions and
changed modules go in `common/` and `targets/`, see `lib/README.md`).  If
`lib/prog8lib` does not exist, ask the user to run
`git submodule update --init`.

The tests use Prog8's examples and compiler tests from `.prog8-reference`.
If `.prog8-reference/VERSION` does not exist, ask the user to run
`python3 setup.py`, or offer to run it.

## Writing Prog8

The compiler's source is Prog8, so the upstream skills apply:

- `.prog8-reference/.agents/skills/prog8-coder/SKILL.md` when writing or
  reviewing Prog8 (skip it if your tool already loaded it as a skill).
- `.prog8-reference/.agents/skills/asm6502-coder/SKILL.md` for the 6502
  assembly the code generator writes.

For a syntax question, grep the grammar:
`.prog8-reference/parser/src/main/antlr/Prog8ANTLR.g4`.  The standard library
is in `lib/`; never read whole library or example files, grep them.

Things that have bitten here:

- The source must stay portable: `pointer` and `^^type`, not `uquad`, for
  addresses; no local arrays or strings in subroutines that recurse.
- `to`, `call`, `word` and the other keywords and builtin names cannot be
  variable names.
- A `for` loop's range end must fit the loop variable's type.

## Layout

| Path | What |
|---|---|
| `src/` | the compiler; `src/llvm64/*_platform.p8` is the host layer, `src/llvm32/` and `src/wasi32/` what differs on a 32-bit host and on WebAssembly (`make wasihost`) |
| `src/lexer.p8`, `parser.p8`, `symtab.p8`, `resolver.p8`, `typer.p8`, `checker.p8` | the front end |
| `src/irgen.p8`, `irprune.p8`, `ir.p8` | the IR, in upstream's `.p8ir` format |
| `src/gen6502.p8`, `peep6502.p8` | the 6502/65C02 code generator and its peephole passes |
| `src/gen68k.p8` | the 68000 code generator |
| `src/genz80.p8`, `peepz80.p8` | the Z80 code generator and the pass over its assembly |
| `src/gen6809.p8`, `peep6809.p8` | the 6809 code generator and the pass over its assembly |
| `src/gen8086.p8`, `peep8086.p8` | the 8086 code generator and the pass over its assembly (MS-DOS; new) |
| `src/gen68k.p8` | the 68000 code generator (qemu68k and the Amigas; new) |
| `src/llvmgen.p8` | LLVM IR for the host |
| `src/target.p8`, `triple.p8`, `importer.p8`, `main.p8` | target files, triple profiles of llvm32, module lookup, the driver |
| `src/sizemap.p8`, `tools/p8size.py` | the program's map (`-map`) and the tool that reports from it |
| `lib/` | the library programs are built with (a submodule; see its README) |
| `runtime/` | support sources some programs are built with |
| `tests/` | test programs, scripts, expected output |
| `tools/` | helper scripts for the tests and generated sources |

## Build and test

```
make            # build/llvm64/p8c
make check      # syntax check only, fast
make test       # unit tests and dumps
```

Which suite after which change (see the Makefile for all of them):

| Change | Run |
|---|---|
| anything | `make test`, `make bootstrap` (p8c compiled by itself must reproduce itself), `make seedcheck` (built from the seed and built by prog8c-llvm it must be the same compiler) |
| front end | `make programs`, `make roundtrip` |
| IR generation | `make conformance` (quick), `make vmcmp`, `make nativecmp`, `make irroundtrip` (the IR file read back) |
| 6502 code generator or peephole | `BUILDALL_CODEGEN=own make buildall`, `EMUCMP_CODEGEN=own make emucmp`, `EMUCMP_CODEGEN=own make emucmp64` |
| IR generation for 68000 targets | `make qemucmpir` (p8p8's IR through prog8c-llvm's 68000 back end) |
| 68000 code generator | `make qemucmp` (needs vasmm68k_mot, vlink, qemu-system-m68k), `make amigacmp`, `make amigacmp500` (vamos), `make coppercmp`, `make amigacmpfloat` (Copperline) |
| 8086 code generator | `make doscmp` (needs nasm and dosbox-x) |
| the 45GS02 code (`-target mega65`) | `make emucmp65` (needs xmega65; 6502 code against 45GS02 code on the MEGA65) |
| assembly by hand with long addresses | `make farcheck` (x16emu, xscpu64, xmega65) |
| what programs draw | `GFXCMP_CODEGEN=own make gfxcmp` |
| the Apple II's library (`lib/targets/appleii`) | `make a2cmp` (bobbin) |
| the Atari's library (`lib/targets/atari`) | `make ataricmp` (atari800) |
| labels or layout of any code generator's output, `sizemap.p8`, `p8size.py` | `make mapcheck` |

The comparison suites build each program with the reference compiler and
with p8c and compare what they print.  The emulator suites need x16emu and
VICE, take many minutes, and must not run at the same time as each other or
as anything else that uses an emulator: run them in the background, one
after the other.

`tests/conformance/` goes through the language area by area (`make
conformance` runs only those, in the virtual machine and natively; the
emulator suites include them).  Basic behaviour of the language that turns
out to be untested gets a few lines in the program for its area: at most 24
lines of 40 characters of output each, since the C64 comparison is of one
screen, and values passed as parameters so that neither compiler can fold
them.

A new feature gets a test program in `tests/programs/` (the comparison
suites pick it up) and, where it is a dump or an error, an expected file in
`tests/expected/` with a line in the Makefile's `test` target.

## Rules

- **Follow upstream.**  The language, the command line and the behaviour of
  programs match the reference compiler by default.  An option of p8p8's own
  is acceptable when it changes nothing unless it is given; say that it is an
  extension, and list it in the README.
- **Never emit `bbr`, `bbs`, `rmb` or `smb`.**  The 65816 that many Commander
  X16s have does not have them.
- **Adding tests is fine; changing an existing test or its expected output
  needs the user's agreement.**
- **A bug in the compiler p8p8 is built with** is not worked around
  silently: write the smallest program that shows it, with what happens and
  what should, and give it to the user to report.  Such reports are issue
  material and are not committed here.
- **Nothing private in the repository:** no host names of the user's
  machines, no absolute paths from their home directory.
- **Commit finished, verified work** without being asked, with what was
  measured in the message when the change is about size or speed.
- **Report measurements as they are.**  Size and cycle numbers come from a
  build that was just made, with the comparison stated.
- **The sources must compile with the seed.**  Do not use a language feature
  in the compiler's own sources that the compiler in `seed/` does not
  compile yet: implement it, run the tests, refresh the seed (`make seed`,
  with a compiler that passed `make seedcheck`), commit, and only then use
  it.  Do not refresh the seed for any other reason without the user's
  agreement: each refresh adds 2 MB to the history.
- **Keep the documents true.**  A change to how the compiler is put
  together goes into `docs/DESIGN.md`; a new option into the README; anything
  that makes p8p8 behave more or less like `prog8c` into
  `docs/DIFFERENCES.md`.  When
  `notes/PLAN.md` exists, add a dated section there for a piece of work.

## Upstream's sources

`docs/UPSTREAM.md` is how a new upstream is taken in: the notes of the merge,
`make upstreamcheck`, then the suites.

Reading the reference compiler's Kotlin sources helps with questions the
docs do not answer.  They are not part of this repository.  Where a script
needs them (`tools/gen_enctables.py`), it takes the directory of a checkout
from `PROG8_SRC`.
