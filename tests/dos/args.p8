; The command line on MS-DOS (tests/dos/args.args is what the program is started with).
%import textio
%import strings

main {
    asmsub dos_version() -> ubyte @AL {
        %asm {{
            mov  ah, 0x30
            int  0x21
            ret
        }}
    }

    sub start() {
        uword n
        txt.print_bool(dos_version() >= 3)
        txt.nl()
        txt.print_uw(sys.argc())
        txt.nl()
        for n in 1 to sys.argc() {
            txt.chrout('[')
            txt.print(sys.argv(n))
            txt.chrout(']')
        }
        txt.nl()
        uword name = sys.argv(0)
        ubyte length = strings.length(name)
        txt.print_bool(length > 4 and @(name + length - 4) == '.' and @(name + length - 3) == 'C')
        txt.nl()
        ; (two arguments held at once)
        uword first = sys.argv(1)
        uword third = sys.argv(3)
        txt.print(third)
        txt.print(first)
        txt.nl()
    }
}
