; The MC6809 code generator: writes a p8p8 IR program (ir.p8) as assembly for lwasm
; (lwtools).  A first version, put together as the Z80 one is.
;
; How it is put together (docs/DESIGN.md, "The 6809"):
;
; - Every IR register has a place in memory (p8r_S_N, as wide as its type; S is the
;   subroutine, as register numbers are used again from one to the next).  An
;   instruction takes its first operand from there into B (a byte) or D (a word),
;   works with the second one straight from memory, and puts the result back.  X holds
;   addresses.
; - The 6809 is big-endian: the high byte of a word comes first.  A place is named
;   with the number of the byte counted from the low end and the width that is
;   wanted (cell, op_mem), and the offset follows from the size of the whole.
; - A call puts its arguments into the subroutine's parameter variables, as the IR
;   names them; a result comes back in B (a byte), D (a word) or X and D (a long, D the
;   low half).
; - What the machine has to do (print a character, a string) is a system call in the
;   IR; the routines for them are the target file's.
;
; Not there yet is said by an error that names the instruction: floats, routines of a
; C library.

%import ir
%import irparse
%import buf
%import strtab
%import strings
%import mem
%import out
%import target

gen6809 {
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
    bool need_divs = false          ; the signed division of words
    bool need_mul32 = false
    bool need_div32 = false
    bool need_divs32 = false
    bool need_long = false          ; the cells of the long routines
    bool[256] slot_used             ; the hardware register slots that the code names
    bool need_print = false
    bool need_vregs = false
    bool uses_floats = false
    ; Recursion.  A subroutine's variables and the places of its IR registers are fixed
    ; memory, so a call that can come back into the calling subroutine saves them on the
    ; stack around it (see call_graph and save_own).
    ^^pointer all_subs = 0          ; every subroutine of the program
    long sub_count = 0
    ^^ubyte reaches = 0             ; sub_count rows of sub_count bytes: row a, byte b: a's code can come to call b
    ^^ir.Sub this_sub = 0           ; the subroutine being written, or 0
    long this_index = -1
    ^^ubyte reg_seen = 0            ; per IR register: named by the subroutine being written
    ^^uword own_regs = 0            ; those registers
    long own_count = 0
    const long OWN_MAX = 4000
    ^^buf.Buf body = 0              ; everything after the first lines
    bool optimize = true            ; parameters in registers; -noopt turns it off
    bool carry_cell = false         ; this subroutine keeps the IR's carry in a place of its own (see carry_scan)
    bool carry_loaded = false       ; the instruction's carry was just taken from there
    bool entry_pending = false      ; the subroutine's first label is still to come
    bool wide_error = false         ; the error about a register used wider than it is was said
    bool[32] need_rt                ; the routines of the system calls (the RT_ numbers)
    const ubyte RT_MOVE = 0
    const ubyte RT_FILL = 1
    const ubyte RT_FILLW = 2
    const ubyte RT_STRCMP = 3
    const ubyte RT_INSTR = 4
    const ubyte RT_INBYTES = 5
    const ubyte RT_INWORDS = 6
    const ubyte RT_CLAMP8 = 7
    const ubyte RT_CLAMPS8 = 8
    const ubyte RT_CLAMP16 = 9
    const ubyte RT_CLAMPS16 = 10
    const ubyte RT_SQRT = 11
    const ubyte RT_WAITKEY = 12
    const ubyte RT_LESS32 = 14
    const ubyte RT_CLAMP32 = 15
    const ubyte RT_INLONGS = 16
    const ubyte RT_CHROUT = 18
    const ubyte RT_GETKEY = 19
    const ubyte RT_CHRIN = 20
    const ubyte RT_WAIT = 21
    const ubyte RT_ARGC = 22
    const ubyte RT_ARGV = 23
    const ubyte RT_ARGS = 24        ; what the two share
    const ubyte RT_TICKS = 25

    sub error(str message, ^^ubyte detail) {
        out.err()
        out.puts("6809 code generator: ")
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

    sub raw(str text) {
        put(text)
        nl()
    }

    ; A name of the program as the assembler takes it: it begins with an underscore, so
    ; that no name is one of the assembler's own words, and each dot is two underscores
    ; (one would not do: main.page_lines and main.page.lines are different things).
    sub name(^^ubyte sym) {
        buf.add_byte(o, '_')
        long k = 0
        while sym[k] != 0 {
            if sym[k] == '.'
                buf.add_str(o, "__")
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

    ; "    mnemonic  " and the operand follows
    sub op(str mnemonic) {
        put("    ")
        put(mnemonic)
        put("  ")
    }

    ; ---- types ----

    sub size_of(ubyte t) -> ubyte {
        when t {
            ir.T_BYTE -> return 1
            ir.T_WORD, ir.T_POINTER -> return 2
            ir.T_LONG, ir.T_FLOAT -> return 4
        }
        return 0
    }

    ; the type an operand register is written with
    sub type1(^^ir.Instr i) -> ubyte {
        if i.t1 != 0
            return i.t1
        return i.type
    }

    ; how wide the place of an IR register is
    sub rsize(uword r) -> ubyte {
        ubyte s = size_of(ir.regtypes[r])
        if s == 0
            return 4
        return s
    }

    ; ---- operands ----
    ;
    ; k is the number of a byte counted from the low end (0 is the lowest), w how many
    ; bytes are wanted from there up (1 or 2): the 6809 has the high byte first, so the
    ; offset is the size of the whole less k less w.

    ; a register's place
    sub cell(uword r, ubyte k, ubyte w) {
        if r <= ir.regcount
            reg_used[r] = 1
        ; (register numbers are used again from one subroutine to the next, so each
        ; subroutine has places of its own)
        put("p8r_")
        putn(part)
        put("_")
        putn(r)
        ubyte s = rsize(r)
        if k + w > s {
            if not wide_error
                error("a register is used wider than its place is (a fault of the generator)", 0)
            wide_error = true
            return
        }
        if s - k - w != 0 {
            put("+")
            putn(s - k - w)
        }
    }

    ; the memory operand of an instruction (without an index), with a byte offset; whole
    ; is the size of what is there
    sub mem_name(^^ir.Instr i, long extra, ubyte whole) {
        if i.sym != 0 {
            name(i.sym)
            if i.offset + extra != 0 {
                put("+")
                putn(i.offset + extra)
            }
        }
        else {
            ; (a fixed address: in the value, or in the offset alone when the value is
            ; the instruction's immediate)
            long address = (i.value as long) + i.offset
            if i.op == ir.OP_STOREIM or i.op == ir.OP_ADDIM or i.op == ir.OP_SUBIM
                address = i.offset
            if address >= $ff0000 {
                ; (one of the library's virtual registers, by its made-up address; the
                ; low byte of one is the second of its two here)
                put("p8_vregs+")
                if whole == 1
                    putn(((address - $ff0000) ^ 1) + extra)
                else
                    putn(address - $ff0000 + extra)
                need_vregs = true
            }
            else
                putn((address + extra) & $ffff)
        }
    }

    ; A hardware register slot of the IR: here a place in memory, four bytes.  The
    ; values that a subroutine returns beside its first, and the one of a call through a
    ; pointer, go through them.
    sub slot(ubyte number, ubyte k, ubyte w) {
        slot_used[number] = true
        put("p8_slot_")
        putn(number)
        if 4 - k - w != 0 {
            put("+")
            putn(4 - k - w)
        }
    }

    sub op_cell(str mnemonic, uword r, ubyte k, ubyte w) {
        op(mnemonic)
        cell(r, k, w)
        nl()
    }

    sub op_mem(str mnemonic, ^^ir.Instr i, ubyte k, ubyte w, ubyte size) {
        op(mnemonic)
        mem_name(i, size - k - w, size)
        nl()
    }

    sub op_imm(str mnemonic, long value) {
        op(mnemonic)
        put("#")
        putn(value)
        nl()
    }

    sub op_slot(str mnemonic, ubyte number, ubyte k, ubyte w) {
        op(mnemonic)
        slot(number, k, w)
        nl()
    }

    ; the value of register r into B (a byte), D (a word) or X and D (a long, D the low
    ; half)
    sub fetch(uword r, ubyte size) {
        if size == 1
            op_cell("ldb", r, 0, 1)
        else {
            op_cell("ldd", r, 0, 2)
            if size == 4
                op_cell("ldx", r, 2, 2)
        }
    }

    sub keep(uword r, ubyte size) {
        if size == 1
            op_cell("stb", r, 0, 1)
        else {
            op_cell("std", r, 0, 2)
            if size == 4
                op_cell("stx", r, 2, 2)
        }
    }

    ; register to = register from, a word at a time where there is one
    sub copy_reg(uword target_reg, uword source_reg, ubyte size) {
        if size == 1 {
            op_cell("ldb", source_reg, 0, 1)
            op_cell("stb", target_reg, 0, 1)
        }
        else {
            op_cell("ldd", source_reg, 0, 2)
            op_cell("std", target_reg, 0, 2)
            if size == 4 {
                op_cell("ldd", source_reg, 2, 2)
                op_cell("std", target_reg, 2, 2)
            }
        }
    }

    ; X = the address of the instruction's memory operand, with its index when it has
    ; one (r2 times the element's size)
    sub x_address(^^ir.Instr i, bool indexed) {
        op("ldx")
        put("#")
        mem_name(i, 0, 0)
        nl()
        if indexed and i.r2 != 0 {
            ubyte times = i.scale
            if times == 0
                times = 1
            if rsize(i.r2) == 1 {
                op_cell("ldb", i.r2, 0, 1)
                if times == 1 {
                    line("abx")
                    return
                }
                line("clra")
            }
            else
                op_cell("ldd", i.r2, 0, 2)
            while times > 1 {
                line("lslb")
                line("rola")
                times >>= 1
            }
            line("leax  d,x")
        }
    }

    ; X = r2: the address of a load or store through a pointer (the offset goes into the
    ; instruction that uses it)
    sub x_pointer(^^ir.Instr i) {
        op_cell("ldx", i.r2, 0, 2)
    }

    ; "    mnemonic  n,x": byte k (of size) from the low end, w wide, of what X points at
    ; plus base
    sub op_x(str mnemonic, long base, ubyte k, ubyte w, ubyte size) {
        op(mnemonic)
        long at = base + size - k - w
        if at != 0
            putn(at)
        put(",x")
        nl()
    }

    ; the bytes at base,X into register r, or the other way round
    sub reg_from_x(uword r, long base, ubyte size) {
        if size == 1 {
            op_x("ldb", base, 0, 1, 1)
            op_cell("stb", r, 0, 1)
            return
        }
        op_x("ldd", base, 0, 2, size)
        op_cell("std", r, 0, 2)
        if size == 4 {
            op_x("ldd", base, 2, 2, size)
            op_cell("std", r, 2, 2)
        }
    }

    sub x_from_reg(uword r, long base, ubyte size) {
        if size == 1 {
            op_cell("ldb", r, 0, 1)
            op_x("stb", base, 0, 1, 1)
            return
        }
        op_cell("ldd", r, 0, 2)
        op_x("std", base, 0, 2, size)
        if size == 4 {
            op_cell("ldd", r, 2, 2)
            op_x("std", base, 2, 2, size)
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
        need_divs = false
        need_mul32 = false
        need_div32 = false
        need_divs32 = false
        need_long = false
        need_print = false
        wide_error = false
        sys.memset(&slot_used, 256, 0)
        need_vregs = false
        sys.memset(&need_rt, 32, 0)
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
        if body == 0
            body = buf.new(65536)
        buf.clear(body)
        o = body
        uses_floats = false
        put("p8_init_globals:")
        nl()
        previous = 0
        part = 0
        chunk_code(prog.initglobals)
        line("rts")
        nl()
        register_cells()
        call_graph()
        this_sub = 0
        this_index = -1
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
        o = output
        head()
        buf.add_bytes(o, body.data, body.len)
        ; (where the program starts, for a format that says so: a DECB file)
        line("end  p8_start")
    }

    ; The first lines: the program begins at the target's load address with the
    ; target's first instructions.
    sub head() {
        put("; Program: ")
        put(prog.name)
        nl()
        raw("; written by p8p8's 6809 code generator, for lwasm")
        line("pragma  autobranchlength")
        put("    org  ")
        putn(target.number("load_address", $0e00))
        nl()
        raw("p8_start:")
        ; (the machine's first instructions, when it needs any: where the stack is)
        if target.text("startup_code") != 0
            target_lines("startup_code")
        ; (the stack the program was called on, for the way back from anywhere)
        line("sts  p8_entry_s")
        if target.number("stack_size", 0) > 0
            line("lds  #p8_stack_top")
        ; the variables without values are zero
        line("ldx  #p8_bss_start")
        raw("p8_clear:")
        line("cmpx  #p8_bss_end")
        line("beq  p8_cleared")
        line("clr  ,x+")
        line("bra  p8_clear")
        raw("p8_cleared:")
        line("jsr  p8_init_globals")
        line("jsr  _main__start")
        line("clrb")
        ; How the program ends, as the target file says; sys.exit comes here too, with
        ; the status in B.  Before the end, what the target wants done there
        ; (exit_hook), when it has that.
        raw("p8_exit:")
        if target.text("exit_hook") != 0
            target_lines("exit_hook")
        line("lds  p8_entry_s")
        target_lines("exit_code")
        raw("p8_entry_s:  fdb  0")
        ; (places of the machine's own that its routines and its library share)
        if target.text("machine_cells") != 0
            target_lines("machine_cells")
        nl()
    }

    ; the lines of a key of the target file, as instructions
    sub target_lines(str key) {
        ^^ubyte text = target.text(key)
        if text == 0 {
            error("the target file lacks a key that a 6809 machine needs", key)
            return
        }
        long k = 0
        while text[k] != 0 {
            ; (a label, a line that ends with a colon, stands at the margin)
            long stop = k
            while text[stop] != 0 and text[stop] != '\n'
                stop++
            if stop == k or text[stop - 1] != ':'
                put("    ")
            while text[k] != 0 and text[k] != '\n' {
                buf.add_byte(o, text[k])
                k++
            }
            nl()
            if text[k] == '\n'
                k++
        }
    }

    sub subroutine(^^ir.Sub s) {
        if s.is_external
            return
        if s.is_asm and s.asmtext != 0 and not s.asm_is_ir {
            ; assembly for another machine is of no use here
            error("a subroutine in assembly (asmsub) cannot be used on the 6809 yet", s.name)
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
        this_sub = s
        this_index = index_of(s.name)
        own_registers(s)
        carry_cell = carry_scan(s)
        if register_params(s) != 0 {
            ; (the way in for a call that has arguments in B, X and U)
            put("p8e")
            name(s.name)
            put(":\n")
            ^^ir.Param rp = s.params
            while rp != 0 {
                ubyte where = param_register(s, rp)
                if where != 0 {
                    when where {
                        1 -> op("stb")
                        2 -> op("stx")
                        else -> op("stu")
                    }
                    name(rp.name)
                    nl()
                }
                rp = rp.next
            }
        }
        ^^ir.Chunk c = s.chunks
        bool first = true
        while c != 0 {
            if first {
                if c.label == 0 or strings.compare(c.label, s.name) != 0 {
                    label(s.name)
                    carry_clear()
                }
                else
                    entry_pending = true
            }
            first = false
            chunk(c)
            c = c.next
        }
        if first
            label(s.name)
        line("rts")
        nl()
        this_sub = 0
        this_index = -1
        register_cells()
        if carry_cell {
            buf.add_str(cells, "p8c_")
            buf.add_long(cells, part)
            buf.add_str(cells, ":  rmb  1\n")
        }
        carry_cell = false
    }

    ; ---- the IR's carry ----
    ;
    ; The IR has a carry flag that only a compare, clc, sec and the shifts and rotations
    ; by one bit change, and that roxl, roxr, bstcc and bstcs read.  Mostly the reader comes
    ; straight after what set it, and the 6809's own carry serves (a load or a store
    ; leaves it alone).  A subroutine where it does not keeps the flag in a place of its
    ; own: clear at its start, as on the host, where each subroutine has its own flags;
    ; every instruction that sets it stores it there, and a reader takes it from there.
    ; The place holds the IR's carry, which after a compare is the other way round than
    ; the 6809's (the IR's is the 6502's: clear for "less").

    sub carry_setter(ubyte opc) -> bool {
        when opc {
            ir.OP_CMP, ir.OP_CMPI, ir.OP_CLC, ir.OP_SEC, ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_ROL, ir.OP_ROR,
            ir.OP_ROXL, ir.OP_ROXR, ir.OP_LSLM, ir.OP_LSRM, ir.OP_ASRM, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM -> return true
        }
        return false
    }

    sub carry_rotation(ubyte opc) -> bool {
        return opc == ir.OP_ROXL or opc == ir.OP_ROXR or opc == ir.OP_ROXLM or opc == ir.OP_ROXRM
    }

    ; does instruction i, after instruction before (or 0), find the carry it reads in the
    ; 6809's own?
    sub carry_at_hand(^^ir.Instr i, ^^ir.Instr before) -> bool {
        if before == 0 or not carry_setter(before.op)
            return false
        if carry_rotation(i.op) and (before.op == ir.OP_CMP or before.op == ir.OP_CMPI)
            return false
        return true
    }

    sub carry_scan(^^ir.Sub s) -> bool {
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            if c.kind != ir.C_ASM {
                ^^ir.Instr before = 0
                ^^ir.Instr i = c.first
                while i != 0 {
                    if (carry_rotation(i.op) or i.op == ir.OP_BSTCC or i.op == ir.OP_BSTCS) and not carry_at_hand(i, before)
                        return true
                    before = i
                    i = i.next
                }
            }
            c = c.next
        }
        return false
    }

    sub carry_place() {
        put("p8c_")
        putn(part)
    }

    sub carry_clear() {
        if carry_cell {
            op("clr")
            carry_place()
            nl()
        }
    }

    ; after an instruction that set the carry: into the place, with the flags and A as
    ; they were
    sub carry_save(ubyte opc) {
        line("pshs  cc,a")
        line("tfr  cc,a")
        if opc == ir.OP_CMP or opc == ir.OP_CMPI
            line("eora  #1")
        op("sta")
        carry_place()
        nl()
        line("puls  cc,a")
    }

    ; before an instruction that reads the carry: from the place, when it is not at hand
    sub carry_in(^^ir.Instr i) {
        carry_loaded = false
        if carry_cell and not carry_at_hand(i, previous) {
            op("lda")
            carry_place()
            nl()
            line("lsra")
            carry_loaded = true
        }
    }

    ; the places of the registers that the code just written names, for the end of the
    ; program
    sub register_cells() {
        uword r
        for r in 1 to ir.regcount {
            if reg_used[r] != 0 {
                reg_used[r] = 0
                buf.add_str(cells, "p8r_")
                buf.add_long(cells, part)
                buf.add_byte(cells, '_')
                buf.add_long(cells, r)
                buf.add_str(cells, ":  rmb  ")
                buf.add_long(cells, rsize(r))
                buf.add_byte(cells, '\n')
            }
        }
    }

    sub chunk(^^ir.Chunk c) {
        if c.label != 0
            label(c.label)
        if entry_pending {
            entry_pending = false
            carry_clear()
        }
        if c.kind == ir.C_ASM {
            if c.is_ir {
                ; (IR text of a block, outside any subroutine.  With nothing in it, as
                ; a block that only marks a place has, there is nothing to write.)
                long tk = 0
                while tk < c.textlen and (c.text[tk] == ' ' or c.text[tk] == '\n' or c.text[tk] == '\r' or c.text[tk] == '\t')
                    tk++
                if tk < c.textlen
                    error("IR text outside a subroutine cannot be used on the 6809", c.label)
            }
            else {
                ; 6809 assembly of the program's own (%asm), as it stands.  It names the
                ; program's variables as this generator writes them: an underscore, and
                ; two underscores for each dot (txt.plot.col is _txt__plot__col).
                raw(";%asm")
                buf.add_bytes(o, c.text, c.textlen)
                nl()
                raw(";%end")
                ; (what it leaves in the carry is not known)
                previous = 0
            }
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
            if carry_cell and carry_setter(i.op)
                carry_save(i.op)
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
        error("this instruction is not written for the 6809 yet", nb.data)
    }

    ; What an arithmetic instruction does, whatever its operands are: 0 add, 1 subtract,
    ; 2 and, 3 or, 4 xor, 5 multiply, 6 divide, 7 remainder, 8 signed divide, 9 signed
    ; remainder.
    sub kind_of(ubyte opc) -> ubyte {
        when opc {
            ir.OP_ADD, ir.OP_ADDR, ir.OP_ADDM, ir.OP_ADDIM -> return 0
            ir.OP_SUB, ir.OP_SUBR, ir.OP_SUBM, ir.OP_SUBIM -> return 1
            ir.OP_AND, ir.OP_ANDR, ir.OP_ANDM -> return 2
            ir.OP_OR, ir.OP_ORR, ir.OP_ORM -> return 3
            ir.OP_XOR, ir.OP_XORR, ir.OP_XORM -> return 4
            ir.OP_MUL, ir.OP_MULR, ir.OP_MULM, ir.OP_MULS, ir.OP_MULSR, ir.OP_MULSM -> return 5
            ir.OP_DIV, ir.OP_DIVR, ir.OP_DIVM, ir.OP_DIVMOD, ir.OP_DIVMODR -> return 6
            ir.OP_MOD, ir.OP_MODR -> return 7
            ir.OP_DIVS, ir.OP_DIVSR, ir.OP_DIVSM, ir.OP_SDIVMOD, ir.OP_SDIVMODR -> return 8
            ir.OP_MODS, ir.OP_MODSR -> return 9
        }
        return 255
    }

    ; The operands of an arithmetic instruction, by its group:
    ;   1  register r1 op= the immediate       2  register r1 op= register r2
    ;   3  memory op= register r1              4  memory op= the immediate
    ; "first" is what is changed, "second" the other one; k and w say which bytes of it.
    sub op_first(str mnemonic, ^^ir.Instr i, ubyte group, ubyte k, ubyte w, ubyte size) {
        if group <= 2
            op_cell(mnemonic, i.r1, k, w)
        else
            op_mem(mnemonic, i, k, w, size)
    }

    sub op_second(str mnemonic, ^^ir.Instr i, ubyte group, ubyte k, ubyte w) {
        when group {
            1, 4 -> {
                if w == 1
                    op_imm(mnemonic, ((i.value >> (k * 8)) as long) & 255)
                else
                    op_imm(mnemonic, ((i.value >> (k * 8)) as long) & $ffff)
            }
            2 -> op_cell(mnemonic, i.r2, k, w)
            else -> op_cell(mnemonic, i.r1, k, w)
        }
    }

    ; the instruction of an operation on A (high) or B: add, subtract, and, or, xor; with
    ; the carry for the bytes after the first of a sum or difference
    sub byte_op(ubyte kind, bool high, bool carry) -> str {
        when kind {
            0 -> {
                if carry {
                    if high
                        return "adca"
                    return "adcb"
                }
                if high
                    return "adda"
                return "addb"
            }
            1 -> {
                if carry {
                    if high
                        return "sbca"
                    return "sbcb"
                }
                if high
                    return "suba"
                return "subb"
            }
            2 -> {
                if high
                    return "anda"
                return "andb"
            }
            3 -> {
                if high
                    return "ora"
                return "orb"
            }
        }
        if high
            return "eora"
        return "eorb"
    }

    ; D = D / X, X = the remainder: the routine, signed or not
    sub divide(ubyte kind) {
        if kind >= 8 {
            line("jsr  p8rt_divs16")
            need_divs = true
        }
        else
            line("jsr  p8rt_div16")
        need_div = true
    }

    ; a byte in B made a word in D, by the kind of division
    sub widen(ubyte kind) {
        if kind >= 8
            line("sex")
        else
            line("clra")
    }

    ; the operands of a long multiplication or division into the cells of the routines
    sub long_cells(^^ir.Instr i, ubyte group) {
        op_first("ldd", i, group, 0, 2, 4)
        line("std  p8_la+2")
        op_first("ldd", i, group, 2, 2, 4)
        line("std  p8_la")
        op_second("ldd", i, group, 0, 2)
        line("std  p8_lb+2")
        op_second("ldd", i, group, 2, 2)
        line("std  p8_lb")
        need_long = true
    }

    ; the routine: the product and a remainder come in p8_lc, a quotient in p8_la
    sub long_call(ubyte kind) {
        if kind == 5 {
            line("jsr  p8rt_mul32")
            need_mul32 = true
        }
        else if kind >= 8 {
            line("jsr  p8rt_divs32")
            need_divs32 = true
            need_div32 = true
        }
        else {
            line("jsr  p8rt_div32")
            need_div32 = true
        }
    }

    ; an arithmetic instruction of any size
    sub arith(^^ir.Instr i, ubyte group) {
        ubyte size = size_of(i.type)
        ubyte kind = kind_of(i.op)
        ubyte half
        if size == 1 {
            if kind <= 4 {
                op_first("ldb", i, group, 0, 1, 1)
                op_second(byte_op(kind, false, false), i, group, 0, 1)
                op_first("stb", i, group, 0, 1, 1)
            }
            else if kind == 5 {
                ; (a byte product is the low byte of the product that the 6809 makes)
                op_first("lda", i, group, 0, 1, 1)
                op_second("ldb", i, group, 0, 1)
                line("mul")
                op_first("stb", i, group, 0, 1, 1)
            }
            else {
                op_second("ldb", i, group, 0, 1)
                widen(kind)
                line("tfr  d,x")
                op_first("ldb", i, group, 0, 1, 1)
                widen(kind)
                divide(kind)
                if kind == 7 or kind == 9
                    line("tfr  x,d")            ; (the remainder)
                op_first("stb", i, group, 0, 1, 1)
            }
        }
        else if size == 2 {
            if kind <= 1 {
                op_first("ldd", i, group, 0, 2, 2)
                if kind == 0
                    op_second("addd", i, group, 0, 2)
                else
                    op_second("subd", i, group, 0, 2)
                op_first("std", i, group, 0, 2, 2)
            }
            else if kind <= 4 {
                op_first("ldd", i, group, 0, 2, 2)
                op_second(byte_op(kind, true, false), i, group, 1, 1)
                op_second(byte_op(kind, false, false), i, group, 0, 1)
                op_first("std", i, group, 0, 2, 2)
            }
            else {
                op_second("ldx", i, group, 0, 2)
                op_first("ldd", i, group, 0, 2, 2)
                if kind == 5 {
                    line("jsr  p8rt_mul16")
                    need_mul = true
                }
                else {
                    divide(kind)
                    if kind == 7 or kind == 9
                        line("tfr  x,d")
                }
                op_first("std", i, group, 0, 2, 2)
            }
        }
        else if size == 4 {
            if kind <= 1 {
                ; A long sum or difference: the low words, then the high words with
                ; the carry (no load or store between them changes it).
                op_first("ldd", i, group, 0, 2, 4)
                if kind == 0
                    op_second("addd", i, group, 0, 2)
                else
                    op_second("subd", i, group, 0, 2)
                op_first("std", i, group, 0, 2, 4)
                op_first("ldd", i, group, 2, 2, 4)
                op_second(byte_op(kind, false, true), i, group, 2, 1)
                op_second(byte_op(kind, true, true), i, group, 3, 1)
                op_first("std", i, group, 2, 2, 4)
            }
            else if kind <= 4 {
                for half in 0 to 1 {
                    op_first("ldd", i, group, half * 2, 2, 4)
                    op_second(byte_op(kind, true, false), i, group, half * 2 + 1, 1)
                    op_second(byte_op(kind, false, false), i, group, half * 2, 1)
                    op_first("std", i, group, half * 2, 2, 4)
                }
            }
            else {
                long_cells(i, group)
                long_call(kind)
                if kind == 6 or kind == 8 {
                    line("ldd  p8_la+2")
                    op_first("std", i, group, 0, 2, 4)
                    line("ldd  p8_la")
                    op_first("std", i, group, 2, 2, 4)
                }
                else {
                    line("ldd  p8_lc+2")
                    op_first("std", i, group, 0, 2, 4)
                    line("ldd  p8_lc")
                    op_first("std", i, group, 2, 2, 4)
                }
            }
        }
        else
            unsupported(i)
    }

    ; r1 = r1 / the second operand, r2 = the remainder
    sub quotient_and_rest(^^ir.Instr i) {
        ubyte size = size_of(i.type)
        ubyte kind = kind_of(i.op)
        ubyte group = 2
        if i.op == ir.OP_DIVMOD or i.op == ir.OP_SDIVMOD
            group = 1
        if size == 1 {
            op_second("ldb", i, group, 0, 1)
            widen(kind)
            line("tfr  d,x")
            op_cell("ldb", i.r1, 0, 1)
            widen(kind)
            divide(kind)
            op_cell("stb", i.r1, 0, 1)
            line("tfr  x,d")
            op_cell("stb", i.r2, 0, 1)
        }
        else if size == 2 {
            op_second("ldx", i, group, 0, 2)
            op_cell("ldd", i.r1, 0, 2)
            divide(kind)
            op_cell("std", i.r1, 0, 2)
            op_cell("stx", i.r2, 0, 2)
        }
        else if size == 4 {
            long_cells(i, group)
            long_call(kind)
            line("ldd  p8_la+2")
            op_cell("std", i.r1, 0, 2)
            line("ldd  p8_la")
            op_cell("std", i.r1, 2, 2)
            line("ldd  p8_lc+2")
            op_cell("std", i.r2, 0, 2)
            line("ldd  p8_lc")
            op_cell("std", i.r2, 2, 2)
        }
        else
            unsupported(i)
    }

    ; first = -first
    sub negate(^^ir.Instr i, ubyte group, ubyte size) {
        if size == 1 {
            op_first("neg", i, group, 0, 1, 1)
            return
        }
        line("ldd  #0")
        op_first("subd", i, group, 0, 2, size)
        op_first("std", i, group, 0, 2, size)
        if size == 4 {
            line("ldd  #0")
            op_first("sbcb", i, group, 2, 1, 4)
            op_first("sbca", i, group, 3, 1, 4)
            op_first("std", i, group, 2, 2, 4)
        }
    }

    ; first += 1 or -= 1, a long
    sub step_long(^^ir.Instr i, ubyte group, bool up) {
        op_first("ldd", i, group, 0, 2, 4)
        if up
            line("addd  #1")
        else
            line("subd  #1")
        op_first("std", i, group, 0, 2, 4)
        op_first("ldd", i, group, 2, 2, 4)
        if up {
            line("adcb  #0")
            line("adca  #0")
        }
        else {
            line("sbcb  #0")
            line("sbca  #0")
        }
        op_first("std", i, group, 2, 2, 4)
    }

    ; zero or not: the flags of a long that is first
    sub long_zero_flags(^^ir.Instr i, ubyte group) {
        long skip = new_label()
        op_first("ldd", i, group, 2, 2, 4)
        jump_if_local("bne", skip)
        op_first("ldd", i, group, 0, 2, 4)
        local(skip)
    }

    ; A long compare, unsigned: r1 against r2 or the immediate.  It leaves what the short
    ; ones leave: carry is "less", zero is "equal".
    sub long_compare(^^ir.Instr i, bool with_register) {
        ubyte group = 1
        if with_register
            group = 2
        long skip = new_label()
        op_cell("ldd", i.r1, 2, 2)
        op_second("cmpd", i, group, 2, 2)
        jump_if_local("bne", skip)
        op_cell("ldd", i.r1, 0, 2)
        op_second("cmpd", i, group, 0, 2)
        local(skip)
    }

    ; Does what follows instruction i read the flags it leaves?  A branch on the status
    ; as the next instruction does, and so may whatever comes after the end of the chunk.
    sub flags_wanted(^^ir.Instr i) -> bool {
        if i.next == 0
            return true
        when i.next.op {
            ir.OP_BSTEQ, ir.OP_BSTNE, ir.OP_BSTNEG, ir.OP_BSTPOS -> return true
        }
        return false
    }

    ; flags for the branch that follows: the value of register r as it is (zero or not;
    ; for the sign, its top byte)
    sub test_reg(uword r, ubyte size, bool sign) {
        if size == 0
            return
        if sign or size == 1
            op_cell("tst", r, size - 1, 1)
        else if size == 2
            op_cell("ldd", r, 0, 2)
        else {
            long skip = new_label()
            op_cell("ldd", r, 2, 2)
            jump_if_local("bne", skip)
            op_cell("ldd", r, 0, 2)
            local(skip)
        }
    }

    ; Is the flag state that a status branch needs what the instruction before left?  A
    ; compare leaves it; after anything else that gave a register its value, the value is
    ; tested again here.
    sub flags_for_branch(bool sign) {
        if previous == 0
            return
        if sign and previous.op == ir.OP_CMPI and previous.value == 0 {
            ; (a compare with 0 and then the sign: the value's own)
            test_reg(previous.r1, size_of(type1(previous)), true)
            return
        }
        when previous.op {
            ir.OP_LOAD, ir.OP_LOADM, ir.OP_LOADMZ, ir.OP_LOADR, ir.OP_LOADI, ir.OP_LOADX, ir.OP_STOREM, ir.OP_STOREI,
            ir.OP_STOREX, ir.OP_LOADHR, ir.OP_LSIGB, ir.OP_LSIGW, ir.OP_MSIGB, ir.OP_MSIGW, ir.OP_EXT, ir.OP_EXTS, ir.OP_EXTL, ir.OP_EXTLS,
            ir.OP_CONCAT, ir.OP_INC, ir.OP_DEC, ir.OP_NEG, ir.OP_INV, ir.OP_SGN, ir.OP_POP,
            ir.OP_ADD, ir.OP_SUB, ir.OP_AND, ir.OP_OR, ir.OP_XOR, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_DIVS, ir.OP_MOD, ir.OP_MODS,
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_ANDR, ir.OP_ORR, ir.OP_XORR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR,
            ir.OP_MODR, ir.OP_MODSR, ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI,
            ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN -> {
                if previous.r1 != 0 and previous.mode != ir.M_IM
                    test_reg(previous.r1, rsize(previous.r1), sign)
            }
        }
    }

    ; "    bcc  target": the assembler takes the long form where the short one does not reach
    sub jump_if(str branch, ^^ubyte target_name) {
        op(branch)
        name(target_name)
        nl()
    }

    sub jump_if_local(str branch, long n) {
        op(branch)
        put_local(n)
        nl()
    }

    ; first operand of a compare into B or D, compared with the second
    sub compare_operands(^^ir.Instr i, ubyte size, bool with_register) {
        ubyte group = 1
        if with_register
            group = 2
        if size == 1 {
            op_cell("ldb", i.r1, 0, 1)
            op_second("cmpb", i, group, 0, 1)
        }
        else {
            op_cell("ldd", i.r1, 0, 2)
            op_second("cmpd", i, group, 0, 2)
        }
    }

    ; the branch of a relation (0 greater, 1 less, 2 greater or equal, 3 less or equal)
    sub relation_branch(ubyte relation, bool signed) -> str {
        if signed {
            when relation {
                0 -> return "bgt"
                1 -> return "blt"
                2 -> return "bge"
            }
            return "ble"
        }
        when relation {
            0 -> return "bhi"
            1 -> return "blo"
            2 -> return "bhs"
        }
        return "bls"
    }

    ; a compare and a branch
    sub compare_branch(^^ir.Instr i, bool with_register, bool signed, ubyte relation) {
        ubyte size = size_of(type1(i))
        if size == 1 or size == 2 {
            compare_operands(i, size, with_register)
            jump_if(relation_branch(relation, signed), i.sym)
        }
        else if size == 4 and not signed {
            long_compare(i, with_register)
            jump_if(relation_branch(relation, false), i.sym)
        }
        else if size == 4 {
            ; signed longs: the high words decide by their sign unless they are the
            ; same; then the low words do, which have no sign
            ubyte group = 1
            if with_register
                group = 2
            long skip = new_label()
            op_cell("ldd", i.r1, 2, 2)
            op_second("cmpd", i, group, 2, 2)
            if relation == 0 or relation == 2
                jump_if("bgt", i.sym)
            else
                jump_if("blt", i.sym)
            jump_if_local("bne", skip)
            op_cell("ldd", i.r1, 0, 2)
            op_second("cmpd", i, group, 0, 2)
            jump_if(relation_branch(relation, false), i.sym)
            local(skip)
        }
        else
            unsupported(i)
    }

    sub instruction(^^ir.Instr i) {
        ubyte size = size_of(i.type)
        ubyte k
        if i.type == ir.T_FLOAT or (i.op >= ir.OP_FFROMUB and i.op <= ir.OP_FCOMP) or (i.op >= ir.OP_FPOW and i.op <= ir.OP_FCEIL) {
            if not uses_floats
                error("floats are not there on the 6809 yet", 0)
            uses_floats = true
            return
        }
        when i.op {
            ir.OP_NOP, ir.OP_BREAKPOINT, ir.OP_ALIGN -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0 {
                    op("ldd")
                    put("#")
                    mem_name(i, 0, 0)
                    nl()
                    op_cell("std", i.r1, 0, 2)
                }
                else if size == 1 {
                    if (i.value as long) & 255 == 0
                        op_cell("clr", i.r1, 0, 1)
                    else {
                        op_imm("ldb", (i.value as long) & 255)
                        op_cell("stb", i.r1, 0, 1)
                    }
                }
                else if size == 2 {
                    op_imm("ldd", (i.value as long) & $ffff)
                    op_cell("std", i.r1, 0, 2)
                }
                else if size == 4 {
                    op_imm("ldd", (i.value as long) & $ffff)
                    op_cell("std", i.r1, 0, 2)
                    if ((i.value >> 16) & $ffff) != (i.value & $ffff)
                        op_imm("ldd", ((i.value >> 16) as long) & $ffff)
                    op_cell("std", i.r1, 2, 2)
                }
                else
                    unsupported(i)
            }
            ir.OP_LOADM -> {
                if size == 1 {
                    op_mem("ldb", i, 0, 1, 1)
                    op_cell("stb", i.r1, 0, 1)
                }
                else if size == 2 {
                    op_mem("ldd", i, 0, 2, 2)
                    op_cell("std", i.r1, 0, 2)
                }
                else if size == 4 {
                    op_mem("ldd", i, 0, 2, 4)
                    op_cell("std", i.r1, 0, 2)
                    op_mem("ldd", i, 2, 2, 4)
                    op_cell("std", i.r1, 2, 2)
                }
                else
                    unsupported(i)
            }
            ir.OP_LOADMZ -> {
                ; a byte from memory into a wider register, the rest zero
                op_mem("ldb", i, 0, 1, 1)
                op_cell("stb", i.r1, 0, 1)
                for k in 1 to rsize(i.r1) - 1
                    op_cell("clr", i.r1, k, 1)
            }
            ir.OP_LOADR -> {
                if size == 0
                    unsupported(i)
                else
                    copy_reg(i.r1, i.r2, size)
            }
            ir.OP_LOADX -> {
                if size == 0
                    unsupported(i)
                else {
                    x_address(i, true)
                    reg_from_x(i.r1, 0, size)
                }
            }
            ir.OP_LOADI -> {
                if size == 0
                    unsupported(i)
                else {
                    x_pointer(i)
                    reg_from_x(i.r1, i.offset, size)
                }
            }
            ir.OP_LOADHR, ir.OP_STOREHR -> {
                if size == 0 or i.slot >= ir.SLOT_FLAGS {
                    unsupported(i)
                    return
                }
                for k in 0 to size - 1 {
                    if i.op == ir.OP_LOADHR {
                        op_slot("lda", i.slot, k, 1)
                        op_cell("sta", i.r1, k, 1)
                    }
                    else {
                        op_cell("lda", i.r1, k, 1)
                        op_slot("sta", i.slot, k, 1)
                    }
                }
            }
            ir.OP_STOREM -> {
                if size == 1 {
                    op_cell("ldb", i.r1, 0, 1)
                    op_mem("stb", i, 0, 1, 1)
                }
                else if size == 2 {
                    op_cell("ldd", i.r1, 0, 2)
                    op_mem("std", i, 0, 2, 2)
                }
                else if size == 4 {
                    op_cell("ldd", i.r1, 0, 2)
                    op_mem("std", i, 0, 2, 4)
                    op_cell("ldd", i.r1, 2, 2)
                    op_mem("std", i, 2, 2, 4)
                }
                else
                    unsupported(i)
            }
            ir.OP_STOREZM -> {
                if size == 0
                    unsupported(i)
                else if size == 1
                    op_mem("clr", i, 0, 1, 1)
                else {
                    line("ldd  #0")
                    op_mem("std", i, 0, 2, size)
                    if size == 4
                        op_mem("std", i, 2, 2, 4)
                }
            }
            ir.OP_STOREIM -> {
                if size == 0
                    unsupported(i)
                else if size == 1 {
                    if (i.value as long) & 255 == 0
                        op_mem("clr", i, 0, 1, 1)
                    else {
                        op_imm("ldb", (i.value as long) & 255)
                        op_mem("stb", i, 0, 1, 1)
                    }
                }
                else {
                    op_imm("ldd", (i.value as long) & $ffff)
                    op_mem("std", i, 0, 2, size)
                    if size == 4 {
                        if ((i.value >> 16) & $ffff) != (i.value & $ffff)
                            op_imm("ldd", ((i.value >> 16) as long) & $ffff)
                        op_mem("std", i, 2, 2, 4)
                    }
                }
            }
            ir.OP_STOREX -> {
                if size == 0
                    unsupported(i)
                else {
                    x_address(i, true)
                    x_from_reg(i.r1, 0, size)
                }
            }
            ir.OP_STOREZX -> {
                if size == 0
                    unsupported(i)
                else {
                    x_address(i, true)
                    for k in 0 to size - 1
                        op_x("clr", 0, k, 1, size)
                }
            }
            ir.OP_STOREI -> {
                if size == 0
                    unsupported(i)
                else {
                    x_pointer(i)
                    x_from_reg(i.r1, i.offset, size)
                }
            }
            ir.OP_STOREZI -> {
                if size == 0
                    unsupported(i)
                else {
                    x_pointer(i)
                    for k in 0 to size - 1
                        op_x("clr", i.offset, k, 1, size)
                }
            }
            ir.OP_JUMP -> jump_if("bra", i.sym)
            ir.OP_JUMPI -> {
                op_cell("ldx", i.r1, 0, 2)
                line("jmp  ,x")
            }
            ir.OP_CALL -> call_instruction(i)
            ir.OP_CALLI -> {
                op_cell("ldx", i.r1, 0, 2)
                line("jsr  ,x")
                ; (what it returns is taken from slot 10 by the code that follows: a byte
                ; comes in B, the low half of D)
                op_slot("std", 10, 0, 2)
                op_slot("stx", 10, 2, 2)
            }
            ir.OP_SYSCALL -> syscall(i)
            ir.OP_RETURN -> line("rts")
            ir.OP_RETURNR -> {
                if size != 0 {
                    fetch(i.r1, size)
                    line("rts")
                }
                else
                    unsupported(i)
            }
            ir.OP_RETURNI -> {
                if size == 1
                    op_imm("ldb", (i.value as long) & 255)
                else if size == 2
                    op_imm("ldd", (i.value as long) & $ffff)
                else if size == 4 {
                    op_imm("ldd", (i.value as long) & $ffff)
                    op_imm("ldx", ((i.value >> 16) as long) & $ffff)
                }
                else
                    unsupported(i)
                line("rts")
            }
            ir.OP_BSTEQ -> {
                flags_for_branch(false)
                jump_if("beq", i.sym)
            }
            ir.OP_BSTNE -> {
                flags_for_branch(false)
                jump_if("bne", i.sym)
            }
            ir.OP_BSTNEG -> {
                flags_for_branch(true)
                jump_if("bmi", i.sym)
            }
            ir.OP_BSTPOS -> {
                flags_for_branch(true)
                jump_if("bpl", i.sym)
            }
            ; (the IR's carry is the 6502's: clear after a compare means "less".  A compare
            ; here leaves the 6809's, which is set then.)
            ir.OP_BSTCC -> {
                carry_in(i)
                if not carry_loaded and previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("bcs", i.sym)
                else
                    jump_if("bcc", i.sym)
            }
            ir.OP_BSTCS -> {
                carry_in(i)
                if not carry_loaded and previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("bcc", i.sym)
                else
                    jump_if("bcs", i.sym)
            }
            ir.OP_CMP -> {
                if size == 1 or size == 2
                    compare_operands(i, size, true)
                else if size == 4
                    long_compare(i, true)
                else
                    unsupported(i)
            }
            ir.OP_CMPI -> {
                if size == 1 or size == 2
                    compare_operands(i, size, false)
                else if size == 4
                    long_compare(i, false)
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
            ir.OP_INC, ir.OP_DEC, ir.OP_INCM, ir.OP_DECM -> {
                ubyte where = 1
                if i.op == ir.OP_INCM or i.op == ir.OP_DECM
                    where = 3
                bool up = i.op == ir.OP_INC or i.op == ir.OP_INCM
                if size == 1 {
                    if up
                        op_first("inc", i, where, 0, 1, 1)
                    else
                        op_first("dec", i, where, 0, 1, 1)
                }
                else if size == 2 {
                    ; (through X: its sum leaves the zero flag, and the store the sign)
                    op_first("ldx", i, where, 0, 2, 2)
                    if up
                        line("leax  1,x")
                    else
                        line("leax  -1,x")
                    op_first("stx", i, where, 0, 2, 2)
                }
                else if size == 4 {
                    step_long(i, where, up)
                    if where == 3 and flags_wanted(i)
                        long_zero_flags(i, where)
                }
                else
                    unsupported(i)
            }
            ir.OP_ADD, ir.OP_SUB, ir.OP_AND, ir.OP_OR, ir.OP_XOR, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_DIVS,
            ir.OP_MOD, ir.OP_MODS -> arith(i, 1)
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_ANDR, ir.OP_ORR, ir.OP_XORR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR,
            ir.OP_MODR, ir.OP_MODSR -> arith(i, 2)
            ir.OP_ADDM, ir.OP_SUBM, ir.OP_ANDM, ir.OP_ORM, ir.OP_XORM, ir.OP_MULM, ir.OP_MULSM, ir.OP_DIVM,
            ir.OP_DIVSM -> arith(i, 3)
            ir.OP_ADDIM, ir.OP_SUBIM -> arith(i, 4)
            ir.OP_DIVMOD, ir.OP_DIVMODR, ir.OP_SDIVMOD, ir.OP_SDIVMODR -> quotient_and_rest(i)
            ir.OP_NEG -> {
                if size == 0
                    unsupported(i)
                else
                    negate(i, 1, size)
            }
            ir.OP_NEGM -> {
                if size == 0
                    unsupported(i)
                else
                    negate(i, 3, size)
            }
            ir.OP_INV, ir.OP_INVM -> {
                ubyte place = 1
                if i.op == ir.OP_INVM
                    place = 3
                if size == 0
                    unsupported(i)
                else for k in 0 to size - 1
                    op_first("com", i, place, k, 1, size)
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = the sign of r2: -1, 0 or 1
                if size == 0 {
                    unsupported(i)
                    return
                }
                long done = new_label()
                line("ldb  #255")
                op_cell("tst", i.r2, size - 1, 1)
                jump_if_local("bmi", done)
                line("ldb  #1")
                for k in 0 to size - 1 {
                    op_cell("tst", i.r2, k, 1)
                    jump_if_local("bne", done)
                }
                line("clrb")
                local(done)
                op_cell("stb", i.r1, 0, 1)
            }
            ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_ROL, ir.OP_ROR, ir.OP_ROXL, ir.OP_ROXR -> shift_register(i, 1, size, 1)
            ir.OP_LSLM, ir.OP_LSRM, ir.OP_ASRM, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM -> shift_register(i, 1, size, 3)
            ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI -> shift_register(i, (i.value & 255) as ubyte, size, 1)
            ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN, ir.OP_LSLNM, ir.OP_LSRNM, ir.OP_ASRNM -> {
                ; by the number in a register (r2; r1 when memory is shifted): one bit at a
                ; time, in memory, with the count in A
                if size == 0 {
                    unsupported(i)
                    return
                }
                long again = new_label()
                long over = new_label()
                ubyte spot = 1
                if i.op == ir.OP_LSLNM or i.op == ir.OP_LSRNM or i.op == ir.OP_ASRNM {
                    spot = 3
                    op_cell("lda", i.r1, 0, 1)
                }
                else
                    op_cell("lda", i.r2, 0, 1)
                jump_if_local("beq", over)
                local(again)
                shift_once(i.op, i, spot, size)
                line("deca")
                jump_if_local("bne", again)
                local(over)
            }
            ir.OP_EXT, ir.OP_EXTS, ir.OP_EXTL, ir.OP_EXTLS -> {
                ; r1 (a wider type) = r2 (the instruction's type)
                ubyte wide = rsize(i.r1)
                if size == 0 or wide <= size {
                    unsupported(i)
                    return
                }
                bool signed = i.op == ir.OP_EXTS or i.op == ir.OP_EXTLS
                if size == 1 and wide == 2 {
                    op_cell("ldb", i.r2, 0, 1)
                    if signed
                        line("sex")
                    else
                        line("clra")
                    op_cell("std", i.r1, 0, 2)
                    return
                }
                for k in 0 to size - 1 {
                    op_cell("lda", i.r2, k, 1)
                    op_cell("sta", i.r1, k, 1)
                }
                if signed {
                    ; (all ones when the top byte is negative)
                    op_cell("ldb", i.r2, size - 1, 1)
                    line("sex")
                }
                else
                    line("clra")
                for k in size to wide - 1
                    op_cell("sta", i.r1, k, 1)
            }
            ir.OP_LSIGB, ir.OP_LSIGW -> {
                ; the low byte (word) of r2
                ubyte low = 1
                if i.op == ir.OP_LSIGW
                    low = 2
                for k in 0 to low - 1 {
                    op_cell("lda", i.r2, k, 1)
                    op_cell("sta", i.r1, k, 1)
                }
            }
            ir.OP_MSIGB -> {
                ; the high byte of r2, which is of the instruction's type
                op_cell("lda", i.r2, size - 1, 1)
                op_cell("sta", i.r1, 0, 1)
            }
            ir.OP_MSIGW -> {
                op_cell("ldd", i.r2, 2, 2)
                op_cell("std", i.r1, 0, 2)
            }
            ir.OP_CONCAT -> {
                ; r1 = r2 (the high half) and r3 (the low half), each of the instruction's type
                if size == 1 or size == 2 {
                    for k in 0 to size - 1 {
                        op_cell("lda", i.r3, k, 1)
                        op_cell("sta", i.r1, k, 1)
                        op_cell("lda", i.r2, k, 1)
                        op_cell("sta", i.r1, size + k, 1)
                    }
                }
                else
                    unsupported(i)
            }
            ir.OP_PUSH -> {
                if size == 1 {
                    op_cell("ldb", i.r1, 0, 1)
                    line("pshs  b")
                }
                else if size == 2 or size == 4 {
                    op_cell("ldd", i.r1, 0, 2)
                    line("pshs  d")
                    if size == 4 {
                        op_cell("ldd", i.r1, 2, 2)
                        line("pshs  d")
                    }
                }
                else
                    unsupported(i)
            }
            ir.OP_POP -> {
                if size == 1 {
                    line("puls  b")
                    op_cell("stb", i.r1, 0, 1)
                }
                else if size == 2 {
                    line("puls  d")
                    op_cell("std", i.r1, 0, 2)
                }
                else if size == 4 {
                    line("puls  d")
                    op_cell("std", i.r1, 2, 2)
                    line("puls  d")
                    op_cell("std", i.r1, 0, 2)
                }
                else
                    unsupported(i)
            }
            ir.OP_SQRT -> {
                ; r1 = the square root of r2 (a whole number, rounded down)
                if size == 0 {
                    unsupported(i)
                    return
                }
                for k in 0 to 3 {
                    if k < size
                        op_cell("lda", i.r2, k, 1)
                    else if k == size
                        line("clra")
                    op("sta")
                    put("p8_la+")
                    putn(3 - k)
                    nl()
                }
                line("jsr  p8rt_sqrt32")
                need_rt[RT_SQRT] = true
                need_long = true
                op_cell("stb", i.r1, 0, 1)
                if rsize(i.r1) >= 2
                    op_cell("sta", i.r1, 1, 1)
            }
            ; (the IR's names are the 6502's: sei stops the interrupts, cli lets them come)
            ir.OP_SEI -> line("orcc  #$50")
            ir.OP_CLI -> line("andcc  #$af")
            ir.OP_CLC -> line("andcc  #$fe")
            ir.OP_SEC -> line("orcc  #1")
            else -> unsupported(i)
        }
    }

    ; One shift or rotation by one bit, in memory: of register r1 (place 1) or of the
    ; instruction's memory operand (place 3).  The bit that leaves is in the carry.
    sub shift_once(ubyte opc, ^^ir.Instr i, ubyte place, ubyte size) {
        ubyte k
        bool through = opc == ir.OP_ROXL or opc == ir.OP_ROXLM or opc == ir.OP_ROXR or opc == ir.OP_ROXRM
        bool around = opc == ir.OP_ROL or opc == ir.OP_ROLM or opc == ir.OP_ROR or opc == ir.OP_RORM
        bool left = false
        when opc {
            ir.OP_LSL, ir.OP_LSLI, ir.OP_LSLN, ir.OP_LSLM, ir.OP_LSLNM, ir.OP_ROL, ir.OP_ROLM, ir.OP_ROXL, ir.OP_ROXLM -> left = true
        }
        long skip = 0
        if left {
            for k in 0 to size - 1 {
                if k == 0 and not through
                    op_first("lsl", i, place, k, 1, size)
                else
                    op_first("rol", i, place, k, 1, size)
            }
            if around {
                ; (the bit that left comes in at the other end; the carry stays)
                skip = new_label()
                jump_if_local("bcc", skip)
                op_first("inc", i, place, 0, 1, size)
                local(skip)
            }
        }
        else {
            k = size
            while k != 0 {
                k--
                if k == size - 1 and not through {
                    if opc == ir.OP_ASR or opc == ir.OP_ASRI or opc == ir.OP_ASRN or opc == ir.OP_ASRM or opc == ir.OP_ASRNM
                        op_first("asr", i, place, k, 1, size)
                    else
                        op_first("lsr", i, place, k, 1, size)
                }
                else
                    op_first("ror", i, place, k, 1, size)
            }
            if around {
                skip = new_label()
                jump_if_local("bcc", skip)
                line("pshs  a")
                op_first("lda", i, place, size - 1, 1, size)
                line("ora  #$80")
                op_first("sta", i, place, size - 1, 1, size)
                line("puls  a")
                local(skip)
            }
        }
    }

    sub shift_register(^^ir.Instr i, ubyte count, ubyte size, ubyte place) {
        if size == 0 {
            unsupported(i)
            return
        }
        if carry_rotation(i.op)
            carry_in(i)
        bool rotation = false
        when i.op {
            ir.OP_ROL, ir.OP_ROR, ir.OP_ROXL, ir.OP_ROXR, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM -> rotation = true
        }
        if size <= 2 and not rotation and count > 1 {
            ; (several bits: in B or D; the last bit out is in the carry, as the IR has it)
            bool left = i.op == ir.OP_LSL or i.op == ir.OP_LSLI or i.op == ir.OP_LSLM
            bool arithmetic = i.op == ir.OP_ASR or i.op == ir.OP_ASRI or i.op == ir.OP_ASRM
            if size == 1
                op_first("ldb", i, place, 0, 1, 1)
            else
                op_first("ldd", i, place, 0, 2, 2)
            repeat count {
                if left {
                    line("lslb")
                    if size == 2
                        line("rola")
                }
                else if size == 1 {
                    if arithmetic
                        line("asrb")
                    else
                        line("lsrb")
                }
                else {
                    if arithmetic
                        line("asra")
                    else
                        line("lsra")
                    line("rorb")
                }
            }
            if size == 1
                op_first("stb", i, place, 0, 1, 1)
            else
                op_first("std", i, place, 0, 2, 2)
            return
        }
        repeat count
            shift_once(i.op, i, place, size)
    }

    ; ---- calls ----

    ; the subroutine of a name, or 0
    sub sub_named(^^ubyte wanted) -> ^^ir.Sub {
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                if strings.compare(s.name, wanted) == 0
                    return s
                s = s.next
            }
            bl = bl.next
        }
        return 0
    }

    ; Parameters in registers.  From the last parameter back: the first byte found is
    ; passed in B, the first word in X, the next word in U.  A call that has all of
    ; them comes in at "p8e_name", where they are stored.  (The name itself stays the way
    ; in for everything that has stored the arguments: a call through a pointer, a jump,
    ; assembly.)
    ; Where the parameter is passed: 0 in its variable, 1 B, 2 X, 3 U.
    sub param_register(^^ir.Sub s, ^^ir.Param want) -> ubyte {
        if not optimize or s == 0 or s.is_external
            return 0
        ; (from the end: so count them, then take the last, the one before it ...)
        ubyte total = 0
        ^^ir.Param p = s.params
        while p != 0 {
            total++
            p = p.next
        }
        bool b_free = true
        bool x_free = true
        bool u_free = true
        while total != 0 {
            p = s.params
            ubyte k = 1
            while k < total {
                p = p.next
                k++
            }
            ubyte where = 0
            if p.name != 0 and p.typestr != 0 and not text_has(p.typestr, "[") and not text_has(p.typestr, "float")
                    and struct_of(p.typestr) == 0 {
                ubyte psize = element_size(p.typestr)
                if psize == 1 and b_free {
                    where = 1
                    b_free = false
                }
                else if psize == 2 and x_free {
                    where = 2
                    x_free = false
                }
                else if psize == 2 and u_free {
                    where = 3
                    u_free = false
                }
            }
            if p == want
                return where
            total--
        }
        return 0
    }

    ; how many parameters are passed in registers
    sub register_params(^^ir.Sub s) -> ubyte {
        ubyte n = 0
        if s == 0
            return 0
        ^^ir.Param p = s.params
        while p != 0 {
            if param_register(s, p) != 0
                n++
            p = p.next
        }
        return n
    }

    ; the parameter that the argument is for (the argument's name may be without its
    ; scope), or 0
    sub param_of(^^ir.Sub s, ^^ir.Arg a) -> ^^ir.Param {
        if s == 0 or a.name == 0
            return 0
        long an = strings.length(a.name)
        ^^ir.Param p = s.params
        while p != 0 {
            if p.name != 0 and p.typestr != 0 and size_of(a.type) == element_size(p.typestr) {
                long pn = strings.length(p.name)
                if an <= pn and strings.compare(p.name + (pn - an), a.name) == 0 and (an == pn or p.name[pn - an - 1] == '.')
                    return p
            }
            p = p.next
        }
        return 0
    }

    ; where the argument of a call to s is passed (as param_register)
    sub arg_register(^^ir.Sub s, ^^ir.Arg a) -> ubyte {
        ^^ir.Param p = param_of(s, a)
        if p == 0
            return 0
        return param_register(s, p)
    }

    ; "    mnemonic  " and an argument: bytes k and up (w of them) of its register, or of
    ; its constant
    sub op_arg(str mnemonic, ^^ir.Arg a, ubyte k, ubyte w) {
        if a.reg != 0
            op_cell(mnemonic, a.reg, k, w)
        else if w == 1
            op_imm(mnemonic, ((a.value >> (k * 8)) as long) & 255)
        else
            op_imm(mnemonic, ((a.value >> (k * 8)) as long) & $ffff)
    }

    ; A call: the arguments into the subroutine's parameters, by their names; a result
    ; comes back in B, D, or X and D.
    sub call_instruction(^^ir.Instr i) {
        ^^ir.Sub callee = sub_named(i.sym)
        if callee != 0 and callee.is_external {
            error("a routine outside the program (extsub) cannot be called on the 6809 yet", i.sym)
            return
        }
        ; (a call that can come back into this subroutine: its variables are kept on
        ; the stack over it)
        long callee_index = index_of(i.sym)
        bool comes_back = this_index >= 0 and callee_index >= 0 and reaches[callee_index * sub_count + this_index] != 0
        long kept_from = 0
        if comes_back
            kept_from = save_own(i)
        ; (in registers when the call has an argument for every parameter that is
        ; passed so)
        bool by_register = false
        ubyte in_registers = 0
        ^^ir.Arg a = i.args
        while a != 0 {
            if arg_register(callee, a) != 0
                in_registers++
            a = a.next
        }
        if in_registers != 0 and in_registers == register_params(callee)
            by_register = true
        a = i.args
        while a != 0 {
            ubyte size = size_of(a.type)
            if a.name == 0 or size == 0 or size > 4 {
                error("the arguments of this call cannot be passed on the 6809 yet", i.sym)
                return
            }
            ubyte k = 0
            if by_register and arg_register(callee, a) != 0
                k = size            ; (loaded last, below)
            while k < size {
                ; (a word at a time where there is one, else a byte)
                ubyte w = 1
                if size - k >= 2
                    w = 2
                if w == 2
                    op_arg("ldd", a, k, 2)
                else
                    op_arg("ldb", a, k, 1)
                if w == 2
                    op("std")
                else
                    op("stb")
                ; (the parameter: a variable of the subroutine, named there without its scope)
                if not text_has(a.name, ".") {
                    name(i.sym)
                    put("__")
                    put(a.name)
                }
                else
                    name(a.name)
                if size - k - w != 0 {
                    put("+")
                    putn(size - k - w)
                }
                nl()
                k += w
            }
            a = a.next
        }
        if by_register {
            a = i.args
            while a != 0 {
                when arg_register(callee, a) {
                    1 -> op_arg("ldb", a, 0, 1)
                    2 -> op_arg("ldx", a, 0, 2)
                    3 -> op_arg("ldu", a, 0, 2)
                }
                a = a.next
            }
        }
        op("jsr")
        if by_register
            put("p8e")
        name(i.sym)
        nl()
        ^^ir.Arg r = i.results
        if r != 0 {
            ubyte result_size = size_of(r.type)
            if r.next != 0 or r.reg == 0 or result_size == 0 {
                error("the results of this call cannot be taken on the 6809 yet", i.sym)
                return
            }
            keep(r.reg, result_size)
        }
        if comes_back
            restore_own(kept_from)
    }

    ; ---- recursion ----

    sub index_of(^^ubyte wanted) -> long {
        long k = 0
        while k < sub_count {
            ^^ir.Sub s = all_subs[k] as ^^ir.Sub
            if strings.compare(s.name, wanted) == 0
                return k
            k++
        }
        return -1
    }

    ; Which subroutine's code can come to call which: first who calls whom, from the
    ; instructions, then everything that follows from that.  (A call through a pointer
    ; is not followed: where it goes is not known here.)
    sub call_graph() {
        sub_count = 0
        ^^ir.Block bl = prog.blocks
        while bl != 0 {
            ^^ir.Sub s = bl.subs
            while s != 0 {
                sub_count++
                s = s.next
            }
            bl = bl.next
        }
        if sub_count == 0
            return
        all_subs = mem.alloc(sub_count * sizeof(pointer))
        reaches = mem.alloc(sub_count * sub_count)
        long k = 0
        bl = prog.blocks
        while bl != 0 {
            s = bl.subs
            while s != 0 {
                all_subs[k] = s
                k++
                ; (IR text of the subroutine becomes instructions now, so that its
                ; calls are seen)
                if not s.is_external and not (s.is_asm and s.asmtext != 0 and not s.asm_is_ir)
                    void irparse.expand(s)
                s = s.next
            }
            bl = bl.next
        }
        long n
        for n in 0 to sub_count * sub_count - 1
            reaches[n] = 0
        for k in 0 to sub_count - 1 {
            s = all_subs[k] as ^^ir.Sub
            ^^ir.Chunk c = s.chunks
            while c != 0 {
                if c.kind != ir.C_ASM {
                    ^^ir.Instr i = c.first
                    while i != 0 {
                        if i.op == ir.OP_CALL and i.sym != 0 {
                            long to_index = index_of(i.sym)
                            if to_index >= 0
                                reaches[k * sub_count + to_index] = 1
                        }
                        i = i.next
                    }
                }
                c = c.next
            }
        }
        ; everything that follows: when a comes to b and b to c, a comes to c
        long mid
        long from_sub
        long to_sub
        for mid in 0 to sub_count - 1 {
            for from_sub in 0 to sub_count - 1 {
                if reaches[from_sub * sub_count + mid] != 0 {
                    for to_sub in 0 to sub_count - 1 {
                        if reaches[mid * sub_count + to_sub] != 0
                            reaches[from_sub * sub_count + to_sub] = 1
                    }
                }
            }
        }
    }

    ; the IR registers that the subroutine names anywhere
    sub own_registers(^^ir.Sub s) {
        long k
        if reg_seen == 0 {
            reg_seen = mem.alloc(70000)
            for k in 0 to 69999
                reg_seen[k] = 0
            own_regs = mem.alloc(OWN_MAX * sizeof(uword))
        }
        if own_count != 0 {
            for k in 0 to own_count - 1
                reg_seen[own_regs[k]] = 0
        }
        own_count = 0
        ; (only a subroutine that can come back into itself needs them)
        if this_index < 0 or reaches[this_index * sub_count + this_index] == 0
            return
        ^^ir.Chunk c = s.chunks
        while c != 0 {
            if c.kind != ir.C_ASM {
                ^^ir.Instr i = c.first
                while i != 0 {
                    own_register(i.r1)
                    own_register(i.r2)
                    own_register(i.r3)
                    ^^ir.Arg a = i.args
                    while a != 0 {
                        own_register(a.reg)
                        a = a.next
                    }
                    a = i.results
                    while a != 0 {
                        own_register(a.reg)
                        a = a.next
                    }
                    i = i.next
                }
            }
            c = c.next
        }
    }

    sub own_register(uword r) {
        if r == 0 or reg_seen[r] != 0 or own_count >= OWN_MAX
            return
        if size_of(ir.regtypes[r]) == 0
            return
        reg_seen[r] = 1
        own_regs[own_count] = r
        own_count++
    }

    ; is the variable one of the subroutine being written: "name.x", a single value?
    sub own_variable(^^ir.Var v) -> bool {
        if v.kind != ir.V_VAR or text_has(v.typestr, "[")
            return false
        long k = 0
        while this_sub.name[k] != 0 {
            if v.name[k] != this_sub.name[k]
                return false
            k++
        }
        if v.name[k] != '.'
            return false
        k++
        while v.name[k] != 0 {
            if v.name[k] == '.'
                return false
            k++
        }
        return element_size(v.typestr) != 0 and struct_of(v.typestr) == 0
    }

    ; Before a call that can come back into this subroutine: its variables and the places
    ; of its IR registers go on the stack (not the register that takes the call's result).
    sub save_own(^^ir.Instr i) -> long {
        uword result_reg = 0
        if i.results != 0
            result_reg = i.results.reg
        ^^ir.Var v = prog.vars
        while v != 0 {
            if own_variable(v) {
                ubyte vsize = element_size(v.typestr)
                push_place(v.name, 0, vsize)
            }
            v = v.next
        }
        long k
        if own_count != 0 {
            for k in 0 to own_count - 1 {
                if own_regs[k] != result_reg
                    push_place(0, own_regs[k], rsize(own_regs[k]))
            }
        }
        return result_reg
    }

    ; after it: back from the stack, in the other order
    sub restore_own(long result_reg) {
        long k = own_count
        while k != 0 {
            k--
            if own_regs[k] != result_reg
                pop_place(0, own_regs[k], rsize(own_regs[k]))
        }
        ; (the variables in the other order: counted, then the last one first)
        long count = 0
        ^^ir.Var v = prog.vars
        while v != 0 {
            if own_variable(v)
                count++
            v = v.next
        }
        while count != 0 {
            long seen = 0
            v = prog.vars
            while v != 0 {
                if own_variable(v) {
                    seen++
                    if seen == count
                        break
                }
                v = v.next
            }
            pop_place(v.name, 0, element_size(v.typestr))
            count--
        }
    }

    ; a variable (by its name) or the place of an IR register, as an operand: the bytes
    ; from offset on (from the first byte, the highest)
    sub place_operand(^^ubyte variable, uword r, ubyte offset) {
        if variable != 0
            name(variable)
        else {
            if r <= ir.regcount
                reg_used[r] = 1
            put("p8r_")
            putn(part)
            put("_")
            putn(r)
        }
        if offset != 0 {
            put("+")
            putn(offset)
        }
    }

    sub push_place(^^ubyte variable, uword r, ubyte size) {
        if size == 1 {
            op("ldb")
            place_operand(variable, r, 0)
            nl()
            line("pshs  b")
            return
        }
        ubyte k = 0
        while k < size {
            op("ldd")
            place_operand(variable, r, k)
            nl()
            line("pshs  d")
            k += 2
        }
    }

    sub pop_place(^^ubyte variable, uword r, ubyte size) {
        if size == 1 {
            line("puls  b")
            op("stb")
            place_operand(variable, r, 0)
            nl()
            return
        }
        ubyte k = size
        while k != 0 {
            k -= 2
            line("puls  d")
            op("std")
            place_operand(variable, r, k)
            nl()
        }
    }

    ; ---- system calls ----

    sub arg_n(^^ir.Instr i, ubyte n) -> ^^ir.Arg {
        ^^ir.Arg a = i.args
        while a != 0 and n != 0 {
            a = a.next
            n--
        }
        return a
    }

    ; a byte argument of a system call into A or B ("lda", "ldb")
    sub arg_byte(^^ir.Arg a, str load) {
        if a == 0
            error("a system call without the arguments it needs", 0)
        else
            op_arg(load, a, 0, 1)
    }

    ; a word argument into D, X, Y or U ("ldd", "ldx", "ldy", "ldu")
    sub arg_word(^^ir.Arg a, str load) {
        if a == 0
            error("a system call without the arguments it needs", 0)
        else if a.reg != 0 and rsize(a.reg) == 1 {
            ; (a byte where a word is wanted)
            if load[2] == 'd' {
                op_cell("ldb", a.reg, 0, 1)
                line("clra")
            }
            else {
                line("pshs  d")
                op_cell("ldb", a.reg, 0, 1)
                line("clra")
                op("tfr")
                put("d,")
                buf.add_byte(o, load[2])
                nl()
                line("puls  d")
            }
        }
        else
            op_arg(load, a, 0, 2)
    }

    ; a long argument of a system call into one of the cells of the long routines
    sub arg_cell(^^ir.Arg a, str place) {
        need_long = true
        if a == 0 {
            error("a system call without the arguments it needs", 0)
            return
        }
        op_arg("ldd", a, 0, 2)
        op("std")
        put(place)
        put("+2")
        nl()
        op_arg("ldd", a, 2, 2)
        op("std")
        put(place)
        nl()
    }

    sub call_rt(ubyte which, str routine) {
        need_rt[which] = true
        op("jsr")
        put(routine)
        nl()
    }

    ; B or D kept between two arguments of a system call (the least, the most)
    sub keep_between(^^ir.Arg least, ^^ir.Arg most, ubyte size, bool signed) {
        if least == 0 or most == 0 {
            error("a system call without the arguments it needs", 0)
            return
        }
        long fits = new_label()
        long over = new_label()
        ^^ubyte compare = "cmpb"
        ^^ubyte load = "ldb"
        if size == 2 {
            compare = "cmpd"
            load = "ldd"
        }
        op_arg(compare, least, 0, size)
        if signed
            jump_if_local("bge", fits)
        else
            jump_if_local("bhs", fits)
        op_arg(load, least, 0, size)
        local(fits)
        op_arg(compare, most, 0, size)
        if signed
            jump_if_local("ble", over)
        else
            jump_if_local("bls", over)
        op_arg(load, most, 0, size)
        local(over)
    }

    ; The system calls: what the library asks of the machine (the low numbers, as the
    ; virtual machine has them), and the builtin functions that the IR leaves to the
    ; back end (from $1000).  A result is in B, D, or X and D.
    sub syscall(^^ir.Instr i) {
        ^^ir.Arg a0 = arg_n(i, 0)
        ^^ir.Arg a1 = arg_n(i, 1)
        ^^ir.Arg a2 = arg_n(i, 2)
        ^^ir.Arg res = i.results
        when i.value as long {
            1 -> {
                ; the end of the program, as the target ends one, with the status in B
                if a0 != 0
                    arg_byte(a0, "ldb")
                else
                    line("clrb")
                line("jmp  p8_exit")
            }
            2 -> {
                ; a character to the console: the machine's routine (console_out)
                arg_byte(a0, "lda")
                call_rt(RT_CHROUT, "p8rt_chrout")
            }
            3 -> {
                ; a string that ends with 0
                arg_word(a0, "ldx")
                line("jsr  p8rt_print")
                need_print = true
            }
            36 -> {
                ; copy memory: from, to, how many bytes (they may overlap)
                arg_word(a0, "ldx")
                arg_word(a1, "ldu")
                arg_word(a2, "ldy")
                call_rt(RT_MOVE, "p8rt_move")
            }
            37 -> {
                ; fill memory: where, how many bytes, the value
                arg_word(a0, "ldx")
                arg_word(a1, "ldy")
                arg_byte(a2, "ldb")
                call_rt(RT_FILL, "p8rt_fill")
            }
            38 -> {
                ; fill memory with a word: where, how many words, the value
                arg_word(a0, "ldx")
                arg_word(a1, "ldy")
                arg_word(a2, "ldd")
                call_rt(RT_FILLW, "p8rt_fillw")
            }
            69 -> {
                ; a character from the console, waited for and shown (char_in)
                need_rt[RT_CHROUT] = true
                call_rt(RT_CHRIN, "p8rt_chrin")
                line("tfr  a,b")
            }
            217 -> {
                ; a key, or 0 when none is waiting (key_poll)
                call_rt(RT_GETKEY, "p8rt_getkey")
                line("tfr  a,b")
            }
            218 -> {
                need_rt[RT_GETKEY] = true
                call_rt(RT_WAITKEY, "p8rt_waitkey")
                line("tfr  a,b")
            }
            13 -> {
                ; wait so many 60ths of a second
                arg_word(a0, "ldx")
                call_rt(RT_WAIT, "p8rt_wait")
            }
            14 -> {
                line("ldx  #1")
                call_rt(RT_WAIT, "p8rt_wait")
            }
            216 -> call_rt(RT_TICKS, "p8rt_ticks")      ; the clock, in 60ths of a second
            213 -> line("clrb")                         ; (the 6809 has no I/O ports)
            214 -> {
            }
            200 -> call_rt(RT_ARGS, "p8rt_argc")
            201 -> {
                arg_word(a0, "ldx")
                call_rt(RT_ARGS, "p8rt_argv")
            }
            $100d -> {
                ; compare two strings: -1, 0 or 1
                arg_word(a0, "ldx")
                arg_word(a1, "ldu")
                call_rt(RT_STRCMP, "p8rt_strcmp")
            }
            $100e -> {
                ; is a character in a string
                arg_byte(a0, "lda")
                arg_word(a1, "ldx")
                call_rt(RT_INSTR, "p8rt_instr")
            }
            $100f -> {
                ; is a byte in an array: the value, the array, its length
                arg_byte(a0, "lda")
                arg_word(a1, "ldx")
                arg_word(a2, "ldy")
                call_rt(RT_INBYTES, "p8rt_inbytes")
            }
            $1010 -> {
                arg_word(a1, "ldx")
                arg_word(a2, "ldy")
                arg_word(a0, "ldd")
                call_rt(RT_INWORDS, "p8rt_inwords")
            }
            $1012, $1013 -> {
                ; clamp a byte: the value, the least, the most
                arg_byte(a0, "ldb")
                keep_between(a1, a2, 1, i.value == $1013)
            }
            $1014, $1015 -> {
                arg_word(a0, "ldd")
                keep_between(a1, a2, 2, i.value == $1015)
            }
            $1016 -> {
                ; clamp a long: the value, the least, the most
                arg_cell(a0, "p8_la")
                arg_cell(a1, "p8_lb")
                arg_cell(a2, "p8_lc")
                need_rt[RT_LESS32] = true
                call_rt(RT_CLAMP32, "p8rt_clamp32")
                line("ldd  p8_la+2")
                line("ldx  p8_la")
            }
            $101b, $1011 -> {
                ; is a long in an array: the value, the array, its length
                arg_cell(a0, "p8_la")
                arg_word(a1, "ldx")
                arg_word(a2, "ldy")
                call_rt(RT_INLONGS, "p8rt_inlongs")
            }
            else -> {
                buf.clear(nb)
                buf.add_long(nb, i.value as long)
                buf.add_byte(nb, 0)
                error("this system call is not there for the 6809 yet", nb.data)
                return
            }
        }
        if res != 0 and res.reg != 0 {
            ubyte result_size = size_of(res.type)
            if result_size != 0
                keep(res.reg, result_size)
            else
                error("the result of this system call cannot be taken on the 6809 yet", 0)
        }
    }

    ; ---- what the code calls ----

    ; several lines of assembly at once: each line of the text, a label (a line that
    ; ends with a colon) at the margin
    sub lines(str text) {
        long k = 0
        while text[k] != 0 {
            long stop = k
            while text[stop] != 0 and text[stop] != '\n'
                stop++
            if stop != k and text[stop - 1] != ':' and text[k] != ';'
                put("    ")
            while k < stop {
                buf.add_byte(o, text[k])
                k++
            }
            nl()
            if text[k] == '\n'
                k++
        }
    }

    sub runtime() {
        if need_print {
            lines("; prints the string at X (it ends with 0)\np8rt_print:\nlda  ,x+\nbeq  p8rt_print_end\npshs  x\njsr  p8rt_chrout\npuls  x\nbra  p8rt_print\np8rt_print_end:\nrts")
            need_rt[RT_CHROUT] = true
        }
        if need_mul
            lines("; D = D * X (the low 16 bits)\np8rt_mul16:\npshs  x,d\nlda  1,s\nldb  3,s\nmul\npshs  d\nlda  2,s\nldb  5,s\nmul\naddb  ,s\nstb  ,s\nlda  3,s\nldb  4,s\nmul\naddb  ,s\nstb  ,s\npuls  d\nleas  4,s\nrts")
        if need_div {
            lines("; D = D / X, X = the remainder (unsigned; a division by 0 gives $ffff)\np8rt_div16:\npshs  x,d\nldd  #0\nldx  #16\np8rt_div16_bit:\nlsl  1,s\nrol  ,s\nrolb\nrola\nbcs  p8rt_div16_fits\ncmpd  2,s")
            lines("blo  p8rt_div16_less\np8rt_div16_fits:\nsubd  2,s\ninc  1,s\np8rt_div16_less:\nleax  -1,x\nbne  p8rt_div16_bit\ntfr  d,x\npuls  d\nleas  2,s\nrts")
        }
        if need_divs {
            lines("; D = D / X, X = the remainder (signed: towards zero, the remainder with the dividend's sign)\np8rt_divs16:\npshs  x,d\nclr  ,-s\nldd  1,s\nbpl  p8rt_divs16_a\ncoma\ncomb\naddd  #1\nstd  1,s\nlda  #3")
            lines("sta  ,s\np8rt_divs16_a:\nldd  3,s\nbpl  p8rt_divs16_b\ncoma\ncomb\naddd  #1\nstd  3,s\nlda  ,s\neora  #1\nsta  ,s\np8rt_divs16_b:\nldd  1,s\nldx  3,s\njsr  p8rt_div16\npshs  x\nlsr  2,s")
            lines("bcc  p8rt_divs16_q\ncoma\ncomb\naddd  #1\np8rt_divs16_q:\nstd  3,s\npuls  d\nlsr  ,s\nbcc  p8rt_divs16_r\ncoma\ncomb\naddd  #1\np8rt_divs16_r:\ntfr  d,x\nleas  1,s\npuls  d\nleas  2,s\nrts")
        }
        if need_mul32 {
            lines("; p8_lc = p8_la * p8_lb (the low 32 bits)\np8rt_mul32:\nldd  #0\nstd  p8_lc\nstd  p8_lc+2\nlda  #32\npshs  a\np8rt_mul32_bit:\nlsl  p8_lc+3\nrol  p8_lc+2\nrol  p8_lc+1\nrol  p8_lc\nlsl  p8_la+3")
            lines("rol  p8_la+2\nrol  p8_la+1\nrol  p8_la\nbcc  p8rt_mul32_next\nldd  p8_lc+2\naddd  p8_lb+2\nstd  p8_lc+2\nldd  p8_lc\nadcb  p8_lb+1\nadca  p8_lb\nstd  p8_lc\np8rt_mul32_next:\ndec  ,s")
            lines("bne  p8rt_mul32_bit\nleas  1,s\nrts")
        }
        if need_div32 {
            lines("; p8_la = p8_la / p8_lb, p8_lc = the remainder (unsigned)\np8rt_div32:\nldd  #0\nstd  p8_lc\nstd  p8_lc+2\nlda  #32\npshs  a\np8rt_div32_bit:\nlsl  p8_la+3\nrol  p8_la+2\nrol  p8_la+1\nrol  p8_la")
            lines("rol  p8_lc+3\nrol  p8_lc+2\nrol  p8_lc+1\nrol  p8_lc\nbcs  p8rt_div32_fits\nldd  p8_lc\ncmpd  p8_lb\nbne  p8rt_div32_decide\nldd  p8_lc+2\ncmpd  p8_lb+2\np8rt_div32_decide:\nblo  p8rt_div32_next")
            lines("p8rt_div32_fits:\nldd  p8_lc+2\nsubd  p8_lb+2\nstd  p8_lc+2\nldd  p8_lc\nsbcb  p8_lb+1\nsbca  p8_lb\nstd  p8_lc\ninc  p8_la+3\np8rt_div32_next:\ndec  ,s\nbne  p8rt_div32_bit\nleas  1,s\nrts")
        }
        if need_divs32 {
            lines("; the same, signed: towards zero, the remainder with the dividend's sign\np8rt_divs32:\nclr  ,-s\ntst  p8_la\nbpl  p8rt_divs32_a\nldx  #p8_la\nbsr  p8rt_neg32\nlda  #3\nsta  ,s\np8rt_divs32_a:")
            lines("tst  p8_lb\nbpl  p8rt_divs32_b\nldx  #p8_lb\nbsr  p8rt_neg32\nlda  ,s\neora  #1\nsta  ,s\np8rt_divs32_b:\njsr  p8rt_div32\nlsr  ,s\nbcc  p8rt_divs32_q\nldx  #p8_la\nbsr  p8rt_neg32\np8rt_divs32_q:")
            lines("lsr  ,s\nbcc  p8rt_divs32_r\nldx  #p8_lc\nbsr  p8rt_neg32\np8rt_divs32_r:\nleas  1,s\nrts\n; the long at X = -it\np8rt_neg32:\nldd  #0\nsubd  2,x\nstd  2,x\nldd  #0\nsbcb  1,x\nsbca  ,x\nstd  ,x\nrts")
        }
        if need_rt[RT_MOVE] {
            lines("; copies Y bytes from X to U; the two may overlap\np8rt_move:\nleay  ,y\nbeq  p8rt_move_end\npshs  u\ncmpx  ,s++\nbhs  p8rt_move_up\ntfr  y,d\nleax  d,x\nleau  d,u\np8rt_move_back:\nlda  ,-x\nsta  ,-u")
            lines("leay  -1,y\nbne  p8rt_move_back\nrts\np8rt_move_up:\nlda  ,x+\nsta  ,u+\nleay  -1,y\nbne  p8rt_move_up\np8rt_move_end:\nrts")
        }
        if need_rt[RT_FILL]
            lines("; fills Y bytes at X with B\np8rt_fill:\nleay  ,y\nbeq  p8rt_fill_end\np8rt_fill_next:\nstb  ,x+\nleay  -1,y\nbne  p8rt_fill_next\np8rt_fill_end:\nrts")
        if need_rt[RT_FILLW]
            lines("; fills Y words at X with D\np8rt_fillw:\nleay  ,y\nbeq  p8rt_fillw_end\np8rt_fillw_next:\nstd  ,x++\nleay  -1,y\nbne  p8rt_fillw_next\np8rt_fillw_end:\nrts")
        if need_rt[RT_STRCMP] {
            lines("; compares the strings at X and U: B = 0 the same, 1 the first is greater, 255 it is less\np8rt_strcmp:\nlda  ,x+\ncmpa  ,u+\nbne  p8rt_strcmp_differ\ntsta\nbne  p8rt_strcmp\nclrb\nrts")
            lines("p8rt_strcmp_differ:\nblo  p8rt_strcmp_less\nldb  #1\nrts\np8rt_strcmp_less:\nldb  #255\nrts")
        }
        if need_rt[RT_INSTR]
            lines("; is the character in A in the string at X: B = 1 or 0\np8rt_instr:\ntst  ,x\nbeq  p8rt_instr_no\ncmpa  ,x+\nbne  p8rt_instr\nldb  #1\nrts\np8rt_instr_no:\nclrb\nrts")
        if need_rt[RT_INBYTES] {
            lines("; is the byte in A among the Y bytes at X: B = 1 or 0\np8rt_inbytes:\nleay  ,y\nbeq  p8rt_inbytes_no\np8rt_inbytes_next:\ncmpa  ,x+\nbeq  p8rt_inbytes_yes\nleay  -1,y\nbne  p8rt_inbytes_next")
            lines("p8rt_inbytes_no:\nclrb\nrts\np8rt_inbytes_yes:\nldb  #1\nrts")
        }
        if need_rt[RT_INWORDS] {
            lines("; is the word in D among the Y words at X: B = 1 or 0\np8rt_inwords:\nleay  ,y\nbeq  p8rt_inwords_no\np8rt_inwords_next:\ncmpd  ,x++\nbeq  p8rt_inwords_yes\nleay  -1,y\nbne  p8rt_inwords_next")
            lines("p8rt_inwords_no:\nclrb\nrts\np8rt_inwords_yes:\nldb  #1\nrts")
        }
        if need_rt[RT_INLONGS] {
            lines("; is the long in p8_la among the Y longs at X: B = 1 or 0\np8rt_inlongs:\nleay  ,y\nbeq  p8rt_inlongs_no\np8rt_inlongs_next:\nldd  ,x\ncmpd  p8_la\nbne  p8rt_inlongs_other\nldd  2,x\ncmpd  p8_la+2")
            lines("beq  p8rt_inlongs_yes\np8rt_inlongs_other:\nleax  4,x\nleay  -1,y\nbne  p8rt_inlongs_next\np8rt_inlongs_no:\nclrb\nrts\np8rt_inlongs_yes:\nldb  #1\nrts")
        }
        if need_rt[RT_CLAMP32] {
            lines("; p8_la = p8_la kept between p8_lb and p8_lc (signed longs)\np8rt_clamp32:\nldx  #p8_la\nldu  #p8_lb\nbsr  p8rt_less32\nbcc  p8rt_clamp32_top\nldd  p8_lb\nstd  p8_la\nldd  p8_lb+2\nstd  p8_la+2\nrts")
            lines("p8rt_clamp32_top:\nldx  #p8_lc\nldu  #p8_la\nbsr  p8rt_less32\nbcc  p8rt_clamp32_end\nldd  p8_lc\nstd  p8_la\nldd  p8_lc+2\nstd  p8_la+2\np8rt_clamp32_end:\nrts")
        }
        if need_rt[RT_LESS32] {
            lines("; carry when the long at X is less than the long at U (signed)\np8rt_less32:\nldd  ,x\ncmpd  ,u\nblt  p8rt_less32_yes\nbgt  p8rt_less32_no\nldd  2,x\ncmpd  2,u\nrts\np8rt_less32_yes:\norcc  #1\nrts")
            lines("p8rt_less32_no:\nandcc  #$fe\nrts")
        }
        if need_rt[RT_SQRT] {
            lines("; D = the square root of the long in p8_la, rounded down: two bits of the number\n; at a time into the rest (three bytes of p8_lc), the root in p8_lb+2\np8rt_sqrt32:\nldd  #0\nstd  p8_lc\nstd  p8_lc+2")
            lines("std  p8_lb+2\nlda  #16\npshs  a\np8rt_sqrt32_bit:\nlsl  p8_la+3\nrol  p8_la+2\nrol  p8_la+1\nrol  p8_la\nrol  p8_lc+3\nrol  p8_lc+2\nrol  p8_lc+1\nlsl  p8_la+3\nrol  p8_la+2\nrol  p8_la+1\nrol  p8_la")
            lines("rol  p8_lc+3\nrol  p8_lc+2\nrol  p8_lc+1\nlsl  p8_lb+3\nrol  p8_lb+2\nclr  ,-s\nldd  p8_lb+2\nlslb\nrola\nrol  ,s\norb  #1\npshs  d\nlda  p8_lc+1\ncmpa  2,s\nbne  p8rt_sqrt32_decide\nldd  p8_lc+2")
            lines("cmpd  ,s\np8rt_sqrt32_decide:\nblo  p8rt_sqrt32_less\nldd  p8_lc+2\nsubd  ,s\nstd  p8_lc+2\nlda  p8_lc+1\nsbca  2,s\nsta  p8_lc+1\ninc  p8_lb+3\np8rt_sqrt32_less:\nleas  3,s\ndec  ,s")
            lines("bne  p8rt_sqrt32_bit\nleas  1,s\nldd  p8_lb+2\nrts")
        }
        if need_rt[RT_WAIT] {
            lines("; waits X 60ths of a second, one at a time as the target file says how\np8rt_wait:\nleax  ,x\nbeq  p8rt_wait_end\np8rt_wait_next:\npshs  x\nbsr  p8rt_jiffy\npuls  x\nleax  -1,x\nbne  p8rt_wait_next")
            lines("p8rt_wait_end:\nrts\np8rt_jiffy:")
            if target.text("wait_jiffy") != 0
                target_lines("wait_jiffy")
            else
                line("rts")
        }
        if need_rt[RT_TICKS] {
            raw("; D = the clock, in 60ths of a second (0 on a machine without one)")
            raw("p8rt_ticks:")
            if target.text("ticks") != 0
                target_lines("ticks")
            else {
                line("ldd  #0")
                line("rts")
            }
        }
        if need_rt[RT_ARGS] {
            lines("; the command line: no machine here has one.  D = the number of arguments, the\n; program's name counted; D = an argument, which is empty\np8rt_argc:\nldd  #1\nrts\np8rt_argv:\nldd  #p8rt_argv_none")
            lines("rts\np8rt_argv_none:\nfcb  0")
        }
        if need_rt[RT_WAITKEY]
            lines("; waits for a key and gives it in A, without showing it\np8rt_waitkey:\njsr  p8rt_getkey\ntsta\nbeq  p8rt_waitkey\nrts")
        if need_rt[RT_CHROUT] {
            raw("; a character (in A) to the console")
            raw("p8rt_chrout:")
            if target.text("console_tap") != 0 {
                ; (lines of the target that see every character first: the tests'
                ; variant keeps what is printed where the emulator's snapshot has it)
                line("pshs  a")
                target_lines("console_tap")
                line("puls  a")
            }
            target_lines("console_out")
        }
        if need_rt[RT_GETKEY] {
            raw("; A = a key, or 0 when none is waiting")
            raw("p8rt_getkey:")
            target_lines("key_poll")
        }
        if need_rt[RT_CHRIN] {
            raw("; A = a character from the console, waited for and shown")
            raw("p8rt_chrin:")
            target_lines("char_in")
        }
        nl()
    }

    ; ---- variables ----

    sub element_size(^^ubyte typestr) -> ubyte {
        if text_has(typestr, "float")
            return 0
        if text_has(typestr, "word") or text_has(typestr, "pointer") or typestr[0] == '^'
            return 2
        if text_has(typestr, "long")
            return 4
        if text_has(typestr, "quad")
            return 0
        return 1
    }

    sub text_has(^^ubyte text, str piece) -> bool {
        long k = 0
        while text[k] != 0 {
            long m = 0
            while piece[m] != 0 and text[k + m] == piece[m]
                m++
            if piece[m] == 0
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
                    ; no 16-bit machine has, to say that they are the back end's to place.
                    ; The low byte of one is the second of its two here.)
                    put("p8_vregs+")
                    if element_size(v.typestr) == 1 and not text_has(v.typestr, "[")
                        putn((address - $ff0000) ^ 1)
                    else
                        putn(address - $ff0000)
                    need_vregs = true
                }
                else
                    put_number_text(v.init)
                nl()
            }
            else if v.kind == ir.V_VAR and v.init != 0 and struct_of(v.typestr) != 0 {
                ; an array of structs: its instances' values, one after the other
                name(v.name)
                put(":")
                nl()
                struct_array_values(v, struct_of(v.typestr).size)
            }
            else if v.kind == ir.V_VAR and v.init != 0 {
                ubyte esize = element_size(v.typestr)
                if esize == 0
                    error("a variable of this type cannot be used on the 6809 yet", v.name)
                else
                    values(v, esize)
            }
            else if v.kind == ir.V_INSTANCE and v.init != 0 {
                name(v.name)
                put(":")
                nl()
                instance_values(v, v.init)
            }
            v = v.next
        }
        if target.text("end_code") != 0
            target_lines("end_code")
        ; (memory that is only set aside is not part of the program's file: it is what
        ; comes after it, and the first instructions clear it)
        raw("; ---- variables without values, and the registers of the code")
        raw("p8_bss_start:")
        v = prog.vars
        while v != 0 {
            if (v.kind == ir.V_VAR and v.init == 0) or v.kind == ir.V_SLAB or (v.kind == ir.V_INSTANCE and v.init == 0) {
                long bytes = v.size
                if v.kind == ir.V_VAR {
                    long vsize = element_size(v.typestr)
                    if struct_of(v.typestr) != 0
                        vsize = struct_of(v.typestr).size
                    if vsize == 0 {
                        error("a variable of this type cannot be used on the 6809 yet", v.name)
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
                put(":  rmb  ")
                putn(bytes)
                nl()
            }
            v = v.next
        }
        buf.add_bytes(o, cells.data, cells.len)
        if need_vregs
            raw("p8_vregs:  rmb  32")
        ubyte sn
        for sn in 0 to 99 {
            if slot_used[sn] {
                put("p8_slot_")
                putn(sn)
                raw(":  rmb  4")
            }
        }
        if need_long {
            raw("p8_la:  rmb  4")
            raw("p8_lc:  rmb  4")
            raw("p8_lb:  rmb  4")
        }
        raw("p8_bss_end:")
        if target.number("stack_size", 0) > 0 {
            put("p8_stack:  rmb  ")
            putn(target.number("stack_size", 0))
            nl()
            raw("p8_stack_top:")
        }
        if target.text("tail_code") != 0
            target_lines("tail_code")
    }

    ; the struct that a type is an array of ("main.Two[4]"), or 0
    sub struct_of(^^ubyte t) -> ^^ir.Var {
        long n = 0
        while t[n] != 0 and t[n] != '['
            n++
        if t[n] == 0
            return 0
        ^^ir.Var sv = prog.vars
        while sv != 0 {
            if sv.kind == ir.V_STRUCT and buf.cstr_len(sv.name) == n and buf.bytes_equal(sv.name, t, n)
                return sv
            sv = sv.next
        }
        return 0
    }

    ; "@instance,@instance": each instance's values (zeros for one without)
    sub struct_array_values(^^ir.Var v, long struct_size) {
        ^^ubyte t = v.init
        long p = 0
        while t[p] != 0 {
            long stop = p
            while t[stop] != 0 and t[stop] != ','
                stop++
            ^^ir.Var inst = 0
            if t[p] == '@' {
                ^^ubyte wanted = strtab.intern(t + p + 1, (stop - p - 1) as uword)
                inst = prog.vars
                while inst != 0 {
                    if inst.kind == ir.V_INSTANCE and strings.compare(inst.name, wanted) == 0
                        break
                    inst = inst.next
                }
            }
            if inst != 0 and inst.init != 0
                instance_values(v, inst.init)
            else {
                put("    rzb  ")
                putn(struct_size)
                nl()
            }
            p = stop
            if t[p] == ','
                p++
        }
    }

    ; the values of a struct instance: "type:value,type:value,..."
    sub instance_values(^^ir.Var v, ^^ubyte init) {
        long p = 0
        while init[p] != 0 {
            long colon = p
            while init[colon] != 0 and init[colon] != ':'
                colon++
            if init[colon] == 0
                break
            ; (the field's type: what stands before the colon)
            if init[p] == '^' or (init[p] == 'u' and init[p + 1] == 'w') or init[p] == 'w' or init[p] == 'p'
                put("    fdb  ")
            else if init[p] == 'l'
                put("    fqb  ")
            else if init[p] == 'f' or init[p] == 'q' or (init[p] == 'u' and init[p + 1] == 'q') {
                error("a struct field of this type cannot be used on the 6809 yet", v.name)
                return
            }
            else
                put("    fcb  ")
            p = colon + 1
            if init[p] == '@' or init[p] == '&' {
                p++
                buf.add_byte(o, '_')
                while init[p] != 0 and init[p] != ',' {
                    if init[p] == '.'
                        buf.add_str(o, "__")
                    else
                        buf.add_byte(o, init[p])
                    p++
                }
            }
            else {
                while init[p] != 0 and init[p] != ',' {
                    buf.add_byte(o, init[p])
                    p++
                }
            }
            nl()
            if init[p] == ','
                p++
        }
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
                    1 -> put("    fcb  ")
                    2 -> put("    fdb  ")
                    else -> put("    fqb  ")
                }
            }
            else
                put(",")
            if v.init[p] == '@' or v.init[p] == '&' {
                p++
                buf.add_byte(o, '_')
                while v.init[p] != 0 and v.init[p] != ',' {
                    if v.init[p] == '.'
                        buf.add_str(o, "__")
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
