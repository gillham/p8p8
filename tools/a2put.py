#!/usr/bin/env python3
"""Put a file on a DOS 3.3 disk image, as a B (binary) file.

    a2put.py IMAGE FILE NAME

IMAGE is a 140 KB image in DOS's sector order (.do, .dsk); it is changed in place.
FILE is what the file has on the disk: for a program, the four bytes of BSAVE (its
address and length) and the program, which is what p8c writes for the appleii
target.  For tests/a2dos.sh; a file of that name must not be there yet.
"""
import sys

SECTORS = 16


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    path, source, name = sys.argv[1:]
    image = bytearray(open(path, "rb").read())
    data = open(source, "rb").read()
    if len(image) != 35 * SECTORS * 256:
        sys.exit(f"{path}: not a 140 KB disk image")

    def at(track, sector):
        return (track * SECTORS + sector) * 256

    vtoc = at(17, 0)

    def take():
        """a free sector, marked as used"""
        for track in list(range(18, 35)) + list(range(16, 2, -1)):
            for sector in range(SECTORS - 1, -1, -1):
                where = vtoc + 0x38 + 4 * track + (0 if sector >= 8 else 1)
                bit = 1 << (sector & 7)
                if image[where] & bit:
                    image[where] &= ~bit & 255
                    return track, sector
        sys.exit(f"{path}: the disk is full")

    chunks = [data[k:k + 256] for k in range(0, len(data), 256)] or [b""]
    lists = []
    first = None
    for start in range(0, len(chunks), 122):
        track, sector = take()
        if first is None:
            first = (track, sector)
        if lists:
            image[lists[-1] + 1] = track
            image[lists[-1] + 2] = sector
        here = at(track, sector)
        image[here:here + 256] = bytes(256)
        image[here + 5] = start & 255
        image[here + 6] = start >> 8
        lists.append(here)
        for k, chunk in enumerate(chunks[start:start + 122]):
            t, s = take()
            image[here + 12 + 2 * k] = t
            image[here + 13 + 2 * k] = s
            image[at(t, s):at(t, s) + 256] = chunk.ljust(256, b"\0")

    track, sector = image[vtoc + 1], image[vtoc + 2]
    while track:
        here = at(track, sector)
        for k in range(7):
            entry = here + 11 + 35 * k
            if image[entry] in (0, 255):
                image[entry] = first[0]
                image[entry + 1] = first[1]
                image[entry + 2] = 4
                image[entry + 3:entry + 33] = bytes((ord(c) | 128) for c in name.upper().ljust(30)[:30])
                total = len(chunks) + len(lists)
                image[entry + 33] = total & 255
                image[entry + 34] = total >> 8
                open(path, "wb").write(image)
                return
        track, sector = image[here + 1], image[here + 2]
    sys.exit(f"{path}: the catalog is full")


if __name__ == "__main__":
    main()
