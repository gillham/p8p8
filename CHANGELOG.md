# Changes

## Unreleased

- Follows Prog8 master at 32f82e9e1 and the LLVM branch at 62101daa8 (the
  library and the reference material; the Amiga has a new `hwinfo` module).
- Struct variables, as upstream has them now: `Point p`,
  `Point p = [1, 2]`, `Point p = Point:[x=1, y=2]`, with `p.x`, a copy of
  the whole struct (`q = p`), `&p` and `&&p` (in the data of arrays and
  other instances too), a struct type declared inside a subroutine, and one
  at a fixed address (`&Point regs = $d000`).  They are fixed storage, also
  inside a subroutine, where field values are data that is there when the
  program is loaded.  On every code generator.  What upstream refuses is
  refused in its words (a struct compared, given a number, a wrong value
  for a field).
- On the 6502 a struct instance without values is in the BSS section
  (`prog8_struct_instances_bss`), as upstream has it: cleared at startup,
  not part of the program file, and in RAM when the program is in a ROM.
  It was zeros in the program file.
- Three programs that were compiled into something else than was written
  are errors, as on the LLVM branch: the remainder of a float (`f % 2.0`
  divided; use `floats.mod()`), `repeat` with a constant count below zero
  (it ran 256 minus that many times), and an array filled from a range
  whose ends are not constants (it was filled with zeros).
- The end of a `for` loop's range is checked as upstream checks it: a value
  that is not a number must have the loop variable's own type
  (`for long k in 0 to wordvalue` is "range end value is incompatible with
  loop variable type"), unless the start is a variable or expression of
  that type, which widens the end.  Programs that upstream rejects were
  accepted before.  Write `0 to wordvalue as long`: the cast now belongs
  to the end value, as in upstream's grammar, where p8c took it for a cast
  of the whole range and refused it.
- On the Z80 machines a subroutine may call itself, directly or by way of
  others: a call that can come back into the calling subroutine keeps that
  subroutine's variables on the stack over it.  (They are fixed memory
  otherwise, as on the 6502, and nothing changes for a subroutine that does
  not do this.)
- A Z80 program can call routines of z88dk's C library: an `extsub` without
  an address is one, by its own name (`extsub malloc(uword size) -> uword`).
  Such a program is linked by `zcc`, and `-Xlink` passes it more options.
- The `trs80` target writes text straight into the screen's memory: letters
  are shown as they are, and there is no cursor on the screen.  Letters
  typed come small unshifted on both models.  Both TRS-80 targets have a
  `trs80` module (`model`, `dos`, `has_lowercase`, `caps_lock`, `capitals`),
  as prog8c-llvm's TRS-80 profiles do.
- In Z80 assembly of a program's own, a name has two underscores for each
  dot (`txt.plot.col` is `_txt__plot__col`): with one, `main.page_lines`
  and `main.page.lines` were the same name.

- More of the system on the Z80 machines: `sys.wait` and `sys.waitvsync`
  (by counting; `sys.ticks` is 0 where there is no clock), `sys.inp` and
  `sys.outp` for the Z80's I/O ports, and on CP/M the command line
  (`sys.argc`, `sys.argv`) and files: a `diskio` module through the BDOS
  with reading and writing by pieces and by lines, load and save, delete,
  rename, exists and the directory.  The TRS-80 targets have the same:
  files through the DOS's own calls (TRSDOS 2.3 and 1.3, LDOS 5, TRSDOS 6),
  with names as other machines write them (`data.txt` is `DATA/TXT`), and
  the command line that the DOS hands a program.

