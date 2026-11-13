; A memory-mapped array of struct instances.
; Compared with upstream by make vmcmp.

%import textio
%zeropage basicsafe

main {
    struct Channel {
        uword period
        ubyte volume
    }

    &Channel[4] channels = $8000

    sub start() {
        ubyte i
        for i in 0 to 3 {
            channels[i].period = 400 + i
            channels[i].volume = 60 + i
        }
        channels[1] = channels[3]
        channels[2].volume += 5
        txt.print_uw(peekw($8003))
        txt.spc()
        txt.print_ub(@($8005))
        txt.spc()
        txt.print_ub(@($8008))
        txt.spc()
        txt.print_uw(channels[0].period)
        txt.nl()
    }
}
