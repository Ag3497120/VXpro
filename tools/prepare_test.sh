#!/bin/sh
# The test program for VX Mac Host: testapp/vxmac_test.m built for macOS (as a Mac app would be), then prepared like
# the game (macho_prepare.py --as-dylib, visionOS platform, the shims) into build/xros_images, and its imports checked.
set -e
cd "$(dirname "$0")/.."
mkdir -p build/mac build/xros_images
xcrun --sdk macosx clang -fobjc-arc -O1 -o build/mac/vxmac_test testapp/vxmac_test.m -framework AppKit -framework Metal \
  -framework QuartzCore -framework IOKit -lcurl -lbz2
python3 tools/macho_prepare.py build/mac/vxmac_test build/xros_images/vxmac_test.dylib --as-dylib @rpath/vxmac_test.dylib \
  --json build/xros_images/vxmac_test.json > /dev/null
python3 tools/check_imports.py build/xros_images/vxmac_test.dylib --shims build/xros:build/xros_images
