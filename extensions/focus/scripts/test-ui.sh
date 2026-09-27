#!/bin/sh
# Compiles the menu bar and end sheet (no Core, no socket) with the headless
# AppKit harness in test/ui and runs it: a fake delegate stands in for the
# session logic, the status item lives in a private NSStatusBar and the
# sheet is ordered in off screen, so nothing appears. Prints "all passed".
# `scripts/test-ui.sh <folder>` also writes sheet.png and menubar.png there.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
swiftc -swift-version 5 -o dist/ui-tests \
  helper/Presenter.swift helper/MenuBar.swift helper/EndSheet.swift helper/UIPresenter.swift \
  test/ui/main.swift
dist/ui-tests "$@"
