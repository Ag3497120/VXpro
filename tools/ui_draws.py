#!/usr/bin/env python3
# ui_draws.py DUMP - world-anchored UI widgets against screen HUD, from a dump with UIDRAW lines (h58). Per draw: its
# vertices' screen bounds (float2 positions at the pipeline's first attribute, stride from RPIPE vl<i>), per frame;
# draws matched across frames by (pipeline, draw order within the pipeline); each one's bounds' motion against the
# camera's heading change (the view matrix from the CBV2 dump, q0@24 floats 80-95). Screen HUD: bounds fixed while the
# camera turns; world widgets: bounds move ~ the turn's projected shift. Prints per pipeline / VS hash the share of
# moving draws, so a static split (shader) can be seen when there is one.
import sys, re, struct, math, collections
F = sys.argv[1]
pipes = {}; vs = {}; heading = {}; draws = collections.defaultdict(list); rank = collections.defaultdict(dict)
for l in open(F):
    if l.startswith('RPIPE '):
        w = l.split(); pid = w[1]
        st = re.search(r' vl(\d+)=(\d+)', l); at = re.search(r' va\d+=f(\d+)@(\d+)/b(\d+)', l)
        pipes[pid] = (int(st.group(2)) if st else 0, (int(at.group(1)), int(at.group(2)), int(at.group(3))) if at else None)
        m = re.search(r'v=\S+#(\w+)', l); vs[pid] = m.group(1) if m else '?'
    elif l.startswith('CBV2 '):
        w = l.split(); p = int(w[1][1:]); f = int(w[2][1:]); r = rank[f].setdefault(p, len(rank[f]))
        if r == 0 and w[3] == 'vert' and w[4] == 'q0' and w[6] == '24':
            b = bytes.fromhex(w[-1]); v = struct.unpack('<%df' % (len(b) // 4), b[:len(b) // 4 * 4])
            heading[f] = math.degrees(math.atan2(v[89], v[88]))
    elif l.startswith('UIDRAW '):
        w = l.split(); f = int(w[2][1:]); kv = dict(x.split('=', 1) for x in w[4:] if '=' in x)
        draws[f].append(kv)
def bounds(kv):
    stride, at = pipes.get(kv['pipe'], (0, None))
    vbs = {int(k[2:]): v for k, v in kv.items() if k.startswith('vb') and k[2:].isdigit() and v != 'private'}
    if not vbs: return None
    bi = at[2] if at and at[2] in vbs else min(vbs)
    raw = bytes.fromhex(vbs[bi]); off = at[1] if at else 0
    if 'stride%d' % bi in kv: stride = int(kv['stride%d' % bi])
    if not stride or stride > 4096: stride = 16
    a, b = map(int, kv.get('vrange', '0-0').split('-'))
    xs, ys = [], []
    for vi in range(a, min(b, a + 64) + 1):
        o = vi * stride + off
        if o + 8 > len(raw): break
        x, y = struct.unpack_from('<2f', raw, o)
        if math.isfinite(x) and math.isfinite(y) and abs(x) < 1e5 and abs(y) < 1e5: xs.append(x); ys.append(y)
    return (min(xs), min(ys), max(xs), max(ys)) if xs else None
frames = sorted(draws)
track = collections.defaultdict(dict)   # key (pipe, n-th draw of that pipe) -> frame -> bounds
for f in frames:
    seen = collections.Counter()
    for kv in draws[f]:
        k = (kv['pipe'], seen[kv['pipe']]); seen[kv['pipe']] += 1
        b = bounds(kv)
        if b: track[k][f] = b
per = collections.defaultdict(lambda: [0, 0])
for k, fb in track.items():
    fs = [f for f in sorted(fb) if f in heading]
    for f0, f1 in zip(fs, fs[1:]):
        dh = (heading[f1] - heading[f0] + 180) % 360 - 180
        if abs(dh) < 2: continue
        dx = (fb[f1][0] + fb[f1][2]) / 2 - (fb[f0][0] + fb[f0][2]) / 2
        per[k][1] += 1
        if abs(dx) > 0.01 * max(1, abs(fb[f0][2] - fb[f0][0])) + 1e-3: per[k][0] += 1
byvs = collections.defaultdict(lambda: [0, 0])
for k, (mv, n) in per.items():
    print('%-8s %-18s draw#%-3d moving %d of %d turning pairs' % (k[0], vs.get(k[0], '?'), k[1], mv, n))
    byvs[vs.get(k[0], '?')][0] += mv; byvs[vs.get(k[0], '?')][1] += n
print('--- by vertex shader'); [print(h, v) for h, v in byvs.items()]
