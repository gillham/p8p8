#!/usr/bin/env python3
"""Run an Apple II binary in bobbin (tty interface, in a pty), type keys, and show
the text screen from a RAM dump.  usage: a2screen.py prog.bin seconds [keys [seconds]]..."""
import os, pty, sys, time, select, tempfile
prog = sys.argv[1]
steps = sys.argv[2:]
dump = tempfile.mktemp(suffix='.ram')
pid, fd = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm'
    os.execvp('bobbin', ['bobbin', '--delay-until', 'INPUT', '--load', prog, '--load-at', '1ffc', '--jump-to', '2000'])
def drain(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: os.read(fd, 65536)
            except OSError: return
def show():
    if os.path.exists(dump): os.remove(dump)
    os.write(fd, b'\x03'); time.sleep(0.2); os.write(fd, b'\x03'); drain(0.5)
    os.write(fd, ('save-ram %s\r' % dump).encode()); drain(1.0)
    ram = open(dump, 'rb').read()
    base = [0x400,0x480,0x500,0x580,0x600,0x680,0x700,0x780,0x428,0x4a8,0x528,0x5a8,0x628,0x6a8,0x728,0x7a8,0x450,0x4d0,0x550,0x5d0,0x650,0x6d0,0x750,0x7d0]
    print('+' + '-'*40 + '+')
    for b in base:
        line = ''
        for c in ram[b:b+40]:
            if c >= 0xa0: ch = chr(c & 0x7f)            # normal
            elif c >= 0x80: ch = chr((c & 0x1f) + 0x40) # normal upper (control range)
            elif c >= 0x60: ch = '~'                    # flashing / alt lower
            elif c >= 0x40: ch = '^'                    # flashing / mousetext
            elif c >= 0x20: ch = chr(c)                 # inverse symbols (shown plain)
            else: ch = chr(c + 0x40).lower()            # inverse upper shown as lower
            line += ch if 32 <= ord(ch) < 127 else '?'
        print('|' + line + '|')
    print('+' + '-'*40 + '+')
    sys.stdout.flush()
i = 0
drain(float(steps[0])); show()
i = 1
while i < len(steps):
    os.write(fd, steps[i].encode().decode('unicode_escape').encode('latin1'))
    drain(float(steps[i+1]) if i+1 < len(steps) else 2); show()
    i += 2
os.write(fd, b'\x03'); time.sleep(0.2); os.write(fd, b'\x03'); time.sleep(0.3); os.write(fd, b'q\r')
time.sleep(0.5)
try: os.kill(pid, 9)
except OSError: pass
