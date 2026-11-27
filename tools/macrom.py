#!/usr/bin/env python3
"""The Macintosh Plus's ROM as MAME wants it.

A Mac Plus ROM is usually kept as one file of 128 KB.  MAME's macplus machine
takes the two chips that it was: the bytes at the even places and those at the
odd ones, in a directory named macplus.  This writes them.

    tools/macrom.py <rom file> <directory>

and tests/macrun.sh is given the directory as MAC_ROMS.  Only the third version
of the ROM (the one that is in nearly every machine) has the names MAME knows.
"""
import os
import sys
import zlib

NAMES = {0xf69697e6: "342-0341-c.u6d", 0x49f25913: "342-0342-b.u8d"}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rom = open(sys.argv[1], "rb").read()
    if len(rom) != 131072:
        sys.exit("not a Macintosh Plus ROM: %d bytes, not 131072" % len(rom))
    where = os.path.join(sys.argv[2], "macplus")
    os.makedirs(where, exist_ok=True)
    for half in (rom[0::2], rom[1::2]):
        name = NAMES.get(zlib.crc32(half))
        if name is None:
            sys.exit("not the third version of the Macintosh Plus's ROM: MAME does not know it")
        with open(os.path.join(where, name), "wb") as out:
            out.write(half)
    print("written to", where)


if __name__ == "__main__":
    main()
