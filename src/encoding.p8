; String and character literal decoding.  The raw text between the quotes
; has its escape sequences resolved and is read as UTF-8 into code points,
; which are then encoded to bytes in the literal's encoding: its prefix
; (iso:"..."), else the module's %encoding directive, else the target's
; default.  The rules follow upstream exactly, oddities included: PETSCII
; and screencodes try the lowercase character set first and then the
; uppercase one; a character that the ISO, CP437 and kata encodings do not
; have becomes '?' silently (Java's charset encoder does that), while the
; table based encodings report an error; "\xHH" always gives the byte HH.
;
; A decoded string literal node gets extra = the bytes (zero terminated)
; and value = their count; a character literal gets value = the byte and
; extra = 1 as the marker that it was decoded.

%import ast
%import mem
%import buf
%import out
%import strings
%import enctables
%import target

encoding {
    %option ignore_unused

    const ubyte E_DEFAULT = 0
    const ubyte E_PETSCII = 1
    const ubyte E_SC = 2
    const ubyte E_ATASCII = 3
    const ubyte E_ISO = 4
    const ubyte E_ISO5 = 5
    const ubyte E_ISO16 = 6
    const ubyte E_CP437 = 7
    const ubyte E_KATA = 8
    const ubyte E_C64OS = 9
    const ubyte E_COUNT = 10
    const ubyte E_INVALID = 255

    str[] names = ["default", "petscii", "sc", "atascii", "iso", "iso5", "iso16", "cp437", "kata", "c64os"]

    ; set by set_target()
    ubyte target_default = E_ISO
    bool newline_to_cr = false

    ; the %encoding of each source file by file index, E_DEFAULT when none
    ubyte[256] file_default

    ; statistics
    long count_strings = 0
    long count_bytes = 0
    long count_chars = 0

    ; the code points of the literal being decoded, then its bytes
    ^^uword cps = 0
    long cps_cap = 0
    long cps_count = 0
    ^^ubyte bytes = 0
    long bytes_cap = 0

    ^^buf.Buf msg = 0       ; error message text when it has to be built

    const uword NONE = $ffff

    ; the special characters of CP437 that the Java charset does not encode: byte 1..31
    uword[] cp437_specials = [
        $263a, $263b, $2665, $2666, $2663, $2660, $2022, $25d8, $25cb, $25d9, $2642, $2640, $266a, $266b, $263c,
        $25ba, $25c4, $2195, $203c, $00b6, $00a7, $25ac, $21a8, $2191, $2193, $2192, $2190, $221f, $2194, $25b2, $25bc
    ]
    ; the special characters of the kata encoding and their bytes
    uword[] kata_specials = [
        $2665, $2666, $2663, $2660, $5927, $4e2d, $5c0f, $767e, $5343, $4e07, $266a, $571f, $91d1,
        $6728, $6c34, $706b, $6708, $65e5, $6642, $5206, $79d2, $5e74, $5186, $4eba, $751f, $3012
    ]
    ubyte[] kata_special_bytes = [
        $e3, $e4, $e5, $e6, $ea, $eb, $ec, $ed, $ee, $ef, $f0, $f1, $f2,
        $f3, $f4, $f5, $f6, $f7, $f8, $f9, $fa, $fb, $fc, $fd, $fe, $ff
    ]

    ; Sets the default encoding and the newline convention for a target name.
    sub set_target(^^ubyte name) {
        target_default = E_ISO
        newline_to_cr = true
        if target.loaded and not target.z80() and not target.m6809() {
            ; a machine with a configuration file says it itself
            ^^ubyte en = target.text("encoding")
            if en != 0 {
                ubyte found = from_name(en)
                if found != E_INVALID and found != E_DEFAULT
                    target_default = found
            }
            return
        }
        if strings.compare(name, "c64") == 0 or strings.compare(name, "c128") == 0
            or strings.compare(name, "cx16") == 0 or strings.compare(name, "pet32") == 0
            target_default = E_PETSCII
        else if strings.compare(name, "atari") == 0
            target_default = E_ATASCII
        else if strings.compare(name, "llvm64") == 0 or strings.compare(name, "llvm32") == 0
            or strings.compare(name, "llvm16") == 0 or strings.compare(name, "virtual") == 0
            or strings.compare(name, "amiga500") == 0 or strings.compare(name, "amiga1200") == 0
            or strings.compare(name, "qemu68k") == 0 or strings.compare(name, "atarist") == 0 or strings.compare(name, "macplus") == 0
            newline_to_cr = false
    }

    ; The encoding number for a prefix or directive name, or E_INVALID.
    sub from_name(^^ubyte name) -> ubyte {
        ubyte i
        for i in 0 to E_COUNT - 1 {
            if strings.compare(name, names[i]) == 0
                return i
        }
        return E_INVALID
    }

    ; Decodes a string or character literal node.  Returns 0 when it worked,
    ; else the error message; the node is left undecoded then.
    sub decode(^^ast.Node n) -> ^^ubyte {
        ubyte enc = file_default[n.file]
        if n.a != 0 {
            enc = from_name(n.a.name)
            if enc == E_INVALID
                return "invalid encoding"
        }
        if enc == E_DEFAULT
            enc = target_default
        ^^ubyte err = unescape(n.name)
        if err != 0
            return err
        ; a kata character may become two bytes
        long needed = cps_count * 2 + 1
        if needed > bytes_cap {
            bytes = mem.grow(bytes, bytes_cap, needed)
            bytes_cap = needed
        }
        long count = 0
        long i = 0
        uword cp
        uword b
        while i < cps_count {
            cp = cps[i]
            if enc == E_KATA {
                uword second = 0
                cp, second = kata_halfwidth(cp)
                if second != 0 {
                    b = encode_char(cp, enc)
                    if b == NONE
                        return cannot_encode(cp, enc)
                    bytes[count] = b as ubyte
                    count++
                    cp = second
                }
            }
            b = encode_char(cp, enc)
            if b == NONE
                return cannot_encode(cp, enc)
            bytes[count] = b as ubyte
            count++
            i++
        }
        if n.kind == ast.N_CHAR {
            if count > 1
                return "character literal encodes into multiple bytes"
            n.value = 0
            if count == 1
                n.value = bytes[0]
            n.extra = 1
            count_chars++
            return 0
        }
        ^^ubyte text = mem.alloc(count + 1)
        mem.copy(bytes, text, count)
        n.extra = text
        n.value = count
        count_strings++
        count_bytes += count
        return 0
    }

    ; Resolves the escape sequences of the raw text and reads it as UTF-8
    ; into cps.  Returns 0 or an error message.
    sub unescape(^^ubyte text) -> ^^ubyte {
        cps_count = 0
        long i = 0
        uword cp
        ubyte c
        ubyte digits
        while text[i] != 0 {
            c = text[i]
            i++
            if c == '\\' {
                c = text[i]
                i++
                when c {
                    '\\' -> cp = '\\'
                    'n' -> cp = 10
                    'r' -> cp = 13
                    't' -> cp = 9
                    '"' -> cp = '"'
                    '\'' -> cp = '\''
                    'u' -> {
                        digits = 4
                        cp = hex_digits(text, i, digits)
                        if cp == NONE
                            return "invalid \\u escape sequence"
                        i += 4
                    }
                    'x' -> {
                        digits = 2
                        cp = hex_digits(text, i, digits)
                        if cp == NONE
                            return "invalid \\x escape sequence"
                        cp += $8000       ; passed through to the byte value by every encoding
                        i += 2
                    }
                    else -> {
                        start_message()
                        buf.add_str(msg, "invalid escape char in string: \\")
                        buf.add_byte(msg, c)
                        return finish_message()
                    }
                }
            }
            else if c < $80
                cp = c
            else if c >= $c0 and c < $e0 {
                cp = ((c & $1f) as uword) << 6
                c = text[i]
                if c < $80 or c >= $c0
                    return "invalid UTF-8 in literal"
                i++
                cp |= c & $3f
            }
            else if c >= $e0 and c < $f0 {
                cp = ((c & $0f) as uword) << 12
                c = text[i]
                if c < $80 or c >= $c0
                    return "invalid UTF-8 in literal"
                i++
                cp |= ((c & $3f) as uword) << 6
                c = text[i]
                if c < $80 or c >= $c0
                    return "invalid UTF-8 in literal"
                i++
                cp |= c & $3f
            }
            else if c >= $f0 and c < $f8
                return "character outside the basic multilingual plane in literal"
            else
                return "invalid UTF-8 in literal"
            add_cp(cp)
        }
        return 0
    }

    sub add_cp(uword cp) {
        if cps_count >= cps_cap {
            long newcap = cps_cap * 2
            if newcap < 64
                newcap = 64
            cps = mem.grow(cps, cps_cap * 2, newcap * 2)
            cps_cap = newcap
        }
        cps[cps_count] = cp
        cps_count++
    }

    ; The value of `count` hex digits at text[i], or NONE.
    sub hex_digits(^^ubyte text, long i, ubyte count) -> uword {
        uword value = 0
        repeat count {
            ubyte c = text[i]
            ubyte d
            if c >= '0' and c <= '9'
                d = c - '0'
            else if c >= 'a' and c <= 'f'
                d = c - 'a' + 10
            else if c >= 'A' and c <= 'F'
                d = c - 'A' + 10
            else
                return NONE
            value = (value << 4) | d
            i++
        }
        return value
    }

    ; Converts hiragana and fullwidth katakana to halfwidth katakana, as the
    ; kata encoding does; the second code point is a sound mark or 0.
    sub kata_halfwidth(uword cp) -> uword, uword {
        uword i = find(&enctables.kata_hiragana, len(enctables.kata_hiragana), cp)
        if i != NONE
            cp = enctables.kata_zenkaku[i]
        i = find(&enctables.kata_zenkaku, len(enctables.kata_zenkaku), cp)
        if i == NONE
            return cp, 0
        return enctables.kata_hankaku[i], enctables.kata_hankaku2[i]
    }

    ; The byte for a code point in an encoding, or NONE.
    sub encode_char(uword cp, ubyte enc) -> uword {
        when enc {
            E_PETSCII -> return cbm_char(cp, &enctables.petscii_lower, &enctables.petscii_upper, false)
            E_SC -> return cbm_char(cp, &enctables.screencode_lower, &enctables.screencode_upper, true)
            E_ISO -> return iso_char(cp, &enctables.iso15)
            E_ISO5 -> return iso_char(cp, &enctables.iso5)
            E_ISO16 -> return iso_char(cp, &enctables.iso16)
            E_CP437 -> return cp437_char(cp)
            E_KATA -> return kata_char(cp)
            E_ATASCII -> return atascii_char(cp)
            E_C64OS -> return c64os_char(cp)
        }
        return NONE
    }

    ; The last index in a table holding the code point, or NONE: as upstream,
    ; the last byte that decodes to a character is the one it encodes to.
    sub find(^^uword table, uword length, uword cp) -> uword {
        uword i = length
        while i != 0 {
            i--
            if table[i] == cp
                return i
        }
        return NONE
    }

    ; The byte for the pass-through range of "\xHH", or NONE.
    sub passthrough(uword cp) -> uword {
        if cp >= $8000 and cp <= $80ff
            return cp - $8000
        return NONE
    }

    ; PETSCII and screencodes: some ASCII punctuation is drawn with similar
    ; looking graphics characters, and lowercase is tried before uppercase.
    sub cbm_char(uword cp, ^^uword lower, ^^uword upper, bool screencodes) -> uword {
        when cp {
            '^' -> cp = $2191       ; upwards arrow
            '_' -> cp = $2581       ; lower one eighth block
            '{' -> cp = $2524       ; box drawings light vertical and left
            '}' -> cp = $251c       ; box drawings light vertical and right
            '|' -> cp = $2502       ; box drawings light vertical
            '\\' -> cp = $2572      ; box drawings light diagonal upper left to lower right
            13 -> cp = 10
        }
        uword b = find(lower, 256, cp)
        if b == NONE
            b = find(upper, 256, cp)
        if b != NONE
            return b
        if cp == 0
            return 0
        if screencodes and cp == 10
            return 141
        return passthrough(cp)
    }

    sub iso_char(uword cp, ^^uword upper) -> uword {
        if cp == 0
            return 0
        if cp == 10 {
            if newline_to_cr
                return 13
            return 10
        }
        uword b = passthrough(cp)
        if b != NONE
            return b
        if cp < $80
            return cp
        b = find(upper, 128, cp)
        if b != NONE
            return $80 + b
        return '?'
    }

    sub cp437_char(uword cp) -> uword {
        if cp == 0
            return 0
        if cp == $a0
            return $ff
        uword b = find(&cp437_specials, len(cp437_specials), cp)
        if b != NONE
            return b + 1
        b = passthrough(cp)
        if b != NONE
            return b
        b = find(&enctables.cp437, 256, cp)
        if b != NONE
            return b
        return '?'
    }

    ; JIS X 0201: ASCII except that $5c is the yen sign and $7e the overline
    ; (the Java charset also encodes the ASCII backslash and tilde to them),
    ; and halfwidth katakana at $a1-$df.
    sub kata_char(uword cp) -> uword {
        if cp == 10 {
            if newline_to_cr
                return 13
            return 10
        }
        if cp == 0
            return 0
        if cp == $a0
            return $a0
        uword b = find(&kata_specials, len(kata_specials), cp)
        if b != NONE
            return kata_special_bytes[b]
        b = passthrough(cp)
        if b != NONE
            return b
        if cp == $a5
            return $5c
        if cp == $203e
            return $7e
        if cp < $80
            return cp
        b = find(&enctables.jis, 128, cp)
        if b != NONE
            return $80 + b
        return '?'
    }

    sub atascii_char(uword cp) -> uword {
        if cp == 13
            return $9b
        if cp == 0
            return 0
        uword b = passthrough(cp)
        if b != NONE
            return b
        return find(&enctables.atascii, 256, cp)
    }

    sub c64os_char(uword cp) -> uword {
        if cp == 13
            cp = 10
        uword b = find(&enctables.c64os, 256, cp)
        if b != NONE
            return b
        if cp == 0
            return 0
        if cp == 10
            return 13
        return passthrough(cp)
    }

    ; "no <encoding> character for char #<code point>"
    sub cannot_encode(uword cp, ubyte enc) -> ^^ubyte {
        start_message()
        buf.add_str(msg, "no ")
        buf.add_str(msg, names[enc])
        buf.add_str(msg, " character for char #")
        buf.add_long(msg, cp)
        return finish_message()
    }

    sub start_message() {
        if msg == 0
            msg = buf.new(80)
        buf.clear(msg)
    }

    sub finish_message() -> ^^ubyte {
        buf.add_byte(msg, 0)
        return msg.data
    }

    sub stats() {
        out.puts("literals: ")
        out.putl(count_strings)
        out.puts(" strings, ")
        out.putl(count_bytes)
        out.puts(" bytes, ")
        out.putl(count_chars)
        out.puts(" chars")
        out.nl()
    }
}
