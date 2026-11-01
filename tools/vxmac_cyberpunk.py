#!/usr/bin/env python3
"""vxmac_cyberpunk.py: your own Mac App Store Cyberpunk 2077 standalone on your own Apple Vision Pro (VX Mac route).

The guided steps of docs/VISION_PRO_CYBERPUNK_MAC.md, with your team, bundle id and headset instead of anyone else's:

    tools/vxmac_cyberpunk.py doctor  [--game <.../Cyberpunk2077.app>]    what is there and what is missing
    tools/vxmac_cyberpunk.py prepare --game <.../Cyberpunk2077.app> [--team <TEAMID>] [--bundle-id <id>] [--device <id>]
                                     (--team defaults to $VXMAC_TEAM, --bundle-id to $VXMAC_BUNDLE_ID)
                                     the shims, then work copies of the game's four images (never the original)
    tools/vxmac_cyberpunk.py build   [--unsigned]  VX Mac Host signed with YOUR team, the work copies embedded (and
                                     the foveated SR model made by tools/fsr_model.py when coremltools is installed)
    tools/vxmac_cyberpunk.py install devicectl device install app (never uninstall: see below)
    tools/vxmac_cyberpunk.py copy    Contents/Data into the app's container (resumable), then verified by size
    tools/vxmac_cyberpunk.py settings [--profile p720] [--set NAME=VALUE ...]   UserSettings.json (game not running)
    tools/vxmac_cyberpunk.py fov     [--max 110]   the FieldOfView slider's range in the headset's work copy (patch_fov.py)
    tools/vxmac_cyberpunk.py launch  [--restart] [--env NAME=VALUE ...]          (e.g. --env VXMAC_FSR=1)
    tools/vxmac_cyberpunk.py pull    [--tag <t>]          the logs back into build/cyberpunk/logs/<t>

Every command that talks to the headset takes --dry-run (prints the devicectl commands, runs nothing on the device).
Everything made here goes into build/cyberpunk/ (git-ignored). The App Store bundle is only read.

NEVER uninstall VX Mac Host (on the headset or with `devicectl device uninstall app`) and never install with
--remove-existing-content: that deletes its container, the copy of the game's data (about 80 GB for 2.5.0) and your saves in it.
"""
import argparse, hashlib, json, os, shlex, shutil, subprocess, sys, tempfile, time

VXMAC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))           # the repository
TOOLS = os.path.join(VXMAC, 'tools')
WORK = os.path.join(VXMAC, 'build', 'cyberpunk')
CONFIG = os.path.join(WORK, 'config.json')
PREPARED = os.path.join(WORK, 'prepared', 'Frameworks')
DST_DATA = 'Documents/Cyberpunk2077.app/Contents/Data'
SETTINGS_PATH = 'Library/Application Support/CD Projekt Red/Cyberpunk 2077/UserSettings.json'
# (the images the game loads from its bundle, and how each is prepared: AVP_MAC.md "Preparing the images")
IMAGES = [
    ('Contents/MacOS/Cyberpunk2077', 'Cyberpunk2077.dylib', ['--system-shim', '--pool-patch', '--as-dylib', '@rpath/Cyberpunk2077.dylib']),
    ('Contents/Frameworks/libGameServicesAppStore.dylib', 'libGameServicesAppStore.dylib', ['--system-shim']),
    ('Contents/Frameworks/libBink2MacArm64.dylib', 'libBink2MacArm64.dylib', []),
    ('Contents/Frameworks/libREDGalaxy64.dylib', 'libREDGalaxy64.dylib', []),
]
sys.path.insert(0, TOOLS)


# (the executables run on the headset: their pool sites are found by pattern, macho_prepare.find_pool_sites)
TESTED = {'3907f316f6adf9dd8188be82aeea9ae161445b2e1f6d25cf08c87b8a3ae6b421': '2.3.2',
          '8f4a88ad201f360772b3747f51701944f39b98b4ecbf7edc6271c1cc24932844': '2.5.0'}


def supported_sha():
    import macho_prepare
    return macho_prepare.POOL_PATCH_SHA256


