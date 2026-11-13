; What the compiler is doing right now, for the message it prints when it crashes:
; the stage, and the file or subroutine it is working on when a stage says so.

crumb {
    %option ignore_unused

    ^^ubyte stage = 0
    ^^ubyte name = 0

    ; a new stage begins
    sub at(str what) {
        stage = what
        name = 0
    }
}
