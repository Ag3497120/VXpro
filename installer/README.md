# VXpro Mac installer

The DMG includes the SwiftUI installer, the visionOS host source and its generated
Xcode project. The installer builds and signs VX Mac Host locally from the player's
Mac App Store game. The distribution contains only VXpro files.

For first-time setup, install Xcode with the visionOS SDK, sign in to a paid Apple
Developer Program team and pair the Vision Pro in Developer Mode. Open the
installer, choose the game, signing team and device, then select **Install to Vision Pro**.
Open VX Mac Host on the headset after the transfer and size verification complete.

The installer detects existing VX Mac Host installations. Use the original bundle
ID and signing team to update the same app container. The installer backs up
existing graphics settings before applying its profile. Transfer checkpoints and
installation logs are in `~/Library/Application Support/VXpro/Installer`.

Manual reload overlays, the optional weapon catalog, Neural Engine models and
experimental cloud settings have separate setup paths in the source documentation.

## Build the installer

With Xcode and XcodeGen available, run `installer/build.sh` from a VXpro checkout.
This produces `build/installer/VXpro.app`, `VXpro.dmg` and its SHA-256 file.
For distribution, set `VXPRO_SIGN_IDENTITY` to your Developer ID Application
identity and `VXPRO_NOTARY_PROFILE` to a working `notarytool` keychain profile.
The script signs the disk image, submits it, and validates its notarization ticket.
Publish the DMG and checksum only. The locally built visionOS app contains the
user's game code.
