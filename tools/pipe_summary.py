# pipe_summary.py DUMP [tex...] - from a VXMAC_PIPE_DUMP file: the targets each vertex shader (by hash) writes, and who reads the named textures
import sys,re,collections
F=sys.argv[1]
pipes={};texs={}
w2t=collections.defaultdict(collections.Counter)   # vs hash -> target desc
readers=collections.defaultdict(collections.Counter) # tex -> reader pipes
for l in open(F):
    w=l.split()
    if not w: continue
    if w[0] in('RPIPE','CPIPE'): pipes[w[1]]=l.strip()
    elif w[0]=='TEX':
        m=re.match(r'TEX (t\d+) (\S+) type (\d+) fmt (\d+) mips (\d+)',l); texs[m.group(1)]=f'{m.group(2)} fmt{m.group(4)} mips{m.group(5)}'+(' VIEW' if 'view-of' in l else '')+(' DRAWABLE' if 'iosurface' in l else '')
    elif w[0] in('RPASS','CPASS'):
        head,pp,rd=l.split('|')
        ps=re.findall(r'p\d+',pp); 
        tg=re.findall(r'(c\d)=(t\d+)',head)
        for p in set(ps):
            d=pipes.get(p,'')
            vs=re.search(r'v=(\S+)',d); key=(vs.group(1) if vs else re.search(r'k=(\S+)',d).group(1) if 'k=' in d else p)
            for c,t in tg: w2t[key][texs.get(t,t)]+=1
        for t in re.findall(r't\d+',rd):
            for p in set(ps):
                d=pipes.get(p,''); vs=re.search(r'(?:v|k)=(\S+)',d)
                readers[t][(vs.group(1) if vs else p)[:30]]+=1
for k,c in sorted(w2t.items(),key=lambda x:-sum(x[1].values())):
    if k.startswith('cs_'): continue
    print(k, dict(c.most_common(4)))
print('---readers of', sys.argv[2:])
for t in sys.argv[2:]: print(t, texs.get(t), dict(readers[t].most_common(6)))
