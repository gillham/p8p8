%import textio
%zeropage basicsafe
main {
    sub dump(str s) {
        ubyte k = 0
        while s[k] != 0 {
            txt.print_ubhex(s[k], false)
            k++
        }
        txt.spc()
    }
    sub start() {
        dump("hello")
        dump(petscii:"hello")
        dump(sc:"my name is Alice")
        dump(iso:"Ich heiße François")
        dump(iso5:"Хозяин и Работник")
        dump(iso16:"zażółć gęślą jaźń")
        dump(atascii:"I am Atari!")
        dump(cp437:"≈ IBM Pc ≈ ♂♀♪☺¶")
        dump(kata:"ｱﾉ ﾆﾎﾝｼﾞﾝ ﾜ ｶﾞｲｺｸｼﾞﾝ｡ # が # ガ")
        dump(c64os:"^Hello_World! \\ ~{_}~")
        txt.print_ubhex(iso:'ß', false)
        txt.print_ubhex(sc:'a', false)
        txt.print_ubhex(cp437:'☺', false)
        txt.nl()
    }
}
