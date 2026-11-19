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
  take between 0.68 and 0.80 times as long as the reference compiler's
  (0.57 to 0.87 on an Amiga 1200) and are about 10% smaller.
- Fixed, on every target: an element of an array that is a field of a
  struct (`p.values[i]`) was read through the field's first bytes as if they
  were a pointer; `^^Thing t = []` at block level made an empty array where
  an instance belongs; and a `str` parameter compared with a string compared
  the two addresses, not the text.  On the 6502 a struct instance without
  values was not defined at all.
- 6502: a multiplication by a constant with few bits set is shifts and
  additions in line, not a call of the general routine.  A loop over a word
  array that multiplies by 37 went from 168 to 63 jiffies on an X16 (the
  reference compiler's code takes 64); `tools/bench65.sh` measures this.
- A first code generator for the 45GS02, the MEGA65's CPU, which
  `-target mega65` now writes code for (`-cpu 6502` for plain 6502 code).  Longs are loaded, combined, compared and stored with the
  32-bit instructions (`c = a + b` is four instructions), which makes a test
  of long arithmetic 876 bytes where the 6502 code is 1,501.
  Long results and returns go through the 32-bit register, and long
  multiplication and division use the MEGA65's arithmetic unit (a test of
  long division: 941 bytes against 1,997).
  `make emucmp65` compares the two kinds of code for every test program in
  xmega65, and `tools/benchmega65.sh` times loops on longs: additions take
  48 frames where the 6502 code takes 65, comparisons 63 against 71,
  multiplications 1 against 18.  Bytes and words are multiplied and
  divided by the machine's arithmetic unit too (a loop of word
  multiplications: 9 frames against 40; of divisions: 13 against 72).
- Far memory, an extension: on the MEGA65 and on a C64 with a SuperCPU a
  long constant is an address of data.  Memory mapped variables and arrays
  (`&ubyte ATTIC = $8000000`, `ATTIC[i]`), `@(...)`, `peek` and `poke` and
  their relatives, with a constant or with a long that the program works
  out (`@(base + i)`, `base[i]`); `&` of a far variable is a long.  The
  target's file says how many bits
  (`far_address_bits`).  `make farcheck` runs the test on both machines.
- The library module `farmem` for those two machines: `copy` and `fill`
  with long addresses (the MEGA65's DMA, the 65816's block moves).
- Fixed: `pokel(address, -5)` stored 251: a value narrower than what is
  stored lost its sign.
- Fixed: an address of more than 16 bits in `@(...)`, in `peek` and `poke`
  and their relatives, or as an indexed constant was accepted on the 6502
  machines and cut to 16 bits without a word.  It is refused, as upstream
  refuses it ("invalid address type for memory access").
- 45GS02: a word variable in the zero page is counted with `inw` and `dew`.
- `make farcheck`: the 65816's four long addressing modes and the 45GS02's
  `[zp],z`, tried by hand in assembly on three emulators.  The compiler does
  not write them yet.
- Fixed: a program for the 65C02 or the 65816 with assembly text that ends
  in `.cpu "default"` was plain 6502 from there on and did not assemble;
  64tass gets the program's CPU on its command line now.
- Fixed: a program with more than 65,535 IR registers was compiled wrongly
  without a word (the numbers began again at zero).  p8p8's own source had
  reached that size.  For the llvm targets subroutines now share register
  numbers, so the size of a program does not matter; for the others it is an
  error.  The seed is new: the one before cannot compile this source.
- Fixed: a block with an address of its own (`data $9000 { ... }`) that
  was not the last block of the program took everything after it along
  to that address.  Such blocks now come after all the others, lowest
  address first, as upstream orders them.
- Constants as upstream works them out: `&`, `|` and `^` of signed byte
  or word constants give the unsigned pattern (`-1 & -15` is 241), a long
  written past its range wraps (`-2147483649` is 2147483647),
  `math.atan2()` of constants is a constant, and `1.0 to 3.0` fills an
  array of floats.  A number of more than 32 bits is refused on the 6502
  machines also where it is folded away (`lsb($1_0000_0012)`).
- An IR file as input: `p8c program.p8ir` builds the program from the IR
  that `p8c -ir` wrote, to the same bytes as from the source
  (`make irroundtrip`).  IR written by upstream mostly does not build: it
  uses instructions p8p8's back ends do not have.
