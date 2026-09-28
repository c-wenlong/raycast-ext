# Color Filter

Sets the macOS grayscale colour filter from Raycast, without opening
Accessibility settings.

## Command

- **Set Grayscale**: with no argument, toggles the filter (off if it is on,
  otherwise 100 %). With a level from 0 to 100, sets that intensity; 0 turns
  the filter off. A HUD shows the result.

## How it works

`src/set-grayscale.ts` runs `assets/colorfilter`, a small C helper
(`helper/colorfilter.c`) that calls the private MediaAccessibility SPI:
`colorfilter get|toggle|set <0-100>` prints the resulting level. The binary is
committed; rebuild it with `npm run build-helper` (`clang -O2`) after editing
the C file and commit the result.

## Development

`npm run dev` for the dev build, `npm run build` and `npm run lint` before a
push. There are no tests; check the filter in System Settings > Accessibility
> Display after a change.
