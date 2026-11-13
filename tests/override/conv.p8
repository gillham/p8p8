; A module of the program's own with the name of a library module.  It takes the
; library's place for every import, also the one inside the library's textio
; (upstream searches the -srcdirs directories first for any import).
; Only which file is loaded is tested (make test, "modules override"): this is not
; a complete conv.

conv {
    %option ignore_unused

    sub marker() -> ubyte {
        return 42
    }
}
