; String literals made by the compiler: "ab" * 3 and "ab" + "cd", as a value, as an
; initial value and as an argument.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%import strings
%zeropage basicsafe

main {
    sub start() {
        str dashes = "-" * 5
        str both = "left" + "right"
        txt.print(dashes)
        txt.print("ab" * 3)
        txt.print("x" + "y")
        txt.print(both)
        txt.print_ub(strings.length("." * 20))
        txt.print_ub(strings.length(both))
        txt.nl()
    }
}
