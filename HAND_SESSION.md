# Hand/weapon session redesign

Status: experimental render-time hand/weapon adapter with a native equipment/ammunition bridge.
**The engine animation-stage pose writer is not connected.**

Checkpoint, 2026-11-06: the player confirmed the right hand holds the trigger grip on every weapon
currently in their inventory. Some shotguns and machine guns still have a supporting-hand intersection.
This snapshot precedes further left-hand corrections. A universal weapon profile, complete physical
reload behavior, physical shot-ray integration and a measured FPS improvement remain unproven.
The implementation history below includes earlier rejected approaches and failed builds.

## Agreed behavior and first proof

Keep the weapon in the right hand. The left hand follows tracking freely except during an explicit
support, magazine or slide interaction. A head turn, hand height, tracking gap or proximity alone
must not attach the support hand. Start with one identified handgun and its exact grip, magazine
well and slide transforms. Do not infer a universal profile from draw counts or weapon length.

Prove a complete eject → acquire magazine → insert → manual rack → fire cycle, with the game's
actual ammunition, before expanding the pose writer to other weapons. Later, long guns keep manual
magazine insertion, automatic chambering and ZL-held support/ADS as requested.

## Ownership and clocks

1. ARKit publishes head + both raw wrist poses + Joy-Con buttons as one immutable, numbered room-space
   sample. This input contains no gun attachment, hand-height clamp or camera-relative correction.
2. The game thread latches that sample together with the equipped weapon identity and native state.
   A future pose adapter produces both hand targets and the weapon transform from this one latch.
3. The weapon transform is `room_from_right_palm * inverse(weapon_from_right_palm)`, using a measured,
   fixed profile. Its source must not be a fresh estimate from the currently animated GPU draw.
4. Support, magazine and slide contacts use that same weapon-local frame. Only the explicitly held
   interaction constrains the left hand. The raw tracked left-hand target remains separate.
5. Game state owns magazine/chamber readiness, ammunition and firing. A command acknowledgement means
   accepted, not loaded. Only the native reload/ammunition report establishes completion.
6. Apply the solved pose at a verified game animation stage, consistently across that animation update's
   passes. GPU skinning receives the result. It must not independently solve or learn another grip.

The present `shims/vrik.inc` render-time solver remains the legacy implementation. The new raw sample
does **not** yet replace its output. Likewise, camera steering is not proof of engine muzzle-ray control.

The legacy renderer now latches one game-space rigid correction after a validated current right-hand
pose is available. The receiver and mounted parts conjugate that same correction by their own object
transforms, instead of independently retargeting each part to the palm. It keeps the correction for
the rest of that frame even if another arm pass arrives. A preliminary wrist draw no longer takes
precedence over a validated current hand. The native left-hand support frame follows this same
latch; a pistol part cannot replace it with absolute coordinates near an assumed model origin.
The previous cache path still handles missing captures. This is an incremental containment change,
not the engine animation-stage replacement or a universal weapon/contact profile.

## Native input isolation (2026-11-06)

The user's 06:50 recording still shows long-gun magazine separation, incorrect grip and large movement.
The six one-second overview sheets cover its 136.75 seconds; magazine separation is visible from about
1:12 onward. Live status also confirmed valid hand publications and actual equipment/ammunition reports.
The player controller and typed root vtables were observed at `0x7cf0ab0` and `0x7cefef8`. Named weapon
controller/root probes remain absent. These observations do not validate an engine pose writer.

The legacy renderer previously modified the game's shared bone storage. A later palette capture could
therefore treat a VR-transformed matrix as native input. The output is now separate CPU storage and a
private Metal copy for each palette consumer and object transform. The cache includes geometry identity;
overlapping native addresses cannot share recognition or output state. Another draw's address no longer
truncates the current draw's transformed range.

Each private instance record rebases its skinning offset to the private palette. The native root, descriptor
table, instance record and bone storage remain unchanged. The next draw restores native bindings, including
dynamic strides. Multi-instance draws are not rewritten by this single-instance adapter. Output publication
is sealed under the pose lock before command-buffer commit, and resources remain owned through GPU completion,
including commands using unretained references. No native source writes or in-flight GPU writes are permitted.

The first isolated-output build incorrectly copied each consumer's entire native-readable tail. The user
reported a crash immediately after installation. `nov06-live/status-crash.json` records 7,720 MB footprint,
54,050,592 bytes for the largest palette copy and 10,626,105,536 cumulative copy bytes at 197 binds. This build
is rejected. The system crash listing had not yet produced a report establishing the termination reason;
the measured allocation increase is direct evidence of this implementation's excessive memory cost.

