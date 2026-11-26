; The system routines of the atarist target: the wait and the clock it counts with,
; the stack that the program keeps, where the program is, the screen's mode.
; tests/atarist/system.out is what it prints (make stcmp).
%import textio

main {
    sub start() {
        long before = tos.hz200()
        sys.wait(60)
        long ticks = tos.hz200() - before
        ; a second is 200 of the clock's ticks
        txt.print_bool(ticks >= 195 and ticks <= 215)
        txt.spc()
        ; the stack: 16 KB less what the program has used of it by now
        long stack = sys.stack_size()
        txt.print_bool(stack > 16000 and stack <= 16384)
        txt.spc()
        txt.print_bool(sys.progend() - sys.progstart() > 500)
        txt.spc()
        txt.print_bool(tos.basepage + 256 == sys.progstart())
        txt.spc()
        txt.print_bool(tos.rez <= 2)
        txt.nl()
        ubyte[10] source = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        ubyte[10] target
        sys.memcopy(&source + 1, &target, 9)
        txt.print_ub(target[0])
        txt.spc()
        txt.print_ub(target[8])
        txt.spc()
        txt.print_ub(target[9])
        txt.nl()
        sys.exit(3)
        txt.print("not reached\n")
    }
}
