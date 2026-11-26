; The 8086 code generator: writes a p8p8 IR program (ir.p8) as assembly for nasm.  A
; first version, put together as the 6809 one is.
;
; How it is put together (docs/DESIGN.md, "The 8086"):
;
; - The program is one segment of 64 KB (a .COM file's): code, data and stack share
;   it, every address is 16 bits, and no segment register is ever changed.
; - Every IR register has a place in memory (p8r_S_N, as wide as its type; S is the
;   subroutine, as register numbers are used again from one to the next).  The 8086
;   works on memory directly, so an instruction mostly is one or two of its own: the
;   second operand through AL or AX when it is no constant.  BX holds addresses.
; - A call puts its arguments into the subroutine's parameter variables, as the IR
;   names them; a result comes back in AL (a byte), AX (a word) or DX and AX (a long,
;   AX the low half).
; - What the machine has to do (print a character, a string) is a system call in the
;   IR; the routines for them are the target file's.
; - A conditional jump of the 8086 reaches 127 bytes.  Every one is written as it is,
;   and a pass over the finished text (branches) turns those that may not reach into
;   the opposite jump around a "jmp".
;
; Not there yet is said by an error that names the instruction: floats.

%import ir
%import irparse
%import buf
%import strtab
%import strings
%import mem
%import out
%import target
%import peep8086

gen8086 {
    %option ignore_unused

    ^^ir.Program prog = 0
    ^^buf.Buf o = 0
    ^^buf.Buf nb = 0
    long errors = 0
    long labels = 0
    ^^ubyte reg_used = 0            ; per IR register: named by the code that was written
    long part = 0                   ; which subroutine's registers: its number
    ^^buf.Buf cells = 0             ; the places of the registers, written at the end
    ^^buf.Buf out_buf = 0           ; the assembly, as generate was given it
    ^^buf.Buf body = 0              ; everything after the first lines
    ^^buf.Buf fixed = 0             ; the text with its jumps made to reach (see branches)
    ^^ir.Instr previous = 0         ; the instruction before the one being written, in its chunk
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
    bool optimize = true            ; parameters in registers; -noopt turns it off
    bool carry_cell = false         ; this subroutine keeps the IR's carry in a place of its own (see carry_scan)
    bool carry_loaded = false       ; the instruction's carry was just taken from there
    bool entry_pending = false      ; the subroutine's first label is still to come
    ubyte skip_next = 0             ; so many instructions that follow are done already
    bool wide_error = false         ; the error about a register used wider than it is was said
    ; An .EXE file (the target's output_format = exe): the code in a segment of its own
    ; and the data in another, each counted from 0, after a header that is written
    ; here.  Else the program is one piece from the load address on (a .COM file).
    bool exe = false
    bool[32] need_rt                ; the routines of the system calls (the RT_ numbers)
    const ubyte RT_MOVE = 0
    const ubyte RT_FILL = 1
    const ubyte RT_FILLW = 2
    const ubyte RT_STRCMP = 3
    const ubyte RT_INSTR = 4
    const ubyte RT_INBYTES = 5
    const ubyte RT_INWORDS = 6
    const ubyte RT_SQRT = 11
    const ubyte RT_WAITKEY = 12
    const ubyte RT_LESS32 = 14
    const ubyte RT_CLAMP32 = 15
    const ubyte RT_INLONGS = 16
    const ubyte RT_INFLOATS = 17
    const ubyte RT_CHROUT = 18
    const ubyte RT_GETKEY = 19
    const ubyte RT_CHRIN = 20
    const ubyte RT_WAIT = 21
    const ubyte RT_ARGS = 24
    const ubyte RT_TICKS = 25

    sub error(str message, ^^ubyte detail) {
        out.err()
        out.puts("8086 code generator: ")
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

    ; the beginning of a line of assembly: what follows is the rest of it
    sub ins(str text) {
        put("    ")
        put(text)
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

    ; ---- types ----

    sub size_of(ubyte t) -> ubyte {
        when t {
            ir.T_BYTE -> return 1
            ir.T_WORD, ir.T_POINTER -> return 2
            ir.T_LONG -> return 4
            ir.T_FLOAT -> return 8              ; (an IEEE double)
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
    ; bytes are wanted from there up (1 or 2).  The 8086 has the low byte first, so k
    ; is the offset; the operand says how wide it is ("byte [..]", "word [..]").

    sub width(ubyte w) {
        if w == 1
            put("byte [")
        else
            put("word [")
    }

    sub plus(long offset) {
        if offset != 0 {
            put("+")
            putn(offset)
        }
    }

    ; a register's place
    sub cell(uword r, ubyte k, ubyte w) {
        if r <= ir.regcount
            reg_used[r] = 1
        ubyte s = rsize(r)
        if k + w > s {
            if not wide_error
                error("a register is used wider than its place is (a fault of the generator)", 0)
            wide_error = true
        }
        width(w)
        ; (register numbers are used again from one subroutine to the next, so each
        ; subroutine has places of its own)
        put("p8r_")
        putn(part)
        put("_")
        putn(r)
        plus(k)
        put("]")
    }

    ; the address of the memory operand of an instruction (without an index), with a
    ; byte offset
    sub mem_name(^^ir.Instr i, long extra) {
        if i.sym != 0 {
            name(i.sym)
            plus(i.offset + extra)
        }
        else {
            ; (a fixed address: in the value, or in the offset alone when the value is
            ; the instruction's immediate)
            long address = (i.value as long) + i.offset
            if i.op == ir.OP_STOREIM or i.op == ir.OP_ADDIM or i.op == ir.OP_SUBIM
                address = i.offset
            if address >= $ff0000 {
                ; (one of the library's virtual registers, by its made-up address)
                put("p8_vregs+")
                putn(address - $ff0000 + extra)
                need_vregs = true
            }
            else
                putn((address + extra) & $ffff)
        }
    }

    sub mem(^^ir.Instr i, ubyte k, ubyte w) {
        width(w)
        mem_name(i, k)
        put("]")
    }

    ; A hardware register slot of the IR: here a place in memory, four bytes.  The
    ; values that a subroutine returns beside its first, and the one of a call through a
    ; pointer, go through them.
    sub slot(ubyte number, ubyte k, ubyte w) {
        slot_used[number] = true
        width(w)
        put("p8_slot_")
        putn(number)
        plus(k)
        put("]")
    }

    ; "    before<the register's place>after"
    sub op_cell(str before, uword r, ubyte k, ubyte w, str after) {
        ins(before)
        cell(r, k, w)
        put(after)
        nl()
    }

    sub op_mem(str before, ^^ir.Instr i, ubyte k, ubyte w, str after) {
        ins(before)
        mem(i, k, w)
        put(after)
        nl()
    }

    sub op_slot(str before, ubyte number, ubyte k, ubyte w, str after) {
        ins(before)
        slot(number, k, w)
        put(after)
        nl()
    }

    ; "    mnemonic  operand, value"
    sub op_imm(str before, long value) {
        ins(before)
        putn(value)
        nl()
    }

    ; AL or AX = bytes k and up of a register's place, and the other way round
    sub load_cell(uword r, ubyte k, ubyte w) {
        if w == 1
            op_cell("mov  al, ", r, k, 1, "")
        else
            op_cell("mov  ax, ", r, k, 2, "")
    }

    sub store_cell(uword r, ubyte k, ubyte w) {
        if w == 1
            op_cell("mov  ", r, k, 1, ", al")
        else
            op_cell("mov  ", r, k, 2, ", ax")
    }

    sub load_mem(^^ir.Instr i, ubyte k, ubyte w) {
        if w == 1
            op_mem("mov  al, ", i, k, 1, "")
        else
            op_mem("mov  ax, ", i, k, 2, "")
    }

    sub store_mem(^^ir.Instr i, ubyte k, ubyte w) {
        if w == 1
            op_mem("mov  ", i, k, 1, ", al")
        else
            op_mem("mov  ", i, k, 2, ", ax")
    }

    ; the value of register r into AL (a byte), AX (a word) or DX and AX (a long, AX the
    ; low half)
    sub fetch(uword r, ubyte size) {
        if size == 8 {
            fcopy(F_FAC, 0, 0, 0, F_CELL, r, 0, 0)     ; (a float: in the float accumulator)
            return
        }
        if size == 1
            load_cell(r, 0, 1)
        else {
            load_cell(r, 0, 2)
            if size == 4
                op_cell("mov  dx, ", r, 2, 2, "")
        }
    }

    sub keep(uword r, ubyte size) {
        if size == 8 {
            fcopy(F_CELL, r, 0, 0, F_FAC, 0, 0, 0)
            return
        }
        if size == 1
            store_cell(r, 0, 1)
        else {
            store_cell(r, 0, 2)
            if size == 4
                op_cell("mov  ", r, 2, 2, ", dx")
        }
    }

    ; register to = register from, a word at a time where there is one
    sub copy_reg(uword target_reg, uword source_reg, ubyte size) {
        if size == 1 {
            load_cell(source_reg, 0, 1)
            store_cell(target_reg, 0, 1)
        }
        else {
            load_cell(source_reg, 0, 2)
            store_cell(target_reg, 0, 2)
            if size == 4 {
                load_cell(source_reg, 2, 2)
                store_cell(target_reg, 2, 2)
            }
        }
    }

    ; BX = the address of the instruction's memory operand, with its index when it has
    ; one (r2 times the element's size)
    sub x_address(^^ir.Instr i, bool indexed) {
        if indexed and i.r2 != 0 {
            ubyte times = i.scale
            if times == 0
                times = 1
            if rsize(i.r2) == 1 {
                op_cell("mov  bl, ", i.r2, 0, 1, "")
                line("xor  bh, bh")
            }
            else
                op_cell("mov  bx, ", i.r2, 0, 2, "")
            if (times & (times - 1)) != 0 {
                ; (a size that is no power of two)
                line("mov  ax, bx")
                op_imm("mov  dx, ", times)
                line("mul  dx")
                line("mov  bx, ax")
            }
            else {
                while times > 1 {
                    line("shl  bx, 1")
                    times >>= 1
                }
            }
            ins("add  bx, ")
            mem_name(i, 0)
            nl()
            return
        }
        ins("mov  bx, ")
        mem_name(i, 0)
        nl()
    }

    ; BX = r2: the address of a load or store through a pointer (the offset goes into the
    ; instruction that uses it)
    sub x_pointer(^^ir.Instr i) {
        op_cell("mov  bx, ", i.r2, 0, 2, "")
    }

    ; "    before<byte k, w wide, of what BX points at plus base>after"
    sub op_x(str before, long base, ubyte k, ubyte w, str after) {
        ins(before)
        width(w)
        put("bx")
        long at = (base + k) & $ffff
        if at >= $8000 {
            put("-")
            putn($10000 - at)
        }
        else
            plus(at)
        put("]")
        put(after)
        nl()
    }

    ; the bytes at base,BX into register r, or the other way round
    sub reg_from_x(uword r, long base, ubyte size) {
        if size == 1 {
            op_x("mov  al, ", base, 0, 1, "")
            store_cell(r, 0, 1)
            return
        }
        op_x("mov  ax, ", base, 0, 2, "")
        store_cell(r, 0, 2)
        if size == 4 {
            op_x("mov  ax, ", base, 2, 2, "")
            store_cell(r, 2, 2)
        }
    }

    sub x_from_reg(uword r, long base, ubyte size) {
        if size == 1 {
            load_cell(r, 0, 1)
            op_x("mov  ", base, 0, 1, ", al")
            return
        }
        load_cell(r, 0, 2)
        op_x("mov  ", base, 0, 2, ", ax")
        if size == 4 {
            load_cell(r, 2, 2)
            op_x("mov  ", base, 2, 2, ", ax")
        }
    }

    ; ---- the program ----

    sub generate(^^ir.Program p, ^^buf.Buf output) {
        prog = p
        o = output
        errors = 0
        labels = 0
        exe = target.text("output_format") != 0 and strings.compare(target.text("output_format"), "exe") == 0
        need_div = false
        need_divs = false
        need_mul32 = false
        need_div32 = false
        need_divs32 = false
        need_long = false
        need_print = false
        wide_error = false
        uses_floats = false
        sys.memset(&slot_used, 256, 0)
        need_vregs = false
        sys.memset(&need_rt, 32, 0)
        if nb == 0
            nb = buf.new(256)
        if cells == 0
            cells = buf.new(65536)
        buf.clear(cells)
        out_buf = output
        part = 0
        long k
        if reg_used == 0
            reg_used = mem.alloc(70000)
        for k in 0 to 69999
            reg_used[k] = 0
        if body == 0
            body = buf.new(65536)
        buf.clear(body)
        ; (the memory-mapped variables, for the pass over the assembly: their values may
        ; change by themselves)
        if peep8086.volatile == 0
            peep8086.volatile = buf.new(1024)
        buf.clear(peep8086.volatile)
        buf.add_byte(peep8086.volatile, '\n')
        ^^ir.Var mv = p.vars
        while mv != 0 {
            if mv.kind == ir.V_MEMVAR {
                o = peep8086.volatile
                name(mv.name)
                nl()
            }
            mv = mv.next
        }
        o = body
        put("p8_init_globals:")
        nl()
        previous = 0
        chunk_code(prog.initglobals)
        line("ret")
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
        o = out_buf
        buf.clear(o)
        head()
        buf.add_bytes(o, body.data, body.len)
        branches()
    }

    ; the value of one of the program's options ("loadAddress"), or 0
    sub option(str key) -> ^^ubyte {
        ^^ubyte t = prog.options
        if t == 0
            return 0
        long keylen = buf.cstr_len(key)
        long i = 0
        while t[i] != 0 {
            if buf.bytes_equal(t + i, key, keylen) and t[i + keylen] == '=' {
                long first = i + keylen + 1
                long stop = first
                while t[stop] != 0 and t[stop] != '\n'
                    stop++
                return strtab.intern(t + first, (stop - first) as uword)
            }
            while t[i] != 0 and t[i] != '\n'
                i++
            if t[i] == '\n'
                i++
        }
        return 0
    }

    ; where the program begins: the target's load address, or what %address or -address
    ; says
    sub load_address() -> long {
        long begins = target.number("load_address", $0100)
        ^^ubyte given = option("loadAddress")
        if given != 0
            begins = number_of(given)
        return begins
    }

    ; The first lines: the program begins at the target's load address with the
    ; target's first instructions.
    sub head() {
        put("; Program: ")
        put(prog.name)
        nl()
        raw("; written by p8p8's 8086 code generator, for nasm")
        line("cpu  8086")
        line("bits  16")
        if uses_floats {
            ; How the library's float routines are written: for the 8087 alone (0),
            ; without one (1), or both, with the choice made when the program starts
            ; (2).  The target file says which (floats = 8087, software or auto).
            ^^ubyte how = target.text("floats")
            put("%define p8f_mode ")
            if how != 0 and strings.compare(how, "8087") == 0
                put("0")
            else if how != 0 and strings.compare(how, "software") == 0
                put("1")
            else
                put("2")
            nl()
        }
        if exe {
            ; The header of an .EXE file: the file's size in pages of 512 bytes, no
            ; relocations (nothing in the program names a segment), a header of two
            ; paragraphs, the memory wanted beyond the file (the data's segment in
            ; full), then SS (the data's segment, counted from the program's first)
            ; and SP, and IP and CS.  The data's addresses begin at 256, as a .COM
            ; file's do (no variable is at an address that a program takes for
            ; none), so its segment begins 16 paragraphs before the data itself.
            raw("section .header start=0")
            line("db  'MZ'")
            line("dw  p8_file_size % 512")
            line("dw  (p8_file_size + 511) / 512")
            line("dw  0")
            line("dw  2")
            line("dw  (65536 - 256 - (p8_data_end - p8_data_start) + 15) / 16")
            line("dw  0xffff")
            line("dw  p8_code_paragraphs - 16")
            line("dw  0xfffe")
            line("dw  0")
            line("dw  p8_start")
            line("dw  0")
            line("dw  0x1c")
            line("dw  0")
            line("times  32-($-$$)  db  0")
            raw("section .text vstart=0 align=16 follows=.header")
            raw("p8_code_start:")
        }
        else {
            put("    org  ")
            putn(load_address())
            nl()
        }
        raw("p8_start:")
        ; (the machine's first instructions, when it needs any)
        if target.text("startup_code") != 0
            target_lines("startup_code")
        ; the variables without values are zero
        line("cld")
        line("mov  di, p8_bss_start")
        line("mov  cx, p8_bss_end-p8_bss_start")
        line("xor  al, al")
        line("rep stosb")
        ; (floats: is there an 8087?)
        if uses_floats
            line("call  p8f_init")
        line("call  p8_init_globals")
        line("call  _main__start")
        line("xor  al, al")
        ; How the program ends, as the target file says; sys.exit comes here too, with
        ; the status in AL.  Before the end, what the target wants done there
        ; (exit_hook), when it has that.
        raw("p8_exit:")
        if target.text("exit_hook") != 0
            target_lines("exit_hook")
        target_lines("exit_code")
        nl()
    }

    ; the lines of a key of the target file, as instructions
    sub target_lines(str key) {
        ^^ubyte text = target.text(key)
        if text == 0 {
            error("the target file lacks a key that an 8086 machine needs", key)
            return
        }
        text_lines(text, buf.cstr_len(text))
    }

    sub text_lines(^^ubyte text, long length) {
        long k = 0
        while k < length {
            ; (a label, a line that ends with a colon, stands at the margin)
            long stop = k
            while stop < length and text[stop] != '\n'
                stop++
            if stop == k or text[stop - 1] != ':'
                put("    ")
            buf.add_bytes(o, text + k, stop - k)
            nl()
            k = stop
            if k < length and text[k] == '\n'
                k++
        }
    }

    sub subroutine(^^ir.Sub s) {
        if s.is_external
            return
        if s.is_asm and s.asmtext != 0 and not s.asm_is_ir {
            ; A subroutine in assembly (asmsub), as it stands: it returns by itself.  One
            ; that is declared inline has no return of its own; it is called like the
            ; others here.
            put("; ---- ")
            put(s.name)
            nl()
            label(s.name)
            raw(";%asm")
            asm_lines(s.asmtext, s.asmlen)
            raw(";%end")
            if s.is_inline
                line("ret")
            nl()
            return
        }
        if not irparse.expand(s) {
            error("the IR text of a subroutine could not be read", s.name)
            return
        }
        put("; ---- ")
        put(s.name)
        nl()
        long from = o.len
        part++
        this_sub = s
        this_index = index_of(s.name)
        own_registers(s)
        carry_cell = carry_scan(s)
        if register_params(s) != 0 {
            ; (the way in for a call that has arguments in AL, BX and CX)
            put("p8e")
            name(s.name)
            put(":\n")
            ^^ir.Param rp = s.params
            while rp != 0 {
                ubyte where = param_register(s, rp)
                if where != 0 {
                    ins("mov  [")
                    name(rp.name)
                    when where {
                        1 -> put("], al")
                        2 -> put("], bx")
                        else -> put("], cx")
                    }
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
        line("ret")
        nl()
        this_sub = 0
        this_index = -1
        if optimize {
            peep8086.run(o, from)
            still_named(from)
        }
        register_cells()
        if carry_cell {
            buf.add_str(cells, "p8c_")
            buf.add_long(cells, part)
            buf.add_str(cells, ":  resb  1\n")
        }
        carry_cell = false
    }

    ; Assembly of the program's own, a line at a time: a line that ends with a colon is a
    ; label and stands at the margin, the others are set in, whatever the source had
    ; before them.
    sub asm_lines(^^ubyte text, long length) {
        long p = 0
        while p < length {
            while p < length and (text[p] == ' ' or text[p] == '\t' or text[p] == '\r')
                p++
            long stop = p
            while stop < length and text[stop] != '\n'
                stop++
            long last = stop
            while last > p and (text[last - 1] == ' ' or text[last - 1] == '\t' or text[last - 1] == '\r')
                last--
            if last > p {
                if text[last - 1] != ':' and text[p] != ';'
                    put("    ")
                buf.add_bytes(o, text + p, last - p)
                nl()
            }
            p = stop + 1
        }
    }

    ; ---- the IR's carry ----
    ;
    ; The IR has a carry flag that only a compare, clc, sec and the shifts and rotations
    ; by one bit change, and that roxl, roxr, bstcc and bstcs read.  Mostly the reader comes
    ; straight after what set it, and the 8086's own carry serves (a "mov" leaves it
    ; alone).  A subroutine where it does not keeps the flag in a place of its own:
    ; clear at its start, as on the host, where each subroutine has its own flags;
    ; every instruction that sets it stores it there, and a reader takes it from there.
    ; The place holds the IR's carry, which after a compare is the other way round than
    ; the 8086's (the IR's is the 6502's: clear for "less").

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
    ; 8086's own?
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
        put("[p8c_")
        putn(part)
        put("]")
    }

    sub carry_clear() {
        if carry_cell {
            ins("mov  byte ")
            carry_place()
            put(", 0")
            nl()
        }
    }

    ; after an instruction that set the carry: into the place (the flags' low byte,
    ; whose lowest bit it is), with the flags and AX as they were
    sub carry_save(ubyte opc) {
        line("pushf")
        line("push  ax")
        line("lahf")
        if opc == ir.OP_CMP or opc == ir.OP_CMPI
            line("xor  ah, 1")
        ins("mov  ")
        carry_place()
        put(", ah")
        nl()
        line("pop  ax")
        line("popf")
    }

    ; before an instruction that reads the carry: from the place, when it is not at hand
    sub carry_in(^^ir.Instr i) {
        carry_loaded = false
        if carry_cell and not carry_at_hand(i, previous) {
            ins("mov  ah, ")
            carry_place()
            nl()
            line("sahf")
            carry_loaded = true
        }
    }

    ; After the pass over the assembly: only the IR registers whose places the lines from
    ; position from on still name get one.
    sub still_named(long from) {
        uword r
        for r in 1 to ir.regcount
            reg_used[r] = 0
        long p = from
        long last = o.len - 6
        while p < last {
            if o.data[p] == 'p' and o.data[p + 1] == '8' and o.data[p + 2] == 'r' and o.data[p + 3] == '_' {
                p += 4
                while p < o.len and o.data[p] >= '0' and o.data[p] <= '9'
                    p++
                p++
                long n = 0
                while p < o.len and o.data[p] >= '0' and o.data[p] <= '9' {
                    n = n * 10 + (o.data[p] - '0')
                    p++
                }
                if n >= 1 and n <= ir.regcount
                    reg_used[n] = 1
            }
            else
                p++
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
                buf.add_str(cells, ":  resb  ")
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
                    error("IR text outside a subroutine cannot be used on the 8086", c.label)
            }
            else {
                ; 8086 assembly of the program's own (%asm), as it stands.  It names the
                ; program's variables as this generator writes them: an underscore, and
                ; two underscores for each dot (txt.plot.col is _txt__plot__col).
                raw(";%asm")
                asm_lines(c.text, c.textlen)
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
            if skip_next != 0
                skip_next--
            else {
                instruction(i)
                if carry_cell and carry_setter(i.op)
                    carry_save(i.op)
            }
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
        error("this instruction is not written for the 8086 yet", nb.data)
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
    sub first(^^ir.Instr i, ubyte group, ubyte k, ubyte w) {
        if group <= 2
            cell(i.r1, k, w)
        else
            mem(i, k, w)
    }

    sub op_first(str before, ^^ir.Instr i, ubyte group, ubyte k, ubyte w, str after) {
        ins(before)
        first(i, group, k, w)
        put(after)
        nl()
    }

    sub immediate(^^ir.Instr i, ubyte k, ubyte w) -> long {
        if w == 1
            return ((i.value >> (k * 8)) as long) & 255
        return ((i.value >> (k * 8)) as long) & $ffff
    }

    ; "    before<the second operand>": a constant, or a place
    sub op_second(str before, ^^ir.Instr i, ubyte group, ubyte k, ubyte w) {
        ins(before)
        when group {
            1, 4 -> putn(immediate(i, k, w))
            2 -> cell(i.r2, k, w)
            else -> cell(i.r1, k, w)
        }
        nl()
    }

    ; "    mnemonic  first, second": with a constant as it stands, else through AL or AX
    sub first_op_second(str mnemonic, ^^ir.Instr i, ubyte group, ubyte k, ubyte w) {
        if group <= 2 {
            ; (a register's place: through AL or AX, where the pass over the assembly
            ; joins it with what is around it)
            load_cell(i.r1, k, w)
            ins(mnemonic)
            if w == 1
                put("  al, ")
            else
                put("  ax, ")
            if group == 1
                putn(immediate(i, k, w))
            else
                cell(i.r2, k, w)
            nl()
            store_cell(i.r1, k, w)
            return
        }
        if group == 4 {
            ins(mnemonic)
            put("  ")
            first(i, group, k, w)
            put(", ")
            putn(immediate(i, k, w))
            nl()
            return
        }
        ins(mnemonic)
        put("  ")
        first(i, group, k, w)
        if w == 1
            put(", al")
        else
            put(", ax")
        nl()
    }

    ; the second operand into AL or AX, when it is no constant (before first_op_second)
    sub second_at_hand(^^ir.Instr i, ubyte group, ubyte k, ubyte w) {
        if group != 3
            return
        if w == 1
            op_second("mov  al, ", i, group, k, 1)
        else
            op_second("mov  ax, ", i, group, k, 2)
    }

    sub logic_name(ubyte kind, bool carry) -> str {
        when kind {
            0 -> {
                if carry
                    return "adc"
                return "add"
            }
            1 -> {
                if carry
                    return "sbb"
                return "sub"
            }
            2 -> return "and"
            3 -> return "or"
        }
        return "xor"
    }

    ; AX = AX / BX, DX = the remainder: the routine, signed or not
    sub divide(ubyte kind) {
        if kind >= 8 {
            line("call  p8rt_divs16")
            need_divs = true
        }
        else {
            line("call  p8rt_div16")
            need_div = true
        }
    }

    ; a byte in AL made a word in AX, by the kind of division
    sub widen(ubyte kind) {
        if kind >= 8
            line("cbw")
        else
            line("xor  ah, ah")
    }

    ; the operands of a long multiplication or division into the cells of the routines
    sub long_cells(^^ir.Instr i, ubyte group) {
        op_first("mov  ax, ", i, group, 0, 2, "")
        line("mov  [p8_la], ax")
        op_first("mov  ax, ", i, group, 2, 2, "")
        line("mov  [p8_la+2], ax")
        op_second("mov  ax, ", i, group, 0, 2)
        line("mov  [p8_lb], ax")
        op_second("mov  ax, ", i, group, 2, 2)
        line("mov  [p8_lb+2], ax")
        need_long = true
    }

    ; the routine: the product and a remainder come in p8_lc, a quotient in p8_la
    sub long_call(ubyte kind) {
        if kind == 5 {
            line("call  p8rt_mul32")
            need_mul32 = true
        }
        else if kind >= 8 {
            line("call  p8rt_divs32")
            need_divs32 = true
            need_div32 = true
        }
        else {
            line("call  p8rt_div32")
            need_div32 = true
        }
    }

    ; how many times 2 a number is when it is a power of two (1 is 0 times), or 255
    sub power_of_two(long value) -> ubyte {
        ubyte n = 0
        if value <= 0 or (value & (value - 1)) != 0
            return 255
        while value > 1 {
            value >>= 1
            n++
        }
        return n
    }

    ; "    mnemonic  first, 1", or by CL for more bits than one (the 8086 has no shift
    ; by a constant other than 1)
    sub shift_first(str mnemonic, ^^ir.Instr i, ubyte group, ubyte w, ubyte count) {
        if count == 0
            return
        if count > 1
            op_imm("mov  cl, ", count)
        if group <= 2 {
            load_cell(i.r1, 0, w)
            ins(mnemonic)
            if w == 1
                put("  al")
            else
                put("  ax")
        }
        else {
            ins(mnemonic)
            put("  ")
            first(i, group, 0, w)
        }
        if count > 1
            put(", cl")
        else
            put(", 1")
        nl()
        if group <= 2
            store_cell(i.r1, 0, w)
    }

    ; Times, divided by, or the remainder by a constant that is a power of two, without
    ; a sign (a product does not mind one): a shift, or a mask.  False when it is not
    ; such an instruction.
    sub by_power_of_two(^^ir.Instr i, ubyte group, ubyte kind, ubyte size) -> bool {
        if (group != 1 and group != 4) or size > 2 or (kind != 5 and kind != 6 and kind != 7)
            return false
        long constant = (i.value as long) & $ffff
        if size == 1
            constant &= 255
        ubyte n = power_of_two(constant)
        if n == 255
            return false
        if kind == 7 and group == 1 {
            load_cell(i.r1, 0, size)
            if size == 1
                op_imm("and  al, ", constant - 1)
            else
                op_imm("and  ax, ", constant - 1)
            store_cell(i.r1, 0, size)
        }
        else if kind == 7 {
            ins("and  ")
            first(i, group, 0, size)
            put(", ")
            putn(constant - 1)
            nl()
        }
        else if kind == 5
            shift_first("shl", i, group, size, n)
        else
            shift_first("shr", i, group, size, n)
        return true
    }

    ; the flags of what is first, for a branch on the status that follows an
    ; instruction whose last step left none
    sub first_flags(^^ir.Instr i, ubyte group, ubyte size) {
        if group >= 3 and size <= 2 and flags_wanted(i)
            op_first("cmp  ", i, group, 0, size, ", 0")
    }

    ; an arithmetic instruction of any size
    sub arith(^^ir.Instr i, ubyte group) {
        ubyte size = size_of(i.type)
        ubyte kind = kind_of(i.op)
        ubyte half
        if by_power_of_two(i, group, kind, size)
            return
        if size == 1 or size == 2 {
            if kind <= 4 {
                second_at_hand(i, group, 0, size)
                first_op_second(logic_name(kind, false), i, group, 0, size)
            }
            else if kind == 5 {
                ; (a product's low half is the same with a sign and without)
                if size == 1 {
                    op_first("mov  al, ", i, group, 0, 1, "")
                    if group == 1 or group == 4 {
                        op_imm("mov  ah, ", immediate(i, 0, 1))
                        line("mul  ah")
                    }
                    else
                        op_second("mul  ", i, group, 0, 1)
                    op_first("mov  ", i, group, 0, 1, ", al")
                }
                else {
                    op_first("mov  ax, ", i, group, 0, 2, "")
                    if group == 1 or group == 4 {
                        op_imm("mov  dx, ", immediate(i, 0, 2))
                        line("mul  dx")
                    }
                    else
                        op_second("mul  ", i, group, 0, 2)
                    op_first("mov  ", i, group, 0, 2, ", ax")
                }
                first_flags(i, group, size)
            }
            else {
                ; a division: the divisor in BX, the dividend in AX, both as words
                if size == 1 {
                    if group == 1 or group == 4 {
                        ; (a constant: as a word, with its sign when the division has one)
                        long divisor = (i.value as long) & 255
                        if kind >= 8 and divisor >= 128
                            divisor |= $ff00
                        op_imm("mov  bx, ", divisor)
                    }
                    else {
                        op_second("mov  al, ", i, group, 0, 1)
                        widen(kind)
                        line("mov  bx, ax")
                    }
                    op_first("mov  al, ", i, group, 0, 1, "")
                    widen(kind)
                    divide(kind)
                    if kind == 7 or kind == 9
                        op_first("mov  ", i, group, 0, 1, ", dl")       ; (the remainder)
                    else
                        op_first("mov  ", i, group, 0, 1, ", al")
                }
                else {
                    op_second("mov  bx, ", i, group, 0, 2)
                    op_first("mov  ax, ", i, group, 0, 2, "")
                    divide(kind)
                    if kind == 7 or kind == 9
                        op_first("mov  ", i, group, 0, 2, ", dx")
                    else
                        op_first("mov  ", i, group, 0, 2, ", ax")
                }
                first_flags(i, group, size)
            }
        }
        else if size == 4 {
            if kind <= 1 {
                ; A long sum or difference: the low words, then the high words with
                ; the carry (no "mov" between them changes it).
                second_at_hand(i, group, 0, 2)
                first_op_second(logic_name(kind, false), i, group, 0, 2)
                second_at_hand(i, group, 2, 2)
                first_op_second(logic_name(kind, true), i, group, 2, 2)
            }
            else if kind <= 4 {
                for half in 0 to 1 {
                    second_at_hand(i, group, half * 2, 2)
                    first_op_second(logic_name(kind, false), i, group, half * 2, 2)
                }
            }
            else {
                long_cells(i, group)
                long_call(kind)
                if kind == 6 or kind == 8 {
                    line("mov  ax, [p8_la]")
                    op_first("mov  ", i, group, 0, 2, ", ax")
                    line("mov  ax, [p8_la+2]")
                    op_first("mov  ", i, group, 2, 2, ", ax")
                }
                else {
                    line("mov  ax, [p8_lc]")
                    op_first("mov  ", i, group, 0, 2, ", ax")
                    line("mov  ax, [p8_lc+2]")
                    op_first("mov  ", i, group, 2, 2, ", ax")
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
            if group == 1 {
                long divisor = (i.value as long) & 255
                if kind >= 8 and divisor >= 128
                    divisor |= $ff00
                op_imm("mov  bx, ", divisor)
            }
            else {
                op_second("mov  al, ", i, group, 0, 1)
                widen(kind)
                line("mov  bx, ax")
            }
            load_cell(i.r1, 0, 1)
            widen(kind)
            divide(kind)
            store_cell(i.r1, 0, 1)
            op_cell("mov  ", i.r2, 0, 1, ", dl")
        }
        else if size == 2 {
            op_second("mov  bx, ", i, group, 0, 2)
            load_cell(i.r1, 0, 2)
            divide(kind)
            store_cell(i.r1, 0, 2)
            op_cell("mov  ", i.r2, 0, 2, ", dx")
        }
        else if size == 4 {
            long_cells(i, group)
            long_call(kind)
            line("mov  ax, [p8_la]")
            store_cell(i.r1, 0, 2)
            line("mov  ax, [p8_la+2]")
            store_cell(i.r1, 2, 2)
            line("mov  ax, [p8_lc]")
            store_cell(i.r2, 0, 2)
            line("mov  ax, [p8_lc+2]")
            store_cell(i.r2, 2, 2)
        }
        else
            unsupported(i)
    }

    ; first = -first
    sub negate(^^ir.Instr i, ubyte group, ubyte size) {
        if size <= 2 and group <= 2 {
            load_cell(i.r1, 0, size)
            if size == 1
                line("neg  al")
            else
                line("neg  ax")
            store_cell(i.r1, 0, size)
            return
        }
        if size <= 2 {
            op_first("neg  ", i, group, 0, size, "")
            return
        }
        op_first("neg  ", i, group, 2, 2, "")
        op_first("neg  ", i, group, 0, 2, "")
        op_first("sbb  ", i, group, 2, 2, ", 0")
    }

    ; zero or not: the flags of a long that is first
    sub long_zero_flags(^^ir.Instr i, ubyte group) {
        op_first("mov  ax, ", i, group, 0, 2, "")
        op_first("or  ax, ", i, group, 2, 2, "")
    }

    ; A part of r1 against the same part of the second operand: the flags of the
    ; difference.
    sub compare_part(^^ir.Instr i, ubyte group, ubyte k, ubyte w) {
        if group == 1 {
            ins("cmp  ")
            cell(i.r1, k, w)
            put(", ")
            putn(immediate(i, k, w))
            nl()
            return
        }
        load_cell(i.r1, k, w)
        if w == 1
            op_cell("cmp  al, ", i.r2, k, 1, "")
        else
            op_cell("cmp  ax, ", i.r2, k, 2, "")
    }

    ; A long compare, unsigned: r1 against r2 or the immediate.  It leaves what the short
    ; ones leave: carry is "less", zero is "equal".
    sub long_compare(^^ir.Instr i, bool with_register) {
        ubyte group = 1
        if with_register
            group = 2
        long skip = new_label()
        compare_part(i, group, 2, 2)
        jump_if_local("jne", skip)
        compare_part(i, group, 0, 2)
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
            op_cell("cmp  ", r, size - 1, 1, ", 0")
        else if size == 2
            op_cell("cmp  ", r, 0, 2, ", 0")
        else {
            load_cell(r, 0, 2)
            op_cell("or  ax, ", r, 2, 2, "")
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

    ; "    jcc  target": as it is; the pass over the finished text makes it reach
    sub jump_if(str branch, ^^ubyte target_name) {
        ins(branch)
        put("  ")
        name(target_name)
        nl()
    }

    sub jump_if_local(str branch, long n) {
        ins(branch)
        put("  ")
        put_local(n)
        nl()
    }

    ; the first operand of a compare against the second
    sub compare_operands(^^ir.Instr i, ubyte size, bool with_register) {
        ubyte group = 1
        if with_register
            group = 2
        compare_part(i, group, 0, size)
    }

    ; the jump of a relation (0 greater, 1 less, 2 greater or equal, 3 less or equal)
    sub relation_branch(ubyte relation, bool signed) -> str {
        if signed {
            when relation {
                0 -> return "jg"
                1 -> return "jl"
                2 -> return "jge"
            }
            return "jle"
        }
        when relation {
            0 -> return "ja"
            1 -> return "jb"
            2 -> return "jae"
        }
        return "jbe"
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
            compare_part(i, group, 2, 2)
            if relation == 0 or relation == 2
                jump_if("jg", i.sym)
            else
                jump_if("jl", i.sym)
            jump_if_local("jne", skip)
            compare_part(i, group, 0, 2)
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
            uses_floats = true
            if not float_instruction(i)
                unsupported(i)
            return
        }
        when i.op {
            ir.OP_NOP, ir.OP_BREAKPOINT, ir.OP_ALIGN -> {
            }
            ir.OP_LOAD -> {
                if i.sym != 0 {
                    ins("mov  ")
                    cell(i.r1, 0, 2)
                    put(", ")
                    mem_name(i, 0)
                    nl()
                }
                else if size == 1
                    op_cell("mov  ", i.r1, 0, 1, immediate_text(immediate(i, 0, 1)))
                else if size == 2
                    op_cell("mov  ", i.r1, 0, 2, immediate_text(immediate(i, 0, 2)))
                else if size == 4 {
                    op_cell("mov  ", i.r1, 0, 2, immediate_text(immediate(i, 0, 2)))
                    op_cell("mov  ", i.r1, 2, 2, immediate_text(immediate(i, 2, 2)))
                }
                else
                    unsupported(i)
            }
            ir.OP_LOADM -> {
                if size == 0
                    unsupported(i)
                else if size == 1 {
                    load_mem(i, 0, 1)
                    store_cell(i.r1, 0, 1)
                }
                else {
                    load_mem(i, 0, 2)
                    store_cell(i.r1, 0, 2)
                    if size == 4 {
                        load_mem(i, 2, 2)
                        store_cell(i.r1, 2, 2)
                    }
                }
            }
            ir.OP_LOADMZ -> {
                ; a byte from memory into a wider register, the rest zero
                load_mem(i, 0, 1)
                if rsize(i.r1) == 1
                    store_cell(i.r1, 0, 1)
                else {
                    line("xor  ah, ah")
                    store_cell(i.r1, 0, 2)
                    if rsize(i.r1) == 4
                        op_cell("mov  ", i.r1, 2, 2, ", 0")
                }
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
                k = 0
                while k < size {
                    ubyte w = 1
                    if size - k >= 2
                        w = 2
                    if i.op == ir.OP_LOADHR {
                        if w == 1
                            op_slot("mov  al, ", i.slot, k, 1, "")
                        else
                            op_slot("mov  ax, ", i.slot, k, 2, "")
                        store_cell(i.r1, k, w)
                    }
                    else {
                        load_cell(i.r1, k, w)
                        if w == 1
                            op_slot("mov  ", i.slot, k, 1, ", al")
                        else
                            op_slot("mov  ", i.slot, k, 2, ", ax")
                    }
                    k += w
                }
            }
            ir.OP_STOREM -> {
                if size == 0
                    unsupported(i)
                else if size == 1 {
                    load_cell(i.r1, 0, 1)
                    store_mem(i, 0, 1)
                }
                else {
                    load_cell(i.r1, 0, 2)
                    store_mem(i, 0, 2)
                    if size == 4 {
                        load_cell(i.r1, 2, 2)
                        store_mem(i, 2, 2)
                    }
                }
            }
            ir.OP_STOREZM -> {
                if size == 0
                    unsupported(i)
                else if size == 1
                    op_mem("mov  ", i, 0, 1, ", 0")
                else {
                    op_mem("mov  ", i, 0, 2, ", 0")
                    if size == 4
                        op_mem("mov  ", i, 2, 2, ", 0")
                }
            }
            ir.OP_STOREIM -> {
                if size == 0
                    unsupported(i)
                else if size == 1
                    op_mem("mov  ", i, 0, 1, immediate_text(immediate(i, 0, 1)))
                else {
                    op_mem("mov  ", i, 0, 2, immediate_text(immediate(i, 0, 2)))
                    if size == 4
                        op_mem("mov  ", i, 2, 2, immediate_text(immediate(i, 2, 2)))
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
                    zero_at_x(0, size)
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
                    zero_at_x(i.offset, size)
                }
            }
            ir.OP_JUMP -> jump_if("jmp", i.sym)
            ir.OP_JUMPI -> op_cell("jmp  ", i.r1, 0, 2, "")
            ir.OP_CALL -> call_instruction(i)
            ir.OP_CALLI -> {
                op_cell("call  ", i.r1, 0, 2, "")
                ; (what it returns is taken from slot 10 by the code that follows: a byte
                ; comes in AL, the low half of AX)
                op_slot("mov  ", 10, 0, 2, ", ax")
                op_slot("mov  ", 10, 2, 2, ", dx")
            }
            ir.OP_SYSCALL -> syscall(i)
            ir.OP_RETURN -> line("ret")
            ir.OP_RETURNR -> {
                if size != 0 {
                    fetch(i.r1, size)
                    line("ret")
                }
                else
                    unsupported(i)
            }
            ir.OP_RETURNI -> {
                if size == 1
                    op_imm("mov  al, ", immediate(i, 0, 1))
                else if size == 2
                    op_imm("mov  ax, ", immediate(i, 0, 2))
                else if size == 4 {
                    op_imm("mov  ax, ", immediate(i, 0, 2))
                    op_imm("mov  dx, ", immediate(i, 2, 2))
                }
                else
                    unsupported(i)
                line("ret")
            }
            ir.OP_BSTEQ -> {
                flags_for_branch(false)
                jump_if("je", i.sym)
            }
            ir.OP_BSTNE -> {
                flags_for_branch(false)
                jump_if("jne", i.sym)
            }
            ir.OP_BSTNEG -> {
                flags_for_branch(true)
                jump_if("js", i.sym)
            }
            ir.OP_BSTPOS -> {
                flags_for_branch(true)
                jump_if("jns", i.sym)
            }
            ; (the IR's carry is the 6502's: clear after a compare means "less".  A compare
            ; here leaves the 8086's, which is set then.)
            ir.OP_BSTCC -> {
                carry_in(i)
                if not carry_loaded and previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("jc", i.sym)
                else
                    jump_if("jnc", i.sym)
            }
            ir.OP_BSTCS -> {
                carry_in(i)
                if not carry_loaded and previous != 0 and (previous.op == ir.OP_CMP or previous.op == ir.OP_CMPI)
                    jump_if("jnc", i.sym)
                else
                    jump_if("jc", i.sym)
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
                if (size == 1 or size == 2) and where == 1 {
                    load_cell(i.r1, 0, size)
                    if up {
                        if size == 1
                            line("inc  al")
                        else
                            line("inc  ax")
                    }
                    else if size == 1
                        line("dec  al")
                    else
                        line("dec  ax")
                    store_cell(i.r1, 0, size)
                }
                else if size == 1 or size == 2 {
                    if up
                        op_first("inc  ", i, where, 0, size, "")
                    else
                        op_first("dec  ", i, where, 0, size, "")
                }
                else if size == 4 {
                    if up {
                        op_first("add  ", i, where, 0, 2, ", 1")
                        op_first("adc  ", i, where, 2, 2, ", 0")
                    }
                    else {
                        op_first("sub  ", i, where, 0, 2, ", 1")
                        op_first("sbb  ", i, where, 2, 2, ", 0")
                    }
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
                else if size <= 2 and place == 1 {
                    load_cell(i.r1, 0, size)
                    if size == 1
                        line("not  al")
                    else
                        line("not  ax")
                    store_cell(i.r1, 0, size)
                }
                else if size <= 2 {
                    op_first("not  ", i, place, 0, size, "")
                    ; ("not" leaves no flags)
                    first_flags(i, place, size)
                }
                else {
                    op_first("not  ", i, place, 0, 2, "")
                    op_first("not  ", i, place, 2, 2, "")
                }
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = the sign of r2: -1, 0 or 1
                if size == 0 {
                    unsupported(i)
                    return
                }
                long done = new_label()
                line("mov  al, 255")
                op_cell("cmp  ", i.r2, size - 1, 1, ", 0")
                jump_if_local("js", done)
                line("mov  al, 1")
                if size == 2
                    op_cell("cmp  ", i.r2, 0, 2, ", 0")
                else if size == 4 {
                    op_cell("mov  bx, ", i.r2, 0, 2, "")
                    op_cell("or  bx, ", i.r2, 2, 2, "")
                }
                jump_if_local("jne", done)
                line("xor  al, al")
                local(done)
                store_cell(i.r1, 0, 1)
            }
            ir.OP_LSL, ir.OP_LSR, ir.OP_ASR, ir.OP_ROL, ir.OP_ROR, ir.OP_ROXL, ir.OP_ROXR -> shift_register(i, 1, size, 1)
            ir.OP_LSLM, ir.OP_LSRM, ir.OP_ASRM, ir.OP_ROLM, ir.OP_RORM, ir.OP_ROXLM, ir.OP_ROXRM -> shift_register(i, 1, size, 3)
            ir.OP_LSLI, ir.OP_LSRI, ir.OP_ASRI -> shift_register(i, (i.value & 255) as ubyte, size, 1)
            ir.OP_LSLN, ir.OP_LSRN, ir.OP_ASRN, ir.OP_LSLNM, ir.OP_LSRNM, ir.OP_ASRNM -> {
                ; by the number in a register (r2; r1 when memory is shifted)
                if size == 0 {
                    unsupported(i)
                    return
                }
                ubyte spot = 1
                if i.op == ir.OP_LSLNM or i.op == ir.OP_LSRNM or i.op == ir.OP_ASRNM {
                    spot = 3
                    op_cell("mov  cl, ", i.r1, 0, 1, "")
                }
                else
                    op_cell("mov  cl, ", i.r2, 0, 1, "")
                if size <= 2 {
                    ; (the 8086 shifts by CL, as many bits as it says: 16 and more leave
                    ; nothing)
                    if spot == 1 {
                        load_cell(i.r1, 0, size)
                        ins(shift_name(i.op, false))
                        if size == 1
                            put("  al, cl")
                        else
                            put("  ax, cl")
                        nl()
                        store_cell(i.r1, 0, size)
                    }
                    else {
                        ins(shift_name(i.op, false))
                        put("  ")
                        first(i, spot, 0, size)
                        put(", cl")
                        nl()
                    }
                    if spot == 3 and flags_wanted(i)
                        op_first("cmp  ", i, spot, 0, size, ", 0")
                }
                else {
                    ; a long: one bit at a time, with the count in CX
                    long again = new_label()
                    long over = new_label()
                    line("xor  ch, ch")
                    jump_if_local("jcxz", over)
                    local(again)
                    shift_once(i.op, i, spot, size)
                    jump_if_local("loop", again)
                    local(over)
                }
            }
            ir.OP_EXT, ir.OP_EXTS, ir.OP_EXTL, ir.OP_EXTLS -> {
                ; r1 (a wider type) = r2 (the instruction's type)
                ubyte wide = rsize(i.r1)
                if size == 0 or wide <= size or size > 2 {
                    unsupported(i)
                    return
                }
                bool signed = i.op == ir.OP_EXTS or i.op == ir.OP_EXTLS
                if size == 1 {
                    load_cell(i.r2, 0, 1)
                    if signed
                        line("cbw")
                    else
                        line("xor  ah, ah")
                }
                else
                    load_cell(i.r2, 0, 2)
                store_cell(i.r1, 0, 2)
                if wide == 4 {
                    if signed {
                        line("cwd")
                        op_cell("mov  ", i.r1, 2, 2, ", dx")
                    }
                    else
                        op_cell("mov  ", i.r1, 2, 2, ", 0")
                }
            }
            ir.OP_LSIGB -> {
                ; the low byte of r2
                load_cell(i.r2, 0, 1)
                store_cell(i.r1, 0, 1)
            }
            ir.OP_LSIGW -> {
                load_cell(i.r2, 0, 2)
                store_cell(i.r1, 0, 2)
            }
            ir.OP_MSIGB -> {
                ; the high byte of r2, which is of the instruction's type
                if size == 0 {
                    unsupported(i)
                    return
                }
                load_cell(i.r2, size - 1, 1)
                store_cell(i.r1, 0, 1)
            }
            ir.OP_MSIGW -> {
                load_cell(i.r2, 2, 2)
                store_cell(i.r1, 0, 2)
            }
            ir.OP_CONCAT -> {
                ; r1 = r2 (the high half) and r3 (the low half), each of the instruction's type
                if size == 1 or size == 2 {
                    load_cell(i.r3, 0, size)
                    store_cell(i.r1, 0, size)
                    load_cell(i.r2, 0, size)
                    store_cell(i.r1, size, size)
                }
                else
                    unsupported(i)
            }
            ir.OP_PUSH -> {
                if size == 1 {
                    load_cell(i.r1, 0, 1)
                    line("push  ax")
                }
                else if size == 2 or size == 4 {
                    op_cell("push  ", i.r1, 0, 2, "")
                    if size == 4
                        op_cell("push  ", i.r1, 2, 2, "")
                }
                else
                    unsupported(i)
            }
            ir.OP_POP -> {
                if size == 1 {
                    line("pop  ax")
                    store_cell(i.r1, 0, 1)
                }
                else if size == 2
                    op_cell("pop  ", i.r1, 0, 2, "")
                else if size == 4 {
                    op_cell("pop  ", i.r1, 2, 2, "")
                    op_cell("pop  ", i.r1, 0, 2, "")
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
                if size == 1 {
                    load_cell(i.r2, 0, 1)
                    line("xor  ah, ah")
                }
                else
                    load_cell(i.r2, 0, 2)
                line("mov  [p8_la], ax")
                if size == 4 {
                    load_cell(i.r2, 2, 2)
                    line("mov  [p8_la+2], ax")
                }
                else
                    line("mov  word [p8_la+2], 0")
                line("call  p8rt_sqrt32")
                need_rt[RT_SQRT] = true
                need_long = true
                if rsize(i.r1) >= 2
                    store_cell(i.r1, 0, 2)
                else
                    store_cell(i.r1, 0, 1)
            }
            ; (the IR's names are the 6502's: sei stops the interrupts, cli lets them come)
            ir.OP_SEI -> line("cli")
            ir.OP_CLI -> line("sti")
            ir.OP_CLC -> line("clc")
            ir.OP_SEC -> line("stc")
            else -> unsupported(i)
        }
    }

    ; ---- floats ----
    ;
    ; A float is an IEEE double: eight bytes, the low ones first.  Loads, stores and
    ; moves are those of four words (through SI and DI, with "movsw").  Arithmetic is
    ; routines of the library's floats module (p8f_add ...: with the 8087 or without
    ; one), which work on the number that DI points at with the one that SI points
    ; at.  A float that a subroutine returns is in the module's accumulator
    ; (floats.fac), a constant operand in its scratch place (floats.operand).

    ; where a float is: the place of a register, the instruction's memory operand, a
    ; number of bytes from where BX points, the accumulator, or the scratch place
    const ubyte F_CELL = 0
    const ubyte F_MEM = 1
    const ubyte F_X = 2
    const ubyte F_FAC = 3
    const ubyte F_SCRATCH = 4
    float fc_value
    uword[4] fc_words

    ; the address of a float's place (not one through BX)
    sub fname(ubyte kind, uword r, ^^ir.Instr i) {
        when kind {
            F_CELL -> {
                if r <= ir.regcount
                    reg_used[r] = 1
                put("p8r_")
                putn(part)
                put("_")
                putn(r)
            }
            F_MEM -> mem_name(i, 0)
            F_FAC -> put("_floats__fac")
            else -> put("_floats__operand")
        }
    }

    sub bx_offset(long at) {
        put("bx")
        at &= $ffff
        if at >= $8000 {
            put("-")
            putn($10000 - at)
        }
        else
            plus(at)
    }

    ; SI or DI = the address of a float's place
    sub faddr(str reg, ubyte kind, uword r, ^^ir.Instr i, long base) {
        if kind == F_X {
            ins("lea  ")
            put(reg)
            put(", [")
            bx_offset(base)
            put("]")
            nl()
            return
        }
        ins("mov  ")
        put(reg)
        put(", ")
        fname(kind, r, i)
        nl()
    }

    ; "word [..]" or "byte [..]": w bytes at offset k of a float's place
    sub fpart(ubyte kind, uword r, ^^ir.Instr i, long base, ubyte k, ubyte w) {
        width(w)
        if kind == F_X
            bx_offset(base + k)
        else {
            fname(kind, r, i)
            plus(k)
        }
        put("]")
    }

    ; one float = another: the first place named is where it goes
    sub fcopy(ubyte to_kind, uword to_r, ^^ir.Instr to_i, long to_base, ubyte from_kind, uword from_r, ^^ir.Instr from_i, long from_base) {
        faddr("si", from_kind, from_r, from_i, from_base)
        faddr("di", to_kind, to_r, to_i, to_base)
        line("movsw")
        line("movsw")
        line("movsw")
        line("movsw")
    }

    ; the four words of a double (the compiler's own floats are such)
    sub float_words(float value) {
        fc_value = value
        ubyte k
        for k in 0 to 3
            fc_words[k] = mkword(@(&fc_value + k * 2 + 1), @(&fc_value + k * 2))
    }

    ; a constant into a float's place
    sub fconst(float value, ubyte kind, uword r, ^^ir.Instr i, long base) {
        float_words(value)
        ubyte k
        for k in 0 to 3 {
            ins("mov  ")
            fpart(kind, r, i, base, k * 2, 2)
            put(", ")
            putn(fc_words[k])
            nl()
        }
    }

    sub fzero(ubyte kind, uword r, ^^ir.Instr i, long base) {
        ubyte k
        for k in 0 to 3 {
            ins("mov  ")
            fpart(kind, r, i, base, k * 2, 2)
            put(", 0")
            nl()
        }
    }

    ; first = first op second (see first for the groups); with_one: the second is 1.0
    sub float_arith(^^ir.Instr i, ubyte group, ubyte kind, bool with_one) {
        if with_one or group == 1 or group == 4 {
            if with_one
                fconst(1.0, F_SCRATCH, 0, 0, 0)
            else
                fconst(i.fvalue, F_SCRATCH, 0, 0, 0)
            faddr("si", F_SCRATCH, 0, 0, 0)
        }
        else if group == 2
            faddr("si", F_CELL, i.r2, 0, 0)
        else
            faddr("si", F_CELL, i.r1, 0, 0)
        if group >= 3
            faddr("di", F_MEM, 0, i, 0)
        else
            faddr("di", F_CELL, i.r1, 0, 0)
        when kind {
            0 -> line("call  p8f_add")
            1 -> line("call  p8f_sub")
            5 -> line("call  p8f_mul")
            else -> line("call  p8f_div")
        }
    }

    ; r1 = a function of r2, by a routine that works on the number where DI points
    sub float_function(^^ir.Instr i, str routine) {
        if i.r1 != i.r2
            fcopy(F_CELL, i.r1, 0, 0, F_CELL, i.r2, 0, 0)
        faddr("di", F_CELL, i.r1, 0, 0)
        ins("call  ")
        put(routine)
        nl()
    }

    ; An instruction with floats; false when it is one that is not written.
    sub float_instruction(^^ir.Instr i) -> bool {
        ubyte k
        when i.op {
            ir.OP_LOAD -> fconst(i.fvalue, F_CELL, i.r1, 0, 0)
            ir.OP_LOADM -> fcopy(F_CELL, i.r1, 0, 0, F_MEM, 0, i, 0)
            ir.OP_STOREM -> fcopy(F_MEM, 0, i, 0, F_CELL, i.r1, 0, 0)
            ir.OP_LOADR -> fcopy(F_CELL, i.r1, 0, 0, F_CELL, i.r2, 0, 0)
            ir.OP_LOADX -> {
                x_address(i, true)
                fcopy(F_CELL, i.r1, 0, 0, F_X, 0, 0, 0)
            }
            ir.OP_STOREX -> {
                x_address(i, true)
                fcopy(F_X, 0, 0, 0, F_CELL, i.r1, 0, 0)
            }
            ir.OP_LOADI -> {
                x_pointer(i)
                fcopy(F_CELL, i.r1, 0, 0, F_X, 0, 0, i.offset)
            }
            ir.OP_STOREI -> {
                x_pointer(i)
                fcopy(F_X, 0, 0, i.offset, F_CELL, i.r1, 0, 0)
            }
            ir.OP_STOREZM -> fzero(F_MEM, 0, i, 0)
            ir.OP_STOREZX -> {
                x_address(i, true)
                fzero(F_X, 0, 0, 0)
            }
            ir.OP_STOREZI -> {
                x_pointer(i)
                fzero(F_X, 0, 0, i.offset)
            }
            ir.OP_STOREIM -> fconst(i.fvalue, F_MEM, 0, i, 0)
            ir.OP_RETURNR -> {
                fcopy(F_FAC, 0, 0, 0, F_CELL, i.r1, 0, 0)
                line("ret")
            }
            ir.OP_RETURNI -> {
                fconst(i.fvalue, F_FAC, 0, 0, 0)
                line("ret")
            }
            ir.OP_LOADHR, ir.OP_STOREHR -> {
                ; (one of the values that a subroutine returns beside its first)
                if i.slot >= ir.SLOT_FLAGS
                    return false
                for k in 0 to 3 {
                    if i.op == ir.OP_LOADHR {
                        op_slot("mov  ax, ", i.slot, k * 2, 2, "")
                        store_cell(i.r1, k * 2, 2)
                    }
                    else {
                        load_cell(i.r1, k * 2, 2)
                        op_slot("mov  ", i.slot, k * 2, 2, ", ax")
                    }
                }
            }
            ir.OP_PUSH -> {
                for k in 0 to 3
                    op_cell("push  ", i.r1, k * 2, 2, "")
            }
            ir.OP_POP -> {
                for k in 0 to 3
                    op_cell("pop  ", i.r1, 6 - k * 2, 2, "")
            }
            ir.OP_ADD, ir.OP_SUB, ir.OP_MUL, ir.OP_MULS, ir.OP_DIV, ir.OP_DIVS -> float_arith(i, 1, kind_of(i.op), false)
            ir.OP_ADDR, ir.OP_SUBR, ir.OP_MULR, ir.OP_MULSR, ir.OP_DIVR, ir.OP_DIVSR -> float_arith(i, 2, kind_of(i.op), false)
            ir.OP_ADDM, ir.OP_SUBM, ir.OP_MULM, ir.OP_MULSM, ir.OP_DIVM, ir.OP_DIVSM -> float_arith(i, 3, kind_of(i.op), false)
            ir.OP_ADDIM, ir.OP_SUBIM -> float_arith(i, 4, kind_of(i.op), false)
            ir.OP_INC -> float_arith(i, 2, 0, true)
            ir.OP_DEC -> float_arith(i, 2, 1, true)
            ir.OP_INCM -> float_arith(i, 3, 0, true)
            ir.OP_DECM -> float_arith(i, 3, 1, true)
            ir.OP_NEG -> {
                ; (the sign is the top bit)
                ins("xor  ")
                fpart(F_CELL, i.r1, 0, 0, 7, 1)
                put(", 128")
                nl()
            }
            ir.OP_NEGM -> {
                ins("xor  ")
                fpart(F_MEM, 0, i, 0, 7, 1)
                put(", 128")
                nl()
            }
            ir.OP_FABS -> {
                if i.r1 != i.r2
                    fcopy(F_CELL, i.r1, 0, 0, F_CELL, i.r2, 0, 0)
                ins("and  ")
                fpart(F_CELL, i.r1, 0, 0, 7, 1)
                put(", 127")
                nl()
            }
            ir.OP_SQRT -> float_function(i, "p8f_sqrt")
            ir.OP_FFLOOR -> float_function(i, "p8f_floor")
            ir.OP_FCEIL -> float_function(i, "p8f_ceil")
            ir.OP_FROUND -> float_function(i, "p8f_round")
            ir.OP_FFROMUB, ir.OP_FFROMSB, ir.OP_FFROMUW, ir.OP_FFROMSW, ir.OP_FFROMSL -> {
                ; a whole number: as a long in DX and AX
                when i.op {
                    ir.OP_FFROMUB -> {
                        load_cell(i.r2, 0, 1)
                        line("xor  ah, ah")
                        line("xor  dx, dx")
                    }
                    ir.OP_FFROMSB -> {
                        load_cell(i.r2, 0, 1)
                        line("cbw")
                        line("cwd")
                    }
                    ir.OP_FFROMUW -> {
                        load_cell(i.r2, 0, 2)
                        line("xor  dx, dx")
                    }
                    ir.OP_FFROMSW -> {
                        load_cell(i.r2, 0, 2)
                        line("cwd")
                    }
                    else -> {
                        load_cell(i.r2, 0, 2)
                        op_cell("mov  dx, ", i.r2, 2, 2, "")
                    }
                }
                faddr("di", F_CELL, i.r1, 0, 0)
                line("call  p8f_from_long")
            }
            ir.OP_FTOUB, ir.OP_FTOSB, ir.OP_FTOUW, ir.OP_FTOSW, ir.OP_FTOSL -> {
                ; towards zero, as a long in DX and AX; what the register holds of it
                faddr("si", F_CELL, i.r2, 0, 0)
                line("call  p8f_to_long")
                ubyte wide = rsize(i.r1)
                if wide == 1
                    store_cell(i.r1, 0, 1)
                else {
                    store_cell(i.r1, 0, 2)
                    if wide == 4
                        op_cell("mov  ", i.r1, 2, 2, ", dx")
                }
            }
            ir.OP_FCOMP -> {
                ; r1 (a byte) = -1, 0 or 1: r2 against r3
                faddr("di", F_CELL, i.r2, 0, 0)
                faddr("si", F_CELL, i.r3, 0, 0)
                line("call  p8f_cmp")
                store_cell(i.r1, 0, 1)
            }
            ir.OP_SGN -> {
                ; r1 (a byte) = the sign of the float r2; one that is all zeros but for
                ; its sign is zero
                long done = new_label()
                op_cell("mov  bx, ", i.r2, 6, 2, "")
                line("mov  ax, bx")
                line("and  ax, 32767")
                op_cell("or  ax, ", i.r2, 4, 2, "")
                op_cell("or  ax, ", i.r2, 2, 2, "")
                op_cell("or  ax, ", i.r2, 0, 2, "")
                line("mov  al, 0")
                jump_if_local("je", done)
                line("mov  al, 1")
                line("test  bx, bx")
                jump_if_local("jns", done)
                line("mov  al, 255")
                local(done)
                store_cell(i.r1, 0, 1)
            }
            else -> return false
        }
        return true
    }

    ; ", value": the end of an instruction that puts a constant somewhere
    ubyte[16] imm_text
    sub immediate_text(long value) -> str {
        imm_text[0] = ','
        imm_text[1] = ' '
        ubyte n = 2
        ubyte[8] digits
        ubyte count = 0
        repeat {
            digits[count] = '0' + ((value % 10) as ubyte)
            count++
            value /= 10
            if value == 0
                break
        }
        while count != 0 {
            count--
            imm_text[n] = digits[count]
            n++
        }
        imm_text[n] = 0
        return &imm_text
    }

    ; so many bytes at base,BX are zero
    sub zero_at_x(long base, ubyte size) {
        if size == 1
            op_x("mov  ", base, 0, 1, ", 0")
        else {
            op_x("mov  ", base, 0, 2, ", 0")
            if size == 4
                op_x("mov  ", base, 2, 2, ", 0")
        }
    }

    ; ---- shifts ----

    ; the 8086's instruction for a shift or a rotation of the IR; inner is the one for
    ; the parts of a long after the first, which take the bit of the part before
    sub shift_name(ubyte opc, bool inner) -> str {
        bool left = false
        when opc {
            ir.OP_LSL, ir.OP_LSLI, ir.OP_LSLN, ir.OP_LSLM, ir.OP_LSLNM, ir.OP_ROL, ir.OP_ROLM, ir.OP_ROXL, ir.OP_ROXLM -> left = true
        }
        if inner {
            if left
                return "rcl"
            return "rcr"
        }
        when opc {
            ir.OP_LSL, ir.OP_LSLI, ir.OP_LSLN, ir.OP_LSLM, ir.OP_LSLNM -> return "shl"
            ir.OP_LSR, ir.OP_LSRI, ir.OP_LSRN, ir.OP_LSRM, ir.OP_LSRNM -> return "shr"
            ir.OP_ASR, ir.OP_ASRI, ir.OP_ASRN, ir.OP_ASRM, ir.OP_ASRNM -> return "sar"
            ir.OP_ROL, ir.OP_ROLM -> return "rol"
            ir.OP_ROR, ir.OP_RORM -> return "ror"
            ir.OP_ROXL, ir.OP_ROXLM -> return "rcl"
        }
        return "rcr"
    }

    ; one bit
    sub shift_once(ubyte opc, ^^ir.Instr i, ubyte place, ubyte size) {
        bool around = opc == ir.OP_ROL or opc == ir.OP_ROLM or opc == ir.OP_ROR or opc == ir.OP_RORM
        bool left = false
        when opc {
            ir.OP_LSL, ir.OP_LSLI, ir.OP_LSLN, ir.OP_LSLM, ir.OP_LSLNM, ir.OP_ROL, ir.OP_ROLM, ir.OP_ROXL, ir.OP_ROXLM -> left = true
        }
        if size <= 2 and place == 1 {
            load_cell(i.r1, 0, size)
            ins(shift_name(opc, false))
            if size == 1
                put("  al, 1")
            else
                put("  ax, 1")
            nl()
            store_cell(i.r1, 0, size)
            return
        }
        if size <= 2 {
            ins(shift_name(opc, false))
            put("  ")
            first(i, place, 0, size)
            put(", 1")
            nl()
            return
        }
        ; a long: its two words, the second with the bit that left the first.  A
        ; rotation around is a shift, and the bit that left comes in at the other end
        ; (the carry stays what it was).
        long skip = 0
        ^^ubyte outer = shift_name(opc, false)
        if around {
            if left
                outer = "shl"
            else
                outer = "shr"
        }
        if left {
            ins(outer)
            put("  ")
            first(i, place, 0, 2)
            put(", 1")
            nl()
            op_first("rcl  ", i, place, 2, 2, ", 1")
            if around {
                skip = new_label()
                jump_if_local("jnc", skip)
                op_first("inc  ", i, place, 0, 1, "")
                local(skip)
            }
        }
        else {
            ins(outer)
            put("  ")
            first(i, place, 2, 2)
            put(", 1")
            nl()
            op_first("rcr  ", i, place, 0, 2, ", 1")
            if around {
                skip = new_label()
                jump_if_local("jnc", skip)
                op_first("or  ", i, place, 3, 1, ", 128")
                line("stc")
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
            ; (several bits: by CL; the last bit out is in the carry, as the IR has it)
            shift_first(shift_name(i.op, false), i, place, size, count)
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
    ; passed in AL, the first word in BX, the next word in CX.  A call that has all of
    ; them comes in at "p8e_name", where they are stored.  (The name itself stays the way
    ; in for everything that has stored the arguments: a call through a pointer, a jump,
    ; assembly.)
    ; Where the parameter is passed: 0 in its variable, 1 AL, 2 BX, 3 CX.
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

    ; "    before<an argument>": bytes k and up (w of them) of its register, or of its
    ; constant
    sub op_arg(str before, ^^ir.Arg a, ubyte k, ubyte w) {
        ins(before)
        put_arg(a, k, w)
        nl()
    }

    sub put_arg(^^ir.Arg a, ubyte k, ubyte w) {
        if a.reg != 0
            cell(a.reg, k, w)
        else if w == 1
            putn(((a.value >> (k * 8)) as long) & 255)
        else
            putn(((a.value >> (k * 8)) as long) & $ffff)
    }

    ; the parameter that an argument is for: a variable of the subroutine, named there
    ; without its scope
    sub param_place(^^ir.Instr i, ^^ir.Arg a, ubyte k, ubyte w) {
        width(w)
        if not text_has(a.name, ".") {
            name(i.sym)
            put("__")
            put(a.name)
        }
        else
            name(a.name)
        plus(k)
        put("]")
    }

    ; bytes k and up of an argument into its parameter
    sub arg_to_param(^^ir.Instr i, ^^ir.Arg a, ubyte k, ubyte w) {
        if a.reg != 0 {
            load_cell(a.reg, k, w)
            ins("mov  ")
            param_place(i, a, k, w)
            if w == 1
                put(", al")
            else
                put(", ax")
            nl()
        }
        else {
            ins("mov  ")
            param_place(i, a, k, w)
            put(", ")
            if w == 1
                putn(((a.value >> (k * 8)) as long) & 255)
            else
                putn(((a.value >> (k * 8)) as long) & $ffff)
            nl()
        }
    }

    ; the 8086 register of a slot of the IR (50 AL, 51 AH ... 57 DH, 58 AX, 59 BX, 60 CX,
    ; 61 DX, 62 SI, 63 DI, 64 BP), or 0 for another slot
    sub slot_register(ubyte number) -> str {
        when number {
            50 -> return "al"
            51 -> return "ah"
            52 -> return "bl"
            53 -> return "bh"
            54 -> return "cl"
            55 -> return "ch"
            56 -> return "dl"
            57 -> return "dh"
            58 -> return "ax"
            59 -> return "bx"
            60 -> return "cx"
            61 -> return "dx"
            62 -> return "si"
            63 -> return "di"
            64 -> return "bp"
        }
        return 0
    }

    ; A call of a subroutine in assembly (asmsub) or of a routine at an address (extsub):
    ; the arguments in the 8086's registers, in the carry, or in the library's virtual
    ; registers, as the declaration says; the values it returns from there.
    sub asm_call(^^ir.Instr i, bool by_address) {
        ; first what goes into memory (through AX), then the registers, then the carry:
        ; a "mov" leaves the flags alone
        ^^ir.Arg a = i.args
        while a != 0 {
            if a.slot == 255 {
                ubyte size = size_of(a.type)
                if a.name == 0 or (size != 1 and size != 2) {
                    error("an argument of this call cannot be passed on the 8086 yet", i.sym)
                    return
                }
                arg_to_param(i, a, 0, size)
            }
            else if a.slot > ir.SLOT_FLAGS {
                error("only the carry can be an argument of a routine in assembly", i.sym)
                return
            }
            a = a.next
        }
        a = i.args
        while a != 0 {
            if a.slot < ir.SLOT_FLAGS {
                ^^ubyte reg = slot_register(a.slot)
                if reg == 0 {
                    error("a register of another machine in the declaration of a routine in assembly", i.sym)
                    return
                }
                ins("mov  ")
                put(reg)
                put(", ")
                if a.slot <= 57
                    put_arg(a, 0, 1)
                else
                    put_arg(a, 0, 2)
                nl()
            }
            a = a.next
        }
        a = i.args
        while a != 0 {
            if a.slot == ir.SLOT_FLAGS {
                if a.reg != 0 {
                    ; (carry when the value is not 0)
                    op_cell("cmp  ", a.reg, 0, 1, ", 1")
                    line("cmc")
                }
                else if (a.value & 255) != 0
                    line("stc")
                else
                    line("clc")
            }
            a = a.next
        }
        if by_address {
            ins("call  ")
            put_number_text(i.sym)
            nl()
        }
        else {
            ins("call  ")
            name(i.sym)
            nl()
        }
        ; the values: the registers first (a "mov" leaves a flag for the branch that
        ; follows alone), then the carry as a value, which needs AL
        ^^ir.Arg r = i.results
        while r != 0 {
            if r.slot < ir.SLOT_FLAGS and r.reg != 0 {
                ^^ubyte from = slot_register(r.slot)
                if from == 0 {
                    error("a register of another machine in the declaration of a routine in assembly", i.sym)
                    return
                }
                ins("mov  ")
                if r.slot <= 57
                    cell(r.reg, 0, 1)
                else
                    cell(r.reg, 0, 2)
                put(", ")
                put(from)
                nl()
            }
            r = r.next
        }
        r = i.results
        while r != 0 {
            if r.slot == ir.SLOT_FLAGS and r.reg != 0 {
                ; the carry as a value: the IR's next two instructions would rotate it
                ; into a zero, which is done here
                line("mov  al, 0")
                line("adc  al, 0")
                store_cell(r.reg, 0, 1)
                if i.next != 0 and i.next.op == ir.OP_LOAD and i.next.r1 == r.reg and i.next.next != 0
                        and i.next.next.op == ir.OP_ROXL and i.next.next.r1 == r.reg
                    skip_next = 2
            }
            r = r.next
        }
    }

    ; A call: the arguments into the subroutine's parameters, by their names; a result
    ; comes back in AL, AX, or DX and AX.
    sub call_instruction(^^ir.Instr i) {
        ^^ir.Sub callee = sub_named(i.sym)
        if callee == 0 and i.sym != 0 and (i.sym[0] == '$' or (i.sym[0] >= '0' and i.sym[0] <= '9')) {
            asm_call(i, true)
            return
        }
        if callee != 0 and callee.is_asm and not callee.asm_is_ir {
            if callee.is_external {
                error("a routine without an address (extsub of a C library) cannot be called on the 8086", i.sym)
                return
            }
            asm_call(i, false)
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
            if a.name == 0 or size == 0 or (size == 8 and a.reg == 0) {
                error("the arguments of this call cannot be passed on the 8086 yet", i.sym)
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
                arg_to_param(i, a, k, w)
                k += w
            }
            a = a.next
        }
        if by_register {
            a = i.args
            while a != 0 {
                when arg_register(callee, a) {
                    1 -> op_arg("mov  al, ", a, 0, 1)
                    2 -> op_arg("mov  bx, ", a, 0, 2)
                    3 -> op_arg("mov  cx, ", a, 0, 2)
                }
                a = a.next
            }
        }
        ins("call  ")
        if by_register
            put("p8e")
        name(i.sym)
        nl()
        ^^ir.Arg r = i.results
        if r != 0 {
            ubyte result_size = size_of(r.type)
            if r.next != 0 or r.reg == 0 or result_size == 0 {
                error("the results of this call cannot be taken on the 8086 yet", i.sym)
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

    ; a variable (by its name) or the place of an IR register, as an operand: w bytes
    ; from offset on
    sub place_operand(^^ubyte variable, uword r, ubyte offset, ubyte w) {
        width(w)
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
        plus(offset)
        put("]")
    }

    ; (a result that is in AX or DX stays there: a byte goes through BL)
    sub push_place(^^ubyte variable, uword r, ubyte size) {
        if size == 1 {
            ins("mov  bl, ")
            place_operand(variable, r, 0, 1)
            nl()
            line("push  bx")
            return
        }
        ubyte k = 0
        while k < size {
            ins("push  ")
            place_operand(variable, r, k, 2)
            nl()
            k += 2
        }
    }

    sub pop_place(^^ubyte variable, uword r, ubyte size) {
        if size == 1 {
            line("pop  bx")
            ins("mov  ")
            place_operand(variable, r, 0, 1)
            put(", bl")
            nl()
            return
        }
        ubyte k = size
        while k != 0 {
            k -= 2
            ins("pop  ")
            place_operand(variable, r, k, 2)
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

    ; a byte argument of a system call into a byte register ("al", "dl")
    sub arg_byte(^^ir.Arg a, str reg) {
        if a == 0 {
            error("a system call without the arguments it needs", 0)
            return
        }
        ins("mov  ")
        put(reg)
        put(", ")
        if a.reg != 0
            cell(a.reg, 0, 1)
        else
            putn((a.value as long) & 255)
        nl()
    }

    ; a word argument into a word register ("ax", "bx", "cx", "dx", "si", "di").  One
    ; that is a byte comes through AX when the register has no halves of its own, so
    ; an argument for AX is loaded last.
    sub arg_word(^^ir.Arg a, str reg) {
        if a == 0 {
            error("a system call without the arguments it needs", 0)
            return
        }
        if a.reg != 0 and rsize(a.reg) == 1 {
            if reg[1] == 'x' {
                ins("mov  ")
                buf.add_byte(o, reg[0])
                put("l, ")
                cell(a.reg, 0, 1)
                nl()
                ins("xor  ")
                buf.add_byte(o, reg[0])
                put("h, ")
                buf.add_byte(o, reg[0])
                put("h")
                nl()
            }
            else {
                load_cell(a.reg, 0, 1)
                line("xor  ah, ah")
                ins("mov  ")
                put(reg)
                put(", ax")
                nl()
            }
            return
        }
        ins("mov  ")
        put(reg)
        put(", ")
        if a.reg != 0
            cell(a.reg, 0, 2)
        else
            putn((a.value as long) & $ffff)
        nl()
    }

    ; a long argument of a system call into one of the cells of the long routines
    sub arg_cell(^^ir.Arg a, str place) {
        need_long = true
        if a == 0 {
            error("a system call without the arguments it needs", 0)
            return
        }
        ubyte half
        for half in 0 to 1 {
            if a.reg != 0 {
                load_cell(a.reg, half * 2, 2)
                ins("mov  [")
                put(place)
                plus(half * 2)
                put("], ax")
            }
            else {
                ins("mov  word [")
                put(place)
                plus(half * 2)
                put("], ")
                putn(((a.value >> (half * 16)) as long) & $ffff)
            }
            nl()
        }
    }

    sub call_rt(ubyte which, str routine) {
        need_rt[which] = true
        ins("call  ")
        put(routine)
        nl()
    }

    ; AL or AX kept between two arguments of a system call (the least, the most)
    sub keep_between(^^ir.Arg least, ^^ir.Arg most, ubyte size, bool signed) {
        if least == 0 or most == 0 {
            error("a system call without the arguments it needs", 0)
            return
        }
        long fits = new_label()
        long over = new_label()
        ^^ubyte compare = "cmp  al, "
        ^^ubyte load = "mov  al, "
        if size == 2 {
            compare = "cmp  ax, "
            load = "mov  ax, "
        }
        op_arg(compare, least, 0, size)
        if signed
            jump_if_local("jge", fits)
        else
            jump_if_local("jae", fits)
        op_arg(load, least, 0, size)
        local(fits)
        op_arg(compare, most, 0, size)
        if signed
            jump_if_local("jle", over)
        else
            jump_if_local("jbe", over)
        op_arg(load, most, 0, size)
        local(over)
    }

    ; The system calls: what the library asks of the machine (the low numbers, as the
    ; virtual machine has them), and the builtin functions that the IR leaves to the
    ; back end (from $1000).  A result is in AL, AX, or DX and AX.
    sub syscall(^^ir.Instr i) {
        ^^ir.Arg a0 = arg_n(i, 0)
        ^^ir.Arg a1 = arg_n(i, 1)
        ^^ir.Arg a2 = arg_n(i, 2)
        ^^ir.Arg res = i.results
        when i.value as long {
            1 -> {
                ; the end of the program, as the target ends one, with the status in AL
                if a0 != 0
                    arg_byte(a0, "al")
                else
                    line("xor  al, al")
                line("jmp  p8_exit")
            }
            2 -> {
                ; a character to the console: the machine's routine (console_out)
                arg_byte(a0, "al")
                call_rt(RT_CHROUT, "p8rt_chrout")
            }
            3 -> {
                ; a string that ends with 0
                arg_word(a0, "si")
                line("call  p8rt_print")
                need_print = true
            }
            36 -> {
                ; copy memory: from, to, how many bytes (they may overlap)
                arg_word(a0, "si")
                arg_word(a1, "di")
                arg_word(a2, "cx")
                call_rt(RT_MOVE, "p8rt_move")
            }
            37 -> {
                ; fill memory: where, how many bytes, the value
                arg_word(a0, "di")
                arg_word(a1, "cx")
                arg_byte(a2, "al")
                call_rt(RT_FILL, "p8rt_fill")
            }
            38 -> {
                ; fill memory with a word: where, how many words, the value
                arg_word(a0, "di")
                arg_word(a1, "cx")
                arg_word(a2, "ax")
                call_rt(RT_FILLW, "p8rt_fillw")
            }
            69 -> {
                ; a character from the console, waited for and shown (char_in)
                need_rt[RT_CHROUT] = true
                call_rt(RT_CHRIN, "p8rt_chrin")
            }
            217 -> call_rt(RT_GETKEY, "p8rt_getkey")    ; a key, or 0 when none is waiting (key_poll)
            218 -> {
                need_rt[RT_GETKEY] = true
                call_rt(RT_WAITKEY, "p8rt_waitkey")
            }
            13 -> {
                ; wait so many 60ths of a second
                arg_word(a0, "cx")
                call_rt(RT_WAIT, "p8rt_wait")
            }
            14 -> {
                line("mov  cx, 1")
                call_rt(RT_WAIT, "p8rt_wait")
            }
            216 -> call_rt(RT_TICKS, "p8rt_ticks")      ; the clock, in 60ths of a second
            213 -> {
                ; a byte from an I/O port
                arg_word(a0, "dx")
                line("in  al, dx")
            }
            214 -> {
                ; a byte to an I/O port
                arg_word(a0, "dx")
                arg_byte(a1, "al")
                line("out  dx, al")
            }
            200 -> call_rt(RT_ARGS, "p8rt_argc")
            201 -> {
                arg_word(a0, "ax")
                call_rt(RT_ARGS, "p8rt_argv")
            }
            $100d -> {
                ; compare two strings: -1, 0 or 1
                arg_word(a0, "si")
                arg_word(a1, "di")
                call_rt(RT_STRCMP, "p8rt_strcmp")
            }
            $100e -> {
                ; is a character in a string
                arg_word(a1, "si")
                arg_byte(a0, "al")
                call_rt(RT_INSTR, "p8rt_instr")
            }
            $100f -> {
                ; is a byte in an array: the value, the array, its length
                arg_word(a1, "di")
                arg_word(a2, "cx")
                arg_byte(a0, "al")
                call_rt(RT_INBYTES, "p8rt_inbytes")
            }
            $1010 -> {
                arg_word(a1, "di")
                arg_word(a2, "cx")
                arg_word(a0, "ax")
                call_rt(RT_INWORDS, "p8rt_inwords")
            }
            $1012, $1013 -> {
                ; clamp a byte: the value, the least, the most
                arg_byte(a0, "al")
                keep_between(a1, a2, 1, i.value == $1013)
            }
            $1014, $1015 -> {
                arg_word(a0, "ax")
                keep_between(a1, a2, 2, i.value == $1015)
            }
            $1016 -> {
                ; clamp a long: the value, the least, the most
                arg_cell(a0, "p8_la")
                arg_cell(a1, "p8_lb")
                arg_cell(a2, "p8_lc")
                need_rt[RT_LESS32] = true
                call_rt(RT_CLAMP32, "p8rt_clamp32")
                line("mov  ax, [p8_la]")
                line("mov  dx, [p8_la+2]")
            }
            $1011 -> {
                ; is a float in an array, byte for byte: the value, the array, its length
                if a0 == 0 or a0.reg == 0 or size_of(a0.type) != 8 {
                    error("system call $1011 needs its float in a register", 0)
                    return
                }
                arg_word(a1, "di")
                arg_word(a2, "cx")
                faddr("si", F_CELL, a0.reg, 0, 0)
                call_rt(RT_INFLOATS, "p8rt_infloats")
            }
            $101b -> {
                ; is a long in an array: the value, the array, its length
                arg_cell(a0, "p8_la")
                arg_word(a1, "si")
                arg_word(a2, "cx")
                call_rt(RT_INLONGS, "p8rt_inlongs")
            }
            else -> {
                buf.clear(nb)
                buf.add_long(nb, i.value as long)
                buf.add_byte(nb, 0)
                error("this system call is not there for the 8086 yet", nb.data)
                return
            }
        }
        if res != 0 and res.reg != 0 {
            ubyte result_size = size_of(res.type)
            if result_size != 0
                keep(res.reg, result_size)
            else
                error("the result of this system call cannot be taken on the 8086 yet", 0)
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
            lines("; prints the string at SI (it ends with 0)\np8rt_print:\nlodsb\ntest  al, al\njz  p8rt_print_end\npush  si\ncall  p8rt_chrout\npop  si\njmp  p8rt_print\np8rt_print_end:\nret")
            need_rt[RT_CHROUT] = true
        }
        if need_div
            lines("; AX = AX / BX, DX = the remainder (unsigned; a division by 0 gives $ffff)\np8rt_div16:\ntest  bx, bx\njz  p8rt_div16_zero\nxor  dx, dx\ndiv  bx\nret\np8rt_div16_zero:\nmov  dx, ax\nmov  ax, 65535\nret")
        if need_divs {
            lines("; AX = AX / BX, DX = the remainder (signed: towards zero, the remainder with the dividend's sign)\np8rt_divs16:\ntest  bx, bx\njz  p8rt_divs16_zero\ncmp  bx, -1\nje  p8rt_divs16_minus\ncwd\nidiv  bx\nret")
            lines("p8rt_divs16_minus:\nneg  ax\nxor  dx, dx\nret\np8rt_divs16_zero:\nmov  dx, ax\ntest  ax, ax\nmov  ax, 65535\njns  p8rt_divs16_end\nmov  ax, 1\np8rt_divs16_end:\nret")
        }
        if need_mul32 {
            lines("; p8_lc = p8_la * p8_lb (the low 32 bits)\np8rt_mul32:\nmov  ax, [p8_la+2]\nmul  word [p8_lb]\nmov  cx, ax\nmov  ax, [p8_la]\nmul  word [p8_lb+2]\nadd  cx, ax\nmov  ax, [p8_la]\nmul  word [p8_lb]\nadd  dx, cx")
            lines("mov  [p8_lc], ax\nmov  [p8_lc+2], dx\nret")
        }
        if need_div32 {
            lines("; p8_la = p8_la / p8_lb, p8_lc = the remainder (unsigned)\np8rt_div32:\nxor  ax, ax\nmov  [p8_lc], ax\nmov  [p8_lc+2], ax\nmov  cx, 32\np8rt_div32_bit:\nshl  word [p8_la], 1\nrcl  word [p8_la+2], 1")
            lines("rcl  word [p8_lc], 1\nrcl  word [p8_lc+2], 1\njc  p8rt_div32_fits\nmov  ax, [p8_lc+2]\ncmp  ax, [p8_lb+2]\njne  p8rt_div32_decide\nmov  ax, [p8_lc]\ncmp  ax, [p8_lb]\np8rt_div32_decide:\njb  p8rt_div32_next")
            lines("p8rt_div32_fits:\nmov  ax, [p8_lb]\nsub  [p8_lc], ax\nmov  ax, [p8_lb+2]\nsbb  [p8_lc+2], ax\ninc  byte [p8_la]\np8rt_div32_next:\nloop  p8rt_div32_bit\nret")
        }
        if need_divs32 {
            lines("; the same, signed: towards zero, the remainder with the dividend's sign\np8rt_divs32:\nxor  bx, bx\ntest  byte [p8_la+3], 128\njz  p8rt_divs32_a\nmov  si, p8_la\ncall  p8rt_neg32\nmov  bl, 3\np8rt_divs32_a:")
            lines("test  byte [p8_lb+3], 128\njz  p8rt_divs32_b\nmov  si, p8_lb\ncall  p8rt_neg32\nxor  bl, 1\np8rt_divs32_b:\ncall  p8rt_div32\ntest  bl, 1\njz  p8rt_divs32_q\nmov  si, p8_la\ncall  p8rt_neg32\np8rt_divs32_q:")
            lines("test  bl, 2\njz  p8rt_divs32_r\nmov  si, p8_lc\ncall  p8rt_neg32\np8rt_divs32_r:\nret\n; the long at SI = -it\np8rt_neg32:\nneg  word [si+2]\nneg  word [si]\nsbb  word [si+2], 0\nret")
        }
        if need_rt[RT_MOVE] {
            lines("; copies CX bytes from SI to DI; the two may overlap\np8rt_move:\ncmp  si, di\njae  p8rt_move_up\nadd  si, cx\ndec  si\nadd  di, cx\ndec  di\nstd\nrep movsb\ncld\nret\np8rt_move_up:\nrep movsb\nret")
        }
        if need_rt[RT_FILL]
            lines("; fills CX bytes at DI with AL\np8rt_fill:\nrep stosb\nret")
        if need_rt[RT_FILLW]
            lines("; fills CX words at DI with AX\np8rt_fillw:\nrep stosw\nret")
        if need_rt[RT_STRCMP] {
            lines("; compares the strings at SI and DI: AL = 0 the same, 1 the first is greater, 255 it is less\np8rt_strcmp:\nlodsb\nmov  ah, [di]\ninc  di\ncmp  al, ah\njne  p8rt_strcmp_differ\ntest  al, al\njnz  p8rt_strcmp\nret")
            lines("p8rt_strcmp_differ:\njb  p8rt_strcmp_less\nmov  al, 1\nret\np8rt_strcmp_less:\nmov  al, 255\nret")
        }
        if need_rt[RT_INSTR]
            lines("; is the character in AL in the string at SI: AL = 1 or 0\np8rt_instr:\nmov  ah, al\np8rt_instr_next:\nlodsb\ntest  al, al\njz  p8rt_instr_end\ncmp  al, ah\njne  p8rt_instr_next\nmov  al, 1\np8rt_instr_end:\nret")
        if need_rt[RT_INBYTES]
            lines("; is the byte in AL among the CX bytes at DI: AL = 1 or 0\np8rt_inbytes:\njcxz  p8rt_inbytes_no\nrepne scasb\njne  p8rt_inbytes_no\nmov  al, 1\nret\np8rt_inbytes_no:\nxor  al, al\nret")
        if need_rt[RT_INWORDS]
            lines("; is the word in AX among the CX words at DI: AL = 1 or 0\np8rt_inwords:\njcxz  p8rt_inwords_no\nrepne scasw\njne  p8rt_inwords_no\nmov  al, 1\nret\np8rt_inwords_no:\nxor  al, al\nret")
        if need_rt[RT_INLONGS] {
            lines("; is the long in p8_la among the CX longs at SI: AL = 1 or 0\np8rt_inlongs:\njcxz  p8rt_inlongs_no\np8rt_inlongs_next:\nmov  ax, [si]\ncmp  ax, [p8_la]\njne  p8rt_inlongs_other\nmov  ax, [si+2]\ncmp  ax, [p8_la+2]")
            lines("je  p8rt_inlongs_yes\np8rt_inlongs_other:\nadd  si, 4\nloop  p8rt_inlongs_next\np8rt_inlongs_no:\nxor  al, al\nret\np8rt_inlongs_yes:\nmov  al, 1\nret")
        }
        if need_rt[RT_INFLOATS]
        {
            lines("; is the float at SI among the CX floats at DI: AL = 1 or 0\np8rt_infloats:\njcxz  p8rt_infloats_no\np8rt_infloats_next:\npush  cx\npush  si\npush  di\nmov  cx, 4\nrepe cmpsw\npop  di\npop  si\npop  cx\nje  p8rt_infloats_yes")
            lines("add  di, 8\nloop  p8rt_infloats_next\np8rt_infloats_no:\nxor  al, al\nret\np8rt_infloats_yes:\nmov  al, 1\nret")
        }
        if need_rt[RT_CLAMP32] {
            lines("; p8_la = p8_la kept between p8_lb and p8_lc (signed longs)\np8rt_clamp32:\nmov  si, p8_la\nmov  di, p8_lb\ncall  p8rt_less32\njnc  p8rt_clamp32_top\nmov  ax, [p8_lb]\nmov  [p8_la], ax\nmov  ax, [p8_lb+2]\nmov  [p8_la+2], ax\nret")
            lines("p8rt_clamp32_top:\nmov  si, p8_lc\nmov  di, p8_la\ncall  p8rt_less32\njnc  p8rt_clamp32_end\nmov  ax, [p8_lc]\nmov  [p8_la], ax\nmov  ax, [p8_lc+2]\nmov  [p8_la+2], ax\np8rt_clamp32_end:\nret")
        }
        if need_rt[RT_LESS32]
            lines("; carry when the long at SI is less than the long at DI (signed)\np8rt_less32:\nmov  ax, [si+2]\ncmp  ax, [di+2]\njl  p8rt_less32_yes\njg  p8rt_less32_no\nmov  ax, [si]\ncmp  ax, [di]\nret\np8rt_less32_yes:\nstc\nret\np8rt_less32_no:\nclc\nret")
        if need_rt[RT_SQRT] {
            lines("; AX = the square root of the long in p8_la, rounded down: two bits of the number\n; at a time into the rest (DI and SI), the root in BX\np8rt_sqrt32:\nxor  bx, bx\nxor  si, si\nxor  di, di\nmov  cx, 16\np8rt_sqrt32_bit:\npush  cx\nmov  cx, 2")
            lines("p8rt_sqrt32_two:\nshl  word [p8_la], 1\nrcl  word [p8_la+2], 1\nrcl  si, 1\nrcl  di, 1\nloop  p8rt_sqrt32_two\nshl  bx, 1\nmov  ax, bx\nxor  dx, dx\nshl  ax, 1\nrcl  dx, 1\nor  al, 1\ncmp  di, dx\njne  p8rt_sqrt32_decide")
            lines("cmp  si, ax\np8rt_sqrt32_decide:\njb  p8rt_sqrt32_less\nsub  si, ax\nsbb  di, dx\ninc  bx\np8rt_sqrt32_less:\npop  cx\nloop  p8rt_sqrt32_bit\nmov  ax, bx\nret")
        }
        if need_rt[RT_WAIT] {
            lines("; waits CX 60ths of a second, one at a time as the target file says how\np8rt_wait:\njcxz  p8rt_wait_end\np8rt_wait_next:\npush  cx\ncall  p8rt_jiffy\npop  cx\nloop  p8rt_wait_next\np8rt_wait_end:\nret\np8rt_jiffy:")
            if target.text("wait_jiffy") != 0
                target_lines("wait_jiffy")
            else
                line("ret")
        }
        if need_rt[RT_TICKS] {
            raw("; AX = the clock, in 60ths of a second (0 on a machine without one)")
            raw("p8rt_ticks:")
            if target.text("ticks") != 0
                target_lines("ticks")
            else {
                line("xor  ax, ax")
                line("ret")
            }
        }
        if need_rt[RT_ARGS] {
            raw("; the command line.  AX = the number of arguments, the program's name counted;")
            raw("; AX = the argument whose number is in AX")
            if target.text("arguments") != 0
                target_lines("arguments")
            else
                lines("p8rt_argc:\nmov  ax, 1\nret\np8rt_argv:\nmov  ax, p8rt_argv_none\nret")
        }
        if need_rt[RT_WAITKEY]
            lines("; waits for a key and gives it in AL, without showing it\np8rt_waitkey:\ncall  p8rt_getkey\ntest  al, al\njz  p8rt_waitkey\nret")
        if need_rt[RT_CHROUT] {
            raw("; a character (in AL) to the console")
            raw("p8rt_chrout:")
            target_lines("console_out")
        }
        if need_rt[RT_GETKEY] {
            raw("; AL = a key, or 0 when none is waiting")
            raw("p8rt_getkey:")
            target_lines("key_poll")
        }
        if need_rt[RT_CHRIN] {
            raw("; AL = a character from the console, waited for and shown")
            raw("p8rt_chrin:")
            target_lines("char_in")
        }
        nl()
    }

    ; ---- variables ----

    sub element_size(^^ubyte typestr) -> ubyte {
        if text_has(typestr, "float")
            return 8
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
        if exe {
            ; (the code must fit its segment; the data begins on a paragraph)
            raw("p8_code_end:")
            raw("    times  -((p8_code_end - p8_code_start) > 65535)  db  0     ; an error here: the program's code is more than 64 KB")
            raw("p8_code_paragraphs  equ  (p8_code_end - p8_code_start + 15) / 16")
            raw("section .data vstart=256 align=16 follows=.text")
            raw("p8_data_start:")
        }
        raw("; ---- variables with values")
        ; (places of the machine's own that its routines and its library share)
        if target.text("machine_cells") != 0
            target_lines("machine_cells")
        if need_rt[RT_ARGS] {
            if target.text("arguments") == 0
                raw("p8rt_argv_none:  db  0")
            else if target.text("arguments_data") != 0
                target_lines("arguments_data")
        }
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
                    putn(address & $ffff)
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
                    error("a variable of this type cannot be used on the 8086 yet", v.name)
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
        raw("p8_data_end:")
        if exe
            raw("p8_file_size  equ  32 + p8_code_paragraphs * 16 + (p8_data_end - p8_data_start)")
        raw("    absolute  p8_data_end")
        raw("p8_bss_start:")
        bss_variables()
        buf.add_bytes(o, cells.data, cells.len)
        if need_vregs
            raw("p8_vregs:  resb  32")
        ubyte sn
        for sn in 0 to 99 {
            if slot_used[sn] {
                put("p8_slot_")
                putn(sn)
                raw(":  resb  8")          ; (a float is eight bytes; the others are in the first four)
            }
        }
        if need_long {
            raw("p8_la:  resb  4")
            raw("p8_lc:  resb  4")
            raw("p8_lb:  resb  4")
        }
        raw("p8_bss_end:")
        ; the program and its variables must end where the target says its memory ends
        ; (memory_end: the first address that is not the program's; the stack is above)
        long limit = target.number("memory_end", 0)
        if limit > 0 {
            if exe
                put("    times  -((p8_bss_end-p8_data_start+256")
            else {
                put("    times  -((p8_bss_end-p8_start+")
                putn(load_address())
            }
            put(") > ")
            putn(limit)
            raw(")  resb  1     ; an error here: the program is too long, it and its variables must end before memory_end of the target")
        }
    }

    ; the variables without values
    sub bss_variables() {
        ^^ir.Var v = prog.vars
        while v != 0 {
            if (v.kind == ir.V_VAR and v.init == 0) or v.kind == ir.V_SLAB or (v.kind == ir.V_INSTANCE and v.init == 0) {
                long bytes = v.size
                if v.kind == ir.V_VAR {
                    long vsize = element_size(v.typestr)
                    if struct_of(v.typestr) != 0
                        vsize = struct_of(v.typestr).size
                    if vsize == 0 {
                        error("a variable of this type cannot be used on the 8086 yet", v.name)
                        vsize = 1
                    }
                    bytes = element_count(v.typestr) * vsize
                }
                if v.align > 1 {
                    put("    alignb  ")
                    putn(v.align)
                    nl()
                }
                name(v.name)
                put(":  resb  ")
                putn(bytes)
                nl()
            }
            v = v.next
        }
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
                put("    times  ")
                putn(struct_size)
                put("  db  0")
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
                put("    dw  ")
            else if init[p] == 'l'
                put("    dd  ")
            else if init[p] == 'f' {
                put("    dw  ")
                p = float_item(init, colon + 1)
                nl()
                if init[p] == ','
                    p++
                continue
            }
            else if init[p] == 'q' or (init[p] == 'u' and init[p + 1] == 'q') {
                error("a struct field of this type cannot be used on the 8086 yet", v.name)
                return
            }
            else
                put("    db  ")
            p = value_item(init, colon + 1)
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

    ; a number as the IR writes it ($hex, decimal, with a minus) for the assembler,
    ; whose hexadecimal numbers begin with 0x
    sub put_number_text(^^ubyte text) {
        long k = 0
        while text[k] != 0 and text[k] != ',' {
            if text[k] == '$'
                put("0x")
            else
                buf.add_byte(o, text[k])
            k++
        }
    }

    ; one value of a list, from position p: a number, or "@name" for the address of
    ; something; where the list goes on
    sub value_item(^^ubyte text, long p) -> long {
        if text[p] == '@' or text[p] == '&' {
            p++
            buf.add_byte(o, '_')
            while text[p] != 0 and text[p] != ',' {
                if text[p] == '.'
                    buf.add_str(o, "__")
                else
                    buf.add_byte(o, text[p])
                p++
            }
            return p
        }
        while text[p] != 0 and text[p] != ',' {
            if text[p] == '$'
                put("0x")
            else
                buf.add_byte(o, text[p])
            p++
        }
        return p
    }

    ; one float of a list of values, as its four words; where the list goes on
    sub float_item(^^ubyte text, long p) -> long {
        buf.clear(nb)
        while text[p] != 0 and text[p] != ',' {
            buf.add_byte(nb, text[p])
            p++
        }
        buf.add_byte(nb, 0)
        float_words(irparse.parse_float(nb.data))
        ubyte k
        for k in 0 to 3 {
            if k != 0
                put(",")
            putn(fc_words[k])
        }
        return p
    }

    ; the values of a variable
    sub values(^^ir.Var v, ubyte esize) {
        if v.align > 1 {
            ; (bytes up to the next address that the number divides; not the
            ; assembler's "align", which would move a whole section)
            put("    times  (")
            putn(v.align)
            if exe
                put(" - (($-p8_data_start+256) % ")
            else {
                put(" - (($-p8_start+")
                putn(load_address())
                put(") % ")
            }
            putn(v.align)
            put(")) % ")
            putn(v.align)
            raw("  db  0")
        }
        name(v.name)
        put(":")
        nl()
        long p = 0
        ubyte column = 0
        while v.init[p] != 0 {
            if column == 0 {
                when esize {
                    1 -> put("    db  ")
                    2, 8 -> put("    dw  ")
                    else -> put("    dd  ")
                }
            }
            else
                put(",")
            if esize == 8 {
                p = float_item(v.init, p)
                column += 3
            }
            else
                p = value_item(v.init, p)
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

    ; ---- the jumps that may not reach ----
    ;
    ; A conditional jump of the 8086 is two bytes and reaches 127 bytes forward, 128
    ; back.  Here every line of the finished text gets the most bytes that it can
    ; be (most_bytes), and a conditional jump whose target may be further than that
    ; becomes the opposite jump around a "jmp" (five bytes: every conditional jump is
    ; counted as that, so that one pass is enough).  "loop" and "jcxz" have no opposite
    ; and are only written around a few instructions.

    long line_count = 0
    ^^long line_at = 0              ; per line: where it begins in the text
    ^^long line_offset = 0          ; per line: the most bytes that are before it
    long line_room = 0
    ^^long local_line = 0           ; per local label (p8z_N): its line
    long local_room = 0
    ^^long named_line = 0           ; per other label: its line
    long named_count = 0
    long named_room = 0
    const long FAR = 100000         ; (bytes of something whose size is not known)

    sub is_name_char(ubyte c) -> bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == '$' or c == '@' or c == '?'
    }

    ; is what stands at text one of the 8086's registers?
    sub is_register(^^ubyte text) -> bool {
        ubyte a = text[0] | 32
        ubyte b = text[1] | 32
        if is_name_char(text[2])
            return false
        if (a == 'a' or a == 'b' or a == 'c' or a == 'd') and (b == 'l' or b == 'h' or b == 'x')
            return true
        if (a == 's' or a == 'd') and b == 'i'
            return true
        if (a == 'b' or a == 's') and b == 'p'
            return true
        return (a == 'c' or a == 'd' or a == 'e' or a == 's') and b == 's'
    }

    ; is the line (from its first character that is no space) a conditional jump that
    ; has an opposite?
    sub is_conditional(^^ubyte text) -> bool {
        if text[0] != 'j'
            return false
        if text[1] == 'm' and text[2] == 'p'
            return false
        if text[1] == 'c' and text[2] == 'x'
            return false
        if text[1] == 'p' and (text[2] == 'e' or text[2] == 'o')
            return false
        return true
    }

    ; the most bytes that a line of the text can be; own is true for assembly of the
    ; program's own, whose instructions may have a prefix
    sub most_bytes(^^ubyte text, long length, bool own) -> long {
        long p = 0
        while p < length and (text[p] == ' ' or text[p] == '\t')
            p++
        if p >= length or text[p] == ';'
            return 0
        ; (a label, with or without something after it)
        long q = p
        while q < length and is_name_char(text[q])
            q++
        if q < length and text[q] == ':' {
            q++
            while q < length and (text[q] == ' ' or text[q] == '\t')
                q++
            if q >= length or text[q] == ';'
                return 0
            if buf.bytes_equal(text + q, "resb", 4)
                return 0
            return FAR
        }
        long n = q - p              ; (the mnemonic's length)
        ^^ubyte m = text + p
        if m[0] == 'j' {
            if m[1] == 'm' and m[2] == 'p' {
                if own
                    return 5
                return 4
            }
            if m[1] == 'c' and m[2] == 'x'
                return 2
            return 5
        }
        if n == 4 and buf.bytes_equal(m, "loop", 4)
            return 2
        if n == 3 and buf.bytes_equal(m, "ret", 3)
            return 1
        if n == 3 and (buf.bytes_equal(m, "cpu", 3) or buf.bytes_equal(m, "org", 3))
            return 0
        if n == 4 and buf.bytes_equal(m, "bits", 4)
            return 0
        if (n == 2 and m[0] == 'd' and (m[1] == 'b' or m[1] == 'w' or m[1] == 'd')) or (n == 5 and buf.bytes_equal(m, "times", 5))
                or (n == 5 and buf.bytes_equal(m, "align", 5)) or (n == 6 and buf.bytes_equal(m, "incbin", 6))
                or (n == 8 and buf.bytes_equal(m, "absolute", 8)) or m[0] == '%' or m[0] == '['
            return FAR
        if own {
            ; (anything: with a prefix, or more than one instruction's worth is not
            ; known, so a line is taken as the longest instruction with two prefixes)
            return 8
        }
        ; an instruction: one byte and one for the registers, two more for an address,
        ; and up to two for a constant
        bool in_memory = false
        bool constant = false
        long k = q
        while k < length {
            if text[k] == '['
                in_memory = true
            if text[k] == ',' {
                long c = k + 1
                while c < length and text[c] == ' '
                    c++
                if c < length and not is_register(text + c) and text[c] != 'b' and text[c] != 'w'
                    constant = true
                if c + 4 < length and (text[c] == 'b' or text[c] == 'w') and not buf.bytes_equal(text + c + 1, "yte [", 5)
                        and not buf.bytes_equal(text + c + 1, "ord [", 5) and not is_register(text + c)
                    constant = true
            }
            k++
        }
        long bytes = 2
        if in_memory
            bytes += 2
        if constant
            bytes += 2
        if n == 4 and buf.bytes_equal(m, "call", 4) and not in_memory
            return 3
        if not in_memory and not constant {
            ; (one operand that is no register: a call or a push of a name)
            k = q
            while k < length and text[k] == ' '
                k++
            if k < length and not is_register(text + k)
                bytes = 4
        }
        return bytes
    }

    ; the line where a label is, or -1
    sub label_line(^^ubyte text, long length) -> long {
        if length > 4 and buf.bytes_equal(text, "p8z_", 4) {
            long n = 0
            long k = 4
            while k < length and text[k] >= '0' and text[k] <= '9' {
                n = n * 10 + (text[k] - '0')
                k++
            }
            if k == length and n < local_room
                return local_line[n]
        }
        long j
        if named_count != 0 {
            for j in 0 to named_count - 1 {
                ^^ubyte at = o.data + line_at[named_line[j]]
                if at[length] == ':' and buf.bytes_equal(at, text, length)
                    return named_line[j]
            }
        }
        return -1
    }

    sub branches() {
        ; the lines: where each begins
        long count = 1
        long k
        for k in 0 to o.len - 1 {
            if o.data[k] == '\n'
                count++
        }
        if count + 1 > line_room {
            line_room = count + 1
            line_at = mem.alloc(line_room * sizeof(long))
            line_offset = mem.alloc(line_room * sizeof(long))
        }
        if labels + 2 > local_room {
            local_room = labels + 2
            local_line = mem.alloc(local_room * sizeof(long))
        }
        if count + 1 > named_room {
            named_room = count + 1
            named_line = mem.alloc(named_room * sizeof(long))
        }
        for k in 0 to local_room - 1
            local_line[k] = -1
        line_count = 0
        named_count = 0
        long at = 0
        long offset = 0
        bool own = false
        while at < o.len {
            long stop = at
            while stop < o.len and o.data[stop] != '\n'
                stop++
            line_at[line_count] = at
            line_offset[line_count] = offset
            ^^ubyte text = o.data + at
            long length = stop - at
            if length >= 5 and buf.bytes_equal(text, ";%asm", 5)
                own = true
            else if length >= 5 and buf.bytes_equal(text, ";%end", 5)
                own = false
            ; (a label at the margin)
            if length > 1 and is_name_char(text[0]) {
                long q = 0
                while q < length and is_name_char(text[q])
                    q++
                if q < length and text[q] == ':' {
                    if q > 4 and buf.bytes_equal(text, "p8z_", 4) {
                        long n = 0
                        long d = 4
                        while d < q {
                            n = n * 10 + (text[d] - '0')
                            d++
                        }
                        if n < local_room
                            local_line[n] = line_count
                    }
                    else {
                        named_line[named_count] = line_count
                        named_count++
                    }
                }
            }
            offset += most_bytes(text, length, own)
            if offset > 100000000
                offset = 100000000
            line_count++
            at = stop + 1
        }
        line_at[line_count] = o.len
        line_offset[line_count] = offset
        ; the text again, with the jumps that may not reach as two
        if fixed == 0
            fixed = buf.new(65536)
        buf.clear(fixed)
        long made = 0
        long j
        for j in 0 to line_count - 1 {
            text = o.data + line_at[j]
            length = line_at[j + 1] - line_at[j]
            if length != 0 and text[length - 1] == '\n'
                length--
            long p = 0
            while p < length and text[p] == ' '
                p++
            bool long_form = false
            long tfrom = 0
            if p == 4 and p < length and is_conditional(text + p) {
                long q2 = p
                while q2 < length and text[q2] != ' '
                    q2++
                tfrom = q2
                while tfrom < length and text[tfrom] == ' '
                    tfrom++
                long tlen = 0
                while tfrom + tlen < length and is_name_char(text[tfrom + tlen])
                    tlen++
                if tlen != 0 and tfrom + tlen == length {
                    long where = label_line(text + tfrom, tlen)
                    long distance = FAR
                    if where >= 0 {
                        if where > j
                            distance = line_offset[where] - line_offset[j + 1]
                        else
                            distance = line_offset[j + 1] - line_offset[where]
                    }
                    if distance > 126 {
                        ; the opposite jump: "jn.." without its n, or with one
                        long_form = true
                        made++
                        buf.add_str(fixed, "    j")
                        long c = p + 1
                        if text[c] == 'n'
                            c++
                        else
                            buf.add_byte(fixed, 'n')
                        while c < q2 {
                            buf.add_byte(fixed, text[c])
                            c++
                        }
                        buf.add_str(fixed, "  p8j_")
                        buf.add_long(fixed, made)
                        buf.add_str(fixed, "\n    jmp  ")
                        buf.add_bytes(fixed, text + tfrom, tlen)
                        buf.add_str(fixed, "\np8j_")
                        buf.add_long(fixed, made)
                        buf.add_str(fixed, ":\n")
                    }
                }
            }
            if not long_form {
                buf.add_bytes(fixed, text, length)
                buf.add_byte(fixed, '\n')
            }
        }
        buf.clear(o)
        buf.add_bytes(o, fixed.data, fixed.len)
    }
}
