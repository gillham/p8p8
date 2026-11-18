%import textio
%zeropage basicsafe

; the address of an element of a constant address, of a pointer and of a memory
; mapped array; a struct field's offset; a member of an enum by an alias of it
main {
    struct Node { ubyte kind  uword value  bool flag }
    enum Level { LOW=7, MID, HIGH=20 }
    alias lv = Level
    const uword screen = $0400
    const ^^ubyte bytes = $2000
    uword @shared base = $3000
    &ubyte[40] row = $0428

    sub start() {
        ubyte @shared i = 3
        uword @shared big = 300
        txt.print_uwhex(&screen[2], true)
        txt.spc()
        txt.print_uwhex(&screen[i], true)
        txt.spc()
        txt.print_uwhex(&screen[big], true)
        txt.spc()
        txt.print_uwhex(&bytes[5], true)
        txt.spc()
        txt.print_uwhex(&base[i], true)
        txt.spc()
        txt.print_uwhex(&row[10], true)
        txt.spc()
        txt.print_uwhex(&row[i], true)
        txt.nl()
        txt.print_ub(offsetof(Node.kind))
        txt.print_ub(offsetof(Node.value))
        txt.print_ub(offsetof(Node.flag))
        txt.spc()
        const ubyte where = offsetof(Node.flag) + sizeof(Node)
        txt.print_ub(where)
        txt.spc()
        txt.print_ub(lv::LOW)
        txt.spc()
        txt.print_ub(lv::MID + Level::HIGH)
        txt.nl()
    }
}
