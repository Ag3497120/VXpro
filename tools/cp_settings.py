#!/usr/bin/env python3
# cp_settings.py PROFILE: the game's settings on the headset (VX Mac Host's container, UserSettings.json) set to one of
# the GPU-budget profiles below, only while the game is not running (its own save would overwrite it). The previous
# file is kept beside the script's output (build/cyberpunk/settings/<time>.json). Profiles (all: the cheap effects off -
# ambient occlusion, local and contact shadows, motion blur, facial tangent updates):
#   p900       1600x900 output, dynamic resolution 50-65 % (what h17-h20 ran, plus the cheap effects)
#   p720       1280x720 output, dynamic resolution 50-65 %
#   p720fixed  1280x720 output, no dynamic resolution, MetalFX Performance (a fixed 50 %: MetalFX temporal may run,
#              which also gives the presenter the game's depth and motion vectors)
import json, os, subprocess, sys, time
DEV = os.environ.get('VXMAC_DEVICE', ''); APP = os.environ.get('VXMAC_BUNDLE_ID', '')   # (or tools/vxmac_cyberpunk.py settings)
PATH = 'Library/Application Support/CD Projekt Red/Cyberpunk 2077/UserSettings.json'
KEEP = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'build', 'cyberpunk', 'settings')
CHEAP = {('/graphics/advanced', 'AmbientOcclusion'): 'Off', ('/graphics/advanced', 'LocalShadowsQuality'): 'Off',
         ('/graphics/advanced', 'ContactShadows'): False, ('/graphics/basic', 'MotionBlur'): 'Off',
         ('/graphics/advanced', 'FacialTangentUpdates'): False}
PROFILES = {
    'p900': {('/video/display', 'Resolution'): '1600x900', ('/graphics/presets', 'DynamicResolutionScaling'): True},
    'p720': {('/video/display', 'Resolution'): '1280x720', ('/graphics/presets', 'DynamicResolutionScaling'): True},
    # (h31: a near-square frame at the screen's aspect (VXMAC_SCREEN 1856x1792): the horizontal FOV 100 kept, the
    #  vertical one ~+-49 deg - the eye's view; 1040x1004 is ~1.13x the pixels of 1280x720)
    'tall1040': {('/video/display', 'Resolution'): '1040x1004', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                 ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Performance',
                 ('/graphics/basic', 'FieldOfView'): 100.0, ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0},
    # (h37's resolution A/B, all 1040x1004 at FOV 100: MetalFX Balanced / Quality (internal ~0.58 / ~0.67 of the frame
    #  against Performance's 0.5), and Quality with the game capped at 22 fps (a steady quarter of 90, the depth warp
    #  fills the rest))
    'tall1040b': {('/video/display', 'Resolution'): '1040x1004', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                  ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Balanced',
                  ('/graphics/basic', 'FieldOfView'): 100.0, ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0,
                  ('/video/display', 'MaximumFPS_OnOff'): False},
    'tall1040q': {('/video/display', 'Resolution'): '1040x1004', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                  ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Quality',
                  ('/graphics/basic', 'FieldOfView'): 100.0, ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0,
                  ('/video/display', 'MaximumFPS_OnOff'): False},
    'tall1040q22': {('/video/display', 'Resolution'): '1040x1004', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                    ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Quality',
                    ('/graphics/basic', 'FieldOfView'): 100.0, ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0,
                    ('/video/display', 'MaximumFPS_OnOff'): True, ('/video/display', 'MaximumFPS_Value'): 22},
    # (h41's 16:9 resolution A/B: 1280x720 Balanced / Quality, 1600x900 Performance; HUD safe zone 0, no FPS cap)
    'p720b': {('/video/display', 'Resolution'): '1280x720', ('/graphics/presets', 'DynamicResolutionScaling'): False,
              ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Balanced',
              ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0, ('/video/display', 'MaximumFPS_OnOff'): False},
    'p720q': {('/video/display', 'Resolution'): '1280x720', ('/graphics/presets', 'DynamicResolutionScaling'): False,
              ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Quality',
              ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0, ('/video/display', 'MaximumFPS_OnOff'): False},
    'p900perf': {('/video/display', 'Resolution'): '1600x900', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                 ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Performance',
                 ('/interface/hudSafezones', 'HudSafezoneHor'): 0.0, ('/video/display', 'MaximumFPS_OnOff'): False},
    # (h56: nothing but the NAME=VALUE arguments - e.g. `cp_settings.py none FieldOfView=110.0`, the rest as the game has it)
    'none': {},
    'p720fixed': {('/video/display', 'Resolution'): '1280x720', ('/graphics/presets', 'DynamicResolutionScaling'): False,
                  ('/graphics/presets', 'ResolutionScaling'): 'MetalFX', ('/graphics/presets', 'MetalFX'): 'Performance'},
}
def dc(*a): return subprocess.run(['xcrun', 'devicectl', *a], capture_output=True, text=True, timeout=30)   # (h28: a hung copy stops at 30 s)
# Extra arguments NAME=VALUE set any other option by its name (h26: HudSafezoneHor=0.5 moves the HUD in from the
# frame's sides natively, HudScaling=110 makes it larger; numbers as numbers, true/false as booleans)
def parse(v):
    if v in ('true', 'false'): return v == 'true'
    try: return int(v)
    except ValueError: pass
    try: return float(v)
    except ValueError: return v
