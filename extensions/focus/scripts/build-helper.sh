#!/bin/sh
# Compiles helper/*.swift into assets/focus-daemon with helper/Info.plist
# embedded (the Calendar permission prompt needs its bundle id and usage
# string), then signs it with the bundle id as identifier (see below for the
# identity). Run from anywhere.
set -eu
cd "$(dirname "$0")/.."
# Signed with Kai's Apple Development identity by default, so the Calendar
# and Automation grants key on the signature and survive rebuilds and
# Raycast's copy of the binary. A Mac without that identity signs ad hoc
# (and prompts again after every rebuild). FOCUS_SIGN_IDENTITY overrides,
# and an override that is not in the keychain fails the build.
default_identity="Apple Development: Wenlong Chen (T4M49Q7QX6)"
identity="${FOCUS_SIGN_IDENTITY:-$default_identity}"
if [ "$identity" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"; then
  if [ -n "${FOCUS_SIGN_IDENTITY:-}" ]; then
    echo "FOCUS_SIGN_IDENTITY \"$identity\" is not in the keychain; not building" >&2
    exit 1
  fi
  echo "signing identity \"$identity\" is not in the keychain; signing ad hoc" >&2
  identity="-"
fi
# The identity is settled before compiling, so a refused override never
# leaves an unsigned binary behind.
swiftc -O -swift-version 5 -framework EventKit \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker helper/Info.plist \
  -o assets/focus-daemon helper/*.swift
codesign --force --sign "$identity" --identifier com.c-wenlong.focus-daemon assets/focus-daemon
echo "built assets/focus-daemon"
