; sys.entropy() is in every target's library (tests/entropycheck.sh builds this for each).
%launcher none

main {
    uword seed

    sub start() {
        seed = sys.entropy()
        if seed == sys.entropy()
            seed++
    }
}