def pool_sites_ok(exe):
    """Another build than 2.3.2: are the pool-size patterns found as expected (macho_prepare.find_pool_sites)?"""
    import macho_prepare
    try:
        return len(macho_prepare.find_pool_sites(open(exe, 'rb').read()))
    except SystemExit as e:
        say('       pool patterns: %s' % e)
        return 0


def say(*a): print(*a, flush=True)


def run(cmd, dry=False, check=True, capture=False, cwd=None, env=None):
    say('$ ' + ' '.join(shlex.quote(c) for c in cmd))
    if dry: return subprocess.CompletedProcess(cmd, 0, '', '')
    r = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=capture)
    if check and r.returncode:
        sys.exit('failed (%d): %s%s' % (r.returncode, cmd[0], ('\n' + (r.stderr or '')[-800:]) if capture else ''))
    return r


def load_config():
    if not os.path.exists(CONFIG): sys.exit('no %s: run prepare first' % CONFIG)
    return json.load(open(CONFIG))


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''): h.update(b)
    return h.hexdigest()


def tree_size(path):
    n = b = 0
    for root, ds, fs in os.walk(path):
        for name in fs:
            n += 1; b += os.path.getsize(os.path.join(root, name))
    return n, b


def devicectl(args, dry=False, check=True, capture=False):
    return run(['xcrun', 'devicectl', *args], dry=dry, check=check, capture=capture)


def paired_devices():
    with tempfile.NamedTemporaryFile(suffix='.json') as t:
        r = subprocess.run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', t.name], capture_output=True, text=True)
        if r.returncode: return []
        try: d = json.load(open(t.name))
        except ValueError: return []
    out = []
    for dev in d.get('result', {}).get('devices', []):
        hw = dev.get('hardwareProperties', {}); props = dev.get('deviceProperties', {})
        if hw.get('platform') in ('visionOS', 'xrOS') or 'Vision' in (hw.get('marketingName') or ''):
            out.append({'id': dev.get('identifier'), 'name': props.get('name'), 'state': dev.get('connectionProperties', {}).get('tunnelState'),
                        'developer_mode': props.get('developerModeStatus')})
    return out


# ---- doctor ----------------------------------------------------------------------------------------------------------
def cmd_doctor(a):
    ok = True
    def line(good, what, more=''):
        nonlocal ok
        ok = ok and good
        say('  %-4s %s%s' % ('ok' if good else 'MISS', what, ('  ' + more) if more else ''))
    say('Mac tools')
    r = subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True)
    line(r.returncode == 0, 'Xcode', (r.stdout.split('\n')[0] if r.returncode == 0 else 'install Xcode 26 or later'))
    r = subprocess.run(['xcrun', '--sdk', 'xros', '--show-sdk-version'], capture_output=True, text=True)
    line(r.returncode == 0, 'visionOS SDK', r.stdout.strip() or 'Xcode > Settings > Components: visionOS')
    line(bool(shutil.which('xcodegen')), 'xcodegen', '' if shutil.which('xcodegen') else 'brew install xcodegen')
    r = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True)
    n = sum(1 for l in r.stdout.splitlines() if 'Apple Development' in l)
    line(n > 0, 'Apple Development signing identities: %d' % n, 'a paid Developer Program team is needed (entitlements)')
    free = shutil.disk_usage(VXMAC).free / 1e9
    line(free > 5, 'free space on the Mac: %.0f GB' % free, 'about 5 GB for the work copies and the build')
    say('Headset')
    devs = paired_devices()
    line(bool(devs), 'paired Vision Pro: %d' % len(devs), '' if devs else 'pair it in Xcode > Window > Devices and Simulators')
    for d in devs:
        say('       %s  %s  tunnel=%s  developer mode=%s' % (d['id'], d['name'], d['state'], d['developer_mode']))
    say('       free space on the headset: check Settings > General > Storage (about 85 GB for 2.5.0, about 160 GB for 2.3.2)')
    say('Game')
    game = a.game or (json.load(open(CONFIG)).get('game') if os.path.exists(CONFIG) else None)
    if not game:
        line(False, 'game bundle', 'pass --game "<.../Cyberpunk2077.app>"')
    else:
        exe = os.path.join(game, 'Contents/MacOS/Cyberpunk2077')
        line(os.path.exists(exe), 'Cyberpunk2077.app', game)
        if os.path.exists(exe):
            digest = sha256(exe)
            if digest in TESTED and (digest == supported_sha() or pool_sites_ok(exe)):
                line(True, 'executable SHA-256 %s' % digest[:16], '%s (Mac App Store): tested' % TESTED[digest])
            else:
                n = pool_sites_ok(exe)
                line(n > 0, 'executable SHA-256 %s' % digest[:16],
                     ('another build: %d pool sites found by pattern - UNTESTED, prepare will warn' % n) if n else
                     'another build and its pool patterns are not found: not supported')
            for src, _, _ in IMAGES[1:]:
                line(os.path.exists(os.path.join(game, src)), os.path.basename(src))
            data = os.path.join(game, 'Contents/Data')
            if os.path.isdir(data):
                n, b = tree_size(data)
                line(True, 'Contents/Data: %d files, %.1f GB' % (n, b / 1e9))
            else:
                line(False, 'Contents/Data')
    say('\n' + ('everything found' if ok else 'something is missing (MISS above)'))
    return 0 if ok else 1


