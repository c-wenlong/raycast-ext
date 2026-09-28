#!/bin/sh
# Compiles the site half of blocking (block page, loopback server, tab
# watcher, the SiteBlocker factory) with the harness in test/site and runs
# it: page escaping and labels, URL encoding, HTTP over a real 127.0.0.1
# listener with a fake policy, host extraction, and the watcher over a fake
# browser. No Core, no real browser. Prints "all passed".
# `scripts/test-site.sh --demo [seconds]` runs the live check instead (SITE.md).
set -eu
cd "$(dirname "$0")/.."
mkdir -p dist
swiftc -swift-version 5 -o dist/site-tests \
  helper/Presenter.swift helper/Blocking.swift helper/BlockPage.swift helper/BlockServer.swift \
  helper/BrowserWatch.swift helper/SiteBlocking.swift \
  test/site/main.swift
dist/site-tests "$@"
