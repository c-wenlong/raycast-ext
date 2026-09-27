#!/bin/sh
# Compiles helper/*.swift into assets/focus-daemon with helper/Info.plist
# embedded (the Calendar permission prompt needs its bundle id and usage
# string), then signs it with the bundle id as identifier. Ad-hoc by default;
# FOCUS_SIGN_IDENTITY="Apple Development: ..." gives a signature whose
# Calendar grant survives rebuilds. Run from anywhere.
set -eu
cd "$(dirname "$0")/.."
swiftc -O -swift-version 5 -framework EventKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker helper/Info.plist \
  -o assets/focus-daemon helper/*.swift
codesign --force --sign "${FOCUS_SIGN_IDENTITY:--}" --identifier com.c-wenlong.focus-daemon assets/focus-daemon
echo "built assets/focus-daemon"
