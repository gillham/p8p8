# p8p8

A [Prog8](https://prog8.readthedocs.io/) compiler written in Prog8.

p8p8 is an independent project.  It is not the reference compiler: the Prog8
language, its compiler `prog8c` and its standard library are by Irmen de Jong,
at <https://github.com/irmen/prog8>.  p8p8 compiles the same language, uses
that standard library unchanged, and follows `prog8c` in its command line
where it can.

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

[docs/DESIGN.md](docs/DESIGN.md) says how the compiler is put together.

## Building

p8p8 is built with the LLVM branch of the Prog8 compiler, run as
`prog8c-llvm` (<https://github.com/gillham/prog8>, branch `llvm`).  You need:

- Java 17 or newer and `prog8c-llvm` in your `PATH`
- clang 15 or newer
- make and Python 3
- [64tass](https://sourceforge.net/projects/tass64/) to build 6502 programs
- optional, for the test suites that run programs:
  [x16emu](https://github.com/X16Community/x16-emulator) and
  [VICE](https://vice-emu.sourceforge.io/)

```
git clone --recurse-submodules <this repository>
make                 # builds build/llvm64/p8c
python3 setup.py     # for the tests: Prog8's examples, compiler tests and docs, into .prog8-reference
make test
```

The library that programs are built with is a repository of its own, the
submodule at `lib/`: Prog8's standard library unchanged, with the machines
and modules that are added beside it (see its README).  A `p8c` in
`build/` finds it there.

`setup.py` fetches Prog8's examples, compiler tests and documentation,
which the test suites use.  They are not part of this repository and are
never committed.

To install the compiler with the library it builds programs with:

```
make install PREFIX=~/.local
```

That puts `p8c` in `PREFIX/bin` and the library in `PREFIX/lib/p8p8`, where
`p8c` finds it by itself.

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
`p8c -libpath` prints which.  Run `p8c` without arguments
for the list of options.

For a 6502 machine the program is built with p8p8's own code generator and
64tass.  `-codegen upstream` hands p8p8's IR to `prog8c-llvm` instead, and
`-ir` only writes the IR.

Options p8p8 has that the reference compiler does not:

| Option | What it does |
|---|---|
| `-encoding <name>` | the encoding of string and character literals without a prefix, in place of the target's (`%encoding` in a module and a prefix still override it) |
| `-codegen own\|upstream` | which back end builds a 6502 program |
| `-noopt` | the own code generator without its optimizations |


## Tests

| Target | What it checks |
|---|---|
| `make test` | unit tests and the dumps of the sample files in `tests/` |
| `make bootstrap` | p8p8 compiled by itself compiles itself to identical output |
| `make vmcmp` | test programs run in the reference compiler's VM from p8p8's IR and from the reference compiler's: same output |
| `make nativecmp` | the same for native executables |
| `make buildall` | every C64 and X16 example builds |
| `make emucmp`, `make emucmp64` | programs built by both compilers print the same in x16emu and in VICE |
| `make gfxcmp` | programs built by both compilers draw the same in x16emu |
| `make programs`, `make roundtrip`, `make corpus` | the front end over the whole reference material |

Set `EMUCMP_CODEGEN=own`, `GFXCMP_CODEGEN=own` or `BUILDALL_CODEGEN=own` to
run those suites with p8p8's own 6502 code generator.

## Layout

| Path | What is there |
|---|---|
| `src/` | the compiler |
| `lib/` | the library programs are built with (a submodule) |
| `runtime/` | support code that some programs are built with |
| `tests/` | test programs, scripts and expected output |
| `docs/` | the design, and the description of target files and the library |
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
