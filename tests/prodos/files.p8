; The file routines of the prodos target (diskio, through ProDOS's MLI): a text file
; written and read back by lines, seek and tell, bytes saved and loaded, a file with
; its address, rename, delete, exists, directories and the directory's list.
; It is started with ProDOS in memory.
%import textio
%import diskio
%import strings

main {
    ubyte[256] buffer
    ubyte[256] back
    ubyte[64] names
    ubyte[66] home
    sub n(str name) -> uword {
        return name
    }

    sub start() {
        uword k
        ubyte b
        ubyte length
        ubyte state
        long position
        long size

        txt.print("\ndiskio\n")
        void strings.copy(diskio.curdir(), home)
        diskio.mkdir("P8TEST")
        txt.print_ub(diskio.status_code())
        txt.spc()
        txt.print_bool(diskio.exists("P8TEST"))
        diskio.chdir("P8TEST")
        uword where = diskio.curdir()
        txt.spc()
        txt.print(where + strings.length(where) - 8)
        txt.nl()

        ; a text file, written and read back by lines
        if diskio.f_open_w(n("lines.txt")) {
            void diskio.f_write("first line\n", 11)
            void diskio.f_write("second\n", 7)
            void diskio.f_write("\n", 1)
            void diskio.f_write("third, without an end", 21)
            diskio.f_close_w()
        }
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
            ; seek and tell
            txt.print_bool(diskio.f_seek(11))
            txt.spc()
            void diskio.f_read(buffer, 6)
            buffer[6] = 0
            txt.print(buffer)
            position, size = diskio.f_tell()
            txt.spc()
            txt.print_l(position)
            txt.spc()
            txt.print_l(size)
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
        diskio.mkdir("SUB")
        txt.print_ub(diskio.list_filenames(0, names, 64))
        txt.spc()
        txt.print_ub(diskio.list_filenames(n("*.TXT"), names, 64))
        txt.spc()
        txt.print(names)
        txt.nl()
        if diskio.lf_start_list(n("LINES.*")) {
            while diskio.lf_next_entry() {
                txt.print(diskio.list_filename)
                txt.spc()
                txt.print(diskio.list_filetype)
                txt.spc()
                txt.print_l(diskio.list_filesize)
                txt.spc()
                txt.print_uw(diskio.list_blocks)
                txt.nl()
            }
            diskio.lf_end_list()
        }

        ; and nothing of the test is left
        diskio.rmdir("SUB")
        diskio.delete(n("lines.txt"))
        txt.print_ub(diskio.list_filenames(0, names, 64))
        diskio.chdir(home)
        diskio.rmdir("P8TEST")
        txt.spc()
        txt.print_ub(diskio.status_code())
        txt.spc()
        txt.print_bool(diskio.exists("P8TEST"))
        txt.nl()
    }
}
