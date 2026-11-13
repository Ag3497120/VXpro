#!/bin/bash
# Build the Mac installer and its DMG from VXpro-owned source.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/build/installer"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
app="$stage/image/VXpro.app"
payload="$app/Contents/Resources/Payload"
mkdir -p "$app/Contents/MacOS" "$payload" "$out"

git ls-files -z app shims vr testapp LICENSE THIRD_PARTY_NOTICES.md \
  tools/check_imports.py tools/cp_settings.py tools/fsr_model.py tools/macho_prepare.py \
  tools/patch_fov.py tools/prepare_test.sh tools/vxmac_cyberpunk.py |
  /usr/bin/tar --null -T - -cf - |
  /usr/bin/tar -xf - -C "$payload"
mkdir "$payload/installer"
cp installer/setup.py "$payload/installer/"
(cd "$payload/app" && xcodegen)

cp installer/Info.plist "$app/Contents/Info.plist"
version="$(find "$payload" -type f -print0 | xargs -0 shasum -a 256 |
  sed "s|$payload/||" | LC_ALL=C sort | shasum -a 256 | cut -c1-16)"
/usr/libexec/PlistBuddy -c "Add :VXproPayloadVersion string $version" "$app/Contents/Info.plist"
/usr/bin/xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 installer/VXpro.swift \
  -o "$app/Contents/MacOS/VXpro"
identity="${VXPRO_SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
ln -s /Applications "$stage/image/Applications"
dmg="$stage/VXpro.dmg"
hdiutil create -quiet -volname "VXpro Installer" -srcfolder "$stage/image" -format UDZO "$dmg"
if [[ "$identity" != "-" ]]; then
  codesign --sign "$identity" --timestamp "$dmg"
fi
if [[ -n "${VXPRO_NOTARY_PROFILE:-}" ]]; then
  [[ "$identity" != "-" ]] || { echo "Set VXPRO_SIGN_IDENTITY before notarizing." >&2; exit 1; }
  xcrun notarytool submit "$dmg" --keychain-profile "$VXPRO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
rm -rf "$out/VXpro.app"
ditto "$app" "$out/VXpro.app"
mv -f "$dmg" "$out/VXpro.dmg"
(cd "$out" && shasum -a 256 VXpro.dmg > VXpro.dmg.sha256)
printf '%s\n' "$out/VXpro.dmg"
