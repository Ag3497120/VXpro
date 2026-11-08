# Direct CDPR cross-progression on Vision Pro

This work restores the owned Mac game's own account/CloudStorage path on the
headset. It does not relay gameplay or saves through a Mac. On 2026-11-08 the
player confirmed CDPR sign-in and that a remote cloud save appeared and loaded
on Vision Pro. Native SDK startup restoration has also succeeded after relaunch. Upload of a new AVP save to another platform and longer account persistence still need verification.

## Opt-in candidate

- `VXMAC_NETWORK=1`: the game's imported curl easy/multi HTTP calls use an original
  MIT adapter backed by Foundation. Otherwise transfers still fail offline.
- Certificate-only DER/PEM import/export fills missing macOS Security helpers for
  the owned RED Galaxy SDK. Existing Security/TLS functions are re-exported from
  visionOS. This does not change trust anchors, import/export private keys, ignore
  certificate validation, modify ownership checks or add publisher entitlements.
- The game can open its CDPR/GOG HTTPS login link using the host browser bridge.
  A browser handoff gives the paused game up to ten minutes before background
  auto-quit. Returning cancels that wait. Background GPU submission stays stopped.
  The QR code can also be scanned on another device.
- `VXMAC_NETWORK_PROBE=1`: one unauthenticated request reads the issuer's public
  OpenID configuration. `Documents/vxmac_network_probe.json` distinguishes
  transport/TLS/HTTP/issuer validation from authentication and save synchronization.
  A successful probe is **not** proof of account login or cloud saves.
  The diagnostic also runs the owned SDK's existing HTTP implementation once,
  synchronously before entering the game, with the same public metadata URL.
  `Documents/vxmac_native_network_probe.json` records symbol availability, numeric
  transport/HTTP/backend results and bounded error categories only. It does not
  initialize the SDK's account client, send credentials, patch its image or alter
  certificate validation. Both opt-in flags are required. This one-off startup
  request has a 12-second timeout; disable the probe after diagnosis.

The HTTPS adapter keeps response memory bounded at 32 MiB per transfer, runs at
most four multi transfers at once, and delivers all game callbacks on the thread
that calls easy/multi perform. Its diagnostics contain status/error/counts only;
URLs, account identifiers, device codes, headers and response bodies are not logged.
Only HTTPS and loopback HTTP fixtures are admitted; redirects cannot downgrade
HTTPS. Unsupported curl options fail explicitly when networking is enabled. This
is a bounded adapter for observed imports, not a full libcurl implementation.
Proxy/custom CA/client-key/cookie-jar configuration and SSL context callbacks are
not implemented. Foundation controls HTTP connection scheduling, decompression
and its platform trust policy. Subphase timing getinfo values are unavailable (0).

## Verification and account test

1. Run `bash tools/check_direct_cloud.sh`. Local fixture tests call the
   adapter using Apple's actual curl headers: GET/POST/PUT, binary data, headers,
   redirects, HTTP errors, timeout, callback abort, multi completion/cancellation,
   bounded response size and refusal of a self-signed TLS certificate. Certificate
   roundtrips and browser/background policy are tested independently.
2. Run the existing release controls (the separate VeRantyx development tree also runs `make -C VXRuntime check`), then build
   with the same private owned game images/reload overlay as the accepted build.
3. While the game is stopped, back up its `Library/Application Support/CD Projekt
   Red/Cyberpunk 2077/saves` before enabling the candidate. Keep startup arguments
   and graphics settings separately. Updates must preserve the app container.
4. Run the public-metadata probe on the actual Vision Pro. Then open MY REWARDS
   or the cross-progression entry. The player completes the genuine CDPR login;
   no password, device code or token is requested in chat or diagnostics.
5. Verify a remote save appears, loads in game, and a new local manual save gets
   a cloud icon. Verify the save on another supported platform and after a fresh
   headset launch. Resolve version/DLC compatibility and conflicts before claiming
   support. Do not test remote deletes or overwrite an unbacked-up save.