# ---- prepare ---------------------------------------------------------------------------------------------------------
def cmd_prepare(a):
    game = os.path.abspath(a.game)
    exe = os.path.join(game, 'Contents/MacOS/Cyberpunk2077')
    if not os.path.exists(exe): sys.exit('no %s' % exe)
    digest = sha256(exe)
    if digest in TESTED and digest != supported_sha() and not pool_sites_ok(exe):
        sys.exit('the pool patterns of %s were not found: report this' % TESTED[digest])
    if digest not in TESTED:
        if not pool_sites_ok(exe):
            sys.exit('this executable (%s) is not Cyberpunk 2077 2.3.2 and its pool patterns are not found: not supported' % digest)
        say('WARNING: this executable (%s) is not a tested build (2.3.2, 2.5.0); its pool sites were found by pattern. It is '
            'untested on the headset: keep your 2.3.2 data and saves backed up.' % digest[:16])
    team = a.team or os.environ.get('VXMAC_TEAM', '')
    if len(team) != 10 or not team.isalnum(): sys.exit('--team (or $VXMAC_TEAM): your 10-character Apple Developer Team ID')
    bundle = a.bundle_id or os.environ.get('VXMAC_BUNDLE_ID') or 'com.%s.VXMacHost' % team.lower()
    device = a.device
    if not device:
        devs = paired_devices()
        if len(devs) == 1: device = devs[0]['id']
        else: say('note: %d paired Vision Pros; pass --device <id> (prepare again) before install' % len(devs))
    os.makedirs(PREPARED, exist_ok=True)
    cfg = {'game': game, 'team': team, 'bundle_id': bundle, 'device': device, 'exe_sha256': digest}
    json.dump(cfg, open(CONFIG, 'w'), indent=1)
    say('config: %s' % CONFIG)
    run(['make', '-C', os.path.join(VXMAC, 'shims')])
    man = os.path.join(WORK, 'manifests'); os.makedirs(man, exist_ok=True)
    for src, dst, flags in IMAGES:
        out = os.path.join(PREPARED, dst)
        run([sys.executable, os.path.join(TOOLS, 'macho_prepare.py'), os.path.join(game, src), out, *flags,
             '--json', os.path.join(man, dst + '.json')], capture=True)
    r = run([sys.executable, os.path.join(TOOLS, 'check_imports.py'), *[os.path.join(PREPARED, d) for _, d, _ in IMAGES],
             '--shims', os.path.join(VXMAC, 'build', 'xros') + ':' + PREPARED], capture=True, check=False)
    say(r.stdout[-1500:])
    if r.returncode: sys.exit('check_imports failed')
    say('prepared: %s (work copies; the App Store bundle was only read)' % PREPARED)


# ---- build -----------------------------------------------------------------------------------------------------------
def app_path():
    return os.path.join(VXMAC, 'build', 'dd', 'Build', 'Products', 'Debug-xros', 'VXMacHost.app')


FSR_DIR = os.path.join(VXMAC, 'build', 'fsr')


