; A block with %option amiga_chipram: its variables, with and without initial
; values, are in the Amiga's chip memory (sections of their own in the program
; file), and are used like any others.
; Compared with upstream by make amigacmp and amigacmp500.
; (No call of a subroutine in such a block from outside: upstream's code for
; that does not assemble.)

%import textio

main {
    sub start() {
        ubyte i
        for i in 0 to 3
            chip.buffer[i] = chip.sprite[i] as ubyte * 10
        chip.counter = 1000
        chip.counter += chip.buffer[1]
        txt.print_ub(chip.buffer[2])
        txt.spc()
        txt.print_uw(chip.counter)
        txt.spc()
        txt.print_uw(chip.sprite[3])
        txt.nl()
    }
}

chip {
    %option amiga_chipram
    uword[4] sprite = [1, 2, 3, 4]
    ubyte[16] buffer
    uword counter
}
