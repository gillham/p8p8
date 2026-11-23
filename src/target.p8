; The configuration of a target machine, read from a properties file in the
; format of the upstream compiler's custom targets (docs/TARGETS.md):
;
;     -target config/mega65.properties      the file itself
;     -target c64                           <lib>/c64/target.properties, or
;                                           <lib>/targets/c64/target.properties, or
;                                           <lib>/targets/c64.properties
;
; where <lib> is the library directory.  Nothing about a 6502 machine is built
; into the compiler: its memory map, zero page and startup code are text, and
; the machines that Prog8 has built in are files of the library like any other.
;
; The llvm, virtual and 68000 targets are not machines of this kind and have no
; file; neither has a name nobody wrote one for (loaded stays false, and the
; program gets neutral defaults).
;
; A properties file: "key = value" lines, # and ; comments, a value continued on
; the next line with a backslash at the end, and \n for a new line in a value.

%import buf
%import mem
%import strtab
%import strings
%import io_platform

target {
    %option ignore_unused

    bool loaded = false
    ^^ubyte file = 0                ; the path of the file that was read
    ^^ubyte dir = 0                 ; and the directory it is in (0: the current one)
    ^^ubyte error_text = 0          ; why resolve failed, or 0

    const ubyte MAX_KEYS = 64
    ^^pointer keys = 0
    ^^pointer values = 0
    ubyte count = 0
    ^^buf.Buf path = 0
    ^^buf.Buf scratch = 0

    sub setup() {
        if keys == 0 {
            keys = mem.alloc(MAX_KEYS * sizeof(pointer))
            values = mem.alloc(MAX_KEYS * sizeof(pointer))
            path = buf.new(512)
            scratch = buf.new(1024)
        }
    }

    sub ends_with(^^ubyte s, str suffix) -> bool {
        long n = buf.cstr_len(s)
        long m = buf.cstr_len(suffix)
        if m > n
            return false
        return strings.compare(s + (n - m), suffix) == 0
    }

    sub is_space(ubyte c) -> bool {
        return c == ' ' or c == '\t' or c == '\r'
    }

    ; Finds the configuration for what -target names; gives the target's name (the
    ; file's name without directory and ".properties", or the name as it is).
    ; A file that is named but cannot be read is an error: 0, with error_text set.
    sub resolve(^^ubyte spec, ^^ubyte libdir) -> ^^ubyte {
        setup()
        loaded = false
        error_text = 0
        count = 0
        if ends_with(spec, ".properties") {
            if not load(spec) {
                error_text = "cannot read the target configuration file"
                return 0
            }
            ; the name: after the last slash, before the dot
            long start = 0
            long i = 0
            while spec[i] != 0 {
                if spec[i] == '/' or spec[i] == '\\'
                    start = i + 1
                i++
            }
            return strtab.intern(spec + start, (i - start - 11) as uword)
        }
        ; a name: a file for it in the library
        if libdir != 0 {
            buf.clear(path)
            buf.add_str(path, libdir)
            buf.add_byte(path, '/')
            buf.add_str(path, spec)
            buf.add_str(path, "/target.properties")
            buf.add_byte(path, 0)
            if load(path.data)
                return spec
            ; (a library with the machines beside the modules that all share: targets/<name>/)
            buf.clear(path)
            buf.add_str(path, libdir)
            buf.add_str(path, "/targets/")
            buf.add_str(path, spec)
            buf.add_str(path, "/target.properties")
            buf.add_byte(path, 0)
            if load(path.data)
                return spec
            buf.clear(path)
            buf.add_str(path, libdir)
            buf.add_str(path, "/targets/")
            buf.add_str(path, spec)
            buf.add_str(path, ".properties")
            buf.add_byte(path, 0)
            if load(path.data)
                return spec
        }
        return spec
    }

    ; Reads a properties file; false when there is none.  A file may name another that
    ; it is made from ("base = file", beside it): what it says itself comes first, and
    ; the other file gives the keys it does not have.  A path in a key of the other file
    ; is still read from where the first one is.
    sub load(^^ubyte name) -> bool {
        if not parse(name, false)
            return false
        ^^ubyte from = text("base")
        if from != 0 {
            ^^buf.Buf bp = buf.new(256)
            if dir != 0 and from[0] != '/' {
                buf.add_str(bp, dir)
                buf.add_byte(bp, '/')
            }
            buf.add_str(bp, from)
            buf.add_byte(bp, 0)
            if not parse(bp.data, true) {
                loaded = false
                return false
            }
        }
        return true
    }

    ; the keys of one file; more: after those that are there already
    sub parse(^^ubyte name, bool more) -> bool {
        setup()
        long size = io_platform.file_size(name)
        if size < 0
            return false
        ^^ubyte text = mem.alloc(size + 2)
        long got = io_platform.read_file(name, text, size)
        if got < 0
            return false
        text[got] = 0
        if not more
            count = 0
        long i = 0
        while text[i] != 0 {
            ; one logical line
            while is_space(text[i])
                i++
            if text[i] == '#' or text[i] == ';' or text[i] == '!' or text[i] == '\n' {
                while text[i] != 0 and text[i] != '\n'
                    i++
                if text[i] == '\n'
                    i++
                continue
            }
            if text[i] == 0
                break
            long kstart = i
            while text[i] != 0 and text[i] != '\n' and text[i] != '=' and text[i] != ':'
                i++
            long kend = i
            while kend > kstart and is_space(text[kend - 1])
                kend--
            buf.clear(scratch)
            if text[i] == '=' or text[i] == ':' {
                i++
                while is_space(text[i])
                    i++
                while text[i] != 0 and text[i] != '\n' {
                    if text[i] == '\\' {
                        i++
                        when text[i] {
                            'n' -> buf.add_byte(scratch, '\n')
                            't' -> buf.add_byte(scratch, '\t')
                            '\r' -> {
                                ; (a backslash before a Windows line end)
                                if text[i + 1] == '\n'
                                    i++
                                i++
                                while is_space(text[i])
                                    i++
                                continue
                            }
                            '\n' -> {
                                ; the value goes on in the next line, after its indentation
                                i++
                                while is_space(text[i])
                                    i++
                                continue
                            }
                            0 -> break
                            else -> buf.add_byte(scratch, text[i])
                        }
                        i++
                    }
                    else {
                        buf.add_byte(scratch, text[i])
                        i++
                    }
                }
                while scratch.len > 0 and is_space(scratch.data[scratch.len - 1])
                    scratch.len--
            }
            if text[i] == '\n'
                i++
            if kend > kstart and count < MAX_KEYS {
                keys[count] = strtab.intern(text + kstart, (kend - kstart) as uword)
                values[count] = strtab.intern(scratch.data, scratch.len as uword)
                count++
            }
        }
        if more
            return true
        loaded = true
        file = strtab.intern_cstr(name)
        dir = 0
        long cut = -1
        long di = 0
        while name[di] != 0 {
            if name[di] == '/' or name[di] == '\\'
                cut = di
            di++
        }
        if cut > 0
            dir = strtab.intern(name, cut as uword)
        return true
    }

    ; is the loaded target a Z80 machine?
    sub z80() -> bool {
        ^^ubyte c = get("cpu")
        return c != 0 and strings.compare(c, "z80") == 0
    }

    ; is the loaded target a 6809 machine?
    sub m6809() -> bool {
        ^^ubyte c = get("cpu")
        return c != 0 and strings.compare(c, "6809") == 0
    }

    ; the value of a key, or 0 when the file does not have it
    sub get(str key) -> ^^ubyte {
        if not loaded
            return 0
        ubyte k = 0
        while k < count {
            if strings.compare(keys[k], key) == 0
                return values[k]
            k++
        }
        return 0
    }

    ; the value of a key that is there and not empty, or 0
    sub text(str key) -> ^^ubyte {
        ^^ubyte v = get(key)
        if v == 0 or v[0] == 0
            return 0
        return v
    }

    ; a number as a properties file writes it: decimal, $hex, 0xhex or %binary
    sub parse_number(^^ubyte t) -> bool, long {
        long v = 0
        long i = 0
        long base = 10
        while is_space(t[i])
            i++
        if t[i] == '$' {
            base = 16
            i++
        }
        else if t[i] == '%' {
            base = 2
            i++
        }
        else if t[i] == '0' and (t[i + 1] == 'x' or t[i + 1] == 'X') {
            base = 16
            i += 2
        }
        long digits = 0
        repeat {
            ubyte c = t[i]
            long d = 99
            if c >= '0' and c <= '9'
                d = c - '0'
            else if c >= 'a' and c <= 'f'
                d = c - 'a' + 10
            else if c >= 'A' and c <= 'F'
                d = c - 'A' + 10
            if d >= base
                break
            v = v * base + d
            digits++
            i++
        }
        return digits > 0, v
    }

    ; A machine whose program file is an image of a fixed size (a cartridge) with the
    ; program at its end: the size, or 0, and the file's extension.  (The keys were
    ; overlay_image_size and overlay_image_ext when only overlays made such a file.)
    sub image_size() -> long {
        long size = number("image_size", 0)
        if size == 0
            size = number("overlay_image_size", 0)
        return size
    }

    sub image_ext() -> ^^ubyte {
        ^^ubyte ext = text("image_ext")
        if ext == 0
            ext = text("overlay_image_ext")
        return ext
    }

    ; the number a key has, or the default when it is missing or not a number
    sub number(str key, long default) -> long {
        ^^ubyte v = text(key)
        if v == 0
            return default
        bool ok
        long n
        ok, n = parse_number(v)
        if ok
            return n
        return default
    }

    ; is the key's value this word (whatever the case of its letters)?
    sub is(str key, str wanted) -> bool {
        ^^ubyte v = text(key)
        if v == 0
            return false
        long i = 0
        while v[i] != 0 and wanted[i] != 0 {
            ubyte a = v[i]
            ubyte b = wanted[i]
            if a >= 'A' and a <= 'Z'
                a += 32
            if b >= 'A' and b <= 'Z'
                b += 32
            if a != b
                return false
            i++
        }
        return v[i] == 0 and wanted[i] == 0
    }

    ; "first-last,address,..." ranges of a key: sets those entries of a table of 256
    sub mark_ranges(str key, ^^bool table, bool value) -> bool {
        ^^ubyte v = text(key)
        if v == 0
            return false
        long i = 0
        bool ok
        long first
        long last
        while v[i] != 0 {
            while is_space(v[i]) or v[i] == ','
                i++
            if v[i] == 0
                break
            ok, first = parse_number(v + i)
            if not ok
                return false
            while v[i] != 0 and v[i] != ',' and v[i] != '-'
                i++
            last = first
            if v[i] == '-' {
                i++
                ok, last = parse_number(v + i)
                if not ok
                    return false
                while v[i] != 0 and v[i] != ','
                    i++
            }
            long a
            for a in first to last {
                if a >= 0 and a <= 255
                    table[a] = value
            }
        }
        return true
    }
}
