; Arrays of struct instances: field access with a variable index, whole-element copy,
; address of an element, a static initializer, an indexed struct pointer.
; Compared with upstream by make vmcmp and make nativecmp.

%import textio
%zeropage basicsafe

main {
    struct Enemy {
        ubyte xpos, ypos
        uword health
        bool elite
    }

    Enemy[4] enemies
    Enemy[] squad = [
        [10, 20, 100, false],
        [30, 40, 200, true],
        Enemy : [50, 60, 150, false]
    ]

    sub show(^^Enemy e) {
        txt.print_ub(e.xpos)
        txt.spc()
        txt.print_ub(e.ypos)
        txt.spc()
        txt.print_uw(e.health)
        txt.spc()
        txt.print_bool(e.elite)
        txt.nl()
    }

    sub start() {
        ubyte i
        for i in 0 to 3 {
            enemies[i].xpos = i
            enemies[i].ypos = i * 2
            enemies[i].health = 1000 + i
            enemies[i].elite = i == 2
        }
        enemies[1].health += 5
        enemies[0] = enemies[3]
        for i in 0 to 3
            show(&enemies[i])
        for i in 0 to len(squad) - 1
            show(&squad[i])
        uword total = 0
        for i in 0 to 2
            total += squad[i].health
        txt.print_uw(total)
        txt.spc()
        txt.print_ub(squad[2].xpos)
        txt.spc()
        txt.print_uw(sizeof(Enemy))
        txt.spc()
        txt.print_ub(len(enemies))
        txt.nl()
        squad[1] = enemies[2]
        show(&squad[1])
        ^^Enemy p = &squad[0]
        p[2].health++
        show(&squad[2])
    }
}
