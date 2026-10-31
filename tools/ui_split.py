# ui_split.py DUMP - the UI pass's draws in order with their screen bounds (frames with the largest heading change), and the split by the first draw of pipeline p807 (ps d12f3abf...): h59 - before it 29 of 49 draws moved with a turn (world widgets), after it 25 of 1008 (screen HUD)
import sys,re,struct,math,collections
F=sys.argv[1]; draws=collections.defaultdict(list); heading={}; rank=collections.defaultdict(dict); passes={}
for l in open(F):
    if l.startswith('CBV2 '):
        w=l.split(); p=int(w[1][1:]); f=int(w[2][1:]); r=rank[f].setdefault(p,len(rank[f]))
        if r==0 and w[3]=='vert' and w[4]=='q0' and w[6]=='24':
            b=bytes.fromhex(w[-1]); v=struct.unpack('<%df'%(len(b)//4),b[:len(b)//4*4]); heading[f]=math.degrees(math.atan2(v[89],v[88]))
    elif l.startswith('UIPASS'):
        w=l.split(); passes[w[1]]=' '.join(w[3:])
    elif l.startswith('UIDRAW'):
        w=l.split(); f=int(w[2][1:]); kv=dict(x.split('=',1) for x in w[4:] if '=' in x); kv['pass']=w[1]
        raw=bytes.fromhex(kv.get('vb6','')); st=int(kv.get('stride6','24'))
        a,b=map(int,kv['vrange'].split('-')); xs=[];ys=[]
        for vi in range(a,min(b,a+64)+1):
            o=vi*st
            if o+8>len(raw): break
            x,y=struct.unpack_from('<2f',raw,o); xs.append(x); ys.append(y)
        kv['bb']=(min(xs),min(ys),max(xs),max(ys)) if xs else None
        draws[f].append(kv)
fs=[f for f in sorted(draws) if f in heading]
best=None
for f0,f1 in zip(fs,fs[1:]):
    dh=(heading[f1]-heading[f0]+180)%360-180
    if best is None or abs(dh)>abs(best[2]): best=(f0,f1,dh)
f0,f1,dh=best; print('frames',f0,f1,'heading change %.1f'%dh)
for f in (f0,f1):
    print('== frame',f)
    for kv in draws[f]:
        bb=kv['bb']; print(kv['pass'], passes.get(kv['pass']), kv['pipe'], 'n=%s'%kv['count'], 'tex' , kv.get('tlab','')[32:48], 'bb', tuple(round(x) for x in bb) if bb else None)
print('==== split by the first p807 draw per UI pass')
stats={'A':[0,0],'B':[0,0]}; nA=collections.Counter()
for f0,f1 in zip(fs,fs[1:]):
    dh=(heading[f1]-heading[f0]+180)%360-180
    def groups(f):
        A=[];B=[];seen=False
        for kv in draws[f]:
            if kv['pipe']=='p807': seen=True
            (B if seen else A).append(kv)
        return A,B
    A0,B0=groups(f0); A1,B1=groups(f1); nA[len(A1)]+=1
    if abs(dh)<3: continue
    # B: match by index
    for k0,k1 in zip(B0,B1):
        if k0['bb'] and k1['bb'] and k0['count']==k1['count']:
            stats['B'][1]+=1
            if abs(k0['bb'][0]-k1['bb'][0])>2: stats['B'][0]+=1
    for k0,k1 in zip(A0,A1):
        if k0['bb'] and k1['bb']:
            stats['A'][1]+=1
            if abs(k0['bb'][0]-k1['bb'][0])>2: stats['A'][0]+=1
print('moving/total while turning >3 deg:', stats, 'draws before the first p807 per frame:', dict(nA))
