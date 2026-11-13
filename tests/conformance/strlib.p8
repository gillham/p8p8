; Conformance: the string and conversion modules of the library: the functions a program
; uses to measure, compare, copy, search and change strings and to print numbers.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.
; (At most 24 lines of 40 characters: the C64 comparison is of one screen.)

%import textio
%import strings
%import conv
%zeropage basicsafe

main {
    ubyte col

    sub item(ubyte width) {
        col += width
        if col >= 36 {
            txt.nl()
            col = 0
        }
        else
            txt.spc()
    }

    sub u(uword v) {
        txt.print_uw(v)
        item(6)
    }

    sub s(word v) {
        txt.print_w(v)
        item(7)
    }

    ; a truth value as one letter, six to a group
    sub t(bool v) {
        if v
            txt.chrout('y')
        else
            txt.chrout('n')
        col++
        if col % 6 == 0
            item(1)
    }

    sub line() {
        if col != 0
            txt.nl()
        col = 0
    }


    str buffer = "?" * 30
    str name = "Commander"
    str other = "commodore"

    sub show(str text) {
        txt.print(text)
        item(13)
    }

    sub measuring() {
        u(strings.length(name))
        u(strings.length(""))
        s(strings.compare(name, other))
        s(strings.compare(other, name))
        s(strings.compare(name, "Commander"))
        t(strings.startswith(name, "Comm"))
        t(strings.startswith(name, "comm"))
        t(strings.endswith(name, "der"))
        t(strings.endswith(name, "dor"))
        u(strings.hash(name))
    }

    sub copying() {
        u(strings.copy(name, buffer))
        show(buffer)
        u(strings.ncopy(other, buffer, 4))
        show(buffer)
        u(strings.append(buffer, name))
        show(buffer)
        u(strings.nappend(buffer, other, 2))
        show(buffer)
        strings.left(name, 3, buffer)
        show(buffer)
        strings.right(name, 3, buffer)
        show(buffer)
        strings.slice(name, 2, 4, buffer)
        show(buffer)
    }

    sub searching(ubyte c) {
        ubyte index
        bool found
        index, found = strings.find(name, c)
        u(index)
        t(found)
        index, found = strings.rfind(name, c)
        u(index)
        t(found)
        index, found = strings.find(name, 'z')
        t(found)
        t(strings.contains(name, c))
        t(strings.contains(name, 'q'))
        t(strings.isdigit('7'))
        t(strings.isdigit(c))
        t(strings.isletter(c))
        t(strings.isspace(' '))
        t(strings.isxdigit('f'))
    }

    sub changing() {
        void strings.copy("  Mixed Case  ", buffer)
        strings.strip(buffer)
        show(buffer)
        u(strings.lower(buffer))
        show(buffer)
        u(strings.upper(buffer))
        show(buffer)
        u(strings.lowerchar('Q'))
        u(strings.upperchar('q'))
    }

    sub numbers(ubyte b, uword w, word sw) {
        show(conv.str_ub(b))
        show(conv.str_ub0(b))
        show(conv.str_b(-(b as byte)))
        show(conv.str_uw(w))
        show(conv.str_uw0(w))
        show(conv.str_w(sw))
        show(conv.str_ubhex(b))
        show(conv.str_uwhex(w))
        show(conv.str_ubbin(b))
        show(conv.str_l(-1234567))
        u(conv.str2ubyte("123"))
        u(conv.str2uword("54321x"))
        s(conv.str2word("-4321"))
        s(conv.str2byte("-99"))
        u(conv.hex2uword("a1f"))
        u(conv.bin2uword("10110"))
        txt.print_ubhex(b, true)
        item(6)
        txt.print_uwhex(w, false)
        item(6)
        txt.print_ubbin(b, false)
        item(10)
        txt.print_b(-(b as byte))
        item(6)
        txt.print_ub0(b)
        item(6)
        txt.print_uw0(w)
        item(6)
        txt.print_bool(b > 5)
        item(6)
    }

    sub start() {
        measuring()
        line()
        copying()
        line()
        searching('m')
        line()
        changing()
        line()
        numbers(77, 4660, -2001)
        txt.nl()
    }
}