- Another seventy of upstream's checks, found by running every example of
  its documentation through both compilers again: variable tags that do
  not exist or do not apply, numbers where booleans belong and the other
  way round, a subroutine with several values used as one, the rules for
  register parameters and bank subroutines, struct field kinds, `sizeof`
  of things without a size.  `tests/bad_upstream2.p8` has a sample.
- Programs with floats need 250 bytes less memory: the float registers of
  library routines that the program does not call no longer get a place.
- Fixed: the parser of `%ir` blocks wrote outside its operand table.
- About seventy checks that upstream makes and p8p8 did not, with
  upstream's messages (`tests/bad_upstream.p8` has a sample): a long used
  as an address or a pointer used as a long where addresses are words, the
  name of a subroutine used as a value, a cast that would cut a constant
  down (`300 as ubyte`), pointers to different things assigned to each
  other, struct and union initializers, enum values, `private public`,
  `[rows,cols]`, a BASIC program that does not load at BASIC's address,
  and more.  Of upstream's 1,362 unit test programs, 9 that it refuses
  still build, 5 of them because upstream itself fails on them.
- New: a loop's own variable can be used before the loop; a label can be
  called; `math.sin8u()` and its relatives, `math.log2()`, `math.diff()`
  and `strings.isdigit()` of constants are worked out when compiling; the
  `.bankedcalls` file; `-run program.p8 -- arguments`; the options
  `-address`, `-D`, `-O`, `-Xlink`, `-clang`, `-breakinstr`, and upstream's
  names `-noasm`, `-dumpsymbols`, `-ignorefootguns`.
- A constant declared without a type counts as the number it is inside an
  expression (`v + A` with `const A = 200` is byte arithmetic), as
  upstream has it.
- More from upstream's documentation.  New: `setlsb`, `setmsb`, `rsave`,
  `rrestore`, `memory("name")` alone, `for ... via .field until node` and
  such a loop without a declared variable, `%asminclude` and `%asmbinary`
  inside a subroutine or as all of an asmsub, an enum's members for
  assembly (`p8c_Enum_MEMBER`), `[6] * 10` for an array of words, floats in
  `%assert`, `repeat 2.5`, `clamp` of a long and `in` with an array of
  longs or floats for the 6502, `-h`, `-help`, `-target llvm`.
- Put right: `pokemon()` was compiled as `pop()`; `msb()` and `msw()` of a
  64-bit value took the top of the low half; `float in [1.0, 3.5]` compared
  whole numbers; `@align64` and the other alignment tags were not applied
  to every array on the hosted targets; `monogfx` did not build (a
  subroutine's `@shared` array that only a nested subroutine's assembly
  names was dropped).
- On the C64, C128 and PET the virtual registers R0-R15 are in the zero
  page with `%zeropage kernalsafe` and `full`, as upstream has them, so
  assembly can use `(cx16.r0),y`.
- Refused now, as upstream does: a statement in a block outside any
  subroutine, and the assignment of one array to another.
- Follows Prog8 master at df16719e7 and the LLVM branch at e261d6c6d: `petgfx`
  with drawing modes, `clear_screen` and `line`, on the X16 as well; the Amiga
  `sprites` module; the Amiga `text` module is `gfxtext` now.
- Found by reading upstream's documentation against p8p8, and put right:
  `ubyte a, b, c = 42` gave the value to `a` only; `pointer^^.field`
  followed the pointer twice; the difference of two pointers was in bytes,
  not elements; an array of two-byte structs was split like a word array;
  `for x in array step -1` ran forwards; a subroutine with several values
  that ended without a `return` gave the last call's; enum members above 255
  were cut to a byte; `value as bool` looked at the low byte only;
  `sizeof()` of a string variable was a pointer's; a constant without a
  type is a long.
- `@alignword`, `@align64` and `@alignpage` were checked and then ignored.
- The names of structs, blocks, aliases, enums and fields cannot be keywords;
  an enum needs a member; `%option amiga_chipram` is for the Amigas.
