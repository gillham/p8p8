#!/usr/bin/env python3
"""Extracts the file and directory helper functions from LLVM IR that upstream
prog8c-llvm wrote for runtime/alldisk.p8 (a program that uses all of diskio).

The result holds the helpers' globals, the functions @.diskio.* and @.file.*,
and declarations of the C library functions they call.  tools/gen_llvmrt.py
turns it into src/llvmrt.p8.

Usage:
  prog8c-llvm -target llvm32 -plaintext -out build/rt runtime/alldisk.p8
  python3 tools/extract_llvmrt.py llvm32 build/rt/alldisk.ll > runtime/llvm32_file.ll
"""
import re
import sys

HELPER = re.compile(r'@(\.diskio\.|\.file\.|\.sys\.curdir\.buf)')


def main():
    target, path = sys.argv[1], sys.argv[2]
    lines = open(path, encoding='utf-8').read().split('\n')
    globals_, functions, declares = [], [], {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith('declare '):
            m = re.search(r'@([A-Za-z0-9_.]+)\(', line)
            if m:
                declares[m.group(1)] = line
        elif line.startswith('@') and HELPER.match(line):
            globals_.append(line)
        elif line.startswith('define ') and HELPER.search(line.split('(')[0]):
            body = []
            while lines[i] != '}':
                body.append(lines[i])
                i += 1
            body.append('}')
            functions.append(re.sub(r' #\d+ \{', ' {', '\n'.join(body)))
        i += 1
    text = '\n\n'.join(functions)
    defined = set(re.findall(r'^define [^@]*@([A-Za-z0-9_.]+)\(', text, re.M))
    called = []
    for name in re.findall(r'@([A-Za-z0-9_.]+)\(', text):
        if name not in defined and name in declares and name not in called:
            called.append(name)
    print('; File and directory helpers of the %s target, as upstream prog8c-llvm emits them' % target)
    print('; (extracted by tools/extract_llvmrt.py from its output for runtime/alldisk.p8).')
    print('; tools/gen_llvmrt.py turns this file into src/llvmrt.p8.')
    print()
    print('\n'.join(globals_))
    print()
    print(text)
    print()
    print('\n'.join(declares[name] for name in called))


if __name__ == '__main__':
    main()
