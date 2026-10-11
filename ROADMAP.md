# Roadmap

Open items only; finished work is removed. Release notes are generated from commit history by the release workflow.

## Open items

- Layer observed in-game disenchant results from the addon on top of the Wowhead yield rates.
- Handle vendor faction/location restrictions.
- Confirm the AH tab and recipe capture (`/shuffledetector recipes`) in the Forever client. Tailoring recipes were not being recorded for the main character, so the "known recipes only" filter falls back to showing everything; if `/shuffledetector recipes` still reports 0 after opening the Tailoring window and `/reload`, the recipe capture needs a fix for the Forever API. Enchanting (craft frame) recipes are not read by the addon.
- Confirm in game that the fast-press gating no longer repeats a craft or disenchant step.
- Shuffle follow-ups: take the craft count or budget from the calculator, and steps beyond craft/disenchant (for example vendor or AH listing) now that the calculator can name them.
- Per-recipe craft times: the calculator uses one default craft time (30 s) unless a recipe sets `craft_seconds`; read the real cast times from the game or Wowhead.
- Calculator follow-ups: model price impact when buying or selling large quantities (walk the sell side of the order book), use observed in-game disenchant results instead of Poisson for the range, and offer a "number of disenchants" target.

## Planned: CurseForge release

Prepare the addon for CurseForge. Check CurseForge's current requirements before submitting, since they change.

- Confirm CurseForge lists the "Forever" client (Interface 16001) as a game version. If not, decide whether to publish under the closest supported version or stay on GitHub releases only.
- Create the project: name, short summary, a full description (what the addon does, that the companion app is a separate GitHub download, how to run the macro), category, license (MIT, already in `LICENSE`), and screenshots of the tracker and the AH tab.
- Icon: a proper square project logo (CurseForge asks for a 400x400 PNG or similar; check the current size limit), plus an optional in-game `## IconTexture` for the addon list. Keep the source image in the repo.
- Packaging: add a `.pkgmeta` (package-as `ShuffleDetector`, ignore dev files) and publish through the BigWigs packager from the release workflow, using a CurseForge API token stored as a repo secret. The zip needs a single top-level `ShuffleDetector` folder whose `.toc` matches it.
- `.toc` updates: add `## X-Curse-Project-ID`, refresh `## Notes` (it still describes only scanning), and consider `## Category` and `## IconTexture`. Keep `## Interface` in step with the supported client.
- Ship a placeholder `Plan.lua` in the package so the `.toc` loads cleanly, and make sure a CurseForge update does not overwrite a user's generated plan, or tell users to resend it after an update.
- Content rules: no bundled executables or the companion app inside the addon zip (link to the GitHub release instead), and credit any libraries. Add a changelog (the packager can generate one from commits).
- Decide on a version scheme and release process (tag `v*`, then upload) and document it in the README.

## Planned: more professions

Go beyond Tailoring -> Enchanting and consider every profession the scanned characters actually have. The addon already records each character's professions and known recipes, so the companion should read that list and evaluate shuffles for all of them, not just Tailoring.

- Generalize `calc.py` from the hard-coded Tailoring-only known-recipe check to any profession's recipes, with the character filter using whichever professions are present in the scan.
- Extend the Wowhead resolver to fetch recipes, reagents, vendor prices and yields for the other crafting professions (Blacksmithing, Leatherworking, Engineering, Alchemy, Jewelcrafting, Inscription, Cooking, and others available in the client), and for the gathering and processing steps (Mining/smelting, Herbalism/milling, Skinning, prospecting).
- Support other exit steps beyond disenchanting, such as prospecting, milling and salvage, in the same exit comparison.
- Allow chains across professions held by different characters (craft on one, process on another).
- GUI: a profession filter alongside the character selector.
