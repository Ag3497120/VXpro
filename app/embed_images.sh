#!/bin/sh
# Xcode build phase of VX Mac Host: the shims (../build/xros/*.dylib, simulator: ../build/xrsim; shims/Makefile) and the prepared program images
# (VXMAC_IMAGES: directories of macho_prepare.py output, colon-separated; default ../build/xros_images, the test
# program) into the app's Frameworks, each signed with the build's identity; each image's <name>.vxmac.plist (its
# entry point) into Resources. The images are local copies of the user's own program, never in git.
set -e
FW="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
RES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$FW" "$RES"
SIGN="${EXPANDED_CODE_SIGN_IDENTITY:--}"
SHIMS="$SRCROOT/../build/xros"; [ "$PLATFORM_NAME" = xrsimulator ] && SHIMS="$SRCROOT/../build/xrsim"
for f in "$SHIMS"/*.dylib; do
  cp -f "$f" "$FW/"
  codesign --force --sign "$SIGN" --timestamp=none "$FW/$(basename "$f")"
done
IMAGES="${VXMAC_IMAGES:-$SRCROOT/../build/xros_images}"
OLDIFS="$IFS"; IFS=:
for d in $IMAGES; do
  IFS="$OLDIFS"
  [ -d "$d" ] || { echo "embed_images: no $d"; continue; }
  for f in "$d"/*.dylib; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if [ ! -f "$FW/$b" ] || [ "$f" -nt "$FW/$b" ]; then cp -f "$f" "$FW/$b"; fi
    codesign --force --sign "$SIGN" --timestamp=none "$FW/$b"
  done
  for p in "$d"/*.vxmac.plist; do [ -f "$p" ] && cp -f "$p" "$RES/"; done
  IFS=:
done
IFS="$OLDIFS"
# (the foveated SR's compiled Core ML models (tools/fsr_model.py -> ../build/fsr), made by tools/vxmac_cyberpunk.py build,
#  into Resources when they are there)
for m in "$SRCROOT/../build/fsr"/*.mlmodelc; do [ -d "$m" ] && rm -rf "$RES/$(basename "$m")" && cp -R "$m" "$RES/"; done
