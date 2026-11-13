#
# Makefile for p8p8, a Prog8 compiler written in Prog8.
#
# The compiler is the LLVM branch of Prog8, run as `prog8c-llvm`, and the
# llvm64 target needs clang 15 or newer to build the executables.
# `java -jar prog8c-14.0-BETA3-llvm.1-all.jar` would be equivalent to
# running `prog8c-llvm` for example.
#
# Make targets:
# all:
#     builds the compiler, the executable p8c, for the llvm64 target (the default):
#     from the seed in seed/ when there is one (BOOT=seed), else with prog8c-llvm
#     (BOOT=prog8c)
# seed:
#     writes the seed of the compiler that was just built
# seedcheck:
#     the compiler from the seed and the one from prog8c-llvm must be the same
# check:
#     runs a compiler syntax check of all programs without building them
# dist:
#     an archive of the compiler and the library for this machine, in dist/
# install:
#     copies p8c to PREFIX/bin and the library LIB to PREFIX/lib/p8p8
#     (PREFIX defaults to ~/.local, LIB to lib)
# run:
#     builds p8p8 and runs it on the example program with -stats
# test:
#     builds and runs every test program in TESTS and compares its output
#     with tests/expected/llvm64_<name>.txt, then runs p8p8 on the sample
#     files in tests/ and compares its dumps with tests/expected/
# corpus:
#     runs p8p8 over every .p8 file of the Prog8 reference material (the
#     standard library, examples and compiler tests) and prints statistics;
#     every file must go through without an error
# roundtrip:
#     prints every corpus file back from its AST, reparses that, and checks
#     that the two AST dumps are identical (tests/roundtrip.sh)
# programs:
#     loads every example program with its imports resolved against the
#     library of its target (tests/programs.sh)
# stats:
#     reports source line counts and the size of the executables
# clean:
#     removes everything in build/
#
# Other llvm targets (llvm32 for wasm, for instance) can be added with a
# src/<target>/ directory holding the *_platform.p8 modules for it.

ifeq ($(OS),Windows_NT)
    CLEAN = del /S /Q build\*
    RM = del /Q
    MD = mkdir
    EXE = .exe
