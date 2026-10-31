# proj_tan.py DUMP - the game's FOV per dumped frame from its projection (the view constants' floats 32 and 37: 1/tan of the half-angles)
import sys,struct,math,collections
F=sys.argv[1]; rank=collections.defaultdict(dict); out=[]
for l in open(F):
    if l.startswith('CBV2 '):
        w=l.split(); p=int(w[1][1:]); f=int(w[2][1:]); r=rank[f].setdefault(p,len(rank[f]))
        if r==0 and w[3]=='vert' and w[4]=='q0' and w[6]=='24':
            b=bytes.fromhex(w[-1]); v=struct.unpack('<%df'%(len(b)//4),b[:len(b)//4*4])
            tx,ty=1/v[32],1/v[37]; out.append('%d:%.1f/%.1f'%(f, 2*math.degrees(math.atan(tx)), 2*math.degrees(math.atan(ty))))
print(' '.join(out))
