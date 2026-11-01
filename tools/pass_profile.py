#!/usr/bin/env python3
# pass_profile.py FILE [--all] [--top N] [--dump PIPES.txt] [--scene WxH]
# Reads libvxmtl's per-pass GPU profile (VXMAC_PASS_PROFILE=1 -> Documents/pass_profile.txt, shims/vxprof.m) and
# answers: where does the game's GPU time go, and how much of it scales with the screen (what game-side foveation /
# a lower render resolution could save at most) against what does not (shadow maps, probes, small targets, fixed-size
# compute).
#   - frames: overlap windows (as the game runs: stages share the GPU, each slice split among the stages running) and
#     serial windows (each of the game's passes alone within its command buffer: its own cost); lead frames (a window's
#     first) left out; --all keeps frames while not in head-look (driving=0) too (default: driving=1 when any are).
#   - groups: kind + attachments + pipelines (render passes with more than 3 pipelines by their count), heaviest first,
#     ms per frame in each mode and how many a frame.
#   - screen share: render passes at the scene's size (the most common largest colour target with depth, or --scene),
#     at half / quarter of it, square shadow-like targets, small ones; compute by threads per frame against the scene's
#     pixels (>= 0.2 of them: screen-sized). The time in each class, both modes.
#   --dump: a VXMAC_PIPE_DUMP file of the same build: pipelines' p-numbers and labels for the hashes.
import collections, re, sys

def parse_kv(s):
    d = {}
    for m in re.finditer(r'(\w+)=(\S+)', s): d[m.group(1)] = m.group(2)
    return d

def sig(e):
    pipes = [] if e['pipes'] == '-' else e['pipes'].split(',')
    n = int(e['npipes'])
    if e['k'] in 'RP':
        p = ' '.join(pipes) if n <= 3 else 'pipes<=%d' % (1 << max(2, (n - 1).bit_length()))
    else:
        p = ' '.join(pipes) + (' +more' if e['more'] else '')
    return ('ours ' if e['ours'] else '') + e['k'] + ' ' + e['att'] + ' | ' + p

