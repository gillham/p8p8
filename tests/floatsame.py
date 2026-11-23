#!/usr/bin/env python3
# Are two outputs the same but for how their floats are written?  A machine whose floats
# are its ROM's (the Color Computer) prints them as its BASIC does: ".5" for 0.5, "3" for
# 3.0, about nine digits.  Word by word: two words that are numbers are the same when
# they agree to seven digits (or both are within 2e-7 of each other), any other two when
# they are equal.  The exit status is 0 when the outputs are the same in this sense.
#
# Usage: tests/floatsame.py <the host's output> <the machine's output>
import re
import sys

def words(path):
    text = open(path, 'rb').read().decode('latin-1')
    # (a number may stand against a letter or a sign: split there too)
    return re.findall(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?|[^\s\d.+-]+|[-+.]', text)

def number(word):
    try:
        return float(word)
    except ValueError:
        return None

a = words(sys.argv[1])
b = words(sys.argv[2])
if len(a) != len(b):
    sys.exit(1)
for x, y in zip(a, b):
    if x == y:
        continue
    p, q = number(x), number(y)
    if p is None or q is None:
        sys.exit(1)
    if abs(p - q) > 2e-7 and abs(p - q) > 1e-7 * max(abs(p), abs(q)):
        sys.exit(1)
sys.exit(0)
