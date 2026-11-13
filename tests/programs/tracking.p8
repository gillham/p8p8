; What a code generator that follows values must not get wrong: a variable that
; changes behind its back (in a subroutine, through a pointer, as an array element,
; under another name), flags that are used after a load was dropped, and results
; that are computed straight into a parameter.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

main {
    ubyte counter = 10
    uword total = 1000
    ubyte[] table = [1, 2, 3, 4, 5]

    sub bump() {
        counter += 5
        total += 300
    }

    sub poke_through(^^ubyte p, ubyte v) {
        p[0] = v
    }

    sub add3(uword a, uword b, uword c) -> uword {
        return a + b + c
    }

    sub zero() -> ubyte {
        return 0
    }

    sub show(uword v) {
        txt.print_uw(v)
        txt.chrout(' ')
    }

    sub start() {
        ; a call between two reads
        ubyte before = counter
        bump()
        show(before)
        show(counter)
        show(total)

        ; a write through a pointer between two reads
        ubyte local = 7
        ubyte first = local
        poke_through(&local, 9)
        show(first)
        show(local)

        ; an array element by constant and by variable index
        ubyte ix = 2
        ubyte e1 = table[2]
        table[ix] = 33
        show(e1)
        show(table[2])
        table[2] = 44
        show(table[ix])

        ; one location under two names
        cx16.r0 = $1234
        ubyte low = cx16.r0L
        cx16.r0L = $56
        show(low)
        show(cx16.r0)
        cx16.r0H = $78
        show(cx16.r0)

        ; flags after a value that was already there
        ubyte z = zero()
        if z == 0
            txt.print("zero ")
        ubyte copy = z
        if copy != 0
            txt.print("wrong ")
        else
            txt.print("still ")
        z++
        if z == 0
            txt.print("wrong ")
        if z != 0
            txt.print("one ")

        ; a word compared after its bytes were moved about
        uword w = total
        uword w2 = w
        if w2 == 1300
            txt.print("1300 ")
        if w2 >= 1301
            txt.print("wrong ")
        w2 -= 1300
        if w2 == 0
            txt.print("gone ")

        ; results computed into the parameters of the next call
        show(add3(total + 16, total - 16, counter))
        show(add3(counter, counter * 2, total / 4))

        ; the same value stored to several places, then one of them changed
        ubyte a = counter
        ubyte b = a
        ubyte c = b
        b++
        show(a)
        show(b)
        show(c)

        ; a loop whose counter is a copy
        ubyte n = table[0] + 3
        ubyte sum = 0
        repeat n
            sum += n
        show(sum)

        ; carry over a rotate pair
        uword bits = $8001
        repeat 3 {
            sys.clear_carry()
            rol(bits)
        }
        show(bits)
        txt.nl()
    }
}
