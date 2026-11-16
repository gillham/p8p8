%import textio
%import strings

; A str parameter compared with a string is compared by its text, like a str
; variable: also when the two are in different places (a copy), and against
; the empty string.
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

main {
    str word1 = "hello"
    str copy = "?????"
    str nothing = "?"

    sub check(str s) {
        txt.print_bool(s == "hello")
        txt.spc()
        txt.print_bool("hello" == s)
        txt.spc()
        txt.print_bool(s == word1)
        txt.spc()
        txt.print_bool(s != "hello")
        txt.spc()
        txt.print_bool(s < "help")
        txt.spc()
        txt.print_bool("" == s)
        txt.spc()
        if s == 0 or "" == s
            txt.print("none")
        else
            txt.print(s)
        txt.nl()
    }

    sub start() {
        void strings.copy(word1, copy)
        nothing[0] = 0
        check(word1)
        check(copy)
        check("jello")
        check(nothing)
    }
}
