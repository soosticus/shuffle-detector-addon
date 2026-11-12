# ShuffleDetector: working notes for AI assistants

Read this first, then `ROADMAP.md` (open work), `README.md` (user docs) and `docs/FORMAT.md` (SavedVariables layout).

## What this is

A WoW Classic addon that ranks and runs crafting "shuffles" (craft something, then disenchant, sell on the AH or vendor it), priced from Auctionator. A desktop companion app (Python, PySide6) used to do the ranking; it was removed in 0.9.6 and only lives in git history (tags up to v0.9.4).

- Target client: the "Forever" Classic client (Interface 16001, game type `camelot`). It exposes the modern `C_TradeSkillUI` profession API, not the classic `GetTradeSkill*` functions (the addon supports both). Install paths differ per machine: on the Linux machine it is `/home/soost/.local/share/Steam/steamapps/compatdata/3544483676/pfx/drive_c/Program Files (x86)/World of Warcraft/_forever_`; on Windows it has been `C:/Games/World of Warcraft/_classic_beta_/`.
- `addon/ShuffleDetector/` (load order in the `.toc`):
  - `ShuffleDetector.lua`: core. Item, profession, recipe and vendor recording, item info requests (`ns.RequestItems`, `ns.LoadRecipeItems` for every item of recorded and catalog recipes), slash commands.
  - `Diagnostics.lua`, `Observations.lua`, `Disenchant.lua`: log ring buffer, observations, logged disenchant results (`AHSnapshotDB.disenchants`).
  - `Prices.lua`: Auctionator `Auctionator.API.v1` prices in game.
  - `Evaluate.lua`, `Planner.lua`, `Calculator.lua`, `Catalog.lua`, `Browser.lua`: per-recipe evaluation, ranking across recorded characters and the recipe catalog (`AHSnapshotDB.catalog`, a spell ID scan for professions nobody has), the batch calculator, and the `/shuffledetector browse` window. **Set active shuffle** saves `AHSnapshotDB.activePlan`, which `ns.RestoreActivePlan` loads as `ns.plan` on login.
  - `Shuffle.lua`: the secure button, step tracker and macro (craft, disenchant, vendor sell, buying).
  - `Snatch.lua`: material buying (AH polling, quotes, vendor purchases, price limits, reservations).
  - `Statistics.lua`: batch statistics and the Analytics window.
- `tests/`: Lua 5.1 harnesses that stub the WoW API and `loadfile` the addon from the repo root; `tests/run.sh` syntax-checks every addon file and runs them all.
- Repo: GitHub `soosticus/shuffle-detector-addon`, releases tagged from `main`.

## Data flow

Everything happens in game. The addon records to `AHSnapshotDB` (SavedVariables, flushed on `/reload` or logout): per character and profession the skill, learned `recipes` and unlearned `available` recipes; `items` (name, vendor sell price, class, quality, ilvl); `vendor` buy prices; `disenchants`; the `catalog`; the active plan, snatcher limits and statistics. Prices come from Auctionator's in-game API on demand. Details are in `docs/FORMAT.md`.

## Rules (from the user)

- Never scrape any site against its terms or robots.txt. All Wowhead data and code was removed for this reason. wago.tools' robots.txt disallows everything but the home page, so it is paused: do not fetch it. Ask the user before using any new external data source.
- Commit after finishing work: `git add` specific files, message passed through a HEREDOC, committed with `--signoff` and no Co-Authored-By or other attribution trailers (the global instructions forbid them). Never push, amend or force-push unless asked. Run `git status` before anything that could discard work.
- Work autonomously; ask only when genuinely blocked.
- Never use the user's real name in anything for WoW addon development (toc Author, LICENSE, commits, docs); use only the alias "soosticus".
- Keep docs and ROADMAP.md current. Finished items are removed from the roadmap.
- Releases: before tagging, write brief, user-facing patch notes in `release-notes/vX.Y.Z.md` (what changed for someone using the addon, what they must do, caveats; no commit log, no internals), commit it, then push `main` and the tag. `release.yml` runs `tests/run.sh`, stamps the tag into the `.toc`, zips the addon and publishes that file as the release body (falling back to GitHub's generated commit list only if it is missing). Never push or tag without being asked.

## Environment

- Tests: `tests/run.sh` (needs `lua5.1` and `luac5.1`). `luac5.1 -p` catches Lua 5.3+ syntax WoW cannot load.
- Deploy for testing: copy `addon/ShuffleDetector/*` to `<WoW root>/Interface/AddOns/ShuffleDetector/` and replace `@project-version@` in the copied `.toc` with `dev-<git rev-parse --short=7 HEAD>` so the user can see what loaded, then ask the user to `/reload`. The version is never bumped in the repo: releases take it from the tag.
- SavedVariables: `<WoW root>/WTF/Account/<account>/SavedVariables/ShuffleDetector.lua`.
- WoW API behavior cannot be verified from here; only the user can test in game. Write nil-safe code (`pcall`, existence checks) with retries. Diagnostics: `/shuffledetector recipes` (recipe counts in the open window and what is saved) and `/shuffledetector log` (hidden ring buffer in `AHSnapshotDB.log`; add new diagnostics with `ns.log`, not chat).

## Status and next steps

- Next release, 0.10.0 (a release candidate for 1.0.0): disenchant yield estimates in game. Auctionator's `Source_Classic/Enchant/DisenchantingProbabilities.lua` is not loaded on the `camelot` client, so its table is not available through Auctionator in game. Options are shipping an equivalent table in the addon (check licensing first) or using observed disenchants (`AHSnapshotDB.disenchants`) with the item `class`/`quality`/`ilvl` that `recordItem` records. Items crafted by Enchanters (wands) cannot be disenchanted.
- `GetRecipeSourceText` never returned a value on this client, so the `source` field of `available` recipes is effectively unused.
- Other open work is in ROADMAP.md.
