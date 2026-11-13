; must be rejected: name errors
main {
    sub start() {
        ubyte x
        x = nothere             ; undefined symbol
        other.hidden()          ; private symbol
        txt.print("x")          ; module not imported
    }
}
other {
    private sub hidden() {
    }
}
