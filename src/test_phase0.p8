; Tests of the phase 0 modules: memory, buffers, output, interning, source files.
; The expected output is in tests/expected/llvm64_test_phase0.txt.

%import out
%import mem
%import buf
%import strtab
%import source
%zeropage basicsafe

main {
    uword failures = 0

    sub start() {
        out.init()
        test_mem()
        test_buf()
        test_strtab()
        test_source()
        out.puts("failures: ")
        out.putl(failures)
        out.nl()
        out.exit(lsb(failures))
    }

    sub check(bool ok, str what) {
        out.puts(what)
        if ok
            out.puts(": ok")
        else {
            out.puts(": FAILED")
            failures++
        }
        out.nl()
    }

    sub test_mem() {
        pointer a = mem.alloc(1)
        pointer b = mem.alloc(1)
        check(b - a == 8, "alloc aligns to 8")
        check(@(a) == 0, "alloc is zeroed")
        pointer c = mem.alloc(100000)
        check(c != 0, "alloc bigger than a chunk")
        ; grow the last allocation in place, then one that must move
        ^^ubyte d = mem.alloc(16)
        d[0] = 'x'
        ^^ubyte e = mem.grow(d, 16, 64)
        check(e == d and e[0] == 'x', "grow in place keeps the address and data")
        pointer other = mem.alloc(8)
        ^^ubyte f = mem.grow(e, 64, 128)
        check(f != e and f[0] == 'x', "grow by copy moves the data")
        check(mem.count_grow_inplace == 1 and mem.count_grow_copy == 1, "grow counters")
    }

    sub test_buf() {
        ^^buf.Buf b = buf.new(4)
        buf.add_str(b, "abc")
        buf.add_byte(b, 'd')
        buf.add_str(b, "efghij")
        check(b.len == 10 and b.data[10] == 0, "buffer grows and stays terminated")
        check(buf.bytes_equal(b.data, "abcdefghij", 10), "buffer contents")
        buf.clear(b)
        buf.add_long(b, 0)
        buf.add_byte(b, ' ')
        buf.add_long(b, -12345)
        buf.add_byte(b, ' ')
        buf.add_long(b, 2147483647)
        buf.add_byte(b, ' ')
        buf.add_hex_byte(b, $a5)
        out.puts("numbers: ")
        out.put_bytes(b.data, b.len)
        out.nl()
        ; a buffer bigger than a chunk
        ^^buf.Buf big = buf.new(16)
        repeat 70000 {          ; (a count above 65536: once a compiler bug, see bugs/repeat_count_crash.p8)
            buf.add_byte(big, 'z')
        }
        ^^ubyte bd = big.data
        check(big.len == 70000 and bd[69999] == 'z' and bd[70000] == 0, "70000 byte buffer")
    }

    sub test_strtab() {
        ^^ubyte a = strtab.intern("hello", 5)
        ^^ubyte b = strtab.intern_cstr("hello")
        ^^ubyte c = strtab.intern("help", 4)
        check(a == b, "same text interns to the same pointer")
        check(a != c, "different text interns differently")
        check(a[5] == 0 and buf.bytes_equal(a, "hello", 5), "interned copy is terminated")
        ; many distinct strings force a rehash
        ^^buf.Buf nb = buf.new(16)
        long i = 0
        while i < 5000 {
            buf.clear(nb)
            buf.add_str(nb, "name")
            buf.add_long(nb, i)
            void strtab.intern(nb.data, nb.len as uword)
            i++
        }
        check(strtab.count == 5002, "5002 interned after rehash")
        buf.clear(nb)
        buf.add_str(nb, "name4999")
        check(strtab.intern(nb.data, 8) == strtab.intern_cstr("name4999"), "lookup after rehash")
        check(strtab.intern_cstr("hello") == a, "old entry survives rehash")
    }

    sub test_source() {
        ^^source.File f = source.load("tests/hello.p8")
        check(f != 0, "load a file")
        if f == 0
            return
        ^^ubyte text = f.text
        check(f.len == 85 and text[85] == 0, "file length and terminator")
        check(text[0] == '%' and f.index == 0, "file text and index")
        check(source.load("tests/does_not_exist.p8") == 0, "missing file gives 0")
        check(source.get(0) == f and source.count == 1, "file registry")
    }
}
