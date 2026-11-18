%import textio
%import floats
%zeropage basicsafe

; peekf and pokef
main {
    sub start() {
        float @shared f = 3.25
        pokef($0400, f * 2.0)
        floats.print(peekf($0400))
        txt.spc()
        pokef($0410, -0.125)
        f = peekf($0410) + peekf($0400)
        floats.print(f)
        txt.nl()
    }
}