- The Z80 code is much shorter: a pass over each subroutine's assembly
  takes out loads, stores and moves that are not needed, and the generator
  moves words as words and uses constants directly.  Variables without values are no longer zero bytes in the
  program's file.  The string routines' test is 4,694 bytes (10,263
  before), long arithmetic 3,200 (4,564), hello 80 (138).  `-noopt` gives
  the code as it was.  It is faster too: multiplications by constants are
  additions, and the long multiplication and division do no more steps
  than the numbers need.  Long multiplication and division work in
  registers (16-bit products; a 16-bit divisor in two 16-step divisions),
  and a long sum is two word additions.  `make z80bench`, whose loops no
  compiler can work out beforehand now: 2.6 seconds in 1,838 bytes, where
  prog8c-llvm's build takes 2.8 seconds in 16,479.
  A large program no longer has memory for temporary values that the
  pass made unnecessary, a call has up to three arguments in A, HL and DE, and what
  the registers hold is known past the end of an `if`.  An editor for the
  TRS-80 Model 4 was 37,317 bytes and is 29,347 (prog8c-llvm's: 29,921);
  its 128K version 48,895 and 38,161 (39,889), which is what lets it run.

- The Z80 machines have a library of their own (`lib/targets/z80`), no
  longer llvm16's, and its most used routines are Z80 assembly now: the
  digits of numbers, reading numbers, and the length, copying and comparing
  of strings.  Programs are a fifth to a quarter smaller for it (a test of
  the string routines 14,006 bytes before and 10,263 after; one of long
  arithmetic 5,769 and 4,564).

- `-target trs80m4`: the TRS-80 Model 4 in its own mode (TRSDOS 6, LS-DOS
  6), with an 80 by 24 screen through the DOS's supervisor calls.  All the
  test programs print there what they print on the host (`make trs80cmp4`).
- `%asm` on a Z80 machine: Z80 assembly as it stands, for z88dk's z80asm.
  It names the program's variables as the generator writes them
  (`txt.plot.col` is `_txt__plot__col`).  Subroutines written wholly in
  assembly (`asmsub`) are not there yet.
- A target file can be made from another: `base = file`.

- A second Z80 machine: `-target trs80`, the TRS-80 Model I and III with a
  DOS.  The program is a command file (`.cmd`), which p8c writes itself;
  the screen, the console and the keys are the ROM's.  All the test
  programs print on a Model I in trs80gp what they print on the host
  (`make trs80cmp`: 65 the same, none different), and on a Model III with
  TRSDOS 1.3 and with LDOS (`make trs80cmp3`).  What is the machine's is
  in its target file: the console and key routines moved there from the
  code generator, for CP/M as well.

- A program with overlays whose variables are put into the overlay window
  (`-varshigh` on the C64, for one) is refused; it was built and went wrong
  when an overlay was brought in.

- `-asm` (an option of p8p8's own) writes the assembly of p8p8's code
  generator and stops: for whoever assembles and links it their own way.
  No assembler has to be installed for it.

- A beginning of a Z80 code generator: `-target cpm` builds a CP/M
  program with z88dk's z80asm, and `-run` starts it in tnylpo.  (A Z80
  machine is a target of its own, with `cpu = z80` in its target file;
  prog8c-llvm's spelling, `-target llvm16 -triple z80-cpm`, means the same.)
  Bytes, words and longs, signed division, calls, loops, structs, text
  output, keys, filling and copying memory, and floats work; files and the
  clock do not yet.  A program with floats is linked by z88dk's `zcc` with
  its 32-bit maths library (`Z88DK` names z88dk's directory); one without
  needs only its assembler.  A subroutine's
  variables are in fixed places, as on the 6502 (on the host they are on the
  stack, which a subroutine that calls itself can tell).  `make z80cmp`
  compares with the host: all the test programs build, and 65 print the same
  (the others do not run on the host).  `make z80ref` compares with
  prog8c-llvm's build for CP/M, which is the reference for floats: 69 the
  same, none different.

- `-meminfo` (and `-verbose`) prints after a 6502 program is built where
  the main program is, how many bytes it takes and how many are free below
  the machine's top of memory, and the same for each overlay with the
  sizes of the loader and of the program's file.

- Overlays, an extension, on the Commander X16: a block with `%overlay n`
  has its code in RAM bank n.  The compiler writes the calls into an
  overlay, between overlays and back; the block's variables and strings
  stay in main memory.  `p8c` writes a loader as `name.prg` and the main
  program with all overlays as `name.non`.  On other machines the
  directive is ignored.  `make overlaycheck` runs the tests in x16emu, as
  65C02 code and as 65816 code.
- Overlays on the C64 and the C128, in a RAM Expansion Unit: an overlay is
  fetched into a window of main memory (4 KB) when its code is called.
  `name.prg` is the program, and it reads its overlays from `name.non` into
  the REU at the first such call.
- Overlays on the MEGA65: kept in bank 4 and 5 of its memory, and copied
  into a window of 8 KB at $a000 by the DMA controller.
- A call into an overlay is about twice a plain call: on the X16 without
  the ROM's far call (20,000 calls: 15 jiffies, from 37; 8 for plain
  calls), on the C64 150 jiffies from 398 (76 plain).  An overlay that is
  brought in is copied by its size, not the window's (4,000 calls into two
  overlays in turn on a C64: 72 jiffies, from 1,162).
- X16: the RAM bank a program's main part chooses stays its own.  Code in
  an overlay may call a subroutine there that chooses a bank for the
  program's data and leaves it chosen; the overlay comes back for its own
  code, and the main program finds its bank as it left it.
- Overlays on the GameTank: `%overlay n` is bank n of the cartridge (128
  to 254), with what the block includes as assembly or binary beside its
  code, and `p8c` writes the whole 2 MB cartridge as `name.gtr`.
- `-overlayinfo` lists every block of a program, the library's too, with
  its bytes and whether it could go into an overlay or why not (the
  compiler's own runtime, a name that assembly uses, an interrupt handler,
  a subroutine that chooses a bank, variables kept in assembly code).
  Blocks of the library can be named in an `%overlay` list.
- `-meminfo` lists the blocks and subroutines in each overlay with their
  bytes, and what the overlays cost in main memory (the ways in, the ways
  out and back, the code they share).
- An interrupt handler in an overlay is an error where the compiler can see
  it being installed; assembly that calls a subroutine in another overlay
  by its full name gets a warning.
- `%option overlay_data` in a block of an overlay: its strings, its arrays
  with values and the string literals only its code uses are in the overlay
  beside the code (on the GameTank: out of the fixed bank), and routines of
  the library are called with the overlay still in the window, so that
  they can print, copy or unpack what is there.
- The number of an `%overlay` can be the name of a constant
  (`%overlay banks.TITLE, title`).
- X16 and GameTank: the way into an overlay is nine bytes of main memory
  for each subroutine (24 and 33 before), with what they share written
  once for each overlay.
- `%option overlay_safe` in a block of the program: it is called like the
  library from an `overlay_data` block, for a decompressor or a copy
  routine of your own that is handed data in an overlay.
- An overlay that the program names but whose subroutines nothing calls is
  reported, and the program is still built as one with overlays (it was
  built in one piece without a word).
- `%overlay n, name, name...` at the top of a module lists the blocks and
  subroutines of an overlay in one place, with nothing in the blocks
  themselves.
- `-nooverlays` builds a program in one piece whatever its `%overlay`
  directives say.
- `%overlay n` in a subroutine puts that one subroutine into the overlay:
  the way to move code out of `main`.
- [docs/OVERLAYS.md](docs/OVERLAYS.md): a guide to overlays.

- 65816: far memory at a known address is read and written with the CPU's
  24-bit addresses (`lda $040000`, `sta $040010,x`), not through a pointer,
  and plain loads and stores go straight between the register and far
  memory.  A loop that fills and sums a far array of 200 bytes 300 times
  takes 11 jiffies on a C64 with a SuperCPU where it took 24, and the test
  of far data is 1,789 bytes where it was 2,989.
- 45GS02: a long in far memory is fetched and put back with one 32-bit
  instruction each (the test of far data: 3,199 bytes, from 3,345).
- The launchers of the VIC-20 with 8 KB or more (`vic20plus8`,
  `vic20plus24`) reset the machine at the end of a program that used zero
  page BASIC needs, as the unexpanded VIC-20's and the other machines' do;
  a program with `%zeropage basicsafe` returns to BASIC as before.

## 0.2.0

Three new code generators (65816, 45GS02, 68000), some hundred and fifty more of
the reference compiler's checks, and the compiler on more hosts.  The
language follows Prog8 master at df16719e7 and the LLVM branch at
e261d6c6d.  [docs/DIFFERENCES.md](docs/DIFFERENCES.md) lists where p8p8
still does not behave as `prog8c` does, and what it has of its own.

### New code generators

- `-cpu 6502|65c02|65816` chooses the CPU of a 6502 machine's program.  For
  the 65816, runs of word arithmetic on variables are done in the 16-bit
  accumulator, comparisons and rotations among them, and a loop of
  such runs stays 16 bits wide from its start to its end: a loop of word
  arithmetic takes 26 jiffies on a Commander X16 where the reference
  compiler's 65C02 code takes 106.  The programs run on
  `x16emu -c816` and VICE's `xscpu64` (`make emucmp816`, `emucmp64816`).
- A code generator for the 45GS02, the MEGA65's CPU, which
  `-target mega65` now writes code for (`-cpu 6502` for plain 6502 code).
  Longs are loaded, combined, compared and stored with the 32-bit
  instructions (`c = a + b` is four instructions), which makes a test of
  long arithmetic 876 bytes where the 6502 code is 1,501.  Long results
  and returns go through the 32-bit register, and multiplication and
  division use the MEGA65's arithmetic unit, for bytes and words too.
  `make emucmp65` compares the two kinds of code for every test program in
  xmega65, and `tools/benchmega65.sh` times loops (frames, 45GS02 code
  against 6502 code): long additions 48 against 65, long comparisons 63
  against 71, long multiplications 1 against 18, word multiplications 9
  against 40, word divisions 13 against 72.
- 45GS02: a word variable in the zero page is counted with `inw` and `dew`.
- A first 68000 code generator: `-target qemu68k -build` (or `-o`, `-run`)
  writes assembly for vasm, links with vlink and runs in QEMU;
  `-target amiga1200` and `amiga500` write an AmigaOS program, with
  `%option amiga_chipram` blocks in chip memory.  Variables and
  temporaries live in CPU registers where they can; on six small
  benchmarks (`tools/bench68k.sh`, an Amiga 500 in Copperline) the programs
  take between 0.68 and 0.80 times as long as the reference compiler's
  (0.57 to 0.87 on an Amiga 1200) and are about 10% smaller.
- `-codegen upstream` for the 68000 machines: `prog8c-llvm`'s back end
  builds the program from p8p8's IR (`make qemucmpir`: 37 programs, all the
  same as from the source).  For that the IR has the target's options,
  register slots for D0-D7, A0-A6 and FP0-FP7, library offsets in decimal,
  the equates of extsubs, and the registers that several return values
  come back in.

