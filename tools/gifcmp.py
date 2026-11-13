#!/usr/bin/env python3
"""Compares two recordings of an emulator's video (x16emu -gif) of the same program
built by two compilers.

The two builds run at different speeds, so the recordings are not compared frame by
frame.  Two things can be compared:

- the final picture, when both recordings end on a picture that no longer changes
  (a program that draws something and stops, or waits for a key); and with it where
  on the screen each recording ever showed something else than that final picture.
  Two builds that end on the same picture must have drawn in the same places on the
  way: one that drew nothing, where the other animated something and cleaned up
  after itself, is not the same program;
- the sequence of distinct pictures, when the program shows whole frames one after the
  other (an animation locked to the vertical blank): the sequences are the same, one
  is just further along than the other.

Prints one line: "same picture", "same frames (N)", "different picture...", "cannot
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


CELL = 8            # the screen in cells of this many pixels
MOST = 400          # distinct pictures looked at, spread over the recording


def touched(path, hashes, other):
    """The cells of the screen that ever showed something else than the final picture,
    in the pictures that only this recording has (a picture that both have, such as
    the screens of the machine starting up, says nothing about a difference)."""
    final = last_frame(path, len(hashes))
    small = (max(1, final.size[0] // CELL), max(1, final.size[1] // CELL))
    mask = Image.new('L', small, 0)
    # the first frame of each picture that is this recording's own
    wanted = []
    seen = set(other)
    for i, h in enumerate(hashes):
        if h not in seen:
            seen.add(h)
            wanted.append(i)
    if len(wanted) > MOST:
        step = len(wanted) / MOST
        wanted = [wanted[int(k * step)] for k in range(MOST)]
    with Image.open(path) as im:
        for i in wanted:
            try:
                im.seek(i)
                frame = im.convert('RGB')
            except (OSError, EOFError):
                break
            if frame.size != final.size:
                continue
            diff = ImageChops.difference(frame, final).convert('L')
            # a cell is touched when any of its pixels differs
            cells = diff.resize(small, Image.BOX).point(lambda v: 255 if v else 0)
            mask = ImageChops.lighter(mask, cells)
    return mask


def lit(mask):
    return mask.size[0] * mask.size[1] - mask.histogram()[0]


def drew_alike(path_a, a, path_b, b):
    """Did the two recordings, which end on the same picture, draw in the same places
    before that?  (The cells one touched and the other did not, against all touched.)"""
    ma = touched(path_a, a, set(b))
    mb = touched(path_b, b, set(a))
    if ma.size != mb.size:
        return True, 0, 0
    union = lit(ImageChops.lighter(ma, mb))
    apart = lit(ImageChops.difference(ma, mb))
    # Some cells differ without meaning anything: the cursor, the digits of the load
    # address, and text that scrolls by, caught at other moments in the two recordings
    # (a third of the cells in examples/queens.p8).  Half of them or more is one
    # recording drawing where the other did not.
    return apart <= max(4, union // 2), apart, union


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
        note = ''
        if a[-1] != b[-1]:
            if not only_load_line(sys.argv[1], len(a), sys.argv[2], len(b)):
                print('different picture')
                return 1
            note = ' (but for the load address)'
        alike, apart, union = drew_alike(sys.argv[1], a, sys.argv[2], b)
        if not alike:
            print('different picture (the same at the end, but %d of the %d cells that were drawn in on the way were so in one only)' % (apart, union))
            return 1
        print('same picture' + note)
        return 0
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
