#!/usr/bin/env python3
"""Local setup for the Mac installer. Uses the same preparation as the CLI."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))

import cp_settings
import vxmac_cyberpunk as vx


def capture(*command, input=None, timeout=30):
    return subprocess.run(command, input=input, capture_output=True, text=True, timeout=timeout)


def device_info(*args, timeout=15):
    with tempfile.TemporaryDirectory() as directory:
        result = Path(directory) / 'result.json'
        cmd = capture('/usr/bin/xcrun', 'devicectl', *args, '--timeout', str(timeout),
                      '--json-output', str(result), timeout=timeout + 5)
        if cmd.returncode:
            raise RuntimeError(cmd.stderr.strip() or cmd.stdout.strip() or 'Vision Pro is unavailable.')
        return json.loads(result.read_text())['result']


def signing_teams():
    identities = capture('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning').stdout
    active = set(re.findall(r'^\s*\d+\) ([A-F0-9]{40}) "Apple Development:', identities, re.M))
    if not active:
        return []
    output = capture('/usr/bin/security', 'find-certificate', '-a', '-c', 'Apple Development', '-p').stdout
    teams = set()
    for certificate in re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', output, re.S):
        x509 = capture('/usr/bin/openssl', 'x509', '-noout', '-fingerprint', '-sha1',
                       '-subject', '-nameopt', 'RFC2253', input=certificate).stdout
        fingerprint = re.search(r'Fingerprint=([A-F0-9:]+)', x509)
        team = re.search(r'(?:,|subject\s*=\s*)OU=([A-Z0-9]{10})(?:,|$)', x509)
        if fingerprint and fingerprint[1].replace(':', '') in active and team:
            teams.add(team[1])
    return sorted(teams)


def discover():
    sdk = capture('/usr/bin/xcrun', '--sdk', 'xros', '--show-sdk-version')
    sdks = sdk.stdout.strip()
    sdk_ok = sdk.returncode == 0 and sdks.partition('.')[0].isdigit() and int(sdks.split('.')[0]) >= 26
    devices = []
    device_error = None
    try:
        for row in device_info('list', 'devices')['devices']:
            hardware = row['hardwareProperties']
            if hardware.get('platform') not in ('visionOS', 'xrOS'):
                continue
            properties = row['deviceProperties']
            devices.append({
                'id': row['identifier'],
                'name': properties.get('name') or hardware.get('marketingName', 'Apple Vision Pro'),
                'udid': hardware['udid'],
                'developerMode': properties.get('developerModeStatus') == 'enabled',
            })
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        device_error = str(error)
    print(json.dumps({'sdk': sdks if sdk_ok else '', 'teams': signing_teams(),
                      'devices': devices, 'deviceError': device_error}))


def settings_profile():
    return {**cp_settings.CHEAP, **vx.EXTRA_PROFILES['p720native'],
            ('/graphics/basic', 'FilmGrain'): False,
            ('/graphics/basic', 'ChromaticAberration'): False,
            ('/graphics/basic', 'DepthOfField'): False,
            ('/graphics/presets', 'TextureQuality'): 'Low',
            ('/graphics/advanced', 'ScreenSpaceReflectionsQuality'): 'Off',
            ('/graphics/advanced', 'VolumetricFogResolution'): 'Low',
            ('/graphics/advanced', 'VolumetricCloudsQuality'): 'Off',
            ('/graphics/performance', 'CrowdDensity'): 'Low',
            ('/gameplay/performance', 'CrowdDensity'): 'Low'}


def apply_profile(settings, schema):
    profile = settings_profile()
    changed = set()
    groups = {group['group_name']: group for group in settings['data']}
    for definitions in schema['options']:
        group_name = definitions['group_name']
        matching = [option for option in definitions['options'] if (group_name, option['name']) in profile]
        if not matching:
            continue
        group = groups.get(group_name)
        if group is None:
            group = {'group_name': group_name, 'options': []}
            settings['data'].append(group)
        entries = {option['name']: option for option in group['options']}
        for option in matching:
            name = option['name']
            value = profile[group_name, name]
            entry = entries.get(name)
            if entry is None:
                fields = ('name', 'type', 'is_dynamic', 'default_index', 'default_value', 'values')
                entry = {key: option[key] for key in fields if key in option}
                group['options'].append(entry)
            values = entry.get('values', option.get('values'))
            if values and value not in values:
                raise RuntimeError(f'The installed game does not accept {name} = {value}.')
            value_changed = entry.get('value') != value
            entry['value'] = value
            if values:
                entry['index'] = values.index(value)
            elif entry['type'] == 'string_list' and value_changed:
                # Resolution has no fixed values in the game schema. It is selected by its saved string.
                entry.pop('index', None)
            changed.add(name)
    required = {'Resolution', 'MotionBlur', 'ResolutionScaling', 'DynamicResolutionScaling'}
    if required - changed:
        raise RuntimeError('Missing settings in the Mac game schema: ' + ', '.join(sorted(required - changed)))


def configure(config, schema):
    address = ['--device', config['device'], '--domain-type', 'appDataContainer',
               '--domain-identifier', config['bundle_id']]
    files = device_info('device', 'info', 'files', *address, timeout=60)['files']
    previous = any(file['relativePath'] == vx.SETTINGS_PATH for file in files)
    backup = Path(tempfile.mkdtemp(prefix='settings-', dir=vx.WORK))
    old = backup / 'UserSettings.original.json'
    if previous:
        vx.devicectl(['device', 'copy', 'from', *address, '--source', vx.SETTINGS_PATH,
                     '--destination', str(old), '--timeout', '30'])
        settings = json.loads(old.read_text())
    else:
        settings = {'version': schema['version'], 'data': []}
    apply_profile(settings, schema)
    updated = backup / 'UserSettings.json'
    updated.write_text(json.dumps(settings, indent=2) + '\n')
    vx.devicectl(['device', 'copy', 'to', *address, '--source', str(updated),
                 '--destination', vx.SETTINGS_PATH, '--timeout', '30'])
    checked = backup / 'UserSettings.readback.json'
    vx.devicectl(['device', 'copy', 'from', *address, '--source', vx.SETTINGS_PATH,
                 '--destination', str(checked), '--timeout', '30'])
    if checked.read_bytes() != updated.read_bytes():
        raise RuntimeError('The headset settings did not match the installed profile.')
    if previous:
        vx.say('Previous settings backed up at', old)


def installed_hosts(device):
    apps = device_info('device', 'info', 'apps', '--device', device)['apps']
    return sorted({app['bundleIdentifier'] for app in apps
                   if app.get('name') == 'VX Mac Host' and app.get('builtByDeveloper')})


def require_game_closed(device):
    processes = device_info('device', 'info', 'processes', '--device', device)['runningProcesses']
    if any(str(row.get('executable', '')).rstrip('/').endswith('/VXMacHost') for row in processes):
        raise RuntimeError('Save the game and quit VX Mac Host on Vision Pro, then retry.')


def install(args):
    game = Path(args.game).resolve()
    if not (game / 'Contents/_MASReceipt/receipt').is_file():
        raise RuntimeError('Select your purchased Mac App Store copy of Cyberpunk 2077.')
    data = game / 'Contents/Data'
    for folder in ('engine', 'r6', 'archive'):
        if not (data / folder).is_dir():
            raise RuntimeError('The Mac App Store game download is incomplete.')
    schema = json.loads((data / 'r6/config/settings/platform/mac/options.json').read_text())
    apply_profile({'version': schema['version'], 'data': []}, schema)
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team):
        raise RuntimeError('Select an Apple Development team.')
    bundle_id = args.bundle_id or f'com.{args.team.lower()}.VXMacHost'
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id):
        raise RuntimeError('Enter the existing bundle ID or leave it blank for a new installation.')
    if shutil.disk_usage(ROOT).free < 5_000_000_000:
        raise RuntimeError('Free at least 5 GB on your Mac to build VX Mac Host.')
    require_game_closed(args.device)
    state = Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)
    with open(state / 'installer.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another VXpro installation is running.') from None
        vx.say('VXPRO_STAGE Preparing game')
        vx.cmd_prepare(argparse.Namespace(game=str(game), team=args.team, bundle_id=bundle_id, device=args.device))
        vx.say('VXPRO_STAGE Building and signing')
        vx.cmd_build(argparse.Namespace(unsigned=False, derived_data=None, generated_project=True,
                                         destination=f'platform=visionOS,id={args.udid}'))
        config = vx.load_config()
        require_game_closed(args.device)
        vx.say('VXPRO_STAGE Installing VX Mac Host')
        vx.cmd_install(argparse.Namespace(dry_run=False))
        vx.say('VXPRO_STAGE Applying VR graphics settings')
        configure(config, schema)
        vx.say('VXPRO_STAGE Copying and verifying game data')
        checkpoint = state / 'transfer' / f'{args.device}-{bundle_id}-{config["exe_sha256"]}'
        vx.cmd_copy(argparse.Namespace(dry_run=False, tries=2, checkpoint=str(checkpoint), strict=True))


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('discover')
    existing = commands.add_parser('installed-hosts')
    existing.add_argument('--device', required=True)
    setup = commands.add_parser('install')
    for name in ('game', 'team', 'device', 'udid', 'state-dir'):
        setup.add_argument('--' + name, required=True)
    setup.add_argument('--bundle-id')
    args = parser.parse_args()
    try:
        if args.command == 'discover':
            discover()
        elif args.command == 'installed-hosts':
            print(json.dumps(installed_hosts(args.device)))
        else:
            install(args)
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        if args.command == 'install':
            vx.say('VXPRO_ERROR', str(error).splitlines()[0])
        sys.exit(str(error))


if __name__ == '__main__':
    main()