def fsr_model():
    # (the foveated SR's Core ML model is made here from tools/fsr_model.py, never committed; embed_images.sh puts
    #  build/fsr/*.mlmodelc into the app. Without coremltools the app is built without it: VXMAC_FSR=1 then does nothing)
    if os.path.isdir(os.path.join(FSR_DIR, 'vxfsr_512x288.mlmodelc')): return
    if subprocess.run([sys.executable, '-c', 'import coremltools, numpy'], capture_output=True).returncode:
        say('note: coremltools / numpy not installed: the app is built without the foveated SR model '
            '(python3 -m pip install coremltools numpy, then build again)'); return
    run([sys.executable, os.path.join(TOOLS, 'fsr_model.py'), '--out', FSR_DIR], cwd=VXMAC)


def cmd_build(a):
    if a.unsigned:
        # (a check that the tree builds: no team, no game; the test program is embedded instead of the game)
        c = {'team': '', 'bundle_id': 'com.example.VXMacHost'}
        images = os.path.join(VXMAC, 'build', 'xros_images')
    else:
        c = load_config()
        if not os.path.exists(os.path.join(PREPARED, 'Cyberpunk2077.dylib')): sys.exit('no work copies: run prepare')
        images = PREPARED
    run(['make', '-C', os.path.join(VXMAC, 'shims')])
    if a.unsigned: run([os.path.join(TOOLS, 'prepare_test.sh')])
    fsr_model()
    appdir = os.path.join(VXMAC, 'app')
    run(['xcodegen'], cwd=appdir)
    env = dict(os.environ, VXMAC_IMAGES=images)
    sign = (['CODE_SIGNING_ALLOWED=NO'] if a.unsigned else
            ['-allowProvisioningUpdates', 'DEVELOPMENT_TEAM=' + c['team']])
    run(['xcodebuild', '-project', 'VXMacHost.xcodeproj', '-scheme', 'VXMacHost', '-destination', 'generic/platform=visionOS',
         '-derivedDataPath', a.derived_data or '../build/dd', 'build', *sign,
         'PRODUCT_BUNDLE_IDENTIFIER=' + c['bundle_id'], 'VXMAC_IMAGES=' + images], cwd=appdir, env=env)
    if a.unsigned:
        say('built (unsigned check build, test program embedded)'); return
    app = app_path()
    for _, d, _ in IMAGES:
        if not os.path.exists(os.path.join(app, 'Frameworks', d)): sys.exit('not embedded: Frameworks/%s' % d)
    r = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', app], capture_output=True, text=True)
    for e in ('com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing'):
        if e not in r.stdout: sys.exit('the signed app lacks %s (a paid team is needed)' % e)
    say('built: %s (signed by your team; do not share it: it contains the game\'s code)' % app)


# ---- install ---------------------------------------------------------------------------------------------------------
def need_device(c):
    if not c.get('device'): sys.exit('no headset chosen: prepare again with --device <id>')
    return c['device']


def cmd_install(a):
    c = load_config(); dev = need_device(c)
    app = app_path()
    if not a.dry_run and not os.path.exists(app): sys.exit('no app: run build')
    # (plain install: an update keeps the app's container, the game data and the saves)
    devicectl(['device', 'install', 'app', '--device', dev, app], dry=a.dry_run)


# ---- copy ------------------------------------------------------------------------------------------------------------
def dst_of(rel):
    if rel.startswith('archive/Mac/'): rel = 'archive/mac/' + rel[len('archive/Mac/'):]   # (the game asks for lower case)
    return DST_DATA + '/' + rel


def device_files(c, dry):
    if dry: return {}
    with tempfile.NamedTemporaryFile(suffix='.json') as t:
        r = subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'files', '--device', c['device'], '--domain-type',
                            'appDataContainer', '--domain-identifier', c['bundle_id'], '--subdirectory', DST_DATA,
                            '--json-output', t.name], capture_output=True, text=True)
        if r.returncode: return {}
        d = json.load(open(t.name))
    return {f['relativePath']: f['metadata']['size'] for f in d.get('result', {}).get('files', [])
            if not f['resources']['isDirectory']}


