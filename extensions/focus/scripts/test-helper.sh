#!/bin/sh
# Compiles the helper's pure logic plus the sqlite layer with the test
# harness (no EventKit, no socket) and runs it, after typechecking the whole
# helper so main.swift, EventKitBackend.swift and the UI files cannot rot
# unnoticed.
# Prints "all passed" when green.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
swiftc -typecheck -swift-version 5 helper/*.swift
swiftc -swift-version 5 -o dist/helper-tests \
  helper/Protocol.swift helper/Dates.swift helper/Config.swift helper/Rules.swift \
  helper/LogText.swift helper/Recovery.swift helper/Database.swift helper/Session.swift \
  helper/Presenter.swift helper/Blocking.swift helper/Categories.swift helper/Matching.swift \
  helper/BlockEngine.swift helper/Stats.swift helper/Chart.swift helper/Core.swift \
  test/helper/main.swift
dist/helper-tests