- A block's assembly, labels, included files and subroutines are written in
  the order of the source (the block's own chunks used to come first).
- From upstream's unit tests (`tools/kttests.py`): `offsetof(Struct.field)`;
  struct types are defined for the assembler (`#size(p8t_Node)`,
  `#p8t_Node.p8v_value`); `Name::MEMBER` through an alias of an enum; the
  address of an element of a constant address, of a word that holds one and
  of a memory mapped array (the last gave the array's address, without the
  index); constants that are a block of `memory()` or a string;
  `return other()` between subroutines that return nothing; a constant
  float cast to an integer is worked out by the compiler.
- Programs for ROM (`%option romable`): the variables have to be moved to
  RAM and floats are not available, as upstream requires, and the assembler
  now stops when anything in the program, the library's assembly included,
  writes to an address inside the program.
- The blocks of a program come right after its startup code, `main` first,
  as upstream lays a program out; the code for the variables' initial
  values was in between, where a cartridge's header lines wrote over it.
- `%asmbinary` and `%asminclude` find a file by its path as it is written,
  from where the compiler runs, as well as beside the source.
- Struct fields may share a line.  The 6502 code generator converts longs
  to floats and back, and returns a float next to other values.
- Directives that p8p8's 6502 code generator took no notice of now work as
  upstream's: `%zpallowed`, `%zpreserved`, `%varsaddress`, `%jmptable` and
  `%breakpoint` (the breakpoints are listed for VICE's monitor).  `%assert`
  took any expression with a name in it for not constant.
- A library (`%output library`) begins with a jump to `main.start`, with
  `main` and its jump table right after it; it had a program's startup code
  there.
- `@zp` and `@requirezp` are told apart, as upstream does: what `@requirezp`
  names is placed first and is an error when it does not fit ("no more
  free space in ZP"), what `@zp` names is placed when there is room.  Both
  work for longs, floats and arrays without values, and on parameters.
- An in-place operation on `@(address)` works the address out once, as
  upstream does: a call in it was made twice.
- Faster 6502 code for bytes through a pointer with a byte index, sums of
  such bytes, words that bytes are added to, and a constant times a variable.
- Float expressions on the 6502 keep their result in the ROM's FAC1 from
  one operation to the next and take variables and constants from where
  they are; a word times itself uses the library's square routine.
- On upstream's benchmark program p8p8's 65C02 code now scores 5242 where
  the reference compiler's scores 5203 (it was 4516); for the 65816, 5288.
- A variable may be declared in an `unroll` loop, as upstream allows.
- `tools/benchx16.sh` runs upstream's benchmark program on a Commander X16
  built by the reference compiler and by p8p8.
- `-cpu 6502|65c02|65816` chooses the CPU of a 6502 machine's program.  For
  the 65816, runs of word arithmetic on variables are done in the 16-bit
  accumulator, comparisons and rotations among them, and a loop of
  such runs stays 16 bits wide from its start to its end: a loop of word
  arithmetic takes 26 jiffies on a Commander X16 where the reference
  compiler's 65C02 code takes 106.  The programs run on
  `x16emu -c816` and VICE's `xscpu64` (`make emucmp816`, `emucmp64816`).
- Follows Prog8 master at 8f50c2ed1 and the LLVM branch at a7076bf71 (the
  library and the reference material).  A struct field that is a struct is
  refused with upstream's new message.
- `-codegen upstream` for the 68000 machines: `prog8c-llvm`'s back end
  builds the program from p8p8's IR (`make qemucmpir`: 37 programs, all the
  same as from the source).  For that, a call of a subroutine with several
  return values names the registers they come back in.
- Fixed for the 6502: a subroutine declared in a subroutine that is itself
  declared in one was put in the wrong scope and could not be called
  (upstream's `lineclip` has one now).
- Without `-check`, `-ir` or another option that says what to do, a program
  for an llvm target is compiled to its `.ll` file, as `prog8c` does it;
  0.1.0 only checked it.  Programs for 68000 machines are built.
- Fixed for the 68000: a float cast to an integer was rounded, not cut off.
- Fixed in the LLVM back end: the complement (`~`) of a byte or word right
  after arithmetic on a wider type was written as invalid LLVM IR.
- `tools/benchp8vi.sh` times a command of the editor p8vi on an Amiga 500,
  built by both compilers: `:%s/5//g` on its sample text takes 2.97 s from
  p8p8 and 3.56 s from the reference compiler.
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
