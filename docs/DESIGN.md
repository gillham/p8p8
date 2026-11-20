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

Register numbers are words, one row of them for the whole program, each with
one type.  The code generators for real machines need that: every register
has a place of its own.  On the llvm targets a subroutine is a function with
registers to itself, so there a subroutine takes the numbers that earlier
ones had, and only those of the type it asks for (`ir.new_reg`: a list of
numbers for each type, and how many the subroutine in hand has taken), so the
table of types holds for all of them.  Without that the compiler could not
compile itself any more: it had passed 65,000 registers, and has under 2,000
numbers now.  On the other targets running out is an error, not a silent
start from zero.

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

### The order of the blocks

`main` is first, then the blocks without an address in the order the program
and the libraries have them, then the blocks with an address of their own,
lowest first (`irgen.addressed_blocks_last`; upstream's order).  A block's
address becomes `* = address` in the assembly, and what follows it in the
file is assembled from there: so nothing may follow but blocks that say
where they go themselves.

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
have them.  The 65816 and the 45GS02 have sections of their own below.

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

## The 45GS02

The MEGA65's CPU, and what `-target mega65` writes code for (the target's
file says `cpu = 45gs02`; `-cpu 6502` gives plain 6502 code for the machine).
It is the 6502 generator with two differences.

**Two 65C02 instructions mean something else.**  `stz` stores the Z register,
and `(zp)` is `(zp),z`.  With Z at zero they are the 65C02's.  The generated
code leaves Z at zero wherever it used it, but does not count on finding it
zero (whether the machine's ROM always hands it back so is not settled), so
those two forms are not written; the other 65C02 instructions are
(`c02z` is "a 65C02 for these two as well").  `P8P8_45_STZ` turns them on, to
try.

**Longs are 32 bits in one instruction.**  A, X, Y and Z together are the
register Q, and `ldq`, `stq`, `adq`, `sbq`, `anq`, `orq`, `eoq`, `cpq`, `inq`,
`deq` and the shifts of Q work on four bytes of memory.  `quad_instruction`
writes the long IR instructions with them (loads, stores, the arithmetic and
logic, shifts by a few places, comparisons, the long arguments of a call);
what it does not know goes the 6502's way, a byte at a time.  Between two
such instructions the value stays in Q, and a long that was only fetched from
a variable *is* that variable until something stores there (`qacc`, the
`qalias` tables; the tables of where a register is named are the 65816
runs'), so that `c = a + b` is `ldq a / clc / adq b / stq c`.  Before any
other instruction `q_flush` puts every value where the 6502's code looks for
it.  There is no immediate form: a constant operand is four
bytes of data (`p8_qconst_N`).  A signed comparison is a subtraction whose
sign the overflow flag turns round; the top byte is in Z, so `tza` first.

**Z is zero where the generated code is left**, not after every 32-bit
instruction: before a call, a return, a jump to another subroutine and
assembly text (`z_matters`).  The ROM is written for a Z of zero (BASIC gave
`?SYNTAX ERROR` when a program came back with another); the generated code
itself never counts on it.  Whether Z is zero is known along a chunk and
unknown where another chunk of a subroutine with longs begins.  The `ldz #0`
goes next to the 32-bit code or to the head of the chunk when a call follows
before the next long instruction (`z_wanted_from`): written just before the
call it would stand in the middle of what the peephole passes work on, and
every temporary around it stays alive.  Never between a comparison and its
branch.

**Where the 6502's way is quicker it stays.**  A 32-bit instruction costs
about as much as two or three of a byte.  Incrementing a long in memory
(`inc / bne`) and testing two longs for equality (compare, branch away at the
first byte that differs) are done after one byte most of the time, so those
are written the 6502's way with the names Q's code knows (`q_byte`).

**The flags.**  The instructions that make a value in Q set N and Z for all
32 bits, so a result that is tested against zero needs no comparison
(`qflags`): `if a & 1023 == 0` is `ldq a / anq mask / bne`.  `stq` does not
leave the flags alone: its prefix `$42 $42` is two real `neg a`, which set
them by the low byte.  (Found by a loop of 65536 turns that made 256;
`tests/mega65/qflags.p8` shows it in xmega65.)  So a value is stored before
a comparison, never between it and the branch, and a counter that has to be
stored is loaded again for its flags.

A long comes back from a call in R14 and R15 and is fetched from there into
Q; a long is returned by storing Q there.

**The MEGA65's arithmetic unit.**  The 45GS02 is that machine's CPU, so its
multiplier and divider are there: two 32-bit numbers at `$d770` and `$d774`,
their product at `$d778` at once and the quotient at `$d76c` when the busy
bit of `$d70f` is off.  A long multiplication is five 32-bit instructions.
The divider is unsigned and prog8's longs are not, so a division calls
`p8_qdivs`, which the generator writes into a program that divides longs:
it makes both numbers positive, divides, and gives the quotient its sign
(18 bytes of the register file are its cells).  Bytes and words go the same
way: where the 6502 code calls the library's `multiply_bytes`,
`multiply_words`, `multiply_ubyte_word`, `divmod_ub_asm` or `divmod_uw_asm`,
the 45GS02 code calls `prog8_hw_mulb` and its like, routines the generator
writes into the program that take and give the same but put the numbers into
the arithmetic unit (`math_routine`, `hw_routines`).  Their names begin with
`prog8_` because the peephole passes go by that for "a routine that reads the
scratch words"; under another name the stores of a dividend were removed.
Signed division is still the library's.  `P8P8_45_NOMATH` leaves all of it
to the library's routines.

The lines are written as text the peephole passes do not look into, and a
long register's cell has a fixed place (they would otherwise move and share
it), as a float's has.

64tass's names for these instructions are its own (`adq`, not `adcq`; `asl q`;
none for the negation of Q, which is three bytes `$42`), and a word it does
not know on a line of its own is a label to it, silently.  Library assembly
that switches to `.cpu "45gs02"` for a few lines goes back with
`.cpu "default"`, which is the CPU of the command line (`--m45gs02` when the
program is 45GS02 code).

