#!/usr/bin/env python3
# vrik_joints.py: V's first-person skeleton from the VRIK3 lines of vxmac_program.log (shims/vxpipe.m's bone dump).
# Each skinned foreground mesh's bones are 3x4 skinning matrices S_i = [R_i | t_i] (bind space -> the mesh's object space).
# Two bones that meet at a joint move its bind-space point j alike in every pose: S_a j = S_b j, i.e.
#   (R_a - R_b) j = t_b - t_a.
# Over many poses this is solved for j by least squares; a small residual means a and b are joined there. The joints
# give the skeleton (parent / child chains, bind positions), from which the arms' shoulder / elbow / wrist bones are told.
#   vrik_joints.py LOG [--key SUBSTR] [--maxres 0.004]
import sys, argparse, collections
import numpy as np

def load_bin(path):
    import struct
    meshes = collections.defaultdict(list); d = open(path, 'rb').read(); i = 0
    while i + 132 <= len(d):
        magic, fr = struct.unpack_from('<II', d, i)
        if magic != 0x334b5256: break
        kh, nb = struct.unpack_from('<QI', d, i + 8)
        itf = np.frombuffer(d, '<f4', 12, i + 20); view = np.frombuffer(d, '<f4', 16, i + 68)
        bones = np.frombuffer(d, '<f4', nb * 12, i + 132).reshape(nb, 3, 4)
        meshes['%016x' % kh].append((fr, nb, itf, bones)); i += 132 + nb * 48
    return meshes

def load(path, keysub):
    if path.endswith('.bin'): return load_bin(path)
    meshes = collections.defaultdict(list)
    for line in open(path, errors='replace'):
        i = line.find('VRIK3 ')
        if i < 0: continue
        w = line[i:].split()
        key = w[3]; nb = int(w[5])
        if keysub and keysub not in key: continue
        a = w.index('itf'); itf = np.array(list(map(float, w[a + 1:a + 13])))
        b = w.index('bones'); vals = np.array(list(map(float, w[b + 1:b + 1 + nb * 12])))
        if len(vals) != nb * 12: continue
        meshes[key].append((int(w[1][1:]), nb, itf, vals.reshape(nb, 3, 4)))
    return meshes

def solve(poses, nb, maxres):
    P = np.stack([p[3] for p in poses if p[1] == nb])   # (frames, nb, 3, 4)
    R = P[:, :, :, :3]; t = P[:, :, :, 3]
    out = []
    for a in range(nb):
        for b in range(a + 1, nb):
            A = (R[:, a] - R[:, b]).reshape(-1, 3); y = (t[:, b] - t[:, a]).reshape(-1)
            if np.linalg.norm(A) < 1e-3: continue   # (always the same rotation: no information)
            j, *_ = np.linalg.lstsq(A, y, rcond=None)
            sv = np.linalg.svd(A, compute_uv=False)
            res = np.sqrt(np.mean((A @ j - y) ** 2))
            if res < maxres and sv[-1] > 0.05: out.append((res, a, b, j))
    return P, out

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('log'); ap.add_argument('--key', default=''); ap.add_argument('--maxres', type=float, default=0.004)
    o = ap.parse_args()
    meshes = load(o.log, o.key)
    for key, poses in sorted(meshes.items(), key=lambda kv: -len(kv[1])):
        nbs = collections.Counter(p[1] for p in poses); nb = nbs.most_common(1)[0][0]
        print('== mesh %s: %d poses, %d bones' % (key, len(poses), nb))
        if len(poses) < 8: continue
        P, joints = solve(poses, nb, o.maxres)
        # current joint position (last pose) in object space, for orientation
        for res, a, b, j in sorted(joints, key=lambda x: (x[1], x[2])):
            cur = P[-1, a] @ np.append(j, 1)
            print('  joint %3d-%3d res %.4f bind (%.3f %.3f %.3f) now (%.3f %.3f %.3f)' % (a, b, res, *j, *cur))

if __name__ == '__main__':
    main()
