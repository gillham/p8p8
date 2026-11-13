#!/usr/bin/env python3
"""Finds error checks that p8p8 lacks: runs small invalid programs through upstream
(prog8c-llvm -check) and through p8p8, and reports where one rejects and the other
does not.  The cases are (name, target, source) tuples in tests/checkprobe_cases.py; a
source without a main block is wrapped in one.

When upstream's -check accepts a case it is compiled in full as well, since -check
stops before constant folding.  Upstream's optimizer removes unused variables before
their values are checked, so a case should use what it declares.

Usage (from the repository root): python3 tools/checkprobe.py [scratch dir]
"""
import subprocess,re,sys,os
S=sys.argv[1] if len(sys.argv)>1 else '/tmp/p8p8_checkprobe'
os.makedirs(S,exist_ok=True)
L=os.environ.get('P8P8_LIB','lib')
cases=eval(open('tests/checkprobe_cases.py').read())
def strip(t): return re.sub(r'\x1b\[[0-9;]*m','',t)
for name,target,body in cases:
    src=body if body.lstrip().startswith('%') or 'main {' in body else '%import textio\nmain {\n'+body+'\n}\n'
    f=f'{S}/{name}.p8'; open(f,'w').write(src)
    u=(subprocess.run(['prog8c-llvm','-target',target,'-check',f],capture_output=True,text=True));u=u if isinstance(u,str) else strip(u.stdout+u.stderr)
    um=[re.sub(r'.*\.p8:(\d+):\d+: ','\\1: ',l) for l in u.split('\n') if 'ERROR' in l]
    if not um:
        # -check stops early: a full compile finds more (unless the optimizer removed the code first)
        u=subprocess.run(['prog8c-llvm','-target',target,'-quiet','-out',S,f],capture_output=True,text=True)
        u=strip(u.stdout+u.stderr)
    um=[re.sub(r'.*\.p8:(\d+):\d+: ','\\1: ',l) for l in u.split('\n') if 'ERROR' in l]
    p=subprocess.run(['build/llvm64/p8p8','-target',target,'-lib',L,'-ir','-out',S,f],capture_output=True,text=True)
    pm=[re.sub(r'.*\.p8:(\d+):\d+: error: ','\\1: ',l) for l in (p.stdout+p.stderr).split('\n') if 'error' in l]
    same = bool(um)==bool(pm)
    print(('ok   ' if same else 'GAP  ')+name+' ['+target+']')
    print('     up:  '+(um[0][:110] if um else '(accepted)'))
    print('     p8:  '+(pm[0][:110] if pm else '(accepted)'))