def cmd_copy(a):
    c = load_config(); dev = need_device(c)
    src = os.path.join(c['game'], 'Contents/Data')
    logd = os.path.join(WORK, 'copy'); os.makedirs(logd, exist_ok=True)
    done_f = os.path.join(logd, 'done.txt')
    done = set(open(done_f).read().split('\n')) if os.path.exists(done_f) else set()
    archives = []
    for root, ds, fs in os.walk(os.path.join(src, 'archive')):
        for name in fs:
            p = os.path.join(root, name); archives.append((os.path.getsize(p), os.path.relpath(p, src)))
    items = ['engine', 'r6'] + [r for _, r in sorted(archives)]
    say('%d items to copy (engine, r6, then each archive smallest first); done before: %d' % (len(items), len(done & set(items))))
    for it in items:
        if it in done: continue
        for attempt in range(1, a.tries + 1):
            r = devicectl(['device', 'copy', 'to', '--device', dev, '--domain-type', 'appDataContainer',
                           '--domain-identifier', c['bundle_id'], '--source', os.path.join(src, it),
                           '--destination', dst_of(it), '--timeout', '7200'], dry=a.dry_run, check=False)
            if r.returncode == 0:
                if not a.dry_run:
                    with open(done_f, 'a') as f: f.write(it + '\n')
                break
            say('  failed (try %d of %d): %s; waiting 60 s' % (attempt, a.tries, it)); time.sleep(60)
        else:
            sys.exit('stopped at %s: run copy again to resume (keep the headset awake, do not install meanwhile)' % it)
    verify(c, src, a.dry_run)


def verify(c, src, dry):
    dev = device_files(c, dry)
    if dry: say('(dry run: no check)'); return
    n = b = bad = 0
    for root, ds, fs in os.walk(src):
        for name in fs:
            p = os.path.join(root, name); rel = os.path.relpath(p, src); s = os.path.getsize(p); n += 1; b += s
            rel2 = dst_of(rel)[len(DST_DATA) + 1:]
            if dev.get(rel2) != s:
                bad += 1
                if bad <= 20: say('  missing or wrong size: %s' % rel2)
    say('check: source %d files %.1f GB; headset %d files %.1f GB; mismatches %d -> %s'
        % (n, b / 1e9, len(dev), sum(dev.values()) / 1e9, bad, 'OK' if not bad else 'INCOMPLETE: run copy again'))
    if bad:
        # (a mismatched item is copied again by the next copy)
        done_f = os.path.join(WORK, 'copy', 'done.txt')
        if os.path.exists(done_f): os.replace(done_f, done_f + '.%d' % int(time.time()))


# ---- settings --------------------------------------------------------------------------------------------------------
def game_running(c):
    r = subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', c['device']], capture_output=True, text=True)
    return 'VXMacHost.app/VXMacHost' in r.stdout


# (profiles of this tool besides tools/cp_settings.py's: 1280x720 / 1600x900 rendered natively, no upscaler)
EXTRA_PROFILES = {
    'p720native': {('/video/display', 'Resolution'): '1280x720', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                   ('/graphics/presets', 'ResolutionScaling'): 'Off'},
    'p900native': {('/video/display', 'Resolution'): '1600x900', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                   ('/graphics/presets', 'ResolutionScaling'): 'Off'},
}


def cmd_settings(a):
    import cp_settings
    profiles = dict(cp_settings.PROFILES); profiles.update(EXTRA_PROFILES)
    c = load_config(); dev = need_device(c)
    if a.profile not in profiles: sys.exit('profiles: ' + ', '.join(profiles))
    if not a.dry_run and game_running(c): sys.exit('the game is running: quit it first (its own save would overwrite the file)')
    keep = os.path.join(WORK, 'settings'); os.makedirs(keep, exist_ok=True)
    old = os.path.join(keep, time.strftime('%Y%m%d-%H%M%S') + '.json')
    r = devicectl(['device', 'copy', 'from', '--device', dev, '--domain-type', 'appDataContainer', '--domain-identifier',
                   c['bundle_id'], '--source', SETTINGS_PATH, '--destination', old], dry=a.dry_run, check=False)
    if a.dry_run: return
    if r.returncode or not os.path.exists(old):
        sys.exit('no UserSettings.json on the headset yet: launch the game once (to the main menu), quit, run settings again')
    d = json.load(open(old))
    ch = {} if a.profile == 'none' else dict(cp_settings.CHEAP); ch.update(profiles[a.profile])
    extra = dict(kv.split('=', 1) for kv in a.set if '=' in kv)   # (any other option by its name, e.g. HudSafezoneHor=0.5)
    for g in d['data']:
        for o in g['options']:
            k = (g['group_name'], o['name'])
            if o['name'] in extra and k not in ch: ch[k] = cp_settings.parse(extra[o['name']])
            if k in ch:
                o['value'] = ch[k]
                if 'values' in o and ch[k] in o['values']: o['index'] = o['values'].index(ch[k])
                say('  %s/%s = %s' % (k[0], k[1], ch[k]))
    new = old.replace('.json', '-%s.json' % a.profile)
    json.dump(d, open(new, 'w'), indent=2)
    devicectl(['device', 'copy', 'to', '--device', dev, '--domain-type', 'appDataContainer', '--domain-identifier',
               c['bundle_id'], '--source', new, '--destination', SETTINGS_PATH])
    say('written (the previous file: %s)' % old)