The replacement uses 21 saved shader libraries' AIR as evidence of the skin addressing formula and checks
the actual pipeline's `blendindices` formats. Only verified libraries with unsigned-byte indices receive
compact copies, at most 256 * 48 = 12,288 palette bytes. Unknown or wider variants are counted as skipped;
they never trigger a full-arena copy. Instance-record staging is separately capped at 256 KB. No game shader
code/assets are redistributed: these private inspection artifacts remain in ignored build output.

The AIR also shows that velocity passes read `skin.z`, the previous palette offset, as well as `skin.x`.
Both offsets now point into the compact posed palette. Skin motion history is stationary in this intermediate
foreground adapter; it is not a verified prior rendered pose history. It prevents the native animated arm
palette from being mixed with the tracked current palette, but its visual/TAA effects require headset testing.
The native animation-stage writer and correct prior rendered pose history remain future work.

The user could load the compact build but reported the normal controller-only weapon presentation. The closed
`nov06-live/program-compact-closed.log` records both wrists tracked and arm solves; the atomic loaded snapshot
records 6,068 MB footprint, a 12,288-byte largest palette copy, 6,718 binds and 47,069 skips. These establish
that input and some processing continued, not that the processed data was consumed by the intended draw.

Inspection found the render interceptor called the pose binding **after** forwarding the native draw. That was
compatible with the old shared-buffer overwrite, but incorrect for private argument/palette bindings: the draw
had already been encoded. Pose preparation now precedes forwarding in every primitive/indexed draw entry point;
post-draw HUD recording stays separate. The earlier direct-binding shader test did not cover this boundary.

The dispatch test now follows the real indexed hook into an actual GPU draw, checks its pixels, follows it with
a native primitive draw and checks that the VR binding is restored, then exercises constant instance input.
It also uses base instance 4096 (over the old 256 KB prefix limit). Verified shader families whose instance_id
is unused and whose active instanced attributes all share one binding use a single private record and a zero
draw base instance. Other bindings retain their native indexing. Constant inputs use their single record;
their base instance does not change. The real bound palette remains limited to 12 KB. These boundary tests
do not establish that physical alignment, jitter or weapon-specific interaction is correct in the headset.

The atomic status includes cumulative `pose_copy` byte/time counts, largest allocation and bind/skip/unposed
counts so device evidence can establish activation and cost. Unchanged FPS has **not** been established;
do not infer physical grip or visual stability from these counters.

Local tests cover overlapping sources/outputs, repeated passes, late updates, base-instance rebasing,
dynamic strides, restoration and commit sealing. An offline-compiled Metal shader reads through the real
private root/table/palette chain, including history and bone index 255, and produces checked pixels. A 54 MB
source-arena fixture verifies that output allocation/copy volume stays compact. Optional saved-shader reflection
tests cover all 21 observed skinning libraries and refusal of wider/unknown variants. A separate test injects the actual Mac shim
and verifies ownership through encoder end and release after command completion. These do not exercise the
game's shaders, animation system or physical grip and do not establish that this recording's symptoms are fixed.

## Support contacts and body coordinates (2026-11-06, 09:16 user recording)

After the dispatch build, the user confirmed both hands follow tracking, magazines no longer separate,
with reduced but remaining jitter. The 251.89-second recording was sampled at one-second intervals
through the end. Handgun support crosses the holding hand; the SMG grip separates visibly at raised
angles. These are unresolved device observations, not a completed handling implementation.

Body draws admitted as the same player may have different object transforms (up to the existing
4 cm / rotation tolerance). Their captured joints previously entered the shared IK model without
conversion. Captures now enter the selected body's coordinates; an output consumer with another
object transform solves in that same space and converts its matrices back. The CPU palette consumer
key now includes object and view matrices, like the independent GPU output key. A changed transform
cannot reuse an already-applied solution for another consumer.

Only validated current left/right hands establish a support reference. The support wrist and finger
pose are latched in the holding-palm frame for one explicit ZL support interaction, released with ZL
and reset on equipment epoch changes. Native idle/ADS/reload updates cannot repeatedly choose a new
contact during that hold. Palm capsules sized from each rig's metacarpal width project an overlapping
support palm outside the holding palm before latching. This is a palm-volume constraint, not full
finger/forearm/weapon collision detection or a verified per-weapon contact profile. Cached authored
hands from a previous equipment epoch cannot seed the next weapon.

Local tests exercise equivalent body draws with different origins/rotations, the holding palm reaching
one room target from those draws, intersecting palms at multiple angles, button/epoch contact lifetime,
and support bones staying fixed relative to that contact despite changing source animation. Existing
immutable-source, 12 KB copy bound, GPU dispatch and resource ownership tests remain required. These
tests do not establish actual machine-gun grip accuracy, absence of all intersections, eliminated jitter,
or unchanged headset FPS. The native animation-stage writer is still unconnected.

## Retrieved device evidence (2026-11-05)

