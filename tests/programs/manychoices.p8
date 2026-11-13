; A when statement with many choices (p8p8 once kept the labels of only the first 64).
; Compared with upstream by make vmcmp, make nativecmp and the emulator suites.

%import textio
main {
    sub pick(ubyte v) -> ubyte {
        when v {
            0 -> return 3
            1 -> return 10
            2 -> return 17
            3 -> return 24
            4 -> return 31
            5 -> return 38
            6 -> return 45
            7 -> return 52
            8 -> return 59
            9 -> return 66
            10 -> return 73
            11 -> return 80
            12 -> return 87
            13 -> return 94
            14 -> return 101
            15 -> return 108
            16 -> return 115
            17 -> return 122
            18 -> return 129
            19 -> return 136
            20 -> return 143
            21 -> return 150
            22 -> return 157
            23 -> return 164
            24 -> return 171
            25 -> return 178
            26 -> return 185
            27 -> return 192
            28 -> return 199
            29 -> return 206
            30 -> return 213
            31 -> return 220
            32 -> return 227
            33 -> return 234
            34 -> return 241
            35 -> return 248
            36 -> return 4
            37 -> return 11
            38 -> return 18
            39 -> return 25
            40 -> return 32
            41 -> return 39
            42 -> return 46
            43 -> return 53
            44 -> return 60
            45 -> return 67
            46 -> return 74
            47 -> return 81
            48 -> return 88
            49 -> return 95
            50 -> return 102
            51 -> return 109
            52 -> return 116
            53 -> return 123
            54 -> return 130
            55 -> return 137
            56 -> return 144
            57 -> return 151
            58 -> return 158
            59 -> return 165
            60 -> return 172
            61 -> return 179
            62 -> return 186
            63 -> return 193
            64 -> return 200
            65 -> return 207
            66 -> return 214
            67 -> return 221
            68 -> return 228
            69 -> return 235
            70 -> return 242
            71 -> return 249
            72 -> return 5
            73 -> return 12
            74 -> return 19
            75 -> return 26
            76 -> return 33
            77 -> return 40
            78 -> return 47
            79 -> return 54
            80 -> return 61
            81 -> return 68
            82 -> return 75
            83 -> return 82
            84 -> return 89
            85 -> return 96
            86 -> return 103
            87 -> return 110
            88 -> return 117
            89 -> return 124
            90 -> return 131
            91 -> return 138
            92 -> return 145
            93 -> return 152
            94 -> return 159
            95 -> return 166
            96 -> return 173
            97 -> return 180
            98 -> return 187
            99 -> return 194
            else -> return 255
        }
    }

    sub start() {
        ubyte k
        uword total = 0
        for k in 0 to 110
            total += pick(k)
        txt.print_uw(total)
        txt.chrout(' ')
        txt.print_ub(pick(63))
        txt.chrout(' ')
        txt.print_ub(pick(64))
        txt.chrout(' ')
        txt.print_ub(pick(99))
        txt.chrout(' ')
        txt.print_ub(pick(100))
        txt.nl()
    }
}