Native CDPR SDK operations may use their own TLS transport instead of the game's
curl imports. Missing identity/private-key operations still return unsupported;
they are not replaced with success. Failure there must be diagnosed before a
direct-sync success claim. Original Apple Game Center/iCloud integration remains
unavailable under the host's own signing identity; CDPR cross-progression is a
separate account service.

### Standard CA-file compatibility

The native SDK public probe reproduced CURL result 77 on AVP (certificate-file
read failure), while Foundation HTTPS to the same issuer succeeded. The SDK
contains a Mac default `/etc/ssl/cert.pem` path. A privately prepared SDK image
can route libSystem through `libvxsystem` (`macho_prepare.py --system-shim`),
which maps reads/stat of that exact path and its `/private/etc` alias to
`HOME/Documents/vxmac_network/cert.pem` only when `VXMAC_NETWORK=1`.
Other paths, writes and offline operation keep their original behavior.

Provision that file privately from the player's Mac `/etc/ssl/cert.pem`, checking
the source is root-owned and not group/world writable. Record its SHA-256 and
read it back from the device. This restores the Mac SDK's standard root bundle;
it does not disable hostname or certificate-chain checks. No user keychain,
private key or custom user CA is exported. Certificates are system data copied
only into that player's app container and are not part of this MIT source tree
or a distributed app. The owned source SDK is never modified; only its private
prepared copy's load commands change. Account login and cloud saves still require
independent tests after the native metadata probe succeeds.

## Historical device investigation, 2026-11-08

- Preflight `20261108T084453Z-direct-cloud-preflight` d1 records passing HTTP,
  certificate and browser tests, required runtime/release checks, signature
  verification and unchanged owned game/presenter data. Saves were backed up.
- Installation `20261108T085313Z-direct-cloud-install` d1 records preserved
  graphics settings and the new startup flags. The first user login attempt
  started before the flag transfer completed and still ran offline (d2).
- After a fresh launch, `20261108T090148Z-direct-cloud-device-probe` d1 verifies
  actual Vision Pro HTTPS to the public CDPR issuer metadata: HTTP 200 and the
  expected issuer/device endpoint. The game still reports service unavailable
  before displaying its login flow (d2). This is **not working cross-save**.
- The owned SDK embeds its own HTTP/TLS library. A separate read-only Mac test of
  that library can fetch public metadata using either of its existing default
  or Secure Transport selections; neither result establishes its behavior on AVP.
  Game Center/iCloud authentication failures in the game log do not establish
  the cause of the separate CDPR login failure.
- Further device diagnostics need the headset unlocked. Bounded debugger
  diagnostics are prepared to collect native HTTP failure categories and numeric
  device-authorization failures without logging request bodies or credentials.
  The debugger connection proved unreliable during attachment; no native login
  failure reason was recovered that way. A self-contained native HTTP probe was
  added so the transport can be checked without stopping for debugger attachment.
- After the private standard CA bundle and read-only mapping were installed,
  `20261108T102220Z-network-ca-device-success` d1 records the same native SDK probe
  succeeding on AVP (HTTP 200, expected issuer, TLS backend 9). This resolves that
  reproduced CA-file transport failure; actual account login and save transfer
  remain separate, pending checks. `new_build.py` now also prepares the SDK with
  the system compatibility shim so a future build retains the CA-path support.
- `20261108T103941Z-cloud-signin-download-user` d1 records the player's successful
  CDPR sign-in and remote cloud-save load. This is a user-confirmed functional
  result, not just a public-metadata probe. The new-save upload roundtrip and
  fresh-launch authentication persistence remain unverified. Startup diagnostics
  can now be disabled with `VXMAC_NETWORK_PROBE=0` while normal networking stays on.

## Account restoration candidate

