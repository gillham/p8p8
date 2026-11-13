%import textio
%import diskio
main {
    ubyte[100] buffer
    sub start() {
        void diskio.directory()
        if diskio.f_open("x.txt") {
            void diskio.f_read(buffer, 10)
            void diskio.f_read_all(buffer)
            void diskio.f_readline(buffer)
            diskio.f_seek(5)
            diskio.f_close()
        }
        if diskio.f_open_w("y.txt") {
            void diskio.f_write(buffer, 10)
            diskio.f_close_w()
        }
        void diskio.save("z.bin", buffer, 10)
        void diskio.load("z.bin", buffer)
        void diskio.load_raw("z.bin", buffer)
        void diskio.exists("z.bin")
        diskio.delete("z.bin")
        diskio.rename("a", "b")
        txt.print(diskio.curdir())
    }
}
