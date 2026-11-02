# Knobs

macOS system switches from Raycast: the grayscale colour filter, sleep with
the lid closed, and caffeinate. Five no-view commands, each ending in a HUD.
Merged from the old Color Filter and Lid Control extensions on 2026-09-29.

## Commands

- **Set Grayscale**: with no argument, toggles the colour filter (off if it is
  on, otherwise 100 %). With a level from 0 to 100, sets that intensity; 0
  turns the filter off.
- **Toggle Lid Sleep** / **Lid Sleep Status**: runs `~/.local/bin/lid
  toggle|status`. On, the Mac stays awake with the lid closed; off restores
  normal lid sleep.
- **Toggle Caffeinate** / **Caffeinate Status**: runs `~/.local/bin/caff
  toggle|status`, which starts or stops a `caffeinate` process that prevents
  idle and display sleep.

## How they work

`src/set-grayscale.ts` runs `assets/colorfilter`, a small C helper
(`helper/colorfilter.c`) that calls the private MediaAccessibility SPI:
`colorfilter get|toggle|set <0-100>` prints the resulting level. The binary is
committed; rebuild it with `npm run build-helper` (`clang -O2`) after editing
the C file and commit the result.

The `lid` and `caff` scripts come from the owner's dotfiles, not this
repo. `lid` needs the NOPASSWD sudoers rule in `/etc/sudoers.d/lid-sleep`;
without it the toggle fails and the HUD says so. `caff` cannot hold a closed
lid: `caffeinate` only takes the idle and display sleep assertions, and a
closed lid goes through the separate clamshell sleep path, which nothing but
`pmset disablesleep` overrides. So use `lid` for a closed MacBook and `caff`
for an open one that should not doze.

## Moving from Color Filter and Lid Control

Raycast sees Knobs as a new extension. Once: run `npm install && npx ray
develop` in `extensions/knobs` so Raycast registers it, remove the two old
development entries in Raycast > Extensions (their folders are gone), and
rebind any hotkeys or aliases you had on the old commands to the Knobs ones
of the same name.

## Development

`npm run dev`, `npm run build` and `npm run lint`. There are no tests; check
the filter in System Settings > Accessibility > Display, `pmset -g | grep
SleepDisabled` and `pgrep caffeinate` after a change.
