; defer: several in one subroutine, in a branch that is not taken, with early
; returns, with a return value that the deferred code changes afterwards, with
; several return values, nested calls, and sys.exit unwinding the callers.
; Compared with upstream by make vmcmp and make nativecmp.

%import textio
%zeropage basicsafe

main {
    ubyte counter

    sub work(ubyte n) -> ubyte {
        defer txt.print("cleanup ")
        if n == 0
            return 1
        defer {
            txt.print("second ")
            counter++
        }
        if n == 9 {
            defer txt.print("never ")
        }
        return n * 2 + counter
    }

    sub pair(ubyte n) -> ubyte, uword {
        defer counter = 100
        return counter + n, counter * (300 as uword)
    }

    sub loops() {
        ubyte i
        for i in 1 to 3 {
            defer txt.print("once ")
            txt.print_ub(i)
            txt.spc()
        }
        txt.print("end ")
    }

    sub inner() {
        defer txt.print("inner-defer ")
        txt.print("inner ")
        if counter == 100 {
            defer txt.print("exit-defer ")
            sys.exit(0)
        }
    }

    sub outer() {
        defer txt.print("outer-defer ")
        inner()
        txt.print("outer-end ")
    }

    sub start() {
        defer txt.print("start-defer\n")
        txt.print_ub(work(0))
        txt.nl()
        txt.print_ub(work(4))
        txt.nl()
        txt.print_ub(work(4))
        txt.nl()
        loops()
        txt.nl()
        outer()
        txt.nl()
        ubyte a
        uword b
        a, b = pair(5)
        txt.print_ub(a)
        txt.spc()
        txt.print_uw(b)
        txt.spc()
        txt.print_ub(counter)
        txt.nl()
        outer()
        txt.print("not reached\n")
    }
}
