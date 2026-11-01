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
The headset now holds 2.5.0's data: build with `VXMAC_IMAGES=build/cyberpunk/prepared_2.5.0/Frameworks:...`
(ddgame60h did). ddgame61 was built from `prepared/` (2.3.2's code, entry_offset 206152) and hung at the game's start
right after "screen placed", no crash report; 2.5.0's entry_offset is 212308. `program_loaded` logs `entry_offset` and
`source_sha256` from h61b on.

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
3. The prediction and the hole fill on the Neural Engine (Core ML), off the GPU. Method 3, below: capture, model and skeleton built 2026-11-01.

## Method 3: our own frame-prediction model on the Neural Engine (2026-11-01, preparation stage)

Why: the game renders 12-15 fps on the headset (frame gaps 50-170 ms, mean 50-70 ms), the warp runs at 90 Hz
(4-5 ms of GPU an eye pair); the GPU is the bottleneck and its contention and heat put the app at 45 Hz, so the model
runs on the Neural Engine only (MLComputeUnitsCPUAndNeuralEngine, never the GPU). The race design predicts only when
real frames are at most ~55 ms apart (the warp's gate is 150 ms), which at 15 fps rarely holds: the model's job is a
usable predicted frame for gaps up to ~150 ms, with the disocclusion holes filled.

Design (optional files). The Neural Engine has no gather or scatter (no warp on it), and a frame is needed at
every 90 Hz display time while the model can run once per real frame. So the model gives the warp what it lacks, once
per real frame N, at 416x240 (half the 853x480 render size, 16-divisible):
- input x (1, 6, 240, 416) fp16 planar: colour N (sRGB-encoded 0..1), depth `log2(1/d)/12` (d the reversed depth),
  the game's velocity as scene motion over the interval before N (target value x vel_check's k x size, / 16 px);
- output y (1, 6, 240, 416) fp16: `fill` rgb (the colour behind foreground edges, for holes), `motion` (the velocity
  cleaned, same unit, per interval), `conf` (the warp's weight for frame N's pixel: low on particles and smears).
The warp then makes the frame at t = age / interval as now (frame N moved by motion x t), weighting by conf and taking
holes from fill moved with the background's motion. Training renders that composite differentiably (soft z-buffered
forward splatting, the farthest neighbour's motion for holes; written in `tools/interp_model.py`) against the real
frame N + gap. Losses: L1, edge (gradient L1), hole-weighted L1, a small pull of motion towards the game's.
Network: our own U-Net, stem stride 2, levels 32/64/96/128 at 1/2..1/16, nearest upsampling, concatenated skips,
pixel shuffle back to full size, residual heads (zero-initialised: before training it is the plain warp's input);
912,856 parameters (1.8 MB fp16); ops conv/relu/upsample_nearest/concat/add/clip/sigmoid/slice/pixel_shuffle.

Files: `tools/interp_model.py` (model, capture reader, dataset, training, Core ML export: ML program, fp16,
CPU_AND_NE, iOS17 target; `smoke` = synthetic end-to-end proof), `app/Sources/interp_capture.m` (the capture),
`app/Sources/npu_model.m` (the model in the app), `app/Sources/interp_pack.h` (the GPU pack kernels both share),
`app/Sources/interp_frame.h` (public: the frame's scene struct and the entry points; stand-ins in strength_hooks.m),
`tests/interp_bench.m` (Neural Engine bench), `tests/interp_capture_mac.m` (the capture on the Mac's GPU).
Accessors added for them: `vx_xros_vr_scene_depth` (xros_vr.m: this frame's depth copy before the submit takes it),
`vxmac_vel_latest_tex` (velocity.m: the newest velocity copy with k and corr, verified or not). host.m builds the
frame's scene (`interp_scene`) only when one of them is on; the stats line gains `cap_*` / `interp_*` only then.

### Training capture (`VXMAC_CAPTURE`, off by default)

On the headset, in VX Mac Host: that is where the frames, gaps, render size, head-driven camera, HUD split and the
verified velocity are exactly what the model will see. A Mac-side path is possible but not built: our CPTest.app copy
(dyhost_mac + DYLD_INSERT of `build/macshim`) could run interp_capture.m unchanged (tests/interp_capture_mac.m builds
it for macOS), but it needs a Mac injector that installs the pass/target/present hooks with velocity.m's copy and the
presenter's depth pick, and a Mac run of the game; its gain (more frames, any gap by skipping frames, no headset heat)
comes with a mouse-driven camera and Mac settings. Later supplement, if the headset data is short.

- `VXMAC_CAPTURE=1`: game frames while vr mode drives the camera; `=2`: every frame (menus, cutscenes).
- Per captured present, in the game's own command buffer before the presenter's submit: one compute pass samples the
  frame (4 bilinear taps), the depth copy and the velocity copy (nearest) at 416x240 (`VXMAC_CAPTURE_SIZE=WxH`) into a
  shared buffer (6 fp16 planes, raw); when the frame completes a utility-QoS queue deflates it (libcompression ZLIB =
  raw deflate) and appends it to `Documents/vxinterp_capture/cap_<date>.vxic`.
- Rate: bursts of `VXMAC_CAPTURE_BURST` (8) consecutive presents every `VXMAC_CAPTURE_EVERY_S` (2 s): ~4 frames/s
  (pairs N/N+1 and N/N+2 at the game's real gaps). A burst ends early when the writer is behind (12 buffers, cap_short).
  Stops at `VXMAC_CAPTURE_MB` (4000), with under 5 GB free, or (h61c) when the process's available memory
  (`os_proc_available_memory`, checked at each burst's start) is under `VXMAC_CAPTURE_MIN_AVAIL_MB` (600):
  `"stopped":"memory"` (interp_capture log lines). ~15 MB of buffers, fixed: the deflate's output and scratch are
  allocated once, the file is written with write(2) and F_NOCACHE, autorelease pools around the capture and the write.
  Stats gain `cap_foot_mb`, `cap_foot_growth_mb` (since the capture started), `cap_avail_mb`, `cap_avail_min_mb`; an
  interp_capture line every 250 MB written carries the footprint and available memory.
- h61c, ddgame61b's 48-minute run (hcap7): killed by the system at the 8 GB limit (no crash report), footprint
  6.4 -> 8.2 GB, internal+compressed +1.4 GB (0.45 MB/s) for 2.9 GB written. The Mac test does not reproduce a leak
  in the capture: ddgame61b's capture code, 5969 frames captured / 2.26 GB written, footprint 33.8 -> 32.6 MB; with
  no autorelease pool on the caller's thread 2161 frames 34.1 -> 32.5 MB (the capture off: 16.6 -> 16.5). Runs
  without the capture also grew after load (hnow075 0.7 MB/s, hnow 1.2 MB/s over 2-3 minutes); no run without it
  has been measured for long, so the game's own growth is the open question.
- Format (`tools/interp_model.py read_capture`): file header `VXIC` v1 w h planes; per record `VXFR` + a 196-byte header
  (flags: depth, velocity, velocity verified, vr mode, stick, HUD split, camera, depth16, zlib; burst, index; source,
  depth and velocity sizes; present number, camera number, present time, previous present time; vel k and corr;
  tangents, near; sent yaw/pitch; the game's view matrix) + the deflated planes r g b d vx vy.
- Mac test long run (footprint every VXT_REPORT presents): `VXT_FRAMES=6000 VXT_GAP_MS=28 VXT_EVERY_S=0
  VXMAC_CAPTURE_MB=100000` (noise in the frame so deflate works); `VXT_OFF=1` the same without the capture,
  `VXT_NOPOOL=1` no autorelease pool per present, `VXMAC_CAPTURE_FAKE_LIMIT_MB=630` the memory stop.
- Mac test (M1 Max): 20 presents, 5 bursts, read back exactly (colour, depth 0.05, velocity, k, tangents); the GPU
  `nn_pack` against Python's `encode_input` on the same frame: max |diff| 0.0001 a plane; deflate+write 4-8 ms a frame.

Capture session (the user drives; the headset, the install and the launch are the parent's):
1. Launch the ddgame61 build with `-env VXMAC_CAPTURE=1` (devicectl launch arguments, or the line
   `-env VXMAC_CAPTURE=1` in `Documents/vxmac_args.txt` for a Home launch: remove it afterwards). Everything else at
   today's defaults (the warp, the GPU cap); the capture records only in head-look gameplay.
2. In game, 2-3 minutes each, normal play: (a) walking a crowded street in Watson / Japantown with head turns slow and
   fast; (b) walking past pillars, doorways, cars and people close by (disocclusion); (c) indoors (an apartment, a bar);
   (d) driving a car and a bike in traffic (fast motion, the long gaps); (e) night with neon, rain if it comes; a fight
   only if convenient (particles, muzzle flashes). 10-15 minutes in all: ~3000 frames, ~1.5-2.5 GB.
3. Pull `Documents/vxinterp_capture/` to the Mac (devicectl device copy from, appDataContainer <bundle id>),
   then `tools/interp_model.py info --data DIR` and `train --data DIR`.
Check in the stats lines: cap_frames rising, cap_dropped / cap_short low, the frame pacing (frame_pacing) and the
45 Hz lock not worse than without it.

### Memory over a long session (h62, ddgame62)

- What grows (hcap7 48 min, hcap8 run 2 24 min): internal + compressed (CPU-side memory) 3.4 -> 5.0 GB, ~20-25 MB a
  minute after load (40-50 MB per 120 s, steady, not tied to the frame count: the same in the screen mode at 2-3x the
  frames); footprint - internal - compressed (GPU memory) flat at 2.9-3.1 GB, so no Metal resource is kept by us. The
  address space grows with it (virtual 484.6 -> 486.1 GB): new mappings, not old pages refilled. The capture stopped
  at 766 s in hcap8 and the growth went on.
- Ruled out on this Mac: the foveated SR's Core ML loop as fsr.m runs it (20000 predictions with outputBackings on a
  serial queue, an autorelease pool each: 21.2 -> 21.3 MB), the capture (h61c). Our per-frame objects are freed with
  the game's encoders; no shim container grows with time.
- The game's VM backend (Cyberpunk2077 +0x14700): reserve = mmap RW (1 GB pools after the pool patch), commit =
  madvise(MADV_FREE_REUSE), decommit = madvise(MADV_FREE_REUSABLE) (the footprint drops: measured here), release =
  munmap. New 1 GB pools are reserved through the session (51, 165, 426, 598, 696, 727, 872, 1060, 1333 s in hcap8),
  each a little higher in the address space than the last: what lies below keeps growing.
- The lever: `hw.memsize` answers the game's "low-memory device" test (+0x1b060: `memsize >> 30 < 10`, kept after its
  first answer, read by 39 sites; e.g. a 1 MB buffer made 512 KB at start). The headset says 15744 MB while the app
  may use ~8 GB. `-env VXMAC_MEMSIZE_MB=8192` (off by default) takes the game's own low-memory path: sysctlbyname,
  sysctl {CTL_HW, HW_MEMSIZE} and NSProcessInfo.physicalMemory all answer it (the game asks the selector too: logged
  once with its caller).
- The `mem` line (every 10 s): `internal_mb`, `compressed_mb`, `reusable_mb`, `graphics_mb`, `neural_mb`, `media_mb`,
  `purgeable_nv_mb`, `peak_mb`, `limit_left_mb`, `regions`, `threads`; `vm_tags_mb` (dirty + compressed per VM tag:
  untagged = the game's pools and mappings, malloc_* by kind, iosurface, ioaccelerator...); `malloc_in_use_mb` /
  `malloc_allocated_mb` and the four largest zones [name, in use, allocated, blocks]; `game_vm` (libvxsystem: the game's
  mappings still mapped, maps / unmaps, decommitted / recommitted MB, other madvise, mprotect to none, the reservations
  and the eight that hold the most [base, size, held MB, caller]); `mtl` (live / made render and compute pipelines,
  libraries and their data, UI twins, the game's shared buffers we index and their MB, our UI / pass records);
  `relief_mb` / `relief_total_mb`. Under `VXMAC_MALLOC_RELIEF_MB` (400) available, at most once a minute, malloc gives
  back its free pages (`=0`: never). munmap now drops a reservation ("vm: release"); a reservation mapped RW is no
  longer reported "committed to 100 %".
- libvxkit: each run-loop slice of nextEventMatchingMask: in its own autorelease pool (what AppKit's main run loop
  observers do on a Mac); a pthread of ours never drains the program thread's pool otherwise.
- Next run: `mem` says which owner grows (an untagged / malloc / tag / zone figure rising ~20 MB a minute with
  internal_mb); then the A/B with `-env VXMAC_MEMSIZE_MB=8192`.

### Model in the app (`VXMAC_INTERP=1`, off by default): integration skeleton

`app/Sources/npu_model.m`, after fsr.m's pattern: the model (`VXMAC_INTERP_MODEL`, default vxinterp_416x240.mlmodelc in
the app's Resources or Documents) loaded on a serial queue; per present in vr mode the GPU packs and encodes the input
into an IOSurface pixel buffer (OneComponent16Half, W x 6H = the model's x as an MLMultiArray, no copy); at the
buffer's completion the model runs (one at a time, busy presents skipped) into one of three IOSurface outputs
(outputBackings, no copy) that the GPU reads as R16Float W x 6H; the presenter asks for the result of the very frame it
warps (`vxmac_interp_result` by present number, in draw_eye; counted as interp_hits / interp_asks). Velocity scale:
vel_check's once verified, else `VXMAC_INTERP_VEL_K` (-1.05). Not yet consumed: the warp's use (holes from fill, conf
as the source weight, the model's motion instead of the raw velocity, and the 150 ms prediction gate lifted when the
model's layers are there): step 4 below (h63).

### Step 4: the warp uses the model's layers (h63, ddgame63; `VXMAC_INTERP=1`, off by default)

- `vr/warp_core.m vxw_set_interp`: once per result (by present number) the model's planar output is repacked in the
  compositor's command buffer into two RGBA16F 416x240 layers (fill sRGB-decoded when the frame is sampled through an
  sRGB view, conf; motion, conf); then per eye the warp's map moves the frame's blocks by the model's motion (x t,
  model px / 16 x 16 x frame size / 416x240; the camera's turn over the interval before N taken out as for motion
  vectors, VXW_CAM_MV; the motion of low-conf pixels scaled towards conf from 100 ms of age), holes keep the
  background's displacement and show the model's fill (no stretched block), and the frame's colour is weighted against
  the fill by min(2 conf, 1) with a share min(t, 1) - the training composite. The fill is 416x240: where conf is low it
  corrects only the frame's low frequencies (fill minus the frame at the fill's mip level), the frame's detail stays.
  The layers' code is a second Metal library (`VXW_INTERP` preprocessor macro, made at the first use): the default
  library's source preprocesses to exactly the old one and its params get the old byte count, so without layers the
  kernels are the same; checked: ddgame62's warp_core.m against this one, the default and the velocity paths on 400
  captured pairs, render pass + depth: identical bytes (`-DVXT_IDENTITY` build of tests/interp_warp_mac.m).
- `vr/xros_vr.m draw_eye_inner`: asks for the result of the very frame it warps; used when there is one, VXRT_VR_PREDICT
  is on, the frame's own interval (time since the present before, `gap_before`: the interval its velocity covers - not
  the smoothed one) is 5-400 ms and, in vr mode, the camera of the frame before is known. Then t = age / gap_before
  (as training's tau), at most `VXMAC_INTERP_TMAX` (1.5), age gated at `VXMAC_INTERP_MAX_MS` (150, where t is then held:
  no jump back), conf fade from `VXMAC_INTERP_FADE_MS` (100). No h60 camera move with it (the camera's motion is in the
  velocity; `VXMAC_INTERP_MOVE=1` both); the depth's z-order is used even outside the dibr gate (then without the eyes'
  baseline). Otherwise (no result yet, late, gates) the eye is drawn exactly as before.
- `VXMAC_INTERP_CONF`: auto (default) ignores conf when the newest checked result's mean conf is under 0.05; 1 always,
  0 never.
- Stats (only while on): `interp_ms_mean/p95/max` (the model on the device), `interp_hits/asks`, `interp_ready_ms`
  (present -> result), `interp_late` / `interp_late_ms` (frames whose result came after the warp first asked),
  `interp_never` (frames shown without one), `interp_conf_mean/low`, `interp_fill_dev`, `interp_motion_dev_px` /
  `interp_motion_in_px` (every 8th result, 1/16 of its pixels); the warp's `iw_eyes` / `iw_eyes_asked`, `iw_frames`,
  `iw_dt_ms_mean/max` (predicted time), `iw_t_mean`, `iw_held`, `iw_conf_off`, `iw_gpu_ms` / `iw_gpu_ms_plain` /
  `iw_gpu_extra_ms` (compositor frames' GPU time with the layers / without, same run). host.m's jlog buffer 6144.
- Model bundled: `app/embed_images.sh` copies `VXMAC_INTERP_MODELS` (default `build/interp_app/*.mlmodelc`: run1's
  vxinterp_416x240.mlmodelc copied there) into Resources; a build without them (no optional files, no model) builds.

Mac test (`tests/interp_warp_mac.m`, M1 Max): 5348 pairs of cap_20261101_091928 (N with N-1 and N+k, k 1-2, age up to
200 ms), the app's kernels (render pass into sRGB + Depth32Float), the model through Core ML as the app (IOSurface in
and out), the real camera of N+k as the head's pose; PSNR against the real N+k (whole frame):

| age | hold | default (ddgame62) | vel (VXMAC_VEL_PREDICT) | model (h63) | velx (h63's timing, raw velocity) |
|---|---|---|---|---|---|
| all (5348) | 22.94 | 24.39 | 24.81 | **25.13** | 25.13 |
| 0-55 ms (2412) | 23.74 | 25.46 | 26.05 | 26.17 | 26.17 |
| 55-100 ms (1502) | 22.03 | 23.41 | 23.89 | 24.07 | 24.07 |
| 100-150 ms (587) | 22.21 | 23.28 | 23.66 | 23.94 | 23.94 |
| 150-200 ms (847) | 23.21 | 24.50 | 24.50 | 25.59 | 25.59 |

t's cap (1783 pairs): 4: 24.74, 2: 25.06, 1.5: 25.21, 1.25: 25.25 dB; MAX_MS 200 the same as 150 on these pairs.
**Finding: run1's model has collapsed** - conf 0.0039 everywhere, fill = the frame (mean |diff| 0.0002), motion = the
game's (0.09 px off against 10.5 px): the training composite was satisfied by conf -> 0 (its soft splat then gives
way to the fill warped backwards by the far motion), and the motion and fill heads (zero-initialised residuals) never
moved. In its own composite it scores 21.6 dB on the first 400 pairs, under holding the frame (22.4). So h63's gain over
ddgame62 (+0.74 dB, +1.1 dB at 150-200 ms) is the new timing (the frame's own interval, t capped at 1.5, the gate at
150 ms held, no h60 move) and hole handling, the same with the raw velocity (velx); the model adds nothing yet and the
auto conf guard keeps its conf out. Retraining is the next step (conf not able to switch the splat off: e.g. the
composite's coverage from the splat's own weights with conf only as a blend, a pull of conf to 1 where the frame is
right, the fill and motion heads trained apart; held-out pairs from a separate capture - run1's "held-out" batches came
from the same pairs as training).
GPU (this Mac, an eye 1600x900 -> 1888x1792, render pass + depth): 0.38-0.59 ms without the layers, +0.11-0.14 ms with
(the repack, once a result, ~0.01 ms); the headset's figure: `iw_gpu_extra_ms`.

### No model: `VXMAC_INTERP=vel` (h63c, ddgame63c)

The h63 prediction on the game's raw velocity, with no Core ML and no Neural Engine (npu_model.m stays off: its
switch is `=1` only): at each present the newest velocity copy (velocity.m, this frame's, verified or not) is copied
into the frame's slot with its scale (vel_check's once verified, else `VXMAC_INTERP_VEL_K`, -1.05); the eyes then use
the same timing as the model path (t = age / the frame's own interval, capped at `VXMAC_INTERP_TMAX` 1.5, age held at
`VXMAC_INTERP_MAX_MS` 150, the camera's turn out, the previous frame's still blocks held, no h60 move, the depth's
z-order) through the default kernels - their DIBR hole rule. Hole rules measured on the held-out bursts: the DIBR rule
(stretched background block) 23.78 dB, the background's displacement with the frame's own colour (= run1's collapsed
layers) 23.78, within 0.01 dB in every bucket: the DIBR rule, no extra GPU work (one velocity copy a game frame:
1600x900 RG16F). Stats: `"interp":"vel"` and the warp's `iw_*`. Off by default (the default path unchanged).

Held-out bursts, the real kernels (tests/interp_warp_mac.m VXT_SPLIT=heldout, 944 pairs), PSNR whole frame:

| age | default | old velocity path | **vel mode** | run3 model |
|---|---|---|---|---|
| all | 23.14 | 23.52 | **23.78** | 23.84 |
| 0-55 ms | 23.77 | 24.27 | 24.38 | 24.40 |
| 55-100 ms | 21.98 | 22.41 | 22.58 | 22.66 |
| 100-150 ms | 23.03 | 23.34 | 23.62 | 23.66 |
| 150-200 ms | 24.07 | 24.07 | 25.08 | 25.14 |

### Retraining against the h63 path (h63b, ddgame63b: run3)

`tools/interp_model.py train2` / `eval2` (run1's `train` kept):
- Split by time: bursts in chunks of 20 (~40 s), every 5th chunk held out (`heldout_burst`): 4404 training pairs (448
  bursts), 944 held-out (100 bursts); tests/interp_warp_mac.m `VXT_SPLIT=heldout|train` applies the same rule.
- `composite_h63`: the h63 warp path made differentiable - frame N's pixels moved by t x (the model's motion less the
  camera's turn from N-1's camera), turned to N+k's real camera, t = min(age, 150 ms) / N's own interval capped at 1.5,
  the long-gap conf fade, soft z-order by depth; coverage from the splat's footprints alone (conf cannot remove the
  splat); conf blends frame against fill as the gather does; holes the fill at the background's displacement; loss
  and PSNR only where N+k's view lies inside N. Found on the way: run1's splat normalised with a 1e-6 floor under
  weights of exp(-20 x farness), which blacked out the far scene in its composite - likely part of its collapse.
- run2 (`--loss v1`: run1's L1 + edge + hole-area L1, plus a pull of conf to 1): conf a constant 0.86-0.93 (std 3e-5),
  below the raw velocity even on its training pairs (25.14 vs 25.20 dB): stopped at 3000 steps.
- run3 (`--loss v2`, default): Charbonnier at full size and 1/2, 1/4, 1/8 (motion gets a gradient beyond one pixel),
  the holes' error over the whole view, motion pull 0.005, a penalty only for conf collapsing (mean under 0.3); body
  from run1, heads reset (starts as the raw velocity); 10000 steps, batch 8, full 416x240, lr 1e-3 one-cycle, MPS,
  ~52 min; best held-out at step 9000 (`build/interp_run3/vxinterp.pt`).

Held-out bursts, the real kernels (tests/interp_warp_mac.m, `VXT_SPLIT=heldout`, 944 pairs), PSNR whole frame:

| age | hold | default | vel | velx (raw velocity, h63 path) | run1 | **run3** |
|---|---|---|---|---|---|---|
| all | 21.61 | 23.14 | 23.52 | 23.78 | 23.78 | **23.84** |
| 0-55 ms (426) | 22.06 | 23.77 | 24.27 | 24.38 | 24.38 | 24.40 |
| 55-100 ms (277) | 20.68 | 21.98 | 22.41 | 22.58 | 22.57 | 22.66 |
| 100-150 ms (94) | 22.07 | 23.03 | 23.34 | 23.62 | 23.62 | 23.66 |
| 150-200 ms (147) | 22.04 | 24.07 | 24.07 | 25.08 | 25.07 | 25.14 |

(train2's own composite on the same held-out pairs: run3 24.41 vs velocity 24.17, 55-200 ms 24.04 vs 23.75 - the soft
splat leaves larger holes than the block warp, so the fill counts for more there.) What run3 learned: the fill (|fill -
frame| 0.055 in the composite's holes, 0.018 over the frame in Core ML); not conf (mean 0.503, std 0.0024: no
collapse, but no information either - at 0.5 the gather's min(2 conf, 1) is 1) and not the motion (0.002 px from the
game's). So it beats velocity everywhere at 55-200 ms, by +0.25-1.07 dB against the old velocity path and by
+0.04-0.08 dB against the same path with the raw velocity: the hole fill, and nothing else yet. Data: one capture
(cap_20261101_091928, 4392 frames); today's second (cap_20261101_103303, 1096 frames, still on the headset) has the
same format and could be added (+25 %) once pulled. Next: motion and conf need a signal the picture loss does not give
at one interval (e.g. a flow target from N -> N+k by block matching, conf trained on the warp's own error).

### Neural Engine bench (tests/interp_bench.m, this Mac: M1 Max; IOSurface in/out as the app does, 100 % of the
estimated cost on the Neural Engine, output written in the backing: no copy)

| widths | params | back to back mean | paced 70 ms mean / p95 / worst | paced 30 ms |
|---|---|---|---|---|
| 16,32,64,128 | 0.49 M | 0.70 ms | (60 ms) 3.1 / 6.5 / 7.4 | |
| 24,48,96,128 | 0.81 M | 0.99 ms | 4.2 / 6.8 / 10.0 | 4.5 |
| **32,64,96,128 (default)** | **0.91 M** | **1.10 ms** | **4.7-4.8 / 6.3-7.1 / 8-11** | 4.6 |
| 32,64,128,160 | 1.37 M | 1.25 ms | 5.3 / 8.0 / 10.4 | 5.4 |
| 48,96,160,192 | 2.26 M | 2.13 ms | (60 ms) 8.9 / 11.3 / 11.7 | |

(448x256, 1.37 M: 1.38 ms back to back, 6.0 ms paced 60 ms.) Paced runs (a pause between predictions, as at the game's
rate) cost 3-4x the back-to-back time and ~2.5 ms of it is fixed (the smallest net pays it too): the Neural Engine
(or Core ML's dispatch) waking each time. Load 255 ms, first prediction 2-5 ms, footprint +7-12 MB. The headset's M2
Neural Engine is a newer generation than M1 Max's (15.8 vs ~11 TOPS) but shares the device with the compositor and
the system; its numbers come from `interp_*` stats on the device. Budget: under 6 ms mean, memory under 100 MB: met on
the Mac with the default; p95 over 6 ms, which only delays a frame's layers (the warp uses the frame without them until
then), never the warp itself.

Smoke (`tools/interp_model.py smoke --steps 1500`, synthetic: a panned textured background, 2-5 nearer textured
objects with their own motion, gaps 0.3-2.2 intervals; 256x160 crops, MPS, 3 min): held-out loss 0.632 -> 0.366,
picture L1 0.247 -> 0.126 against the plain composite (fill = frame, the game's motion); export: Core ML vs PyTorch
mean |diff| 0.0002 (fp16). `train --data` on the Mac test's capture: 23 pairs, loss down, exported (the loader path).

Status: capture, model, training, export, bench and the app skeleton built (ddgame61 and a build without them without the
optional files both compile). Untested: anything on the headset (the capture's cost there, deflate time on M2, the
stats, the Neural Engine's time beside the game), training on real data, the warp's use of the layers.

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

## Game-side foveation: feasibility, and the per-pass GPU profile (h63d, 2026-11-01)

The goal: the game itself rendering the periphery more coarsely, since it is GPU-bound (2.5.0 native 1600x900,
~11-17 fps, `game_gpu_busy_pct` ~73 % under the pacing cap) while the 90 Hz warp shares the GPU. Display-side
foveation (ddgame60e) gave nothing (the warp's logical size grew to 4493x3604).

Evidence at hand (no per-pass numbers yet - the profile below is for them):
- Headset logs, game command-buffer time a frame = busy share / fps: 2.5.0 native 1600x900 (h54-h54c, before the
  cap) 95 % at 12.9-14.5 fps = ~65-74 ms; 2.3.2 with the game's dynamic resolution (h51/h52, targets 1067x600 to
  1600x900, no MetalFX encode) 93-96 % at 16.5-18.6 fps = ~52-58 ms; 2.3.2 1280x720 out at 853x480 (r91) 94 % at
  22 fps = ~43 ms. A line through them: ~35 ms a frame that does not follow the render size plus ~22 ms per million
  pixels - at native about half of the frame scales with the pixels. Rough: two builds, different scenes and warp
  settings, and a command buffer's GPU interval includes time the warp held the GPU.
- h59's dump (2.5.0 native, one gameplay frame): 63 compute encoders (the lighting / post chains, 6-18 kernels each,
  reading the G-buffer and depth by pixel through their argument buffers), ~27 render passes with work at 1600x900 plus
  13 clear-only ones; the G-buffer is 4 passes with only 4-8 pipelines (GPU-driven drawing), then forward passes load
  its depth-stencil (format 260); 19 passes at 32x32 and 6 at 64x64 (probes), shadow maps 1024x1024 / 2048x2048, a few
  800x450 / 800x900 (half-size effects).
- The headset's settings (avp_mac/settings, 2026-11-01): every effect at its lowest already (SSR off, AO off,
  volumetric fog Low, clouds off, cascades / distant shadows Low, LOD Low, crowd Low, RT off); ResolutionScaling Off and
  DynamicResolutionScaling off: the one lever left in the game's own menu is the render resolution.

Verdicts:
- (a) Rasterization rate maps on the heavy passes: not feasible as a first step. Only render passes take a map (the
  lighting, the screen-space effects and post are compute here), the targets must be the map's physical size, and every
  consumer reads the compressed layout. A boundary exists - after the last G-buffer pass, before the first lighting
  kernel - where our own pass could resolve the 4 colour targets and the depth-stencil (stencil export) to linear
  (~0.5 ms of full-size writes), but it would only save the G-buffer passes' fragment work (GPU-driven: much of their
  time is vertex / visibility, which a map does not reduce), and the blocky periphery feeds lighting, shadows and the
  temporal AA. Worth it only if the profile shows the G-buffer's fragment time is large (over ~8 ms).
- (b) Lowering chosen passes by interposing their targets / viewports: not feasible blind. The converted shaders address
  by pixel and by sizes in constant buffers we cannot see (empty reflection); a smaller target breaks every reader. The
  game's own quality settings do this correctly and are at their lowest. The profile names the heavy groups (pipeline
  hashes); a targeted fix would start from one of them.
- (c) The game's settings: feasible now - the render resolution (MetalFX Performance / Balanced, or dynamic
  resolution). `tools/cp_settings.py native900` (today), `p900perf`, `drs`, `drs_mfx` (h63d) for the A/B with the
  profile on. Never on UserSettings.orig.json; cp_settings keeps the previous file.
- (d) Dynamic resolution: the Mac build has it (DynamicResolutionScaling, DRS_TargetFPS / Min / Max, MetalFX
  "Dynamic"); 2.3.2's h51/h52 ran it (1067x600-1600x900). The warp already resamples the frame over the eyes, so a lower
  render size is upscaled there (periphery included); with MetalFX Dynamic the game's own temporal upscale may run (then
  `fx_encodes` > 0 and the presenter gets MetalFX's depth / motion). Our pacing holds commits on the CPU side; whether
  the game's controller sees that (CPU frame time) or only its GPU time is for the run to show (its render size in the
  "colour target" / pass-profile attachment sizes over time).
- No `VXMAC_GAME_FOVEA` prototype in this build: neither (a) nor (b) is clearly feasible without the per-pass numbers,
  and the resolution lever exists in the game. The profile's "screen-proportional" line is the most any of them can save.

### The per-pass GPU profile (`shims/vxprof.m`, `VXMAC_PASS_PROFILE=1`; off by default)

Off: nothing is installed (the hooks' calls test one flag), the game's descriptors and calls as before (Mac test: the
same results with libvxmtl absent, present, profile on). On: every 5 s (`VXMAC_PASS_PROFILE_EVERY`, 0 = every frame) a
window of 5 consecutive frames (`_FRAMES`; frames run present to present), 240 windows at most (`_MAX`). Each encoder
made in a window - the game's render, parallel render, compute, blit and acceleration-structure encoders, and ours (the
"VX Mac compositor" queue, and what the host encodes inside the present / pass / target hooks and the UI capture,
marked `ours`) - gets Metal's stage-boundary timestamps (Apple GPUs sample only there: a render pass's vertex and
fragment stages, a compute / blit pass's start and end; ns, GPUStartTime's clock). Render passes: the game's descriptor
is copied with a sample buffer attachment added; computeCommandEncoder / ...WithDispatchType: / blitCommandEncoder /
accelerationStructureCommandEncoder become their ...WithDescriptor: forms (same dispatch type) with the attachment.
Kept per encoder: kind, queue, command buffer, attachments (size / format / load+store), the pipelines set (by their
function's library hash: `f`/`v`/`k` + the 16 hex digits VXMAC_PIPE_DUMP prints after `#`), dispatches and threads.

Time per encoder: its stages' intervals (a render pass's vertex and fragment apart - the wait between them is not its
work), and its share: the window's GPU time cut at every stage start / end, each slice split evenly among the stages
running in it (a tile GPU overlaps passes: spans add up to more than the frame, shares to the union of busy time).
Alternate windows are serial (`VXMAC_PASS_PROFILE=1`; `=overlap` / `=serial` for one kind): each of the game's
sampled encoders waits (MTLFence) for the one before it in the same command buffer - its own cost, without neighbours.
Only within one command buffer (encoders there run in order, so a wait can never be on later-submitted work), never on
ours; ordering only, the game's hazard tracking untouched. Serial frames are slower (the overlap is lost): a small
hitch every 10 s while profiling. A window's first frame (lead=1) is written but left out of its totals (it can overlap
the unsampled frame before). Limits: a stage's interval includes waits (a hazard on another queue, the warp holding the
GPU) - sampling ours makes the warp's slices shared rather than charged to the game, but a wait with an idle GPU stays
in the stage; compute encoders hold several kernels each (6-18 in the game) and are timed as one (per-dispatch
counters are not supported on Apple GPUs).