### Far memory (an extension)

- On the MEGA65 and on a C64 with a SuperCPU (`-cpu 65816`) a long is an
  address of data.  Memory mapped variables and arrays
  (`&ubyte ATTIC = $8000000`, `ATTIC[i]`), `@(...)`, `peek` and `poke` and
  their relatives, with a constant or with a long that the program works
  out (`@(base + i)`, `base[i]`); `&` of a far variable is a long.  The
  target's file says how many bits (`far_address_bits`).  Pointers stay
  words, and a block that is copied stays inside one 64 KB bank; each
  access goes through a zero page pointer, which is not fast yet.
- The library module `farmem` for those two machines: `copy` and `fill`
  with long addresses (the MEGA65's DMA, the 65816's block moves).
- `make farcheck` runs the tests of far memory on three emulators: the
  65816's four long addressing modes and the 45GS02's `[zp],z` written by
  hand, then the compiler's own code and the library's on the MEGA65 and
  the SuperCPU.

### Closer to the reference compiler

- Follows Prog8 master at df16719e7 and the LLVM branch at e261d6c6d: `petgfx`
  with drawing modes, `clear_screen` and `line`, on the X16 as well; the Amiga
  `sprites` module; the Amiga `text` module is `gfxtext` now.
- Follows Prog8 master at 8f50c2ed1 and the LLVM branch at a7076bf71 (the
  library and the reference material).  A struct field that is a struct is
  refused with upstream's new message.
