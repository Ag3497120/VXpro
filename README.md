# VXpro

**Controller / hand-tracking integration · 2026-11-10.** `main` now includes the accumulated hand-tracking,
performance, camera and direct cloud-save changes. Switch between standard controller weapon handling and
Joy-Con-assisted tracked hands during play; both modes keep VR head tracking. This remains an experimental preview.

[English](README.md) · [日本語](README_ja.md)

**Community:** [Join the VeRantyx / VXpro Discord](https://discord.gg/h2znwYJt3) for setup help, bug reports and development discussions.

## Current hand-tracking state

ARKit hand/wrist tracking drives the existing arm, hand and weapon bones through custom Metal rendering hooks.
Joy-Con buttons provide movement, firing and other explicit actions. This is an experimental, controller-assisted
hand-tracking implementation, with weapon-specific compatibility still being tested.

- **Live mode switch:** hold Joy-Con **+ and − together for one second**, then release both before switching again.
  Single presses keep their menu behavior. Switching releases synthetic held inputs and restores native weapon
  rendering/reload handling in controller mode. The player confirmed that the physical mode switch works.
- **Menu presentation:** the quick menu uses one presentation plane during transitions, as do load/save screens.
- **Tracked melee:** swinging an equipped melee weapon sends an attack. Grip placement is still incomplete on some weapons.

- The weapon stays in the right hand. ZR fires. On long guns, holding ZL requests left-hand support and ADS;
  releasing it releases both. Reload interactions take priority over support.
- X requests magazine ejection. The script/equipment bridge supports magazine pickup/insertion, manual pistol
  slide interaction and automatic chambering for non-pistols. A signed app may embed a matching private reload overlay;
  the source includes the compiler helper, not the compiled game cache.
- Hand/weapon corrections use bounded independent GPU buffers and preserve the game's source palettes.
- The accepted head-turn fix captures camera view and projection together on the owning Metal command buffer,
  then uses that same snapshot when submitting the image. The user reported the walking head-turn rebound
  completely resolved in the latest headset test.
- Ordinary VR peripheral coverage has also been restored, with the user confirming the picture no longer has
  the reported gaps and the head-turn rebound has not returned. The November 9 vehicle follow-up is described below.
- The November 9 follow-up rejects invalid world-camera samples, and the user reports VR-only blackouts gone.
  Vehicle peripheral coverage and steering handling were improved; VR vertical look now uses the head only,
  with accelerator/brake/steering input paths retained. The user reported improvement after the installed update.
- Opt-in direct CDPR sign-in and cloud-save download/load have been confirmed on the headset. Startup account
  restoration is included; upload roundtrip and broader save compatibility still need verification.
- **Known issues:** rectangular image borders may remain in story/constrained camera views; all vehicle scenes are unverified.
  Individual weapons, support spacing, sight/scope attachment and reload/slide visuals still need polish and verification.
  Detached sleeves, some melee grips and scope lenses remain reported issues. The extra handgun fingers were reported
  resolved in the latest test; the other visual issues are not claimed fixed. Barrel-directed shot integration remains experimental.

## Performance checkpoint

A **60-second M2 test averaged 37.1 new game images per second** (the user identified the session as Phantom Liberty).
The game submission counter measured 37.0 FPS over its sampling span. This is one session, not a minimum across scenes,
and it predates the latest camera fix. **45 FPS is the next target, not an achieved result.**

The source now includes frame pacing, bounded image slots, scheduled warp release, demand-driven history copying,
and the profiling/comparison tools used during development. The tested hand build uses four image slots.
See [release notes and tested settings](docs/RELEASE_2026_11_08.md) for the opt-in runtime flags and verification scope.

Some testers find the headset view smoother than recordings. System reprojection or other display processing may
contribute, but the cause and effective display cadence are unconfirmed; they are not added to the measured game FPS.
NPU/weight-edit/frame-generation work is included as experimental tools; models remain disabled in the measured setup,
and no NPU FPS gain has been established.

Implementation and controls: [HAND_SESSION.md](HAND_SESSION.md), [design notes](docs/DESIGN.md).
Current fixes, settings and limits: [2026-11-09 checkpoint](docs/RELEASE_2026_11_09.md).
Latest integration and verification: [2026-11-10 update](docs/RELEASE_2026_11_10.md).
Historical FPS evidence: [2026-11-08 release notes](docs/RELEASE_2026_11_08.md).
Optional direct account/cloud setup: [DIRECT_CLOUD.md](DIRECT_CLOUD.md).
Experiments: [frame pipeline](FRAME_PIPELINE.md), [NPU offload](NPU_OFFLOAD_RESULT.md), [weight editing](NPU_WEIGHT_EDIT.md).

## Graphics recovery: blurred picture or smeared head turns

Check the game's **Video / Graphics settings** if the picture becomes blurred, head turns leave a strong smear,
or performance changes after adjusting graphics options. Replacing or rolling back the app does not necessarily
restore the settings saved inside its container.

The November 8 audit found the following differences. Restoring the low-effects profile without changing the app
was followed by the user's confirmation that picture quality and head motion had returned to the previous state.

| Setting | Observed during the regression | Recovery baseline |
| --- | --- | --- |
| Output resolution | 1280×720 | **1280×720 native** |
| Resolution scaling / dynamic resolution / frame generation | Off at the audited launch | **All Off** |
| Motion Blur | High | **Off** |
| Film Grain / Chromatic Aberration / Depth of Field | On | **All Off** |
| Texture Quality | High | Low |
| Screen Space Reflections | Ultra | Off |
| Ambient Occlusion / Contact Shadows | High / On | Off / Off |
| Shadow Mesh / Cascaded Shadows / Distant Shadows | High | Low |
| Local Shadows | High | Off |
| Volumetric Fog / Volumetric Clouds | Ultra / Ultra | Low / Off |
| Subsurface Scattering / Maximum Dynamic Decals / Level of Detail | High / Ultra / High | Low / Low / Low |
| Color Precision / Anisotropic Filtering | High / 16× | Medium / 4× |
| Mirror Quality / Crowd Density / Facial Tangent Updates | High / High / On | Low / Low / Off |
| Field of View | 110 | Keep 110 |

**MetalFX is not established as the sole cause.** At that audited launch, `ResolutionScaling` was `Off` and no
temporal-scaler encodes were recorded, even though the saved MetalFX quality option said `Quality`. The restored
file says `Performance`, but that sub-option is inactive while scaling is off; enabling MetalFX Performance is
**not** the recovery instruction. A separate earlier capture had 1280×720 output with an **853×480 internal surface**,
so the output-resolution label alone does not establish native rendering.

Use the in-game menus to apply this baseline. For an external edit, save and quit the game first, back up your own
`Library/Application Support/CD Projekt Red/Cyberpunk 2077/UserSettings.json` from the host's app container,
and change only graphics/crowd options. Preserve other settings, saves and account data. Restart and check the
settings again; do not delete VX Mac Host to reset graphics.

This is a **recovery baseline, not a complete snapshot of the historical 37.1 FPS test or a promised frame rate**.
VR-only blackouts remained after the settings recovery and were addressed separately by the camera fix described
in the [November 9 checkpoint](docs/RELEASE_2026_11_09.md). Vehicle/story borders also need separate diagnosis.
Development evidence: `20261108T125547Z-graphics-settings-audit-restore/o1,o2,o3,o5` and
`20261108T214855Z-graphics-restored-vr-camera-preflight/d1`; raw logs and personal settings are not distributed.

## Switching controls during play

Hold **+ and − together for one second**. No app restart or save reload is required. Release both buttons to
rearm the shortcut. Release firing/support buttons too when changing modes: the new owner waits for neutral inputs.
To start with native controller weapons, launch with `--env VXMAC_CONTROL_MODE=controller`.

One mode owns gameplay input at a time. Switching preserves the equipped weapon and actual ammunition; it does not
grant ammunition or reload a save. Local tests cover held-input release, script acknowledgement, native binding
restoration and repeated switches. Broader weapon/reload/vehicle combinations still need testing.

## Get the current version

```sh
git clone https://github.com/Ag3497120/VXpro.git
cd VXpro
```

The base setup below prepares your own purchased game. Hand interaction is experimental and opt-in;
see the tracked-hand weapon section of the [design notes](docs/DESIGN.md) for the environment options
and matching manual-reload overlay. Regenerate the Xcode project after updating sources.

Weapon-specific bindings on the tested installation use a **locally generated numeric catalog**.
Game meshes, extracted metadata, compiled overlays, model weights, recordings and built apps are not included.
`tools/weapon_asset_catalog.py` can generate `build/hand-session-v2/weapon_asset_catalog.h` from your own
fully unpacked CR2W mesh resources; the external-buffer extraction utility is not bundled.
Without that private catalog the source builds with the existing generic fallback, which does not reproduce
all of the tested installation's weapon-specific contacts. Run `sh tools/check_hand_session.sh` for local checks.

## Base runtime and setup

The Preview 0.3 notes below describe the original controller preview. The integrated controls and measured
performance above are newer; historical rates and controls below are not a guarantee for this branch.

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
- **Tested builds** 2.5.0 and 2.3.2 (checked by hash). The original preview was offline-only. The current version adds
  opt-in direct CDPR cloud-save support as described above; Game Center/iCloud synchronization is not established.
  Ray tracing/HDR remain unsupported. Development signing expires with your profile.
- The Neural Engine features are built in but **off by default**: `VXMAC_FSR=1` (foveated super-resolution),
  `VXMAC_FOVEATE=1` (compositor foveation). Others: `VXMAC_VEL`, `VXMAC_NPU`, `VXMAC_VR_CACHE`, `VXMAC_VR_VIGNETTE`,
  `VXMAC_VR_ZOOM`, `VXMAC_STICK_PITCH` (see the guide's "Options").
- **Eye-tracked foveated rendering is not enabled.** The display-side experiment did not improve FPS with the current
  pipeline. Game-side foveation remains future optimization work; no ETFR or NPU performance gain is claimed.

## Safety

VX Mac Host is not a sandbox: the game's code runs natively with the app's permissions. Run only software you own and
trust. VR can be uncomfortable: take breaks.

## Licence

MIT ([LICENSE](LICENSE)). Third-party notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Built by one person with AI coding agents. Community: [VeRantyx](https://github.com/Ag3497120/VeRantyx).
