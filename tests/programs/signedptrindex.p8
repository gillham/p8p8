%import textio
%zeropage basicsafe

; An address variable may be indexed by a signed variable (an array may not):
; the index is added to the address with its sign, so a negative one reads
; and writes before it.  Only word and long indexes are here: for a signed
; byte the reference compiler's 6502 code adds the index as if unsigned.

main {
    ubyte[12] @shared arr = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]

    sub show(ubyte v) {
        txt.print_ub(v)
        txt.spc()
    }

    sub start() {
        pointer @shared ptr = &arr + 6
        word @shared w = -5
        long @shared l = -6
        show(ptr[w])
        show(ptr[l])
        w = 4
        l = 5
        show(ptr[w])
        show(ptr[l])
        txt.nl()
        ptr[l] = 99
        l = -1
        ptr[l] = 77
        w = -3
        ptr[w] += 100
        w = -4
        ptr[w]++
        ubyte i
        for i in 0 to 11
            show(arr[i])
        txt.nl()
    }
}
