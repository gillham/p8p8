#!/usr/bin/env python3
"""Generates src/enctables.p8: the character encoding tables of the upstream
Prog8 compiler as Prog8 arrays.

The PETSCII, screencode, ATASCII and C64 OS tables are read from the Kotlin
sources of the Prog8 compiler (the decode table of each: the Unicode code
point of every byte value); PROG8_SRC names the directory of a checkout of
https://github.com/irmen/prog8.  The ISO-8859 and CP437 tables come from Python's
codecs, which implement the same standards as the Java charsets upstream
uses.  JIS X 0201 (the 'kata' encoding) is constructed: ASCII with the yen
sign and overline, plus halfwidth katakana at $a1-$df.

Run from the repository root:  PROG8_SRC=<prog8 checkout> python3 tools/gen_enctables.py
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if not os.environ.get("PROG8_SRC"):
    sys.exit("set PROG8_SRC to a checkout of the Prog8 compiler's sources")
ENC = Path(os.environ["PROG8_SRC"]) / "codeCore/src/prog8/code/target/encodings"
OUT = ROOT / "src/enctables.p8"

UNDEFINED = 0xFFFE

KOTLIN_ESCAPES = {
    "n": 10, "r": 13, "t": 9, "b": 8, "\\": 92, "'": 39, '"': 34, "$": 36,
}

# a character literal, or the start of a line comment (which ends the scan of a line)
TOKEN = re.compile(r"'((?:\\u[0-9a-fA-F]{4})|(?:\\.)|(?:[^'\\]))'|//")


def kotlin_char(text):
    if text.startswith("\\u"):
        return int(text[2:], 16)
    if text.startswith("\\"):
        return KOTLIN_ESCAPES[text[1]]
    return ord(text)


def char_array(path, name):
    """The entries of `private val NAME = charArrayOf(...)` in a Kotlin file."""
    lines = path.read_text(encoding="utf-8").splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"\s*(private |internal )?val {name}(: CharArray)? = charArrayOf\(", line):
            start = i + 1
            break
    if start is None:
        sys.exit(f"{path}: table {name} not found")
    values = []
    for line in lines[start:]:
        if line.strip() == ")" or line.strip().startswith(")"):
            break
        for m in TOKEN.finditer(line):
            if m.group(0) == "//":
                break
            values.append(kotlin_char(m.group(1)))
    return values


def string_array(path, name):
    """The entries of `private val NAME = arrayOf("..", ..)`: a list of strings."""
    text = path.read_text(encoding="utf-8")
    m = re.search(rf"val {name} = arrayOf\((.*?)\n\s*\)", text, re.S)
    if not m:
        sys.exit(f"{path}: table {name} not found")
    return re.findall(r'"([^"]*)"', m.group(1))


def codec_table(codec, first, last):
    values = []
    for b in range(first, last + 1):
        try:
            values.append(ord(bytes([b]).decode(codec)))
        except UnicodeDecodeError:
            values.append(UNDEFINED)
    return values


def emit_uword(out, name, values, comment):
    out.append(f"    ; {comment}")
    out.append(f"    uword[{len(values)}] {name} = [")
    for i in range(0, len(values), 16):
        chunk = ", ".join(f"${v:04x}" for v in values[i:i + 16])
        comma = "," if i + 16 < len(values) else ""
        out.append(f"        {chunk}{comma}")
    out.append("    ]")
    out.append("")


def main():
    petscii = ENC / "PetsciiEncoding.kt"
    tables = [
        ("petscii_lower", char_array(petscii, "decodingPetsciiLowercase"),
         "PETSCII, lowercase character set: code point for each byte"),
        ("petscii_upper", char_array(petscii, "decodingPetsciiUppercase"),
         "PETSCII, uppercase character set"),
        ("screencode_lower", char_array(petscii, "decodingScreencodeLowercase"),
         "screencodes, lowercase character set"),
        ("screencode_upper", char_array(petscii, "decodingScreencodeUppercase"),
         "screencodes, uppercase character set"),
        ("atascii", char_array(ENC / "AtasciiEncoding.kt", "decodeTable"),
         "ATASCII"),
        ("c64os", char_array(ENC / "C64osEncoding.kt", "decodingC64os"),
         "C64 OS screencodes"),
        ("cp437", codec_table("cp437", 0, 255),
         "IBM code page 437"),
        ("iso15", codec_table("iso8859_15", 128, 255),
         "ISO-8859-15 (Latin-9), bytes $80-$ff; $00-$7f are ASCII"),
        ("iso5", codec_table("iso8859_5", 128, 255),
         "ISO-8859-5 (Cyrillic), bytes $80-$ff"),
        ("iso16", codec_table("iso8859_16", 128, 255),
         "ISO-8859-16 (South-Eastern European), bytes $80-$ff"),
    ]
    for name, values, _ in tables:
        expected = 128 if name.startswith("iso") else 256
        if len(values) != expected:
            sys.exit(f"table {name} has {len(values)} entries, expected {expected}")

    # JIS X 0201 upper half: halfwidth katakana at $a1-$df, the rest undefined
    jis = [UNDEFINED] * 128
    for b in range(0xA1, 0xE0):
        jis[b - 0x80] = 0xFF61 + (b - 0xA1)
    tables.append(("jis", jis, "JIS X 0201, bytes $80-$ff; $00-$7f are ASCII except $5c yen and $7e overline"))

    kata = ENC / "KatakanaEncoding.kt"
    zenkaku = char_array(kata, "ZENKAKU_KATAKANA")
    hiragana = char_array(kata, "HANKAKU_HIRAGANA")
    hankaku = string_array(kata, "HANKAKU_KATAKANA")
    if not (len(zenkaku) == len(hiragana) == len(hankaku)):
        sys.exit(f"katakana tables differ in length: {len(zenkaku)} {len(hiragana)} {len(hankaku)}")
    hankaku1 = [ord(s[0]) for s in hankaku]
    hankaku2 = [ord(s[1]) if len(s) > 1 else 0 for s in hankaku]
    if any(len(s) > 2 for s in hankaku):
        sys.exit("a halfwidth katakana entry has more than two characters")

    out = [
        "; Character encoding tables, generated by tools/gen_enctables.py from",
        "; the upstream compiler's tables.  Do not edit by hand.",
        ";",
        "; Each table gives the Unicode code point that a byte value decodes to;",
        "; $fffe marks an undefined byte.  Encoding searches a table from the end",
        "; so that, as upstream, the last byte decoding to a character wins.",
        "",
        "enctables {",
        "    %option ignore_unused",
        "",
    ]
    for name, values, comment in tables:
        emit_uword(out, name, values, comment)
    emit_uword(out, "kata_zenkaku", zenkaku, "fullwidth katakana, converted to halfwidth before 'kata' encoding")
    emit_uword(out, "kata_hiragana", hiragana, "hiragana, converted to the fullwidth katakana at the same index")
    emit_uword(out, "kata_hankaku", hankaku1, "the halfwidth katakana for each fullwidth one")
    emit_uword(out, "kata_hankaku2", hankaku2, "its second character (a sound mark), or 0")
    out.append("}")
    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    total = sum(len(v) for _, v, _ in tables) + 4 * len(zenkaku)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(tables) + 4} tables, {total} entries, {total * 2} bytes")


if __name__ == "__main__":
    main()