def main():
    a = sys.argv[1:]
    if not a: sys.exit(__doc__ if __doc__ else 'usage: pass_profile.py FILE [--all] [--top N] [--dump PIPES] [--scene WxH]')
    path = a[0]; keep_all = '--all' in a
    top = int(a[a.index('--top') + 1]) if '--top' in a else 30
    scene = tuple(map(int, a[a.index('--scene') + 1].split('x'))) if '--scene' in a else None
    names = {}
    if '--dump' in a:
        for l in open(a[a.index('--dump') + 1], errors='ignore'):
            if l.startswith(('RPIPE', 'CPIPE')):
                pid = l.split()[1]
                lab = re.search(r'label=(\S+)', l)
                for m in re.finditer(r' ([vfk])=\w+#([0-9a-f]{16})', l):
                    names.setdefault(m.group(1) + m.group(2), set()).add(pid + ('' if not lab or lab.group(1) == '-' else '[' + lab.group(1) + ']'))
    frames, encs = {}, collections.defaultdict(list)
    for l in open(path, errors='ignore'):
        if l.startswith('PFRAME '):
            fid = l.split()[1]; d = parse_kv(l); d['id'] = fid; frames[fid] = d
        elif l.startswith('PENC '):
            p = l.split()
            fid = p[1]; d = parse_kv(l)
            m = re.search(r'pipes=(\d+):(\S+)', l)
            e = {'k': d['k'], 'ours': ' ours=1 ' in l, 'att': d.get('att', '-'), 'share': float(d['share_ms']), 'span': float(d['span_ms']),
                 'vtx': float(d['vtx_ms']), 'frag': float(d['frag_ms']), 'mthreads': float(d['mthreads']), 'disp': int(d['disp']),
                 'npipes': int(m.group(1)) if m else 0, 'pipes': (m.group(2).rstrip(',.') if m else '-'), 'more': l.rstrip().endswith(',...'),
                 'label': d.get('label', '-')}
            encs[fid].append(e)
    if not frames: sys.exit('no PFRAME lines in ' + path)
    driving = [f for f in frames.values() if f.get('driving') == '1']
    use = [f for f in frames.values() if f.get('lead') != '1' and (keep_all or not driving or f.get('driving') == '1')]
    if not use: sys.exit('no frames left (all lead frames?)')
    modes = sorted(set(f['mode'] for f in use))
    # the scene's size: the most common largest colour target among render passes with depth
    if not scene:
        c = collections.Counter()
        for f in use:
            for e in encs[f['id']]:
                if e['k'] in 'RP' and not e['ours'] and 'd:' in e['att']:
                    sz = [tuple(map(int, m.groups())) for m in re.finditer(r'c\d:(\d+)x(\d+)', e['att'])]
                    if sz: c[max(sz, key=lambda s: s[0] * s[1])] += 1
        scene = c.most_common(1)[0][0] if c else (1600, 900)
    spx = scene[0] * scene[1]
    print('file %s: %d frames used (%s), scene %dx%d%s' % (path, len(use), ', '.join('%s %d' % (m, sum(f['mode'] == m for f in use)) for m in modes),
          scene[0], scene[1], '' if keep_all or not driving else ', head-look frames only'))
    for m in modes:
        fs = [f for f in use if f['mode'] == m]; n = len(fs)
        g = lambda k: sum(float(f.get(k, 0)) for f in fs) / n
        print('  %-7s GPU busy %.1f ms/frame: game %.1f (render %.1f, compute %.1f, blit %.1f, accel %.1f), ours %.1f; command buffers %.1f; encoders %.0f' %
              (m, g('busy_ms'), g('game_ms'), g('render_ms'), g('compute_ms'), g('blit_ms'), g('accel_ms'), g('ours_ms'), g('cb_busy_ms'), g('encoders')))
    # classes: what scales with the screen
    def klass(e):
        if e['ours']: return 'ours'
        if e['k'] in 'RP':
            sz = [tuple(map(int, mm.groups())) for mm in re.finditer(r'[cd]\d?:(\d+)x(\d+)', e['att'])]
            if not sz: return 'render other'
            w, h = max(sz, key=lambda s: s[0] * s[1]); px = w * h
            if w == h and w >= 256 and (w, h) != scene: return 'render square (shadow/probe)'
            if px >= 0.7 * spx: return 'render scene size'
            if px >= 0.18 * spx: return 'render half size'
            if px >= 0.04 * spx: return 'render quarter size'
            return 'render small'
        if e['k'] == 'C':
            t = e['mthreads'] * 1e6
            if t >= 0.2 * spx: return 'compute screen-sized (threads >= 0.2 scene px)'
            if e['disp'] and t == 0: return 'compute indirect only'
            return 'compute small'
        return {'B': 'blit', 'A': 'accel'}.get(e['k'], 'other')
    print('\nwhere the time goes (ms per frame; overlap = shares as the game runs, serial = each pass alone):')
    cls = collections.defaultdict(lambda: collections.defaultdict(float))
    for f in use:
        for e in encs[f['id']]: cls[klass(e)][f['mode']] += e['share']
    nby = {m: sum(f['mode'] == m for f in use) for m in modes}
    for k in sorted(cls, key=lambda k: -max(cls[k][m] / nby[m] for m in modes)):
        print('  %-48s %s' % (k, '  '.join('%s %6.2f' % (m, cls[k][m] / nby[m]) for m in modes)))
    for m in modes:
        tot = sum(cls[k][m] for k in cls if k != 'ours') / nby[m]
        scr = sum(cls[k][m] for k in cls if k in ('render scene size', 'render half size', 'compute screen-sized (threads >= 0.2 scene px)')) / nby[m]
        print('  %s: screen-proportional %.1f of the game\'s %.1f ms (%.0f %%) - the most a lower or foveated render resolution can save' % (m, scr, tot, 100 * scr / tot if tot else 0))
    # groups
    grp = collections.defaultdict(lambda: {'n': 0, 'mt': 0.0, **{m: 0.0 for m in modes}, **{m + 'f': 0.0 for m in modes}})
    for f in use:
        for e in encs[f['id']]:
            g = grp[sig(e)]; g[f['mode']] += e['share']; g[f['mode'] + 'f'] += e['frag']; g['n'] += 1; g['mt'] += e['mthreads']
    nf = len(use)
    print('\nheaviest groups (ms per frame):')
    key = lambda kv: -max(kv[1][m] / nby[m] for m in modes)
    for i, (k, g) in enumerate(sorted(grp.items(), key=key)[:top]):
        cols = '  '.join('%s %6.2f' % (m[:3], g[m] / nby[m]) for m in modes)
        nm = ''
        if names:
            hs = re.findall(r'([vfk][0-9a-f]{16})', k)
            nm = '  [' + ' '.join(','.join(sorted(names.get(h, {'?'}))) for h in hs[:4]) + ']' if hs else ''
        print('  %2d %s  x%.1f  %s%s%s' % (i + 1, cols, g['n'] / nf, k[:150], ('  Mthreads %.2f' % (g['mt'] / g['n'])) if g['mt'] else '', nm))

if __name__ == '__main__':
    main()
