; A Macintosh application from an assembled program (the 68000 Macs, "macplus").
;
; The assembler writes what it does for the Atari ST: a TOS program file, which is the
; text and data sections, the length of the BSS, and a list of the places that hold an
; address.  A Mac's Segment Loader fixes no addresses, so the program does it itself:
; the list is kept behind the program and the library's startup code walks it
; (lib/targets/macplus/prog8_lib.p8).  The program's first bytes are a branch over two
; longs that are filled in here: the length of text and data, and the length of the BSS.
;
; An application is resources: CODE 0, the jump table, with the one entry that the
; system starts the program through; CODE 1, the program; SIZE -1, the memory it
; wants under MultiFinder and System 7.  They are in the file's resource fork, which
; only a Mac's file system has: the file that is written is a MacBinary II file, the
; form that carries both forks and the file's type over other systems, and that the
; tools that write Mac disks take (hfsutils' "hcopy -m").

%import buf
%import mem

macapp {
    %option ignore_unused

    const long BELOW_A5 = 1024      ; QuickDraw's globals (206 bytes) and room to spare
    const long EXTRA = 131072       ; heap and stack on top of the program, for SIZE
    ^^ubyte problem = 0             ; what was wrong with the assembler's file

    sub long_at(^^ubyte data, long at) -> long {
        long v = data[at] as long
        v = (v << 8) | data[at + 1]
        v = (v << 8) | data[at + 2]
        v = (v << 8) | data[at + 3]
        return v
    }

    sub add_word(^^buf.Buf b, long value) {
        buf.add_byte(b, lsb(value >> 8))
        buf.add_byte(b, lsb(value))
    }

    sub add_be(^^buf.Buf b, long value) {
        add_word(b, value >> 16)
        add_word(b, value)
    }

    sub add_zeros(^^buf.Buf b, long count) {
        while count > 0 {
            buf.add_byte(b, 0)
            count--
        }
    }

    sub put_long(^^ubyte data, long at, long value) {
        data[at] = lsb(value >> 24)
        data[at + 1] = lsb(value >> 16)
        data[at + 2] = lsb(value >> 8)
        data[at + 3] = lsb(value)
    }

    ; one resource in the fork's data: its length and its bytes follow
    sub resource(^^buf.Buf b, long length) {
        add_be(b, length)
    }

    ; The MacBinary file of the application, from the TOS file's bytes.  0 when the
    ; file is not what the assembler should have written (problem says what).
    sub wrap(^^ubyte tos, long size, ^^ubyte name) -> ^^buf.Buf {
        if size < 28 or tos[0] != $60 or tos[1] != $1a {
            problem = "not a TOS program file"
            return 0
        }
        long text_len = long_at(tos, 2)
        long data_len = long_at(tos, 6)
        long bss_len = long_at(tos, 10)
        long sym_len = long_at(tos, 14)
        long image = text_len + data_len
        long reloc = 28 + image + sym_len
        if image < 10 or reloc > size or (image & 1) != 0 {
            problem = "its sections are not what a Mac program's are"
            return 0
        }
        ^^ubyte program = tos + 28
        if program[0] != $60 or program[1] != $08 {
            problem = "it does not start with the library's startup code"
            return 0
        }
        put_long(program, 2, image)
        put_long(program, 6, bss_len)
        ; the list of addresses: a long (0: none), then bytes up to a zero
        long reloc_len = 4
        if reloc + 4 <= size and long_at(tos, reloc) != 0 {
            while reloc + reloc_len < size and tos[reloc + reloc_len] != 0
                reloc_len++
            reloc_len++
        }
        long code1 = 4 + image + reloc_len
        if (code1 & 1) != 0
            code1++

        ^^buf.Buf out = buf.new(code1 + 1024)
        ; ---- the MacBinary header, 128 bytes ----
        long name_len = buf.cstr_len(name)
        if name_len > 31
            name_len = 31
        buf.add_byte(out, 0)
        buf.add_byte(out, lsb(name_len))
        buf.add_bytes(out, name, name_len)
        add_zeros(out, 63 - name_len)
        buf.add_str(out, "APPLP8P8")            ; type and creator
        add_zeros(out, 10)                      ; Finder flags, position, folder, protected
        add_be(out, 0)                          ; the data fork's length
        long fork_at = out.len
        add_be(out, 0)                          ; the resource fork's (filled in below)
        add_be(out, $7c25b080)                  ; created and changed: 1 January 1970,
        add_be(out, $7c25b080)                  ;   so that a build is the same every time
        add_zeros(out, 23)
        buf.add_byte(out, 129)                  ; written by MacBinary II,
        buf.add_byte(out, 129)                  ;   and it takes II to read
        add_word(out, crc(out.data, 124))
        add_word(out, 0)

        ; ---- the resource fork ----
        long fork = out.len
        long data_size = (4 + 24) + (4 + code1) + (4 + 10)
        add_be(out, 256)                        ; where the data is,
        add_be(out, 256 + data_size)            ;   and the map
        add_be(out, data_size)
        add_be(out, 28 + 2 + 16 + 36)           ; the map's length
        add_zeros(out, 240)
        ; CODE 0: the sizes above and below A5, and the jump table with its one entry
        resource(out, 24)
        add_be(out, 40)
        add_be(out, BELOW_A5)
        add_be(out, 8)
        add_be(out, 32)
        add_word(out, 0)                        ; the routine at the start of the segment:
        add_word(out, $3f3c)                    ;   move.w #1,-(sp)
        add_word(out, 1)
        add_word(out, $a9f0)                    ;   _LoadSeg
        ; CODE 1: the program and the list of its addresses
        resource(out, code1)
        add_word(out, 0)                        ; its first entry in the jump table,
        add_word(out, 1)                        ;   and how many
        buf.add_bytes(out, program, image)
        if reloc_len == 4
            add_be(out, 0)
        else
            buf.add_bytes(out, tos + reloc, reloc_len)
        if ((4 + image + reloc_len) & 1) != 0
            buf.add_byte(out, 0)
        ; SIZE -1: 32 bit clean, knows about MultiFinder; preferred and smallest memory
        long wants = (code1 + bss_len + BELOW_A5 + EXTRA + 4095) & $7ffff000
        resource(out, 10)
        add_word(out, $5880)
        add_be(out, wants + EXTRA)
        add_be(out, wants)
        ; the map: a copy of the header (may be zero), the list of types, the resources
        add_zeros(out, 24)
        add_word(out, 28)                       ; where the types are, from the map's start
        add_word(out, 28 + 2 + 16 + 36)         ;   and the names (there are none)
        add_word(out, 1)                        ; two types
        buf.add_str(out, "CODE")
        add_word(out, 1)                        ;   two of them,
        add_word(out, 2 + 16)                   ;   listed here (from the list of types)
        buf.add_str(out, "SIZE")
        add_word(out, 0)
        add_word(out, 2 + 16 + 24)
        reference(out, 0, 0)
        reference(out, 1, 4 + 24)
        reference(out, -1, 4 + 24 + 4 + code1)
        long fork_len = out.len - fork
        put_long(out.data, fork_at, fork_len)
        ; (the header's check sum is over the lengths too)
        long sum = crc(out.data, 124)
        out.data[124] = lsb(sum >> 8)
        out.data[125] = lsb(sum)
        add_zeros(out, (128 - (fork_len & 127)) & 127)
        return out
    }

    ; a resource in the map: its number, no name, where its data is
    sub reference(^^buf.Buf b, long number, long at) {
        add_word(b, number)
        add_word(b, $ffff)
        add_be(b, at)               ; (the first byte is its attributes: none)
        add_be(b, 0)
    }

    ; the check sum of a MacBinary header: CRC-16 as XMODEM has it
    sub crc(^^ubyte data, long count) -> long {
        long sum = 0
        long k
        for k in 0 to count - 1 {
            sum ^= (data[k] as long) << 8
            repeat 8 {
                if (sum & $8000) != 0
                    sum = ((sum << 1) ^ $1021) & $ffff
                else
                    sum = (sum << 1) & $ffff
            }
        }
        return sum
    }
}
