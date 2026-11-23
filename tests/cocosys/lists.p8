; More of the coco2 target's file routines (diskio): the place in a file that is read
; (f_seek, f_tell), the files of a disk listed with and without a pattern, and a
; second drive.  make cocosys runs it in XRoar after files.p8, with the disk that
; that left in drive 0 and a disk with two files in drive 1.

%import textio
%import diskio
%import strings

main {
    ubyte[300] buffer
    ubyte[120] names

    sub show(long place) {
        ; the byte of BIG.DAT at the place, as it is and as it should be
        txt.print_bool(diskio.f_seek(place))
        txt.spc()
        if diskio.f_read(buffer, 1) == 1 {
            txt.print_ub(buffer[0])
            txt.chrout('=')
            txt.print_ub(lsb(((place % 300) as uword) * 3 + 1))
        }
        else
            txt.print("end")
        txt.spc()
        long at
        long size
        at, size = diskio.f_tell()
        txt.print_l(at)
        txt.nl()
    }

    sub list(str pattern) {
        if diskio.lf_start_list(pattern) {
            while diskio.lf_next_entry() {
                txt.print(diskio.list_filename)
                txt.spc()
                txt.print(diskio.list_filetype)
                txt.spc()
                txt.print_uw(diskio.list_blocks)
                txt.nl()
            }
        }
        else
            txt.print("no list\n")
        txt.print("-\n")
    }

    sub start() {
        ; BIG.DAT is 5100 bytes, in three granules: places in each, at the ends of
        ; sectors and of a granule, backwards, and at and after its end
        txt.print_bool(diskio.f_seek(10))
        txt.nl()
        if diskio.f_open("big.dat") {
            show(0)
            show(4700)
            show(255)
            show(256)
            show(2303)
            show(2304)
            show(4608)
            show(5099)
            show(5100)
            show(5101)
            show(-1)
            show(1000)
            ; and on from there
            uword got = diskio.f_read(buffer, 300)
            txt.print_uw(got)
            txt.spc()
            txt.print_ub(buffer[299])
            txt.chrout('=')
            txt.print_ub(lsb(((1300 % 300) as uword) * 3 + 1))
            txt.nl()
            diskio.f_close()
        }

        list(0)
        list("*.txt")
        list("?i*")
        list("empty")
        list("*.bas")
        list("*:1")
        list("b*.d?t:1")

        ; a list while files are read, and the names in a buffer
        if diskio.lf_start_list("*.TXT") {
            while diskio.lf_next_entry() {
                txt.print(diskio.list_filename)
                txt.chrout(':')
                if diskio.f_open(diskio.list_filename) {
                    txt.print_l(diskio.f_size())
                    diskio.f_close()
                }
                txt.nl()
            }
        }
        txt.print_ub(diskio.list_filenames("*", names, 120))
        txt.spc()
        uword p = &names
        while @(p) != 0 {
            txt.print(p)
            txt.chrout(',')
            p += strings.length(p) + 1
        }
        txt.nl()

        ; the second drive: a file read from it and one written to it
        if diskio.f_open("one.bas:1") {
            ubyte length
            ubyte state
            length, state = diskio.f_readline(buffer)
            txt.print(buffer)
            txt.nl()
            diskio.f_close()
        }
        txt.print_bool(diskio.save_raw("made.dat:1", buffer, 300))
        txt.print_bool(diskio.exists("made.dat:1"))
        txt.print_bool(diskio.exists("made.dat"))
        txt.nl()
        list("*:1")
        txt.print_bool(strings.pattern_match("hello", "h*l?"))
        txt.print_bool(strings.pattern_match("hello", "h*l"))
        txt.print_bool(strings.pattern_match("", "*"))
        txt.print_bool(strings.pattern_match("abcabc", "*abc"))
        txt.print_bool(strings.pattern_match_nocase("HeLLo", "he??o*", true))
        txt.nl()
    }
}
