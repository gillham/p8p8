; The platform profile of an llvm32 program: which machine and system the LLVM
; IR is for, and how clang makes a program of it.  A profile is a properties
; file in the format of the LLVM branch of Prog8 (its llvm-triples directory):
;
;     -triple armv7-unknown-linux-gnueabihf     <lib>/triples/<name>.properties
;     -triple config/mine.properties            the file itself
;
; Without -triple it is wasm32-wasip1, which is also built in, for a library
; that has no triples directory.
;
; Only the keys that the 32-bit hosted platforms use are known here.  A profile
; with another key is refused: what the key asks for would silently not happen.
; (llvm64 and llvm16 do not read profiles yet: their platforms are in main.p8
; and llvmgen.p8.)

%import buf
%import mem
%import strtab
%import strings
%import io_platform

triple {
    %option ignore_unused

    bool loaded = false
    ^^ubyte error_text = 0          ; why load failed
    ^^ubyte bad_key = 0             ; and the key it is about, or 0

    ^^ubyte name = 0                ; triple: what the LLVM IR says it is for
    ^^ubyte datalayout = 0
    long dirent_name_offset = 9     ; where readdir()'s struct dirent has its d_name
    ^^ubyte readdir_symbol = 0      ; the C routine to call for readdir
    ^^ubyte clang_args = 0
    ^^ubyte link_args = 0           ; after the files on clang's command line, or 0
    ^^ubyte getkey_source = 0       ; the console runtime source, or 0: no raw keys, no terminal size
    ^^ubyte output_extension = 0    ; of the program file; "" for none
    ^^ubyte run_command = 0         ; for -run, with {file}; 0: the program is run as it is
    bool strict_indirect_signatures = false     ; a call through a pointer must name the exact type
    ^^ubyte c_main_symbol = 0

    sub defaults() {
        name = "wasm32-unknown-wasip1"
        datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-i128:128-n32:64-S128-ni:1:10:20"
        dirent_name_offset = 9
        readdir_symbol = "readdir"
        clang_args = "--target=wasm32-wasip1 --sysroot=${WASI_SYSROOT:-/opt/homebrew/opt/wasi-libc/share/wasi-sysroot} -Wl,--fatal-warnings"
        link_args = 0
        getkey_source = 0
        output_extension = ".wasm"
        run_command = "wasmtime --dir=. {file}"
        strict_indirect_signatures = true
        c_main_symbol = "__main_argc_argv"
    }

    sub is_space(ubyte c) -> bool {
        return c == ' ' or c == '\t' or c == '\r'
    }

    sub is_file_name(^^ubyte spec) -> bool {
        long n = 0
        bool slash = false
        while spec[n] != 0 {
            if spec[n] == '/' or spec[n] == '\\'
                slash = true
            n++
        }
        return slash or (n > 11 and strings.compare(spec + n - 11, ".properties") == 0)
    }

    ; Reads the profile that -triple names (0: the default one).  False with
    ; error_text when there is none or it cannot be used.
    sub load(^^ubyte spec, ^^ubyte libdir) -> bool {
        defaults()
        loaded = true
        error_text = 0
        bad_key = 0
        bool builtin = spec == 0 or strings.compare(spec, "wasm32-wasip1") == 0
        if spec == 0
            spec = "wasm32-wasip1"
        ^^buf.Buf pb = buf.new(512)
        if is_file_name(spec)
            buf.add_str(pb, spec)
        else {
            if libdir == 0 {
                if builtin
                    return true
                error_text = "there is no library directory to find the triple profile in"
                return false
            }
            buf.add_str(pb, libdir)
            buf.add_str(pb, "/triples/")
            buf.add_str(pb, spec)
            buf.add_str(pb, ".properties")
        }
        buf.add_byte(pb, 0)
        long size = io_platform.file_size(pb.data)
        if size < 0 {
            if builtin
                return true
            error_text = "no such triple profile"
            bad_key = strtab.intern(pb.data, (pb.len - 1) as uword)
            return false
        }
        ^^ubyte text = mem.alloc(size + 2)
        long got = io_platform.read_file(pb.data, text, size)
        if got < 0 {
            error_text = "the triple profile cannot be read"
            return false
        }
        text[got] = 0
        ; what the file does not say is not taken from the default profile
        name = 0
        datalayout = 0
        clang_args = ""
        output_extension = ""
        run_command = 0
        strict_indirect_signatures = false
        c_main_symbol = "main"
        long i = 0
        while text[i] != 0 {
            while is_space(text[i]) or text[i] == '\n'
                i++
            if text[i] == 0
                break
            if text[i] == '#' or text[i] == ';' {
                while text[i] != 0 and text[i] != '\n'
                    i++
                continue
            }
            long kstart = i
            while text[i] != 0 and text[i] != '\n' and text[i] != '='
                i++
            long kend = i
            while kend > kstart and is_space(text[kend - 1])
                kend--
            long vstart = i
            long vend = i
            if text[i] == '=' {
                i++
                while is_space(text[i])
                    i++
                vstart = i
                while text[i] != 0 and text[i] != '\n'
                    i++
                vend = i
                while vend > vstart and is_space(text[vend - 1])
                    vend--
            }
            ^^ubyte key = strtab.intern(text + kstart, (kend - kstart) as uword)
            ^^ubyte value = strtab.intern(text + vstart, (vend - vstart) as uword)
            if not set(key, value) {
                bad_key = key
                return false
            }
        }
        if name == 0 or datalayout == 0 {
            error_text = "the triple profile needs a triple and a datalayout"
            return false
        }
        return true
    }

    sub set(^^ubyte key, ^^ubyte value) -> bool {
        if strings.compare(key, "triple") == 0
            name = value
        else if strings.compare(key, "datalayout") == 0
            datalayout = value
        else if strings.compare(key, "c_long_size") == 0 {
            if strings.compare(value, "4") != 0 {
                error_text = "llvm32 is for platforms whose C long has 4 bytes"
                return false
            }
        }
        else if strings.compare(key, "dirent_name_offset") == 0 {
            dirent_name_offset = 0
            long k = 0
            while value[k] >= '0' and value[k] <= '9' {
                dirent_name_offset = dirent_name_offset * 10 + (value[k] - '0')
                k++
            }
            if k == 0 or value[k] != 0 {
                error_text = "the triple profile's key needs a number"
                return false
            }
        }
        else if strings.compare(key, "readdir_symbol") == 0
            readdir_symbol = value
        else if strings.compare(key, "clang_args") == 0
            clang_args = value
        else if strings.compare(key, "link_args") == 0
            link_args = value
        else if strings.compare(key, "getkey_source") == 0
            getkey_source = value
        else if strings.compare(key, "output_extension") == 0
            output_extension = value
        else if strings.compare(key, "run_command") == 0
            run_command = value
        else if strings.compare(key, "strict_indirect_signatures") == 0
            strict_indirect_signatures = strings.compare(value, "true") == 0
        else if strings.compare(key, "c_main_symbol") == 0
            c_main_symbol = value
        else {
            error_text = "p8p8 does not know this key of a triple profile yet"
            return false
        }
        return true
    }
}
