; Hardware registers on the Commodore 64 through llvm16 (-triple mos-c64): a loop that
; waits for the raster line to change, and colour registers written and read back, by
; address and through a memory-mapped variable.  The addresses must be the real ones
; and the accesses volatile, or the loop never ends and the writes go nowhere.
; Compared with upstream by make nativecmp16c64.

%import textio
main {
    &ubyte EXTCOL = $d020

    sub start() {
        ; wait for the raster line to change twice, then show the border colour register
        ubyte line = @($d012)
        while @($d012) == line {
        }
        EXTCOL = 5
        @($d021) = 6
        txt.print_ub(EXTCOL & 15)
        txt.spc()
        txt.print_ub(@($d021) & 15)
        txt.nl()
    }
}
