%import textio
%zeropage basicsafe
%option romable

; Overlays in the banks of a GameTank cartridge (make overlaycheck needs an emulator for
; it; without one the cartridge is built and its banks are looked at).  The main program
; is in the fixed bank.  Code in two banks that call each other and the main program; a
; bank with data in it (as an asset is, here four bytes) beside the subroutine that reads
; it, also through a routine of the library (%option overlay_data).
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
        txt.print_ub(asset.copied())
        txt.spc()
        txt.print_uw(counter)
        txt.nl()
        asset.describe()
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
    %option overlay_data        ; (the library is given addresses in this bank)
    %asm {{
table   .byte  10, 20, 30, 40
    }}
packed:
    %asm {{
        .byte  1, 2, 3, 4, 5, 6
    }}

    str where = "text in bank 129"

    ; (the string is in this bank too, and the library prints it from here)
    sub describe() {
        txt.print(where)
    }

    ; a routine of the library copies out of this bank
    sub copied() -> ubyte {
        ubyte[6] buffer
        sys.memcopy(packed, &buffer, 6)
        return buffer[0] + buffer[5] * 10
    }

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
