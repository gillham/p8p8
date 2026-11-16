#!/bin/sh
# Checks an llvm64 triple profile on a machine of that kind.  For each program, p8p8
# writes LLVM IR for the triple here; the other machine builds it with its clang and
# runs it; the output is compared with that of the same program built and run here.
#
# The machine is reached with ssh and named by P8P8_HOST (not kept in this repository).
# It needs clang; everything happens in a new directory under /tmp there (%TEMP% on
# Windows, for a triple with "windows" in it), removed at the end.  Programs whose output depends on the machine (directory listings, the time)
# are not for this test.
#
# HOSTCMP_TARGET=llvm32 does it for a 32-bit profile: the triple names a file in
# the library's triples directory, and the output is still compared with the
# 64-bit program's here.
#
# Usage: P8P8_HOST=<ssh host> tests/hostcmp.sh <p8p8> <triple> <reference dir> <file.p8>...
p8p8=$1
triple=$2
ref=$3
shift 3
lib=${P8P8_LIB:-lib}
target=${HOSTCMP_TARGET:-llvm64}
if [ -z "$P8P8_HOST" ]; then
    echo "set P8P8_HOST to the ssh name of a machine for $triple"
    exit 2
fi
work=${TMPDIR:-/tmp}/p8p8_hostcmp.$$
mkdir -p "$work/here" "$work/there" "$work/back"
linkargs=
case "$triple" in *linux*) linkargs=-lm ;; esac
names=
failed=0
total=0
for f in "$@"; do
    name=$(basename "$f" .p8)
    if ! "$p8p8" -target llvm64 -lib "$lib" -llvm -out "$work/here" "$f" > "$work/err" 2>&1 \
        || ! clang -O2 -Wno-override-module "$work/here/$name.ll" -o "$work/here/$name" > "$work/err" 2>&1; then
        echo "skipped (does not build here): $f"
        continue
    fi
    timeout 60 "$work/here/$name" < /dev/null > "$work/here/$name.out" 2>&1
    if ! "$p8p8" -target "$target" -triple "$triple" -lib "$lib" -llvm -out "$work/there" "$f" > "$work/err" 2>&1; then
        echo "failed (p8p8 rejects it for $triple): $f"
        head -3 "$work/err"
        failed=$((failed + 1))
        total=$((total + 1))
        continue
    fi
    names="$names $name"
done
case "$triple" in
*windows*)
    # a Windows machine: cmd is the shell, the work is done by a batch file in a new
    # directory under %TEMP%; the programs are linked with the console support source
    remote=$(ssh -o BatchMode=yes "$P8P8_HOST" 'echo %TEMP%' 2> /dev/null | tr -d '\r' | tail -1)
    if [ -z "$remote" ]; then
        echo "cannot reach the machine"
        exit 2
    fi
    remote="$remote\\p8p8_hostcmp_$$"
    ssh -o BatchMode=yes "$P8P8_HOST" "mkdir \"$remote\"" 2> /dev/null
    cp "${P8P8_RUNTIME:-runtime}/windows-console.c" "$work/there/"
    {
        printf '@echo off\r\n'
        printf 'clang --target=%s -O2 -c windows-console.c -o support.obj > support.build 2>&1\r\n' "$triple"
        for name in $names; do
            printf 'clang --target=%s -O2 -Wno-override-module support.obj %s.ll -o %s.exe > %s.build 2>&1\r\n' "$triple" "$name" "$name" "$name"
            printf 'if errorlevel 1 (echo BUILD-FAILED> %s.out) else (%s.exe < nul > %s.out 2>&1)\r\n' "$name" "$name" "$name"
        done
    } > "$work/there/run.bat"
    (cd "$work/there" && COPYFILE_DISABLE=1 tar cf - *.ll windows-console.c run.bat) \
        | ssh -o BatchMode=yes "$P8P8_HOST" "tar xf - -C \"$remote\"" 2> /dev/null
    ssh -o BatchMode=yes "$P8P8_HOST" "cd /d \"$remote\" && run.bat" > /dev/null 2>&1
    ssh -o BatchMode=yes "$P8P8_HOST" "cd /d \"$remote\" && tar cf - *.out *.build" 2> /dev/null | tar xf - -C "$work/back" 2> /dev/null
    ssh -o BatchMode=yes "$P8P8_HOST" "rmdir /s /q \"$remote\"" 2> /dev/null
    ;;
*)
    remote=$(echo 'mktemp -d /tmp/p8p8_hostcmp.XXXXXX' | ssh -o BatchMode=yes "$P8P8_HOST" sh -s)
    if [ -z "$remote" ]; then
        echo "cannot reach the machine"
        exit 2
    fi
    # (a program that reads keys or asks for the terminal's size needs the console runtime)
    cp "${P8P8_RUNTIME:-runtime}/hosted-keys.c" "$work/there/"
    (cd "$work/there" && COPYFILE_DISABLE=1 tar cf - *.ll hosted-keys.c) | ssh -o BatchMode=yes "$P8P8_HOST" "tar xf - -C $remote 2> /dev/null"
    {
        echo "cd $remote"
        for name in $names; do
            keys=
            grep -q '^declare .* @prog8_\(getkey\|waitkey\|termsize\)' "$work/there/$name.ll" && keys=hosted-keys.c
            echo "if clang -O2 -Wno-override-module $keys $name.ll -o $name $linkargs > $name.build 2>&1; then"
            echo "  (./$name < /dev/null > $name.out 2>&1) 2> /dev/null; else echo BUILD-FAILED > $name.out; fi"
        done
        echo "tar cf - *.out *.build"
    } | ssh -o BatchMode=yes "$P8P8_HOST" sh -s | tar xf - -C "$work/back"
    echo "rm -rf $remote" | ssh -o BatchMode=yes "$P8P8_HOST" sh -s
    ;;
esac
for name in $names; do
    total=$((total + 1))
    if cmp -s "$work/here/$name.out" "$work/back/$name.out"; then
        echo "ok: $name"
    else
        echo "failed (output differs on $triple): $name"
        if grep -q BUILD-FAILED "$work/back/$name.out"; then
            head -5 "$work/back/$name.build"
        else
            diff "$work/here/$name.out" "$work/back/$name.out" | head -8
        fi
        failed=$((failed + 1))
    fi
done
rm -rf "$work"
echo "host comparison ($triple): $total programs, $failed failed"
[ "$failed" -eq 0 ]
