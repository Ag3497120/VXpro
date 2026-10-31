# cbv_show.py DUMP - per dumped frame: the sent yaw / pitch and the view matrix found by cbv_find.py (q0@24, floats 80-95)
import sys,re,struct,math,collections
F=sys.argv[1]; sent={}; rank=collections.defaultdict(dict); rows=[]
for l in open(F):
    if l.startswith('SENT'):
        w=l.split(); sent[int(w[1][1:])]=(float(w[3]),float(w[5]),int(w[7]))
    elif l.startswith('CBV2 '):
        w=l.split(); p=int(w[1][1:]); f=int(w[2][1:]); r=rank[f].setdefault(p,len(rank[f]))
        if r==0 and w[3]=='vert' and w[4]=='q0' and w[6]=='24':
            b=bytes.fromhex(w[-1]); v=struct.unpack('<%df'%(len(b)//4),b[:len(b)//4*4])
            rows.append((f,v))
for f,v in rows:
    s=sent.get(f,(0,0,0))
    m=v[80:96]; 
    a=(m[2],m[6],m[10]); yaw=math.degrees(math.atan2(a[1],a[0])); pit=math.degrees(math.asin(max(-1,min(1,a[2]))))
    print(f, 'sent %7.2f %7.2f d%d'%s, 'cam yaw %7.2f pitch %7.2f'%(-yaw,pit), ' '.join('%.3f'%x for x in m))
print('floats 64-128 of last:', ' '.join('%.3f'%x for x in rows[-1][1][64:128]))
