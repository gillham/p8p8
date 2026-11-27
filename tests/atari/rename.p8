; diskio.rename of the atari target with a device before the new name: the DOS takes
; the new name without one ("D1:OLD.EXT,NEW.EXT"), so the library leaves it off.  A
; program that names both files in full ("D2:OLD.TMP" to "D2:NEW.TXT") must get the
; file that it asked for, not one named after the device.
; (The files are on the emulator's H: device, as those of tests/atari/files.p8.)
%import textio
%import diskio

main {
    ubyte[16] data

    sub show() {
        txt.print_ub(diskio.status_code())
        txt.spc()
        txt.print_bool(diskio.exists("H:ONE.DAT"))
        txt.print_bool(diskio.exists("H:TWO.DAT"))
        txt.print_bool(diskio.exists("H:THREE.DAT"))
        txt.print_bool(diskio.exists("H:H"))
        txt.nl()
    }

    sub start() {
        txt.print_bool(diskio.save_raw("H:ONE.DAT", data, 16))
        txt.nl()
        ; the new name with its device
        diskio.rename("H:ONE.DAT", "H:TWO.DAT")
        show()
        ; and without, as before
        diskio.rename("H:TWO.DAT", "THREE.DAT")
        show()
        diskio.delete("H:THREE.DAT")
        show()
    }
}
