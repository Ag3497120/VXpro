#!/usr/bin/env python3
"""Compile the optional reload overlay from the player's own script cache; never overwrite the input."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bundle", required=True, type=Path, help="the user's unmodified final.redscripts")
parser.add_argument("--compiler", required=True, type=Path, help="redscript-cli executable")
parser.add_argument("--output", required=True, type=Path, help="private overlay file, outside the game data")
parser.add_argument("--manual-config", type=Path,
                    help="original r6/config directory; also build the experimental manual input overlays")
parser.add_argument("--weapon-bridge", action="store_true",
                    help="include read-only equipment and shot telemetry for VXMac's optional native bridge")
args = parser.parse_args()
if args.weapon_bridge and not args.manual_config:
    parser.error("--weapon-bridge requires --manual-config")
bundle = args.bundle.resolve(strict=True)
output = args.output.resolve()
if output == bundle:
    parser.error("the output must not overwrite the original game script cache")
script_dir = Path(__file__).resolve().parents[1] / "mod/VXHands/r6/scripts"
source = script_dir / ("vxhands_manual_mag.reds" if args.manual_config else "vxhands_no_auto_reload.reds")


def manual_input_files(config, output):
    commands = (("VXHandsEject", "IK_F10"), ("VXHandsInsert", "IK_F11"), ("VXHandsChamber", "IK_F12"))
    files = ("inputUserMappings.xml", "inputContexts.xml")
    originals = [(config / name).resolve(strict=True) for name in files]
    destinations = [output.parent / name for name in files]
    if output.name != "final.redscripts":
        parser.error("manual mode output must be named final.redscripts")
    if any(path.resolve() in [bundle, *originals] for path in [output, *destinations]):
        parser.error("manual overlays must be outside the original game's files")
    mappings, contexts = (path.read_text(encoding="utf-8") for path in originals)
    if any(name in mappings or name in contexts or key in mappings for name, key in commands):
        parser.error("manual command names or keys already exist in the input files")
    new_mappings = "".join(
        f'\t<mapping name="{name}_Button" type="Button"><button id="{key}"/></mapping>\n'
        for name, key in commands
    )
    mappings, count = re.subn(r"</bindings>", new_mappings + "</bindings>", mappings)
    if count != 1:
        parser.error("expected one bindings root in inputUserMappings.xml")
    new_actions = "".join(f'\t\t<action name="{name}" map="{name}_Button"/>\n' for name, _ in commands)
    contexts, count = re.subn(r'(<context\s+name="Combat"\s*>)(.*?)(</context>)',
                              lambda m: m[1] + "\n" + new_actions + m[2] + m[3], contexts, flags=re.S)
    if count != 1:
        parser.error("expected one Combat context in inputContexts.xml")
    for text in (mappings, contexts):
        ET.fromstring(text)
    return dict(zip(destinations, (mappings, contexts)))


inputs_xml = manual_input_files(args.manual_config, output) if args.manual_config else {}
output.parent.mkdir(parents=True, exist_ok=True)
digest = hashlib.sha256(bundle.read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(prefix="vxhands-", dir=output.parent) as work:
    work = Path(work)
    inputs = work / "scripts"
    inputs.mkdir()
    shutil.copyfile(source, inputs / source.name)
    if args.weapon_bridge:
        bridge = script_dir / "vxhands_weapon_bridge.reds"
        shutil.copyfile(bridge, inputs / bridge.name)
    result = work / "overlay.redscripts"
    subprocess.run([str(args.compiler.resolve(strict=True)), "compile", "-s", str(inputs), "-b", str(bundle), "-o", str(result)], check=True)
    if hashlib.sha256(bundle.read_bytes()).hexdigest() != digest:
        raise SystemExit("the input changed while compiling; no overlay installed")
    for destination, xml in inputs_xml.items():
        staged = work / destination.name
        staged.write_text(xml, encoding="utf-8")
        staged.replace(destination)
    result.replace(output)
print(f"Private overlay compiled from input SHA-256 {digest}: {output}")
