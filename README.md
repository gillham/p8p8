# p8p8

A [Prog8](https://prog8.readthedocs.io/) compiler written in Prog8.

p8p8 is an independent project.  It is not the reference compiler: the Prog8
language, its compiler `prog8c` and its standard library are by Irmen de Jong,
at <https://github.com/irmen/prog8>.  p8p8 compiles the same language, builds
programs with that standard library, and follows `prog8c` in its command
line where it can.

The command is `p8c`.

## What it does

- Reads Prog8 source, checks it, and writes the same intermediate
  representation (`.p8ir`) that the reference compiler writes.
- For 6502 and 65C02 machines it has a code generator of its own, which
  writes 64tass assembly and builds the program.  The Commodore 64, the
  Commodore 128, the Commander X16 and the PET come with it; any other 6502
  machine is described by a properties file in the format of the reference
  compiler's custom targets (see [docs/TARGETS.md](docs/TARGETS.md)).
- For the host it writes LLVM IR and builds a native executable with clang.
  That is how p8p8 compiles itself.

It is a cross compiler.  It runs on macOS, Linux and Windows.  A compiler
that runs on the 8-bit machines themselves is the long-term idea, not what
this is today.

## Status

Experimental.  It compiles itself to a fixed point, builds every example
program of the reference compiler for the C64 and the X16, and its output is
compared with the reference compiler's by the test suites below.  Real
programs have been built with it for the C64, C128, X16, PET, VIC-20, Plus/4,
MEGA65, Foenix F256 and GameTank.  It has had far less use than the reference
compiler, so expect to find bugs.

[docs/DIFFERENCES.md](docs/DIFFERENCES.md) lists where p8p8 differs from
`prog8c`.  [docs/DESIGN.md](docs/DESIGN.md) says how the compiler is put
together.

## Building

p8p8 builds itself.  You need:

- clang 15 or newer
- make
- [64tass](https://sourceforge.net/projects/tass64/) to build 6502 programs

```
git clone --recurse-submodules <this repository>
make                 # builds build/llvm64/p8c
```

`seed/p8c.ll.gz` is the compiler's own earlier output, as LLVM IR.  clang
makes a first compiler of it, that one compiles the sources, and clang makes
`p8c` of the result.  `make bootstrap` checks that `p8c` then reproduces
itself.  The seed is the same file for macOS, Linux and Windows.

On Windows there is a script in place of `make`, which needs clang and
nothing else:

```
powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1
```

It builds `build\llvm64\p8c.exe` from the same seed and checks that it
reproduces itself.

The library that programs are built with is a repository of its own, the
submodule at `lib/`: Prog8's standard library as it comes, and beside it the
machines and modules that are added and a few modules with bug fixes that
take the place of upstream's (see its README).  A `p8c` in
`build/` finds it there.

For the tests, and as a second way to build the compiler
(`make BOOT=prog8c`), you also need:

- Python 3, and `python3 setup.py` once: it fetches Prog8's examples,
  compiler tests and documentation into `.prog8-reference`, which the test
  suites use.  They are not part of this repository and are never committed.
- Java 17 or newer and `prog8c-llvm`, the LLVM branch of the Prog8 compiler
  (<https://github.com/gillham/prog8>, branch `llvm`), in your `PATH`: the
  comparison suites build every test program with it too.
- optional, for the suites that run programs:
  [x16emu](https://github.com/X16Community/x16-emulator) and
  [VICE](https://vice-emu.sourceforge.io/)

To install the compiler with the library it builds programs with:

```
make install PREFIX=~/.local
```

That puts `p8c` in `PREFIX/bin` and the library in `PREFIX/lib/p8p8`, where
`p8c` finds it by itself.

`make dist` (on Windows `tools\build-windows.ps1 -Dist`) makes an archive
with the same layout in `dist/`, to unpack anywhere: `bin/p8c` finds the
library beside it.

## Using it

```
p8c -target c64 -out build program.p8
p8c -target cx16 -srcdirs src:src/cx16 -out build src/main.p8
p8c -target plus4 -out build program.p8              # a machine of the library
p8c -target config/mine.properties -out build program.p8     # or a file of your own
p8c -target llvm64 -out build -run program.p8
```

`-lib` names the library directory.  Without it `p8c` uses `P8P8_LIB` from
the environment, or the library installed with it (`../lib/p8p8` from the
directory `p8c` is in; `lib/` of the repository for one in `build/`);
`p8c -libpath` prints which, and `p8c -version` the version of the compiler
and of that library.  Run `p8c` without arguments
for the list of options.

For a 6502 machine the program is built with p8p8's own code generator and
64tass.  `-codegen upstream` hands p8p8's IR to `prog8c-llvm` instead, and
`-ir` only writes the IR.

A command line written for `prog8c` mostly works as it is: options may
stand before the source file or after it, and may be
written with two dashes, `-emu` is `-run`, and the options of `prog8c` that
only concern what it prints (`-plaintext`, `-quiet`, `-quietasm`,
`-nosourcelines`, `-timings`, `-warnimplicitcasts`, `-ircomments`) are
accepted and ignored.  `-o file` names the program as it
does there: its directory is where the output goes, and its name is that of
every output file.  An option that would change the program and that p8p8
does not have is an error, not ignored.

Warnings about things that are not wrong but may not be meant are asked
for, each kind by its own option:

| Option | Warns about |
|---|---|
| `-warnunused` | a variable, parameter or subroutine that nothing uses |
| `-warnunreachable` | statements after a `return`, `goto`, `break` or `continue` |
| `-warnshadow` | (as `prog8c` has it) the assembler's warnings about symbols that hide others |
| `-warnall` | all of these |

They look at the program's own modules only, and say nothing in a block or
module with `%option ignore_unused`, about a `@shared` variable, or about
the variables of a subroutine or block that has assembly in it.

`-traceimports` prints, as it does for `prog8c`, which file every imported
module comes from and what imported it.  With a library in parts it also says
which file a module takes the place of:

```
[import-trace] Importing module 'syslib' from lib/targets/c128/syslib.p8 (the target's own) - imported by '~implicit~' - in place of lib/prog8lib/c128/syslib.p8
```

p8p8 prints errors and warnings and nothing else.  `-verbose` also prints
the commands it runs and lets the assembler print its summary of the
program's sections and sizes.

Options p8p8 has that the reference compiler does not:

| Option | What it does |
|---|---|
| `-encoding <name>` | the encoding of string and character literals without a prefix, in place of the target's (`%encoding` in a module and a prefix still override it) |
| `-codegen own\|upstream` | which back end builds a 6502 program |
| `-noopt` | the own code generator without its optimizations |
| `-verbose` | print the commands that are run and the assembler's summary |
| `-libpath` | print the library directory that is used |
| `-report <dir>` | write a report of this run into the new directory `<dir>` (see below); `-reportnosource` leaves the program's sources out of it |


## When something goes wrong

If p8c rejects a program it should accept, builds one that misbehaves, or
stops with "internal error", please report it:
<https://github.com/gillham/p8p8/issues> (the form there asks for what is
needed).  The smallest program that shows the problem is the best report.  When that is hard to make, run the same
command once more with `-report` and a directory that does not exist yet:

```
p8c -target cx16 game.p8 -report problem
```

The compiler runs as it would without the option, and writes into
`problem/` everything needed to repeat the run somewhere else:

| File | What |
|---|---|
| `report.txt` | the versions of p8c and of the library, the kind of machine, the command, how the run ended, and every file that was loaded |
| `output.txt` | what the run printed, with the commands it ran and where each module came from |
| `out/` | the files the run wrote: assembly, IR, the program |
| `src/` | the program's own source files |
| `tools.txt` | the versions of 64tass and clang |

**The directory contains your source code.**  Look through it before you
attach it; `-reportnosource` writes the same report without `src/` (the
assembly in `out/` is still made from your program).  Files a program pulls
in with `%asminclude` or `%asmbinary` are not copied.

When the compiler itself crashes, it says in which stage and at which file or
subroutine, and exits with status 70.

## Working on the compiler

Nothing in this section is needed to compile programs with p8c, and none of it
is in a release archive.

### Tests

`make test` and `make bootstrap` need only this repository and its library,
and are what CI runs.  The suites that compare with the reference compiler
need `prog8c-llvm` (from its commit 486bd411 on: two programs of
`tests/conformance` fail on the 6502 with an older one), and the emulator
suites need 64tass, x16emu and VICE as well.

| Target | What it checks |
|---|---|
| `make test` | unit tests and the dumps of the sample files in `tests/` |
| `make bootstrap` | p8p8 compiled by itself compiles itself to identical output |
| `make seedcheck` | the compiler built from the seed and the one built by `prog8c-llvm` write identical output |
| `make conformance` | the programs of `tests/conformance`, one for each area of the language, built by both compilers: same output in the VM and natively |
| `make vmcmp` | test programs run in the reference compiler's VM from p8p8's IR and from the reference compiler's: same output |
| `make nativecmp` | the same for native executables |
| `make buildall` | every C64 and X16 example builds |
| `make emucmp`, `make emucmp64` | programs built by both compilers print the same in x16emu and in VICE |
| `make gfxcmp` | programs built by both compilers draw the same in x16emu |
| `make programs`, `make roundtrip`, `make corpus` | the front end over the whole reference material |

Set `EMUCMP_CODEGEN=own`, `GFXCMP_CODEGEN=own` or `BUILDALL_CODEGEN=own` to
run those suites with p8p8's own 6502 code generator.

### Layout

| Path | What is there |
|---|---|
| `src/` | the compiler |
| `lib/` | the library programs are built with (a submodule) |
| `seed/` | the compiler's own earlier output, which it is built from |
| `runtime/` | support code that some programs are built with |
| `tests/` | test programs, scripts and expected output |
| `docs/` | the differences from `prog8c`, the design, and the description of target files and the library |
| `tools/` | helper scripts for the tests |

## Licence and credits

Prog8 is the work of Irmen de Jong and is licensed under the GPLv3.  p8p8
builds programs with Prog8's standard library and was written with its
documentation and sources as the reference.  The startup code in
the library's `target.properties` files for the C64, C128, X16 and PET is
taken from the Prog8 compiler's sources.

The LLVM support files in `runtime/` (`mos-c64-support.c`,
`windows-console.c` and the helper functions in the `.ll` files) come from
the LLVM branch of Prog8 that p8p8 is built with, which is by the author of
p8p8 and not part of Prog8 itself.

p8p8 is licensed under the GPLv3 too; see [LICENSE](LICENSE).  As with Prog8
itself, the files the compiler generates (intermediate files and the programs
it builds) are excluded: you can do with those whatever you want.