The closed 42,295,474-byte program log was retrieved after the user saved and quit. It contains the
mailbox handshake, eject/insert acknowledgements and native ammunition reports. Long guns returned
to phase 0 with full magazines. Handgun entity 10022705 / record 131270002750 reached phase 5 with
12/12 rounds: loaded, waiting for its manual slide. There were no kind-3 chamber submissions in
this log. This verifies command/ammunition synchronization, not the physical rack or the gun pose.

The live player's animation-controller context consistently reported vtable RVA `0x7cf0ab0`.
The named weapon `animController` was absent; that binding remains unresolved. Offline comparison
identified ARM64 RVA `0x266cc08` as the pose-apply candidate: two callers, 48-byte parent-local pose
copies and the same descriptor accesses as the reference implementation. It has direct callers,
not an identified writable virtual-dispatch slot. No hook or pose write at this address is installed.

The native PhysicalRay candidate is RVA `0x1ddf538`, vtable `0x7921250` slot `0x130`. Its position
and forward evaluator calls are at `0x1ddf5a8` / `0x1ddf650`. These are static findings only; the
player-firearm ownership filter, native shared-data layout and on-device ray origin/direction have
not been verified. Redirecting all rays or only the camera is not an acceptable substitute.

## Implemented foundation

`app/Sources/weapon_bridge.{h,c}` now contains:

- Complete head/wrist/button publications, with sequence numbers and freshness checks. A stale/invalid
  sample becomes invalid instead of inventing a height-limited replacement pose.
- An optional game-thread mailbox for eject/insert/chamber commands. Each pending command includes entity,
  record, equipment generation and a monotonically increasing serial. Replies must match all of them.
  Equipment changes discard pending commands. Unacknowledged commands expire after two seconds.
- A 2.5.0-only native adapter using writable VM dispatch data. The shipping report callback receives replies.
  The global `IntToString` callback intercepts only `I32Const(0x56584832), ParamEnd`; every ordinary call goes
  unchanged to the shipping callback, with its argument expression evaluated only once.
- A read-only probe of the current script VM's live animation-controller context. Its vtable must be inside
  the recognized game image. The probe records image-relative function entries for offline inspection; it
  calls no virtual method and reads no guessed class/IK fields. The context is not retained and no bone,
  IK controller or game transform is written.

`vxhands_manual_mag.reds` polls this mailbox on the game thread and acknowledges exact request serials.
Legacy input callbacks and the mailbox share one command executor; a running mailbox prevents the legacy
Reload/F10/F11/F12 path from executing the same command again. Existing native ammunition confirmation remains
in place and must still be verified in game.

`vr/xros_vr.m` publishes raw tracking packets. In mailbox mode it submits reload requests through the native
bridge instead of private keyboard actions. Rejection/timeout restores the gesture state to the latest game
report and cannot manufacture ammunition or a successful chamber operation.

## Native connection investigation

The local ARM64 2.5.0 image contains animation-controller IK target add/remove handlers and the animation rig
types. This establishes that engine-side facilities exist, not that they control the player's final FPP pose.
Windows addresses, structures and detours cannot be used without validating the Mac implementation.

The diagnostic overlay calls a method on the player's actual animation controller. It also looks up the
weapon's named `animController`; a missing component is reported, not guessed from a mesh. The native report
handler observes the live caller via the VM frame's context. The next device evidence must establish the exact
native types/layouts and then the supported route into player/weapon animation. Do not enable an engine writer
on the basis of synthetic tests alone.

The current overlay also queries each entity's typed `AnimatedComponent` named `root` and reports its name via
the game's `IComponent.GetName` API. No guessed component-array layout is read. The existing atomic
`Documents/vxmac_now.json` now includes `weapon_bridge`: real equipment/ammunition state, command readiness,
raw hand sequence/validity, and cumulative image-relative vtable observations in this order: player controller,
weapon controller, player root, weapon root. These are observations, not retained object bindings or proof of
a functioning pose writer. The small status file can be retrieved while the game is running; the 42 MB stdout
log is no longer necessary for this handshake check.

No game executable instruction, original game asset, save or original script bundle was edited. All overlay
outputs and header-only local test images live under ignored `VXMac/build/hand-session-v2/`. No Windows DLL,
MinHook, GPL implementation or third-party game asset was copied into the implementation. The SDK's reflection
descriptions were consulted as layout clues; Mac vtable/layout verification is still required before use.

## Checks and activation

Run from the repository root:

```
sh VXMac/tools/check_hand_session.sh
make -C VXRuntime check
```

After `make -C VXMac/shims mac`, setting `VXMAC_TEST_METAL_SHIM` to the absolute Mac `libvxmtl.dylib`
path also runs the real-hook resource lifetime test in `check_hand_session.sh`.