def cmd_fov(a):
    # (tools/patch_fov.py: the slider's maximum in the work copy's options.json on the headset; never the App Store bundle)
    c = load_config(); dev = need_device(c)
    cmd = [sys.executable, os.path.join(TOOLS, 'patch_fov.py'), str(a.max)]
    if a.dry_run: say('$ VXMAC_DEVICE=%s VXMAC_BUNDLE_ID=%s %s' % (dev, c['bundle_id'], ' '.join(cmd))); return
    run(cmd, env=dict(os.environ, VXMAC_DEVICE=dev, VXMAC_BUNDLE_ID=c['bundle_id']))


# ---- launch / pull ---------------------------------------------------------------------------------------------------
def cmd_launch(a):
    c = load_config(); dev = need_device(c)
    args = ['device', 'process', 'launch', '--device', dev]
    if a.restart: args.append('--terminate-existing')   # (ends a running game without saving)
    extra = []
    for kv in a.env:
        if '=' not in kv: sys.exit('--env NAME=VALUE')
        extra += ['-env', kv]
    devicectl(args + [c['bundle_id']] + (['--'] + extra if extra else []), dry=a.dry_run)
    say('put the headset on and unlock it; the game starts in the immersive space')


def cmd_pull(a):
    c = load_config(); dev = need_device(c)
    out = os.path.join(WORK, 'logs', a.tag or time.strftime('%Y%m%d-%H%M%S')); os.makedirs(out, exist_ok=True)
    for name in ('vxmac_host.jsonl', 'vxmac_program.log'):
        devicectl(['device', 'copy', 'from', '--device', dev, '--domain-type', 'appDataContainer', '--domain-identifier',
                   c['bundle_id'], '--source', 'Documents/' + name, '--destination', os.path.join(out, name)],
                  dry=a.dry_run, check=False)
    say('logs: %s (they name your files and device: do not post them unread)' % out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('doctor'); p.add_argument('--game')
    p = sp.add_parser('prepare'); p.add_argument('--game', required=True); p.add_argument('--team')
    p.add_argument('--bundle-id'); p.add_argument('--device')
    p = sp.add_parser('build'); p.add_argument('--unsigned', action='store_true', help='check build: no team, no game')
    p.add_argument('--derived-data')
    for name in ('install', 'copy', 'settings', 'fov', 'launch', 'pull'):
        p = sp.add_parser(name); p.add_argument('--dry-run', action='store_true')
        if name == 'copy': p.add_argument('--tries', type=int, default=8)
        if name == 'settings': p.add_argument('--profile', default='p720native'); p.add_argument('--set', action='append', default=[])
        if name == 'launch':
            p.add_argument('--restart', action='store_true', help='end a running instance first (unsaved progress is lost)')
            p.add_argument('--env', action='append', default=[], help='NAME=VALUE for the app (e.g. VXMAC_FSR=1)')
        if name == 'pull': p.add_argument('--tag')
        if name == 'fov': p.add_argument('--max', type=int, default=110)
    a = ap.parse_args()
    return {'doctor': cmd_doctor, 'prepare': cmd_prepare, 'build': cmd_build, 'install': cmd_install, 'copy': cmd_copy,
            'settings': cmd_settings, 'fov': cmd_fov, 'launch': cmd_launch, 'pull': cmd_pull}[a.cmd](a) or 0


if __name__ == '__main__':
    sys.exit(main())
