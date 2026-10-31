#!/usr/bin/env python3
# patch_fov.py MAX: the game's FieldOfView slider range raised to MAX (default 120) in the WORK COPY of its data on the
# headset only (VX Mac Host's container, Documents/Cyberpunk2077.app/Contents/Data/r6/config/settings/platform/mac/
# options.json) - never the App Store bundle, never the original install. The file before is kept beside the settings
# backups (build/cyberpunk/settings/options-<time>.json); `patch_fov.py restore FILE` copies a kept one back. Only while the game
# is not running. Then cp_settings.py ... FieldOfView=120 sets the value; the host reads it and the presenter uses
# tan(FOV/2) horizontally, the frame's aspect vertically.
import json, os, subprocess, sys, time
DEV = os.environ.get('VXMAC_DEVICE', ''); APP = os.environ.get('VXMAC_BUNDLE_ID', '')   # (or tools/vxmac_cyberpunk.py settings)
PATH = 'Documents/Cyberpunk2077.app/Contents/Data/r6/config/settings/platform/mac/options.json'
KEEP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'build', 'cyberpunk', 'settings')
def dc(*a): return subprocess.run(['xcrun', 'devicectl', *a], capture_output=True, text=True, timeout=30)
def main():
    if not DEV or not APP: sys.exit('set VXMAC_DEVICE (the headset id) and VXMAC_BUNDLE_ID (your bundle id)')
    if 'VXMacHost.app/VXMacHost' in dc('device', 'info', 'processes', '--device', DEV).stdout:
        sys.exit('the game is running: its data is not changed while it runs')
    os.makedirs(KEEP, exist_ok=True)
    if len(sys.argv) > 2 and sys.argv[1] == 'restore':
        r = dc('device', 'copy', 'to', '--device', DEV, '--domain-type', 'appDataContainer', '--domain-identifier', APP, '--source', sys.argv[2], '--destination', PATH)
        sys.exit('restored' if not r.returncode else 'copy to failed: ' + r.stderr[-300:])
    mx = float(sys.argv[1]) if len(sys.argv) > 1 else 120.0
    old = os.path.join(KEEP, 'options-' + time.strftime('%Y%m%d-%H%M%S') + '.json')
    r = dc('device', 'copy', 'from', '--device', DEV, '--domain-type', 'appDataContainer', '--domain-identifier', APP, '--source', PATH, '--destination', old)
    if r.returncode: sys.exit('copy from failed: ' + r.stderr[-300:])
    d = json.load(open(old))
    n = 0
    def walk(x):
        nonlocal n
        if isinstance(x, dict):
            if x.get('name') == 'FieldOfView' and 'max_value' in x: x['max_value'] = mx; n += 1
            for v in x.values(): walk(v)
        elif isinstance(x, list):
            for v in x: walk(v)
    walk(d)
    if n != 1: sys.exit('FieldOfView found %d times: nothing written' % n)
    new = old.replace('.json', '-fov%.0f.json' % mx)
    json.dump(d, open(new, 'w'), indent=4)
    r = dc('device', 'copy', 'to', '--device', DEV, '--domain-type', 'appDataContainer', '--domain-identifier', APP, '--source', new, '--destination', PATH)
    print('FieldOfView max_value ->', mx, 'written' if not r.returncode else 'copy to failed: ' + r.stderr[-300:], '(before:', old + ')')
if __name__ == '__main__':
    main()
