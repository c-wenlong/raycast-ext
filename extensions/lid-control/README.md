# Lid Control

Keeps a MacBook awake from Raycast: with the lid closed (`pmset
disablesleep`) or against idle and display sleep (`caffeinate`). Four
no-view commands, each ending in a HUD.

## Commands

- **Toggle Lid Sleep** / **Lid Sleep Status**: runs `~/.local/bin/lid
  toggle|status`. On, the Mac stays awake with the lid closed; off restores
  normal lid sleep.
- **Toggle Caffeinate** / **Caffeinate Status**: runs `~/.local/bin/caff
  toggle|status`, which starts or stops a `caffeinate` process that prevents
  idle and display sleep.

## Requirements

The `lid` and `caff` scripts come from Kai's home-manager config, not this
repo. `lid` needs the NOPASSWD sudoers rule in `/etc/sudoers.d/lid-sleep`;
without it the toggle fails and the HUD says so. `caff` cannot hold a closed
lid; only `lid` can (see the memory note on macOS sleep control).

`scripts/toggle-lid-sleep.sh` at the repo root is the older Raycast script
command for the same `lid toggle`.

## Development

`npm run dev`, `npm run build` and `npm run lint`. There are no tests; check
`pmset -g | grep SleepDisabled` and `pgrep caffeinate` after a change.
