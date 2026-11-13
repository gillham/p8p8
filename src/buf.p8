; Growable byte buffers: source text, output text, and any string being built.
; A buffer is a heap struct; its data is always followed by a zero byte so it
; can be used as a C string at any time.

%import mem

buf {
    %option ignore_unused

    struct Buf {
        ^^ubyte data
        long len
        long cap        ; bytes available in data, not counting the terminator
    }

    sub new(long cap) -> ^^Buf {
        if cap < 16
            cap = 16
        ^^Buf b = mem.alloc(sizeof(Buf))
        b.data = mem.alloc(cap + 1)
        b.len = 0
        b.cap = cap
        return b
    }

    ; Makes room for at least extra more bytes.
    sub reserve(^^Buf b, long extra) {
        long need = b.len + extra
        if need <= b.cap
            return
        long newcap = b.cap * 2
        if newcap < need
            newcap = need
        b.data = mem.grow(b.data, b.len, newcap + 1)
        b.cap = newcap
    }

    sub clear(^^Buf b) {
        b.len = 0
        b.data[0] = 0
    }

    sub add_byte(^^Buf b, ubyte value) {
        if b.len >= b.cap
            reserve(b, 1)
        b.data[b.len] = value
        b.len++
        b.data[b.len] = 0
    }

    sub add_bytes(^^Buf b, pointer data, long count) {
        if count <= 0
            return
        reserve(b, count)
        ^^ubyte d = b.data + b.len
        mem.copy(data, d, count)
        d[count] = 0
        b.len += count
    }

    ; Appends a zero-terminated string of any length.
    sub add_str(^^Buf b, ^^ubyte text) {
        add_bytes(b, text, cstr_len(text))
    }

    ; Appends a signed number in decimal.
    sub add_long(^^Buf b, long value) {
        add_quad(b, value as quad)      ; the quad path also handles the most negative value
    }
    sub add_quad(^^Buf b, quad value) {
        if value < 0 {
            add_byte(b, '-')
            ; two's complement: negating the minimum quad gives its magnitude as uquad
            add_uquad(b, (0 - value) as uquad)
        }
        else
            add_uquad(b, value as uquad)
    }

    ; Appends an unsigned 64-bit number in decimal.
    sub add_uquad(^^Buf b, uquad value) {
        ubyte[24] digits
        ubyte n = 0
        repeat {
            digits[n] = (value % 10) as ubyte + '0'
            n++
            value /= 10
            if value == 0
                break
        }
        repeat {
            n--
            add_byte(b, digits[n])
            if n == 0
                break
        }
    }

    ; Appends the number as 2 hex digits.
    sub add_hex_byte(^^Buf b, ubyte value) {
        add_byte(b, hex_digit(value >> 4))
        add_byte(b, hex_digit(value & 15))
    }

    sub hex_digit(ubyte nibble) -> ubyte {
        if nibble < 10
            return nibble + '0'
        return nibble - 10 + 'a'
    }

    ; Length of a zero-terminated string of any length.
    sub cstr_len(^^ubyte text) -> long {
        long n = 0
        while text[n] != 0
            n++
        return n
    }

    ; True when the two byte sequences are equal.
    sub bytes_equal(^^ubyte a, ^^ubyte b, long count) -> bool {
        long i = 0
        while i < count {
            if a[i] != b[i]
                return false
            i++
        }
        return true
    }
}
