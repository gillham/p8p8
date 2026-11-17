# Differences from prog8c

p8p8 compiles the Prog8 language as the reference compiler, `prog8c`, defines
it, and tries to behave the same.  This is the list of where it does not, or
not yet.  It is meant to be complete about the kinds of difference and honest
about how much has been checked; where a statement rests on a test, the test
is named.

"Upstream" below is `prog8c` and its standard library, by Irmen de Jong
(<https://github.com/irmen/prog8>).  p8p8 is compared against its LLVM
branch (<https://github.com/gillham/prog8>), which is a fork of upstream's
compiler with LLVM targets added.

## What is the same

- **The language.**  The parser takes upstream's whole grammar.  Every file
  of upstream's standard library, examples and the two directories of
  compiler test programs loads and checks (`make programs`, `make corpus`).
- **The standard library.**  p8p8 has no library of its own: programs are
  built with upstream's.  Its files are not edited; a few modules are
  replaced by copies with bug fixes or changes for the added targets, which
  the library repository lists.
- **The intermediate representation.**  p8p8 writes upstream's `.p8ir`
  format.  Its IR runs in upstream's virtual machine and builds with
  upstream's IR back ends.
- **The conventions of 6502 programs:** symbol prefixes, how arguments reach
  `asmsub`s, split word arrays, the layout that library assembly expects,
  64tass as the assembler.
- **What programs do.**  Test programs built by both compilers print the same
  in the virtual machine, as native executables, and in emulators of the
  Commander X16 and Commodore 64, and programs that draw end on the same
  picture (`make vmcmp`, `nativecmp`, `emucmp`, `emucmp64`, `gfxcmp`).  All
  of upstream's C64 and X16 examples build (`make buildall`).
- **The language, feature by feature.**  `tests/conformance/` goes through
  the language one area in each program (arithmetic, comparisons, control
  flow, assignments, subroutines, arrays and strings, pointers and structs,
  builtin functions, variables and scopes, floating point, the string and
  conversion modules), with values the compiler cannot know in advance.
  Each prints the same from both compilers in the virtual machine and
  natively, and on the two emulated machines except for one program that
  is skipped there: the remainder of signed numbers, which upstream does
  not have for the 6502.  The set is not complete: it has what one pass
  through the language thought of.

## Targets

| | upstream | p8p8 |
|---|---|---|
| 6502 and 65C02 machines | built in: c64, c128, cx16, pet32; others as custom targets | every machine is a target file, the four built-in ones included; a code generator of p8p8's own |
| 65816 | no | `-cpu 65816`: the 65C02's code, with runs of word arithmetic in the 16-bit accumulator |
| 45GS02 | no | no (planned) |
| 68000 (Amiga and others) | yes | a first code generator of p8p8's own, for qemu68k and the two Amigas, new and with little optimization |
| the virtual machine | yes, with the machine itself | p8p8 writes the IR for it and has no virtual machine: upstream's runs it |
| the host, through LLVM | in the fork's LLVM branch | yes; it is how p8p8 compiles itself |

On a 65C02 p8p8 uses only instructions that a 65816 in emulation mode has
as well (no `bbr`, `bbs`, `rmb`, `smb`), as upstream does.

## The code that is generated

- **A different code generator.**  For the 6502, p8p8 does not use upstream's
  code generator or its output.  It translates the IR one instruction at a
  time and improves the result with its own passes ([DESIGN.md](DESIGN.md)).
  The assembly looks different, has no source lines as comments, and
  variables and temporaries are at other addresses, also in the zero page.
- **No optimizer in the front end.**  Upstream optimizes the program before
  generating code: constant propagation, inlining of small subroutines,
  removal of dead stores and of unreachable code, and more.  p8p8 folds
  constants, removes subroutines and variables that nothing refers to, and
  leaves the rest to its 6502 passes and to LLVM.  Two visible consequences:
  - `inline` on a subroutine is not acted on, except for an `asmsub` whose
    body is put in place of the call as upstream does;
  - upstream sometimes accepts a program because its optimizer changed it
    first (a variable that is never written becomes a constant and may then
    stand where a constant is required).  p8p8 does this for the places
    where it matters, an array initializer and a `when` choice
    (`tests/programs/neverwritten.p8`), not everywhere.
- **Size and speed** are measured on whole programs and are close to
  upstream's default code generator, a little smaller on some programs and a
  little larger on others.  They are not the same and are not meant to be.
- **Floating point on the 6502** goes through the ROM routines, as upstream's
  does.  Some forms of float arithmetic are not implemented in p8p8's
  generator and are reported as an error when a program uses them.
- **The remainder of signed numbers** is not there for the 6502 in either
  compiler.  Upstream says so when it checks the program; p8p8's message
  comes from its code generator and names the instruction.

## Checking and messages

- **Errors.**  p8p8 reports the errors of upstream's that have been ported,
  with upstream's wording.  `tools/checkprobe.py` compares the two compilers
  on 195 small invalid programs: they agree on 182.  In 11 of the others
  p8p8 rejects a program that upstream's `-check` lets through (upstream
  rejects most of them too once the values are used).  Known programs that
  upstream rejects and p8p8 accepts:
  - an `if` expression whose two values have types that cannot be assigned;
  - `unroll` with a count that is not constant;
  - `p^^ = array[i]` where upstream asks for `&`;
  - `w * w` of a signed `word` passed where a `word` is wanted: upstream
    makes it a square, whose type is `uword`, and then reports a type
    mismatch;
  - a `str` assigned to a `long` on a 6502 target.  Upstream's
    documentation says it is allowed on every target; `prog8c` took it for
    the virtual machine only (seen at e13ac65c7).  The LLVM branch takes it
    everywhere since 94f9494c2.

  And the other way round, programs that upstream accepts and p8p8 does not:
  - an `if` expression whose first value begins with a sign and has no
    `then`: `if v < 0 -v else v`.  p8p8 reads `0 - v`; write `then`, or
    parentheses;
  - on a target with addresses wider than a word, an array of `uword`
    initialized with addresses of subroutines.

  An address variable indexed by a signed variable (`ptr[i]`, where an
  array would be refused) is accepted by both and counts backwards for a
  negative index.  For a signed *byte* on the 6502, `prog8c`'s code added
  the index as if it were unsigned (seen at e13ac65c7); p8p8 extends its
  sign, as the virtual machine does, and so does the LLVM branch since
  94f9494c2.

  The values of a multi-value return are computed in the order they are
  written, on every target.  Upstream's 6502 code computes the first one
  last, which shows when the values are calls with side effects; its other
  targets use the written order.

  `len()` of an array that is a field of a struct is accepted by p8p8 and
  refused by upstream.  The address of an element of such a field
  (`&p.values[2]`) crashed `prog8c` (seen at b9fae1820); p8p8 compiles it,
  and so does the LLVM branch since 9ed2fe9ea.

  There will be others: the 195 cases were written here, they are not
  upstream's own test suite.
- **Warnings and notes.**  Upstream prints warnings and information lines
  (a variable made constant, recursion, and so on).  p8p8 prints errors and
  two warnings, and has others on request (`-warnunused`,
  `-warnunreachable`, `-warnshadow`, `-warnall`).
- **Format.**  p8p8's messages are `file:line:column: error: text`, without
  colors.  Parse errors are worded differently (the parser is written by
  hand, not generated from the grammar).

## The command line

Options are upstream's where both have them, with one dash or two.

- **Accepted and ignored**, because they only concern what upstream prints:
  `-plaintext`, `-quiet`, `-quietasm`, `-nosourcelines`, `-timings`,
  `-warnimplicitcasts`, `-ircomments`.
- **Not there** (an error, not ignored): `-D`, `-address`, `-breakinstr`,
  `-profiling`, `-noasm`, `-ignorefootguns`, `-newcodegen`, `-watch`,
  `-daemon`, `-emu2`, and the tools that upstream has built in:
  `-libsearch`, `-libdump`, `-dumpsymbols`, `-dumpvars`, `-gendoc`,
  `-printast1`, `-printast2`, `-float2bytes`, `-bytes2float`, `-vm`,
  `-vmtrace`, `-compareir`.
- **p8p8's own:** `-codegen own|upstream`, `-encoding`, `-lib`, `-libpath`,
  `-verbose`, `-ir`, `-llvm`, `-build`, `-run`, `-report` and
  `-reportnosource` (everything about one run in a directory, to attach to
  a report of a problem), and options that print the compiler's internal
  tables.
- Without an option that says what to do the program is compiled, as by
  upstream: a program file for a machine, the `.ll` file for an llvm
  target.  (Up to 0.1.0 p8p8 only checked a program for an llvm target.)
- `-srcdirs` takes `:` and `;` between directories on every system;
  upstream takes `:` on Unix and `;` on Windows.
- `-codegen upstream` is p8p8's: the program is built from p8p8's IR by
  `prog8c-llvm`'s back end, for the 6502 and the 68000 machines.
- `-cpu 6502|65c02|65816` is p8p8's: the CPU to write 6502 code for, in
  place of the one the target's file names.
- `-Xcompile` is there for llvm32 only.
- `-triple` for llvm32 reads the LLVM branch's profile files, but only the
  keys of the hosted 32-bit platforms ([TARGETS.md](TARGETS.md)); for llvm64
  and llvm16 it takes a few names that are built in.
- The output directory of `-out` or `-o` has to exist.
- One program for each run of the compiler: several source files on one
  command line are not reliable.

## The library

- Upstream carries its library inside the compiler.  p8p8 reads it from a
  directory, which is a repository of its own: upstream's library unchanged,
  with machines, modules, and minor bugfixes that are added beside it
  ([TARGETS.md](TARGETS.md)).
- A machine's description is a properties file in the format of upstream's
  custom targets, with a few keys of p8p8's own (the startup code among
  them, which upstream has in its Kotlin sources for its built-in machines).
- `%import` looks in the same places in the same order; the library has more
  layers.  `-traceimports` shows which file a module came from.

## Things upstream has that p8p8 does not

- the virtual machine, and running a program in it;
- a language server and editor support;
- the syntax files, documentation and examples: those are upstream's and
  apply to p8p8 as they are;
- years of use.  p8p8 is new and has been run on few programs.  Mistakes in
  basic behaviour have been found as late as its first week (where an
  uninitialized local is set to zero, the address of an element behind a
  pointer, the value of a call through a pointer); each now has a test, and
  there will be more of the same.

## Things p8p8 has that upstream does not

- It is written in Prog8 and compiles itself; it is built from its own
  earlier output with clang alone, on macOS, Linux and Windows.
- It starts at once: there is no Java virtual machine to start.
- Every 6502 machine, the built-in ones too, is a text file that can be
  changed without rebuilding the compiler.
