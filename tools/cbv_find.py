# cbv_find.py DUMP - from a VXMAC_PIPE_DUMP file with TLAB/CBV/CBV2 lines (h51+): every rotation 3x3 in the scene passes' constants, its yaw / pitch readings scored against the SENT yaw / pitch (h51: the view matrix at bytes 320-383 of the CB at the vertex TLAB q0 descriptor table byte 24)
import sys,re,struct,math,collections
F=sys.argv[1]
sent={}; data=collections.defaultdict(dict)   # key -> frame -> floats
rank=collections.defaultdict(dict)
for l in open(F):
    if l.startswith('SENT'):
        w=l.split(); sent[int(w[1][1:])]=(float(w[3]),float(w[5]),int(w[7]),int(w[9]))
    elif l.startswith('CBV2 '):
        w=l.split(); p=int(w[1][1:]); f=int(w[2][1:]); st=w[3]; q=w[4]+'@'+w[6]
        r=rank[f].setdefault(p,len(rank[f]))
        b=bytes.fromhex(w[-1]); n=len(b)//4
        data[(r,st,q)][f]=struct.unpack('<%df'%n,b[:n*4])
    elif l.startswith('CBV '):
        w=l.split(); p=int(w[1][1:]); f=int(w[2][1:]); st=w[3]; q=w[4]
        r=rank[f].setdefault(p,len(rank[f]))
        b=bytes.fromhex(w[-1]); n=len(b)//4
        data[(r,st,q)][f]=struct.unpack('<%df'%n,b[:n*4])
fr=[f for f in sorted(sent) if sent[f][2]==1]
print('driving frames',len(fr))
res=[]
for key,d in data.items():
    fs=[f for f in fr if f in d]
    if len(fs)<20: continue
    n=min(len(d[f]) for f in fs)
    for o in range(0,n-11):
        # 3 rows of 3 at stride 4 (row-major float4x4 / float3x4)
        ok=True; mats=[]
        for f in fs:
            v=d[f]; m=[v[o:o+3],v[o+4:o+7],v[o+8:o+11]]
            if any(not all(map(math.isfinite,r)) for r in m): ok=False;break
            if any(abs(sum(x*x for x in r)-1)>0.02 for r in m): ok=False;break
            if abs(sum(a*b for a,b in zip(m[0],m[1])))>0.02 or abs(sum(a*b for a,b in zip(m[0],m[2])))>0.02: ok=False;break
            mats.append(m)
        if not ok: continue
        # variance check: it must change
        for ax in range(6):
            for up in (1,2):
                ys=[];ps=[]
                for m in mats:
                    a=m[ax] if ax<3 else [m[0][ax-3],m[1][ax-3],m[2][ax-3]]
                    h=[i for i in range(3) if i!=up]
                    ys.append(math.degrees(math.atan2(a[h[1]],a[h[0]]))); ps.append(math.degrees(math.asin(max(-1,min(1,a[up])))))
                sy=[sent[f][0] for f in fs]; sp=[sent[f][1] for f in fs]
                def corr(x,y):
                    mx=sum(x)/len(x); my=sum(y)/len(y)
                    sxy=sum((a-mx)*(b-my) for a,b in zip(x,y)); sxx=sum((a-mx)**2 for a in x); syy=sum((b-my)**2 for b in y)
                    return sxy/math.sqrt(sxx*syy) if sxx>1e-9 and syy>1e-9 else 0, (sxy/sxx if sxx>1e-9 else 0)
                # yaw wraps: unwrap relative to sent
                yu=[]
                for y,s in zip(ys,sy):
                    yu.append(y)
                cy,_=corr(ys,sy); cp,sc=corr(ps,sp)
                # try sign-flipped/offset yaw via circular: correlate cos/sin of difference
                best=0
                for sg in (1,-1):
                    dd=[(sg*y - s) for y,s in zip(ys,sy)]
                    C=sum(math.cos(math.radians(x)) for x in dd)/len(dd); S=sum(math.sin(math.radians(x)) for x in dd)/len(dd)
                    R=math.hypot(C,S)
                    if R>best: best=R; bsg=sg
                res.append((best+abs(cp),best,bsg,cp,sc,key,o,ax,up,len(fs)))
res.sort(reverse=True)
for r in res[:25]: print('score %.3f yawR %.3f sign %d pitchCorr %.3f pitchScale %.2f key %s off %d (bytes %d) axis %d up %d n %d'%(r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[6]*4,r[7],r[8],r[9]))