def main():
    if not DEV or not APP: sys.exit('set VXMAC_DEVICE (the headset id) and VXMAC_BUNDLE_ID (your bundle id)')
    prof = sys.argv[1] if len(sys.argv) > 1 else ''
    if prof not in PROFILES: sys.exit('profiles: ' + ', '.join(PROFILES))
    extra = dict(a.split('=', 1) for a in sys.argv[2:] if '=' in a)
    if 'VXMacHost.app/VXMacHost' in dc('device', 'info', 'processes', '--device', DEV).stdout:
        sys.exit('the game is running: settings are not changed while it runs')
    os.makedirs(KEEP, exist_ok=True)
    old = os.path.join(KEEP, time.strftime('%Y%m%d-%H%M%S') + '.json')
    r = dc('device', 'copy', 'from', '--device', DEV, '--domain-type', 'appDataContainer', '--domain-identifier', APP, '--source', PATH, '--destination', old)
    if r.returncode: sys.exit('copy from failed: ' + r.stderr[-300:])
    d = json.load(open(old))
    ch = {} if prof == 'none' else dict(CHEAP); ch.update(PROFILES[prof])
    for g in d['data']:
        for o in g['options']:
            k = (g['group_name'], o['name'])
            if o['name'] in extra and k not in ch:
                # (the option's own type: h27's HudSafezoneHor=0 went in as an int 0 where the game wants a float, and the
                #  game ignored the whole file - it ran 1600x900 with its defaults)
                v = parse(extra[o['name']])
                if o.get('type') == 'float': v = float(v)
                elif o.get('type') == 'int': v = int(v)
                ch[k] = v
            if k in ch:
                o['value'] = ch[k]
                if 'values' in o and ch[k] in o['values']: o['index'] = o['values'].index(ch[k])
                print('%s/%s = %s' % (k[0], k[1], ch[k]))
    new = old.replace('.json', '-%s%s.json' % (prof, ''.join('-%s%s' % kv for kv in extra.items())))
    json.dump(d, open(new, 'w'), indent=2)
    r = dc('device', 'copy', 'to', '--device', DEV, '--domain-type', 'appDataContainer', '--domain-identifier', APP, '--source', new, '--destination', PATH)
    print('written' if not r.returncode else 'copy to failed: ' + r.stderr[-300:], '(previous:', old + ')')
if __name__ == '__main__':
    main()
