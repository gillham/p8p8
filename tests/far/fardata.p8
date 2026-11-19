%import textio

; data at addresses of more than 16 bits, by every way of writing one that is a
; constant: memory mapped variables and arrays, @(), peek and poke.
; FARBASE is somewhere the machine has memory of its own: the MEGA65's bank 4
; here ($40000); for a C64 with a SuperCPU, -D or an edit makes it $020000.
main {
    const long FARBASE = $40000
    &ubyte farbyte = FARBASE
    &uword farword = FARBASE + 2
    &long farlong = FARBASE + 4
    &bool farflag = FARBASE + 8
    &ubyte[32] fararray = FARBASE + 16
    &uword[8] @nosplit farwords = FARBASE + 64
    ubyte[4] @shared near = [1, 2, 3, 4]

    sub start() {
        farbyte = 42
        farword = 12345
        farlong = 123456789
        farflag = true
        txt.print_ub(farbyte)
        txt.spc()
        txt.print_uw(farword)
        txt.spc()
        txt.print_l(farlong)
        txt.spc()
        txt.print_bool(farflag)
        txt.nl()

        farbyte++
        farbyte += 10
        farword -= 345
        farword <<= 1
        farlong += 1000000
        farbyte |= $80
        txt.print_ub(farbyte)
        txt.spc()
        txt.print_uw(farword)
        txt.spc()
        txt.print_l(farlong)
        txt.spc()
        txt.print_ub(farbyte & 15)
        txt.nl()

        ubyte i
        for i in 0 to 31
            fararray[i] = i * 3
        ubyte sum = 0
        for i in 0 to 31
            sum += fararray[i]
        txt.print_ub(sum)
        txt.spc()
        txt.print_ub(fararray[10])
        txt.spc()
        fararray[5]++
        fararray[6] += fararray[5]
        txt.print_ub(fararray[6])
        txt.spc()
        for i in 0 to 7
            farwords[i] = 1000 * i
        txt.print_uw(farwords[7])
        txt.spc()
        txt.print_uw(farwords[3] + farwords[4])
        txt.nl()

        @($40100) = 77
        @($40101) = @($40100) + 1
        poke($40102, 99)
        pokew($40104, 54321)
        pokel($40108, -5)
        txt.print_ub(@($40100))
        txt.spc()
        txt.print_ub(@($40101))
        txt.spc()
        txt.print_ub(peek($40102))
        txt.spc()
        txt.print_uw(peekw($40104))
        txt.spc()
        txt.print_l(peekl($40108))
        txt.spc()
        txt.print_ub(peek($40105))
        txt.nl()

        ; a loop over a far array, its length, comparisons
        ubyte total = 0
        ubyte each
        for each in fararray
            total += each
        txt.print_ub(total)
        txt.spc()
        txt.print_ub(len(fararray))
        txt.spc()
        farbyte = 200
        if farbyte > 100
            txt.print("big ")
        if farbyte == 200 and fararray[7] == 21
            txt.print("eq ")
        farbyte = fararray[2] * 2 + farbyte / 4
        txt.print_ub(farbyte)
        txt.nl()

        ; the memory nearby is as it was
        txt.print_ub(near[0] + near[1] + near[2] + near[3])
        txt.spc()
        txt.print_ub(@($0100) ^ @($0100))
        txt.nl()
    }
}