The optional first argument to `check_hand_session.sh` is a private local macOS-header copy of the player's 2.5.0
dylib. That test loads its initializers, never its game entry point. It verifies real native IntToString/string
assignment code with a fixture literal operand decoder, because the full game's VM is not initialized there.
It does not test a running game's animation, inventory or input loop.

The new route is off by default. The matching host and three-file manual overlay must be installed together.
For the current diagnostic milestone, add `VXMAC_WEAPON_COMMANDS=1` and `VXMAC_NATIVE_POSE_PROBE=1` to an existing
manual-reload launch that already enables `VXMAC_WEAPON_BRIDGE=1`. Do not activate it in an unsaved game session.

Completion gates:

- [x] Local queue tests: retry, exact acknowledgement, stale reply, weapon switch and timeout.
- [x] Complete tracking publications under concurrent writer/reader access; head motion does not change raw wrists.
- [x] Actual native string callback/return ABI tested without running the game entry point.
- [x] Matching script overlay compiles; Vision Pro host builds and is signed.
- [x] Device mailbox handshake and eject/insert round trips with actual ammunition reports.
- [ ] Exact player/weapon animation-object binding (player controller vtable observed; weapon binding unresolved).
- [ ] Verified Mac game animation write stage or suitable native IK route.
- [ ] One handgun's fixed grip/contact profile, free left hand and complete physical reload in the headset.
- [ ] Engine muzzle direction, repeated pose passes, tracking loss/recovery and performance measurements.

Local checks do not establish visual stability, physical grip accuracy or unchanged frame rate.

## 2026-11-06 private asset adapter

After reconnecting the player's SSD, `tools/weapon_asset_profile.py` and
`tools/weapon_asset_catalog.py` inspected locally unpacked weapon resources. The ignored
`build/hand-session-v2/weapon_asset_catalog.h` contains exact index fingerprints, bone roles
and contact points, not vertex/index geometry. The renderer builds with an empty catalog
when this private file is absent (`VRIK_ASSET_NO_LOCAL` also exercises that configuration).
The external extraction utility is not linked, copied or redistributed with the app.
Conflicting draw identities with different joint layouts are refused rather than inferred
from a weapon's index count alone.

For a matched receiver, the adapter binds the actual root to the displayed right-hand
index contact once per equipment epoch. Native ready/ADS animation no longer recalibrates
that binding. Mounted parts use the same foreground camera transform. Long-gun support
uses a named contact or a point derived from the receiver surface; handgun support separates
the two palm frames using their captured finger extents and rig width. These are rendered
contact constraints, not a general-purpose collision solver.

Named magazine/cartridge masks limit ejection to ammunition joints; mixed palettes retain
their receiver, and carried/dropped ammunition keeps its relative joint transforms. Matched
revolver cylinders have a separate opening transform. Revolvers report kind 3 in both the
script and native bridge, so they do not request handgun slide handling or long-gun support.
Original game data remains read-only; the compiled overlay stays in the app data container.

Local checks cover the root/finger connection under animated native roots and changed draw
cameras, measured support-point placement, ammunition separation and cylinder isolation,
input/reload transitions, private index bounds, and GPU resource lifetime. The private
overlay compiles, the visionOS app builds and its embedded renderer matches the tested
build. These checks do not establish the live source selection, a natural grip on every
weapon, cylinder opening direction, absence of hand intersections or unchanged FPS.
The native animation writer and physical shot-ray integration above remain incomplete.

## 2026-11-06 recorded camera handedness

The numeric recording build retrieved 13 bounded snapshots during the player's weapon
switching session. Five contain both a recognized receiver and the displayed right index
joint. In these samples the game camera has determinant -1, while the body object and
native skinning matrices have determinant +1. The former receiver adapter multiplied a
proper view-space palm basis directly by the inverse camera. That reflected only the gun,
placing its trigger 3.7–6.3 cm from the displayed index contact. This is independent of
which weapons were initially present in the save.

The adapter now transforms the palm's forward/up directions to world coordinates before
building its proper basis. Support offsets use that same physical palm frame in the arm
solver, body draw and published contact. The left long-gun palm faces the lower receiver
surface instead of presenting its back. Input ownership, reload and tracking filters are
unchanged by this correction.

`VXMAC_TEST_REPLAY_DIR` enables optional replay of the player's private snapshots in
`tests/vrik_grip_alignment_mac.m`. All five applicable snapshots reproduce the former
reflection and contact gap as a negative control; the corrected adapter preserves proper
gun rotation and aligns the trigger within 0.02 mm in this numeric replay. The applicable
long-gun support surfaces and palm direction are checked in the recorded body/camera
coordinates. Eight snapshots lack a captured recognized receiver and are explicitly
excluded, not counted as successes. These are local matrix checks, not a headset playtest,
an all-weapon compatibility result or a frame-rate measurement.