- About seventy checks that upstream makes and p8p8 did not, with
  upstream's messages (`tests/bad_upstream.p8` has a sample): a long used
  as an address or a pointer used as a long where addresses are words, the
  name of a subroutine used as a value, a cast that would cut a constant
  down (`300 as ubyte`), pointers to different things assigned to each
  other, struct and union initializers, enum values, `private public`,
  `[rows,cols]`, a BASIC program that does not load at BASIC's address,
  and more.  Of the 1,143 programs taken out of upstream's unit tests
  (`tools/kttests.py`), 8 that it refuses still build and 3 that it builds
  do not.
- Another seventy of upstream's checks, found by running every example of
  its documentation through both compilers again: variable tags that do
  not exist or do not apply, numbers where booleans belong and the other
  way round, a subroutine with several values used as one, the rules for
  register parameters and bank subroutines, struct field kinds, `sizeof`
  of things without a size.  `tests/bad_upstream2.p8` has a sample.
- Found by reading upstream's documentation against p8p8, and put right:
  `ubyte a, b, c = 42` gave the value to `a` only; `pointer^^.field`
  followed the pointer twice; the difference of two pointers was in bytes,
  not elements; an array of two-byte structs was split like a word array;
  `for x in array step -1` ran forwards; a subroutine with several values
  that ended without a `return` gave the last call's; enum members above 255
  were cut to a byte; `value as bool` looked at the low byte only;
  `sizeof()` of a string variable was a pointer's; a constant without a
  type is a long.
