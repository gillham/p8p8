; The file routines of the coco2 target (diskio: Disk BASIC's files through its sector
; routine): a text file written and read back by lines, bytes saved and loaded, the
; two-byte header, rename, delete, exists, a file of several granules, a file that
; another program wrote, and the directory.  make cocosys runs it in XRoar with a disk
; that has one file, HOST.TXT.

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

        ; a file of more than two granules (2304 bytes each), written in pieces and read
        ; back in other pieces
        for k in 0 to 299
            buffer[k] = lsb(k * 3 + 1)
        if diskio.f_open_w("big.dat:0") {
            repeat 17
                void diskio.f_write(buffer, 300)
            diskio.f_close_w()
        }
        txt.print(diskio.status())
        txt.spc()
        uword total = 0
        wrong = 0
        if diskio.f_open("big.dat") {
            txt.print_l(diskio.f_size())
            txt.spc()
            repeat {
                uword got = diskio.f_read(back, 256)
                if got == 0
                    break
                for k in 0 to got - 1 {
                    if back[k] != lsb(((total + k) % 300) * 3 + 1)
                        wrong++
                }
                total += got
            }
            diskio.f_close()
        }
        txt.print_uw(total)
        txt.spc()
        txt.print_uw(wrong)
        txt.nl()

        ; a file that another program put on the disk
        if diskio.f_open("host.txt") {
            repeat {
                length, state = diskio.f_readline(buffer)
                txt.print(buffer)
                txt.chrout('|')
                if state != 0
                    break
            }
            diskio.f_close()
        }
        txt.nl()
        ; an empty file, and the directory
        if diskio.f_open_w("empty")
            diskio.f_close_w()
        if diskio.f_open("empty") {
            txt.print_l(diskio.f_size())
            diskio.f_close()
        }
        txt.nl()
        void diskio.directory()
    }
}
