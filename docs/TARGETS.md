# Target machines

A 6502 machine is described to p8p8 by a text file, in the format of the
upstream compiler's custom targets (a Java properties file).  Nothing about
the Commodore 64, the Commander X16 or any other machine is built into the
compiler: its memory map, zero page and startup code come from such a file,
and changing them is editing it.

```
p8c -target c64 ...                             a name
p8c -target config/mega65.properties ...        a file
```

A name is looked for as

1. `<lib>/<name>/target.properties`
2. `<lib>/targets/<name>/target.properties`
3. `<lib>/targets/<name>.properties`

where `<lib>` is the library directory (see "Where the library is").  The
machines that the upstream compiler has built in (c64, c128, cx16 and pet32)
are files of the library too, with the values of its built-in targets; a
library without them, such as a plain copy of upstream's `prog8lib`, has no
6502 machine for p8p8.

The llvm targets, `virtual` and the 68000 targets are not machines of this
kind and have no file.

## A library in parts

When the `-lib` directory has a `prog8lib` directory in it, it is a library
laid out in parts: `prog8lib/` with upstream's standard library as it comes,
`common/` with shared modules that are added or changed, and
`targets/<name>/` with each machine's `target.properties` and the modules
that are its own (also for a target without a configuration file, such as
llvm64).  A module is then looked for in the `-srcdirs` directories, in
`targets/<name>/`, in `prog8lib/<name>/`, in `common/` and in `prog8lib/`,
in that order, so what is added lies over the standard library without
changing it.  `library:` files of `%asminclude` and `%asmbinary` are found
the same way.

A `library` value that starts with `../` is beside the configuration file's
directory (`library = ../vic20` for a variant that shares another machine's
modules); any other path is from where the compiler runs, as upstream has
it.  The assembler is given the configuration file's directory as an include
directory, for the files its startup code includes.

## Where the library is

1. the directory `-lib` names
2. `P8P8_LIB` in the environment
3. `../lib/p8p8` from the directory the compiler is in (an installed compiler:
   `bin/p8c` and `lib/p8p8`; `make install` puts them there)
4. `../../lib` from there (a compiler in its repository: `build/<host>/p8c`)
5. `.prog8-reference/compiler/res/prog8lib` in the current directory

The compiler's own place is found in `PATH` when it was started by name, and
symbolic links to it are followed.  `p8c -libpath` prints the library
directory that is used.

## The file

`key = value` lines; `#` and `;` start a comment line; a value goes on in
the next line after a backslash at the end; `\n` in a value is a new line.
Numbers are decimal, `$hex`, `0xhex` or `%binary`.  A list of addresses is
`$02-$06,$0a,$9b` (ranges include both ends).

### Keys of the upstream format