- From upstream's unit tests (`tools/kttests.py`): `offsetof(Struct.field)`;
  struct types are defined for the assembler (`#size(p8t_Node)`,
  `#p8t_Node.p8v_value`); `Name::MEMBER` through an alias of an enum; the
  address of an element of a constant address, of a word that holds one and
  of a memory mapped array (the last gave the array's address, without the
  index); constants that are a block of `memory()` or a string;
  `return other()` between subroutines that return nothing; a constant
  float cast to an integer is worked out by the compiler.
- More from upstream's documentation.  New: `setlsb`, `setmsb`, `rsave`,
  `rrestore`, `memory("name")` alone, `for ... via .field until node` and
  such a loop without a declared variable, `%asminclude` and `%asmbinary`
  inside a subroutine or as all of an asmsub, an enum's members for
  assembly (`p8c_Enum_MEMBER`), `[6] * 10` for an array of words, floats in
  `%assert`, `repeat 2.5`, `clamp` of a long and `in` with an array of
  longs or floats for the 6502, `-h`, `-help`, `-target llvm`.
- New: a loop's own variable can be used before the loop; a label can be
  called; `math.sin8u()` and its relatives, `math.log2()`, `math.diff()`
  and `strings.isdigit()` of constants are worked out when compiling; the
  `.bankedcalls` file; `-run program.p8 -- arguments`; the options
  `-address`, `-D`, `-O`, `-Xlink`, `-clang`, `-breakinstr`, and upstream's
  names `-noasm`, `-dumpsymbols`, `-ignorefootguns`.
- A constant declared without a type counts as the number it is inside an
  expression (`v + A` with `const A = 200` is byte arithmetic), as
  upstream has it.
- Constants as upstream works them out: `&`, `|` and `^` of signed byte
  or word constants give the unsigned pattern (`-1 & -15` is 241), a long
  written past its range wraps (`-2147483649` is 2147483647),
  `math.atan2()` of constants is a constant, and `1.0 to 3.0` fills an
  array of floats.  A number of more than 32 bits is refused on the 6502
  machines also where it is folded away (`lsb($1_0000_0012)`).
- Refused now, as upstream does: a statement in a block outside any
  subroutine, and the assignment of one array to another.
- The names of structs, blocks, aliases, enums and fields cannot be keywords;
  an enum needs a member; `%option amiga_chipram` is for the Amigas.