Output `Documents/pass_profile.txt` (`VXMAC_PASS_PROFILE_FILE`): `PPROF` (settings), `PENC w<win>.<frame> ...` (each
encoder: k, ours, q, cb, start / span / vtx / frag / share ms, pipeline sets, dispatches, Mthreads, label, att,
pipes), `PFRAME` (busy, game_ms, ours_ms, command buffers' busy, by kind, mode, lead, driving), `PWIN` and `PTOP`
(the window's groups by share). Host log: one "Metal: pass profile w<n> (overlap|serial)" line per window with the
eight heaviest groups; stats `pp_frames`, `pp_encoders`, `pp_busy_ms`, `pp_span_ms`, `pp_dropped`.
`tools/pass_profile.py FILE [--dump PIPES] [--all] [--top N] [--scene WxH]`: per mode the game's ms a frame by kind
and ours; the time by class (render at the scene size / half / quarter, square shadow-like targets, small; compute with
threads >= 0.2 of the scene's pixels vs small; blit) and the **screen-proportional** total - the most a lower or
foveated render resolution could save; the heaviest groups (with p-numbers and labels from a VXMAC_PIPE_DUMP file of
the same build). Head-look frames only when there are some (driving=1).
Mac test: `tests/pass_profile_mac.m` + `.metal` (build / run lines in its header): a heavy and a light pass, compute
by computeCommandEncoder and ...WithDispatchType:Concurrent, a blit, a compositor-labelled queue, `PP_THREADS=1` for
four command buffers encoded at once; M1 Max serial: heavy 16.4 ms, light 1.2, drawable pass 0.06.

Headset run (the user drives; install / launch are the parent's): ddgame63d with `-env VXMAC_PASS_PROFILE=1`
(optionally `-env VXMAC_PIPE_DUMP=pipes.txt -env VXMAC_PIPE_START=engage` for the names), 3-5 minutes of head-look
gameplay (a street, indoors, driving); pull `Documents/pass_profile.txt` and `vxmac_host.jsonl`; then
`tools/pass_profile.py pass_profile.txt --dump pipes.txt`. Read: the game's ms a frame in overlap vs serial windows,
ours (the warp's share of the GPU in the game's frame), the screen-proportional line, the top groups (the G-buffer's
frag_ms decides (a)). Then the same with `cp_settings.py p900perf` / `drs` (and back to `native900`).

## The long session's memory and the 45 Hz GPU share (h64, ddgame64)

ddgame63d, default settings, 30 min (181 `mem` lines), at 32 s / 902 s / 1782 s:
- **malloc_small is the unbounded part**: 99 -> 655 -> 976 MB (DefaultMallocZone 1.5 M -> 10.2 M -> 18.8 M blocks):
  ~9000 blocks a second net, ~50 bytes each, ~21 MB a minute, linear to the end. Not tied to pipeline creation (the
  bursts at 1042 s and 1202 s, +600 / +1200 pipelines, left the rate at 8.8-9.2 k/s), nor to the frame rate (vr at 8-13
  fps and screen at 50-120 fps: 9-14 k/s), nor to the foveated SR's predictions (6-75 a second); it follows the game's
  command buffers (~550 a second in vr, ~16 blocks each). Who allocates it is not in the log: hence the trace below.
- untagged (the game's pools) 2887 MB at 82 s -> 3275 at 1202 s, then flat to the end (3274); the game's committed VM
  (recommit - decommit) flat at ~3.17 GB from 1042 s: **the game's pool fill, it plateaus**. ioaccelerator 405 -> 677
  MB, levelling.
- Metal: render pipelines alive 3640-4160 (bounded: the game drops and makes them again, 7814 made, ~170 a minute after
  15 min), libraries alive 4 of 4406 made (each made from bytes and freed after its pipeline), compute 758 made once,
  UI twins 66-67 the whole session. Nothing of ours multiplies: twins only for the UI vertex shaders' pipelines, none
  retained beyond the game's; the binary archive hook only logs (the game opens 4 `default-binaryarchive-N.metallib`).
  So no library / pipeline cache of ours is needed for memory (one would keep what the game frees).

What h64 adds (all in this build):
- `VXMAC_MALLOC_TRACE=<N>` (off by default; shims/vxmtrace.c in libvxsystem): libmalloc's `malloc_logger` hook (what
  MallocStackLogging uses) keeps one address in N (by a hash of the address: its free found by the same test) with its
  size and stack (frame pointers, 20 frames); fixed tables mapped once (1 M blocks, 64 K stacks), no malloc in the hook.
  The `mem` line gets `mtrace` (rate, est_mb / est_blocks = sampled x N, stacks, dropped, the top three by their first
  frame outside the allocators); `Documents/malloc_trace.txt` every 60 s: the 30 stacks holding the most, frame by frame
  as image+offset (symbol), each with its MB/min since the last report. Mac test `tests/mtrace_mac.m`: 300000 x 64 B
  kept from `leak_c` and 200000 objects from `leak_objc`, a malloc/free churn and reallocs alongside: est 17.8 / 12.1 MB
  for 18.3 / 12.2 real, churn absent (rate 64; also at 128).
- Our records on the game's encoders (depth / target / UI / camera-scan keys) are dropped at its endEncoding, not left
  to its dealloc (`VXMAC_ENC_CLEAR=0`: as before). A sampled probe (1 tagged encoder in 16, never dropped) tells
  whether the device frees an encoder's associations with it: `mtl.enc_probes_live` stays near 0 if so, and grows with
  the encoders if not (then that was the leak and the drop fixes the rest). Mac (`tests/enc_assoc_mac.m`, 60000 command
  buffers x 4 depth passes with the pass hook): malloc flat (-1.7 B per command buffer), probes 15000 made / 0 live.
- Pipeline creations counted in `mtl`: `libs_distinct` / `libs_repeat` (a library made again from the same bytes),
  `rp_distinct` / `rp_repeat` (a key over the functions' library hash + name and the descriptor's state), `rp_ms`
  (total on the game's threads), `rp_ms_max` (the slowest since the last line), `rp_slow` (over 16 ms),
  `rp_with_archives`, `game_arch_adds` / `game_arch_writes` (the game's own binary archive calls; its first writes logged
  with the path). The archive log line now has the full path. rp_repeat close to render_pipes_made - 3700 means the
  game's own cache drops and remakes the same pipelines (then rp_ms / rp_slow say what it costs a fight).
- `VXMAC_PIPE_ARCHIVE=1` (off by default): our binary archives in `Library/Caches/vxmac_pipes/<device>-<OS build>/`
  (never the game's folders): each game render pipeline is made with them added to its descriptor's binaryArchives (a
  miss compiles as before); a new one is added on a background queue (Metal compiles it there once more), written
  every 60 s / 400 adds / on going to the background (a<n>.bin, 16 files at most, reopened from the file after), keys in
  keys.bin; `mtl.pa` {files, adds, add_fail, add_ms, saved, known (made with its key already archived), used, keys}.
  Mac (`tests/pipe_archive_mac.m`, 240 pipelines from bytes): run 1 adds 240 (33 ms on the queue), writes a0.bin in
  646 ms; run 2 / 3 make all 240 with `MTLPipelineOptionFailOnBinaryArchiveMiss` and an empty archive of the game's
  (the control without ours: 240 of 240 fail) - served from ours. Not default: on the Mac the system's own shader cache
  already makes the second launch fast (240 in 67 ms without, 86 ms with ours), and an archive being filled holds its
  binaries in memory until written. Worth it only if `rp_slow` / `rp_ms_max` show compile hitches on the headset.
- `VXMAC_GPU_CAP_HALF=<cap>` (off by default, try 0.85): ddgame63d's compositor sat at 22.2 ms (half rate) in 335 of
  356 windows; there the cap (0.70, 0.55 after misses) held the game back - its commits waited 1257 ms of every 2 s
  (median), game GPU busy 74 %, 11.2 fps - while the warp needs half the GPU time it has at 90 Hz. With the variable:
  after 3 windows (15 s) at 21-24 ms the cap's start becomes <cap>; a window under 15 ms (90 Hz back) restores
  VXMAC_GPU_CAP. The misses rule stays (over 3 in 5 s: 0.05 lower, to 0.55; six clean windows: 0.05 up to the start of
  the rate it is at). Logged ("the compositor at 22.2 ms a frame: ... cap 0.70 -> 0.85 (half rate)"); stats `gpu_cap`,
  `gpu_cap_half`. Not default: at 45 Hz the deadline margin's per-window minimum was 2.7 ms (median) and below 0 in a
  tenth of the windows already at 0.70. Expected gain if GPU-bound: at most 0.85 / 0.74 of the frame rate (+15-20 %).
- `Documents/vxmac_now.json`: ~700 bytes every 5 s (a temporary file renamed over it): t, since_start, game_fps,
  compositor_hz, mode, footprint / available / peak MB, malloc MB and blocks, thermal, gpu_cap, gpu_cap_half,
  game_gpu_busy_pct, pace_ms, warp_gpu_ms, interp, render_pipes_made / render_pipes / rp_repeat / rp_ms_max,
  enc_probes_live, and `mtrace` when the trace is on (-1: not known yet).

Headset run (ddgame64; the user drives): `-env VXMAC_MALLOC_TRACE=128 -env VXMAC_GPU_CAP_HALF=0.85`, 25+ minutes of
play including a fight; fetch `Documents/vxmac_now.json` during it, `Documents/malloc_trace.txt` and the jsonl after.
Read: malloc_trace.txt's top stacks with MB/min near the malloc_small slope (~20 MB/min) = the owner; enc_probes_live;
rp_repeat / rp_slow; at 45 Hz the cap 0.85 against `missed` and `deadline_margin_min_ms` in compositor_pacing, and
game_fps / pace_ms against ddgame63d (11.2 fps, 1257 ms). A pass profile (`VXMAC_PASS_PROFILE=1`) on a later run, not
with the trace.

## Fights, ADS and controller aim (h64, ddgame64a)

From hab1's runs with fights (`d.jsonl` 1800 s, `m2.jsonl`): `vr_auto` gave 9 Screen spells of 6-28 s (no 3D view) and
`warp_mode` / `manual_toggle` never - the "switching" was the head-look detectors, not VR/Screen:
- `vehicle_mode` flipped 162 times (81 entries, nearly all at FOV 110.6 = the on-foot FOV; the bike measured 82-90 in h57e): the
  pivot test reads strafing while turning as an orbit (|v / w| = 2-7 m). Each entry stopped head pitch (sent pitch
  frozen, e.g. 1448-1460 s) and pulled the frame's pitch within 10 deg of the head; `pitch_follow` flipped with it.
- `axis_freeze` 127 (89 pitch "camera moves itself": recoil, aim snap / assist, ADS's zoom read as a row shift): 1 s
  of no head pitch each time, then a catch-up.
- the pitch account drifted 40-60 deg from the head (`vr_sent_pitch` vs `vr_head_pitch`, 300-470 s; `pitch_clamps`
  ~800) from the head pitch vehicle mode absorbs, and a pitch limit was learned from a menu cut at 1429 s (-28.7 deg)
  and kept for the rest of the session.

Fixes (on by default, each with its switch): the combat gate (`vxmac_combat_input`: triggers, mouse buttons; plus 1 s
after an FOV change) - no vehicle entry, no `pitch_follow` verdict, no "camera moves itself" freeze while it holds
(`VXMAC_COMBAT_GATE=0`: as before); vehicle entry also needs the pivot with the camera's own translation taken out
over 1.5 m, 2 s; the pitch axis checks read the game's own pitch (view matrix) when both frames have it; the pitch
account rebased at vehicle exit (`pitch_rebase` log); no picture-learned pitch limit while the game's pitch is read,
limits reset at each vr zero (`VXMAC_PITCH_LEARN=1`: the old rule); a frame without a device anchor keeps the last
head (`head_tracking` log, `VXMAC_HEAD_HOLD=0`). New logs: `vehicle_signal` pivot_vc_m / combat / gated_*;
`axis_freeze` src / sent / seen / combat / fov; `game_cam_yaw` free_gain / aim_gain (the game's yaw per sent yaw,
aiming or not); `aim_mode`.

Warp mode 7, free look + controller aim (`VXMAC_AIM=1` starts in it, `VXMAC_AIM=cycle` only adds it to the cycle;
unset: modes 0-6 as before). The head looks around inside a cone (`VXMAC_AIM_CONE=20,12`, yaw / pitch half-angles)
without moving the game's camera; the frame stays world-fixed where the game camera points (mode 6's rendering);
past the edge the camera is pulled along (yaw 1:1 at the edge, pitch by a loop on the game's own pitch); the right
stick's pitch reaches the game; the HUD's centre (`VXMAC_AIM_XHAIR=0.05` UV half-width) is drawn at the frame's
centre in each eye, so the crosshair shows the gun's aim, not the head's. `VXMAC_AIM_DRIFT=<deg/s>` (default 0): the
camera drifts toward the head inside the cone. The game's crosshair cannot be moved apart from its camera (it is the
screen centre of the UI pass), hence the cone.

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

## h67: the long-session memory fixed (audio HAL off by default)
ddgame66's headset A/B: with the HAL (A, 51 min) Wwise's AK::AudioMgr thread brought 8 HAL plug-ins in at 3.4 s, and
BTAudioHALPlugin's XPC handler on a never-idle GCD worker autoreleased into a pool that never drained: malloc_small
1.3 GB (~0.95 GB of it BTAudioHALPlugin), footprint 7.8 GB, 374 MB left. Without it (B, VXMAC_AUDIO_HAL=0, 27 min):
0 plug-ins, malloc 0.22 GB and flat (top stacks +0.00 MB/min), footprint 5.8 GB, 2.4 GB left; the user heard no
difference (sound, panning, volume). Now the default; VXMAC_AUDIO_HAL=1 restores the HAL path.
