# pipe_frame.py DUMP FRAME - one dumped frame: its passes in order and the pipelines they used
import sys,re
F,frame=sys.argv[1],sys.argv[2]
pipes={};texs={}
passes=[]
for l in open(F):
    w=l.split()
    if not w: continue
    if w[0] in('RPIPE','CPIPE'): pipes[w[1]]=l.strip()
    elif w[0]=='TEX': texs[w[1]]=l.strip()
    elif w[0] in('RPASS','CPASS') and w[2]=='f'+frame: passes.append(l.strip())
passes.sort(key=lambda s:int(s.split()[1][1:]))
used=set()
for p in passes:
    print(p[:400])
    for m in re.findall(r'\bp\d+',p.split('| pipes')[1].split('|')[0]): used.add(m)
print('--- pipes')
for u in sorted(used,key=lambda s:int(s[1:])): print(pipes.get(u,u)[:300])
