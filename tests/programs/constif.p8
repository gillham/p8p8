; Features switched by constants, as a program configured at compile time has them:
; an if expression as the value of a constant and as the size of an array, a
; boolean constant of another block as a condition, a constant that takes its value
; from one in another block, and a main block in two parts (%option merge).
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
%zeropage basicsafe

features {
    const bool MARKS = true
    const bool SMALL = false
}

settings {
    const ubyte COUNT = if features.MARKS 29 else 2
    const ubyte OTHER = if features.SMALL 5 else 7
    const uword WIDE = if features.MARKS and not features.SMALL 40000 else 1
}

store {
    const ubyte SLOTS = settings.COUNT
    uword[SLOTS] slots
    bool[if features.MARKS 27 else 1] flags
}

main {
    %option merge
    sub extra() -> ubyte {
        return settings.OTHER
    }
}

main {
    sub start() {
        txt.print_ub(settings.COUNT)
        txt.chrout(' ')
        txt.print_ub(extra())
        txt.chrout(' ')
        txt.print_uw(settings.WIDE)
        txt.chrout(' ')
        txt.print_ub(len(store.slots))
        txt.chrout(' ')
        txt.print_ub(len(store.flags))
        txt.chrout(' ')
        if features.MARKS {
            for cx16.r0L in 0 to len(store.flags) - 1
                store.flags[cx16.r0L] = cx16.r0L & 1 == 0
        }
        ubyte set = 0
        for cx16.r1L in 0 to len(store.flags) - 1 {
            if store.flags[cx16.r1L]
                set++
        }
        txt.print_ub(set)
        txt.chrout(' ')
        if features.SMALL
            txt.print("small")
        else
            txt.print("full")
        txt.nl()
    }
}
