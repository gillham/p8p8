; String interning: every identifier and string literal in the compiler is
; stored once, so names compare by pointer and the AST never copies text.
; An interned string is zero terminated, so it can be printed as a str.

%import mem
%import buf

strtab {
    %option ignore_unused

    struct Sym {
        ^^Sym next          ; next in the same bucket
        ^^ubyte text        ; the zero-terminated copy
        uword len
        uword hash
        ubyte kind          ; token kind when the text is a keyword, else 0
        uword mark          ; free for a back end (peep6502: what the text is)
        long stamp          ; free for a back end
        long extra          ; free for a back end
        long live           ; free for a back end (peep6502: what is live at a label)
    }

    ^^pointer buckets = 0       ; array of ^^Sym heads
    long nbuckets = 0
    long count = 0
    long text_bytes = 0         ; bytes of interned text, with terminators

    sub init(long size) {
        nbuckets = size
        buckets = mem.alloc(size * sizeof(pointer))
        count = 0
        text_bytes = 0
    }

    ; Returns the canonical copy of the length bytes at text.
    sub intern(^^ubyte text, uword length) -> ^^ubyte {
        ^^Sym s = intern_sym(text, length)
        return s.text
    }

    ; Returns the symbol entry of the length bytes at text, interning them first when needed.
    sub intern_sym(^^ubyte text, uword length) -> ^^Sym {
        if nbuckets == 0
            init(1024)
        uword h = hash(text, length)
        long index = (h as long) % nbuckets
        ^^Sym s = buckets[index]
        while s != 0 {
            if s.hash == h and s.len == length and buf.bytes_equal(s.text, text, length)
                return s
            s = s.next
        }
        s = mem.alloc(sizeof(Sym))
        s.text = mem.alloc((length as long) + 1)
        mem.copy(text, s.text, length)
        s.text[length] = 0
        s.len = length
        s.hash = h
        s.next = buckets[index]
        buckets[index] = s
        count++
        text_bytes += (length as long) + 1
        if count > nbuckets * 2
            rehash()
        return s
    }

    ; Interns a zero-terminated string.
    sub intern_cstr(^^ubyte text) -> ^^ubyte {
        return intern(text, buf.cstr_len(text) as uword)
    }

    sub hash(^^ubyte text, uword length) -> uword {
        ; djb2 variant on 16 bits: cheap on every target
        uword h = 5381
        uword i = 0
        while i < length {
            h = (h << 5) + h ^ text[i]
            i++
        }
        return h
    }

    sub rehash() {
        long oldsize = nbuckets
        ^^pointer old = buckets
        nbuckets = oldsize * 4
        buckets = mem.alloc(nbuckets * sizeof(pointer))
        long i = 0
        while i < oldsize {
            ^^Sym s = old[i]
            while s != 0 {
                ^^Sym next = s.next
                long index = (s.hash as long) % nbuckets
                s.next = buckets[index]
                buckets[index] = s
                s = next
            }
            i++
        }
    }

    sub stats() {
        out.puts("strings: ")
        out.putl(count)
        out.puts(" interned, ")
        out.putl(text_bytes)
        out.puts(" bytes, ")
        out.putl(nbuckets)
        out.puts(" buckets")
        out.nl()
    }
}
