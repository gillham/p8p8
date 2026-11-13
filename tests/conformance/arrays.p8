; Conformance: arrays of every element type and strings: how they are initialized, indexed with
; constants, variables and expressions, measured, searched, compared and copied.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.
; (At most 24 lines of 40 characters: the C64 comparison is of one screen.)

%import textio
%import strings
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


    ubyte[] bytes = [1, 2, 3, 4, 5]
    byte[] sbytes = [-1, -2, 3]
    uword[] words = [100, 2000, 30000]
    word[] swords = [-100, 100, -30000]
    long[] longs = [100000, -100000, 7]
    bool[] flags = [true, false, true]
    uword[] @nosplit linear = [$1122, $3344]
    ubyte[10] zeros
    ubyte[6] repeated = [7] * 6
    ubyte[] ramp = 10 to 14
    str greeting = "hello"
    str[] names = ["ab", "cde", "f"]

    sub lengths() {
        u(len(bytes))
        u(len(words))
        u(len(zeros))
        u(len(repeated))
        u(len(ramp))
        u(len(greeting))
        u(len(names))
        u(sizeof(bytes))
        u(sizeof(words))
        u(sizeof(longs))
    }

    sub reading(ubyte i) {
        u(bytes[0])
        u(bytes[i])
        u(bytes[i + 1])
        u(bytes[len(bytes) - 1])
        s(sbytes[i])
        u(words[i])
        u(words[i + 1])
        s(swords[2])
        s(swords[i - 1])
        txt.print_l(longs[i])
        item(12)
        t(flags[0])
        t(flags[i])
        u(linear[i])
        u(zeros[9])
        u(repeated[5])
        u(ramp[i + 3])
    }

    sub writing(ubyte i, ubyte v) {
        zeros[i] = v
        zeros[i + 1] = zeros[i] + 1
        zeros[9] = zeros[i] + zeros[i + 1]
        u(zeros[i])
        u(zeros[i + 1])
        u(zeros[9])
        words[i] = v * $0100 + v
        words[0] = words[i] + 1
        u(words[0])
        u(words[i])
        longs[2] = longs[0] + v
        txt.print_l(longs[2])
        item(12)
        flags[1] = flags[0] and v > 5
        t(flags[1])
        ; an element as the index of another
        u(bytes[bytes[i]])
    }

    sub membership(ubyte v, uword w) {
        t(v in bytes)
        t(v in [10, 20, 30])
        t(w in words)
        t(v in 3 to 5)
        t(v not in bytes)
        t(v in "hxl")
    }

    sub strings(ubyte i) {
        u(greeting[0])
        u(greeting[i])
        u(greeting[len(greeting) - 1])
        txt.print(greeting)
        item(6)
        txt.print(names[i])
        item(6)
        txt.print(names[0])
        item(6)
        str copy = "?????"
        void strings.copy(greeting, copy)
        copy[0] = 'j'
        txt.print(copy)
        item(6)
        txt.print(greeting)
        item(6)
        ; escapes and a character as a number
        str special = "a\x41\\b"
        u(special[1])
        u(special[2])
        u('z' - 'a')
        t(greeting == "hello")
        t(greeting == copy)
        t(greeting < copy)
    }

    sub start() {
        lengths()
        line()
        reading(1)
        line()
        writing(2, 9)
        line()
        membership(4, 2313)
        membership(20, 100)
        membership(108, 5)
        line()
        strings(1)
        txt.nl()
    }
}
