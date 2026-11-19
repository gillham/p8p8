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

An IR file can be the input too (`p8c program.p8ir`): `irread.p8` reads the
whole file into the same structures `irgen` builds, with `irparse.p8` (which
was there for the libraries' `%ir` blocks) for the instruction lines, and the
program goes on through `irprune` and a back end as generated IR does.  The
test is that p8p8's own IR comes back the same: written, read and written
again it is the same text, and the code made from the file is byte for byte
what the program gives directly (`make irroundtrip`).  For that the file
carries what the code generators take from the program besides the IR, as
attributes of `<PROGRAM>` that upstream's reader passes over: `FLOATS` and
`VARSADDRESS` when set, the order the variables were declared in
(`VARORDER`: the file groups them by kind, and the order decides zero page
addresses) and the registers' types (`REGTYPES`).  A block's chunks and
subroutines are written in source order.  IR that upstream wrote is another
matter: it has opcodes p8p8 does not generate or translate (`storep_inc`,
`loadiz`, `loadmzl`, `bsigb`, `midb`) and a `<LOOP>` element, so only the
simplest programs get through.

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

The zero page is given out in this order: what `@requirezp` names (it is an
error, in upstream's words, when one does not fit), what `@zp` names (as
long as there is room), the pool's cells, and then the other variables by
how often they are named, with more weight for a pointer that is followed
(in the zero page it needs no copy).  `%zpreserved` and `%zpallowed` (the main module's) take bytes out of
what is free before any of that.  `@nozp` keeps a variable out, and a
parameter's tags count like a variable's.  Asked for, a variable of any
size goes there, and an array without values, which the start of the
program clears; an array or string with values does not (its values would
have to be copied in), which is an error for `@requirezp`.  Which zero page
bytes are free is the target file's business.

A float register's cell is used by address and keeps its place, so those are
given out before the others; only the float registers that the code left
after pruning still names get one (the library's float routines that a
program does not call used to cost 250 bytes of cells).

On the C64, the C128 and the PET the library has the virtual registers
R0-R15 outside the zero page.  When the program has the zero page to itself
(`%zeropage kernalsafe`, the default, or `full`; not a library, not with
floats unless the mode is given) they are moved into it, as upstream does,
so that assembly can use one as a pointer: `irgen.zeropage_registers` gives
`cx16`'s memory mapped variables new addresses from the target file's
`virtual_registers_zp` before anything is declared, and those 32 bytes are
not given to variables.

### Programs for ROM

With `%option romable` nothing that is written may be in the program.  A
scalar with an initial value lives with the uninitialized variables and gets
its value from code at the start; the variables have to be somewhere else
(`-varsgolden`, `-varshigh`, `-varsaddress`, `%varsaddress` or the target's
`vars_address`), which is checked as upstream checks it.  What nobody can
check by reading the generator is that none of its code, none of its
peephole passes and no routine of the library writes into the program after
all.  So the assembler checks: `rom_guard` goes over the finished assembly
text and puts, after every instruction that writes to a named or numbered
address, a `.cerror` that fails when that address is inside the program.  A
write to an array with values, a library routine that changes its own code,
a variable that was left in the program: each stops the build with the
instruction named.  A write through a pointer is not seen.

### CPUs

The generator knows the 6502 and the 65C02.  On the 65C02 it uses `stz`,
`bra`, `inc a`/`dec a`, `(zp)`, `tsb` and `trb`.  It never uses `bbr`,
`bbs`, `rmb` or `smb`: the 65816, which many Commander X16s have, does not
have them.  The 65816 and the 45GS02 are planned as further CPUs.

Multiplication, division, shifts by a variable and floating point use the
library's routines, the same ones the reference compiler calls.  A
multiplication by a constant is done in line where that is cheaper: shifts
for a power of two, and shifts and additions for a constant with few bits
set (times 37 is five shifts and two additions).

## The 68000 code generator

`src/gen68k.p8` writes assembly for vasm from the same IR, one IR
instruction at a time.  It
writes programs for qemu68k (a bare 68020 in QEMU, where it can be tested
without an operating system), the Amiga 1200 and the Amiga 500.

- A virtual register is a cell of four bytes with the value at its low end,
  so that a value read narrower than it was written is its low part on a
  big-endian machine too.  d0, d1, a0 and a1 are scratch within one IR
  instruction.
- d2 to d7 keep values from one instruction to the next.  A subroutine's
  own plain variables, the most used ones, get one each for the whole
  subroutine (a pointer that is only loaded, stored and added to gets a2,
  a3 or a4); what is left goes to virtual registers that are only named
  within one chunk, each from its first to its last mention.  Everything
  else is in the frame.  A subroutine saves and restores the registers it
  uses, so a call keeps them; the ones that its calls pass arguments or take
  results in are not used in it, and a subroutine that calls through a
  pointer uses none.  `P8P8_NOREGS` in the environment turns this off.
- A virtual register often needs no place of its own: one that is loaded
  from a variable in a register and not changed is that register; so is a
  copy of a register, or of its low byte or word; one that only holds a
  number or an address is written as that wherever it is used; and "copy
  the base, add the index, use the sum as an address" becomes the addressing
  mode `offset(base,index.l)`; and "load a variable, work on it, store it
  back" is worked on in the variable's register.  Each of these is decided before the code is
  written, by looking ahead in the chunk for anything that changes one of
  the values involved.
- Multiplication, division and remainder by a power of two are shifts and
  masks; a 68020 multiplies and divides longs in the register that holds
  the value.  A subroutine with nothing in its frame has no `link`.  Two things
  are done to the lines as they are written: a value that was just stored
  in its cell is not fetched again, and a `tst` right after the `move` that
  set the same flags is left out.
- The cells of a subroutine are in a stack frame under a5.  So are its own
  plain variables and parameters, when nothing but the subroutine names them
  (no other subroutine, no assembly text, no address taken): that is what a
  subroutine that calls itself needs, and what the reference compiler does
  on this CPU.  The caller still writes an argument to the static parameter;
  the subroutine copies it into its frame when it is entered.
- Floating point is the FPU's.  A float in memory is four bytes, as the
  reference compiler and its library have it; a float register's cell is
  twelve and holds what the FPU had, so a value is only rounded to four
  bytes where the program stores it.
- A subroutine with assembly text in it has no frame, because the text may
  return on its own; its cells are in a static area.
- Arguments of assembly routines go into the registers their declarations
  name, results come from them; a subroutine's own value comes back in d0,
  several values in d0, d1 and so on.  The first two parameters of a
  subroutine that are not floats and that nothing but the subroutine names
  arrive in d0 and d1; the others in their static variables, as before.
- An assembly routine of the library that nothing refers to is left out,
  as for the 6502.
- On the Amiga a routine of a library is called through the library's jump
  table: its base in a6 (exec's from address 4, the others from the
  variables the library's startup code fills), then `jsr offset(a6)`.  The
  sizes and field offsets of structs are written as equates, which the
  library's assembly text uses.  vasm writes the hunk file itself.
- The Amiga 500 has a 68000, which multiplies and divides words only: for
  longs the code calls the routines of the library's `m68k_prog8_longmath`
  (they use utility.library where there is one).  A program with floats is
  assembled for a 68020 with an FPU there too, as the reference compiler
  does it: the floats library needs both.
- A block with `%option amiga_chipram` goes into sections of its own
  (`code_c`, `data_c`, `bss_c`), which AmigaOS loads into chip memory.  A
  call is always `jsr` with an absolute address, so it can cross sections.
- vasm assembles with names in full (`-ldots`), without scopes; vlink lays
  the program out with the target's `link.ld` from the library.

## The 65816

`-cpu 65816` (or `cpu = 65816` in a target's file) gives the same 6502 code
generator a CPU that has everything the 65C02 code here uses, and a 16-bit
accumulator.  The second is where the 6502 family is weakest: adding two
words is six instructions on a 65C02 and three on a 65816.

- **Runs.**  Within a chunk, a run of consecutive IR instructions on words
  is written for the 16-bit accumulator between one `rep #$20` and one
  `sep #$20`.  Inside it one value is in the accumulator; a register that
  was loaded from a variable is that variable until one of them changes, one
  that was loaded with a number is that number, and a second value that is
  still needed waits in one of the two scratch words.  A run names no
  virtual register that is named outside it, because the 8-bit code keeps
  every byte of a register in a cell of its own and the two bytes of a word
  need not be next to each other.  A run that would need more is written as
  8-bit code.  The peephole passes take a run for text.
- **Within a run.**  After a store the accumulator is that variable still,
  so a load of it writes nothing; a store that the next store to the same
  variable overtakes, with no memory named in between, is taken out;
  `(v << n) | (v >> (16 - n))` is a rotation (`asl a` / `adc #0` for one bit
  to the left, `xba` for eight); a comparison that branches on greater or
  less ends a run, unsigned by the carry and signed by the sign of a
  subtraction that `bvc` / `eor #$8000` corrects.
- **From run to run.**  A chunk that begins with a run has a second label
  after its `rep #$20`.  A branch at the end of a run that goes to such a
  chunk (a loop's way back) is taken 16 bits wide to that label, and a run
  that ends where its chunk ends, before a chunk that begins with one, falls
  into it without `sep` and `rep`.  Whatever else jumps to that chunk's own
  label finds it after the subroutine's code: `rep #$20`, and a jump to the
  second label.  So a loop of word arithmetic changes the width once on the
  way in and once on the way out.
- **Native mode.**  16-bit registers only exist in the 65816's native mode.
  Where the machine's ROM is written for programs in native mode (the
  target's `native65816 = rest`: the Commander X16), the entry code switches
  to it around `main.start`, with 8-bit registers as the rest of the code
  and the library's assembly expect, and a call of `sys.exit` switches back
  first.  On any other machine the program stays in emulation mode and each
  run switches for itself: the C64's BASIC ROM divides floats wrongly when
  it is called in native mode.  Where a loop is all runs the switching is
  outside it and costs nothing that can be measured (the word loop of the
  benchmarks: 89 jiffies either way, 366 for the 65C02's code); code that
  alternates between words and bytes pays for each change.
- **Interrupts.**  A subroutine that may run from an interrupt has no runs:
  the X16's ROM calls those in emulation mode.
- Not yet: word arrays (two byte arrays on this CPU family), anything through
  a pointer, values that come from outside a run (a call's result), 16-bit
  index registers, stack-relative addressing, block moves.

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

## A 32-bit host

The compiler builds for llvm32 too, and runs there.  Two host layers lie
over llvm64's, each with only the modules that differ:

- `src/llvm32/`: a 32-bit hosted platform (Linux on ARM).  The C library's
  sizes are 32 bits wide; everything else is as on a 64-bit host.  Source
  directories `src:src/llvm32:src/llvm64`.
- `src/wasi32/`: WebAssembly with WASI, run by wasmtime.  There is nothing
  to run a command or catch a signal with, so this compiler checks programs
  and writes assembly, IR and LLVM IR, and cannot start 64tass or clang.
  Source directories `src:src/wasi32:src/llvm32:src/llvm64`.

On a 32-bit host a program is for that machine by default: llvm32, with the
machine's triple profile.

`make wasihost` builds the WebAssembly compiler and compares what it writes
with the native compiler's: its own source for llvm32 (it reproduces itself)
and for llvm64, and the 6502 assembly of the test programs and examples.
`tests/hostcmp.sh` compares programs on another machine; with `P8P8_CROSS`
they are built here for it and copied with rsync, for a machine without
clang.  `tests/hostbootstrap.sh` with `HOSTCMP_TARGET=llvm32` checks the compiler on a
32-bit machine reached by ssh; `P8P8_HOST_BINARY` gives it a compiler that
was cross-built here.

`make cross` builds the compiler for such a machine and packs it like
`make dist` does, with the library and the documents:

```
make cross TRIPLE=armv7-unknown-linux-gnueabihf SYSROOT=<the platform's sysroot>
```

It needs a clang that knows the platform and links with lld (`CROSS_CLANG`;
Homebrew's is taken where there is one), and writes
`dist/p8p8-<version>-<triple>.tar.gz`.  `CROSS_FLAGS=-static` links the C
library in, for a machine whose own is older than the sysroot's.

The seed is for 64-bit hosts.  The first compiler of a 32-bit machine is
built by a 64-bit one (`make cross`), or from its LLVM IR by the clang of
the 32-bit machine.  From then on the machine builds its own: there `make`
takes the p8c that is installed in place of the seed (`BOOT=p8c`), the
target is llvm32 and the host layer `src/llvm32`, and `make bootstrap`
checks the result as everywhere.  As with the seed, the installed compiler
must know everything the sources use.

The platform of an llvm32 program is not built into the compiler: it is a
triple profile, a properties file of the library (`src/triple.p8`,
[TARGETS.md](TARGETS.md)).  The generator takes the data layout, the name
of `main`, the layout of a directory entry and whether indirect calls are
typed from it, the driver the clang command.  The platforms of llvm64 and
llvm16 are still in `main.p8` and `llvmgen.p8`.

## Not done yet

- `make` and the test suites on Windows: there is the build script, and the
  compiler built on Windows is checked from another host (`make
  hostbootstrap`).
- The 65816 and the 45GS02; a Z80 code generator.
- In the 68000 code generator: registers for values that live across
  chunks, passes over its output, and structs whose fields are at odd
  addresses on a 68000.
- The reference compiler's optimizer has no counterpart in p8p8's front
  end; the 6502 passes and LLVM do that work on their side.
- A compiler that runs on an 8-bit machine.
