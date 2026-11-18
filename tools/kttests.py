#!/usr/bin/env python3
"""Upstream's unit tests as a test of p8p8: the Prog8 programs that are written inside
the Kotlin test sources (compiler/test/**/*.kt, between triple quotes) are taken out,
each is compiled by the reference compiler and by p8p8, and where one accepts a program
that the other rejects, that is reported.

The reference compiler is the oracle, not the Kotlin code around a program: what a test
expects is not read.  So a program that upstream's test expects to fail and that fails
for both is fine, whatever the message.

A program is taken when it has a main block and nothing of Kotlin's left in it: "${'$'}"
is a dollar sign and so is one before a digit, any other "$name" or "${...}" is a Kotlin
value and the program is left out (counted).  Its target is the first "XxxTarget()" after it in the file (cx16 when
there is none).

Upstream's sources are not part of this repository: PROG8_SRC names a checkout.  The
reference compiler's answers are kept in the work directory (cache.json, by the
program's text), so only the first run is slow.

Usage (from the repository root):
    PROG8_SRC=<checkout> python3 tools/kttests.py [-j N] [-x] [--only TEXT] [workdir]
        -j N        compile N programs at a time (4)
        -x          only take the programs out (into workdir/src), compile nothing
        --only TEXT only the programs whose name has TEXT in it
The report goes to the terminal and to workdir/report.txt; the exit status is 1 when
the two compilers disagree anywhere.
"""
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import textwrap

TARGETS = {'C64': 'c64', 'Cx16': 'cx16', 'C128': 'c128', 'PET32': 'pet32', 'VM': 'virtual'}


def arguments():
    jobs, extract_only, only, work = 4, False, None, None
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == '-j':
            jobs = int(args.pop(0))
        elif a == '-x':
            extract_only = True
        elif a == '--only':
            only = args.pop(0)
        else:
            work = a
    return jobs, extract_only, only, work or os.path.join(os.environ.get('TMPDIR', '/tmp'), 'p8p8_kttests')


def programs(root):
    """(name, target, text) for every program in the Kotlin files under root, and how many were left out."""
    found, skipped = [], 0
    for directory, _, files in sorted(os.walk(root)):
        for file in sorted(files):
            if not file.endswith('.kt'):
                continue
            source = open(os.path.join(directory, file), encoding='utf-8', errors='replace').read()
            for match in re.finditer(r'"""(.*?)"""', source, re.S):
                text = match.group(1)
                if not re.search(r'\bmain\s*\{', text):
                    continue
                text = text.replace("${'$'}", '\x00')
                if re.search(r'\$[A-Za-z_{]', text):
                    skipped += 1
                    continue
                text = textwrap.dedent(text.replace('\x00', '$')).strip('\n') + '\n'
                after = re.search(r'\b(\w+)Target\(\)', source[match.end():match.end() + 2000])
                target = TARGETS.get(after.group(1), 'cx16') if after else 'cx16'
                line = source.count('\n', 0, match.start()) + 1
                found.append((f'{file[:-3]}_{line}', target, text))
    return found, skipped


def plain(text):
    return re.sub(r'\x1b\[[0-9;]*m', '', text)


def first_error(output):
    for line in plain(output).split('\n'):
        if 'error' in line.lower() and 'There are' not in line:
            line = re.sub(r'^.*\.p8:(\d+):\d+:\s*(error:\s*)?', r'\1: ', line.strip())
            line = re.sub(r'^\S*/([^/\s]+\.asm)', r'\1', line)      # (the assembler's: without the directory)
            return re.sub(r'^ERROR\s*', '', line)[:140]
    return '(failed without a message)'


def compile_with(command, timeout=120):
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout, errors='replace')
        return done.returncode == 0, done.stdout + done.stderr
    except subprocess.TimeoutExpired:
        return False, 'error: the compiler did not finish'


def main():
    jobs, extract_only, only, work = arguments()
    root = os.environ.get('PROG8_SRC')
    if not root or not os.path.isdir(os.path.join(root, 'compiler', 'test')):
        sys.exit('PROG8_SRC must name a checkout of Prog8 (it has compiler/test)')
    tests = os.path.join(root, 'compiler', 'test')
    fixtures = os.path.join(tests, 'fixtures')
    lib = os.environ.get('P8P8_LIB', 'lib')
    p8c = os.environ.get('P8C', 'build/llvm64/p8c')
    found, skipped = programs(tests)
    if only:
        found = [p for p in found if only in p[0]]
    srcdir = os.path.join(work, 'src')
    os.makedirs(srcdir, exist_ok=True)
    for name, target, text in found:
        open(os.path.join(srcdir, name + '.p8'), 'w').write(text)
    print(f'{len(found)} programs taken out of the Kotlin tests into {srcdir}; '
          f'{skipped} left out (they have Kotlin values in them)')
    if extract_only:
        return
    version = plain(subprocess.run(['prog8c-llvm', '-version'], capture_output=True, text=True).stdout).strip()[:80]
    cache_file = os.path.join(work, 'cache.json')
    cache = json.load(open(cache_file)) if os.path.exists(cache_file) else {}

    def one(program):
        name, target, text = program
        file = os.path.join(srcdir, name + '.p8')
        out = os.path.join(work, 'out', name)
        os.makedirs(out, exist_ok=True)
        key = hashlib.sha1((version + '\0' + target + '\0' + text).encode()).hexdigest()
        if key not in cache:
            ok, output = compile_with(['prog8c-llvm', '-target', target, '-quiet', '-srcdirs', fixtures,
                                       '-out', out, file])
            cache[key] = [ok, '' if ok else first_error(output)]
        up_ok, up_message = cache[key]
        ok, output = compile_with([p8c, '-target', target, '-lib', lib, '-srcdirs', fixtures, '-out', out, file])
        return name, target, up_ok, up_message, ok, '' if ok else first_error(output)

    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        results = list(pool.map(one, found))
    json.dump(cache, open(cache_file, 'w'))
    both = sum(1 for r in results if r[2] and r[4])
    neither = sum(1 for r in results if not r[2] and not r[4])
    lacking = [r for r in results if r[2] and not r[4]]
    lenient = [r for r in results if not r[2] and r[4]]
    lines = [f'{len(results)} programs: {both} built by both, {neither} rejected by both, '
             f'{len(lacking)} that only upstream builds, {len(lenient)} that only p8p8 builds']
    if lacking:
        lines.append('')
        lines.append('upstream builds it, p8p8 does not:')
        for name, target, _, _, _, message in lacking:
            lines.append(f'  {name} [{target}]  {message}')
    if lenient:
        lines.append('')
        lines.append('upstream rejects it, p8p8 builds it:')
        for name, target, _, message, _, _ in lenient:
            lines.append(f'  {name} [{target}]  {message}')
    report = '\n'.join(lines) + '\n'
    open(os.path.join(work, 'report.txt'), 'w').write(report)
    sys.stdout.write(report)
    sys.exit(1 if lacking or lenient else 0)


if __name__ == '__main__':
    main()
