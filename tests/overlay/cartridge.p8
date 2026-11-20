%import textio
%zeropage basicsafe
%option romable

; Overlays in the banks of a GameTank cartridge (make overlaycheck needs an emulator for
; it; without one the cartridge is built and its banks are looked at).  The main program
; is in the fixed bank.  Code in two banks that call each other and the main program; a
; bank with data in it (as an asset is, here four bytes) beside the subroutine that reads
; it; and the bank the main program chooses itself is still chosen after a call.
%overlay 128, sums, main.triple
%overlay 129, asset

main {
    uword counter

    sub start() {
        txt.print("cartridge ")
        txt.print_uw(triple(14))
        txt.spc()
        txt.print_uw(sums.add(100, 23))
        txt.spc()
        txt.print_ub(asset.third())
        txt.spc()
        txt.print_uw(asset.total())
        txt.spc()
        txt.print_uw(counter)
        txt.nl()
    }

    sub triple(uword v) -> uword {
        counter++
        return v * 3
    }

    sub bump() {
        counter += 10
    }
}

sums {
    sub add(uword a, uword b) -> uword {
        main.bump()
        return a + b
    }
}

asset {
    %asm {{
table   .byte  10, 20, 30, 40
    }}

    asmsub third() -> ubyte @A {
        %asm {{
            lda  p8b_asset.table+2
            rts
        }}
    }

    asmsub entry(ubyte index @Y) -> ubyte @A {
        %asm {{
            lda  p8b_asset.table,y
            rts
        }}
    }

    sub total() -> uword {
        uword sum = 0
        ubyte i
        for i in 0 to 3
            sum += entry(i)
        return sums.add(sum, main.triple(1))
    }
}
