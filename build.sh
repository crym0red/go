#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

# optional: embed AirShareLogo.png (repo root) into the dylib
rm -f AirShareLogo.h
if [ -f AirShareLogo.png ]; then
  xxd -i AirShareLogo.png > AirShareLogo.h
fi

clang -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=14.0 \
  -fobjc-arc -O2 \
  -dynamiclib \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -framework AudioToolbox -framework CoreHaptics \
  -I. \
  -install_name @rpath/AirHide.dylib \
  -o AirHide.dylib \
  AirHide.m

ldid -S AirHide.dylib
echo "Built AirHide.dylib"