`tools/benchmega65.sh` times four loops on longs both ways (by the VIC-IV's
frame counter; the jiffy clock stands still in xmega65).  Frames for the
6502 code and the 45GS02 code: addition 65 and 48, multiplication 18 and 1,
division 12 and 0, comparisons 71 and 63; 1,841 and 1,243 bytes.  Words and
bytes: multiplication 40 and 9, 13 and 6; division with remainder 72 and 13,
14 and 6.  The first
version, which made Z zero after every instruction and did everything with
Q, was slower than the 6502 code on two of the four.

**Words in the zero page** are counted up and down with `inw` and `dew`
(`word_step`): one instruction of two bytes.  For variables; where a
temporary will be is not known yet when the code is written.

**Z is not an index register** of the generated code.  It is left for the
28-bit pointers, `[zp],z`.

There is no other compiler to compare with: `make emucmp65` runs each test
program on the MEGA65 (xmega65, without a window) as 6502 code and as 45GS02
code and compares the screens.

## Addresses of more than 16 bits

An extension, where the CPU has the means and the target says the machine
has the memory: `far_address_bits` in the target's file (28 for the MEGA65,
24 for the C64, which counts with a SuperCPU and `-cpu 65816`; the Commander
X16 has the 65816's instructions and nothing to reach with them).  The
driver puts the number into `types.far_bits` when the program's CPU is the
65816 or the 45GS02; everywhere else an address of that size is refused as
upstream refuses it.

A long is a far address.  Pointers stay words: what needs a pointer to far
memory (a typed pointer, an array passed or searched) is refused, and so is
a far address into a word.

A constant address: a memory mapped variable or array
(`&ubyte ATTIC = $8000000`, `ATTIC[i]`), `@(constant)`, `peek` and `poke`
and their relatives.  In the IR those are what they are nearby: a memory
operand with a fixed address or the variable's name, only larger.