else
    CLEAN = rm -fr build/*
    RM = rm -f
    MD = mkdir -p
    EXE =
endif

PCC=prog8c-llvm
TARGET=llvm64
PCCARGS=-srcdirs src:src/$(TARGET) -plaintext -target $(TARGET)

MAIN	= src/main.p8
SRCS	= $(wildcard src/*.p8) $(wildcard src/$(TARGET)/*.p8)
TESTS	= test_phase0
OUT	= build/$(TARGET)
P8P8	= $(OUT)/p8c$(EXE)
TESTBIN	= $(addprefix $(OUT)/,$(addsuffix $(EXE),$(TESTS)))
EXAMPLE	= tests/hello.p8

CORPUS	= $(shell find -L lib/prog8lib lib/common lib/targets .prog8-reference/examples .prog8-reference/compiler/test -name '*.p8')

.PHONY:	all check seed seedcheck install dist test corpus roundtrip programs clean run stats vmcmp nativecmp nativecmp32 nativecmp16 nativecmp16c64 hostcmp hostbootstrap buildall gfxcmp bootstrap emucmp emucmp64

all: $(OUT) $(P8P8)

$(OUT):
	$(MD) $(OUT)

# How the compiler is built: from the seed (BOOT=seed), which is p8c's own earlier
# output as LLVM IR, or by prog8c-llvm (BOOT=prog8c).  The seed is used when it is there.
#
# From the seed: clang makes stage 0 of it, stage 0 compiles the sources, and clang
# makes p8c of that.  (make bootstrap then checks that p8c reproduces itself.)
# The seed has no target lines, so it is the same file for macOS and Linux.
SEED	= seed/p8c.ll.gz
BOOT	?= $(if $(wildcard $(SEED)),seed,prog8c)
STAGE0	= build/stage0/p8c$(EXE)
P8CARGS	= -target $(TARGET) -lib lib -srcdirs src:src/$(TARGET)
CLANG	?= clang
CFLAGS	?= -O2
# (the math library is a library of its own on Linux; naming it does no harm elsewhere)
LDLIBS	?= -lm

ifeq ($(BOOT),seed)

$(STAGE0): $(SEED)
	$(MD) build/stage0
	gzip -dc $(SEED) > build/stage0/p8c.ll
	$(CLANG) $(CFLAGS) -Wno-override-module build/stage0/p8c.ll -o $@ $(LDLIBS)

$(P8P8): $(SRCS) $(STAGE0) | $(OUT)
	$(STAGE0) $(P8CARGS) -llvm -out $(OUT) $(MAIN)
	mv $(OUT)/main.ll $(OUT)/p8c.ll
	$(CLANG) $(CFLAGS) -Wno-override-module $(OUT)/p8c.ll -o $@ $(LDLIBS)

$(OUT)/test_%$(EXE): src/test_%.p8 $(SRCS) $(P8P8) | $(OUT)
	$(P8P8) $(P8CARGS) -out $(OUT) -build $<

check:	$(P8P8)
	$(P8P8) $(P8CARGS) -check $(MAIN)
	@for t in $(TESTS); do $(P8P8) $(P8CARGS) -check src/$$t.p8 || exit 1; done

else

# -o names the executable; clang builds it from the .ll written next to it
$(P8P8): $(SRCS) | $(OUT)
	$(PCC) $(PCCARGS) -o $@ $(MAIN)

$(OUT)/test_%$(EXE): src/test_%.p8 $(SRCS) | $(OUT)
	$(PCC) $(PCCARGS) -o $@ $<

check:
	$(PCC) -check -quiet $(PCCARGS) $(MAIN) $(addprefix src/,$(addsuffix .p8,$(TESTS)))

endif

# make seed: the seed of this compiler, for the next one to be built from.
# (Without the two target lines, which are all that differs between macOS and Linux;
# gzip -n leaves out the time, so the same compiler gives the same file.)
seed:	$(P8P8)
	$(MD) seed build/seed
	$(P8P8) $(P8CARGS) -llvm -out build/seed $(MAIN)
	grep -v '^target ' build/seed/main.ll | gzip -9 -n > $(SEED)
	@ls -l $(SEED) | awk '{print "wrote", $$9 ":", $$5, "bytes"}'

# make seedcheck: the compiler built from the seed and the one built by prog8c-llvm must
# be the same compiler: each compiles the sources, and the two results must be identical.
seedcheck:
	@tests/seedcheck.sh $(SEED) "$(PCC) $(PCCARGS)" "$(P8CARGS)" $(MAIN)

# make install [PREFIX=dir] [LIB=dir]: the compiler in PREFIX/bin and the library it builds
# programs with in PREFIX/lib/p8p8, where p8c finds it by itself.  LIB is the library
# (the directory with prog8lib/, common/ and targets/ in it).
PREFIX	?= $(HOME)/.local
LIB	?= lib
install: $(P8P8)
	@test -f $(LIB)/prog8lib/prog8_lib.p8 || { echo "no library in '$(LIB)': give its directory with LIB=..."; exit 1; }
	$(MD) $(PREFIX)/bin $(PREFIX)/lib/p8p8
	cp $(P8P8) $(PREFIX)/bin/p8c$(EXE)
	rm -rf $(PREFIX)/lib/p8p8/prog8lib $(PREFIX)/lib/p8p8/common $(PREFIX)/lib/p8p8/targets
	cp -R $(LIB)/prog8lib $(LIB)/common $(LIB)/targets $(PREFIX)/lib/p8p8/
	cp $(LIB)/VERSION $(LIB)/LICENSE $(PREFIX)/lib/p8p8/
	$(MD) $(PREFIX)/lib/p8p8/runtime
	cp runtime/windows-console.c runtime/mos-c64-support.c $(PREFIX)/lib/p8p8/runtime/
	@echo "installed $(PREFIX)/bin/p8c and $(PREFIX)/lib/p8p8"

# make dist: an archive of the compiler for this machine, to unpack anywhere and use:
# dist/p8p8-<version>-<system>-<cpu>.tar.gz, with bin/p8c and lib/p8p8 in it as make
# install lays them out, and the documents.  (On Windows: tools\build-windows.ps1 -Dist.)
VERSION	= $(shell sed -n 's/.*str number = "\(.*\)".*/\1/p' src/version.p8)
HOSTNAME = $(shell uname -s | tr A-Z a-z)-$(shell uname -m)
DISTNAME = p8p8-$(VERSION)-$(HOSTNAME)
dist:	$(P8P8)
	rm -rf dist/$(DISTNAME)
	$(MAKE) install PREFIX=dist/$(DISTNAME) LIB=$(LIB)
	cp README.md LICENSE dist/$(DISTNAME)/
	$(MD) dist/$(DISTNAME)/docs
	cp docs/*.md dist/$(DISTNAME)/docs/
	tar czf dist/$(DISTNAME).tar.gz -C dist $(DISTNAME)
	rm -rf dist/$(DISTNAME)
	@ls -l dist/$(DISTNAME).tar.gz | awk '{print "wrote", $$9 ":", $$5, "bytes"}'

clean:
	$(CLEAN)

run:	$(P8P8)
	$(P8P8) -stats $(EXAMPLE)

test:	$(TESTBIN) $(P8P8)
	@for t in $(TESTS); do \
	    echo "test $$t"; \
	    $(OUT)/$$t$(EXE) | diff -u tests/expected/$(TARGET)_$$t.txt - || exit 1; \
	done
	@echo "test tokens lexsample"
	@$(P8P8) -tokens tests/lexsample.p8 | diff -u tests/expected/$(TARGET)_tokens_lexsample.txt -
	@echo "test ast lexsample"
	@$(P8P8) -parse -ast tests/lexsample.p8 | diff -u tests/expected/$(TARGET)_ast_lexsample.txt -
	@echo "test build and run hello"
	@$(P8P8) -out $(OUT) -run tests/hello.p8 | diff -u tests/expected/$(TARGET)_run_hello.txt -
	@echo "test modules hello"
	@$(P8P8) -lib lib -modules tests/hello.p8 | diff -u tests/expected/$(TARGET)_modules_hello.txt -
	@echo "test target file"
	@$(P8P8) -target tests/targets/variant.properties -codegen own -ir -out $(OUT) tests/targets/variant.p8 > /dev/null
	@grep '^\* = \|VARIANT\|variant\|^P8ZP\|p8v_.* = [0-9]\|memtop=' $(OUT)/variant.asm | diff -u tests/expected/$(TARGET)_target_variant.txt -
	@echo "test modules override"
	@$(P8P8) -lib lib -srcdirs tests/override -modules tests/override/main.p8 2> /dev/null | grep '^conv:' | diff -u tests/expected/$(TARGET)_modules_override.txt -
	@for t in encodings encodings_sc; do \
	    echo "test literals $$t"; \
	    $(P8P8) -types -ast -nopos -nolib tests/$$t.p8 | diff -u tests/expected/$(TARGET)_literals_$$t.txt - || exit 1; \
	done
	@echo "test warnings"
	@$(P8P8) -lib lib -check -warnall tests/warnings.p8 2>&1 | diff -u tests/expected/$(TARGET)_warnings.txt -
	@$(P8P8) -lib lib -check tests/warnings.p8 2>&1 | diff -u /dev/null -
	@echo "test literals encoding_option"
	@$(P8P8) -target c64 -encoding iso -types -ast -nopos -nolib tests/encoding_option.p8 | diff -u tests/expected/$(TARGET)_literals_encoding_option.txt -
	@for t in bad_resolve bad_types bad_strings bad_checks; do \
	    echo "test $$t (must be rejected)"; \
	    $(P8P8) tests/$$t.p8 > $(OUT)/$$t.out 2>&1; \
	    [ $$? -eq 1 ] || { echo "expected exit status 1"; exit 1; }; \
	    diff -u tests/expected/$(TARGET)_$$t.txt $(OUT)/$$t.out || exit 1; \
	done

corpus:	$(P8P8)
	@echo "$(words $(CORPUS)) files"
	@$(P8P8) -parse -stats $(CORPUS)

roundtrip:	$(P8P8)
	@tests/roundtrip.sh $(P8P8) $(CORPUS)

programs:	$(P8P8)
	@tests/programs.sh $(P8P8) .prog8-reference

# generate IR for the test programs with p8p8 and with prog8c-llvm, run both in the VM, compare the output
# (the graphics examples bouncegfx, fountain and pixelshader run until their window closes, so they are left out)
# (the pointer examples for the cx16 and the graphical fountain are left out too)
PTRTESTS=$(addprefix .prog8-reference/examples/pointers/,animalgame.p8 binarytree.p8 hashtable.p8 sortedlist.p8 sorting.p8)
# (tests/programs holds p8p8's own programs for features the upstream tests do not reach)
VMTESTS=$(wildcard .prog8-reference/compiler/test/arithmetic/*.p8 .prog8-reference/compiler/test/comparisons/*.p8) .prog8-reference/examples/virtual/bsieve.p8 .prog8-reference/examples/virtual/sincos.p8 $(PTRTESTS) $(wildcard tests/programs/*.p8)
vmcmp:	$(P8P8)
	@tests/vmcmp.sh $(P8P8) .prog8-reference $(VMTESTS)

# compile the test programs natively with both compilers (p8p8 -llvm plus clang) and compare the output
NATIVETESTS=$(filter-out %/structmapped.p8,$(VMTESTS)) $(wildcard .prog8-reference/examples/llvm/*.p8)
nativecmp:	$(P8P8)
	@tests/nativecmp.sh $(P8P8) .prog8-reference $(NATIVETESTS)

# the same for llvm32: WebAssembly, run with wasmtime (needs Homebrew's llvm, lld and wasi-libc, see tests/nativecmp.sh)
nativecmp32:	$(P8P8)
	@NATIVECMP_TARGET=llvm32 tests/nativecmp.sh $(P8P8) .prog8-reference $(NATIVETESTS)

# llvm64 on another kind of machine, reached by ssh: make hostcmp P8P8_HOST=<ssh name> TRIPLE=x86_64-unknown-linux-gnu
# compares programs built and run there with the same ones here; make hostbootstrap builds p8p8 there and has it
# compile itself.  (Not the programs whose output depends on the machine.)
HOSTTESTS=$(filter-out %/ls.p8 %/find.p8 %/clib.p8 %/hexdump.p8 %/wordcount.p8,$(NATIVETESTS)) tests/hello.p8
hostcmp:	$(P8P8)
	@tests/hostcmp.sh $(P8P8) $(TRIPLE) .prog8-reference $(HOSTTESTS)
hostbootstrap:	$(P8P8)
	@tests/hostbootstrap.sh $(P8P8) $(TRIPLE) .prog8-reference $(MAIN) src:src/$(TARGET)

# and for llvm16: a 6502 program built with the llvm-mos SDK, run in its simulator mos-sim
# (LLVM_MOS names the SDK, default ~/.local/llvm-mos; programs with floats are skipped: upstream has none on llvm16)
nativecmp16:	$(P8P8)
	@NATIVECMP_TARGET=llvm16 tests/nativecmp.sh $(P8P8) .prog8-reference tests/hello.p8 $(NATIVETESTS)

# llvm16 with the mos-c64 profile: Commodore 64 programs, run in VICE (needs x64sc)
# (not the programs that wait for a key: their last frame is not the same twice; and not fnv64.p8,
#  which needs four times the cycles the others are given)
nativecmp16c64:	$(P8P8)
	@NATIVECMP_TARGET=llvm16 NATIVECMP_TRIPLE=mos-c64 tests/nativecmp.sh $(P8P8) .prog8-reference tests/hello.p8 \
	    $(wildcard tests/programs/c64/*.p8) $(addprefix .prog8-reference/examples/,fibonacci.p8 primes.p8) \
	    $(filter-out %/bitshift.p8 %/animalgame.p8 %/testforloops.p8 %/fnv64.p8,$(NATIVETESTS))

# every cx16 and c64 example must build to a program file through p8p8 (nothing is run)
buildall:	$(P8P8)
	@tests/buildall.sh $(P8P8) .prog8-reference cx16 $(wildcard .prog8-reference/examples/*.p8 .prog8-reference/examples/cx16/*.p8)
	@tests/buildall.sh $(P8P8) .prog8-reference c64 $(wildcard .prog8-reference/examples/*.p8 .prog8-reference/examples/c64/*.p8)

# what programs draw: recordings of x16emu's video for the reference build and p8p8's (see tests/gfxcmp.sh)
gfxcmp:	$(P8P8)
	@tests/gfxcmp.sh $(P8P8) .prog8-reference $(wildcard .prog8-reference/examples/*.p8 .prog8-reference/examples/cx16/*.p8)

# the 8-bit oracle: build from source and from p8p8's IR, run both in an emulator, compare what they print
# (needs 64tass and x16emu; text programs only, each runs for a few seconds)
# Left out, because they print how long they took: queens, mandelbrot, cube3d-float, cx16/sortingbench;
# and cx16/interpolation, which moves on to a next screen after a delay
EMUTESTS_COMMON=$(wildcard .prog8-reference/compiler/test/arithmetic/*.p8 .prog8-reference/compiler/test/comparisons/*.p8) \
	$(addprefix .prog8-reference/examples/,fibonacci.p8 primes.p8 maze.p8 screencodes.p8 swirl-float.p8 numbergame.p8) $(PTRTESTS) $(wildcard tests/programs/*.p8)
EMUTESTS=$(EMUTESTS_COMMON) .prog8-reference/examples/cx16/floatparse.p8 $(wildcard tests/programs/cx16/*.p8)
emucmp:	$(P8P8)
	@tests/emucmp.sh $(P8P8) .prog8-reference $(EMUTESTS)

# the same for the c64, in VICE (needs x64sc): the text screen is compared when the program ends
# (bitshift.p8 waits for input, so it never ends)
# (animalgame.p8 waits for input too: its cursor blinks)
# (swirl-float.p8, numbergame.p8 and maze.p8 never end, and the last frame of a program that is
#  stopped is not the same in both builds)
EMUTESTS64=$(filter-out %/swirl-float.p8 %/numbergame.p8 %/maze.p8 %/bitshift.p8 %/animalgame.p8,$(EMUTESTS_COMMON)) \
	$(addprefix .prog8-reference/examples/c64/,banking.p8 charset.p8)
emucmp64:	$(P8P8)
	@EMUCMP_TARGET=c64 tests/emucmp.sh $(P8P8) .prog8-reference $(EMUTESTS64)

# the self-hosting test: stage 2 is p8p8 compiled by itself, stage 3 must be identical to stage 2
bootstrap:	$(P8P8)
	@tests/bootstrap.sh $(P8P8) .prog8-reference $(MAIN) src:src/$(TARGET)

stats:	$(P8P8)
	@echo "source lines:"; wc -l $(SRCS) | sort -n
	@echo "executables:"; ls -l $(P8P8) $(TESTBIN) 2>/dev/null | awk '{print $$5, $$9}'

#
# end-of-file
#
