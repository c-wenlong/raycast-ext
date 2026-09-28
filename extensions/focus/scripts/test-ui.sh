#!/bin/sh
# Compiles the menu bar, the end sheet and the block window (no Core, no
# socket) with the headless AppKit harness in test/ui and runs it: a fake
# delegate stands in for the session logic, the status item lives in a
# private NSStatusBar, the sheet and the block window are ordered in off
# screen, and the app blocker hides nothing, so nothing appears. The block
# window is wired to a real BlockEngine (pure files only). Prints "all passed".
# `scripts/test-ui.sh <folder>` also writes sheet.png, menubar-*.png and
# block.png there.
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
swiftc -swift-version 5 -o dist/ui-tests \
  helper/Presenter.swift helper/MenuBar.swift helper/EndSheet.swift helper/UIPresenter.swift \
  helper/FloatingPanel.swift helper/Completion.swift \
  helper/Protocol.swift helper/Dates.swift helper/Rules.swift helper/Session.swift helper/LogText.swift helper/Config.swift \
  helper/Blocking.swift helper/Categories.swift helper/Matching.swift helper/BlockEngine.swift \
  helper/BlockWindow.swift helper/AppBlocker.swift \
  test/ui/main.swift
dist/ui-tests "$@"