An address the program works out: a long variable or expression in `@()`,
in `peek` and `poke`, or with an index (`base[i]`); `&` of a far variable
is a long (the typer, `far_memvar`).  In the IR the load or store goes
through a register as always (`LOADI`, `STOREI`), and the register is a
long, not a pointer; that is how the code generator knows
(`far_indirect`: the register's bytes are the far pointer).

The code generator (`far_instruction`) does every instruction with a far
memory operand in one way: a pointer to the operand goes into the two scratch
words, which are four bytes in a row (three bytes and `[dp],y` on the 65816,
four and `[zp],z` on the 45GS02; the index of an array is added in), the
value is fetched through it into a few bytes of the register file, the
instruction is written as for a variable there, and what it changed is
stored back.  That is not fast (a byte read is some ten instructions) but
whatever can be done to a variable can be done to a far one at once.  On the 65816 a far operand at a known address needs no pointer: the
instruction names the address itself (`lda @l 262144`, and `,x` for an
element; `far_long`).  A plain load or store, of a register, of zero or of
a constant, goes straight between the register and far memory; anything
else still fetches the value, works on it and puts it back, without the
pointer.  These lines are instructions like any other for the peephole
passes, which have to know what becomes of A; the `@l` in front marks the
operand as one that only the accumulator's instructions take, so no pass
makes an `ldy`, `stx` or `stz` of it.  A loop that fills and sums a far
array of 200 bytes 300 times takes 11 jiffies on a SuperCPU where the
pointer took 24.  An address the program works out still goes through the
pointer, as everything does on the 45GS02; there a long is fetched and put
back with one `ldq`/`stq` through the pointer.  The 16-bit runs and the fusing of indexed patterns leave
chunks with far operands alone (the runs had written to the low 16 bits of
the address).

The library's part is the module `farmem` in the two machines' directories
of `lib/targets`: `copy` and `fill` with long addresses, a DMA order on the
MEGA65, `mvn`/`mvp` on the 65816 (the two bank numbers are in the
instruction, so it is put together in a variable and called there; nothing
is written into the program's code).

`make farcheck` runs these programs: the instructions written by hand (the
65816's absolute long, absolute long indexed, `[dp]`, `[dp],y` on the X16 and
the SuperCPU; the 45GS02's `[zp],z` and `ldq`/`stq` through it on the MEGA65)
and `tests/far/fardata.p8` (constant addresses) and `farcomputed.p8`
(worked out ones), where the compiler writes the code, and `farlib.p8`
(the library), on the two machines with far memory.  On the X16 a bank other than 0 is bank 0 again in
x16emu.

Assembly text that switches the CPU for a few lines goes back with
`.cpu "default"`, so p8c gives 64tass the program's CPU on its command line
whatever it is (`--m65c02`, `--m65816`, `--m45gs02`), not only in the file.

## Overlays

An extension: a block with `%overlay n` has its code in overlay n, on a
machine whose target file describes overlays (the Commander X16: a bank of
high memory, in the window at $a000 while its code runs).  Anywhere else the
directive says nothing and the program is built in one piece.

`%overlay n` in a subroutine puts that one subroutine into the overlay,
whatever its block says (`ir.Sub.overlay`; `overlay_prepare` gives every
subroutine the overlay its code is in, and one declared inside another the
overlay of that one).  Such a subroutine is written in its overlay's part
outside its block's scope but under its full name
(`p8b_main.p8s_name  .proc`), so nothing that names it changes.

`%overlay n, name, name...` at module level is the same said from outside:
`irgen.overlay_lists` looks each name up after all blocks are generated
and sets the block's or the subroutine's overlay.

Only code is in an overlay.  The variables, strings and arrays of such a
block are in main memory with all the others (the code generator writes them
outside the blocks anyway), so an overlay is never written back, a value is
there whichever overlay is in, and the same would do for banks of ROM.

The program is still compiled as one: one zero page, one set of names.  The
generator knows for every call where it is and where it goes
(`overlay_entry`): within an overlay and from an overlay into the main
program it is a plain `jsr`; into an overlay from outside it is a `jsr` to a
thunk in main memory, written from the target's `overlay_thunk` (on the X16
the ROM's JSRFAR, which keeps the registers and flags and puts back the bank
that was there, so a program that chooses banks for its data is not
disturbed).  The address of a subroutine in an overlay is its thunk's.
Every subroutine of an overlay block gets a thunk; the assembler leaves out
the ones nothing names.  A target may give two thunks: `overlay_thunk`
keeps A, X, Y and the flags both ways, which a subroutine in assembly may
need, and `overlay_thunk_fast` keeps A, X and Y, which is all an ordinary
subroutine takes and gives.  The X16's are written out for each subroutine
(save the bank, choose, call, put back), without the ROM's JSRFAR: 20,000
calls take 15 jiffies where JSRFAR took 37 and a plain call takes 8.

A call out of an overlay is a plain `jsr` unless the target has
`overlay_return` (the X16).  There the window's bank is also what a program
keeps its data in, and its main part may choose a bank and count on it
staying chosen (a page store that maps a page and remembers that it did).
So the bank register is the main program's own, and the overlay's bank is in
the window only while the overlay's code runs:

- a call from the main program into an overlay (`overlay_thunk`) keeps the
  bank in a byte of main memory, chooses the overlay's, and afterwards
  chooses what that byte holds;
- a call out of an overlay goes to a stub in main memory, one for each
  subroutine and overlay that calls it (`overlay_out`): it chooses the
  main program's bank, calls, keeps what is chosen then, and chooses the
  overlay's bank again (two shared routines, the second one for each
  overlay: `overlay_back`); a call through a pointer has such a stub too;
- a call from one overlay into another (`overlay_thunk_cross`) keeps the
  caller's bank on the stack.

ROM routines called by their address are called as they are.  So are
routines of the library when the calling block has `%option overlay_data`
(`ir.Block.overlay_data`): its overlay stays in the window, because the block
has data beside its code and gives the library the address.  That is not
the default: p8vi's code in an overlay passes an address in a text page on
to `diskio.f_write`, which has to find the text's bank there.  (The first
version put the overlay's bank back after the call, in the overlay: code
that is not there when the call returns.  The second did it in a stub but
left the main program with the overlay's bank, and the editor p8vi read
its text out of its own code.)

