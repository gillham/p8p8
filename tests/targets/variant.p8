; See variant.properties next to this file.
%import textio
%zeropage basicsafe

main {
    ubyte counter
    uword total
    ubyte @zp wanted
    sub start() {
        counter++
        total += counter
        wanted = counter
        txt.print_uw(total + wanted)
        txt.nl()
    }
}
