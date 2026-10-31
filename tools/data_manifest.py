#!/usr/bin/env python3
# data_manifest.py DATA_DIR OUT.json - every file of a game's Contents/Data (read only): relative path, size, mtime and
# a quick fingerprint (SHA-256 of the whole file under 64 MB, else of its first and last 16 MB plus its size).
# data_manifest.py --delta OLD.json NEW.json [--list] - what an update changed: new / changed / removed files and their bytes
# (the headset copy then sends only those; archive/Mac -> archive/mac as copy_game_data.sh does).
import hashlib, json, os, sys
CH = 16 << 20
def fp(p, size):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        if size <= 4 * CH:
            for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
        else:
            h.update(f.read(CH)); f.seek(size - CH); h.update(f.read(CH)); h.update(str(size).encode())
    return h.hexdigest()
def manifest(root, out):
    files = {}
    for d, _, fs in os.walk(root):
        for n in fs:
            p = os.path.join(d, n); r = os.path.relpath(p, root); st = os.stat(p)
            files[r] = {'size': st.st_size, 'mtime': int(st.st_mtime), 'fp': fp(p, st.st_size)}
    json.dump({'root': root, 'files': files}, open(out, 'w'), indent=0, sort_keys=True)
    print('%d files, %.1f GB -> %s' % (len(files), sum(f['size'] for f in files.values()) / 1e9, out))
def delta(a, b, listing=False):
    A, B = json.load(open(a))['files'], json.load(open(b))['files']
    new = sorted(set(B) - set(A)); gone = sorted(set(A) - set(B))
    chg = sorted(r for r in set(A) & set(B) if (A[r]['size'], A[r]['fp']) != (B[r]['size'], B[r]['fp']))
    if listing:   # (new and changed, smallest first: copy_game_data.sh LIST=)
        for r in sorted(new + chg, key=lambda r: B[r]['size']): print(r)
        return
    for k, l in (('new', new), ('changed', chg), ('removed', gone)):
        src = A if k == 'removed' else B
        print('%s: %d files, %.2f GB' % (k, len(l), sum(src[r]['size'] for r in l) / 1e9))
        for r in l: print('  %s %s %.1f MB' % (k[0], r, src[r]['size'] / 1e6))
if __name__ == '__main__':
    if len(sys.argv) in (4, 5) and sys.argv[1] == '--delta': delta(sys.argv[2], sys.argv[3], sys.argv[4:] == ['--list'])
    elif len(sys.argv) == 3: manifest(sys.argv[1], sys.argv[2])
    else: sys.exit(__doc__ or 'usage: data_manifest.py DATA_DIR OUT.json | --delta OLD.json NEW.json')
