#!/bin/zsh

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Toggle Lid Sleep
# @raycast.mode compact

# Optional parameters:
# @raycast.icon 💤
# @raycast.packageName System

# Documentation:
# @raycast.description Keep the Mac awake with the lid closed (pmset disablesleep). Requires the lid-sleep sudoers rule.

exec "$HOME/.local/bin/lid" toggle
