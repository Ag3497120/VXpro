# Weapon interaction update, November 9

Changes prepared for the recording `ScreenRecording_11-09-2026 15-00-05_1.MP4`:

- Grip shape storage is keyed by skin consumer, not only a skeleton joint name. Hand, nails and cyberware retain their own inverse bind transforms across material passes.
- The local asset adapter can identify short sleeve and finger palettes by index fingerprint and exact named-bone order. A helper bone's non-rotational matrix no longer truncates an identified palette. The private numeric catalog was generated from the player's owned base-game and Phantom Liberty resources; no geometry is included in the source tree.
- Melee models can bind their root to the authored palm without a trigger joint. Swing detection is enabled only for an equipped non-ranged weapon during tracked gameplay. It rejects head translation, tracking discontinuities and repeated samples; each stroke sends a short standard attack input. Menus, vehicle/story contexts and controller mode disable this path.
- Mounted scope parts share the receiver correction. Rigid passes that omit skinning use a private instance transform only when the part is identified or shares the identified receiver instance. Native instance data remains unchanged.
- The host requests direct delivery of Menu/Options events using GameController's public system-gesture preference. It resolves combined and split Joy-Con profiles and input remappings. Holding both buttons for one second toggles control mode once; both must be released to rearm. A single menu action is delivered on release, and a chord does not open either menu.

Local checks passed: actual Metal draw fixtures for skin/rigid attachment copying and native binding restoration; separate grip consumers; small named palettes with deformed helper matrices; the owned crowbar root adapter; swing recognition and release; GameController profile/chord fixtures; existing reload, support, camera, menu and runtime checks. `make -C VXRuntime check` passed.

The app update changes the host executable and Metal pose shim. The other 33 payload files, including the existing cloud-authentication and game-script payloads, are identical to the previous installed candidate. Device readback confirms the same 1280 × 720 graphics settings and persisted launch arguments.

Installation completed. Gameplay verification of the reported arm/finger artifacts, physical button chord, melee swings and individual scope lenses remains pending. Local GPU fixtures do not establish that every in-game weapon or material pass is corrected. No new FPS measurement is claimed.


## Follow-up from the 17:04 and 17:08 recordings

The player confirmed the physical mode chord and tracked swing attacks work. The black sleeve, extra handgun fingers, separated melee grip and scope lens still appeared; the preceding local fixtures did not demonstrate those visual fixes in the game.

Read-only inspection of the owned `basegame_4_appearance.archive` identified the actual runtime sleeve hashes (`57fdc635f10e8148` / `fb1cf43e99da8f8d`) and finger hashes (`7e3b26a3528dc182` / `d23c6b8b7f119776`). The preceding catalog only covered the gamedata and DLC archives and missed these appearance consumers. Clothing shares index data between distinct 12- and 16-joint layouts. The catalog now preserves those alternatives and resolves them against named, unmodified joints of another body draw in the current frame. Identical named layouts are deduplicated, including supported `_setup` aliases. A not-yet-resolved draw reserves a private native copy so a later body draw can publish its resolved pose before submission. It is never guessed from the unused allocation tail or treated as a weapon.

An offline replay of the actual `e13-s0` source resolves the sleeve to its 12-joint layout, while refusing the same ambiguous identity when anatomical references are absent. GPU fixtures cover the reflected-instance path for a skinned attachment whose shader lacks the verified compact palette-copy contract. Single-joint material variants with another skin stride can also use an identified instance without rebasing unknown palette addresses. These checks are not a headset verification of the scope lens or clothing appearance.

The follow-up changes only the Metal pose shim code. The host executable's unsigned contents and 33 other payload files are identical to the prior installed app; its code signature is renewed. Graphics, camera, authentication, game scripts, mode chord and swing code are unchanged. A bounded opt-in route report retains numeric draw metadata and up to 16 private shader contracts to locate any remaining melee/scope consumer that bypasses correction. No geometry or full GPU arena is exported. The precise missed melee route remains unconfirmed.

## Follow-up from the 23:33 recording

The player reported that all four visual problems remain. The full recording still shows the detached sleeve/fingers, melee grip and scope lens. A CPU palette marked `applied` was insufficient evidence that its material actually used that palette on the GPU.

The corresponding rotated device log records the crowbar's 4,476-index draws with `foreground=0` in the scene depth range, including the verified `d3f3e26df4fc32b2` shader. The preceding foreground-only return therefore skipped those draws before mesh identification. The 4,944-index hand material (`1de951b843f562a9`) also had no allowed private palette span. Its CPU pose could be calculated while its actual draw retained the native binding. Further read-only extraction added the owned core hand/cyberware mesh identities and their named layouts.

The new candidate admits exact catalog consumers outside the compressed foreground depth range, gated by equipped weapon/context and the current player's source pose. Such consumers cannot establish the head/reference camera. Early consumers reserve native private palette copies and receive the later foreground hand solution before command submission. Known meshes using reflected byte joint indices can use a bounded 256-matrix copy without rebasing an unverified shader's `baseInstance`. Anonymous geometry remains excluded from that material fallback. No original palette or instance data is written.

A GPU regression fixture now passes the owned crowbar index identity through the actual scene-depth routing, encodes an early draw, publishes the later palm pose, and verifies the resulting pixels. It also checks an unverified material retaining its instance base, controller-mode restoration, and rejection when another weapon class is equipped. Existing appearance, reload, support, menu, mode-switch and swing checks passed. These local fixtures still do not establish that the reported in-game visuals are fixed.

The preceding library-export diagnostic had no retained source bytes and did not produce the intended shader files. The new diagnostic captures only five observed contracts at library creation (each bounded to 2 MiB), rather than retaining the game's whole shader collection. A bounded consumer report records whether each identified material was actually rebound. Exact shader behavior and live appearance remain to be verified on the headset.

Only the Metal shim code changes in the packaged candidate. The unsigned host executable and 33 other payload files match the installed predecessor. Graphics, camera, input, game scripts and authentication are unchanged. No FPS improvement is claimed.

## November 10 status

The player reported that only the extra handgun fingers were resolved. Detached sleeves, melee grip separation
and scope lenses remain reported issues. Follow-up local fixtures cover additional bounded palette rebases,
consumer readback prioritization and opt-in late-submission diagnostics. These are investigation tools, not
evidence that the remaining headset visuals are fixed. The physical mode switch and swing attacks were already
confirmed working. The accumulated source is integrated into `main` in the
[November 10 update](RELEASE_2026_11_10.md).
