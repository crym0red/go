#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

clang -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=14.0 \
  -fobjc-arc -O2 \
  -dynamiclib \
  -framework UIKit -framework Foundation -framework QuartzCore \
  -install_name @rpath/AirHide.dylib \
  -o AirHide.dylib \
  AirHide.m

ldid -S AirHide.dylib
echo "Built AirHide.dylib"
