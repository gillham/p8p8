; sys.entropy() (p8p8's own): a number to seed with, another one at every call.
%import textio
%zeropage basicsafe

main {
    sub start() {
        uword a = sys.entropy()
        uword b = sys.entropy()
        uword c = sys.entropy()
        uword d = sys.entropy()
        ; (two that are the same can happen, once in 65536; four cannot be expected to)
        txt.print_bool(a != b or b != c or c != d)
        txt.nl()
    }
}
