; A subroutine called through a pointer, and the value it returns (call() gives a
; word).  Compared with upstream by the emulator suites and natively; the reference
; virtual machine cannot run it.

%import textio
main {
    uword fn
    sub yes() -> bool {
        return true
    }
    sub no() -> bool {
        return false
    }
    sub seven() -> uword {
        return 7777
    }
    sub start() {
        fn = &yes as uword
        if lsb(call(fn)) == 0
            txt.print("wrong ")
        else
            txt.print("ok ")
        fn = &no as uword
        if lsb(call(fn)) == 0
            txt.print("ok ")
        else
            txt.print("wrong ")
        fn = &seven as uword
        uword v = call(fn)
        txt.print_uw(v)
        txt.nl()
    }
}