The player subsequently reported that removing the headset and relaunching loses
the signed-in state. The existing `user.gls` was still present, checksum-valid,
and contained a nonempty refresh credential. No credential value is logged or
written into test fixtures. This establishes saved data, not successful reuse.

With `VXMAC_NETWORK=1`, the startup bridge reads only the game's own SLGR v1
profile, checks bounds and CRC32, and asks the owned SDK's `SignInSmartLogin` to
use its existing credential at most once. The SDK and server determine whether
authentication succeeds. The bridge does not set an authenticated flag, change
ownership checks, impersonate Game Center, or modify the profile. No additional
password/token store is created. `VXMAC_ACCOUNT_RESTORE=0` disables this bridge.

The game-thread poll synchronously dispatches short SDK calls onto a dedicated
serial queue, keeping the SDK's thread-local errors separate while preventing
concurrent game-thread shutdown. Network authentication remains the SDK's async
operation; the bridge never drives `ProcessData` or waits for a network response.
It skips existing signed-in sessions, waits for SDK initialization, pauses in the
background, and stops after one request or the bounded startup timeout. It does
not automatically sign back in after a later logout in the same process.
`Documents/vxmac_account_restore.json` records state and booleans only.

The parser/policy tests cover real format checksums, malformed/truncated/duplicate
fields, empty credentials, SDK startup timing, one-shot requests, later logout,
and timeout. A private read-only test validated the existing profile; a separate
owned-SDK binding test resolves the four exact functions without signing in.
`20261108T114935Z-account-restore-and-load-exit` d1 records the native SDK
reporting successful startup restoration. A later captured launch also restored
without a new interactive sign-in. The first different cloud save terminated
during load (d2); low remaining memory is a suspicion (i1), not a recovered OS
termination reason. Upload/roundtrip and longer account persistence still need
verification.

The player then reported poor image quality, view jitter and unchanged native
weapon animation with both a previously working cloud save and a local save.
The captured game used 1280x720 output with an 853x480 internal MetalFX surface.
The older 37.11 FPS reference instead recorded 1280x720 depth with no temporal
scaler encodes. A temporary fix removed an old 1024-pixel pass-metadata gate and
restored native 1280x720. Its local tests passed, but the player reported that
image quality and head-turn symptoms were still wrong. That candidate is not
accepted as a visual fix.

At the player's request, the renderer is now restored to the checkpoint whose
normal VR coverage and head stability were explicitly accepted in
`20261107T202438Z-normal-vr-coverage-accepted` d1. `xros_vr.m`, `vxpipe.m` and
`frame_camera.h` and their corresponding release tests match the saved sources;
the temporary resolution experiment is retained only in private build artifacts.
The built Metal, MetalFX and display compatibility libraries match the accepted
checkpoint's sections. Network/certificate/browser libraries and the owned SDK
instead match the working account candidate. The owned game sections, weapon
code and compiled manual-reload overlay remain unchanged. The host's changes
relative to that source checkpoint are account restoration, login-browser
background grace and optional network diagnostics.

This restores the checkpoint's whole presentation path, including its older
menu transition behavior. Later menu/camera/vehicle refinements need separate
integration after visual acceptance; they must not be silently mixed into this
rollback. Native 1280x720 is retained, but visual acceptance and new FPS remain
pending. The historic 37.11 result is not a guarantee for this build or every save.

## Accepted follow-up, 2026-11-09

The final paragraph above describes an earlier rollback, not the current camera fix.
The accepted source now rejects orthographic/missing-projection camera samples,
keeps the paired world-camera snapshot, extends the existing peripheral fill to
vehicles, and uses head-only vertical look in VR vehicles. The player reported
the VR-only blackouts gone and vehicle behavior improved. See
[the current checkpoint](docs/RELEASE_2026_11_09.md) for verification and remaining limits.
Graphics settings were restored separately: native 1280x720, scaling/DRS/frame
generation off. No new FPS or universal save compatibility result is claimed.
