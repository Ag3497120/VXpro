# yaw_sign.py DUMP - the game camera heading's sign against the sent yaw (circular agreement, both signs)
import sys,struct,math,collections
F=sys.argv[1]; sent={}; rank=collections.defaultdict(dict); gy={}
for l in open(F):
    if l.startswith('SENT'):
        w=l.split(); sent[int(w[1][1:])]=(float(w[3]),float(w[5]),int(w[7]))
    elif l.startswith('CBV2 '):
        w=l.split(); p=int(w[1][1:]); f=int(w[2][1:]); r=rank[f].setdefault(p,len(rank[f]))
        if r==0 and w[3]=='vert' and w[4]=='q0' and w[6]=='24':
            b=bytes.fromhex(w[-1]); v=struct.unpack('<%df'%(len(b)//4),b[:len(b)//4*4]); gy[f]=math.degrees(math.atan2(v[89],v[88]))
fs=[f for f in sorted(sent) if sent[f][2]==1 and f in gy]
for sg in (1,-1):
    d=[sg*gy[f]-sent[f][0] for f in fs]
    C=sum(math.cos(math.radians(x)) for x in d)/len(d); S=sum(math.sin(math.radians(x)) for x in d)/len(d)
    print('sign',sg,'R %.3f'%math.hypot(C,S), 'n',len(fs))
