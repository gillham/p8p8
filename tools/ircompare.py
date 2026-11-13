#!/usr/bin/env python3
"""Structural comparison of two .p8ir files: upstream's and p8p8's.

The two compilers number registers, name generated labels and order code
differently, and upstream optimizes and removes unused code, so the files
cannot be compared line by line.  This compares what must agree anyway,
for every subroutine and asmsub that upstream kept:

  - the asmsub declarations (address, clobbers, returns, parameters)
  - the subroutine signatures (return types, parameters)
  - the calls each subroutine makes, as a multiset with registers
    normalized (targets, argument locations and types)
  - the declarations of the variables both files have

Usage: python3 tools/ircompare.py upstream.p8ir p8p8.p8ir [-v]
"""
import re
import sys
from collections import Counter


def parse(path):
    text = open(path, encoding='utf-8', errors='replace').read()
    subs = {}
    for m in re.finditer(r'<SUB NAME="([^"]*)" RETURNS="([^"]*)"[^>]*>(.*?)</SUB>', text, re.S):
        name, returns, body = m.groups()
        params = re.search(r'<PARAMS>(.*?)</PARAMS>', body, re.S)
        plist = tuple(l.strip() for l in (params.group(1) if params else '').strip().splitlines() if l.strip())
        calls = Counter()
        for code in re.findall(r'<CODE>(.*?)</CODE>', body, re.S):
            for line in code.splitlines():
                if line.startswith(('call ', 'callfar ', 'syscall ')):
                    calls[normalize(line)] += 1
        subs[name] = ('sub', returns, plist, calls)
    asmsubs = {}
    for m in re.finditer(r'<ASMSUB NAME="([^"]*)" ADDRESS="([^"]*)" CLOBBERS="([^"]*)"(?: CLOBBERSDECLARED="([^"]*)")? RETURNS="([^"]*)" POS="[^"]*" INLINE="([^"]*)"[^>]*>\s*<ASMPARAMS>(.*?)</ASMPARAMS>', text, re.S):
        name, address, clobbers, declared, returns, inline, params = m.groups()
        plist = tuple(l.strip() for l in params.strip().splitlines() if l.strip())
        asmsubs[name] = (address, clobbers, declared or '', returns, inline, plist)
    variables = {}
    for section in ('NOINITCLEAN', 'NOINITDIRTY', 'INIT', 'CONSTANTS', 'MEMORYMAPPED'):
        m = re.search(r'<%s>(.*?)</%s>' % (section, section), text, re.S)
        if not m:
            continue
        for line in m.group(1).strip().splitlines():
            parts = line.split(' ', 2)
            if len(parts) < 2:
                continue
            vtype = parts[0]
            vname = parts[1].split('=')[0]
            if vname.startswith('prog8_interned_strings.') or 'auto_heap_value' in vname:
                continue        # numbered by each compiler in its own order
            variables[vname] = (section, vtype)
    return subs, asmsubs, variables


def normalize(line):
    line = re.sub(r'\bf?r\d+\.', 'r.', line)
    line = re.sub(r'#[A-Za-z_][A-Za-z0-9_.]*', '#sym', line)
    line = re.sub(r'#\$?[0-9a-fA-F-]+\.', '#n.', line)       # constant values may be folded differently
    return line


def main():
    verbose = '-v' in sys.argv
    args = [a for a in sys.argv[1:] if a != '-v']
    up_subs, up_asm, up_vars = parse(args[0])
    my_subs, my_asm, my_vars = parse(args[1])
    problems = Counter()
    details = []

    def report(kind, text):
        problems[kind] += 1
        details.append('%s: %s' % (kind, text))

    for name, decl in sorted(up_asm.items()):
        if name not in my_asm:
            report('asmsub missing', name)
        elif my_asm[name] != decl:
            report('asmsub differs', '%s\n    upstream %s\n    p8p8     %s' % (name, decl, my_asm[name]))
    for name, (_, returns, params, calls) in sorted(up_subs.items()):
        if name not in my_subs:
            report('sub missing', name)
            continue
        _, myreturns, myparams, mycalls = my_subs[name]
        if returns != myreturns or params != myparams:
            report('sub signature differs', '%s\n    upstream %s %s\n    p8p8     %s %s' % (name, returns, params, myreturns, myparams))
        if calls != mycalls:
            only_up = calls - mycalls
            only_my = mycalls - calls
            report('sub calls differ', '%s\n    only upstream: %s\n    only p8p8:     %s' % (
                name, dict(only_up), dict(only_my)))
    for name, decl in sorted(up_vars.items()):
        if name not in my_vars:
            report('variable missing', '%s %s' % (name, decl))
        elif my_vars[name] != decl:
            report('variable differs', '%s upstream %s p8p8 %s' % (name, decl, my_vars[name]))

    print('%d asmsubs, %d subs, %d variables in upstream' % (len(up_asm), len(up_subs), len(up_vars)))
    for kind, count in sorted(problems.items()):
        print('  %-24s %d' % (kind, count))
    if not problems:
        print('  no structural differences')
    if verbose:
        for d in details:
            print(d)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
