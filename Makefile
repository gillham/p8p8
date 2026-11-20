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
#     from the seed in seed/ when there is one (BOOT=seed), with a p8c that is
#     installed (BOOT=p8c, the way on a 32-bit machine), else with prog8c-llvm
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
# The compiler is a program for the machine it is built on: llvm64, or llvm32 on a
# 32-bit machine, where the host layer is src/llvm32 over src/llvm64.
TARGET=llvm64
SRCDIRS=src:src/llvm64
ifneq ($(filter armv6l armv7l armv8l riscv32 i686,$(shell uname -m 2> /dev/null)),)
    TARGET=llvm32
    SRCDIRS=src:src/llvm32:src/llvm64
endif
PCCARGS=-srcdirs $(SRCDIRS) -plaintext -target $(TARGET)

MAIN	= src/main.p8
SRCS	= $(wildcard src/*.p8) $(wildcard src/llvm64/*.p8) $(wildcard src/llvm32/*.p8)
TESTS	= test_phase0
OUT	= build/$(TARGET)
P8P8	= $(OUT)/p8c$(EXE)
TESTBIN	= $(addprefix $(OUT)/,$(addsuffix $(EXE),$(TESTS)))
EXAMPLE	= tests/hello.p8

CORPUS	= $(shell find -L lib/prog8lib lib/common lib/targets .prog8-reference/examples .prog8-reference/compiler/test -name '*.p8')

.PHONY:	quick816 emucmp816 emucmp64816 qemucmp qemucmpir amigacmp amigacmp500 amigacmpfloat coppercmp cross wasihost upstreamcheck conformance all check seed seedcheck install dist test corpus roundtrip programs clean run stats vmcmp nativecmp nativecmp32 nativecmp16 nativecmp16c64 hostcmp hostbootstrap buildall gfxcmp bootstrap emucmp emucmp64 irroundtrip

all: $(OUT) $(P8P8)

$(OUT):
	$(MD) $(OUT)

# How the compiler is built: from the seed (BOOT=seed), which is p8c's own earlier
# output as LLVM IR, by a p8c that is already there (BOOT=p8c, the one in the PATH or
# P8C=<file>), or by prog8c-llvm (BOOT=prog8c).  The seed is used when it is there; on a
# 32-bit machine it cannot be (its pointers are 64 bits wide), and a p8c is used.
# A p8c that is older than the seed may not know everything the sources use.
#
# From the seed: clang makes stage 0 of it, stage 0 compiles the sources, and clang
# makes p8c of that.  (make bootstrap then checks that p8c reproduces itself.)
# The seed has no target lines, so it is the same file for macOS and Linux.
SEED	= seed/p8c.ll.gz
ifeq ($(TARGET),llvm32)
    BOOT ?= p8c
endif
BOOT	?= $(if $(wildcard $(SEED)),seed,prog8c)
P8C	?= p8c
ifeq ($(BOOT),p8c)
    STAGE0 = $(P8C)
    STAGE0DEP =
else
    STAGE0 = build/stage0/p8c$(EXE)
    STAGE0DEP = $(STAGE0)
endif
P8CARGS	= -target $(TARGET) -lib lib -srcdirs $(SRCDIRS)
CLANG	?= clang
CFLAGS	?= -O2
# (the math library is a library of its own on Linux; naming it does no harm elsewhere)
LDLIBS	?= -lm

ifneq ($(filter seed p8c,$(BOOT)),)

ifeq ($(BOOT),seed)
$(STAGE0): $(SEED)
	$(MD) build/stage0
	gzip -dc $(SEED) > build/stage0/p8c.ll
	$(CLANG) $(CFLAGS) -Wno-override-module build/stage0/p8c.ll -o $@ $(LDLIBS)
endif

$(P8P8): $(SRCS) $(STAGE0DEP) | $(OUT)
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

# make upstreamcheck PROG8_SRC=<checkout of Prog8> [FROM=commit] [TO=rev]: what changed
# upstream since the commit the library follows, sorted by what it means for p8p8
# (docs/UPSTREAM.md)
upstreamcheck:
	@python3 tools/upstream_diff.py $(if $(FROM),--from $(FROM)) $(if $(TO),--to $(TO))

# make seedcheck: the compiler built from the seed and the one built by prog8c-llvm must
# be the same compiler: each compiles the sources, and the two results must be identical.
seedcheck:
	@tests/seedcheck.sh $(SEED) "$(PCC) $(PCCARGS)" "$(P8CARGS)" $(MAIN)

# make install [PREFIX=dir] [LIB=dir]: the compiler in PREFIX/bin and the library it builds
# programs with in PREFIX/lib/p8p8, where p8c finds it by itself.  LIB is the library
# (the directory with prog8lib/, common/ and targets/ in it).
PREFIX	?= $(HOME)/.local
LIB	?= lib
# (the compiler that is installed: this machine's, unless make cross gives another)
BIN	?= $(P8P8)
BINEXE	?= $(EXE)
install: $(P8P8)
	@test -f $(LIB)/prog8lib/prog8_lib.p8 || { echo "no library in '$(LIB)': give its directory with LIB=..."; exit 1; }
	$(MD) $(PREFIX)/bin $(PREFIX)/lib/p8p8
	cp $(BIN) $(PREFIX)/bin/p8c$(BINEXE)
	rm -rf $(PREFIX)/lib/p8p8/prog8lib $(PREFIX)/lib/p8p8/common $(PREFIX)/lib/p8p8/targets $(PREFIX)/lib/p8p8/triples
	cp -R $(LIB)/prog8lib $(LIB)/common $(LIB)/targets $(PREFIX)/lib/p8p8/
	@if [ -d $(LIB)/triples ]; then cp -R $(LIB)/triples $(PREFIX)/lib/p8p8/; fi
	cp $(LIB)/VERSION $(LIB)/LICENSE $(PREFIX)/lib/p8p8/
	$(MD) $(PREFIX)/lib/p8p8/runtime
	cp runtime/windows-console.c runtime/hosted-keys.c runtime/mos-c64-support.c $(PREFIX)/lib/p8p8/runtime/
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
	cp README.md CHANGELOG.md LICENSE dist/$(DISTNAME)/
	$(MD) dist/$(DISTNAME)/docs
	cp docs/*.md dist/$(DISTNAME)/docs/
	tar czf dist/$(DISTNAME).tar.gz -C dist $(DISTNAME)
	rm -rf dist/$(DISTNAME)
	@ls -l dist/$(DISTNAME).tar.gz | awk '{print "wrote", $$9 ":", $$5, "bytes"}'

# make cross TRIPLE=<profile> SYSROOT=<dir>: the compiler for a 32-bit machine of another
# kind, built here, as an archive like make dist's: dist/p8p8-<version>-<triple>.tar.gz.
# TRIPLE is a profile of the library's triples/ (armv7-unknown-linux-gnueabihf,
# riscv32-unknown-linux-gnu), SYSROOT that platform's C library and startup files; a
# gcc directory in it is used too.  CROSS_CLANG is a clang that knows the platform and
# links with lld (Homebrew's where there is one, else clang); CROSS_FLAGS are more
# arguments for it (-static, when the machine's C library is older than the sysroot's).
CROSS_CLANG ?= $(firstword $(wildcard /opt/homebrew/opt/llvm/bin/clang) clang)
CROSS_FLAGS ?=
CROSSDIR = build/cross/$(TRIPLE)
CROSSNAME = p8p8-$(VERSION)-$(TRIPLE)
cross:	$(P8P8)
	@test -n "$(TRIPLE)" || { echo "which machine?  make cross TRIPLE=<profile> SYSROOT=<dir>"; exit 1; }
	@test -d "$(SYSROOT)" || { echo "no sysroot '$(SYSROOT)': give the directory with SYSROOT=..."; exit 1; }
	$(MD) $(CROSSDIR)
	P8P8_CLANG=$(CROSS_CLANG) $(P8P8) -lib $(LIB) -target llvm32 -triple $(TRIPLE) \
	    -Xcompile --sysroot=$(SYSROOT) $(if $(wildcard $(SYSROOT)/gcc),-Xcompile --gcc-install-dir=$(SYSROOT)/gcc) \
	    -Xcompile -fuse-ld=lld $(foreach flag,$(CROSS_FLAGS),-Xcompile $(flag)) \
	    -srcdirs src:src/llvm32:src/llvm64 -o $(CROSSDIR)/p8c $(MAIN)
	rm -rf dist/$(CROSSNAME)
	$(MAKE) install BIN=$(CROSSDIR)/p8c BINEXE= PREFIX=dist/$(CROSSNAME) LIB=$(LIB)
	cp README.md CHANGELOG.md LICENSE dist/$(CROSSNAME)/
	$(MD) dist/$(CROSSNAME)/docs
	cp docs/*.md dist/$(CROSSNAME)/docs/
	COPYFILE_DISABLE=1 tar --no-xattrs -czf dist/$(CROSSNAME).tar.gz -C dist $(CROSSNAME)
	rm -rf dist/$(CROSSNAME)
	@ls -l dist/$(CROSSNAME).tar.gz | awk '{print "wrote", $$9 ":", $$5, "bytes"}'

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
	@$(P8P8) -lib lib -target c64 -out $(OUT) tests/zpfull.p8 2>&1 | diff -u tests/expected/zpfull.txt -
	@# (these two assemble programs: only where the assembler is)
	@if command -v 64tass > /dev/null 2>&1; then \
		tests/directivecheck.sh $(P8P8) $(OUT) | diff -u tests/expected/directives.txt - && \
		tests/romcheck.sh $(P8P8) $(OUT) | diff -u tests/expected/romable.txt -; \
	else echo "(no 64tass here: the directive and ROM checks are left out)"; fi
	@echo "test literals encoding_option"
	@$(P8P8) -target c64 -encoding iso -types -ast -nopos -nolib tests/encoding_option.p8 | diff -u tests/expected/$(TARGET)_literals_encoding_option.txt -
	@echo "test option order"
	@$(P8P8) tests/encoding_option.p8 -nolib -nopos -ast -types -encoding iso -target c64 | diff -u tests/expected/$(TARGET)_literals_encoding_option.txt -
	@$(P8P8) -lib lib -ir -out $(OUT) -target c64 tests/hello.p8 && mv $(OUT)/hello.p8ir $(OUT)/hello_before.p8ir
	@$(P8P8) tests/hello.p8 -target c64 -out $(OUT) -ir -lib lib && cmp $(OUT)/hello_before.p8ir $(OUT)/hello.p8ir
	@$(P8P8) tests/hello.p8 -target 2>&1 | diff -u tests/expected/option_value.txt -
	@echo "test srcdirs separators"
	@$(P8P8) -lib lib -target llvm64 -srcdirs "nonexistent;src;src/llvm64" -check $(MAIN)
	@$(P8P8) -lib lib -target llvm64 -srcdirs "nonexistent:src;src/llvm64" -check $(MAIN)
	@echo "test triple profiles"
	@$(P8P8) -lib lib -target llvm32 -triple armv7-unknown-linux-gnueabihf -llvm -out $(OUT) tests/hello.p8
	@sed -n '4,5p' $(OUT)/hello.ll | diff -u tests/expected/triple_arm.txt -
	@$(P8P8) -lib lib -target llvm32 -llvm -out $(OUT) tests/hello.p8
	@sed -n '4,5p' $(OUT)/hello.ll | diff -u tests/expected/triple_wasm.txt -
	@$(P8P8) -lib lib -target llvm32 -triple nosuch -check tests/hello.p8 2>&1 | diff -u tests/expected/triple_nosuch.txt -
	@$(P8P8) -lib lib -target llvm32 -triple tests/triple_unknown.properties -check tests/hello.p8 2>&1 | diff -u tests/expected/triple_unknown.txt -
	@echo "test 68000 IR"
	@$(P8P8) -lib lib -target qemu68k -ir -out $(OUT) tests/m68kir.p8
	@tools/m68kir.sh $(OUT)/m68kir.p8ir | diff -u tests/expected/m68kir_qemu.txt -
	@$(P8P8) -lib lib -target amiga500 -ir -out $(OUT) tests/m68kir.p8
	@grep -q '^output=AMIGAHUNK$$' $(OUT)/m68kir.p8ir
	@grep -q '^exec.OpenLibrary = -552 ; @bank 1$$' $(OUT)/m68kir.p8ir
	@grep -q '^callfar #1,-552,exec.OpenLibrary(r[0-9]*\.p@s19,r[0-9]*\.l@s10):r[0-9]*\.p@s10$$' $(OUT)/m68kir.p8ir
	@echo "test Amiga chip memory"
	@$(P8P8) -lib lib -target amiga500 -codegen own -ir -out $(OUT) tests/programs/amiga/chipram.p8
	@grep '^    section  .*_c,' $(OUT)/chipram.asm | diff -u tests/expected/chipram_sections.txt -
	@grep -q '^<BLOCK NAME="p8b_chip" ADDRESS="" AMIGACHIPRAM="true"' $(OUT)/chipram.p8ir
	@echo "test console runtime"
	@$(P8P8) -lib lib -target llvm64 -llvm -out $(OUT) tests/console.p8
	@grep -c '^declare i32 @prog8_getkey()\|^declare i32 @prog8_termsize()' $(OUT)/console.ll | diff -u tests/expected/console_two.txt -
	@echo "test report"
	@$(P8P8) -selfcrash tests/hello.p8 2>&1 | diff -u tests/expected/crash_message.txt -
	@rm -rf $(OUT)/report $(OUT)/report2
	@$(P8P8) -lib lib -target c64 -ir tests/hello.p8 -report $(OUT)/report | diff -u tests/expected/report_done.txt -
	@cmp tests/hello.p8 $(OUT)/report/src/hello.p8
	@test -s $(OUT)/report/out/hello.p8ir && test -s $(OUT)/report/output.txt
	@grep -c '^command: \|^exit status: 0\|^host: \|^p8p8 \|copied to src/hello.p8' $(OUT)/report/report.txt | diff -u tests/expected/report_lines.txt -
	@$(P8P8) -lib lib -target c64 -ir -selfcrash tests/hello.p8 -reportnosource -report $(OUT)/report2 | diff -u tests/expected/report_crash.txt -
	@grep -c 'internal error: the compiler crashed' $(OUT)/report2/output.txt | diff -u tests/expected/report_one.txt -
	@test ! -e $(OUT)/report2/src
	@for t in bad_resolve bad_types bad_strings bad_checks; do \
	    echo "test $$t (must be rejected)"; \
	    $(P8P8) tests/$$t.p8 > $(OUT)/$$t.out 2>&1; \
	    [ $$? -eq 1 ] || { echo "expected exit status 1"; exit 1; }; \
	    diff -u tests/expected/$(TARGET)_$$t.txt $(OUT)/$$t.out || exit 1; \
	done
	@echo "test bad_overlay (%overlay: where it may stand)"
	@$(P8P8) -lib lib -target cx16 -check tests/bad_overlay.p8 2>&1 | diff -u tests/expected/bad_overlay.txt -
	@echo "test bad_far (far memory on the MEGA65: what is refused)"
	@$(P8P8) -lib lib -target mega65 -check tests/bad_far.p8 2>&1 | diff -u tests/expected/bad_far.txt -
	@for t in bad_upstream bad_upstream2 bad_upstream_syntax; do \
	    echo "test $$t (upstream's checks, for the X16; must be rejected)"; \
	    $(P8P8) -lib lib -target cx16 -check tests/$$t.p8 > $(OUT)/$$t.out 2>&1; \
	    [ $$? -eq 1 ] || { echo "expected exit status 1"; exit 1; }; \
	    diff -u tests/expected/$$t.txt $(OUT)/$$t.out || exit 1; \
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
# (tests/conformance goes through the language feature by feature; make conformance runs
#  only those, in the virtual machine and natively)
CONFTESTS=$(wildcard tests/conformance/*.p8)
VMTESTS=$(wildcard .prog8-reference/compiler/test/arithmetic/*.p8 .prog8-reference/compiler/test/comparisons/*.p8) .prog8-reference/examples/virtual/bsieve.p8 .prog8-reference/examples/virtual/sincos.p8 $(PTRTESTS) $(wildcard tests/programs/*.p8) $(CONFTESTS)
vmcmp:	$(P8P8)
	@tests/vmcmp.sh $(P8P8) .prog8-reference $(VMTESTS)

# a .p8ir file as input: p8c's own IR, read back, gives the same IR and the same code
IRTESTS=tests/hello.p8 $(wildcard tests/programs/*.p8)
irroundtrip:	$(P8P8)
	@tests/irroundtrip.sh $(P8P8) cx16 $(IRTESTS)
	@tests/irroundtrip.sh $(P8P8) c64 $(IRTESTS)
	@tests/irroundtrip.sh $(P8P8) llvm64 $(IRTESTS)
	@tests/irroundtrip.sh $(P8P8) qemu68k $(IRTESTS)

conformance:	$(P8P8)
	@tests/vmcmp.sh $(P8P8) .prog8-reference $(CONFTESTS)
	@tests/nativecmp.sh $(P8P8) .prog8-reference $(CONFTESTS)

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
	@tests/hostbootstrap.sh $(P8P8) $(TRIPLE) .prog8-reference $(MAIN) $(SRCDIRS)

# the compiler itself on a 32-bit host: p8c built for llvm32 (WebAssembly) and run with wasmtime must write
# what the native p8c writes, for its own source and for the 6502 assembly of test programs and examples
WASITESTS=$(wildcard tests/programs/*.p8) $(CONFTESTS) $(wildcard .prog8-reference/examples/*.p8 .prog8-reference/examples/c64/*.p8 .prog8-reference/examples/cx16/*.p8)
wasihost:	$(P8P8)
	@tests/wasihost.sh $(P8P8) $(MAIN) $(WASITESTS)

# the 68000: programs built for qemu68k by prog8c-llvm and by p8p8's own code generator, run in QEMU
# (needs vasmm68k_mot, vlink and qemu-system-m68k; not localzero.p8: a @dirty local is in the
#  frame upstream and static here, and not callpointer.p8: it keeps addresses in words)
QEMUTESTS=tests/hello.p8 $(filter-out %/localzero.p8 %/callpointer.p8,$(wildcard tests/programs/*.p8)) $(CONFTESTS) \
	$(addprefix .prog8-reference/examples/,fibonacci.p8 primes.p8)
qemucmp:	$(P8P8)
	@tests/qemucmp.sh $(P8P8) $(QEMUTESTS)

# p8p8's IR built by prog8c-llvm's 68000 back end (-codegen upstream), against prog8c-llvm from the source
qemucmpir:	$(P8P8)
	@QEMUCMP_CODEGEN=upstream tests/qemucmp.sh $(P8P8) $(QEMUTESTS)

# the same for the Amiga 1200, run in vamos (P8P8_VAMOS names it when it is not in the PATH)
AMIGATESTS=$(QEMUTESTS) $(wildcard tests/programs/amiga/*.p8)
amigacmp:	$(P8P8)
	@QEMUCMP_TARGET=amiga1200 tests/qemucmp.sh $(P8P8) $(AMIGATESTS)

# an Amiga 1200 with an FPU in the Copperline emulator: the programs with floats, which vamos cannot run
amigacmpfloat:	$(P8P8)
	@QEMUCMP_TARGET=amiga1200 QEMUCMP_COPPERLINE=1 tests/qemucmp.sh $(P8P8) tests/hello.p8 tests/conformance/floating.p8

# upstream's Amiga examples, the ones that open screens and windows too: both compilers'
# programs in Copperline, the screen after 90 emulated seconds compared (the picture is
# finished by then; p8p8's code is slower).  Not the ones that keep moving (3d, rasters,
# star-blit, window3d, agabobs, penrose-triangle, beachballs, lineclip-easygfx) or print how long something
# took (lowlevel-timer, hwtimers).
# COPPERCMP_TARGET=amiga1200 for that machine; COPPERCMP_ROM names a Kickstart file.
COPPERTESTS=$(filter-out %/3d.p8 %/rasters.p8 %/star-blit.p8 %/window3d.p8 %/agabobs.p8 %/penrose-triangle.p8 %/beachballs.p8 %/lineclip-easygfx.p8 %/lowlevel-timer.p8 %/hwtimers.p8,$(wildcard .prog8-reference/examples/amiga/*.p8))
coppercmp:	$(P8P8)
	@COPPERCMP_SECONDS=$${COPPERCMP_SECONDS:-90} tests/coppercmp.sh $(P8P8) $(COPPERTESTS)

# and for the Amiga 500: a 68000, long multiplication and division by the library's routines
amigacmp500:	$(P8P8)
	@QEMUCMP_TARGET=amiga500 tests/qemucmp.sh $(P8P8) $(AMIGATESTS)

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
	$(addprefix .prog8-reference/examples/,fibonacci.p8 primes.p8 maze.p8 screencodes.p8 swirl-float.p8 numbergame.p8) $(PTRTESTS) $(wildcard tests/programs/*.p8) $(CONFTESTS)
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
# the 45GS02, on the MEGA65 in xmega65 (Xemu): p8p8's 6502 code for that machine (-cpu 6502)
# against its code for the machine's own CPU; no other compiler has one to compare with
emucmp65:	$(P8P8)
	@tests/emucmp65.sh $(P8P8) $(EMUTESTS64)

# addresses of more than 16 bits, in assembly written by hand: the 65816's four long
# addressing modes (x16emu -c816, xscpu64) and the 45GS02's [zp],z (xmega65)
farcheck:	$(P8P8)
	@tests/farcheck.sh $(P8P8) | diff -u tests/expected/farcheck.txt -

# make overlaycheck: programs with overlays (%overlay n) on the Commander X16, built with
# their loader and run in x16emu
overlaycheck:	$(P8P8)
	@tests/overlaycheck.sh $(P8P8) | diff -u tests/expected/overlaycheck.txt - && echo "overlay check: as expected"

# make z80cmp: the Z80 code generator (new): the test programs built for the host and for
# CP/M on the Z80 (llvm16 with the z80-cpm triple), run in tnylpo, their output compared.
# What it cannot build yet is counted, not a failure.
z80cmp:	$(P8P8)
	@tests/z80cmp.sh $(P8P8) $(wildcard tests/programs/*.p8 tests/conformance/*.p8)

emucmp64:	$(P8P8)
	@EMUCMP_TARGET=c64 tests/emucmp.sh $(P8P8) .prog8-reference $(EMUTESTS64)

# the 65816: p8p8's code for that CPU (-cpu 65816) on x16emu -c816 and on VICE's SuperCPU C64 (xscpu64),
# against the reference compiler's 65C02 and 6502 programs on the same machines
emucmp816:	$(P8P8)
	@EMUCMP_CPU=65816 EMUCMP_CODEGEN=own tests/emucmp.sh $(P8P8) .prog8-reference $(EMUTESTS)
emucmp64816:	$(P8P8)
	@EMUCMP_CPU=65816 EMUCMP_CODEGEN=own EMUCMP_TARGET=c64 tests/emucmp.sh $(P8P8) .prog8-reference $(EMUTESTS64)

# make quick816: a few minutes, for use after every change to the 65816 code.  The
# programs that have caught mistakes there so far, on both machines; the full suites
# (emucmp816, emucmp64816, and the 6502 ones) are for a finished piece of work.
QUICK816=tests/hello.p8 tests/programs/wordruns.p8 tests/programs/constmul.p8 tests/programs/defer.p8 \
	tests/conformance/arith.p8 tests/conformance/assign.p8 tests/conformance/arrays.p8 tests/conformance/pointers.p8 \
	tests/conformance/compare.p8 tests/conformance/control.p8 .prog8-reference/compiler/test/arithmetic/minus.p8 \
	.prog8-reference/compiler/test/comparisons/more_compares.p8
QUICK816C64=tests/programs/wordruns.p8 tests/conformance/arith.p8 tests/conformance/compare.p8 tests/conformance/floating.p8 \
	.prog8-reference/compiler/test/arithmetic/div.p8
quick816:	$(P8P8)
	@EMUCMP_SECONDS=3 EMUCMP_CPU=65816 EMUCMP_CODEGEN=own tests/emucmp.sh $(P8P8) .prog8-reference $(QUICK816) | grep -v '^ok'
	@EMUCMP_CPU=65816 EMUCMP_CODEGEN=own EMUCMP_TARGET=c64 tests/emucmp.sh $(P8P8) .prog8-reference $(QUICK816C64) | grep -v '^ok'

# the self-hosting test: stage 2 is p8p8 compiled by itself, stage 3 must be identical to stage 2
bootstrap:	$(P8P8)
	@BOOTSTRAP_TARGET=$(TARGET) tests/bootstrap.sh $(P8P8) .prog8-reference $(MAIN) $(SRCDIRS)

stats:	$(P8P8)
	@echo "source lines:"; wc -l $(SRCS) | sort -n
	@echo "executables:"; ls -l $(P8P8) $(TESTBIN) 2>/dev/null | awk '{print $$5, $$9}'

#
# end-of-file
#
