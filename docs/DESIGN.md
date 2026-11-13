# The design of p8p8

p8p8 is a Prog8 compiler written in Prog8.  This document says how it is
put together and why.  [TARGETS.md](TARGETS.md) describes target files and
the library; the README has the command line.  [INTERNALS.md](INTERNALS.md)
is the long version: how each part works, with real output.

## Aims

- **Compile the Prog8 language as the reference compiler does.**  The
  language, the standard library, the conventions of generated code and the
  command line are upstream's.  Where p8p8 differs it is by an option that
  changes nothing unless it is given.
- **Be written in what it compiles.**  The compiler is plain Prog8 with
  calls into the C library, no inline assembly, so that it compiles itself
  and stays portable to smaller hosts.
- **Good code for 8-bit machines.**  The 6502 code generator is p8p8's own
  and is measured against the reference compiler's on real programs, for
  size first.
- A compiler that runs on the 8-bit machines themselves is the long-term
  idea.  Nothing in the design should make that harder; it is not built yet.

## The pipeline

```
source ─ lexer ─ parser ─ importer ─ symbols ─ resolver ─ typer ─ checker
                                                                    │
                                     IR generation (irgen) ─ unused code removal (irprune)
                                                                    │
                        ┌───────────────────────┬───────────────────┴──────────┐
                   .p8ir text             LLVM IR (llvmgen)          6502 assembly (gen6502,
              (the reference VM,          then clang:                 peep6502), then 64tass:
               the reference back end)    the host, and p8p8 itself   the 8-bit machines
```

| Stage | File | Notes |
|---|---|---|
| lexer | `lexer.p8` | hand written; newlines are tokens, as the grammar needs |
| parser | `parser.p8` | recursive descent, precedence climbing; the whole grammar |
| importer | `importer.p8` | `%import` against `-srcdirs` and the library, in the order TARGETS.md gives |
| symbols, resolver | `symtab.p8`, `resolver.p8` | scopes, names, `%option merge` |
| typer | `typer.p8`, `types.p8` | types, constant folding, string literal encoding |
| checker | `checker.p8` | the errors the reference compiler reports |
| IR | `irgen.p8`, `ir.p8`, `irprune.p8` | the reference compiler's IR, instruction for instruction |
| back ends | `llvmgen.p8`, `gen6502.p8`, `peep6502.p8` | below |
| driver | `main.p8`, `target.p8` | options, target files, running clang or 64tass |

There is one syntax tree, typed in place.  The reference compiler has two
(a compiler tree and a simplified one); that split is its history and not
something the language needs.

### Why the IR is the reference compiler's

Every back end takes the same intermediate representation, and it is the
`.p8ir` format of the reference compiler, not a format of p8p8's own.  That
buys three things:

- p8p8's IR runs in the reference compiler's virtual machine, so the front
  end can be tested without any back end of p8p8's.
- The reference compiler's back ends accept it (`-codegen upstream`), which
  gives a second way to build every program and to compare.
- A back end written for it once serves both compilers' idea of a program.

For the 6502 machines the IR is already in their conventions: register
arguments of `asmsub`s, split word arrays, the symbol prefixes (`p8b_`,
`p8s_`, `p8v_`) that library assembly expects.

## Conventions of the source

- **Memory is allocated and not freed.**  A compiler is a batch job.
  Allocation goes through `mem.p8` and a platform module, so another host
  can supply its own.
- **Tree nodes** are one record for every kind (kind, position, type, up
  to four children, a name, a value); lists are linked through a `next`
  pointer.
- **Names are interned** (`strtab.p8`) and compared by pointer.  The symbol
  record carries a few fields a back end may use for its own marks.
- **Text is in growable byte buffers** (`buf.p8`), never in Prog8 strings,
  which are static and limited.
- **Portable types:** `pointer` and typed pointers for addresses, never a
  64 bit integer; no arrays or strings as locals of subroutines that
  recurse (Prog8's locals are static).
- **Host specifics** are in `src/<target>/*_platform.p8`: files, the
  environment, running a command.

## Reports of problems

`-report dir` is for the user who has a problem and no small program that
shows it.  The compiler starts itself a second time with the same command
line, the output and the written files redirected into the directory, and
adds the versions, the command, the list of loaded files and copies of the
program's own sources.  It is a second process so that a run that crashes
is reported like any other.

The compiler keeps a note of what it is doing (`crumb.p8`: the stage, and
the file or subroutine where a stage records one).  A handler for the
signals of a crash prints that note and exits with status 70.


`llvmgen.p8` writes LLVM IR text from the IR: a function for each
subroutine, a basic block for each chunk of the IR, and every virtual
register as a stack slot that LLVM's optimizer turns back into a register.
clang builds it.  This is
how p8p8 itself is built, for macOS, Linux and Windows, and how Prog8
programs are built for the host.  A few helper functions that every program
needs are kept as text in `llvmrt.p8`.

## The 6502 code generator

`gen6502.p8` translates the IR to 64tass assembly; `peep6502.p8` improves
what it writes.  The layout of the output (launcher, startup, one scope per
block and subroutine, data, uninitialized data) is what the library's
assembly expects.

### One instruction at a time, then passes over the result

Each IR virtual register has a **cell**, a byte or more of memory.  The
generator translates each IR instruction by itself: operands from their
cells, the result to its cell.  That is simple and always right, and on its
own it is poor code.  All of the quality comes from the passes that run
over each subroutine's lines before they are written out:

- **Jumps:** threading, branches around jumps, unreachable code, labels
  nothing names, a call followed by a return as a jump.
- **Forward, with value numbers** for A, X, Y, the cells, plain variables,
  the virtual registers and the scratch pointer: a load of what a register
  already holds goes, a cell that is a copy of a variable is read as the
  variable, a constant is used as a constant.
- **Backward, with liveness** of A, X, Y, the flags, the carry and the
  scratch pointer: a load or transfer nobody uses goes, as does a store to
  a cell that is written again first.  What is known at each label is kept
  from one pass to the next, so loops are understood on the second round.
- **Stores:** a value stored to a cell and then to a variable is stored to
  the variable; a value stored from both arms of a test is stored once.
- **Operands in place:** a memory operand used where it is instead of by
  way of a cell; a word plus one made in A and Y; arguments computed in the
  order that needs no cell.

Lines the generator does not understand (inline assembly, a few runtime
sequences) are opaque to the passes: everything is forgotten there.

### What a call may change

A call makes the forward pass forget every variable, with three exceptions
that matter a great deal for size:

- a subroutine's **own variables**, when nothing else names them (no other
  subroutine, no assembly, no address taken) and the subroutine cannot be
  running a second time inside the call.  `own_variables` works that out
  from the call graph, where assembly, a call through a pointer or a call
  out of the program may reach any subroutine that assembly names or whose
  address is taken;
