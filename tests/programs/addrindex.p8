; The address of an element behind a pointer: &pointer[i] is where the pointer
; points plus the index, not the address of the pointer variable.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
main {
    sub digits(^^ubyte t) -> bool, long {
        long v = 0
        long k = 0
        while t[k] != 0 {
            if t[k] < '0' or t[k] > '9'
                return false, 0
            v = v * 10 + (t[k] - '0')
            k++
        }
        return true, v
    }

    sub classify(^^ubyte operand) {
        bool ok
        long v
        ok, v = digits(&operand[4])
        if ok
            txt.print("ok ")
        else
            txt.print("no ")
        txt.print_l(v)
        txt.spc()
        ^^ubyte rest = &operand[2]
        txt.chrout(rest[0])
        txt.chrout(rest[1])
        txt.nl()
    }

    struct Text {
        ^^ubyte data
        uword length
    }

    ubyte[] letters = [65, 66, 67, 68, 69, 70, 71, 0]
    ubyte[16] holder

    ; the same through a field that is a pointer, with a constant and a variable index
    sub fields() {
        ^^Text t = &holder as ^^Text
        t.data = &letters
        t.length = 7
        ^^ubyte p = &t.data[2]
        txt.chrout(p[0])
        txt.chrout(p[1])
        ubyte from = 4
        p = &t.data[from]
        txt.chrout(p[0])
        txt.chrout(p[2])
        txt.nl()
    }

    sub start() {
        classify("abc+123")
        classify("xyz+7")
        fields()
    }
}
