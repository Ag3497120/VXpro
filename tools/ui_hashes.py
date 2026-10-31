#!/usr/bin/env python3
# ui_hashes.py DUMP - the UI vertex shaders of a build, from a VXMAC_PIPE_DUMP file: the vertex-shader hashes of the
# pipelines that draw (premultiplied blend One / OneMinusSrcAlpha) into frame-sized colour targets with a mip chain and
# no depth - the UI layers (2.3.2: 9659c847a5663c68, dd2ffa0fee62e619). Prints VXMAC_UI_VS=... for the launch.
import re, sys, collections
F = sys.argv[1]; pipes = {}; texs = {}; drawable = None; cnt = collections.Counter(); layers = collections.Counter()
for l in open(F):
    w = l.split()
    if not w: continue
    if w[0] == 'RPIPE':
        m = re.search(r'v=\S+#(\w+)', l); pipes[w[1]] = (m.group(1) if m else '', '/blend(1,5,1,5' in l)
    elif w[0] == 'TEX':
        m = re.match(r'TEX (t\d+) (\d+)x(\d+)x\d+ type \d+ fmt (\d+) mips (\d+)', l)
        texs[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))
        if 'CAMetalLayer' in l: drawable = texs[m.group(1)][:2]
    elif w[0] == 'RPASS' and drawable:
        head, pp = l.split('|')[:2]
        if ' d=' in head: continue
        m = re.search(r'c0=(t\d+)/', head)
        if not m or m.group(1) not in texs: continue
        tw, th, fmt, mips = texs[m.group(1)]
        if (tw, th) != drawable or mips < 2: continue
        for p in set(re.findall(r'p\d+', pp)):
            h, blend = pipes.get(p, ('', False))
            if h and blend: cnt[h] += 1
        layers[(fmt, mips)] += 1
print('drawable', drawable, 'UI layers (format, mips):', dict(layers))
for h, n in cnt.most_common(): print(h, n)
print('VXMAC_UI_VS=' + ','.join(h for h, n in cnt.most_common() if n * 10 >= cnt.most_common(1)[0][1]))
