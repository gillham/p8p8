; The file routines of the TRS-80 targets (diskio, through the DOS): the same program as
; tests/z80sys/files.p8 without the directory.  These DOSes keep a file's length in
; bytes, so what was saved comes back exactly.  make trs80sys runs it on the Model I
; and III with TRSDOS, the Model III with LDOS and the Model 4.

%import textio
%import diskio
%import strings

main {
    ubyte[300] buffer
    ubyte[300] back

    sub start() {
        uword k
        ubyte length
        ubyte state

        ; a text file, written and read back by lines
        if diskio.f_open_w("lines.txt") {
            void diskio.f_write("first line\r\n", 12)
            void diskio.f_write("second\r\n", 8)
            void diskio.f_write("third, without an end", 21)
            diskio.f_close_w()
        }
        txt.print_bool(diskio.exists("lines.txt"))
        txt.print_bool(diskio.exists("nothere.txt"))
        txt.nl()
        if diskio.f_open("lines.txt") {
            repeat {
                length, state = diskio.f_readline(buffer)
                txt.print_ub(length)
                txt.chrout(':')
                txt.print(buffer)
                txt.nl()
                if state != 0
                    break
            }
            diskio.f_close()
        }

        ; bytes: more than two records, saved and loaded
        for k in 0 to 299
            buffer[k] = lsb(k * 7)
        txt.print_bool(diskio.save_raw("bytes.dat", buffer, 300))
        uword end = diskio.load_raw("bytes.dat", back)
        txt.spc()
        txt.print_uw(end - &back)
        txt.spc()
        uword wrong = 0
        for k in 0 to 299 {
            if back[k] != buffer[k]
                wrong++
        }
        txt.print_uw(wrong)
        txt.nl()

        ; with the two bytes before it that say where it was
        txt.print_bool(diskio.save("where.dat", buffer, 100))
        txt.spc()
        txt.print_bool(diskio.get_loadaddress("where.dat") == &buffer)
        sys.memset(back, 300, 0)
        end = diskio.load("where.dat", back)
        txt.spc()
        txt.print_ub(back[99])
        txt.nl()

        ; rename and delete
        diskio.rename("where.dat", "moved.dat")
        txt.print_bool(diskio.exists("where.dat"))
        txt.print_bool(diskio.exists("moved.dat"))
        diskio.delete("moved.dat")
        txt.print_bool(diskio.exists("moved.dat"))
        txt.spc()
        txt.print_bool(diskio.f_open("nothere.txt"))
        txt.nl()
        diskio.delete("bytes.dat")

    }
}
