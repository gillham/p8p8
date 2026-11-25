#!/usr/bin/env python3
"""Print an Atari text screen (40 x 24 screen codes, as the atari800 monitor's
WRITE dumps them) as lines of text.  Inverse characters are shown as the plain ones
unless -i is given, which puts them in brackets: [x].

usage: atscreen.py [-i] screen.dat"""
import sys

args = sys.argv[1:]
inverse = False
if args and args[0] == '-i':
    inverse = True
    args = args[1:]
data = open(args[0], 'rb').read()
for row in range(24):
    line = ''
    for code in data[row * 40:row * 40 + 40]:
        inv = code >= 128
        code &= 127
        if code < 64:
            ch = chr(code + 32)
        elif code < 96:
            ch = '.'            # the graphics characters
        else:
            ch = chr(code)
        if not 32 <= ord(ch) < 127:
            ch = '.'
        line += '[' + ch + ']' if inv and inverse else ch
    print(line.rstrip())
