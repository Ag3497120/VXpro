# VXpro

Run Mac App Store games (Cyberpunk 2077) in VR on Apple Vision Pro — head look, depth reprojection, Neural Engine
foveated upscaling. Free, MIT.

[English](README.md) · [日本語](README_ja.md) · [简体中文](README_zh-Hans.md) · [繁體中文](README_zh-Hant.md) · [한국어](README_ko.md)

VXpro runs the **Mac App Store version of Cyberpunk 2077** on the **Vision Pro by itself**. The Mac build of the game is
arm64 Metal code, like visionOS, so it runs natively: no emulation, no translation, no streaming, no PC. A host app
(VX Mac Host) loads the game's code, replaces the macOS-only libraries it uses with small shims, and shows its frames in
an immersive space: in 3D gameplay your head turns the game's camera and each eye is reprojected at 90 Hz from the
game's depth; menus, cutscenes and loading screens are on a panel fixed in your room.

**Status: Preview 0.3** (experimental, 2026-11-01). Main menu, character creation and the opening of the game run on an M2
Vision Pro at reduced settings, about 20-30 fps from the game with 90 Hz reprojection.

## What's new in Preview 0.3

- **Long-session crash fixed.** The audio HAL path is now off by default (`VXMAC_AUDIO_HAL=1` restores it). In an A/B on
  the headset the app was near the 8 GB memory limit after 51 minutes before the fix; after it, memory stayed flat at
  about 5.8 GB.
- **Recommended resolution: 1280x720 native, FOV 110.** Noticeably smoother than 1600x900: about 11 -> 17 fps in fights
  on M2.
- **Aiming fixes**: no more false switches to the vehicle mode while aiming down sights or strafing; the pitch no longer
  gets stuck (you can look down again); the pitch drift is reset; the head pose is held while tracking is lost.
