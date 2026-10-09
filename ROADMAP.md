# Roadmap

Open items only; finished work is removed. Release notes are generated from commit history by the release workflow.

## Open items

- Layer observed in-game disenchant results from the addon on top of the Wowhead yield rates.
- Handle vendor faction/location restrictions.
- Confirm the AH tab and recipe capture (`/shuffledetector recipes`) in the Forever client.

## Planned: shuffle calculator

Given a chosen shuffle, tell the user how many of each material to buy for a target (budget, craft count, or number of disenchants) and the expected profit. Show the per-step material quantities (including rounding up for yields), total cost at current AH/vendor prices, expected output, and net profit after AH cut, with a range that accounts for disenchant yield variance. Should reuse `calc.py` so it honors the exit filters and known-recipe settings.

## Planned: in-game shuffle button

A one-button action in the addon that walks the shuffle steps in order, so the user can press or spam it (or bind a key) instead of clicking each step. Ideas:

- A secure action button (`SecureActionButtonTemplate`) whose type/spell/item attributes are updated after each step, so each press performs the next action: craft, then disenchant, then craft again.
- Protected actions such as casting Disenchant need a hardware event per press, so one action per press is the realistic limit; a macro-style `/click` bind keeps it spammable.
- Attribute changes are blocked in combat, so update the button only out of combat.
- Fallback if full sequencing is not feasible: just simplify disenchanting, for example a button that targets the next disenchantable item in bags and casts Disenchant.
- The companion could export the chosen shuffle (recipe, quantities, exit) to SavedVariables or a pasted string so the addon knows which steps to run.
- Needs an in-game check of what the Forever client allows.

## Planned: more professions

Go beyond Tailoring -> Enchanting and consider every profession the scanned characters actually have. The addon already records each character's professions and known recipes, so the companion should read that list and evaluate shuffles for all of them, not just Tailoring.

- Generalize `calc.py` from the hard-coded Tailoring-only known-recipe check to any profession's recipes, with the character filter using whichever professions are present in the scan.
- Extend the Wowhead resolver to fetch recipes, reagents, vendor prices and yields for the other crafting professions (Blacksmithing, Leatherworking, Engineering, Alchemy, Jewelcrafting, Inscription, Cooking, and others available in the client), and for the gathering and processing steps (Mining/smelting, Herbalism/milling, Skinning, prospecting).
- Support other exit steps beyond disenchanting, such as prospecting, milling and salvage, in the same exit comparison.
- Allow chains across professions held by different characters (craft on one, process on another).
- GUI: a profession filter alongside the character selector.
