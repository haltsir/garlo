# design

The artboards behind the Garlo Screens design canvas (a Claude artifact owned by the maintainer). Each `.dc.html` is one artboard; `canvas.json` lays them out and carries annotations. `garlo-screens.html` is the generated canvas page and is gitignored.

| Artboard | Screen |
| --- | --- |
| `MenuBar.dc.html` | The menu bar icon in its three states. |
| `PopoverIdle.dc.html` | The empty popover. |
| `Main.dc.html` | The popover with Now rows, findings and notices. |
| `FindingCards.dc.html` | Card variants: suspected, confirmed, notice, with the tier hint. |
| `History.dc.html` | The History window with lanes and the device page. |
| `Settings.dc.html` | The Settings window. |

Rules of the house:

- The code is the source of truth for behaviour; the artboards are the source of truth for layout and copy tone. When a screen changes materially, update the artboard and re-seed the canvas with the `design` skill from this directory.
- Copy on the artboards follows the same rules as the app: one-sentence verdicts, units on numbers, imperative actions, no em-dashes.
- Never put real file names, volume names or process names from the maintainer's Mac on an artboard. Use the fixture names (Archive, Backup, Scratch, Torrent).
