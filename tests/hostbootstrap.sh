#!/bin/sh
# Self-hosting on another kind of machine.  p8p8 here writes its own LLVM IR for the
# triple; the other machine builds that into a p8p8, which then compiles the p8p8 source
# itself.  The IR it writes there must be the IR that was sent, byte for byte.  The new
# p8p8 also builds and runs hello, and lists a directory (the readdir details differ per
# platform).
#
# The machine is reached with ssh and named by P8P8_HOST (not kept in this repository).
# It needs clang.  Everything happens in a new directory under /tmp there (%TEMP% on
# Windows), removed at the end.
#
# Usage: P8P8_HOST=<ssh host> tests/hostbootstrap.sh <p8p8> <triple> <reference dir> <main.p8> <srcdirs>
p8p8=$1
triple=$2
ref=$3
main=$4
srcdirs=$5
lib=${P8P8_LIB:-lib}
if [ -z "$P8P8_HOST" ]; then
    echo "set P8P8_HOST to the ssh name of a machine for $triple"
    exit 2
fi
name=$(basename "$main" .p8)
work=${TMPDIR:-/tmp}/p8p8_hostbootstrap.$$
mkdir -p "$work/send"
"$p8p8" -target llvm64 -triple "$triple" -lib "$lib" -srcdirs "$srcdirs" -llvm -out "$work/send" "$main" || exit 1
linkargs=
case "$triple" in *linux*) linkargs=-lm ;; esac
case "$triple" in
*windows*)
    # a Windows machine: cmd is the shell, the work is done by a batch file in a new
    # directory under %TEMP%
    remote=$(ssh -o BatchMode=yes "$P8P8_HOST" 'echo %TEMP%' 2> /dev/null | tr -d '\r' | tail -1)
    if [ -z "$remote" ]; then
        echo "cannot reach the machine"
        exit 2
    fi
    remote="$remote\\p8p8_hostbootstrap_$$"
    ssh -o BatchMode=yes "$P8P8_HOST" "mkdir \"$remote\"" 2> /dev/null
    wsrcdirs=$(echo "$srcdirs" | tr ':' ';')
    {
        printf '@echo off\r\n'
        printf 'clang -O2 -Wno-override-module runtime/windows-console.c %s.ll -o p8c.exe || (echo BUILD-FAILED & exit /b 1)\r\n' "$name"
        printf 'mkdir out hello lsdir\r\n'
        printf 'p8c.exe -target llvm64 -lib lib -srcdirs %s -llvm -out out %s || echo SELF-COMPILE-FAILED\r\n' "$srcdirs" "$main"
        printf 'fc /b %s.ll out\\%s.ll > nul && (echo IDENTICAL) || (echo DIFFERENT)\r\n' "$name" "$name"
        printf 'p8c.exe -lib lib -out hello -run tests/hello.p8 > hello.txt 2>&1\r\n'
        printf 'set /p HELLO=<hello.txt\r\n'
        printf 'echo hello: %%HELLO%%\r\n'
        printf 'echo x> lsdir\\alpha.txt\r\n'
        printf 'echo y> lsdir\\beta.txt\r\n'
        printf 'mkdir lsdir\\gamma\r\n'
        printf 'p8c.exe -lib lib -out hello -build examples/llvm/ls.p8\r\n'
        printf 'cd lsdir\r\n'
        printf '..\\hello\\ls.exe\r\n'
    } > "$work/send/run.bat"
    tar cf - -C "$work/send" "$name.ll" run.bat | ssh -o BatchMode=yes "$P8P8_HOST" "tar xf - -C \"$remote\"" 2> /dev/null
    COPYFILE_DISABLE=1 tar cf - src tests/hello.p8 runtime "$lib/prog8lib" "$lib/common" "$lib/targets" -C "$ref" examples/llvm/ls.p8 \
        | ssh -o BatchMode=yes "$P8P8_HOST" "tar xf - -C \"$remote\"" 2> /dev/null
    ssh -o BatchMode=yes "$P8P8_HOST" "cd /d \"$remote\" && run.bat" 2> /dev/null | tr -d '\r' | sed 's/^ *[0-9][0-9]*\t/ls: &/' > "$work/result"
    ssh -o BatchMode=yes "$P8P8_HOST" "rmdir /s /q \"$remote\"" 2> /dev/null
    ;;
*)
    remote=$(echo 'mktemp -d /tmp/p8p8_hostbootstrap.XXXXXX' | ssh -o BatchMode=yes "$P8P8_HOST" sh -s)
    if [ -z "$remote" ]; then
        echo "cannot reach the machine"
        exit 2
    fi
    # the IR, the source, the library, and two test programs
    {
        tar cf - -C "$work/send" "$name.ll"
    } | ssh -o BatchMode=yes "$P8P8_HOST" "tar xf - -C $remote 2> /dev/null"
    tar cf - src tests/hello.p8 runtime "$lib/prog8lib" "$lib/common" "$lib/targets" -C "$ref" examples/llvm/ls.p8 \
        | ssh -o BatchMode=yes "$P8P8_HOST" "tar xf - -C $remote 2> /dev/null"
    {
        echo "cd $remote || exit 1"
        echo "clang -O2 -Wno-override-module $name.ll -o p8c $linkargs || { echo BUILD-FAILED; exit 1; }"
        echo "mkdir out hello lsdir"
        echo "./p8c -target llvm64 -lib lib -srcdirs $srcdirs -llvm -out out $main || echo SELF-COMPILE-FAILED"
        echo "if cmp -s $name.ll out/$name.ll; then echo IDENTICAL; else echo DIFFERENT; fi"
        echo "echo hello: \$(./p8c -lib lib -out hello -run tests/hello.p8 2>&1)"
        echo "touch lsdir/alpha.txt lsdir/beta.txt; mkdir lsdir/gamma"
        echo "./p8c -lib lib -out hello -build examples/llvm/ls.p8 && (cd lsdir && ../hello/ls | sed 's/^/ls: /')"
        echo "head -5 out/$name.ll | sed -n 5p"
    } | ssh -o BatchMode=yes "$P8P8_HOST" sh -s > "$work/result" 2>&1
    echo "rm -rf $remote" | ssh -o BatchMode=yes "$P8P8_HOST" sh -s
    ;;
esac
cat "$work/result"
ok=0
grep -q '^IDENTICAL$' "$work/result" && grep -q '^hello: hello, world!$' "$work/result" && grep -q 'alpha.txt' "$work/result" && ok=1
rm -rf "$work"
if [ $ok -eq 1 ]; then
    echo "host bootstrap ($triple): p8p8 built there compiles itself to the same LLVM IR"
else
    echo "host bootstrap ($triple): FAILED"
    exit 1
fi
