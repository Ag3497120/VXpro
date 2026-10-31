# Cyberpunk 2077 standalone on Apple Vision Pro: the Mac App Store route (Preview 0.1)

[日本語](VISION_PRO_CYBERPUNK_MAC_ja.md)

**VXpro** (the VX Mac route of [VeRantyx](https://github.com/Ag3497120/VeRantyx)) runs the **Mac App Store version of Cyberpunk 2077** on the **Vision Pro itself**: no PC, no
Mac in the loop once it is started, no streaming. The Mac build of the game is arm64 Metal code, like visionOS, so
VX Mac runs that code as it is, natively: no emulation and no translation. The game is shown in an immersive space,
in VR: your head turns the game's camera, and menus appear on a panel fixed in your room.

This is an **experimental preview** for people who are comfortable with Xcode and the command line. It is the guide
for doing it with **your own** copy of the game, on **your own** headset, signed with **your own** Apple developer
team. Nothing of the game is distributed by VXpro. Technical background and history:
[`DESIGN.md`](DESIGN.md). (The other route, the Windows/Steam version through VXRuntime, is in
[VeRantyx](https://github.com/Ag3497120/VeRantyx).)

> **Never delete VX Mac Host from the headset** (and never install it with `--remove-existing-content`). Deleting
> the app deletes its container: the ~158 GB copy of the game's data **and your saves**. Re-installing with
> `tools/vxmac_cyberpunk.py install` keeps them.

> **Save often.** The app runs close to visionOS's memory limit for one app (see "Limits"). If visionOS ends it,
> everything since your last save is lost. Use the game's manual save before long sessions, at least as often as
> you would on a handheld.

## What it does today

| | |
|---|---|
| Main menu, character creation | yes |
| In game | yes (tested: the opening, indoors; further areas are not tested yet) |
| Picture | VR: the game's camera follows your head yaw/pitch; each eye is reprojected at the compositor's 90 Hz |
| Game frame rate | about 20-30 fps (the game's own rate; the 90 Hz reprojection keeps head motion smooth) |
| Menus, cutscenes, loading | on a world-anchored panel in front of you, in a dark surround (placed again when you look back) |
| Switching | automatic: VR while the game's camera follows the mouse look, the panel otherwise, with a short fade |
| Input | game controllers (Joy-Con tested), hand pointer on the panel, Bluetooth keyboard / mouse |
| Memory | about 6.4-6.6 GB in game of about 8.2 GB the app may use |

> Tested on a Vision Pro (M2) with visionOS 26: 1280x720 (`p720fixed`) for the frame rates above, sound works, played through the opening of Phantom Liberty (Dogtown, Songbird), and launching from the headset's Home View works the same as `launch` from the Mac.

## What it needs

> **Game version:** right now only Cyberpunk 2077 **2.3.2** (the Mac App Store build from 2025) is supported. The latest Mac App Store update (App Store version 1.0.4, released 2026-10-22) is **not supported yet — support is coming soon.** If your copy has already updated, the tool stops at `doctor` / `prepare` without changing anything.

- **Apple Vision Pro** with **Developer Mode** on (Settings > Privacy & Security > Developer Mode), paired with the
  Mac in Xcode (Window > Devices and Simulators). The app targets visionOS 26.0 and later; tested on an M2 Vision Pro.
- **About 160 GB free on the headset**: the game's data is 158.5 GB (decimal; Phantom Liberty and all voice
  languages included), plus the app. Check in Settings > General > Storage: the Mac cannot read the headset's free
  space. If you also have the Windows route installed, it keeps its own ~67 GB.
- **A Mac with Apple silicon**, **Xcode 26** or later with the visionOS SDK, `xcodegen` (`brew install xcodegen`),
  Python 3, and **about 5 GB free** for the work copies and the build. Clone the repository into a path
  **without spaces**.
- **A paid Apple Developer Program membership.** The app needs the *Increased Memory Limit* and *Extended Virtual
  Addressing* entitlements; Xcode's automatic signing adds them to your App ID, which a free personal team cannot do.
  The app is signed with **your** team and **your** bundle id.
- **Cyberpunk 2077 from the Mac App Store, version 2.3.2**, that you bought, installed on the Mac (anywhere the Mac
  can read, e.g. an external drive). Its executable `Contents/MacOS/Cyberpunk2077` must be exactly this build:
  `sha256 3907f316f6adf9dd8188be82aeea9ae161445b2e1f6d25cf08c87b8a3ae6b421`. `doctor` checks it. Other versions
  (other patches, Steam / GOG / Epic Mac builds) are refused.
- **Time**: the build takes minutes; copying 158 GB to the headset over the network takes longer (devicectl ran at
  roughly 30-40 MB/s on the Windows route: plan on one to two hours or more; keep the headset awake and on the
  same network).

> The copy time on this route hasn't been measured yet; plan for one to two hours or more.

## The tool

Everything goes through one guided tool, run from the repository's root:

```sh
tools/vxmac_cyberpunk.py doctor  --game "/Applications/Cyberpunk2077.app"
tools/vxmac_cyberpunk.py prepare --game "/Applications/Cyberpunk2077.app" --team <TEAMID> [--bundle-id <id>] [--device <id>]
tools/vxmac_cyberpunk.py build
tools/vxmac_cyberpunk.py install
tools/vxmac_cyberpunk.py copy                  # resumable; then every file's size is checked
tools/vxmac_cyberpunk.py launch
tools/vxmac_cyberpunk.py fov --max 110         # optional: see "Recommended settings"
tools/vxmac_cyberpunk.py settings --profile p720fixed --set FieldOfView=110
tools/vxmac_cyberpunk.py pull --tag t1         # logs back to the Mac
```

`install`, `copy`, `settings`, `launch` and `pull` take `--dry-run` (they print the `devicectl` commands and run
nothing on the device). Everything the tool makes goes into `build/cyberpunk/` (ignored by git).

> Note: the guided tool is new in this preview and hasn't been run end to end by other people yet. If a step fails, please open an issue with its output (remove personal details first).

### What each step does

1. **Your original game is never modified.** `prepare` reads the App Store bundle and writes **work copies** of the
   game's four code images (`Cyberpunk2077`, `libGameServicesAppStore`, `libBink2MacArm64`, `libREDGalaxy64`) into
   `build/cyberpunk/prepared/`. In the copies only the load commands change: the platform (macOS to visionOS),
   the library paths (macOS-only libraries to VX Mac's shims), the code signature (removed: your build signs them),
   and the executable becomes a dynamic library the host app can load. In the executable's copy, 15 instructions
   that set the sizes of the engine's memory pools are changed (the same change as the Windows route: 64 to 16 GB,
   32 to 8, 16 to 8, each 4 GB pool to 1 GB), because a visionOS app has far less address space than a Mac. This
   is keyed by the executable's SHA-256 and refused for anything else. It changes no DRM, store, online or save code.
   Then it builds the shims and checks that every symbol the copies import is found on visionOS.
2. **build**: `xcodegen` and `xcodebuild` for VX Mac Host, with your team and bundle id (default
   `com.<team>.VXMacHost`), the work copies embedded and signed with your identity; then a check that the copies
   are embedded and both entitlements granted. The built app contains the game's code: **do not share it**.
3. **install**: `xcrun devicectl device install app` only. An update keeps the app's container (the data, saves).
4. **copy**: the game's `Contents/Data` into the app's container, `Documents/Cyberpunk2077.app/Contents/Data`:
   `engine` and `r6` first, then each archive, one `devicectl device copy to` per item, eight tries each, done items
   remembered so that running `copy` again resumes. `archive/Mac` becomes `archive/mac` on the headset (the game
   asks for lower case and visionOS's file system is case-sensitive). Then every file's size on the headset is
   compared with your install. Only the data folder is copied: no saves, no settings, no account data. Do not
   `install` while a copy runs (it closes the copy's connection).
5. **launch**: `devicectl device process launch` of your bundle id. Wear the headset, unlocked. The host finds the
   data, starts the game on a thread of its own and opens the immersive space. `--restart` ends a running copy
   first (**unsaved progress is lost**).
6. **settings** (optional): the game writes `UserSettings.json` on its first run. `settings` takes it from the
   headset, keeps the old one in `build/cyberpunk/settings/`, applies a GPU-budget profile (`p900`, `p720`,
   `p720fixed`: output resolution and dynamic resolution, with ambient occlusion, local and contact shadows and
   motion blur off) and puts it back. Only while the game is not running: the game saves its own settings on exit.
7. **pull**: `vxmac_host.jsonl` (the host's events, memory every 2 s) and `vxmac_program.log` (the game's output)
   into `build/cyberpunk/logs/<tag>`. They contain file paths and device details: read them before posting them.

## Recommended settings

| setting | value | why |
|---|---|---|
| aspect | 16:9 | the presenter's projection assumes the game's 16:9 frame |
| resolution | **1280x720, MetalFX Performance**, dynamic resolution off | keeps the headset at 90 Hz; 1600x900 gives about 40 Hz on M2 |
| field of view | **110** | covers more of the eye's view; the game's slider stops lower, so raise its range first |

```sh
tools/vxmac_cyberpunk.py fov --max 110                                  # patch_fov.py 110: the slider's range, in the headset's work copy only
tools/vxmac_cyberpunk.py settings --profile p720fixed --set FieldOfView=110
```

Both only while the game is not running. `fov` changes the FieldOfView slider's maximum in the work copy's
`r6/config/settings/platform/mac/options.json` on the headset (never the App Store bundle); the file before is kept in
`build/cyberpunk/settings/` and `tools/patch_fov.py restore <file>` puts it back.

The `settings` profiles (`tools/cp_settings.py`; all of them also turn off ambient occlusion, local and contact
shadows, motion blur and facial tangent updates):

| profile | output | upscaling |
|---|---|---|
| `p720fixed` (recommended) | 1280x720 | MetalFX Performance, fixed |
| `p720` | 1280x720 | dynamic resolution 50-65 % |
| `p720b`, `p720q` | 1280x720 | MetalFX Balanced / Quality (heavier) |
| `p900`, `p900perf` | 1600x900 | dynamic resolution / MetalFX Performance (about 40 Hz on M2) |
| `tall1040*` | 1040x1004 | experiments with a near-square frame (not recommended) |

`--set NAME=VALUE` sets any other option by its name, e.g. `HudSafezoneHor=0.5` (HUD further in), `HudScaling=110`.

## Controls

- **Head**: in 3D gameplay your head's yaw and pitch turn the game's camera (sent to the game as mouse motion);
  between the game's frames the compositor reprojects each eye at 90 Hz. In menus, cutscenes and loading screens
  the game is on the panel; see "Controls in the headset" below to switch by hand.
- **Controller** (any controller visionOS supports; Joy-Con tested): the game's own Mac controller support. While
  your head controls the camera, the **right stick turns only left / right (yaw)**; its up / down is ignored so that
  pitch stays with your head.
- **Hands**: on the panel, point to move the pointer, pinch to click, pinch and move up / down to scroll.
- **Keyboard / mouse**: a Bluetooth keyboard and mouse reach the game as Mac input.

> Not yet available: a recentre control. Joy-Con were used for this preview; other controllers are untested.

## Controls in the headset

Hand gestures that VX Mac Host reads itself. In head-look (VR) your pinches never reach the game.

| Gesture | What it does |
| --- | --- |
| **Both hands pinch at the same time, held 1 s, then let go (before 3 s)** | Switches between **VR** (head-look) and **Screen** (the game on a world-fixed panel you can look around). A 1 s label shows "VR" or "Screen". Use it whenever an automatic switch below is wrong. Back in VR, your head's up / down angle is sent to the game afresh. A forced VR ends by itself once the automatic choice is VR again. |
| **One hand pinch held 1 s** (in VR) | Cycles the warp mode (how the picture follows your head between the game's frames). A 1 s label shows the mode. |
| **Both hands pinch held 3 s, then both hands pinch again** | Quits the game safely. At 3 s "Quit? Pinch both hands again" shows for 6 s; a both-hands pinch then quits (no VR / Screen switch happens). |

### Quitting safely

- **In the headset**: hold the both-hands pinch for 3 s, then pinch with both hands again. Or tap **Quit game** in the
  app's window (it shows when the app is opened and before the immersive view opens).
- Either way the game quits through its own path, exactly as Cmd+Q / the Quit menu on a Mac (`[NSApp terminate:]` into
  the game's `applicationShouldTerminate:`): its shutdown runs, then the app closes. Nothing is killed.
- **If you just close the app** (Digital Crown, or the app goes to the background): the game is paused at once (no GPU
  work, inactive), and after 10 s in the background it is asked to quit the same way. Coming back within 10 s resumes.
  `VXMAC_BG_QUIT_S=<s>` changes the delay (0: never).
- Save in the game before quitting; never force-quit the app while the game is saving.

The warp modes, in the order the pinch cycles them. The label shows the number and the name, for example
"Mode 6: rotation + fixed stereo" (in your device's language).

| Mode | Name | What it does | Distortion | Stereo depth | When to use |
| --- | --- | --- | --- | --- | --- |
| **6** (default) | Rotation + fixed stereo | Rotates the whole frame with your head; each eye's offset from the game's depth at a constant half eye distance | None | Yes | Normal play |
| 2 | Rotation only | Rotates the whole frame; no depth | None | No (flat, at infinity) | Stability over depth |
| 5 | No warp | The frame as the game rendered it (like turning with the controller) | None | No | Comparison; about 0.1 s of lag when you turn |
| 0 | Depth + head position | Per-pixel reprojection from the game's depth, including your head's movement | Visible (rubbery) | Yes | Theoretically the most exact |
| 1 | Depth, rotation only | Mode 0 without head movement | Some | Yes | |
| 3 | Depth + head position (3 cm) | Mode 0 with head movement limited to 3 cm | Some | Yes | |
| 4 | Camera from the picture | The camera's orientation measured from the picture's motion | Varies | Yes | Experimental |

What switches automatically:

- **HUD**: the game's UI (minimap, quest, ammo, pickups, tutorial popups) is taken off the scene and shown as one
  panel in front of you, about +-28 degrees wide, so nothing sits in the far corners. Subtitles are shown a little
  below the centre.
- **Menus and guides over the scene** (radio, phone, large popups): the whole frame (scene and menu) is shown on a
  centred panel (+-30 degrees) over a dark backdrop.
- **Cutscenes**: when the game ignores your head for about 9 seconds (no response at all), the game moves to the
  world-fixed Screen; VR comes back when the picture follows your head again.
- **Menus, loading and logos**: the Screen.

Tip for vehicles: use the game's **first-person driving camera**. The third-person vehicle camera orbits and
re-centres by itself, so it cannot follow your head one to one.

## Options (environment toggles)

Pass them at launch, `tools/vxmac_cyberpunk.py launch --env NAME=VALUE` (repeatable), or put `-env NAME=VALUE` lines in
`Documents/vxmac_args.txt` in the app's container (also used when the app is opened from the Home View).

| variable | default | what |
|---|---|---|
| `VXMAC_FSR=1` | off | foveated super-resolution of the frame's centre on the Neural Engine (needs the model: `build` makes it with coremltools) |
| `VXMAC_FSR_CROP`, `VXMAC_FSR_MODEL` | model size, `vxfsr_512x288` | the SR crop's share of the frame's width; the model's name |
| `VXMAC_FOVEATE=1` | off | CompositorServices foveation (denser centre) |
| `VXMAC_HUD=1` | off | the HUD's corner regions drawn again near the centre (or `"u0 v0 u1 v1 x y s; ..."` for your own) |
| `VXMAC_VEL=0` | on | the game's own velocity buffer as motion vectors (only after it is verified against the picture) |
| `VXMAC_NPU=1` / `0` | off | optical flow between frames (Vision) as motion vectors when the game's own are not used |
| `VXMAC_VR_CACHE=0`, `VXMAC_VR_CACHE_DIM` | on, 0.8 | the room panorama outside the game's frame; its brightness |
| `VXMAC_VR_VIGNETTE` | 0.93 | where the frame's edge starts fading (0 off) |
| `VXMAC_VR_ZOOM` | 1.0 | the frame's angular size against the game's FOV |
| `VXMAC_STICK_PITCH=1` | off | keep the right stick's up / down in head control |
| `VXMAC_GPU_WORKING_SET_MB` | 4096 | the GPU memory the game is told it has |
| `VXMAC_AUTO_SCREEN=0` | on | cutscenes (the game ignoring your head) stay in VR instead of switching to Screen: the picture stays world-locked and nothing is sent to the game until it follows again. Also remembered from the headset: switch to **VR** with the both-hands pinch while a cutscene's Screen shows (label "VR: cutscenes stay in VR"); switch to **Screen** in VR to turn the automatic switch on again |

Other `VXMAC_*` variables in the sources are debugging switches; see [`DESIGN.md`](DESIGN.md).

## Known issues (Preview 0.1)

Each item is independent; fixed ones will be removed from this list.

- **Game 2.5.0 (when supported): English voice only** (subtitles and menus in every language work): its other voice
  languages are Apple-hosted downloads that only the App Store app itself can fetch.
- **Quit with the both-hands 3 s pinch** (see "Quitting safely"): closing the app pauses the game and asks it to quit after
  10 s, which may not complete in the background.
- **1600x900 runs at about 40 Hz on M2**: use the recommended 1280x720 (see "Recommended settings").
- **The first copy of the game's data is large and slow** (158 GB over the network).
- **A paid Apple Developer Program membership is required** (a free account can't grant the two entitlements the
  app needs). The signing profile still expires eventually; renew it with `build` + `install`.

## Limits

- **One exact build**: Cyberpunk 2077 2.3.2 from the Mac App Store (the hash above). A game update changes the
  executable: `prepare` then refuses it until VX Mac supports the new build. Keep the version you prepared.
- **Memory**: about 8.2 GB for the app, Metal included; the game uses about 6.4-6.6 GB in game at reduced settings
  (it is told a 4 GB GPU working set). Higher settings or busier areas can cross the limit and visionOS ends the app.
- **Frame rate**: about 20-30 fps from the game; head motion stays smooth through reprojection, but fast turns and
  moving objects show the low game rate (judder, edges).
- **Offline only, no Apple or CD PROJEKT RED online services**: re-signing with your team drops the game's Game
  Center and iCloud entitlements, so Game Center reports a signed-out player and there are no cloud saves; GOG
  Galaxy and the game's network requests are offline. Saves are local, in the app's container on the headset.
- **Developer signing**: when your provisioning profile expires the app stops opening: run `build` and `install`
  again (the data and saves stay).
- **No mods**, no ray tracing, no HDR. The game's attempt to run a shell command at startup fails harmlessly
  (visionOS has no shell).
- **HUD**: the game's HUD corners (minimap, quests, health) sit near the edges of the frame, where they are hard to see in
  VR. Options: the game's own HUD safe zone (`settings --set HudSafezoneHor=0.5`), or `VXMAC_HUD=1` (the corner regions
  drawn again near the centre).
- **Below and around the frame**: the game's picture covers less than the eye's view (about half of it below the frame at
  FOV 100). That area is filled with a dimmed panorama of the room the game showed (`VXMAC_VR_CACHE`), not the live
  game: it lags and can look stale; `VXMAC_VR_CACHE=0` shows black instead.
- The Neural Engine features (foveated super-resolution, compositor foveation) are in the build but **off by default**
  until they are verified on more headsets (see "Options").

## What is NOT distributed, and what is not bypassed

This repository contains no game file and nothing made from one:

- **no game files** (executable, libraries, archives, settings): you copy your own install to your own headset;
- **no prepared images**: the work copies are made on your Mac from your bundle and signed with your team;
- **no shaders, caches or logs** from anyone's run.

What the repository does contain about the game: the executable's SHA-256, the file offsets with the original and
new values of the 15 pool-size instructions (`tools/macho_prepare.py`), the names of the four images, the data
layout, and the names and values of the settings `settings` changes.

VX Mac does not remove, emulate or work around any copy protection or ownership check. The Mac App Store build's
executable carries no FairPlay encryption; VX Mac does not touch the App Store receipt, StoreKit, Game Center,
iCloud or GOG accounts, and never writes to the App Store bundle. Use it only with a copy you bought, for yourself.
VXpro and VeRantyx are not affiliated with CD PROJEKT RED or Apple; Cyberpunk 2077 is a trademark of CD PROJEKT S.A.

> This guide is not legal advice. Check the game's and the Mac App Store's terms yourself.

## Safety

- **VX Mac is not a sandbox.** The game's code runs natively with the full permissions of the VX Mac Host app: its
  container, the network, and the hand-tracking / world-sensing permissions you grant it. visionOS's app sandbox is
  the only boundary. Run only software you own and trust.
- The tool never deletes anything on the headset and never uninstalls the app. On the Mac it writes only into
  `build/`; your install is read only.
- The headset gets warm and the app uses most of its memory: take breaks. If VR makes you uncomfortable, stop.

## Troubleshooting

| Symptom | What to do |
|---|---|
| The app closes during play | most likely visionOS's memory limit: load your last save, use `settings --profile p720fixed` (the recommended one), avoid long sessions without saving. `pull` and look at `footprint_mb` and `available_mb` in the last `stats` lines of `vxmac_host.jsonl` |
| `prepare`: "not Cyberpunk 2077 2.3.2" | another build of the game: only 2.3.2 from the Mac App Store is supported |
| `build`: signing errors / missing entitlements | a paid team (`doctor`), a bundle id of your own (`prepare --bundle-id`), Xcode signed in to your account |
| `copy` stops | run `copy` again: it resumes and re-checks every file; keep the headset awake and do not install meanwhile |
| The game starts without its data (`game_data ... null` in `vxmac_host.jsonl`) | the copy is incomplete or in the wrong place: `copy` (it verifies) |
| `launch` waits at "Acquired usage assertion" | put the headset on and unlock it |
| The picture freezes when you open another app | the game waits while VX Mac Host is in the background (visionOS allows no GPU work there); come back to it |
| Wanting to "start fresh" | do **not** delete the app (that deletes the 158 GB copy and your saves); `install` again instead |
