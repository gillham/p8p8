; Reads a whole IR file (.p8ir) into an IR program (ir.p8): the other
; direction of ir.write.  The file is upstream's IRFORMAT 8:
;
;     <PROGRAM NAME=.. COMPILERVERSION=.. IRFORMAT="8">
;     <OPTIONS> compTarget=.. and the other options, a line each </OPTIONS>
;     <ASMSYMBOLS> </ASMSYMBOLS>
;     <VARS> the variables, a section for each kind, a line each </VARS>
;     <INITGLOBALS> one chunk </INITGLOBALS>
;     <BLOCK ..> chunks, inline assembly, <SUB ..> and <ASMSUB ..> </BLOCK> ...
;     </PROGRAM>
;
; The instruction lines of a chunk are parsed by irparse.p8.  A file of p8p8's
; own is read back as the program it was written from: the same assembly or
; LLVM IR comes out of it.  For that the first tag has attributes that
; upstream's format does not have (FLOATS, VARSADDRESS, VARORDER, REGTYPES:
; see ir.write).  A file that upstream wrote is read as far as its IR is the
; same: its newer instructions (storep_inc, loadiz, ...) and <LOOP> are not
; known here.

%import ir
%import irparse
%import strtab
%import mem
%import buf
%import out
%import strings

irread {
    %option ignore_unused

    ^^ubyte text = 0
    long pos = 0
    long end = 0
    long errors = 0
    ^^ubyte filename = 0
    ^^buf.Buf nb = 0
    ^^ir.Program prog = 0
    bool own = false            ; the file is one p8p8 wrote

    ; the attributes of the tag that was opened last: text[tag_start..tag_end)
    long tag_start = 0
    long tag_end = 0
    ; the line that was read last: text[ls..le)
    long ls = 0
    long le = 0

    sub error(str message) {
        errors++
        if errors > 20
            return
        long line = 1
        long k = 0
        while k < pos and k < end {
            if text[k] == '\n'
                line++
            k++
        }
        out.err()
        out.puts(filename)
        out.putc(':')
        out.putl(line)
        out.puts(": error: ")
        out.puts(message)
        out.nl()
        out.std()
    }

    ; ---- the text ----

    sub looking_at(str lit) -> bool {
        long n = buf.cstr_len(lit)
        if pos + n > end
            return false
        return buf.bytes_equal(text + pos, lit, n)
    }

    sub skip_space() {
        while pos < end and (text[pos] == ' ' or text[pos] == '\t' or text[pos] == '\r' or text[pos] == '\n')
            pos++
    }

    sub expect(str lit) -> bool {
        skip_space()
        if looking_at(lit) {
            pos += buf.cstr_len(lit)
            return true
        }
        buf.clear(nb)
        buf.add_str(nb, "expected ")
        buf.add_str(nb, lit)
        buf.add_byte(nb, 0)
        error(nb.data)
        return false
    }

    ; where lit is next, from pos on; -1 when it is not there
    sub find(str lit) -> long {
        long n = buf.cstr_len(lit)
        long p = pos
        ubyte first = lit[0]
        while p + n <= end {
            if text[p] == first and buf.bytes_equal(text + p, lit, n)
                return p
            p++
        }
        return -1
    }

    ; is the tag <name ...> next?
    sub at_tag(str name) -> bool {
        skip_space()
        long n = buf.cstr_len(name)
        if pos + n + 1 >= end or text[pos] != '<'
            return false
        if not buf.bytes_equal(text + pos + 1, name, n)
            return false
        ubyte c = text[pos + 1 + n]
        return c == ' ' or c == '>' or c == '\n' or c == '\r' or c == '\t'
    }

    ; goes past <name attributes>; the attributes are kept for attribute()
    sub open_tag(str name) -> bool {
        if not at_tag(name) {
            buf.clear(nb)
            buf.add_str(nb, "expected <")
            buf.add_str(nb, name)
            buf.add_byte(nb, '>')
            buf.add_byte(nb, 0)
            error(nb.data)
            return false
        }
        pos += 1 + buf.cstr_len(name)
        tag_start = pos
        bool quoted = false
        while pos < end and (quoted or text[pos] != '>') {
            if text[pos] == '"'
                quoted = not quoted
            pos++
        }
        tag_end = pos
        if pos < end
            pos++
        return true
    }

    ; text[from..upto) with the XML escapes undone, into nb
    sub unescape(long from, long upto) {
        buf.clear(nb)
        long p = from
        while p < upto {
            ubyte c = text[p]
            if c == '&' {
                if p + 4 <= upto and buf.bytes_equal(text + p, "&lt;", 4) {
                    buf.add_byte(nb, '<')
                    p += 4
                    continue
                }
                if p + 4 <= upto and buf.bytes_equal(text + p, "&gt;", 4) {
                    buf.add_byte(nb, '>')
                    p += 4
                    continue
                }
                if p + 5 <= upto and buf.bytes_equal(text + p, "&amp;", 5) {
                    buf.add_byte(nb, '&')
                    p += 5
                    continue
                }
                if p + 6 <= upto and buf.bytes_equal(text + p, "&quot;", 6) {
                    buf.add_byte(nb, '"')
                    p += 6
                    continue
                }
                if p + 6 <= upto and buf.bytes_equal(text + p, "&apos;", 6) {
                    buf.add_byte(nb, 39)
                    p += 6
                    continue
                }
                if p + 5 <= upto and buf.bytes_equal(text + p, "&#10;", 5) {
                    buf.add_byte(nb, '\n')
                    p += 5
                    continue
                }
            }
            buf.add_byte(nb, c)
            p++
        }
    }

    ; text[from..upto) as a string of the program (a long one is not interned: the
    ; string table's lengths are words)
    sub make_text(long from, long upto) -> ^^ubyte {
        unescape(from, upto)
        return kept()
    }

    sub kept() -> ^^ubyte {
        if nb.len < 60000
            return strtab.intern(nb.data, nb.len as uword)
        ^^ubyte copy = mem.alloc(nb.len + 1)
        mem.copy(nb.data, copy, nb.len)
        copy[nb.len] = 0
        return copy
    }

    ; the value of an attribute of the tag opened last; 0 when it does not have it
    sub attribute(str name) -> ^^ubyte {
        long n = buf.cstr_len(name)
        long p = tag_start
        while p < tag_end {
            while p < tag_end and (text[p] == ' ' or text[p] == '\t' or text[p] == '\n' or text[p] == '\r')
                p++
            long namestart = p
            while p < tag_end and text[p] != '=' and text[p] != ' '
                p++
            long nameend = p
            if p >= tag_end or text[p] != '='
                continue
            p++
            if p >= tag_end or text[p] != '"'
                continue
            p++
            long valuestart = p
            while p < tag_end and text[p] != '"'
                p++
            if nameend - namestart == n and buf.bytes_equal(text + namestart, name, n)
                return make_text(valuestart, p)
            p++
        }
        return 0
    }

    sub attribute_true(str name) -> bool {
        ^^ubyte v = attribute(name)
        return v != 0 and strings.compare(v, "true") == 0
    }

    ; an attribute that is 0 when it is not there or empty
    sub attribute_or_none(str name) -> ^^ubyte {
        ^^ubyte v = attribute(name)
        if v != 0 and v[0] == 0
            return 0
        return v
    }

    ; The next line of a section into ls..le; false at the tag that ends it.
    sub section_line() -> bool {
        skip_space()
        if pos >= end or text[pos] == '<'
            return false
        ls = pos
        while pos < end and text[pos] != '\n'
            pos++
        le = pos
        while le > ls and (text[le - 1] == '\r' or text[le - 1] == ' ')
            le--
        return true
    }

    ; the decimal number at text[p..), up to a character that is not a digit
    sub decimal(long p, long upto) -> long {
        long v = 0
        bool negative = false
        if p < upto and text[p] == '-' {
            negative = true
            p++
        }
        while p < upto and text[p] >= '0' and text[p] <= '9' {
            v = v * 10 + (text[p] - '0')
            p++
        }
        if negative
            return -v
        return v
    }

    ; where the word that starts at p ends: at a space or at upto
    sub word_end(long p, long upto) -> long {
        while p < upto and text[p] != ' '
            p++
        return p
    }

    ; where " key=" is in the line from p on, the last one; -1 when it is not there
    sub last_key(long p, str key) -> long {
        long n = buf.cstr_len(key)
        long found = -1
        while p + n <= le {
            if text[p] == ' ' and buf.bytes_equal(text + p, key, n)
                found = p
            p++
        }
        return found
    }

    ; ---- the program ----

    ; Reads the file's text.  Returns 0 when it is not an IR file that can be used.
    sub read(^^ubyte data, long length, ^^ubyte name) -> ^^ir.Program {
        text = data
        end = length
        pos = 0
        errors = 0
        filename = name
        if nb == 0
            nb = buf.new(1024)
        skip_space()
        if looking_at("<?xml") {
            long close = find("?>")
            if close < 0 {
                error("not an IR file")
                return 0
            }
            pos = close + 2
        }
        if not open_tag("PROGRAM")
            return 0
        ^^ubyte pname = attribute("NAME")
        if pname == 0
            pname = "program"
        ^^ubyte madeby = attribute("COMPILERVERSION")
        own = madeby != 0 and strings.compare(madeby, "p8p8") == 0
        ^^ubyte irformat = attribute("IRFORMAT")
        if irformat != 0 and strings.compare(irformat, "8") != 0
            error("the file is not of IR format 8")
        bool usesfloats = attribute_true("FLOATS")
        ^^ubyte varsaddress = attribute("VARSADDRESS")
        prog = ir.new_program(pname, "")
        prog.floats = usesfloats
        if varsaddress != 0 {
            long vk = 0
            long va = 0
            while varsaddress[vk] >= '0' and varsaddress[vk] <= '9' {
                va = va * 10 + (varsaddress[vk] - '0')
                vk++
            }
            prog.vars_address = va
        }
        ^^ubyte varorder = attribute("VARORDER")
        ^^ubyte regs = attribute("REGTYPES")
        ; a p8p8 file numbers every register in one row; upstream's float registers
        ; have numbers of their own
        irparse.one_row = own
        irparse.exact = true
        read_options()
        if open_tag("ASMSYMBOLS") {
            long symsend = find("</ASMSYMBOLS>")
            if symsend < 0
                error("expected </ASMSYMBOLS>")
            else
                pos = symsend
            void expect("</ASMSYMBOLS>")
        }
        read_vars()
        if varorder != 0
            declared_order(varorder)
        if own and regs != 0 {
            ; every register's type, those of code that was removed too (they have cells)
            long rk = 0
            while regs[rk] != 0 {
                ubyte rtype = irparse.type_of(regs[rk])
                if rtype != ir.T_NONE
                    ir.note_reg((rk + 1) as uword, rtype)
                rk++
            }
            if rk > ir.regcount and rk < 65536
                ir.note_reg(rk as uword, ir.T_NONE)
        }
        if errors == 0 and open_tag("INITGLOBALS") {
            while at_tag("CHUNK") {
                void open_tag("CHUNK")
                read_code(prog.initglobals, 0)
            }
            void expect("</INITGLOBALS>")
        }
        while errors == 0 and at_tag("BLOCK")
            read_block()
        if errors == 0
            void expect("</PROGRAM>")
        irparse.one_row = false
        irparse.exact = false
        if errors > 0
            return 0
        return prog
    }

    ; compTarget is the program's target; outputDir is the writer's; the lines between
    ; them are the options as the code generators read them
    sub read_options() {
        if not open_tag("OPTIONS")
            return
        ^^buf.Buf ob = buf.new(256)
        while section_line() {
            long eq = ls
            while eq < le and text[eq] != '='
                eq++
            if eq - ls == 10 and buf.bytes_equal(text + ls, "compTarget", 10)
                prog.target = make_text(eq + 1, le)
            else if eq - ls == 9 and buf.bytes_equal(text + ls, "outputDir", 9) {
                ; (where the writer's files went)
            }
            else if eq - ls == 10 and buf.bytes_equal(text + ls, "outputFile", 10) {
            }
            else {
                buf.add_bytes(ob, text + ls, le - ls)
                buf.add_byte(ob, '\n')
            }
        }
        void expect("</OPTIONS>")
        if ob.len > 0
            prog.options = strtab.intern(ob.data, ob.len as uword)
    }

    ; ---- variables ----

    sub read_vars() {
        if not open_tag("VARS")
            return
        if at_tag("NOINITCLEAN") {
            void open_tag("NOINITCLEAN")
            while section_line()
                void var_line(false)
            void expect("</NOINITCLEAN>")
        }
        if at_tag("NOINITDIRTY") {
            void open_tag("NOINITDIRTY")
            while section_line()
                void var_line(true)
            void expect("</NOINITDIRTY>")
        }
        if at_tag("INIT") {
            void open_tag("INIT")
            while section_line()
                void var_line(false)
            void expect("</INIT>")
        }
        if at_tag("STRUCTINSTANCESNOINIT") {
            void open_tag("STRUCTINSTANCESNOINIT")
            while section_line()
                instance_line()
            void expect("</STRUCTINSTANCESNOINIT>")
        }
        if at_tag("STRUCTINSTANCES") {
            void open_tag("STRUCTINSTANCES")
            while section_line()
                instance_line()
            void expect("</STRUCTINSTANCES>")
        }
        if at_tag("STRUCTDEFS") {
            void open_tag("STRUCTDEFS")
            while section_line()
                struct_line()
            void expect("</STRUCTDEFS>")
        }
        if at_tag("CONSTANTS") {
            void open_tag("CONSTANTS")
            while section_line()
                constant_line()
            void expect("</CONSTANTS>")
        }
        if at_tag("MEMORYMAPPED") {
            void open_tag("MEMORYMAPPED")
            while section_line()
                memory_line()
            void expect("</MEMORYMAPPED>")
        }
        if at_tag("MEMORYSLABS") {
            void open_tag("MEMORYSLABS")
            while section_line()
                slab_line()
            void expect("</MEMORYSLABS>")
        }
        void expect("</VARS>")
    }

    sub struct_line() {
        ; name size=N fields=...
        long nameend = word_end(ls, le)
        long sizeat = last_key(nameend, " size=")
        long fieldsat = last_key(nameend, " fields=")
        if sizeat < 0 or fieldsat < 0 {
            error("a struct definition is: name size=N fields=...")
            return
        }
        ^^ubyte sname = make_text(ls, nameend)
        ^^ubyte fields = make_text(fieldsat + 8, le)
        ^^ir.Var st = ir.add_var(prog, ir.V_STRUCT, sname, fields, 0)
        st.size = decimal(sizeat + 6, le)
    }

    sub constant_line() {
        ; type name=value [noprefix]
        bool noprefix = false
        if le - ls > 9 and buf.bytes_equal(text + le - 9, " noprefix", 9) {
            noprefix = true
            le -= 9
        }
        long typeend = word_end(ls, le)
        long eq = typeend
        while eq < le and text[eq] != '='
            eq++
        if typeend >= le or eq >= le {
            error("a constant is: type name=value")
            return
        }
        ^^ubyte ctype = make_text(ls, typeend)
        ^^ubyte cname = make_text(typeend + 1, eq)
        ^^ubyte cvalue = make_text(eq + 1, le)
        ^^ir.Var c = ir.add_var(prog, ir.V_CONST, cname, ctype, cvalue)
        c.noprefix = noprefix
    }

    sub memory_line() {
        ; @type name=address
        long from = ls
        if text[from] == '@'
            from++
        long typeend = word_end(from, le)
        long eq = typeend
        while eq < le and text[eq] != '='
            eq++
        if typeend >= le or eq >= le {
            error("a memory mapped variable is: @type name=address")
            return
        }
        ^^ubyte mtype = make_text(from, typeend)
        ^^ubyte mname = make_text(typeend + 1, eq)
        ; (a "zp=" or the like after the address is upstream's, and not used)
        long valueend = word_end(eq + 1, le)
        ^^ubyte maddress = make_text(eq + 1, valueend)
        void ir.add_var(prog, ir.V_MEMVAR, mname, mtype, maddress)
    }

    sub slab_line() {
        ; name size align
        long nameend = word_end(ls, le)
        long sizeend = word_end(nameend + 1, le)
        ^^ubyte slabname = make_text(ls, nameend)
        ^^ir.Var slab = ir.add_var(prog, ir.V_SLAB, slabname, "", 0)
        slab.size = decimal(nameend + 1, le)
        if sizeend < le
            slab.align = decimal(sizeend + 1, le)
    }

    ; The file has the variables by kind.  VARORDER, when the file has it, says in which
    ; order they were declared: a letter for each, the kind (ir.var_letter).  The list is
    ; put back in that order; left as it is when the letters do not fit the variables.
    sub declared_order(^^ubyte order) {
        long count = 0
        ^^ir.Var v = prog.vars
        while v != 0 {
            count++
            v = v.next
        }
        if count == 0 or buf.cstr_len(order) != count
            return
        ^^pointer listed = mem.alloc(count * sizeof(pointer))
        ^^pointer placed = mem.alloc(count * sizeof(pointer))
        ^^ubyte letters = mem.alloc(count)
        long k = 0
        v = prog.vars
        while v != 0 {
            listed[k] = v
            letters[k] = ir.var_letter(v)
            k++
            v = v.next
        }
        ; where the search for the next variable of each kind goes on
        ^^long cursor = mem.alloc(256 * sizeof(long))
        k = 0
        while k < count {
            ubyte want = order[k]
            long at = cursor[want]
            while at < count and letters[at] != want
                at++
            if at >= count
                return
            placed[k] = listed[at]
            cursor[want] = at + 1
            k++
        }
        ^^ir.Var last = 0
        k = 0
        while k < count {
            v = placed[k]
            v.next = 0
            if last == 0
                prog.vars = v
            else
                last.next = v
            last = v
            k++
        }
        prog.lastvar = last
    }

    ; type name[=value] zp=WHERE [split=true] [align=N] [shared=true]
    sub var_line(bool dirty) -> ^^ir.Var {
        long typeend = word_end(ls, le)
        if typeend >= le {
            error("a variable is: type name[=value] zp=...")
            return 0
        }
        long nameend = typeend + 1
        while nameend < le and text[nameend] != '=' and text[nameend] != ' '
            nameend++
        ^^ubyte vtype = make_text(ls, typeend)
        ^^ubyte vname = make_text(typeend + 1, nameend)
        ^^ubyte value = 0
        long rest = nameend
        if nameend < le and text[nameend] == '=' {
            ; the value goes up to the tags, of which zp= is the first
            rest = last_key(nameend, " zp=")
            if rest < 0
                rest = le
            value = make_text(nameend + 1, rest)
        }
        ^^ir.Var v = ir.add_var(prog, ir.V_VAR, vname, vtype, value)
        v.dirty = dirty
        while rest < le {
            while rest < le and text[rest] == ' '
                rest++
            long wordstop = word_end(rest, le)
            if wordstop - rest > 3 and buf.bytes_equal(text + rest, "zp=", 3)
                v.zp = make_text(rest + 3, wordstop)
            else if wordstop - rest == 10 and buf.bytes_equal(text + rest, "split=true", 10)
                v.split = true
            else if wordstop - rest > 6 and buf.bytes_equal(text + rest, "align=", 6)
                v.align = decimal(rest + 6, wordstop)
            else if wordstop - rest == 11 and buf.bytes_equal(text + rest, "shared=true", 11)
                v.shared = true
            else if wordstop - rest == 10 and buf.bytes_equal(text + rest, "dirty=true", 10)
                v.dirty = true
            rest = wordstop
        }
        return v
    }

    ; structname name size=N [values=...]
    sub instance_line() {
        long typeend = word_end(ls, le)
        long nameend = word_end(typeend + 1, le)
        long sizeat = last_key(typeend, " size=")
        if typeend >= le or sizeat < 0 {
            error("a struct instance is: struct name size=N [values=...]")
            return
        }
        ^^ubyte itype = make_text(ls, typeend)
        ^^ubyte iname = make_text(typeend + 1, nameend)
        ^^ubyte values = 0
        long valuesat = sizeat + 6
        while valuesat < le and text[valuesat] != ' '
            valuesat++
        if valuesat + 8 <= le and buf.bytes_equal(text + valuesat, " values=", 8)
            values = make_text(valuesat + 8, le)
        ^^ir.Var iv = ir.add_var(prog, ir.V_INSTANCE, iname, itype, values)
        iv.size = decimal(sizeat + 6, le)
    }

    ; ---- code ----

    ; After <CHUNK ...>: the instructions between <CODE> and </CODE> into the chunk.
    sub read_code(^^ir.Chunk c, ^^ir.Sub owner) {
        long codeat = find("<CODE>")
        long codeend = find("</CODE>")
        if codeat < 0 or codeend < codeat {
            error("a chunk without <CODE>")
            return
        }
        pos = codeat + 6
        irparse.begin(owner, c)
        irparse.parse_text(text + pos, codeend - pos)
        if irparse.errors > 0 {
            errors += irparse.errors
            error("that chunk is not understood")
        }
        pos = codeend
        void expect("</CODE>")
        void expect("</CHUNK>")
    }

    ; After <ASM ...>: the text up to </ASM>, without the line ends the writer puts
    ; around it; -1 for its length when there is no text at all.
    ^^ubyte asm_text = 0
    long asm_length = 0

    sub read_assembly() {
        asm_text = 0
        asm_length = -1
        long close = find("</ASM>")
        if close < 0 {
            error("expected </ASM>")
            return
        }
        long from = pos
        long upto = close
        if from < upto and text[from] == '\n' {
            from++
            if upto > from and text[upto - 1] == '\n'
                upto--
            else if upto == from
                from = upto + 1         ; (nothing: only the line end before </ASM>)
        }
        if from <= upto {
            unescape(from, upto)
            asm_text = mem.alloc(nb.len + 1)
            mem.copy(nb.data, asm_text, nb.len)
            asm_text[nb.len] = 0
            asm_length = nb.len
        }
        pos = close + 6
    }

    sub read_block() {
        void open_tag("BLOCK")
        ^^ubyte bname = attribute("NAME")
        if bname == 0 {
            error("a block without a name")
            return
        }
        ^^ubyte bpos = attribute("POS")
        if bpos == 0
            bpos = ""
        ^^ir.Block b = ir.add_block(prog, bname, bpos, attribute_true("LIBRARY"))
        b.address = attribute_or_none("ADDRESS")
        b.force_output = attribute_true("FORCEOUTPUT")
        b.no_prefixing = attribute_true("NOPREFIXING")
        b.ignore_unused = attribute_true("IGNOREUNUSED")
        b.chipram = attribute_true("AMIGACHIPRAM")
        while errors == 0 {
            if at_tag("CHUNK") {
                void open_tag("CHUNK")
                ^^ir.Chunk c = ir.add_block_chunk(b, attribute_or_none("LABEL"))
                read_code(c, 0)
            }
            else if at_tag("ASM") {
                void open_tag("ASM")
                ^^ir.Chunk ac = ir.add_block_chunk(b, attribute_or_none("LABEL"))
                ac.kind = ir.C_ASM
                ac.is_ir = attribute_true("IR")
                read_assembly()
                ac.text = asm_text
                ac.textlen = asm_length
                if asm_length < 0 {
                    ac.text = ""
                    ac.textlen = 0
                }
            }
            else if at_tag("SUB")
                read_sub(b)
            else if at_tag("ASMSUB")
                read_asmsub(b)
            else
                break
        }
        void expect("</BLOCK>")
    }

    sub read_sub(^^ir.Block b) {
        void open_tag("SUB")
        ^^ubyte sname = attribute("NAME")
        if sname == 0 {
            error("a subroutine without a name")
            return
        }
        ^^ubyte spos = attribute("POS")
        if spos == 0
            spos = ""
        ^^ir.Sub s = ir.add_sub(b, sname, spos)
        ^^ubyte returns = attribute("RETURNS")
        if returns != 0
            s.returns = returns
        if open_tag("PARAMS") {
            while section_line() {
                ; type name
                long typeend = word_end(ls, le)
                if typeend >= le {
                    error("a parameter is: type name")
                    continue
                }
                ^^ubyte ptype = make_text(ls, typeend)
                ^^ubyte pname = make_text(typeend + 1, le)
                void ir.add_param(s, pname, ptype)
            }
            void expect("</PARAMS>")
        }
        while errors == 0 {
            if at_tag("CHUNK") {
                void open_tag("CHUNK")
                ^^ir.Chunk c = ir.add_chunk(s, attribute_or_none("LABEL"))
                read_code(c, s)
            }
            else if at_tag("ASM") {
                void open_tag("ASM")
                ^^ubyte alabel = attribute_or_none("LABEL")
                bool is_ir = attribute_true("IR")
                read_assembly()
                if asm_length < 0 {
                    asm_text = ""
                    asm_length = 0
                }
                void ir.add_asm_chunk(s, alabel, asm_text, asm_length, is_ir)
            }
            else
                break
        }
        void expect("</SUB>")
    }

    sub read_asmsub(^^ir.Block b) {
        void open_tag("ASMSUB")
        ^^ubyte sname = attribute("NAME")
        if sname == 0 {
            error("an asmsub without a name")
            return
        }
        ^^ubyte spos = attribute("POS")
        if spos == 0
            spos = ""
        ^^ir.Sub s = ir.add_sub(b, sname, spos)
        s.is_asm = true
        s.is_inline = attribute_true("INLINE")
        s.is_external = attribute_true("EXTERNAL")
        s.clobbers_declared = attribute_true("CLOBBERSDECLARED")
        s.clobbered = attribute("CLOBBERS")
        if s.clobbered != 0 and s.clobbered[0] == 0 and not s.clobbers_declared
            s.clobbered = 0
        ^^ubyte returns = attribute_or_none("RETURNS")
        if returns != 0 {
            if returns[0] == '-' and returns[1] == ':'
                s.returns = strtab.intern_cstr(returns + 2)     ; values that are in no register
            else {
                ; "A:ubyte,Pc:bool": the registers with the types, and the types alone
                s.asmreturns = returns
                buf.clear(nb)
                long k = 0
                bool intype = false
                while returns[k] != 0 {
                    if returns[k] == ':'
                        intype = true
                    else if returns[k] == ',' {
                        intype = false
                        buf.add_byte(nb, ',')
                    }
                    else if intype
                        buf.add_byte(nb, returns[k])
                    k++
                }
                s.returns = strtab.intern(nb.data, nb.len as uword)
            }
        }
        if open_tag("ASMPARAMS") {
            while section_line() {
                ; type register, or "type -" for one that is in no register
                long typeend = word_end(ls, le)
                if typeend >= le {
                    error("an asmsub parameter is: type register")
                    continue
                }
                ^^ubyte ptype = make_text(ls, typeend)
                ^^ubyte preg = make_text(typeend + 1, le)
                ^^ir.Param p = ir.add_param(s, "", ptype)
                if not (preg[0] == '-' and preg[1] == 0) {
                    p.reg = preg
                    p.asmtype = ptype
                }
            }
            void expect("</ASMPARAMS>")
        }
        if at_tag("ASM") {
            void open_tag("ASM")
            s.asm_is_ir = attribute_true("IR")
            read_assembly()
            if asm_length >= 0 {
                s.asmtext = asm_text
                s.asmlen = asm_length
            }
        }
        void expect("</ASMSUB>")
    }
}
