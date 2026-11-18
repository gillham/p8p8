%import textio

main {
    const ubyte LIMIT = 12
    %assert LIMIT == 12
    %assert LIMIT > 20, "the limit is too low"
    sub start() {
        %assert LIMIT == 13
        txt.print_ub(LIMIT)
    }
}
