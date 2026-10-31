# VX Mac: the Mac App Store Cyberpunk 2077 natively on Apple Vision Pro

Design notes and history (written while it was built inside [VeRantyx](https://github.com/Ag3497120/VeRantyx);
"avp-port" and "VX Runtime" are the Windows route there). The user guide is [VISION_PRO_CYBERPUNK_MAC.md](VISION_PRO_CYBERPUNK_MAC.md).

The Mac build of the game is arm64 Metal code, like visionOS. VX Mac runs that code as it is on the headset:
its Mach-O images are prepared (load commands only, plus the pool-size patch), the macOS-only libraries
they name are replaced by our shims, the executable runs as a dylib inside a visionOS host app, and its frames go
to the immersive presenter shared with VX Runtime (the Windows route, `avp-port`). No emulation, no translation.

Game: `/Applications/Cyberpunk2077.app` (Mac App Store 2.3.2, arm64, macOS 15.5;
`Contents/MacOS/Cyberpunk2077` SHA-256 `3907f316f6adf9dd8188be82aeea9ae161445b2e1f6d25cf08c87b8a3ae6b421`, no
FairPlay encryption). The bundle is only read. Work copies: `build/cyberpunk/` (local, never in
git). Nothing touches the receipt, StoreKit, Game Center, iCloud or Galaxy accounts.

## Layout

| path | what |
|---|---|
| `tools/macho_prepare.py` | copy of one image for visionOS: platform, library paths to the shims, signature removed; `--as-dylib`, `--pool-patch`, `--system-shim` |
| `tools/check_imports.py` | every import of a prepared image looked up in the visionOS SDK's .tbd files and the built shims |
| `tools/prepare_test.sh` | the test program built for macOS and prepared like the game |
| `shims/` | one dylib per macOS library (Makefile -> `build/xros`) |
| `vr/` | the immersive presenter, copied from avp-port, and its glue |
| `app/` | VX Mac Host (your bundle id, e.g. `com.example.VXMacHost`), xcodegen project |
| `testapp/vxmac_test.m` | a Mac program shaped like the game where it meets the system |
| `tests/dyhost_mac.c` | the Mac test of `--as-dylib` |

## Preparing the images

```
APP=".../Cyberpunk2077.app"; W=build/cyberpunk/prepared/Frameworks
tools/macho_prepare.py "$APP/Contents/MacOS/Cyberpunk2077" $W/Cyberpunk2077.dylib --system-shim --pool-patch \
    --as-dylib @rpath/Cyberpunk2077.dylib --json ../manifests/Cyberpunk2077.json
tools/macho_prepare.py "$APP/Contents/Frameworks/libGameServicesAppStore.dylib" $W/libGameServicesAppStore.dylib --system-shim
tools/macho_prepare.py "$APP/Contents/Frameworks/libBink2MacArm64.dylib" $W/libBink2MacArm64.dylib
tools/macho_prepare.py "$APP/Contents/Frameworks/libREDGalaxy64.dylib" $W/libREDGalaxy64.dylib
tools/check_imports.py $W/*.dylib --shims build/xros:$W        # -> non-weak missing: 0
```

What changes in a copy:
- `LC_BUILD_VERSION` macOS 15 -> visionOS 26; library paths: `Versions/A` layouts to visionOS's flat ones,
  `../Frameworks` to `Frameworks`, and the replaced libraries to the shims (one path per library: dyld refuses an
  image that names one dylib twice, so AppKit and Cocoa get different shims). The signature is removed (the app
  build signs each copy with the user's team).
- `--as-dylib` (the executable): dyld will not `dlopen` an executable, and UIKit needs the process's main thread,
  so the game cannot be the app's executable. The copy becomes an `MH_DYLIB`: `__PAGEZERO`, `LC_MAIN`,
  `LC_LOAD_DYLINKER` removed, `LC_ID_DYLIB` added in the header's padding, the chained-fixup starts lose
  PAGEZERO's empty entry (segment indices move down by one). The entry point's offset (`LC_MAIN`'s, 206152 for
  this build) goes to `<name>.vxmac.plist`. Verified on the Mac: the converted test program runs from
  `dyhost_mac` (170 frames in 3 s, MetalFX temporal), and the converted game (`--platform macos`) loads with all
  its fixups and C++ initializers (`dyhost_mac ... -n`).
- `--system-shim`: libSystem through `libvxsystem` (re-exports libSystem): `syslog$DARWIN_EXTSN` (missing on
  visionOS; imported by libGameServicesAppStore) and `_NSGetExecutablePath` (below).
- `--pool-patch` (the work copy only, keyed by the SHA-256 above, refused on any mismatch).

### The pool patch

The engine reserves fixed address ranges for its memory pools; the sizes are `movz` immediates in the code. Same
change as the Windows route (VeRantyx `VXRuntime/src/game_patch.h``): 16->8, 64->16, 32->8 GB, every 4 GB pool ->
1 GB. `POOL_PATCHES` in `macho_prepare.py` holds (file offset, expected instruction, new instruction) only:

| file offset | what | from -> to |
|---|---|---|
| 0xfde8, 0xfe28, 0xfe6c | `0x10000fdc0`: the three large pools' descriptors (Windows exe+0x260dc48) | 16/64/32 GB -> 8/16/8 GB |
| 0x15fcbfc | `0x1015fcbd0`: three DynamicLinearAllocator pools in one register (Windows exe+0x68bd5d) | 4 GB -> 1 GB |
| 0x14f2e48, 0x1d23cb4, 0x2b13768, 0x2b13808, 0x2b147f0, 0x37cac30, 0x37cacb0, 0x3a316a0, 0x3a31e24 | the other call sites of the DynamicLinearAllocator constructor `0x100013398` (all pass 4 GB) | 4 GB -> 1 GB |
| 0x14170 | a pool constructor `0x100014144` that reserves 4 GB itself | 4 GB -> 1 GB |
| 0xe43b0c | `0x100e43afc`: a 4 GB descriptor for the `0x10000cff0` pool kind | 4 GB -> 1 GB |

Found from the reservation path (`0x10000cff0` / `0x100013398` -> `0x1000151a4` -> the page allocator's virtual
reserve) and every 4 GB `movz` feeding it. Why it is needed, measured on the headset: the test program's unpatched
reservations got 16 and 32 GB but the 64 GB one failed (`base 0x0`) even with extended virtual addressing.
Not yet verified at run time: that no other 4 GB+ reservation exists (the Windows route found its list from a run).

## The shims (`shims/`, our code from Apple's public documentation; no AppKit code)

| shim | for | what it does |
|---|---|---|
| libvxkit | AppKit | NSApplication (own event queue; `nextEventMatchingMask:` runs the calling thread's run loop in 2 ms slices while waiting), NSWindow/NSView/NSWindowController (model objects: frame, style, delegate, first responder, content view and its layer; nothing drawn), NSEvent, NSScreen (1920x1080 @1x, 90 Hz), NSCursor, NSImage, NSMenu, NSTrackingArea, NSWorkspace, `NSApp`, the notification names. An unimplemented method reaches a catch-all (returns 0) and is logged once. Host input: `vxkit_post_*` (HID keyboard usages -> kVK codes) |
| libvxcocoa / libvxcarbon | Cocoa / Carbon | re-exports libvxkit + Foundation / empty (Bink links Carbon but imports nothing) |
| libvxcg | CoreGraphics | re-exports CG; CGDisplay*, CGDisplayMode* (CF dictionaries), cursor warp/associate, event source |
| libvxiokit | IOKit | re-exports IOKit; IODisplayCreateInfoDictionary (empty), IODisplayGetFloatParameter (unsupported) |
| libvxsec | Security | re-exports Security; the 4 macOS-only calls return errSecUnimplemented (Galaxy's TLS client) |
| libvxgk | GameKit | re-exports GameKit; GKDialogController (presents nothing). Game Center itself is untouched |
| libvxcurl | libcurl | the 17 calls, offline: every transfer ends with CURLE_COULDNT_RESOLVE_HOST (the Mac build's offline result) |
| libvxmtl | Metal | re-exports Metal; MTLCopyAllDevicesWithObserver/MTLRemoveDeviceObserver; the present hook; framebufferOnly kept off; CAMetalDisplayLink stand-in (alloc returns our link: a timer at the preferred rate, update.drawable from the layer) |
| libvxmtlfx | MetalFX | re-exports MetalFX; the temporal-scaler interposer and stand-in (below) |
| libvxsystem | libSystem | re-exports libSystem; syslog$DARWIN_EXTSN; `_NSGetExecutablePath` = `$VXMAC_EXECUTABLE_PATH`; `readdir` lists a symbolic link as what it points to (opendir/closedir keep the paths; `VXMAC_TRACE_FS=1` logs each opendir) |
| libvxaudiounit | AudioUnit | re-exports AudioToolbox (AudioUnit.framework is headers only on visionOS; Bink links it) |

libvxkit also makes the program's thread its "main thread" for notifications: an observer (or a main-queue block)
the program registers from its thread is called on that thread (`performSelector:onThread:`, run by its event
pump), not concurrently on UIKit's main thread. Without it the game crashed in the simulator when GameController
posted a keyboard connect on the main thread while the game was still initialising (`+0x29cd2bc`, NULL).

The game finds its data from its executable's path (`_NSGetExecutablePath` + `realpath`, at `0x102a20d2c`). VX Mac
Host sets `VXMAC_EXECUTABLE_PATH=Documents/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077` (a placeholder file it
creates) when `Documents/Cyberpunk2077.app/Contents/Data` exists, so only the game's images (bound to libvxsystem)
see the Mac layout in the app's Documents.

## MetalFX

The game looks MetalFX's classes up by name. libvxmtlfx wraps every scaler made by
`MTLFXTemporalScalerDescriptor -newTemporalScalerWithDevice:` in a proxy (`forwardingTargetForSelector:`: every call
goes straight to the real scaler) that records, at each `-encodeToCommandBuffer:`, colour, depth, motion vectors,
output, jitter, motion-vector scale, content size and reset (`vxfx_take_frame`). The headers mark
MTLFXTemporalScaler unavailable on visionOS, but on the headset (visionOS 26, M2) the real one works:
`temporal_supported=1`, `_MFXTemporalScalingEffectV4`, 293 encodes captured in 5 s. Where it is unsupported or fails,
`+supportsDevice:` says YES and VXFXTemporalScaler is returned: one compute pass, jitter-compensated bilinear, no
history (`VXMAC_FX_FORCE_FALLBACK=1` tested on the Mac; `VXMAC_FX_FALLBACK=0` disables it).

## VX Mac Host (`app/`)

Your bundle id (default `com.example.VXMacHost`). SwiftUI app with the same window +
ImmersiveSpace + CompositorServices loop as VX Runtime's host (`VXMacImmersive.swift`, copied with names changed,
plus `vxmtl_displaylink_tick`). `host.m`: the launch arguments, the logs (`Documents/vxmac_host.jsonl`,
`Documents/vxmac_program.log` = the program's stdout/stderr), the present hook (VR: `vx_xros_vr_submit` into the
presenter's slot in the program's own command buffer, the offscreen present dropped; `-present flat`: the program's
CAMetalLayer added to the window), GameController keyboard and mouse as macOS events, and the program: its dylib
`dlopen`ed and its entry called on a "program main" thread with a 64 MB stack.

```
make -C shims && tools/prepare_test.sh
cd app && xcodegen && xcodebuild -project VXMacHost.xcodeproj -scheme VXMacHost -destination generic/platform=visionOS \
    -allowProvisioningUpdates -derivedDataPath ../build/dd build          # VXMAC_IMAGES=<dirs> to embed the game
xcrun devicectl device install app --device <id> build/dd/Build/Products/Debug-xros/VXMacHost.app
xcrun devicectl device process launch --device <id> --terminate-existing <bundle id> -- \
    -image vxmac_test -present vr -- -seconds 15 -displaylink
```

The presenter: `vr/xros_vr.m`, `vr/warp_core.{h,m}`, `vr/xros_vr.h` copied unchanged from avp-port
`VXRuntime/src` at **4f803c1** (h5a safe defaults: depth parallax only while the game is fast, no prediction in vr mode, damped calibration); `vr/vxmac_vr_glue.m` provides what VXRuntime's Windows layers gave it (raw mouse,
pointer, wheel, keys -> libvxkit events; the scene's depth and motion vectors from the MetalFX capture via a
stand-in `npu_interp.h`). MetalFX gives no projection: the glue makes one in place of FSR2's constants (its FSR2 parser is ours too):
`VXMAC_FOV_V` (vertical degrees, default 70, from the game's FOV setting), reversed depth when MetalFX says
`isDepthReversed` (distance = `VXMAC_NEAR` / d, default 0.2), the motion vectors' scale from MetalFX's (input
pixels per unit / input size). `VXMAC_PROJ=0`: none (the presenter's knobs, no vr mode).

## On the headset (2026-10-30)

The Mac test program (`testapp/vxmac_test.m` built for macOS, prepared, unchanged code) runs in VX Mac Host:
AppKit loop, window, view + CAMetalLayer, NSScreen 1920x1080 90 Hz, CG and IOKit display calls, curl offline
(error 6), bz2, MetalFX temporal (real, captured), presents through the hook into the immersive presenter:
screen mode, compositor 90 Hz, both eyes warped (180 eyes/s, warp 1.2-2.6 ms GPU), program 120 fps (its own loop)
or 60 fps (CAMetalDisplayLink stand-in), hand pointer events into the program, footprint 290 MB. 20 s, exit ok.
Catch-all hits: only CALayerDelegate probes on the view (`layerWillDraw:` etc.: harmless). A program left running
when the app went to the background kept going (the display-link stand-in is a timer). A rerun after the
notification and readdir changes waited at "Acquired usage assertion" (headset not worn): not repeated.

## In the visionOS simulator (2026-10-30): the game itself, data read in place

`make -C shims sim`, `macho_prepare.py --platform xrsim` (-> `build/cyberpunk/prepared_sim`), the host
built for the simulator with those images; the container's `Documents/Cyberpunk2077.app/Contents/Data` is
`engine/` and `r6/` copied (0.19 GB) and `archive/mac/{content,ep1}/*` symbolic links to the Mac install's archives
(read only; nothing of the original written). The game:
- loads (0.4-0.8 s for the 150 MB dylib, all fixups, C++ initializers), `NSApplication sharedApplication`,
  `finishLaunching` with its GameApplicationDelegate;
- reads `engine/config/base`, `engine/config/platform/mac`, finds its archives;
- asks Game Center: "local player has not been authenticated" (GKErrorDomain 6), handled by the game;
- stops at the simulator's Metal: `-[MTLSimDevice newHeapWithDescriptor:]: MTLStorageModePrivate is required for
  heaps` (the simulator has no shared heaps; the device has). That is as far as the simulator goes.

Found on the way (both apply to the headset): the game asks for `archive/mac/...` in lower case (the Mac's
file system ignores case, visionOS's does not: the copy must be `archive/mac`); `sh: grep: command not found`
(the game runs a shell pipeline at start; visionOS has no `/bin/sh` at all: popen fails, the game went on).

## Game data copy plan 

`Contents/Data` = 158.5 GB (decimal; 147.6 GiB): `archive/Mac/content` 115.8 GB, `archive/Mac/ep1` 42.2 GB,
`engine` 0.13 GB (configs, shader caches), `r6` 0.06 GB. Voice packs are 75.4 GB of it (11 languages, base + ep1).

| plan | what | size |
|---|---|---|
| full | everything | 158.5 GB |
| A | all but non-English voice packs (`lang_*_voice.archive` except `lang_en_voice`, in content and ep1); all text packs (0.2 GB) | 89.7 GB |
| B | A + Japanese voices | 96.5 GB |
| C | A without Phantom Liberty (`archive/Mac/ep1`) | 68.5 GB |

Voice packs are separate archives per language (as Steam's optional language depots); with the voice language set
to English the others are not read. Removing ep1 should look like the DLC not installed (untested on the Mac
build). Copy with `devicectl device copy to --domain-type appDataContainer --domain-identifier <bundle id>`
into `Documents/Cyberpunk2077.app/Contents/Data/...` with **`archive/mac`** in lower case (the game's spelling; the
Mac bundle says `archive/Mac`), one archive per call (resumable, as avp-port's
`tools/avp_cyberpunk.py` does). The headset already holds VX Runtime's 66.8 GB; its free space must be checked.
The prepared code (`Cyberpunk2077.dylib` 150 MB + Galaxy 37 MB + Bink + GameServices) goes inside the app bundle
(built with `VXMAC_IMAGES=build/cyberpunk/prepared/Frameworks`): also a copy of the game to the headset,
so it waits for the same OK.

## Walls and open questions

- The game itself has not run on the headset (needs the copy). Unknown until then: what its startup asks of
  libvxkit beyond the 120 selectors checked against AppKit (the catch-all logs them), whether `pthread_main_np()`
  being 0 on the program thread matters, the receipt (appears unread at startup on the Mac), memory: 7 GB at the
  lowest settings on the Mac route vs ~8 GB available to the app here (`available_mb` 8189 at launch).
- Game Center / iCloud entitlements are lost by re-signing (accepted); GameKit calls fail as for a signed-out
  player. Galaxy (GOG) and curl are offline.
- The presenter's vr mode (head turns as mouse) and prediction need the game's projection: MetalFX gives none.
  Options: the jitter + motion-vector scale give the render size; the FOV from the game's settings.
- `MTLFXTemporalScaler` is `API_UNAVAILABLE(visionos)` in the headers but works on the device today; the stand-in
  covers its removal.

## On the headset with the game (2026-10-30 evening)

- Data copied (110 files, 158,458,157,867 bytes, verified per file) with `tools/copy_game_data.sh`.
- Fixed on the way: macOS-only MTLDevice methods (`isDepth24Stencil8PixelFormatSupported`...) and a forwarding
  catch-all on Metal's classes; the MetalFX proxy was over-released (swizzled `new*`/`alloc` must return +1);
  GameController connects are held until the first frame (a Joy-Con on at launch reached the game before its input
  system); the program's commits wait while the app is in the background (the game stops on
  `CommandBufferErrorNotPermitted`); the immersive space is reopened when it closes while the app is active.
- Reached: main menu, character creation, in game (the opening, indoors), 1600x900, footprint 6.55 GB in game
  (limit ~8.19 GB). The GPU working set reported to the game is the device's own (`-env VXMAC_GPU_WORKING_SET_MB=n`
  to change it).
- Fixed (75600e8): skinned characters were garbled (vertex explosions, black patches, smeared people). Cause: frames
  in flight unbounded. A CAMetalLayer on screen gives out at most maximumDrawableCount drawables and takes one back
  only after its frame is done; ours is offscreen and its presents are dropped (the presenter shows the frame), so the
  game ran ahead of the GPU and rewrote per-frame bone buffers the GPU was still reading. libvxmtl now bounds it
  (nextDrawable waits while 3 drawables are out; one is back when the command buffer presenting it completed): 4044
  waits in a run to the bar, people right, in-game fps median 12 -> 19, footprint max 6.6 -> 6.4 GB. Ruled out on
  the way: the executable-to-dylib conversion and the pool patch (the same image is right on a Mac, CPTest), the
  Metal / MetalFX shims (right on the Mac with them), the Mac binary archives (garbled with them off), the reduced 4 GB
  pools (garbled with only the core patch). Debug switches kept (off by default): VXMAC_INFLIGHT, VXMAC_GPU_FAMILY_MAX,
  VXMAC_GPU_FAMILY_MAC, VXMAC_BINARY_ARCHIVES, VXMAC_GPU_WORKING_SET_MB.
  Diagnostics in the build: every Metal capability query the game makes and its answer, every failed buffer / heap /
  texture creation and the large ones, every reservation of 256 MB or more and how far it is committed (50/75/90/100 %).

## Presentation: one VR mode

The presenter runs in its automatic mode only (VXRT_VR_MODE stays unset; `screen`/`vr` remain debug variables):
(a) head -> camera as mouse deltas with reprojection while the game renders a 3D view with depth and motion vectors
(MetalFX's capture) and follows the head; (b) otherwise a world-locked panel, placed again in front of the head when
it comes back, in the dark surrounding - never head-locked. VX Mac's addition to the copied presenter: two calibration
rounds in a row with the sent turns absent from the game's motion (|correlation| < 0.2) hand back to the panel for
20 s, then 60, 180... (menus, character creation, cutscenes). Mouse-moved events always reach the game's view (its
tracking area, not acceptsMouseMovedEvents). The game's FOV for the projection comes from its UserSettings.json
(FieldOfView, horizontal at 16:9; set to 100 on the device for more coverage of the eyes' view). A change between
(a) and (b) fades in from black over 0.35 s. The window is dismissed once the space is open (`-window keep` keeps
it): its plate showed as a grey area below the view. The game profile tells the game a 4096 MB GPU working set
(`-env VXMAC_GPU_WORKING_SET_MB=n` to change). State (a) in game needs depth and motion vectors from the path the game really upscales with
(MetalFX temporal is not called with dynamic resolution).

### Head control in game (1dee362)

No motion vectors on the Mac route (MetalFX temporal is not called with dynamic resolution), so:
- the scene's depth comes from the game's own render passes: libvxmtl reports each render encoder's depth attachment
  when it ends (`vxmtl_set_pass_hook`), the presenter keeps the biggest of the frame's aspect (its D3D12 rule) and
  copies it in the game's command buffer; the compositor's own passes are skipped (queue "VX Mac compositor");
- the game profile sets the presenter to engage on depth (`VXRT_VR_ENGAGE=depth`), reversed infinite depth, 0.2 m
  near, tan from the game's FieldOfView;
- whether the game follows the head is measured from the frames: a 160-column brightness profile per frame (a small
  compute pass in the game's command buffer), the horizontal shift between frames against the yaw sent; 1.5 s
  windows with at least 4 degrees sent: under 25 % turned = not following (twice: the panel, 20/60/180 s backoff),
  over 50 % = following. Logs: `vr_follow` lines in vxmac_host.jsonl.
Tested in the simulator with the test program (depth found and copied, vr mode engaged); the follow check needs
head tracking (device).

### Controller turns, NPU flow (first stage), GPU load (fa8efe7 and after)

- A controller's right stick turns the game's camera without the head: the image check (columns and rows) measures
  each frame's turn, and what the sent mouse does not explain (stick out of its dead zone, or over 2 degrees) goes to
  the presenter's camera offset, so the warp poses frames where the camera was; those frames count in no follow
  window. The stick itself stays as the game has it (continuous turn): snap turns would need the controller's values
  changed before the game reads them (GameController), not done.
- NPU flow (`app/Sources/npu_flow.m`, `VXMAC_NPU=0` off): each frame scaled to 320 wide in the game's command buffer,
  Vision's optical flow (Neural Engine) between it and the frame before, one at a time; the newest flow is the frame's
  motion vectors for the presenter, which predicts every compositor frame from the newest real frame
  (`VXRT_VR_PREDICT_VR=1` with it). VideoToolbox's optical flow and frame interpolation are unavailable on visionOS
  in the SDK headers (the interpolation class is in the runtime: a later stage). Stats: `npu_*` in the stats lines.
- GPU load: `game_gpu_busy_pct` (the union of the game's command buffers' GPU time per second).

### The game's own motion vectors (velocity.m) and the NPU plan

- h24's colour-target log: the G-buffer pass (with depth) writes an RG16Float target at the render size as its colour
  attachment 3 (853x480 for 1280x720 out; also RG16Snorm at attachment 0, and half-size RG16Float targets). It is
  copied when its pass ends and verified before use: regression of the picture's measured shift on its mean
  (|correlation| >= 0.7 over 30 moving frames) and near-zero values on still frames; then it is the presenter's motion
  vectors with the regression's scale and sign (`vel_check` lines). Vision's flow is off by default (`VXMAC_NPU=1`,
  CPU only: Vision's optical flow refuses the Neural Engine on visionOS, and on the GPU it cost frames).
- counts per degree: the image check alone tunes them; the presenter's motion-vector calibration is log only
  (`VXMAC_MVCAL_APPLY=1` brings it back).
- The NPU stage (planned): our own Core ML model, computeUnits cpuAndNeuralEngine, fed with the game's colour (the
  853x480 frame), its depth and its velocity: first the predicted frame's clean-up (holes from disocclusion and the
  warp's block edges filled from the surrounding colour/depth), later an upsample of the render-size frame toward the
  panel. Targets for M2's Neural Engine: a small U-Net-like net, about 1-2 M parameters in fp16 (2-4 MB), inputs at
  half the render size (426x240 x 7 channels), under 6 ms a frame, so it runs once per real frame (18-30 Hz) alongside
  the GPU, its output reused by the 90 Hz warp; memory under 100 MB (weights, IOSurface-backed inputs/outputs, Core ML's
  working set). Trained offline on pairs from the Mac (frames, depth, velocity, the next frame).

## Next stage: NPU interpolation (after the character fix, the background / space fixes and memory headroom)

1. Depth and motion vectors from the game's real upscale path: with dynamic resolution MetalFX temporal is not
   called; find the path (MetalFX spatial, FSR2/FSR3 compute, its own TAA) and capture its inputs there, or force
   MetalFX temporal by settings.
2. avp-port's NPU race: the camera's motion taken out of the motion vectors, objects' motion predicted, prediction
   only when real frames are at most ~55 ms apart.
3. The prediction and the hole fill on the Neural Engine (Core ML), off the GPU.

## Optional modules and foveated SR (2026-10-31)

The Neural Engine modules (`app/Sources/npu_flow.m`, `app/Sources/fsr.m`, `tools/fsr_model.py`, `tests/fsr_bench.m`)
are in the default build. `app/Sources/strength_hooks.m` holds weak stand-ins, so a build without them links too
(`EXCLUDED_SOURCE_FILE_NAMES="npu_flow.m fsr.m"`; the features read as off).

Foveated SR v1 (not learned): `tools/fsr_model.py` builds a Core ML ML program (x2 polyphase cubic + clamped unsharp
mask, 512x288 -> 1024x576, image in/out). `tests/fsr_bench.m` on the M1 Max Mac: every op on the Neural Engine, 3.6 ms
mean / 5.2 ms worst, load 354 ms.

Wired in (ddgame21, off by default): `VXMAC_FSR=1` runs `app/Sources/fsr.m` per game present: the centre 512x288 (1:1,
a blit in the game's command buffer; `VXMAC_FSR_CROP=<share of width>` resamples instead) into an IOSurface buffer,
then the model on a serial queue (CPU+Neural Engine only, one at a time, busy frames skipped) into one of three
IOSurface outputs; the presenter asks for the detail of the very frame it warps (`vx_xros_vr_next_seq`, slot `pseq`),
never an older one, and the warp blends it over the bilinear frame with a 12 % soft ring (`warp_core.m vxw_col`,
`vxw_set_detail`). Logs: `fsr` lines (ready, first_ms, plan: ane_cost_share) and stats fsr_* (ms mean/max,
offered/made/skipped_busy, hits/asks). Memory: ~9 MB of buffers, the model 24 KB.
Foveation: `VXMAC_FOVEATE=1` turns on CompositorServices' foveation; the eye's rasterization rate map goes to the
presenter (`vx_xros_vr_set_rate_map`), every eye pass draws through it on the logical screen (`eye_encoder`), and the
warp works on the map's screen size (render pass only). `vr_eye_density` logs the centre's px/deg once. The warp's key
blocks now grow with the output's density over the frame's (`kbs`): above 2x, holes stayed unresolved (a grid of dark
lines; found in a Mac test at 4x); at today's 1.28x it is unchanged (kbs 2). Centre density: game frame 1280 over
FOV 100 = 9.4 px/deg; the eye texture without foveation is 12 px/deg at the centre, so x2 SR reaches 12 px/deg (the
eye texture's cap) plus edge sharpness until compositor foveation (rate maps in warp_core) raises the cap.

## A new game build (checklist; 2.3.2 is the tested one)

2.3.2's code images are kept in `build/cyberpunk/game_2.3.2_code/` (SHA256SUMS, Info.plist) with its data
manifest `data_manifest_2.3.2.json` (the headset holds 2.3.2's data), so 2.3.2 can always be prepared again.

1. `tools/new_build.py <Cyberpunk2077.app> <outdir>` (read only): version, SHA-256, the pool patterns
   (`macho_prepare.py --pool-check`: the three large pools, the linear pools, the pool-kind descriptor, the constructor
   reserving itself; exact counts or refused; 2.3.2 reproduces its 15 sites exactly), each image's libraries against
   2.3.2's, new MetalFX / BackgroundAssets / Metal 4 names, the data delta, the four images prepared and check_imports.
2. Missing symbols: MetalFX frame interpolation (`MTLFXFrameInterpolator*`) and denoised scalers -> libvxmtlfx (the real
   class where visionOS has it, else a stand-in that reports unsupported so the game takes its other path); a new
   framework (BackgroundAssets...) -> its visionOS version if the SDK has it, else a shim in `shims/`.
3. Data: where the build keeps its data (Contents/Data, or assets downloaded in the background into its container's
   Application Support); `tools/data_manifest.py DATA new.json` and `--delta old new` give the files to copy to the
   headset (only those, archive/Mac -> archive/mac).
4. Per-build Metal identities (a Mac or headset run with `VXMAC_PIPE_DUMP`):
   - UI layers' vertex shaders: `tools/ui_hashes.py DUMP` -> `VXMAC_UI_VS=<h>,<h>` (2.3.2: 9659c847a5663c68,
     dd2ffa0fee62e619; defaults in vxpipe.m);
   - the camera: `tools/cbv_find.py DUMP` -> `VXMAC_CAM_PATH=<word>:<table byte>:<matrix byte>` (2.3.2: 0:24:320);
   - then make them the defaults for that build (keyed by the executable's SHA-256 from `<image>.vxmac.plist`).
5. Settings: the build's UserSettings.json keys (FieldOfView, resolution, MetalFX modes) for `tools/cp_settings.py`
   and `patch_fov.py`.
