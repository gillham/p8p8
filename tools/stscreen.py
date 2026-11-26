#!/usr/bin/env python3
"""The text of an Atari ST screen, from a dump of its 32000 bytes of screen memory.

The ST's screen is a picture: the console draws the characters and keeps no text.
So the program that is looked at prints the characters 32 to 126 itself, in the
screen's last rows (as many as their 95 need), and this reads the pictures of the
characters from there and finds them again in the rows above.

Usage: stscreen.py <dump> <mode>    (mode: 0 low, 1 medium, 2 high resolution)

Prints the rows above the characters' rows, without the empty ones at their end, and
after them a line for every run of characters that is not in the usual colours (the
mode's last colour on colour 0): row, first column, length, text colour, background.
A place whose picture is none of the characters' is a '?'.
"""
import sys

def main():
    data = open(sys.argv[1], 'rb').read()
    mode = int(sys.argv[2])
    planes = (4, 2, 1)[mode]
    width = (320, 640, 640)[mode]
    cell_h = (8, 8, 16)[mode]
    cols = width // 8
    rows = 25
    words_per_line = width // 16 * planes

    def pixel(x, y):
        at = (y * words_per_line + (x // 16) * planes) * 2
        bit = 15 - (x & 15)
        value = 0
        for p in range(planes):
            word = (data[at + p * 2] << 8) | data[at + p * 2 + 1]
            value |= ((word >> bit) & 1) << p
        return value

    def cell(col, row):
        return tuple(pixel(col * 8 + x, row * cell_h + y) for y in range(cell_h) for x in range(8))

    def shape(pixels, background):
        return tuple(p != background for p in pixels)

    usual_text = (1 << planes) - 1
    # the characters' own rows: 95 of them from the left of the first of the last rows
    legend_rows = -(-95 // cols)
    first = rows - legend_rows
    font = {}
    for k in range(95):
        font.setdefault(shape(cell(k % cols, first + k // cols), 0), chr(32 + k))
    lines = []
    runs = []
    for row in range(first):
        text = ''
        run = None
        for col in range(cols):
            pixels = cell(col, row)
            colours = sorted(set(pixels))
            found = '?'
            pair = (usual_text, 0)
            if len(colours) == 1:
                found = ' '
                pair = (usual_text, colours[0])
            elif len(colours) == 2:
                for text_colour, background in ((colours[0], colours[1]), (colours[1], colours[0])):
                    char = font.get(shape(pixels, background))
                    if char is not None:
                        found = char
                        pair = (text_colour, background)
                        if background == 0:
                            break
            if found == ' ':
                # (a blank has no text colour of its own: that of the run it is in)
                if pair[1] == 0:
                    pair = (usual_text, 0)
                elif run is not None and run[3][1] == pair[1] and run[1] + run[2] == col:
                    pair = run[3]
            text += found
            if pair != (usual_text, 0):
                if run is not None and run[3] == pair and run[1] + run[2] == col:
                    run[2] += 1
                else:
                    run = [row, col, 1, pair]
                    runs.append(run)
        lines.append(text.rstrip())
    while lines and lines[-1] == '':
        lines.pop()
    for line in lines:
        print(line)
    for row, col, length, pair in runs:
        print('colours: row %d column %d length %d: %d on %d' % (row, col, length, pair[0], pair[1]))

main()
