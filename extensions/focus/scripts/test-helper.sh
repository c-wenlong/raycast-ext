#!/bin/sh
# Compiles the helper's pure logic plus the sqlite layer with the test
# harness (no EventKit, no socket) and runs it, after typechecking the whole
# helper so main.swift and EventKitBackend.swift cannot rot unnoticed.
# Prints "all passed" when green.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
swiftc -typecheck -swift-version 5 helper/*.swift
swiftc -swift-version 5 -o dist/helper-tests \
  helper/Protocol.swift helper/Dates.swift helper/Config.swift helper/Rules.swift \
  helper/LogText.swift helper/Recovery.swift helper/Database.swift helper/Core.swift \
  test/helper/main.swift
dist/helper-tests