- **New experimental options** (off by default): `VXMAC_AIM=1` (warp mode 7), `VXMAC_GPU_CAP_HALF=0.85`,
  `VXMAC_INTERP=vel` / `=1`, `VXMAC_PASS_PROFILE=1` (see the guide's "Options").

VXpro is the Mac App Store route of [VeRantyx](https://github.com/Ag3497120/VeRantyx), where the Windows/Steam route
(VXRuntime) lives.

## You need

> **Game versions:** Cyberpunk 2077 **2.5.0** (the latest Mac App Store update; the App Store lists it as version **1.0.4**, which is its own numbering — the game inside is 2.5.0) and **2.3.2**, both tested on the headset. English voice is included; other voice languages need their voice archives, which are not supported yet for 2.5.0 (its other voices are Apple-hosted downloads). Subtitles and menus work in every language.

- an **Apple Vision Pro** in Developer Mode, paired with your Mac, with **about 85 GB free** for 2.5.0 (its data is about 80 GB; 2.3.2 with all voice languages needs about 160 GB);
- a **Mac with Apple silicon**, **Xcode 26** with the visionOS SDK, `xcodegen`, Python 3;
- your **own paid Apple Developer Program account** (the app needs the Increased Memory Limit and Extended Virtual
  Addressing entitlements; you sign it with your own team);
- your **own, purchased copy of Cyberpunk 2077 from the Mac App Store, version 2.5.0 or 2.3.2**, installed on the Mac.

## Get started

```sh
tools/vxmac_cyberpunk.py doctor  --game "/Applications/Cyberpunk2077.app"
tools/vxmac_cyberpunk.py prepare --game "/Applications/Cyberpunk2077.app" --team <YOUR_TEAM_ID>
tools/vxmac_cyberpunk.py build && tools/vxmac_cyberpunk.py install
tools/vxmac_cyberpunk.py copy && tools/vxmac_cyberpunk.py launch
```

The full guide, with what each step does, the controls, the options and troubleshooting:
[docs/VISION_PRO_CYBERPUNK_MAC.md](docs/VISION_PRO_CYBERPUNK_MAC.md). How it works and its history:
[docs/DESIGN.md](docs/DESIGN.md).

In the headset: **pinch with both hands for 1 s and let go** to switch between VR and the world-fixed Screen whenever an
automatic switch is wrong; **pinch with one hand for 1 s** in VR to cycle the warp mode. **To quit, hold the both-hands
pinch for 3 s, then pinch with both hands again** when "Quit? Pinch both hands again" shows: the game quits through
its own path (as Cmd+Q on a Mac) and the app closes. See "Controls in the headset" in the guide.

> **Never delete VX Mac Host from the headset**: that deletes the copy of the game's data (about 80 GB) and your saves.
> **Save often**: the game runs close to visionOS's memory limit.

## What VXpro does not do

- It does **not distribute any game file** or anything made from one. Your copy is prepared on your Mac, signed with
  your team and copied to your headset only. Do not share the built app: it contains the game's code.
- It does **not bypass DRM, StoreKit or ownership checks**. It never writes to the App Store bundle and does not touch
  the receipt, StoreKit, Game Center, iCloud or GOG accounts. Use it only with a copy you bought, for yourself.
- It is **not affiliated with CD PROJEKT RED or Apple**. Cyberpunk 2077 is a trademark of CD PROJEKT S.A.;
  Apple Vision Pro, visionOS and Mac App Store are trademarks of Apple Inc.

## Known issues (Preview 0.3)

- Quit with the both-hands pinch (3 s + again) or the app window's **Quit game** button. Closing the app instead pauses
  the game and asks it to quit after 10 s, which may not complete in the background; do not force-quit it while it saves.
- The display can lock at about 45 Hz when the headset gets hot or the warp misses frames: let the headset cool down.
- Other voice languages on 2.5.0 are not supported yet (English voice works; subtitles and menus in every language).
- Recommended: 16:9, **1280x720 native**, FOV 110 (`fov --max 110` + `settings`; see the guide).
- The first copy of the game's data is large and slow (about 80 GB for 2.5.0).
- A paid Apple Developer Program membership is required, even though nothing goes to the App Store. The reason is two entitlements: without **Increased Memory Limit**, visionOS caps the app at about 5 GB and the game (6-8 GB) is shut down while loading; **Extended Virtual Addressing** is needed because the game reserves a very large virtual address range up front. As far as we know, free (Personal Team) accounts can't sign these two (not tested ourselves; reports welcome). Free signing also expires every 7 days.

## Known limitations

- **Frame rate**: about 20-30 fps from the game. Head motion stays smooth (90 Hz reprojection), but fast turns and
  moving objects show the low rate.
- **HUD**: the corners (minimap, quests, health) are near the frame's edges and hard to see in VR; `VXMAC_HUD=1` or the
  game's HUD safe zone help.
- **Bottom border**: the game's frame covers less than the eye's view; the rest (mostly below) is filled with a dimmed,
  older panorama of the scene (`VXMAC_VR_CACHE`), not the live game.
- **Memory**: about 6.5 GB of the ~8.2 GB the app may use; higher settings can end the app.
- **Tested builds** 2.5.0 and 2.3.2 (checked by hash); offline only (no Game Center, iCloud saves or GOG); no mods, ray
  tracing or HDR; development signing has to be renewed when your profile expires.
- The Neural Engine features are built in but **off by default**: `VXMAC_FSR=1` (foveated super-resolution),
  `VXMAC_FOVEATE=1` (compositor foveation). Others: `VXMAC_VEL`, `VXMAC_NPU`, `VXMAC_VR_CACHE`, `VXMAC_VR_VIGNETTE`,
  `VXMAC_VR_ZOOM`, `VXMAC_STICK_PITCH` (see the guide's "Options").

## Safety

VX Mac Host is not a sandbox: the game's code runs natively with the app's permissions. Run only software you own and
trust. VR can be uncomfortable: take breaks.

## Licence

MIT ([LICENSE](LICENSE)). Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Built by one person with AI coding agents. Community: [VeRantyx](https://github.com/Ag3497120/VeRantyx).