In the assembly the overlay blocks come last, each overlay as a segment
that is placed at the window's address when `prog8_overlay` is its number
and is virtual otherwise.  So the driver runs the assembler once for each
overlay and once for the main program (`overlay_build` in `main.p8`), every
run with the same labels, and cuts the overlay's bytes out of its run.  It
writes `name.non`: the main program and the overlays as records of length,
address and bytes (64tass's nonlinear format), an overlay after a record of
one byte at `overlay_select` that chooses it.  Then it assembles the
target's `overlay_loader` as `name.prg`, with the file's name and the
program's entry (read from the assembler's list of labels): on the X16 a
loader that moves itself to $0400 and reads the file, after the X16 Golden
Loader.

On the C64 and the C128 the overlays are in a RAM Expansion Unit and run in
a window of main memory, one at a time ($c000-$cfdf on the C64, $b000-$bfff
on the C128; the program itself then ends below the window).  The thunk is
`jsr p8_overlay.call` with the overlay's number and the subroutine's
address behind it.  That routine is in `overlay_reu.asm`, the target's
`overlay_support`, which the generator includes in such a program: it keeps
the registers and flags, fetches the wanted overlay from the REU when
another is in the window, calls, and fetches the caller's overlay back.
There is no loader: `name.prg` is the main program, and the first call
into an overlay reads `name.non` (the overlays only) from the disk the
program came from and puts each overlay into the REU, overlay n at
(n - 1) * $1000.  The generator gives the support file a table of the
overlays' sizes (`p8_overlay_sizes`, from labels the assembler works out),
so that a fetch moves the overlay's bytes and not the window's: two
overlays in turn, 4,000 calls, take 72 jiffies on a C64 where whole windows
took 1,162.  The fast thunk looks itself whether the overlay is in the
window and calls the support code only when it is not (20,000 calls: 150
jiffies; 398 through the general routine; 76 for a plain call).

The MEGA65 has the same arrangement with its own memory: the overlays are
kept from `overlay_store` on ($40000, bank 4) and the DMA controller copies
one into the window at $a000-$bfff (`overlay_dma.asm`).  Nothing is banked
or mapped, so the ROM stays where it is.

Three checks: assembly text is scanned for `jsr`/`jmp` to the full name of a
subroutine in another overlay (`asm_overlay_scan`, a warning); the IR is
scanned for the address of a subroutine in an overlay that goes to a call
or a store whose name has irq, nmi or cinv in it, or to $0314-$0318
(`overlay_interrupt_check`, an error); and an overlay that the directives
name but that has no code is said.  `-meminfo` lists what is in an overlay
from where each block and lone subroutine begins in the assembler's list
of labels (a symbol that nothing uses is not in that list, so sizes cannot
be symbols of their own), and what the thunks, the stubs and the support
file take in main memory from labels around them.

`-overlayinfo` (`gen6502.overlay_verdicts`, `main.overlay_info`) gives every
block and subroutine a reason why it cannot go into an overlay, or none:
the runtime blocks that the generator names itself, a block with an address,
a name that assembly elsewhere uses (every name in every piece of assembly
is looked up among the subroutines), an interrupt handler, a call of
something with "bank" in its name where the window is the program's too,
and assembly that writes to a place it defines itself (outside a section),
which only matters where an overlay is copied in or is ROM.  What code does
with addresses is not looked at, and the report says so.

After the build the driver removes what the assembler wrote for each part
(`name.ov0`, `name.ov1`...).

The GameTank's overlays are banks of its cartridge, in the window at
$8000-$bfff below the main program, which is in the fixed bank.  Its texts
are the X16's with `cartbank` for the bank register (the routine keeps the
bank it chose in a variable, which is what the thunks read).  The target
gives `overlay_image_size`: the driver then writes one file with the whole
cartridge (`overlay_image` in `main.p8`), bank `overlay_image_first` at its
start and the main program at its end; an overlay's run of the assembler
begins with the overlay, the window being below the program.  The assembler
is only run for the overlays that exist (there are 127 numbers).

Not there: an overlay of more than the window, code of the library in an
overlay, overlays in an IR file (`-ir` does not write the directive).
Assembly in an overlay block that calls another overlay by its label is not
seen by the compiler.  `make overlaycheck` runs programs in x64sc and x128
with an REU, in xmega65 (as 45GS02 and as 6502 code), and three programs in x16emu, as
65C02 code and as 65816 code: there the program is in native mode when it
goes through JSRFAR, and the 16-bit runs are in the overlays as anywhere.

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
