#!/bin/sh
# SPDX-License-Identifier: MIT
# Isolated loopback fixtures only; no real account/cloud/save writes.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
out=${VXMAC_CLOUD_CHECK_DIR:-build/direct-cloud-tests}
mkdir -p "$out"
xcrun clang -O1 -g -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations -Wno-unused-parameter \
    -framework Foundation tests/curl_network_mac.m shims/vxcurl.m -o "$out/curl_network_mac"
python3 tests/network_fixture.py "$out" "$out/curl_network_mac"
xcrun clang -O1 -g -fobjc-arc -Wall -Wextra -Wno-unused-parameter -framework Foundation -framework Security \
    tests/security_certificate_mac.m shims/vxsec.c -o "$out/security_certificate_mac"
"$out/security_certificate_mac" "$out/fixture-cert.pem"
xcrun clang -O1 -g -fobjc-arc -Wall -Wextra -framework Foundation tests/auth_browser_mac.m -o "$out/auth_browser_mac"
"$out/auth_browser_mac"
xcrun clang -O1 -g -Wall -Wextra tests/network_ca_path_mac.c -o "$out/network_ca_path_mac"
"$out/network_ca_path_mac"
xcrun clang -O1 -g -Wall -Wextra tests/account_restore_mac.c -o "$out/account_restore_mac"
"$out/account_restore_mac"
