#!/usr/bin/env python3
"""Compares two recordings of an emulator's video (x16emu -gif) of the same program
built by two compilers.

The two builds run at different speeds, so the recordings are not compared frame by
frame.  Two things can be compared:

- the final picture, when both recordings end on a picture that no longer changes
  (a program that draws something and stops, or waits for a key);
- the sequence of distinct pictures, when the program shows whole frames one after the
  other (an animation locked to the vertical blank): the sequences are the same, one
  is just further along than the other.

Prints one line: "same picture", "same frames (N)", "different picture", "cannot
tell (...)" or "nothing drawn".  Only "different picture" is a finding: two builds of
different speed show different frames of a program that draws at its own pace, without
anything being wrong.  The exit status is 0 for the same, 1 for a different picture, 2
when the recordings cannot be compared.

Usage: python3 tools/gifcmp.py <reference.gif> <other.gif> [settled frames, default 300]
"""
import hashlib
import sys

from PIL import Image, ImageChops, ImageFile

# (a recording ends when the emulator is stopped: its last frame may be cut off)
ImageFile.LOAD_TRUNCATED_IMAGES = True


def frames(path):
    """The hash of every frame's pixels."""
    out = []
    with Image.open(path) as im:
        n = getattr(im, 'n_frames', 1)
        for i in range(n):
            try:
                im.seek(i)
                out.append(hashlib.md5(im.convert('RGB').tobytes()).hexdigest())
            except (OSError, EOFError):
                break
    return out


def last_frame(path, count):
    with Image.open(path) as im:
        im.seek(max(0, count - 2))
        return im.convert('RGB')


def only_load_line(path_a, count_a, path_b, count_b):
    """Do the final pictures differ in nothing but the "LOADING FROM $0801 TO $xxxx"
    line that the emulator's autostart leaves near the top of a text screen?  It shows
    the end address of the program, which is not the same for two compilers."""
    a = last_frame(path_a, count_a)
    b = last_frame(path_b, count_b)
    if a.size != b.size:
        return False
    box = ImageChops.difference(a, b).getbbox()
    if box is None:
        return True
    left, top, right, bottom = box
    return bottom - top <= 16 and bottom <= a.size[1] // 2 and right - left <= 80


def distinct(seq):
    out = []
    for f in seq:
        if not out or out[-1] != f:
            out.append(f)
    return out


def settled(seq, need):
    return len(seq) >= need and len(set(seq[-need:])) == 1


def main():
    need = int(sys.argv[3]) if len(sys.argv) > 3 else 300
    a = frames(sys.argv[1])
    b = frames(sys.argv[2])
    da, db = distinct(a), distinct(b)
    if len(da) <= 1 and len(db) <= 1:
        print('nothing drawn')
        return 2
    if settled(a, need) and settled(b, need):
        if a[-1] == b[-1]:
            print('same picture')
            return 0
        if only_load_line(sys.argv[1], len(a), sys.argv[2], len(b)):
            print('same picture (but for the load address)')
            return 0
        print('different picture')
        return 1
    if settled(a, need) != settled(b, need):
        print('cannot tell (one of the two is still drawing)')
        return 2
    # an animation: compare the distinct frames they share
    n = min(len(da), len(db))
    for i in range(n):
        if da[i] != db[i]:
            print('cannot tell (the frames differ from number %d: not locked to the frame?)' % (i + 1))
            return 2
    print('same frames (%d)' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main())
