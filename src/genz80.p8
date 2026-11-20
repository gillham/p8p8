; The Z80 code generator: writes a p8p8 IR program (ir.p8) as assembly for z88dk's
; z80asm.  A first version.
;
; How it is put together (docs/DESIGN.md, "The Z80"):
;
; - Every IR register has a place in memory (p8r_N, as wide as its type).  An
;   instruction takes its operands from there into A (a byte) or HL and DE (a word),
;   works, and puts the result back.  That is slow and simple; registers that live in
;   CPU registers come later.
; - A call puts its arguments into the subroutine's parameter variables, as the IR
;   names them; a result comes back in A (a byte) or HL (a word).
; - What the machine has to do (print a character, a string) is a system call in the
;   IR; here those are routines for CP/M's BDOS.
; - The program is a CP/M .com file: it begins at $0100, takes its stack below the
;   BDOS, clears its variables, and returns to CP/M with a warm start.
;
; Not there yet is said by an error that names the instruction: longs beyond loading,
; storing, adding and comparing, floats, signed division, most system calls.

%import ir
%import irparse
%import buf
%import strtab
%import strings
%import mem
%import out

genz80 {
    %option ignore_unused

    ^^ir.Program prog = 0
    ^^buf.Buf o = 0
    ^^buf.Buf nb = 0
    long errors = 0
    long labels = 0
    ^^ubyte reg_used = 0            ; per IR register: named by the code that was written
    long part = 0                   ; which subroutine's registers: its number
    ^^buf.Buf cells = 0             ; the places of the registers, written at the end
    ^^ir.Instr previous = 0         ; the instruction before the one being written, in its chunk
    bool need_mul = false
    bool need_div = false
    bool need_print = false
    bool need_jphl = false
    bool need_vregs = false

    sub error(str message, ^^ubyte detail) {
        out.err()
        out.puts("Z80 code generator: ")
        out.puts(message)
        if detail != 0 {
            out.puts(": ")
            out.puts(detail)
        }
        out.nl()
        errors++
    }

    ; ---- writing ----

    sub put(^^ubyte text) {
        buf.add_str(o, text)
    }

    sub putn(long value) {
        buf.add_long(o, value)
    }

    sub nl() {
        buf.add_byte(o, '\n')
    }

    ; one line of assembly
    sub line(str text) {
        buf.add_str(o, "    ")
        buf.add_str(o, text)
        buf.add_byte(o, '\n')
    }

    ; a name of the program as the assembler takes it: its dots are underscores, and it
    ; begins with an underscore, so that no name is one of the assembler's own words
    sub name(^^ubyte sym) {
        buf.add_byte(o, '_')
        long k = 0
        while sym[k] != 0 {
            if sym[k] == '.'
                buf.add_byte(o, '_')
            else
                buf.add_byte(o, sym[k])
            k++
        }
    }

    sub label(^^ubyte sym) {
        name(sym)
        put(":")
        nl()
    }

    sub new_label() -> long {
        labels++
        return labels
    }

    sub put_local(long n) {
        put("p8z_")
        putn(n)
    }

    sub local(long n) {
        put_local(n)
        put(":")
        nl()
    }

    ; "    mnemonic  " and the rest of the line follows
    sub start(str mnemonic) {
        put("    ")
        put(mnemonic)
        put("  ")
    }

    ; ---- types ----

    sub size_of(ubyte t) -> ubyte {
        when t {
            ir.T_BYTE -> return 1
            ir.T_WORD, ir.T_POINTER -> return 2
            ir.T_LONG -> return 4
        }
        return 0
    }

    ; the type an operand register is written with
    sub type1(^^ir.Instr i) -> ubyte {
        if i.t1 != 0
            return i.t1
        return i.type
    }

    sub type2(^^ir.Instr i) -> ubyte {
        if i.t2 != 0
            return i.t2
        return i.type
    }

    ; ---- operands ----

    ; a register's place, with a byte offset
    sub reg(uword r, ubyte offset) {
        if r <= ir.regcount
            reg_used[r] = 1
        ; (register numbers are used again from one subroutine to the next, so each
        ; subroutine has places of its own)
        put("p8r_")
        putn(part)
        put("_")
        putn(r)
        if offset != 0 {
            put("+")
            putn(offset)
        }
    }

    ; the memory operand of an instruction (without an index), with a byte offset
    sub mem_name(^^ir.Instr i, long extra) {
        if i.sym != 0 {
            name(i.sym)
            if i.offset + extra != 0 {
                put("+")
                putn(i.offset + extra)
            }
        }
        else if (i.value as long) + i.offset >= $ff0000 {
            ; (one of the library's virtual registers, by its made-up address)
            put("p8_vregs+")
            putn((i.value as long) + i.offset - $ff0000 + extra)
            need_vregs = true
        }
        else
            putn((i.value as long) + i.offset + extra)
    }

    ; "ld a,(reg)" and its relatives
    sub a_from_reg(uword r, ubyte offset) {
        start("ld")
        put("a,(")
        reg(r, offset)
        put(")")
        nl()
    }

    sub reg_from_a(uword r, ubyte offset) {
        start("ld")
        put("(")
        reg(r, offset)
        put("),a")
        nl()
    }

    sub pair_from_reg(str pair, uword r, ubyte offset) {
        start("ld")
        put(pair)
        put(",(")
        reg(r, offset)
        put(")")
        nl()
    }

    sub reg_from_pair(uword r, ubyte offset, str pair) {
        start("ld")
        put("(")
        reg(r, offset)
        put("),")
        put(pair)
        nl()
    }

    sub a_from_mem(^^ir.Instr i, long extra) {
        start("ld")
        put("a,(")
        mem_name(i, extra)
        put(")")
        nl()
    }

    sub mem_from_a(^^ir.Instr i, long extra) {
        start("ld")
        put("(")
        mem_name(i, extra)
        put("),a")
        nl()
    }

    sub pair_from_mem(str pair, ^^ir.Instr i, long extra) {
        start("ld")
        put(pair)
        put(",(")
        mem_name(i, extra)
        put(")")
        nl()
    }

    sub mem_from_pair(^^ir.Instr i, long extra, str pair) {
        start("ld")
        put("(")
        mem_name(i, extra)
        put("),")
        put(pair)
        nl()
    }

    sub pair_imm(str pair, long value) {
        start("ld")
        put(pair)
        put(",")
        putn(value & $ffff)
        nl()
    }

    sub a_imm(long value) {
        start("ld")
        put("a,")
        putn(value & 255)
        nl()
    }

    ; HL = the address of the instruction's memory operand, with its index when it has
    ; one (r2 times the element's size)
    sub hl_address(^^ir.Instr i, bool indexed) {
        start("ld")
        put("hl,")
        mem_name(i, 0)
        nl()
        if indexed and i.r2 != 0 {
            if size_of(ir.regtypes[i.r2]) == 1 {
                a_from_reg(i.r2, 0)
                line("ld  e,a")
                line("ld  d,0")
            }
            else
                pair_from_reg("de", i.r2, 0)
            ubyte times = i.scale
            if times == 0
                times = 1
            while times > 1 {
                line("sla  e")
                line("rl  d")
                times >>= 1
            }
            line("add  hl,de")
        }
    }

    ; HL = r2 + offset: the address of a load or store through a pointer
    sub hl_pointer(^^ir.Instr i) {
        pair_from_reg("hl", i.r2, 0)
        if i.offset != 0 {
            pair_imm("de", i.offset)
            line("add  hl,de")
        }
    }

    ; the bytes at (HL) into register r, or the other way round
    sub reg_from_hl(uword r, ubyte size) {
        ubyte k
        for k in 0 to size - 1 {
            line("ld  a,(hl)")
            reg_from_a(r, k)
            if k != size - 1
                line("inc  hl")
        }
    }

    sub hl_from_reg(uword r, ubyte size) {
        ubyte k
        for k in 0 to size - 1 {
            a_from_reg(r, k)
            line("ld  (hl),a")
            if k != size - 1
                line("inc  hl")
        }
    }

    ; ---- the program ----

    sub generate(^^ir.Program p, ^^buf.Buf output) {
        prog = p
        o = output
        errors = 0
        labels = 0
        need_mul = false
        need_div = false
        need_print = false
        need_jphl = false
        need_vregs = false
        if nb == 0
            nb = buf.new(256)
        if cells == 0
            cells = buf.new(65536)
        buf.clear(cells)
        part = 0
        reg_used = mem.alloc(70000)
        long k
        for k in 0 to 69999
            reg_used[k] = 0
        put("; Program: ")
        put(prog.name)
        nl()
        line("; written by p8p8's Z80 code generator, for z88dk-z80asm; a CP/M program")
        line("org  $0100")
        line("ld  sp,($0006)          ; the stack below the BDOS")
        ; the variables without values are zero
        line("ld  hl,p8_bss_start")
        line("ld  bc,p8_bss_end-p8_bss_start")
        put("p8_clear:")
        nl()
        line("ld  a,b")
        line("or  c")
        line("jr  z,p8_cleared")
        line("ld  (hl),0")
        line("inc  hl")
        line("dec  bc")
        line("jr  p8_clear")
        put("p8_cleared:")
        nl()
        line("call  p8_init_globals")
        line("call  _main_start")
        line("jp  0                   ; back to CP/M")
        nl()
        put("p8_init_globals:")
        nl()
        previous = 0
        part = 0
        chunk_code(prog.initglobals)
        line("ret")
        nl()
        register_cells()
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Chunk c = bl.chunks
            part++
            while c != 0 {
                chunk(c)
                c = c.next
            }
            register_cells()
            ^^ir.Sub s = bl.subs
            while s != 0 {
                subroutine(s)
                s = s.next
            }
            bl = bl.next
        }
        runtime()
        variables()
    }

    sub subroutine(^^ir.Sub s) {
        if s.is_external
            return
        if s.is_asm and s.asmtext != 0 and not s.asm_is_ir {
            ; assembly for another machine is of no use here
            error("a subroutine in assembly cannot be used on the Z80 yet", s.name)
            return
        }
        if not irparse.expand(s) {
            error("the IR text of a subroutine could not be read", s.name)
            return
        }
        put("; ---- ")
        put(s.name)
        nl()
        part++
        ^^ir.Chunk c = s.chunks
        bool first = true
        while c != 0 {
            if first and (c.label == 0 or strings.compare(c.label, s.name) != 0)
                label(s.name)
            first = false
            chunk(c)
            c = c.next
        }
        if first
            label(s.name)
        line("ret")
        nl()
        register_cells()
    }

    ; the places of the registers that the code just written names, for the end of the
    ; program
    sub register_cells() {
        uword r
        for r in 1 to ir.regcount {
            if reg_used[r] != 0 {
                reg_used[r] = 0
                ubyte rsize = size_of(ir.regtypes[r])
                if rsize == 0
                    rsize = 4
                buf.add_str(cells, "p8r_")
                buf.add_long(cells, part)
                buf.add_byte(cells, '_')
                buf.add_long(cells, r)
                buf.add_str(cells, ":  defs  ")
                buf.add_long(cells, rsize)
                buf.add_byte(cells, '\n')
            }
        }
    }

    sub chunk(^^ir.Chunk c) {
        if c.label != 0
            label(c.label)
        if c.kind == ir.C_ASM {
            if c.is_ir
                error("IR text that was not turned into instructions", c.label)
            else
                error("assembly text cannot be used on the Z80 yet", c.label)
            return
        }
        previous = 0
        chunk_code(c)
    }

    sub chunk_code(^^ir.Chunk c) {
        if c == 0
            return
        ^^ir.Instr i = c.first
        while i != 0 {
            instruction(i)
            previous = i
            i = i.next
        }
    }

    ; ---- instructions ----

    sub unsupported(^^ir.Instr i) {
        buf.clear(nb)
        buf.add_str(nb, ir.opcode_names[i.op])
        when i.type {
            ir.T_BYTE -> buf.add_str(nb, ".b")
            ir.T_WORD -> buf.add_str(nb, ".w")
            ir.T_LONG -> buf.add_str(nb, ".l")
            ir.T_QUAD -> buf.add_str(nb, ".q")
            ir.T_FLOAT -> buf.add_str(nb, ".f")
            ir.T_POINTER -> buf.add_str(nb, ".p")
        }
        buf.add_byte(nb, 0)
        error("this instruction is not written for the Z80 yet", nb.data)
    }

    ; the value of register r into A (a byte) or HL (a word), by the type
    sub fetch(uword r, ubyte size) {
        if size == 1
            a_from_reg(r, 0)
        else
            pair_from_reg("hl", r, 0)
    }

    sub keep(uword r, ubyte size) {
        if size == 1
            reg_from_a(r, 0)
        else
            reg_from_pair(r, 0, "hl")
    }

    ; A op= the byte in register r2 / the immediate, HL op= DE for words: the second
    ; operand into its place (B for a byte, DE for a word)
    sub second_reg(uword r, ubyte size) {
        if size == 1 {
            a_from_reg(r, 0)
            line("ld  b,a")
        }
        else
            pair_from_reg("de", r, 0)
    }

    sub second_imm(long value, ubyte size) {
        if size == 1 {
            start("ld")
            put("b,")
            putn(value & 255)
            nl()
        }
        else
            pair_imm("de", value)
    }

    ; first (A or HL) op= second (B or DE); the result is in A or HL
    sub combine(ubyte op, ubyte size) {
        when op {
            ir.OP_ADD, ir.OP_ADDR, ir.OP_ADDM, ir.OP_ADDIM -> {
                if size == 1
                    line("add  a,b")
                else
                    line("add  hl,de")
            }
            ir.OP_SUB, ir.OP_SUBR, ir.OP_SUBM, ir.OP_SUBIM -> {
                if size == 1
                    line("sub  b")
                else {
                    line("or  a")
                    line("sbc  hl,de")
                }
            }
            ir.OP_AND, ir.OP_ANDR, ir.OP_ANDM -> {
                if size == 1
                    line("and  b")
                else
                    logic16("and")
            }
            ir.OP_OR, ir.OP_ORR, ir.OP_ORM -> {
                if size == 1
                    line("or  b")
                else
                    logic16("or")
            }
            ir.OP_XOR, ir.OP_XORR, ir.OP_XORM -> {
                if size == 1
                    line("xor  b")
                else
                    logic16("xor")
            }
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULM, ir.OP_MULS, ir.OP_MULSR, ir.OP_MULSM -> {
                if size == 1 {
                    ; (a byte product is the low byte of the word product)
                    line("ld  l,a")
                    line("ld  h,0")
                    line("ld  e,b")
                    line("ld  d,0")
                    line("call  p8rt_mul16")
                    line("ld  a,l")
                }
                else
                    line("call  p8rt_mul16")
                need_mul = true
            }
            ir.OP_DIV, ir.OP_DIVR, ir.OP_DIVM, ir.OP_MOD, ir.OP_MODR -> {
                if size == 1 {
                    line("ld  l,a")
                    line("ld  h,0")
                    line("ld  e,b")
                    line("ld  d,0")
                }
                line("call  p8rt_div16")
                need_div = true
                if op == ir.OP_MOD or op == ir.OP_MODR
                    line("ex  de,hl")           ; (the remainder)
                if size == 1
                    line("ld  a,l")
            }
        }
    }

    sub logic16(str mnemonic) {
        line("ld  a,l")
        start(mnemonic)
        put("e")
        nl()
        line("ld  l,a")
        line("ld  a,h")
        start(mnemonic)
        put("d")
        nl()
        line("ld  h,a")
    }

    ; a long in register r1 op= a long: byte by byte with the carry
    sub long_from_mem(uword r, ^^ir.Instr i) {
        pair_from_mem("hl", i, 0)
        reg_from_pair(r, 0, "hl")
        pair_from_mem("hl", i, 2)
        reg_from_pair(r, 2, "hl")
    }

    sub mem_from_long(^^ir.Instr i, uword r) {
        pair_from_reg("hl", r, 0)
        mem_from_pair(i, 0, "hl")
        pair_from_reg("hl", r, 2)
        mem_from_pair(i, 2, "hl")
    }

    ; flags for the branch that follows: the value of register r as it is
    sub test_reg(uword r, ubyte size) {
        if size == 1 {
            a_from_reg(r, 0)
            line("or  a")
        }
        else {
            pair_from_reg("hl", r, 0)
            line("ld  a,h")
            line("or  l")
        }
    }

    ; Is the flag state that a status branch needs what the instruction before left?  A
    ; compare, an addition and so on leave it; after a load or a store the value is
    ; tested again here.
    sub flags_for_branch() {
        if previous == 0
            return
        when previous.op {
            ir.OP_LOAD, ir.OP_LOADM, ir.OP_LOADMZ, ir.OP_LOADR, ir.OP_LOADI, ir.OP_LOADX, ir.OP_STOREM, ir.OP_STOREI,
            ir.OP_STOREX, ir.OP_LSIGB, ir.OP_MSIGB, ir.OP_EXT, ir.OP_EXTS, ir.OP_CONCAT -> {
                if previous.r1 != 0 and previous.mode != ir.M_IM
                    test_reg(previous.r1, size_of(ir.regtypes[previous.r1]))
            }
        }
    }

    ; "jp cc,target"
    sub jump_if(str condition, ^^ubyte target) {
        start("jp")
        put(condition)
        put(",")
        name(target)
        nl()
    }

    sub jump_if_local(str condition, long n) {
        start("jp")
        put(condition)
        put(",")
        put_local(n)
        nl()
    }

    ; first operand of a compare into A or HL, the second into B or DE, signed ones with
    ; their top bit turned over (then the unsigned compare says the signed order)
    sub compare_operands(^^ir.Instr i, ubyte size, bool with_register, bool signed) {
        if with_register
            second_reg(i.r2, size)
        else
            second_imm(i.value as long, size)
        if signed {
            if size == 1 {
                line("ld  a,b")
                line("xor  $80")
                line("ld  b,a")
            }
            else {
                line("ld  a,d")
                line("xor  $80")
                line("ld  d,a")
            }
        }
        fetch(i.r1, size)
        if signed {
            if size == 1
                line("xor  $80")
            else {
                line("ld  a,h")
                line("xor  $80")
                line("ld  h,a")
            }
        }
        if size == 1
            line("cp  b")
        else {
            line("or  a")
            line("sbc  hl,de")
        }
    }

    ; a compare and a branch: carry is "less", zero is "equal"
    sub compare_branch(^^ir.Instr i, bool with_register, bool signed, ubyte relation) {
        ubyte size = size_of(type1(i))
        if size != 1 and size != 2 {
            unsupported(i)
            return
        }
        compare_operands(i, size, with_register, signed)
        when relation {
            0 -> {
                ; greater: not less and not equal
                long skip = new_label()
                jump_if_local("z", skip)
                jump_if("nc", i.sym)
                local(skip)
            }
            1 -> jump_if("c", i.sym)        ; less
            2 -> jump_if("nc", i.sym)       ; greater or equal
            3 -> {
                jump_if("c", i.sym)         ; less or equal
                jump_if("z", i.sym)
            }
        }
    }

    sub instruction(^^ir.Instr i) {
        ubyte size = size_of(i.type)
        ubyte k
        when i.op {
            ir.OP_NOP, ir.OP_BREAKPOINT, ir.OP_ALIGN -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0 {
                    start("ld")
                    put("hl,")
                    mem_name(i, 0)
                    nl()
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 1 {
                    a_imm(i.value as long)
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_imm("hl", i.value as long)
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 4 {
                    pair_imm("hl", i.value as long)
                    reg_from_pair(i.r1, 0, "hl")
                    pair_imm("hl", (i.value >> 16) as long)
                    reg_from_pair(i.r1, 2, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_LOADM -> {
                if size == 1 {
                    a_from_mem(i, 0)
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_from_mem("hl", i, 0)
                    reg_from_pair(i.r1, 0, "hl")
                }
                else if size == 4
                    long_from_mem(i.r1, i)
                else
                    unsupported(i)
            }
            ir.OP_LOADMZ -> {
                ; a byte from memory into a wider register, the rest zero
                a_from_mem(i, 0)
                reg_from_a(i.r1, 0)
                line("xor  a")
                for k in 1 to size_of(ir.regtypes[i.r1]) - 1
                    reg_from_a(i.r1, k)
            }
            ir.OP_LOADR -> {
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1 {
                    a_from_reg(i.r2, k)
                    reg_from_a(i.r1, k)
                }
            }
            ir.OP_LOADX -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_address(i, true)
                    reg_from_hl(i.r1, size)
                }
            }
            ir.OP_LOADI -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_pointer(i)
                    reg_from_hl(i.r1, size)
                }
            }
            ir.OP_STOREM -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    mem_from_a(i, 0)
                }
                else if size == 2 {
                    pair_from_reg("hl", i.r1, 0)
                    mem_from_pair(i, 0, "hl")
                }
                else if size == 4
                    mem_from_long(i, i.r1)
                else
                    unsupported(i)
            }
            ir.OP_STOREZM -> {
                if size == 0
                    unsupported(i)
                else {
                    line("xor  a")
                    for k in 0 to size - 1
                        mem_from_a(i, k)
                }
            }
            ir.OP_STOREIM -> {
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1 {
                    a_imm((i.value >> (k * 8)) as long)
                    mem_from_a(i, k)
                }
            }
            ir.OP_STOREX -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_address(i, true)
                    hl_from_reg(i.r1, size)
                }
            }
            ir.OP_STOREZX -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_address(i, true)
                    for k in 0 to size - 1 {
                        line("ld  (hl),0")
                        if k != size - 1
                            line("inc  hl")
                    }
                }
            }
            ir.OP_STOREI -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_pointer(i)
                    hl_from_reg(i.r1, size)
                }
            }
            ir.OP_STOREZI -> {
                if size == 0
                    unsupported(i)
                else {
                    hl_pointer(i)
                    for k in 0 to size - 1 {
                        line("ld  (hl),0")
                        if k != size - 1
                            line("inc  hl")
                    }
                }
            }
            ir.OP_JUMP -> {
                start("jp")
                name(i.sym)
                nl()
            }
            ir.OP_JUMPI -> {
                pair_from_reg("hl", i.r1, 0)
                line("jp  (hl)")
            }
            ir.OP_CALL -> call_instruction(i)
            ir.OP_CALLI -> {
                pair_from_reg("hl", i.r1, 0)
                line("call  p8rt_jphl")
                need_jphl = true
            }
            ir.OP_SYSCALL -> syscall(i)
            ir.OP_RETURN -> line("ret")
            ir.OP_RETURNR -> {
                if size == 1 or size == 2 {
                    fetch(i.r1, size)
                    line("ret")
                }
                else
                    unsupported(i)
            }
            ir.OP_RETURNI -> {
                if size == 1
                    a_imm(i.value as long)
                else if size == 2
                    pair_imm("hl", i.value as long)
                else
                    unsupported(i)
                line("ret")
            }
            ir.OP_BSTEQ -> {
                flags_for_branch()
                jump_if("z", i.sym)
            }
            ir.OP_BSTNE -> {
                flags_for_branch()
                jump_if("nz", i.sym)
            }
            ir.OP_BSTNEG -> {
                flags_for_branch()
                jump_if("m", i.sym)
            }
            ir.OP_BSTPOS -> {
                flags_for_branch()
                jump_if("p", i.sym)
            }
            ; (the IR's carry is the 6502's: clear after a compare means "less".  A compare
            ; here leaves the Z80's, which is set then.)
            ir.OP_BSTCC -> {
                if previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("c", i.sym)
                else
                    jump_if("nc", i.sym)
            }
            ir.OP_BSTCS -> {
                if previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("nc", i.sym)
                else
                    jump_if("c", i.sym)
            }
            ir.OP_CMP -> {
                if size == 1 or size == 2
                    compare_operands(i, size, true, false)
                else
                    unsupported(i)
            }
            ir.OP_CMPI -> {
                if size == 1 or size == 2
                    compare_operands(i, size, false, false)
                else
                    unsupported(i)
            }
            ir.OP_BGT -> compare_branch(i, false, false, 0)
            ir.OP_BGTR -> compare_branch(i, true, false, 0)
            ir.OP_BLT -> compare_branch(i, false, false, 1)
            ir.OP_BGE -> compare_branch(i, false, false, 2)
            ir.OP_BGER -> compare_branch(i, true, false, 2)
            ir.OP_BLE -> compare_branch(i, false, false, 3)
            ir.OP_BGTS -> compare_branch(i, false, true, 0)
            ir.OP_BGTSR -> compare_branch(i, true, true, 0)
            ir.OP_BLTS -> compare_branch(i, false, true, 1)
            ir.OP_BGES -> compare_branch(i, false, true, 2)
            ir.OP_BGESR -> compare_branch(i, true, true, 2)
            ir.OP_BLES -> compare_branch(i, false, true, 3)
            ir.OP_INC, ir.OP_DEC -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    if i.op == ir.OP_INC
                        line("inc  a")
                    else
                        line("dec  a")
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_from_reg("hl", i.r1, 0)
                    if i.op == ir.OP_INC
                        line("inc  hl")
                    else
                        line("dec  hl")
                    reg_from_pair(i.r1, 0, "hl")
                    line("ld  a,h")
                    line("or  l")
                }
                else
                    unsupported(i)
            }
            ir.OP_INCM, ir.OP_DECM -> {
                if size == 1 {
                    start("ld")
                    put("hl,")
                    mem_name(i, 0)
                    nl()
                    if i.op == ir.OP_INCM
                        line("inc  (hl)")
                    else
                        line("dec  (hl)")
                }
                else if size == 2 {
                    pair_from_mem("hl", i, 0)
                    if i.op == ir.OP_INCM
                        line("inc  hl")
                    else
                        line("dec  hl")
                    mem_from_pair(i, 0, "hl")
                    line("ld  a,h")
                    line("or  l")
                }
                else
                    unsupported(i)
            }
            ir.OP_ADD, ir.OP_SUB, ir.OP_AND, ir.OP_OR, ir.OP_XOR, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_MOD -> {
                ; register op= immediate
                if size == 1 or size == 2 {
                    second_imm(i.value as long, size)
                    fetch(i.r1, size)
                    combine(i.op, size)
                    keep(i.r1, size)
                }
                else
                    unsupported(i)
            }
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_ANDR, ir.OP_ORR, ir.OP_XORR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_MODR -> {
                ; register op= register
                if size == 1 or size == 2 {
                    second_reg(i.r2, size)
                    fetch(i.r1, size)
                    combine(i.op, size)
                    keep(i.r1, size)
                }
                else if size == 4 and (i.op == ir.OP_ADDR or i.op == ir.OP_SUBR) {
                    for k in 0 to 3 {
                        a_from_reg(i.r2, k)
                        line("ld  b,a")
                        a_from_reg(i.r1, k)
                        if i.op == ir.OP_ADDR {
                            if k == 0
                                line("add  a,b")
                            else
                                line("adc  a,b")
                        }
                        else {
                            if k == 0
                                line("sub  b")
                            else
                                line("sbc  a,b")
                        }
                        reg_from_a(i.r1, k)
                    }
                }
                else
                    unsupported(i)
            }
            ir.OP_ADDM, ir.OP_SUBM, ir.OP_ANDM, ir.OP_ORM, ir.OP_XORM, ir.OP_MULM, ir.OP_MULSM, ir.OP_DIVM -> {
                ; memory op= register
                if size == 1 {
                    second_reg(i.r1, 1)
                    a_from_mem(i, 0)
                    combine(i.op, 1)
                    mem_from_a(i, 0)
                }
                else if size == 2 {
                    second_reg(i.r1, 2)
                    pair_from_mem("hl", i, 0)
                    combine(i.op, 2)
                    mem_from_pair(i, 0, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_ADDIM, ir.OP_SUBIM -> {
                ; memory op= immediate
                if size == 1 {
                    second_imm(i.value as long, 1)
                    a_from_mem(i, 0)
                    combine(i.op, 1)
                    mem_from_a(i, 0)
                }
                else if size == 2 {
                    second_imm(i.value as long, 2)
                    pair_from_mem("hl", i, 0)
                    combine(i.op, 2)
                    mem_from_pair(i, 0, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_NEG -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    line("neg")
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    pair_from_reg("de", i.r1, 0)
                    line("ld  hl,0")
                    line("or  a")
                    line("sbc  hl,de")
                    reg_from_pair(i.r1, 0, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_INV -> {
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1 {
                    a_from_reg(i.r1, k)
                    line("cpl")
                    reg_from_a(i.r1, k)
                }
            }
            ir.OP_LSL, ir.OP_LSR, ir.OP_ASR -> shift_register(i, 1, size)
            ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI -> shift_register(i, (i.value & 255) as ubyte, size)
            ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN -> {
                ; by the number in r2: one bit at a time
                if size != 1 and size != 2 {
                    unsupported(i)
                    return
                }
                long again = new_label()
                long done = new_label()
                a_from_reg(i.r2, 0)
                line("or  a")
                jump_if_local("z", done)
                line("ld  c,a")
                local(again)
                shift_once(i.op, i.r1, size)
                line("dec  c")
                jump_if_local("nz", again)
                local(done)
            }
            ir.OP_EXT, ir.OP_EXTS -> {
                ; r1 (the next wider type) = r2 (the instruction's type)
                ubyte wide = size_of(ir.regtypes[i.r1])
                if size == 0 or wide <= size {
                    unsupported(i)
                    return
                }
                for k in 0 to size - 1 {
                    a_from_reg(i.r2, k)
                    reg_from_a(i.r1, k)
                }
                if i.op == ir.OP_EXTS {
                    ; (A is the top byte still: all ones when it is negative)
                    line("rlca")
                    line("sbc  a,a")
                }
                else
                    line("xor  a")
                for k in size to wide - 1
                    reg_from_a(i.r1, k)
            }
            ir.OP_LSIGB, ir.OP_LSIGW -> {
                ; the low byte (word) of r2
                ubyte part = 1
                if i.op == ir.OP_LSIGW
                    part = 2
                for k in 0 to part - 1 {
                    a_from_reg(i.r2, k)
                    reg_from_a(i.r1, k)
                }
            }
            ir.OP_MSIGB -> {
                ; the high byte of r2, which is of the instruction's type
                a_from_reg(i.r2, size - 1)
                reg_from_a(i.r1, 0)
            }
            ir.OP_MSIGW -> {
                a_from_reg(i.r2, 2)
                reg_from_a(i.r1, 0)
                a_from_reg(i.r2, 3)
                reg_from_a(i.r1, 1)
            }
            ir.OP_CONCAT -> {
                ; r1 = r2 (the high half) and r3 (the low half), each of the instruction's type
                if size == 1 or size == 2 {
                    for k in 0 to size - 1 {
                        a_from_reg(i.r3, k)
                        reg_from_a(i.r1, k)
                        a_from_reg(i.r2, k)
                        reg_from_a(i.r1, size + k)
                    }
                }
                else
                    unsupported(i)
            }
            ir.OP_PUSH -> {
                if size == 1 {
                    a_from_reg(i.r1, 0)
                    line("push  af")
                }
                else if size == 2 {
                    pair_from_reg("hl", i.r1, 0)
                    line("push  hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_POP -> {
                if size == 1 {
                    line("pop  af")
                    reg_from_a(i.r1, 0)
                }
                else if size == 2 {
                    line("pop  hl")
                    reg_from_pair(i.r1, 0, "hl")
                }
                else
                    unsupported(i)
            }
            ir.OP_CLC -> line("or  a")
            ir.OP_SEC -> line("scf")
            else -> unsupported(i)
        }
    }

    ; one bit: the register's bytes from the end that the bit leaves
    sub shift_once(ubyte op, uword r, ubyte size) {
        ubyte k
        if op == ir.OP_LSL or op == ir.OP_LSLI or op == ir.OP_LSLN {
            for k in 0 to size - 1 {
                a_from_reg(r, k)
                if k == 0
                    line("add  a,a")
                else
                    line("rla")
                reg_from_a(r, k)
            }
        }
        else {
            k = size
            while k != 0 {
                k--
                a_from_reg(r, k)
                if k == size - 1 {
                    if op == ir.OP_ASR or op == ir.OP_ASRI or op == ir.OP_ASRN
                        line("sra  a")
                    else
                        line("srl  a")
                }
                else
                    line("rra")
                reg_from_a(r, k)
            }
        }
    }

    sub shift_register(^^ir.Instr i, ubyte count, ubyte size) {
        if size == 0 {
            unsupported(i)
            return
        }
        repeat count
            shift_once(i.op, i.r1, size)
    }

    ; A call: the arguments into the subroutine's parameters, by their names; a result
    ; comes back in A or HL.
    sub call_instruction(^^ir.Instr i) {
        ^^ir.Arg a = i.args
        while a != 0 {
            ubyte size = size_of(a.type)
            if a.name == 0 or size == 0 or size > 4 {
                error("the arguments of this call cannot be passed on the Z80 yet", i.sym)
                return
            }
            ubyte k
            for k in 0 to size - 1 {
                if a.reg != 0
                    a_from_reg(a.reg, k)
                else
                    a_imm((a.value >> (k * 8)) as long)
                start("ld")
                put("(")
                ; (the parameter: a variable of the subroutine, named there without its scope)
                if not text_has(a.name, ".") {
                    name(i.sym)
                    put("_")
                    put(a.name)
                }
                else
                    name(a.name)
                if k != 0 {
                    put("+")
                    putn(k)
                }
                put("),a")
                nl()
            }
            a = a.next
        }
        start("call")
        name(i.sym)
        nl()
        ^^ir.Arg r = i.results
        if r != 0 {
            ubyte rsize = size_of(r.type)
            if r.next != 0 or r.reg == 0 or (rsize != 1 and rsize != 2) {
                error("the results of this call cannot be taken on the Z80 yet", i.sym)
                return
            }
            keep(r.reg, rsize)
        }
    }

    ; ---- system calls: CP/M ----

    sub syscall(^^ir.Instr i) {
        ^^ir.Arg a = i.args
        when i.value as long {
            2 -> {
                ; a character to the console (BDOS function 2)
                if a == 0 or a.reg == 0 {
                    error("system call 2 needs its character in a register", 0)
                    return
                }
                a_from_reg(a.reg, 0)
                line("ld  e,a")
                line("ld  c,2")
                line("call  5")
            }
            3 -> {
                ; a string that ends with 0
                if a == 0 or a.reg == 0 {
                    error("system call 3 needs its string in a register", 0)
                    return
                }
                pair_from_reg("hl", a.reg, 0)
                line("call  p8rt_print")
                need_print = true
            }
            else -> {
                buf.clear(nb)
                buf.add_long(nb, i.value as long)
                buf.add_byte(nb, 0)
                error("this system call is not there for CP/M yet", nb.data)
            }
        }
    }

    ; ---- what the code calls ----

    sub runtime() {
        if need_print {
            raw("; prints the string at HL (it ends with 0)")
            raw("p8rt_print:")
            line("ld  a,(hl)")
            line("or  a")
            line("ret  z")
            line("push  hl")
            line("ld  e,a")
            line("ld  c,2")
            line("call  5")
            line("pop  hl")
            line("inc  hl")
            line("jr  p8rt_print")
            nl()
        }
        if need_jphl {
            raw("p8rt_jphl:")
            line("jp  (hl)")
            nl()
        }
        if need_mul {
            raw("; HL = HL * DE (the low 16 bits)")
            raw("p8rt_mul16:")
            line("ld  b,h")
            line("ld  c,l")
            line("ld  hl,0")
            line("ld  a,16")
            raw("p8rt_mul16_bit:")
            line("add  hl,hl")
            line("rl  c")
            line("rl  b")
            line("jr  nc,p8rt_mul16_next")
            line("add  hl,de")
            raw("p8rt_mul16_next:")
            line("dec  a")
            line("jr  nz,p8rt_mul16_bit")
            line("ret")
            nl()
        }
        if need_div {
            raw("; HL = HL / DE, DE = the remainder (unsigned; a division by 0 gives $ffff)")
            raw("p8rt_div16:")
            line("ld  b,h")
            line("ld  c,l")
            line("ld  hl,0")
            line("ld  a,16")
            raw("p8rt_div16_bit:")
            line("sla  c")
            line("rl  b")
            line("adc  hl,hl")
            line("sbc  hl,de")
            line("jr  nc,p8rt_div16_fits")
            line("add  hl,de")
            line("dec  c")
            raw("p8rt_div16_fits:")
            line("inc  c")
            line("dec  a")
            line("jr  nz,p8rt_div16_bit")
            line("ex  de,hl")
            line("ld  h,b")
            line("ld  l,c")
            line("ret")
            nl()
        }
    }

    sub raw(str text) {
        put(text)
        nl()
    }

    ; ---- variables ----

    sub element_size(^^ubyte typestr) -> ubyte {
        if text_has(typestr, "word") or text_has(typestr, "pointer") or typestr[0] == '^'
            return 2
        if text_has(typestr, "long")
            return 4
        if text_has(typestr, "float") or text_has(typestr, "quad")
            return 0
        return 1
    }

    sub text_has(^^ubyte text, str part) -> bool {
        long k = 0
        while text[k] != 0 {
            long m = 0
            while part[m] != 0 and text[k + m] == part[m]
                m++
            if part[m] == 0
                return true
            k++
        }
        return false
    }

    ; how many elements a type has ("ubyte[65]": 65; 1 for what is no array)
    sub element_count(^^ubyte typestr) -> long {
        long k = 0
        while typestr[k] != 0 and typestr[k] != '['
            k++
        if typestr[k] == 0
            return 1
        long n = 0
        k++
        while typestr[k] >= '0' and typestr[k] <= '9' {
            n = n * 10 + (typestr[k] - '0')
            k++
        }
        return n
    }

    sub variables() {
        raw("; ---- variables with values")
        ^^ir.Var v = prog.vars
        while v != 0 {
            if v.kind == ir.V_MEMVAR and v.init != 0 {
                name(v.name)
                put("  equ  ")
                long address = number_of(v.init)
                if address >= $ff0000 {
                    ; (the library's virtual registers r0-r15: it gives them addresses that
                    ; no 16-bit machine has, to say that they are the back end's to place)
                    put("p8_vregs+")
                    putn(address - $ff0000)
                    need_vregs = true
                }
                else
                    put_number_text(v.init)
                nl()
            }
            else if v.kind == ir.V_VAR and v.init != 0 {
                ubyte esize = element_size(v.typestr)
                if esize == 0
                    error("a variable of this type cannot be used on the Z80 yet", v.name)
                else
                    values(v, esize)
            }
            v = v.next
        }
        raw("; ---- variables without values, and the registers of the code")
        raw("p8_bss_start:")
        v = prog.vars
        while v != 0 {
            if (v.kind == ir.V_VAR and v.init == 0) or v.kind == ir.V_SLAB {
                long bytes = v.size
                if v.kind == ir.V_VAR {
                    ubyte vsize = element_size(v.typestr)
                    if vsize == 0 {
                        error("a variable of this type cannot be used on the Z80 yet", v.name)
                        vsize = 1
                    }
                    bytes = element_count(v.typestr) * vsize
                }
                if v.align > 1 {
                    put("    align  ")
                    putn(v.align)
                    nl()
                }
                name(v.name)
                put(":  defs  ")
                putn(bytes)
                nl()
            }
            v = v.next
        }
        buf.add_bytes(o, cells.data, cells.len)
        if need_vregs
            raw("p8_vregs:  defs  32")
        raw("p8_bss_end:")
    }

    ; the value of a number as the IR writes it ($hex or decimal)
    sub number_of(^^ubyte text) -> long {
        long value = 0
        long k = 0
        if text[0] == '$' {
            k = 1
            repeat {
                ubyte c = text[k] | 32
                if text[k] >= '0' and text[k] <= '9'
                    value = value * 16 + (text[k] - '0')
                else if c >= 'a' and c <= 'f'
                    value = value * 16 + (c - 'a' + 10)
                else
                    break
                k++
            }
            return value
        }
        while text[k] >= '0' and text[k] <= '9' {
            value = value * 10 + (text[k] - '0')
            k++
        }
        return value
    }

    ; a number as the IR writes it ($hex, decimal, with a minus) for the assembler
    sub put_number_text(^^ubyte text) {
        long k = 0
        while text[k] != 0 and text[k] != ',' {
            buf.add_byte(o, text[k])
            k++
        }
    }

    ; the values of a variable: numbers, and "@name" for the address of something
    sub values(^^ir.Var v, ubyte esize) {
        if v.align > 1 {
            put("    align  ")
            putn(v.align)
            nl()
        }
        name(v.name)
        put(":")
        nl()
        long p = 0
        ubyte column = 0
        while v.init[p] != 0 {
            if column == 0 {
                when esize {
                    1 -> put("    defb  ")
                    2 -> put("    defw  ")
                    else -> put("    defq  ")
                }
            }
            else
                put(",")
            if v.init[p] == '@' or v.init[p] == '&' {
                p++
                buf.add_byte(o, '_')
                while v.init[p] != 0 and v.init[p] != ',' {
                    if v.init[p] == '.'
                        buf.add_byte(o, '_')
                    else
                        buf.add_byte(o, v.init[p])
                    p++
                }
            }
            else {
                while v.init[p] != 0 and v.init[p] != ',' {
                    buf.add_byte(o, v.init[p])
                    p++
                }
            }
            if v.init[p] == ','
                p++
            column++
            if column == 16 {
                nl()
                column = 0
            }
        }
        if column != 0
            nl()
    }
}