| Key | Meaning |
|-----|---------|
| `cpu` | `6502`, `65c02` or `65816` (`-cpu` on the command line chooses another) |
| `native65816` | `rest`: with a 65816 the program runs in native mode from start to end, because the machine's ROM allows it.  Without the key it stays in emulation mode, and the 16-bit runs of the code switch to native mode and back |
| `encoding` | the default text encoding: `petscii`, `iso`, `atascii`, ... |
| `output_type` | `PRG`, `RAW`, `XEX` or `LIBRARY`: the default of `%output`, and what the assembler is asked to write |
| `launcher` | `BASIC` or `NONE`: the default of `%launcher` |
| `load_address` | the default of `%address` |
| `memtop` | the default of `%memtop`: the program must end below it |
| `zp_scratch_b1`, `zp_scratch_reg`, `zp_scratch_w1`, `zp_scratch_w2`, `zp_scratch_ptr` | the zero page cells the library's assembly code uses (`P8ZP_SCRATCH_...`); `zp_scratch_reg` is `zp_scratch_b1` + 1 |
| `zp_fullsafe`, `zp_kernalsafe`, `zp_basicsafe` | the free zero page locations for `%zeropage full`, `kernalsafe` and `basicsafe` |
| `virtual_registers` | where the library has the 32 bytes of R0-R15; when that is in the zero page they are not given to variables |
| `virtual_registers_zp` | (optional) the zero page address R0-R15 are moved to when the program has the zero page to itself (`%zeropage kernalsafe` or `full`) |
| `bss_goldenram_start`, `bss_goldenram_end` | the memory `-varsgolden` puts the variables without an initial value in |
| `bss_highram_start`, `bss_highram_end` | the same for `-varshigh N` (N: the RAM bank, for the library's startup code) |
| `vars_address` | where those variables go when no option says so (`-varsaddress` on the command line) |
| `library` | the directory of the machine's own library modules (syslib and so on).  Without it: `<lib>/<name>`.  The modules all machines share come from `-lib` |
| `custom_launcher_code` | when not empty: the whole launcher and startup code, written after the `* = address` line as it is, instead of what p8p8 writes |
| `assembler_options` | more options for 64tass, before `--output` |

Read by the upstream compiler and not used by p8p8 yet: `io_regions`,
`supports_banked_calls`, `pointer_size`.

### Keys of p8p8's own

These express what the upstream compiler has in its code for its built-in
targets.  The upstream compiler ignores keys it does not know, so one file
serves both.

| Key | Meaning |
|-----|---------|
| `zp_floatsafe` | the free zero page locations for `%zeropage floatsafe` (without it: the basicsafe list) |
| `asm_symbols` | lines for the assembler before the program: symbols the library expects |
| `asm_symbols_floats` | used in place of `asm_symbols` in a program that uses floats |
| `startup_code` | the first instructions of the program, before the stack pointer is saved |
| `startup_code_floats` | instructions before the call of `main.start`, in a program that uses floats |
| `exit_code` | lines after the startup code: routines the library jumps to at the end |
| `reset_address` | what is pushed as the return address of the program when the zero page is not kept (default `sys.reset_system`) |
| `jsrfar_routine` | the routine for a call into another bank (default `<name>.x16jsrfar`) |

## What the zero page lists do

Scalar variables go to the free zero page locations: those with `@zp` or
`@requirezp` first, then the others, the most used first; what is left
goes to the temporary cells of the generated code.  The scratch cells and
`%zpreserved` ranges are taken out, `%zpallowed` restricts the rest.  With
`%zeropage dontuse` nothing is placed there.

## Platforms of llvm32: triple profiles

`-target llvm32` is for 32-bit platforms through LLVM, and which one is a
*triple profile*: a properties file in the format of the LLVM branch of Prog8
(its `llvm-triples` directory), in the library's `triples/` directory.

```
p8c -target llvm32 program.p8                                    # wasm32-wasip1 (on a 32-bit machine: that machine)
p8c -target llvm32 -triple armv7-unknown-linux-gnueabihf program.p8
p8c -target llvm32 -triple config/mine.properties program.p8     # a file of your own
```

| Profile | Platform |
|---|---|
| `wasm32-wasip1` | WebAssembly with WASI, run by wasmtime; the default |
| `armv7-unknown-linux-gnueabihf` | 32-bit ARM Linux |
| `riscv32-unknown-linux-gnu` | 32-bit RISC-V Linux |

The keys p8p8 reads:

| Key | Meaning |
|---|---|
| `triple`, `datalayout` | what the LLVM IR says it is for |
| `c_long_size` | has to be 4 |
| `dirent_name_offset`, `readdir_symbol` | where `readdir()` has a file's name, and its C name |
| `clang_args` | arguments for clang; `${VAR:-default}` is the shell's |
| `link_args` | arguments after the files (`-lm`) |
| `getkey_source` | the console runtime to build along when the program reads keys or asks for the terminal's size |
| `output_extension` | of the program file |
| `run_command` | what `-run` runs, with `{file}` for the program; without it the program itself |
| `strict_indirect_signatures` | calls through a pointer name the exact type (WebAssembly) |
| `c_main_symbol` | the name the C library calls `main` by |

A profile with any other key is refused, so that nothing it asks for is
left out silently: the bare-metal, Z80 and 6809 profiles of the LLVM branch
are not usable yet.  `-Xcompile <argument>` gives clang one more argument
(a sysroot), and can be repeated.  clang is `clang` in the `PATH`, or `P8P8_CLANG`; for
WebAssembly it is Homebrew's (`P8P8_WASM_CLANG`), because Apple's clang has
none.  Building for another machine than the one p8c runs on needs that
platform's sysroot in `clang_args`; `-llvm` writes the LLVM IR to build
there instead.

llvm64 and llvm16 do not read profiles yet: `-triple` takes one of the names
built into p8p8 for them.
