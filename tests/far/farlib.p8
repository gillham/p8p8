%import textio
%import farmem
%zeropage basicsafe

; the library's copy and fill in far memory (make farcheck)
main {
    const long FAR = $40800
    ubyte[16] near

    sub show(long where, ubyte count) {
        ubyte i
        for i in 0 to count - 1 {
            txt.print_ub(@(where + i))
            txt.spc()
        }
        txt.nl()
    }

    sub start() {
        ubyte i
        for i in 0 to 15
            near[i] = i + 1
        farmem.fill(FAR, 64, 0)
        farmem.copy(&near, FAR, 16)             ; into far memory
        show(FAR, 10)
        farmem.copy(FAR, FAR + 4, 8)            ; overlapping, upwards
        show(FAR, 14)
        farmem.copy(FAR + 2, FAR, 8)            ; overlapping, downwards
        show(FAR, 14)
        farmem.fill(FAR + 3, 4, 99)
        farmem.fill(FAR + 20, 1, 77)
        show(FAR, 10)
        farmem.copy(FAR + 2, FAR + $10000, 6)   ; from one bank to another
        farmem.copy(FAR + $10000, &near, 6)     ; and back to the program
        for i in 0 to 7 {
            txt.print_ub(near[i])
            txt.spc()
        }
        txt.print_ub(@(FAR + 20))
        txt.spc()
        txt.print_ub(@(FAR + 21))
        txt.nl()
    }
}
