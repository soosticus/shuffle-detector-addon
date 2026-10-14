# ShuffleDetector

Find the most profitable crafting shuffle (any profession, with Disenchanting, AH resale or vendor exits) from your Auctionator auction house prices.

- `addon/ShuffleDetector/` - WoW addon (requires [Auctionator](https://www.curseforge.com/wow/addons/auctionator)). Records profession skill, recipes (known and not yet learned, with reagents), item names and vendor prices to SavedVariables, and runs the shuffle tracker. It does no scanning of its own.
- `companion/` - cross-platform Python app (CLI + PySide6 GUI) that reads those SavedVariables plus Auctionator's own price database (`Auctionator.lua`, in the same SavedVariables folder) and ranks shuffles for every profession (`--profession`, or the GUI profession box), with a per-step cost/yield breakdown and suggestions for recipes to acquire.
- `common/` - shared data format doc and reference data (`data/reference.json`: items, vendor prices, recipes, disenchant yields). The bundled values are unverified seed data; recipes, item names and vendor prices recorded by the addon in game are layered over them (see [ROADMAP.md](ROADMAP.md)).
- `CLAUDE.md` - working notes and handoff for AI assistants (environment quirks, rules, status).

## Run from the source tree

```
python run.py              # launch the GUI (Windows: run.cmd, Linux/macOS: ./run.sh)
python run.py --cli ARGS   # command-line interface
python run.py --test       # run the tests
```

The first run creates a per-machine virtualenv, `.venv-<hostname>`, and installs the dependencies; it reinstalls when `companion/pyproject.toml` changes.

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

The GUI finds your WoW install(s) (or use Addon > Choose WoW folder..., or set `WOW_PATH`), shows the installed addon version, and installs or updates the bundled addon from the Addon menu. "Update addon automatically" (on by default) updates an outdated installed copy at startup. The `.toc` in the repo carries a `@project-version@` placeholder; installing from a source checkout stamps it as `dev-<commit sha>`. Dev builds can't be ordered against releases, so a source install always replaces a different install, and a release bundle never replaces a dev install. SavedVariables are never touched. Close WoW first if an update fails.

To bundle the addon into a built package, run `python companion/scripts/bundle_addon.py` before building; from a repo checkout the app uses `addon/` directly.

Copy `addon/ShuffleDetector` into `Interface/AddOns`. Open each profession window (and a vendor) once so the addon can record recipes and prices, then `/reload` or log out so the game writes them.

To have the addon look up names and vendor sell prices for every recipe item without you meeting them first, run `shuffledetector --local-recipes --send-items` (it writes the item ids to the addon's `ItemList.lua`), then `/reload` in game; the addon requests them in the background (`/shuffledetector items` repeats it). Vendor buy prices still come only from visiting a vendor.

## Shuffle calculator

Recipes the character has not seen can also come straight from the game's own data files: `shuffledetector --local-recipes` (optionally `--wow "C:\Program Files (x86)\World of Warcraft"`) reads reagents, products, trivial levels and craft times for every profession from your installed client, takes a few seconds, downloads nothing and stores nothing. Recipe skill requirements are not in the client, so those recipes show status "unknown" until a character has seen them.

The GUI's Calculator tab plans a batch of the selected shuffle either by number of crafts or by budget. CLI: `shuffledetector --calc "Recipe Name" --crafts 20` or `--budget 250g`. It lists how many of each material to buy (from the AH, walking the cheapest listings, or from a vendor if that is cheaper), the total cost, the expected output, and the net profit after the AH cut. For disenchants it adds a 90% range from yield variance (yields are modelled as independent Poisson counts, so the range is rough for small batches). It honors the exit and price settings, buys no more than is listed, and values output at current prices, so large batches will move the market. Because big purchases pay a spread of prices, you can enter your own average cost per material (the Calculator tab lists every material of the selected shuffle with separate gold, silver and copper boxes pre-filled (in grey) with its market average for the batch; change any of them to enter your own price, or press "Use market" to go back; your prices are remembered per item, or use `--cost "Silk Cloth=1g 20s"` on the CLI, repeatable). A custom cost replaces the market price of that item for any quantity; bolts and bars are still bought or made from raw materials, whichever is cheaper, and the batch notes say when a custom cost was not used.

## In-game shuffle

Select a shuffle in the companion and choose Addon > "Send selected shuffle to game" (or the "Send to game" button; CLI: `--send-plan "Recipe Name"`), then `/reload` in game. A small tracker appears showing the shuffle's steps with the current one highlighted, plus how many crafts your reagents allow and how many crafted pieces are in your bags. Drag it to move it; `/shuffledetector shuffle` shows or hides it.

To run the shuffle, make a macro (`/shuffledetector macro` prints it) and press it repeatedly:

```
/click ShuffleDetectorShuffleButton
```

Each press does one step: disenchant a crafted piece in your bags, otherwise craft the next one, until the reagents run out. For a Vendor exit, open a merchant window and each press sells one stack of the crafted item (the tracker says "Open a vendor window to sell N" when you are out of reagents); an AH exit only prompts you to post the items yourself. WoW doesn't let chat commands cast spells, so the macro presses an invisible secure button that picks and does the action. Presses while a cast or bag update is in progress do nothing. You can also bind a key under Key Bindings > AddOns > ShuffleDetector. The step only changes out of combat. `/shuffledetector plan` prints the loaded shuffle and the next step.

Prices: Auctionator is required (the companion shows a warning with a CurseForge link when it is missing from the selected client; it does not download it for you). Scan the auction house with Auctionator as usual, then `/reload` (or log out) so the game writes its price database to disk, and refresh the companion. Auctionator keeps minimum prices only, so the companion assumes any quantity can be bought at that price, and the realm box lists Auctionator's realm keys (the one with the freshest prices is selected first).

Disenchant yields: with Auctionator installed, the companion reads the disenchant table that ships in Auctionator's folder (next to your SavedVariables; the addon only records each item's class and level, `/shuffledetector yields` refreshes older entries) and uses those expected yields for the Disenchant step; yields observed from your own disenchants take over once there are samples, and the bundled seed estimates are only the fallback. The Calculator and details view say which source was used. Items an Enchanter crafts (wands) cannot be disenchanted, so Enchanting recipes get no Disenchant exit.

Click, cast and game-error diagnostics are not printed to chat; they go to a hidden log. `/shuffledetector log` shows the last lines (`log <n>`, `log clear`), and `/shuffledetector log echo` also prints new lines live while you debug a macro.

## License

[MIT](LICENSE).

## Releases

Pushing a tag like `v0.3.0` runs `.github/workflows/release.yml`, which replaces the `@project-version@` placeholder in the addon `.toc` with the tag (without the leading `v`), stamps the same version into the app, then publishes a GitHub Release containing `ShuffleDetector-<version>.zip` (the addon) and `ShuffleDetector-Companion-<tag>-<os>` (PyInstaller builds of the GUI) for Windows, Linux and macOS. A manual run of the workflow stamps `dev-<sha>` instead. `ci.yml` runs the tests on every push and PR.

When not run from the source tree, the GUI's Addon > "Check for updates..." looks at the latest release: it installs a newer addon automatically and offers to update the companion. The packaged app also checks in the background at startup (Addon > "Check for companion updates at startup", on by default) and, when a newer release exists, asks whether to download it. If you say yes it downloads the build for your OS from the release (checking GitHub's SHA-256 digest when one is published), unpacks it next to the installed copy, closes, swaps the folders and starts the new version; the old copy is deleted afterwards. If the app folder is not writable (for example under Program Files) or the release has no build for your OS, it shows the release link instead. Saying no asks again on the next start. Release notes are bundled with the app: after an update it shows what is new, and Help > Release notes brings them up again. Set `SHUFFLEDETECTOR_REPO=owner/repo` if the repository is not `soosticus/ShuffleDetector`.

### Windows SmartScreen warning

The companion builds are not code signed, so Windows SmartScreen shows "Windows protected your PC" the first time you run a downloaded copy. Click **More info**, then **Run anyway**. To avoid the prompt, right-click the downloaded zip, choose Properties, tick **Unblock**, and only then extract it. The addon zip is plain Lua and is not affected. You can also skip the executable and [run from the source tree](#run-from-the-source-tree).
