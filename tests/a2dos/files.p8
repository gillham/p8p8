; The file routines of the appleii target (diskio, through DOS 3.3): a text
; file written and read back by lines, bytes saved and loaded, the two-byte header,
; rename, delete, exists, and the directory's list.
; It is run from a DOS 3.3 disk (BRUN).
%import textio
%import diskio
%import strings

main {
    ubyte[256] buffer
    ubyte[256] back
    ubyte[64] names
    sub n(str name) -> uword {
        return name
    }

    sub start() {
        uword k
        ubyte b
        ubyte length
        ubyte state

        txt.print("\ndiskio\n")

        ; a text file, written and read back by lines
        diskio.file_type = diskio.TEXT
        if diskio.f_open_w(n("lines.txt")) {
            void diskio.f_write("first line\n", 11)
            void diskio.f_write("second\n", 7)
            void diskio.f_write("\n", 1)
            void diskio.f_write("third, without an end", 21)
            diskio.f_close_w()
        }
        diskio.file_type = diskio.BINARY
        txt.print_bool(diskio.exists(n("lines.txt")))
        txt.print_bool(diskio.exists(n("nothere.txt")))
        txt.nl()
        if diskio.f_open(n("lines.txt")) {
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
        if diskio.f_open(n("lines.txt")) {
            txt.print_uw(diskio.f_read(buffer, 6))
            buffer[5] = 0
            txt.spc()
            txt.print(buffer)
            txt.spc()
            txt.print_uw(diskio.f_read(buffer, 250))
            txt.spc()
            txt.print_uw(diskio.f_read(buffer, 250))
            txt.nl()
            diskio.f_close()
        }

        ; bytes: more than a sector, saved and loaded
        for b in 0 to 249
            buffer[b] = b * 7
        txt.print_bool(diskio.save_raw(n("bytes.dat"), buffer, 250))
        uword end = diskio.load_raw(n("bytes.dat"), back)
        txt.spc()
        txt.print_uw(end - &back)
        txt.spc()
        uword wrong = 0
        for b in 0 to 249 {
            if back[b] != buffer[b]
                wrong++
        }
        txt.print_uw(wrong)
        txt.nl()

        ; with the two bytes before it that say where it was
        txt.print_bool(diskio.save(n("where.dat"), buffer, 100))
        txt.spc()
        txt.print_bool(diskio.get_loadaddress(n("where.dat")) == &buffer)
        sys.memset(back, 250, 0)
        end = diskio.load(n("where.dat"), back)
        txt.spc()
        txt.print_ub(back[99])
        txt.nl()

        ; rename and delete
        diskio.rename(n("where.dat"), "moved.dat")
        txt.print_ub(diskio.status_code())
        txt.spc()
        txt.print_bool(diskio.exists(n("where.dat")))
        txt.print_bool(diskio.exists(n("moved.dat")))
        diskio.delete(n("moved.dat"))
        txt.print_bool(diskio.exists(n("moved.dat")))
        txt.spc()
        txt.print_bool(diskio.f_open(n("nothere.txt")))
        txt.spc()
        txt.print_ub(diskio.status_code())
        txt.nl()

        ; the directory
        diskio.delete(n("bytes.dat"))
        txt.print_ub(diskio.list_filenames(n("*.TXT"), names, 64))
        txt.spc()
        txt.print(names)
        txt.nl()
        if diskio.lf_start_list(n("LINES.*")) {
            while diskio.lf_next_entry() {
                txt.print(diskio.list_filename)
                txt.spc()
                txt.print(diskio.list_filetype)
                txt.print_bool(diskio.list_locked)
                txt.spc()
                txt.print_uw(diskio.list_blocks)
                txt.nl()
            }
            diskio.lf_end_list()
        }

        ; and nothing of the test is left
        diskio.delete(n("lines.txt"))
        txt.print_ub(diskio.list_filenames(n("*.TXT"), names, 64))
        txt.spc()
        txt.print_ub(diskio.list_filenames(n("*.DAT"), names, 64))
        txt.nl()
    }
}