- A variable may be declared in an `unroll` loop, as upstream allows.
- `@alignword`, `@align64` and `@alignpage` were checked and then ignored.
- `@zp` and `@requirezp` are told apart, as upstream does: what `@requirezp`
  names is placed first and is an error when it does not fit ("no more
  free space in ZP"), what `@zp` names is placed when there is room.  Both
  work for longs, floats and arrays without values, and on parameters.
- Directives that p8p8's 6502 code generator took no notice of now work as
  upstream's: `%zpallowed`, `%zpreserved`, `%varsaddress`, `%jmptable` and
  `%breakpoint` (the breakpoints are listed for VICE's monitor).  `%assert`
  took any expression with a name in it for not constant.
- A library (`%output library`) begins with a jump to `main.start`, with
  `main` and its jump table right after it; it had a program's startup code
  there.
- The blocks of a program come right after its startup code, `main` first,
  as upstream lays a program out; the code for the variables' initial
  values was in between, where a cartridge's header lines wrote over it.
- A block's assembly, labels, included files and subroutines are written in
  the order of the source (the block's own chunks used to come first).
- Programs for ROM (`%option romable`): the variables have to be moved to
  RAM and floats are not available, as upstream requires, and the assembler
  now stops when anything in the program, the library's assembly included,
  writes to an address inside the program.
- `%asmbinary` and `%asminclude` find a file by its path as it is written,
  from where the compiler runs, as well as beside the source.
- Struct fields may share a line.  The 6502 code generator converts longs
  to floats and back, and returns a float next to other values.
- On the C64, C128 and PET the virtual registers R0-R15 are in the zero
  page with `%zeropage kernalsafe` and `full`, as upstream has them, so
  assembly can use `(cx16.r0),y`.
- An in-place operation on `@(address)` works the address out once, as
  upstream does: a call in it was made twice.
- Without `-check`, `-ir` or another option that says what to do, a program
  for an llvm target is compiled to its `.ll` file, as `prog8c` does it;
  0.1.0 only checked it.  Programs for 68000 machines are built.

### The compiler itself

- An IR file as input: `p8c program.p8ir` builds the program from the IR
  that `p8c -ir` wrote, to the same bytes as from the source
  (`make irroundtrip`).  IR written by upstream mostly does not build: it
  uses instructions p8p8's back ends do not have.
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
- A target's custom launcher is told whether the program leaves the zero
  page as BASIC needs it (the assembler symbol `prog8_zeropage_safe`), and
  the MEGA65's resets the machine at the end when it does not, as on the
  other machines; before, such a program fell back into a BASIC that could
  not go on (`?SYNTAX ERROR`).

### Faster and smaller programs for the 6502

- On upstream's benchmark program p8p8's 65C02 code now scores 5242 where
  the reference compiler's scores 5203 (it was 4516); for the 65816, 5288.
- 6502: a multiplication by a constant with few bits set is shifts and
  additions in line, not a call of the general routine.  A loop over a word
  array that multiplies by 37 went from 168 to 63 jiffies on an X16 (the
  reference compiler's code takes 64); `tools/bench65.sh` measures this.
- Faster 6502 code for bytes through a pointer with a byte index, sums of
  such bytes, words that bytes are added to, and a constant times a variable.
- Float expressions on the 6502 keep their result in the ROM's FAC1 from
  one operation to the next and take variables and constants from where
  they are; a word times itself uses the library's square routine.
- Programs with floats need 250 bytes less memory: the float registers of
  library routines that the program does not call no longer get a place.

### Fixed

- Fixed, on every target: an element of an array that is a field of a
  struct (`p.values[i]`) was read through the field's first bytes as if they
  were a pointer; `^^Thing t = []` at block level made an empty array where
  an instance belongs; and a `str` parameter compared with a string compared
  the two addresses, not the text.  On the 6502 a struct instance without
  values was not defined at all.
- Several return values are all computed before any is put in its place.
  On the 68000 a division in a later value overwrote an earlier one.
  Floats among several return values have slots of their own (s25 on), as
  upstream numbers them.
- Fixed: `pokel(address, -5)` stored 251: a value narrower than what is
  stored lost its sign.
- Fixed: an address of more than 16 bits in `@(...)`, in `peek` and `poke`
  and their relatives, or as an indexed constant was accepted on the 6502
  machines and cut to 16 bits without a word.  It is refused, as upstream
  refuses it ("invalid address type for memory access").
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
- Fixed: the parser of `%ir` blocks wrote outside its operand table.
- Put right: `pokemon()` was compiled as `pop()`; `msb()` and `msw()` of a
  64-bit value took the top of the low half; `float in [1.0, 3.5]` compared
  whole numbers; `@align64` and the other alignment tags were not applied
  to every array on the hosted targets; `monogfx` did not build (a
  subroutine's `@shared` array that only a nested subroutine's assembly
  names was dropped).
- Fixed for the 6502: a subroutine declared in a subroutine that is itself
  declared in one was put in the wrong scope and could not be called
  (upstream's `lineclip` has one now).
- Fixed for the 68000: a float cast to an integer was rounded, not cut off.
- Fixed in the LLVM back end: the complement (`~`) of a byte or word right
  after arithmetic on a wider type was written as invalid LLVM IR.

### Measuring and comparing

- `tools/benchx16.sh` runs upstream's benchmark program on a Commander X16
  built by the reference compiler and by p8p8.
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
