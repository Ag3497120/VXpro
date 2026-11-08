#!/usr/bin/env python3
# new_build.py APP [OUTDIR] - a first look at a new Mac App Store Cyberpunk 2077 build (read only; nothing of APP is
# written): version and SHA-256, the pool patch's patterns (macho_prepare --pool-check), each image's libraries against
# 2.3.2's (new frameworks need a shim or must exist on visionOS), the MetalFX / BackgroundAssets classes it names, its
# data's layout and the delta against 2.3.2's manifest (data_manifest.py), then the four images prepared into OUTDIR and
# check_imports run on them. 2.3.2's code is kept in build/cyberpunk/game_2.3.2_code (with its manifest).
import json, os, plistlib, re, subprocess, sys
T = os.path.dirname(os.path.abspath(__file__)); V = os.path.dirname(T)
OLD = os.path.expanduser('build/cyberpunk/game_2.3.2_code')
app = os.path.abspath(sys.argv[1]); out = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else '/tmp/vxmac_new_build')
os.makedirs(out, exist_ok=True)
sh = lambda *c: subprocess.run(c, text=True, capture_output=True)
IM = [('MacOS/Cyberpunk2077', 'Cyberpunk2077.dylib', ['--system-shim', '--pool-patch', '--as-dylib', '@rpath/Cyberpunk2077.dylib']),
      ('Frameworks/libGameServicesAppStore.dylib', 'libGameServicesAppStore.dylib', ['--system-shim']),
      ('Frameworks/libBink2MacArm64.dylib', 'libBink2MacArm64.dylib', []), ('Frameworks/libREDGalaxy64.dylib', 'libREDGalaxy64.dylib', ['--system-shim'])]
info = plistlib.load(open(os.path.join(app, 'Contents/Info.plist'), 'rb'))
print('== version', info.get('CFBundleShortVersionString'), info.get('CFBundleVersion'), 'min macOS', info.get('LSMinimumSystemVersion'))
print('== frameworks folder:', sorted(os.listdir(os.path.join(app, 'Contents/Frameworks'))))
print('== pool patterns'); r = sh(sys.executable, os.path.join(T, 'macho_prepare.py'), '--pool-check', os.path.join(app, 'Contents/MacOS/Cyberpunk2077')); print(r.stdout + r.stderr)
def libs(p): return set(l.strip().split(' (')[0] for l in sh('otool', '-L', p).stdout.splitlines()[1:])
for src, _, _ in IM:
    n = os.path.join(app, 'Contents', src); o = os.path.join(OLD, src)
    if not os.path.exists(n): print('== MISSING', src); continue
    a, b = libs(o) if os.path.exists(o) else set(), libs(n)
    print('== libraries of', src, ': new', sorted(b - a), 'gone', sorted(a - b))
exe = os.path.join(app, 'Contents/MacOS/Cyberpunk2077')
names = set(re.findall(r'MTLFX\w+|BA[A-Z][a-z]\w+|BackgroundAssets\w*|MTL4\w+', sh('strings', '-a', exe).stdout))
oldn = set(re.findall(r'MTLFX\w+|BA[A-Z][a-z]\w+|BackgroundAssets\w*|MTL4\w+', sh('strings', '-a', os.path.join(OLD, 'MacOS/Cyberpunk2077')).stdout))
print('== MetalFX / BackgroundAssets / Metal 4 names: new', sorted(names - oldn), '\n   (all now:', sorted(names), ')')
data = os.path.join(app, 'Contents/Data')
if os.path.isdir(data):
    man = os.path.join(out, 'data_manifest_new.json')
    sh(sys.executable, os.path.join(T, 'data_manifest.py'), data, man)
    r = sh(sys.executable, os.path.join(T, 'data_manifest.py'), '--delta', os.path.join(OLD, 'data_manifest_2.3.2.json'), man)
    print('== data delta against 2.3.2 (the headset holds 2.3.2)\n' + r.stdout[:6000])
else: print('== no Contents/Data in the bundle (background-downloaded assets? look in ~/Library/Containers/*/Data/Library/Application Support)')
print('== prepare + check_imports')
sh('make', '-C', os.path.join(V, 'shims'))
pre = os.path.join(out, 'Frameworks'); os.makedirs(pre, exist_ok=True)
for src, dst, fl in IM:
    r = sh(sys.executable, os.path.join(T, 'macho_prepare.py'), os.path.join(app, 'Contents', src), os.path.join(pre, dst), *fl, '--json', os.path.join(out, dst + '.json'))
    print(dst, 'ok' if not r.returncode else 'FAILED: ' + r.stderr[-400:])
r = sh(sys.executable, os.path.join(T, 'check_imports.py'), *[os.path.join(pre, d) for _, d, _ in IM], '--shims', os.path.join(V, 'build/xros') + ':' + pre)
print(r.stdout[-6000:] + r.stderr[-2000:])
