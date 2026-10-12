# ShuffleDetector

Find the most profitable crafting shuffle (any profession, with Disenchanting, AH resale or vendor exits) from auction house scans.

- `addon/ShuffleDetector/` - WoW addon. Scans the auction house (`/shuffledetector scan`, `/ahsnap` also works) and records profession skill and known recipes to SavedVariables.
- `companion/` - cross-platform Python app (CLI + PySide6 GUI) that reads those SavedVariables and ranks shuffles for every profession (`--profession`, or the GUI profession box), with a per-step cost/yield breakdown and suggestions for recipes to acquire.
- `common/` - shared data format doc and reference data (`data/reference.json`: items, vendor prices, recipes, disenchant yields). The bundled values are unverified seed data; `--update-wowhead` (or the GUI menu) downloads recipes for all professions from Wowhead (`--update-profession SLUG` for one).

## Run from the source tree

```
python run.py              # launch the GUI (Windows: run.cmd, Linux/macOS: ./run.sh)
python run.py --cli ARGS   # command-line interface
python run.py --test       # run the tests
```

The first run creates `.venv` and installs the dependencies; it reinstalls when `companion/pyproject.toml` changes.

## Run the companion (manual)

```
cd companion
pip install -e ".[gui]"
shuffledetector-gui [path\to\ShuffleDetector.lua]
shuffledetector [path\to\ShuffleDetector.lua] --detail
pytest
```

See [ROADMAP.md](ROADMAP.md) for future considerations.

## Addon install and updates

The GUI finds your WoW install(s) (or use Addon > Choose WoW folder..., or set `WOW_PATH`), shows the installed addon version, and installs or updates the bundled addon from the Addon menu. "Update addon automatically" (on by default) updates an outdated installed copy at startup. SavedVariables are never touched. Close WoW first if an update fails.

To bundle the addon into a built package, run `python companion/scripts/bundle_addon.py` before building; from a repo checkout the app uses `addon/` directly.

Copy `addon/ShuffleDetector` into `Interface/AddOns`.

## Shuffle calculator

The GUI's Calculator tab plans a batch of the selected shuffle either by number of crafts or by budget. CLI: `shuffledetector --calc "Recipe Name" --crafts 20` or `--budget 250g`. It lists how many of each material to buy (from the AH, walking the cheapest listings, or from a vendor if that is cheaper), the total cost, the expected output, and the net profit after the AH cut. For disenchants it adds a 90% range from yield variance (yields are modelled as independent Poisson counts, so the range is rough for small batches). It honors the exit and price settings, buys no more than is listed, and values output at current prices, so large batches will move the market.

## In-game shuffle

Select a shuffle in the companion and choose Addon > "Send selected shuffle to game" (or the "Send to game" button; CLI: `--send-plan "Recipe Name"`), then `/reload` in game. A small tracker appears showing the shuffle's steps with the current one highlighted, plus how many crafts your reagents allow and how many crafted pieces are in your bags. Drag it to move it; `/shuffledetector shuffle` shows or hides it.

To run the shuffle, make a macro (`/shuffledetector macro` prints it) and press it repeatedly:

```
/click ShuffleDetectorShuffleButton
```

Each press does one step: disenchant a crafted piece in your bags, otherwise craft the next one, until the reagents run out. WoW doesn't let chat commands cast spells, so the macro presses an invisible secure button that picks and does the action. Presses while a cast or bag update is in progress do nothing. You can also bind a key under Key Bindings > AddOns > ShuffleDetector. The step only changes out of combat. `/shuffledetector plan` prints the loaded shuffle and the next step.

## License

[MIT](LICENSE).

## Releases

Pushing a tag like `v0.3.0` runs `.github/workflows/release.yml`, which publishes a GitHub Release containing `ShuffleDetector-<version>.zip` (the addon) and `ShuffleDetector-Companion-<tag>-<os>` (PyInstaller builds of the GUI) for Windows, Linux and macOS. `ci.yml` runs the tests on every push and PR.

When not run from the source tree, the GUI's Addon > "Check for updates..." looks at the latest release: it offers a download link for a newer app and installs a newer addon automatically. Set `SHUFFLEDETECTOR_REPO=owner/repo` if the repository is not `soosticus/ShuffleDetector`.
