#!/usr/bin/env python3
"""Test vectors for the 68000 machines' float routines (lib/common/m68k_softfloat.asm).

vectors.py make <dir>     writes <dir>/table.s (operation, operand, operand as longs,
                          for tests/softfloat/driver.s) and <dir>/rows.txt, <dir>/expect.txt
vectors.py check <dir> <output>
                          compares what the driver printed (a result in hex on a line)

The operations: 0 add, 1 subtract, 2 multiply, 3 divide, 4 compare, 5 long to float,
6 float to long, 7 square root.  What is expected is Python's arithmetic rounded to
a single; the square root may be one unit in the last place off.  Operands and
results that are 0 or too small for a normal single are left out of the arithmetic
(the routines have no denormals and one zero).
"""
import math
import random
import struct
import sys

random.seed(7)
def bits(f):
    return struct.unpack('>I', struct.pack('>f', f))[0]
def single(f):
    try:
        return struct.unpack('>f', struct.pack('>f', f))[0]
    except OverflowError:
        return math.copysign(float('inf'), f)
def rnd():
    k = random.random()
    if k < 0.1: return float(random.randint(-20, 20))
    if k < 0.2: return single(random.uniform(-1, 1) * 10.0 ** random.randint(-30, 30))
    if k < 0.5: return single(random.uniform(-1000, 1000))
    return single(random.uniform(-2, 2))
rows = []; expect = []
def add(op, a, b, r):
    rows.append('        dc.l %d,$%08x,$%08x' % (op, a, b)); expect.append('%08X' % (r & 0xffffffff))
def res(x):
    x = single(x)
    if x != 0 and abs(x) < 1.17549435e-38: return 0      # no denormals
    if x == 0: return None                                # sign of zero: checked apart
    return bits(x)
for n in range(3000):
    a = rnd(); b = rnd()
    for op, f in ((0, lambda: a + b), (1, lambda: a - b), (2, lambda: a * b), (3, lambda: a / b if b != 0 else None)):
        if op == 3 and b == 0: continue
        if a == 0 or b == 0:
            continue
        r = res(f())
        if r is None: continue
        if r == 0 and op in (2, 3): add(op, bits(a), bits(b), 0); continue
        if r == 0: continue
        add(op, bits(a), bits(b), r)
    add(4, bits(a), bits(b), (a > b) - (a < b))
    if a >= 0: add(7, bits(a), 0, 0x12345678)   # sqrt: compared apart
for n in range(600):
    v = random.choice([0, 1, -1, 2**31 - 1, -2**31, random.randint(-2**31, 2**31 - 1), random.randint(-100000, 100000), random.randint(-2**25, 2**25)])
    add(5, v & 0xffffffff, 0, bits(float(v)) if v != 0 else 0)
    f = single(random.uniform(-1, 1) * 10.0 ** random.randint(-3, 9))
    t = int(f)
    if -2**31 <= t < 2**31: add(6, bits(f), 0, t)

def make(directory):
    open(directory + '/table.s', 'w').write('\n'.join(rows) + '\n')
    open(directory + '/expect.txt', 'w').write('\n'.join(expect) + '\n')
    open(directory + '/rows.txt', 'w').write('\n'.join(rows) + '\n')

def value(text):
    return struct.unpack('>f', struct.pack('>I', int(text, 16)))[0]

def check(directory, output):
    table = [line.split() for line in open(directory + '/rows.txt')]
    want = open(directory + '/expect.txt').read().split()
    got = open(output).read().split()
    names = ['add', 'subtract', 'multiply', 'divide', 'compare', 'long to float', 'float to long', 'square root']
    bad = [0] * 8
    total = [0] * 8
    if len(got) != len(want):
        print('%d results, %d expected' % (len(got), len(want)))
        return 1
    for row, g, w in zip(table, got, want):
        op, a, b = row[1].split(',')
        op = int(op)
        total[op] += 1
        if op == 7:
            root = struct.unpack('>I', struct.pack('>f', math.sqrt(value(a[1:]))))[0]
            if abs(int(g, 16) - root) > 1:
                bad[op] += 1
        elif g != w:
            bad[op] += 1
            if sum(bad) < 10:
                print('%s of %s and %s: %s, not %s' % (names[op], a, b, g, w))
    print(', '.join('%s %d of %d' % (names[k], total[k] - bad[k], total[k]) for k in range(8)))
    return 1 if sum(bad) else 0

if sys.argv[1] == 'make':
    make(sys.argv[2])
else:
    sys.exit(check(sys.argv[2], sys.argv[3]))
