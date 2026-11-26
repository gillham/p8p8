; The file routines of the dos target (diskio, through DOS's file handles): a text file
; written and read back by lines, bytes saved and loaded, the two-byte header, seek and
; tell, rename, delete, exists, directories and their lists.
%import textio
%import diskio
%import strings

main {
    ubyte[300] buffer
    ubyte[300] back
    ubyte[64] names

    asmsub is_dos() -> ubyte @AL {
        %asm {{
            mov  ah, 0x30
            int  0x21
            ret
        }}
    }

    sub start() {
        uword k
        ubyte length
        ubyte state
        long position
        long size

        void is_dos()
        diskio.mkdir("P8TEST")
        txt.print_bool(diskio.exists("P8TEST"))
        diskio.chdir("P8TEST")
        uword where = diskio.curdir()
        txt.spc()
        txt.print(where + strings.length(where) - 7)
        txt.nl()

        ; a text file, written and read back by lines
        if diskio.f_open_w("lines.txt") {
            void diskio.f_write("first line\r\n", 12)
            void diskio.f_write("second\r\n", 8)
            void diskio.f_write("unix\n", 5)
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
            ; seek and tell
            txt.print_bool(diskio.f_seek(12))
            txt.spc()
            void diskio.f_read(buffer, 6)
            buffer[6] = 0
            txt.print(buffer)
            position, size = diskio.f_tell()
            txt.spc()
            txt.print_l(position)
            txt.spc()
            txt.print_l(size)
            txt.spc()
            txt.print_l(diskio.f_size())
            txt.nl()
            diskio.f_close()
        }

        ; bytes: more than what is read ahead, saved and loaded
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
        txt.spc()
        txt.print_ub(diskio.status_code())
        txt.nl()

        ; the directory: one file and one directory are left
        diskio.delete("bytes.dat")
        diskio.mkdir("SUB")
        txt.print_ub(diskio.list_filenames("*.TXT", names, 64))
        txt.spc()
        txt.print(names)
        txt.nl()
        void diskio.directory_files()
        void diskio.directory_dirs()
        if diskio.lf_start_list("LINES.*") {
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

        ; and nothing is left
        diskio.rmdir("SUB")
        diskio.delete("lines.txt")
        txt.print_ub(diskio.list_filenames(0, names, 64))
        diskio.chdir("..")
        diskio.rmdir("P8TEST")
        txt.spc()
        txt.print_bool(diskio.exists("P8TEST"))
        txt.nl()
    }
}
