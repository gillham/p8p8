%import textio

; a block with an address of its own, written between two others: it goes
; after everything else, so the rest of the program is not assembled there
main {
    sub start() {
        txt.print_ub(high.value)
        txt.spc()
        high.more()
        txt.print_ub(high.value)
        txt.spc()
        txt.print_ub(after.other)
        txt.spc()
        txt.print_bool(&high.value >= $9000)
        txt.print_bool(&after.other < $9000)
        txt.print_bool(&after.bump < $9000)
        txt.nl()
    }
}

high $9000 {
    ubyte @shared value = 3
    sub more() {
        value++
        after.bump()
    }
}

after {
    ubyte @shared other = 4
    sub bump() {
        other += 10
    }
}
