; Warnings that are asked for: things that are not wrong but may not be meant.
;
;     -warnunused        a variable, parameter or subroutine that nothing uses
;     -warnunreachable   statements that come after a return, goto, break or continue
;     -warnall           every one of them (also -warnshadow, which is the assembler's)
;
; Only the program's own modules are looked at, not the library's, and not a block or
; module with %option ignore_unused.  Assembly can use anything by name, so nothing is
; said about the variables of a subroutine or block that has assembly in it.

%import ast
%import symtab
%import importer
%import diag
%import source
%import buf
%import strings
%import strtab
%import parser

warn {
    %option ignore_unused

    bool unused = false
    bool unreachable = false

    const ubyte M_USED = 1          ; symtab.Sym.marks: the resolver saw the name used

    sub run() {
        if not unused and not unreachable
            return
        ^^ubyte kw_ignore = strtab.intern_cstr("ignore_unused")
        ^^importer.Module m = importer.modules
        while m != 0 {
            if not m.is_library and not symtab.has_option(m.tree.a, kw_ignore) {
                ^^ast.Node b = m.tree.a
                while b != 0 {
                    if b.kind == ast.N_BLOCK and not symtab.has_option(b.a, kw_ignore) {
                        if unused
                            unused_in_block(b)
                        if unreachable
                            unreachable_in(b.a)
                    }
                    b = b.next
                }
            }
            m = m.next
        }
    }

    sub warning(^^ast.Node at, str what, ^^ubyte name, str rest) {
        buf.clear(parser.scratch)
        buf.add_str(parser.scratch, what)
        if name != 0 {
            buf.add_str(parser.scratch, " '")
            buf.add_str(parser.scratch, name)
            buf.add_byte(parser.scratch, 39)
        }
        buf.add_str(parser.scratch, rest)
        buf.add_byte(parser.scratch, 0)
        diag.warning_at(source.get(at.file), at.line, at.col, parser.scratch.data)
    }

    ; ---- unused ----

    sub unused_in_block(^^ast.Node b) {
        ^^symtab.Sym bs = b.extra
        if bs == 0 or bs.inner == 0
            return
        bool block_asm = has_asm_here(b.a)
        bool is_main = strings.compare(b.name, "main") == 0
        ^^symtab.Sym s = bs.inner.syms
        while s != 0 {
            if s.decl != 0 and s.marks & M_USED == 0 {
                if s.kind == symtab.K_VAR and s.decl.kind == ast.N_VARDECL and not block_asm and not tagged(s.decl, "shared")
                    warning(s.decl, "variable", s.name, " is never used")
                else if s.kind == symtab.K_SUB and s.decl.kind == ast.N_SUB and not block_asm
                        and not (is_main and strings.compare(s.name, "start") == 0)
                    warning(s.decl, "subroutine", s.name, " is never called")
            }
            if s.kind == symtab.K_SUB and s.decl != 0 and s.decl.kind == ast.N_SUB and s.decl.extra == s
                unused_in_sub(s)
            s = s.next
        }
    }

    sub unused_in_sub(^^symtab.Sym sub_sym) {
        if sub_sym.inner == 0 or has_asm(sub_sym.decl.c)
            return
        ^^symtab.Sym s = sub_sym.inner.syms
        while s != 0 {
            if s.decl != 0 {
                if s.marks & M_USED == 0 {
                    if s.kind == symtab.K_VAR and s.decl.kind == ast.N_VARDECL and not tagged(s.decl, "shared")
                        warning(s.decl, "variable", s.name, " is never used")
                    else if s.kind == symtab.K_PARAM and s.decl.kind == ast.N_PARAM and s.decl.b == 0
                        ; (not one that is passed in a register: the code may use the register)
                        warning(s.decl, "parameter", s.name, " is never used")
                    else if s.kind == symtab.K_SUB and s.decl.kind == ast.N_SUB
                        warning(s.decl, "subroutine", s.name, " is never called")
                }
                ; (a subroutine declared inside this one)
                if s.kind == symtab.K_SUB and s.decl.kind == ast.N_SUB and s.decl.extra == s and s != sub_sym
                    unused_in_sub(s)
            }
            s = s.next
        }
    }

    sub tagged(^^ast.Node decl, str tag) -> bool {
        ^^ast.Node t = decl.d
        while t != 0 {
            if t.kind == ast.N_TAG and strings.compare(t.name, tag) == 0
                return true
            t = t.next
        }
        return false
    }

    ; assembly among these statements themselves (a block's own)
    sub has_asm_here(^^ast.Node list) -> bool {
        while list != 0 {
            if list.kind == ast.N_ASM
                return true
            list = list.next
        }
        return false
    }

    ; assembly anywhere in these statements or below them
    sub has_asm(^^ast.Node list) -> bool {
        while list != 0 {
            if list.kind == ast.N_ASM
                return true
            if has_asm(list.a) or has_asm(list.b) or has_asm(list.c) or has_asm(list.d)
                return true
            list = list.next
        }
        return false
    }

    ; ---- unreachable ----

    ; One warning for each list of statements that goes on after a statement that
    ; always leaves it.  A label can be jumped to, and declarations are not code.
    sub unreachable_in(^^ast.Node list) {
        bool left = false
        bool said = false
        while list != 0 {
            when list.kind {
                ast.N_LABEL -> left = false
                ast.N_SUB, ast.N_ASMSUB, ast.N_EXTSUB, ast.N_STRUCT, ast.N_UNION, ast.N_ENUM, ast.N_ALIAS,
                ast.N_DIRECTIVE, ast.N_REMOVED -> {
                }
                ast.N_VARDECL -> {
                    if left and not said and list.b != 0 {
                        warning(list, "this is never reached", 0, " (its value is never assigned)")
                        said = true
                    }
                }
                else -> {
                    if left and not said {
                        warning(list, "this is never reached", 0, "")
                        said = true
                    }
                }
            }
            if list.kind == ast.N_RETURN or list.kind == ast.N_GOTO or list.kind == ast.N_BREAK or list.kind == ast.N_CONTINUE
                left = true
            unreachable_in(list.a)
            unreachable_in(list.b)
            unreachable_in(list.c)
            unreachable_in(list.d)
            list = list.next
        }
    }
}