- the program's variables over the library's multiply and divide routines;
- cells, which are private to their subroutine.

### Cells and the zero page

Most cells do not survive the passes.  Those that do are short lived, so
cells that are not in use at the same time share storage:

- a few zero page bytes (the **pool**) serve the cells of every subroutine
  that are not in use over a call;
- cells in use over a call share among themselves within their subroutine;
- a subroutine that may run from an interrupt keeps off the pool.

A cell's lifetime is its first line to its last, stretched over a loop it
is in, unless every use is known to come after its first store.

The rest of the free zero page goes to the variables that gain most:
those asked for with `@zp`, then by how often they are named, with more
weight for a pointer that is followed (in the zero page it needs no copy).
Which zero page bytes are free is the target file's business.

### CPUs

The generator knows the 6502 and the 65C02.  On the 65C02 it uses `stz`,
`bra`, `inc a`/`dec a`, `(zp)`, `tsb` and `trb`.  It never uses `bbr`,
`bbs`, `rmb` or `smb`: the 65816, which many Commander X16s have, does not
have them.  The 65816 and the 45GS02 are planned as further CPUs.

Multiplication, division, shifts by a variable and floating point use the
library's routines, the same ones the reference compiler calls.

## Machines and the library

Nothing about a particular machine is in the compiler.  A 6502 machine is a
properties file in the format of the reference compiler's custom targets:
memory map, zero page, startup code.  The machines the reference compiler
has built in are such files too.

The library that programs are built with is a separate repository: the
reference compiler's standard library as it comes, and beside it the
machines and modules that are added and a few modules with bug fixes that
take the place of upstream's.  See [TARGETS.md](TARGETS.md).

## How it is tested

p8p8 has a reference to be compared with, and nearly every test is such a
comparison:

- **The front end over a corpus:** every file of the standard library, the
  examples and the reference compiler's tests must parse, print back to the
  same tree, and load with its imports.
- **Self-hosting:** p8p8 compiled by itself must compile itself to
  identical output.
- **Same behaviour:** test programs built by both compilers must print the
  same, in the reference virtual machine, as native executables, and in
  emulators of the Commander X16 and the Commodore 64; programs that draw
  must draw the same.
- **The language, area by area:** `tests/conformance` has a program for
  each area of the language, with values neither compiler can know in
  advance, compared in all of those places.
- **Everything builds:** each example for the X16 and the C64.
- **Other hosts:** the compiler built on Linux and Windows must reproduce
  itself there.

Size and speed are measured on whole programs against the reference
compiler's output, not on fragments.

## Building itself

p8p8 is built from a **seed**: its own output for its own sources, as LLVM
IR (`seed/p8c.ll.gz`).  clang makes a first compiler of the seed, that one
compiles the sources, and clang makes `p8c` of the result.  No other Prog8
compiler is needed.  The IR for macOS and Linux differs only in two target
lines, which the seed leaves out, so it is one file for both.  For Windows
four functions of the C library have other names; `tools/build-windows.ps1`
renames them where the seed calls or declares them, which gives exactly the
IR the compiler writes for Windows, and builds from that.

Two things keep this honest:

- `make bootstrap`: `p8c` compiles itself again, and the result must be
  identical.
- `make seedcheck`: the reference compiler's LLVM branch builds p8p8 from
  the same sources, and that compiler and the one from the seed must write
  identical output, for the compiler's own sources and for the test programs
  through the 6502 code generator.  A compiler that only ever builds itself
  could carry a mistake along from seed to seed; the first compiler p8p8
  built of itself did have mistakes that this comparison found.

The seed is refreshed (`make seed`) when the compiler's sources start to
use something that the compiler in the old seed does not compile, and for
releases.  Because the sources must always be compilable by the seed, a new
language feature is first implemented, then the seed refreshed, and only
then used in the compiler's own sources.

## Not done yet

- `make` and the test suites on Windows: there is the build script, and the
  compiler built on Windows is checked from another host (`make
  hostbootstrap`).
- The 65816 and the 45GS02; a Z80 or 68000 code generator.
- The reference compiler's optimizer has no counterpart in p8p8's front
  end; the 6502 passes and LLVM do that work on their side.
- A compiler that runs on an 8-bit machine.
