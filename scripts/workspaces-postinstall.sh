#!/bin/sh
# ray's typecheck probes ./node_modules/.bin/tsc relative to the extension
# dir, which breaks under hoisted workspaces: focus/notes have no local
# node_modules at all. Give every workspace without one a symlink to the
# root copy so the probe resolves. Workspaces whose versions diverge
# (knobs) keep their real nested node_modules untouched.
set -e
cd "$(dirname "$0")/.."
for d in extensions/*/; do
  [ -e "$d/node_modules" ] || ln -s ../../node_modules "$d/node_modules"
done
