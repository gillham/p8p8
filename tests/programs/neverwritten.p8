; A variable that is never written counts as a constant where one is required: as an
; element of an array initializer and as a choice of a when statement (upstream makes
; such a variable a constant).
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
main {
    sub start() {
        ubyte v = 2
        ubyte w = 5
        w++
        ubyte[] arr = [1, v, 3]
        when w {
            v -> txt.print("two ")
            6 -> txt.print("six ")
            else -> txt.print("other ")
        }
        txt.print_ub(arr[1])
        txt.nl()
    }
}
