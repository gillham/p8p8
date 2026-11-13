; A call with two results, a value and a flag: pos, found = strings.find(...).
; (On the 6502 the position comes back in A and "found" in the carry; p8p8 once
; never made the carry into the value.)  And updates of a variable from itself:
; v = (v << 1) ^ k, v <<= 1, v = v + a - b.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%import strings
%zeropage basicsafe

main {
    sub start() {
        str text = "the quick brown fox"
        ubyte pos
        bool found
        uword total = 0
        ubyte c
        for c in "qxzf " {
            pos, found = strings.find(text, c)
            if found
                total += pos
            else
                total += 100
        }
        txt.print_uw(total)
        txt.chrout(' ')
        pos, found = strings.find(text, 't')
        txt.print_ub(pos)
        txt.chrout(' ')
        txt.print_bool(found)
        txt.chrout(' ')

        uword crc = $ffff
        ubyte step = 3
        repeat 20 {
            if crc & $8000 != 0
                crc = (crc << 1) ^ $1021
            else
                crc <<= 1
            crc = crc + step - 1
        }
        txt.print_uwhex(crc, true)
        txt.chrout(' ')
        ubyte b = 200
        b = (b >> 1) | 3
        b = b & $f0
        b >>= 1
        txt.print_ub(b)
        txt.nl()
    }
}
