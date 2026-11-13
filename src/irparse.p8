; Parses IR text, as found in %ir {{ }} blocks of the libraries, into IR
; instructions (ir.p8), so that a backend can lower it like generated
; code.  The canonical text format of upstream's IRFORMAT 8 is accepted:
;
;     opcode[.type] operand,operand,...
;     _label:
;
; with registers rN.t and frN.f, immediates #value.t / #symbol[+offset],
; memory [symbol[+offset]], [$address], [rN.p[+offset]] and
; [symbol[+offset]+rN.t[*scale]], branch targets, hardware slots sN.t, and
; call sites name(args):results.  Float registers get their own numbers
; above FLOAT_BASE in the single register space of ir.p8.

%import ir
%import strtab
%import mem
%import buf
%import out
%import strings

irparse {
    %option ignore_unused

    const uword FLOAT_BASE = 50000
    const long SYSCALL_BASE_TEXT = 99000
    const uword SYSCALL_BASE = 60000

    ^^ubyte text = 0        ; the text being parsed
    long pos = 0
    long end = 0
    ^^ir.Sub cursub = 0
    ^^ir.Chunk chunk = 0
    ^^buf.Buf nb = 0
    long errors = 0
    ^^ubyte errtext = 0

    ; operand kinds
    const ubyte K_REG = 1
    const ubyte K_IMM = 2
    const ubyte K_MEM = 3
    const ubyte K_PTR = 4       ; [rN+offset]
    const ubyte K_TARGET = 5
    const ubyte K_SLOT = 6

    ; a parsed operand
    struct Operand {
        ^^ubyte sym
        quad value
        float fvalue
        long offset
        uword reg           ; register, or index/pointer register of a memory operand
        ubyte kind
        ubyte type          ; type suffix of a register or immediate (T_NONE when absent)
        ubyte scale
        bool is_float_imm
    }

    ^^Operand ops = 0
    ubyte nops = 0

    ; Replaces every inline IR chunk of the subroutine by the instructions
    ; it holds.  Returns false when something could not be parsed.
    sub expand(^^ir.Sub s) -> bool {
        if nb == 0 {
            nb = buf.new(256)
            ops = mem.alloc(sizeof(Operand) * 4)
        }
        errors = 0
        ^^ir.Chunk old = s.chunks
        s.chunks = 0
        s.lastchunk = 0
        cursub = s
        chunk = 0
        while old != 0 {
            ^^ir.Chunk next = old.next
            old.next = 0
            if old.kind == ir.C_ASM and old.is_ir {
                ; its label starts a code chunk; the text continues it
                chunk = ir.add_chunk(s, old.label)
                parse_text(old.text, old.textlen)
            }
            else {
                if s.lastchunk == 0
                    s.chunks = old
                else
                    s.lastchunk.next = old
                s.lastchunk = old
                chunk = old
            }
            old = next
        }
        return errors == 0
    }

    sub error(str message) {
        errors++
        out.err()
        out.puts("inline IR: ")
        out.puts(message)
        if cursub != 0 {
            out.puts(" in ")
            out.puts(cursub.name)
        }
        out.nl()
        out.std()
    }

    sub parse_text(^^ubyte t, long length) {
        text = t
        end = length
        pos = 0
        while pos < end {
            ; one line
            long linestart = pos
            while pos < end and text[pos] != '\n'
                pos++
            long lineend = pos
            if pos < end
                pos++
            parse_line(linestart, lineend)
        }
    }

    sub is_space(ubyte c) -> bool {
        return c == ' ' or c == '\t' or c == '\r'
    }

    sub parse_line(long start, long stop) {
        while start < stop and is_space(text[start])
            start++
        while stop > start and is_space(text[stop - 1])
            stop--
        if start >= stop
            return
        if text[start] == ';'
            return
        ; a label line: _name:
        if text[start] == '_' and text[stop - 1] == ':' {
            ^^ubyte lname = strtab.intern(text + start + 1, (stop - start - 2) as uword)
            chunk = ir.add_chunk(cursub, lname)
            return
        }
        ; the opcode, with its type suffix
        long p = start
        while p < stop and not is_space(text[p])
            p++
        long opend = p
        long dot = start
        while dot < opend and text[dot] != '.'
            dot++
        ubyte type = ir.T_NONE
        if dot < opend {
            type = type_of(text[dot + 1])
            if type == ir.T_NONE {
                error("unknown type suffix")
                return
            }
        }
        ubyte op = opcode_of(text + start, (dot - start) as uword)
        if op == 255 {
            buf.clear(nb)
            buf.add_str(nb, "unknown opcode: ")
            buf.add_bytes(nb, text + start, dot - start)
            buf.add_byte(nb, 0)
            error(nb.data)
            return
        }
        while p < stop and is_space(text[p])
            p++
        ^^ir.Instr i
        if op == ir.OP_CALL or op == ir.OP_SYSCALL {
            i = ir.emit(chunk, op, type, ir.M_CALL)
            parse_call(i, p, stop)
            return
        }
        ; the operands, separated by commas
        nops = 0
        while p < stop {
            long opstart = p
            while p < stop and text[p] != ','
                p++
            if nops < 4
                parse_operand(nops, opstart, p)
            nops++
            if p < stop
                p++
            while p < stop and is_space(text[p])
                p++
        }
        if nops > 4 {
            error("too many operands")
            return
        }
        i = ir.emit(chunk, op, type, ir.M_NONE)
        assign_operands(i)
    }

    sub type_of(ubyte c) -> ubyte {
        when c {
            'b' -> return ir.T_BYTE
            'w' -> return ir.T_WORD
            'l' -> return ir.T_LONG
            'q' -> return ir.T_QUAD
            'f' -> return ir.T_FLOAT
            'p' -> return ir.T_POINTER
        }
        return ir.T_NONE
    }

    sub opcode_of(^^ubyte name, uword length) -> ubyte {
        ubyte i = 0
        while i < ir.OP_COUNT {
            ^^ubyte n = ir.opcode_names[i]
            if buf.cstr_len(n) == length and buf.bytes_equal(n, name, length)
                return i
            i++
        }
        return 255
    }

    ; the number in text[p..stop): decimal, $hex, %binary, with an optional sign
    sub number(long p, long stop) -> quad {
        bool negative = false
        if p < stop and text[p] == '-' {
            negative = true
            p++
        }
        quad v = 0
        if p < stop and text[p] == '$' {
            p++
            while p < stop {
                ubyte c = text[p]
                ubyte d = 255
                if c >= '0' and c <= '9'
                    d = c - '0'
                else if c >= 'a' and c <= 'f'
                    d = c - 'a' + 10
                else if c >= 'A' and c <= 'F'
                    d = c - 'A' + 10
                if d == 255
                    break
                v = (v << 4) | d
                p++
            }
        }
        else if p < stop and text[p] == '%' {
            p++
            while p < stop and (text[p] == '0' or text[p] == '1') {
                v = (v << 1) | (text[p] - '0')
                p++
            }
        }
        else {
            while p < stop and text[p] >= '0' and text[p] <= '9' {
                v = v * 10 + (text[p] - '0')
                p++
            }
        }
        if negative
            return -v
        return v
    }

    sub is_number_start(ubyte c) -> bool {
        return (c >= '0' and c <= '9') or c == '$' or c == '%' or c == '-'
    }

    ; a register rN.t or frN.f at text[p..stop): its number and type
    sub register(long p, long stop, ^^Operand o) -> bool {
        bool is_float = false
        if text[p] == 'f' {
            is_float = true
            p++
        }
        if p >= stop or text[p] != 'r'
            return false
        p++
        if p >= stop or text[p] < '0' or text[p] > '9'
            return false
        long n = 0
        while p < stop and text[p] >= '0' and text[p] <= '9' {
            n = n * 10 + (text[p] - '0')
            p++
        }
        if is_float
            n += FLOAT_BASE
        else if n >= SYSCALL_BASE_TEXT
            n = SYSCALL_BASE + (n - SYSCALL_BASE_TEXT)      ; the VM's r99000.. syscall registers, in uword range
        o.reg = n as uword
        o.type = ir.T_NONE
        if p < stop and text[p] == '.' and p + 1 < stop
            o.type = type_of(text[p + 1])
        if is_float
            o.type = ir.T_FLOAT
        if o.type != ir.T_NONE
            ir.note_reg(n as uword, o.type)
        return true
    }

    sub parse_operand(ubyte index, long p, long stop) {
        ^^Operand o = ops + index * sizeof(Operand)
        o.sym = 0
        o.value = 0
        o.offset = 0
        o.reg = 0
        o.scale = 1
        o.type = ir.T_NONE
        o.is_float_imm = false
        ubyte c = text[p]
        if c == '#' {
            o.kind = K_IMM
            p++
            if p < stop and (is_number_start(text[p])) {
                ; a number with a type suffix; a float has a '.' inside it
                long last = stop - 1
                while last > p and text[last] != '.'
                    last--
                ubyte suffix = ir.T_NONE
                long numend = stop
                if last > p and last + 2 == stop {
                    suffix = type_of(text[last + 1])
                    numend = last
                }
                o.type = suffix
                if suffix == ir.T_FLOAT {
                    o.is_float_imm = true
                    buf.clear(nb)
                    buf.add_bytes(nb, text + p, numend - p)
                    buf.add_byte(nb, 0)
                    o.fvalue = parse_float(nb.data)
                }
                else
                    o.value = number(p, numend)
                return
            }
            ; a symbol address, with an optional +offset
            long symend = p
            while symend < stop and text[symend] != '+'
                symend++
            o.sym = strtab.intern(text + p, (symend - p) as uword)
            if symend < stop
                o.offset = number(symend + 1, stop) as long
            return
        }
        if c == '[' {
            parse_memory(o, p + 1, stop - 1)
            return
        }
        if (c == 'r' or c == 'f') and register(p, stop, o) {
            o.kind = K_REG
            return
        }
        if c == 's' and p + 1 < stop and text[p + 1] >= '0' and text[p + 1] <= '9' {
            o.kind = K_SLOT
            o.value = number(p + 1, stop)
            long dot = p
            while dot < stop and text[dot] != '.'
                dot++
            if dot + 1 < stop
                o.type = type_of(text[dot + 1])
            return
        }
        ; a code target
        o.kind = K_TARGET
        o.sym = strtab.intern(text + p, (stop - p) as uword)
    }

    ; the inside of [ ... ]
    sub parse_memory(^^Operand o, long p, long stop) {
        ; parts separated by +
        bool first = true
        o.kind = K_MEM
        while p < stop {
            long partend = p
            while partend < stop and text[partend] != '+'
                partend++
            ubyte c = text[p]
            if first {
                if (c == 'r' or c == 'f') and register(p, partend, o) {
                    o.kind = K_PTR          ; the register is the pointer
                }
                else if is_number_start(c)
                    o.offset = number(p, partend) as long
                else
                    o.sym = strtab.intern(text + p, (partend - p) as uword)
            }
            else if is_number_start(c)
                o.offset += number(p, partend) as long
            else {
                ; an index register, with an optional *scale
                long star = p
                while star < partend and text[star] != '*'
                    star++
                ^^Operand tmp = ops + 3 * sizeof(Operand)
                if register(p, star, tmp) {
                    o.reg = tmp.reg
                    o.type = tmp.type
                }
                if star < partend
                    o.scale = number(star + 1, partend) as ubyte
            }
            first = false
            p = partend
            if p < stop
                p++
        }
    }

    ; a float literal's value; only simple forms occur in IR text
    sub parse_float(^^ubyte s) -> float {
        float v = 0.0
        bool negative = false
        long p = 0
        if s[0] == '-' {
            negative = true
            p++
        }
        while s[p] >= '0' and s[p] <= '9' {
            v = v * 10.0 + ((s[p] - '0') as float)
            p++
        }
        if s[p] == '.' {
            p++
            float scale = 0.1
            while s[p] >= '0' and s[p] <= '9' {
                v += ((s[p] - '0') as float) * scale
                scale /= 10.0
                p++
            }
        }
        if s[p] == 'e' or s[p] == 'E' {
            p++
            bool eneg = false
            if s[p] == '-' {
                eneg = true
                p++
            }
            else if s[p] == '+'
                p++
            long e = 0
            while s[p] >= '0' and s[p] <= '9' {
                e = e * 10 + (s[p] - '0')
                p++
            }
            repeat e as uword {
                if eneg
                    v /= 10.0
                else
                    v *= 10.0
            }
        }
        if negative
            return -v
        return v
    }

    ; Fills the instruction's slots from the parsed operands and picks its mode.
    sub assign_operands(^^ir.Instr i) {
        ubyte nregs = 0
        ubyte n = 0
        ^^Operand o
        while n < nops {
            o = ops + n * sizeof(Operand)
            when o.kind {
                K_REG -> {
                    nregs++
                    if nregs == 1 {
                        i.r1 = o.reg
                        if o.type != i.type
                            i.t1 = o.type
                    }
                    else if nregs == 2 {
                        i.r2 = o.reg
                        if o.type != i.type
                            i.t2 = o.type
                    }
                    else {
                        i.r3 = o.reg
                        if o.type != i.type
                            i.t3 = o.type
                    }
                }
                K_IMM -> {
                    i.sym = o.sym
                    i.value = o.value
                    i.fvalue = o.fvalue
                    if o.sym != 0
                        i.offset = o.offset
                }
                K_MEM, K_PTR -> {
                    i.sym = o.sym
                    i.offset = o.offset
                    i.r2 = o.reg
                    i.scale = o.scale
                    if o.type != ir.T_NONE and o.kind == K_MEM
                        i.t2 = o.type
                }
                K_TARGET -> i.sym = o.sym
                K_SLOT -> i.slot = o.value as ubyte
            }
            n++
        }
        ; the mode from the operand shapes
        ubyte k1 = 0
        ubyte k2 = 0
        ubyte k3 = 0
        if nops > 0
            k1 = ops.kind
        if nops > 1 {
            o = ops + sizeof(Operand)
            k2 = o.kind
        }
        if nops > 2 {
            o = ops + 2 * sizeof(Operand)
            k3 = o.kind
        }
        if nops == 0
            i.mode = ir.M_NONE
        else if nops == 1 {
            when k1 {
                K_REG -> i.mode = ir.M_R
                K_IMM -> i.mode = ir.M_I
                K_MEM -> i.mode = ir.M_M
                K_PTR -> i.mode = ir.M_P
                K_TARGET -> i.mode = ir.M_T
                else -> error("bad operand")
            }
        }
        else if nops == 2 {
            if k1 == K_REG and k2 == K_REG
                i.mode = ir.M_RR
            else if k1 == K_REG and k2 == K_IMM
                i.mode = ir.M_RI
            else if k1 == K_REG and k2 == K_MEM
                i.mode = ir.M_RM
            else if k1 == K_REG and k2 == K_PTR
                i.mode = ir.M_RP
            else if k1 == K_IMM and k2 == K_MEM
                i.mode = ir.M_IM
            else if k1 == K_REG and k2 == K_SLOT
                i.mode = ir.M_RS
            else
                error("bad operands")
        }
        else {
            if k1 == K_REG and k2 == K_REG and k3 == K_REG
                i.mode = ir.M_RRR
            else if k1 == K_REG and k2 == K_REG and k3 == K_IMM
                i.mode = ir.M_RRI
            else if k1 == K_REG and k2 == K_IMM and k3 == K_TARGET
                i.mode = ir.M_RIT
            else if k1 == K_REG and k2 == K_REG and k3 == K_TARGET
                i.mode = ir.M_RRT
            else
                error("bad operands")
        }
    }

    ; name(args):results, or a syscall number in place of the name
    sub parse_call(^^ir.Instr i, long p, long stop) {
        long paren = p
        while paren < stop and text[paren] != '('
            paren++
        if paren >= stop {
            error("call without argument list")
            return
        }
        long nameend = paren
        while nameend > p and is_space(text[nameend - 1])
            nameend--
        i.sym = strtab.intern(text + p, (nameend - p) as uword)
        if i.op == ir.OP_SYSCALL
            i.value = number(p, nameend)
        ; the arguments
        long q = paren + 1
        long close = q
        while close < stop and text[close] != ')'
            close++
        while q < close {
            long argend = q
            while argend < close and text[argend] != ','
                argend++
            ir.add_arg(i, call_operand(q, argend))
            q = argend + 1
        }
        ; the results after ':'
        q = close + 1
        while q < stop and is_space(text[q])
            q++
        if q < stop and text[q] == ':' {
            q++
            while q < stop and is_space(text[q])
                q++
            long resend = q
            while resend < stop and not is_space(text[resend])
                resend++
            while q < resend {
                long one = q
                while one < resend and text[one] != ','
                    one++
                ir.add_result(i, call_operand(q, one))
                q = one + 1
            }
        }
    }

    ; [name=]source[@sN]
    sub call_operand(long p, long stop) -> ^^ir.Arg {
        ^^ubyte name = 0
        while p < stop and is_space(text[p])
            p++
        while stop > p and is_space(text[stop - 1])
            stop--
        long eq = p
        while eq < stop and text[eq] != '='
            eq++
        if eq < stop {
            name = strtab.intern(text + p, (eq - p) as uword)
            p = eq + 1
        }
        long at = p
        while at < stop and text[at] != '@'
            at++
        ubyte slot = 255
        if at < stop
            slot = number(at + 2, stop) as ubyte
        ^^Operand o = ops + 3 * sizeof(Operand)
        o.reg = 0
        ^^ir.Arg a
        if text[p] == '#' {
            parse_operand(3, p, at)
            a = ir.new_arg(name, 0, o.type)
            a.value = o.value
        }
        else {
            if not register(p, at, o)
                error("bad call operand")
            a = ir.new_arg(name, o.reg, o.type)
        }
        a.slot = slot
        return a
    }
}
