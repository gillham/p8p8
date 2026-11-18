%import textio
%address $2000
%output library
%launcher none

; a library: it begins with a jump to main.start, and main's jump table comes
; right after it, where whoever loads the library expects it
main {
    %jmptable ( main.one, main.two )
    sub start() {
    }
    sub one() {
        txt.print("1")
    }
    sub two() {
        txt.print("2")
    }
}
