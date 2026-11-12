local function eq(actual, expected, message)
    assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local widgets = {}
local function widget(parent)
    local w = { parent = parent, scripts = {}, shown = true }
    widgets[#widgets + 1] = w
    for _, method in ipairs({
        "SetPoint", "SetMovable", "EnableMouse", "RegisterForDrag", "StartMoving",
        "StopMovingOrSizing", "SetJustifyH", "SetWordWrap", "SetAutoFocus",
        "SetMaxLetters", "ClearFocus", "RegisterEvent",
        "SetSpacing", "SetAllPoints", "SetFrameStrata", "SetColorTexture",
        "SetClampedToScreen", "SetHighlightTexture",
    }) do w[method] = function() end end
    function w:SetScript(event, fn) self.scripts[event] = fn end
    function w:SetSize(width, height) self.width, self.height = width, height end
    function w:SetHeight(height) self.height = height end
    function w:SetWidth(width) self.width = width end
    function w:SetText(value)
        self.text = value
        if self.scripts.OnTextChanged then self.scripts.OnTextChanged(self) end
    end
    function w:GetText() return self.text end
    function w:GetParent() return self.parent end
    function w:GetStringHeight() return #self.text end
    function w:SetScrollChild(child) self.child = child end
    function w:SetVerticalScroll(value) self.scroll = value end
    function w:Show() self.shown = true end
    function w:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function w:IsShown() return self.shown and (not self.parent or self.parent:IsShown()) end
    function w:Disable() self.disabled = true end
    function w:Enable() self.disabled = false end
    function w:CreateFontString() return widget(self) end
    function w:CreateTexture() return widget(self) end
    return w
end
UIParent = widget()
CreateFrame = function(_, name, parent, template)
    local w = widget(parent)
    w.name, w.template = name, template
    if template == "BasicFrameTemplateWithInset" then w.TitleText = widget(w) end
    return w
end
SlashCmdList = {}
date = function() return "12:00:00" end
time = function() return 1700000000 end
UnitName = function() return "Test" end
GetRealmName = function() return "Realm" end
UnitFactionGroup = function() return "Alliance" end
local ns = {}
local selectedTarget, targetChanges = nil, 0
ns.PrepareShufflePlanChange = function() return true end
ns.SetSnatchTarget = function(target)
    selectedTarget, targetChanges = target, targetChanges + 1
    return true
end
assert(loadfile("addon/ShuffleDetector/ShuffleDetector.lua"))("ShuffleDetector", ns)

-- Synthetic records; no production data or DE baseline.
local function recipe(name, item, reagent, qty, spell, makes)
    return { name = name, item = item, reagents = { { item = reagent, qty = qty } }, spell = spell, makes = makes }
end
AHSnapshotDB.characters = {
    ["Test-Realm-Alliance"] = { professions = {
        Tailoring = {
            recipes = {
                recipe("Bolt", 11, 10, 2, 1),
                recipe("Piece", 20, 11, 3, 2, 2),
                { name = "Incomplete", item = 50 },
            },
            available = { recipe("Unlearned", 21, 11, 4, 3) },
        },
        Enchanting = { recipes = { { name = "Productless enchant" } } },
    } },
    ["Other-Realm-Alliance"] = { professions = { Alchemy = {
        recipes = { recipe("Other character", 22, 10, 1, 4) },
    } } },
}
AHSnapshotDB.items = {
    [10] = { name = "Raw", class = 7 },
    [11] = { name = "Bolt", class = 7, sell = 1 },
    [20] = { name = "Piece", class = 4, sell = 100 },
    [21] = { name = "Unlearned", class = 4, sell = 50 },
}
AHSnapshotDB.vendor = { [10] = 4 }
AHSnapshotDB.planSelection = { preserve = true }
ns.plan = { item = 900, private = "legacy-plan" }
local prices = { [10] = 5, [11] = 20, [20] = 99999 }
local reads = {}
GetBuildInfo = function() return "1.60.1", "70888", "date", 16001 end
WOW_PROJECT_ID = 18
C_AddOns = { GetAddOnMetadata = function() return "344" end }
GetItemInfo = function() error("ID read must not require cached item info") end
Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(addon, id)
        eq(addon, "ShuffleDetector")
        reads[id] = (reads[id] or 0) + 1
        return prices[id]
    end,
    GetAuctionAgeByItemID = function() return 0 end,
} } }
for _, module in ipairs({ "Prices", "Evaluate", "Calculator", "Planner", "Browser" }) do
    assert(loadfile("addon/ShuffleDetector/" .. module .. ".lua"))("ShuffleDetector", ns)
end
local function find(results, name)
    for _, r in ipairs(results) do if r.recipe.name == name then return r end end
end
local results, err, info = ns.PlannerResults({ knownOnly = true })
eq(err, nil)
eq(#results, 2, "current character's learned item-producing recipes only")
eq(info.skipped, 2, "incomplete records reported")
eq(reads[10], 1, "one quote per item per refresh")
eq(reads[20], nil, "gear AH quotes must remain gated even with a numeric API price")
eq(info.quotes[20].reason, "unsupported-item-identity")
local piece = find(results, "Piece")
eq(piece.cost, 24, "raw preparation uses a learned recipe and cheaper vendor raw")
eq(piece.exit, "Vendor")
eq(piece.net, 200, "multi-output vendor value")
eq(piece.profit, 176)
eq(piece.recipe.known, true)
eq(piece.recipe.disenchant, nil, "no seed or sparse observation is promoted")
eq(ns.CanActivatePlannerResult({ recipe = { known = false } }, {}), nil,
    "unlearned recipes cannot become the active shuffle")
eq(ns.plan.item, 900, "preview never replaces the loaded plan")
eq(AHSnapshotDB.planSelection.preserve, true)
local batch = assert(ns.CalculateBatch(piece, "crafts", 10))
eq(batch.crafts, 10)
eq(batch.items, 20)
eq(batch.cost, 240)
eq(batch.revenue, 2000)
eq(batch.purchases[1].item, 10, "raw preparation produces a raw shopping requirement")
eq(batch.purchases[1].qty, 60)
eq(batch.purchases[1].total, 240)
eq(batch.purchases[1].source, "Vendor")
eq(batch.purchases[1].prepare, true)
eq(batch.marketDepth, "unknown")
eq(batch.outputs[1].expected, 20)
batch = assert(ns.CalculateBatch(piece, "budget", 239))
eq(batch.crafts, 9, "budget must not exceed the actual input")
assert(batch.cost <= 239)
eq(assert(ns.CalculateBatch(piece, "budget", 240)).crafts, 10)
eq(assert(ns.CalculateBatch(piece, "crafts", 0)).cost, 0)
local free = ns.Evaluate({ item = 11, makes = 1, reagents = { { item = 10, qty = 2 } } }, {
    vendorBuy = function() return 0 end,
    vendorSell = function() return 1 end,
})
local freeBatch = assert(ns.CalculateBatch(free, "budget", 0))
eq(freeBatch.crafts, 100000, "valid zero economic costs use the budget search cap")
eq(freeBatch.cost, 0)
eq(freeBatch.capped, true)
for _, invalid in ipairs({ -1, 100001, 1.5, math.huge, 0 / 0 }) do
    local bad, reason = ns.CalculateBatch(piece, "crafts", invalid)
    eq(bad, nil)
    assert(reason)
end
batch = assert(ns.CalculateBatch(piece, "crafts", 100000))
eq(batch.crafts, 100000)
eq(batch.items, 200000, "calculator never silently clamps finished item output")
assert(batch.transferReason:find("100000", 1, true))
batch = assert(ns.CalculateBatch(piece, "budget", 100000000000))
eq(batch.crafts, 100000)
eq(batch.capped, true)

results = assert(ns.PlannerResults({ profession = "Tailoring", search = "unlearned" }))
eq(#results, 1)
eq(results[1].recipe.known, false)
results = assert(ns.PlannerResults({ unlearnedOnly = true }))
eq(#results, 2, "patterns filter excludes learned shuffles and includes other characters' professions")
local alt = find(results, "Other character")
eq(alt.recipe.profession, "Alchemy")
eq(alt.recipe.known, false, "another character's recipe is never craftable here")
eq(alt.recipe.learnedBy, "Other")
eq(alt.recipe.professionKnown, false)
eq(find(results, "Unlearned").recipe.professionKnown, true)
eq(ns.CanActivatePlannerResult(alt, {}), nil, "another character's recipe cannot become the active shuffle")
eq(#assert(ns.PlannerResults({ knownOnly = true })), 2, "learned filter stays this character's crafts")
results = assert(ns.PlannerResults({ newOnly = true }))
eq(#results, 1, "new-profession filter lists only professions this character lacks")
eq(results[1].recipe.name, "Other character")
AHSnapshotDB.catalog = { version = 1, professions = {
    Engineering = { recipes = { recipe("Gadget", 23, 10, 2, 5), { name = "Broken" } } },
    Alchemy = { recipes = { recipe("Catalog alchemy", 24, 10, 1, 6) } },
    Tailoring = { recipes = { recipe("Catalog tailoring", 25, 10, 1, 7) } },
} }
results, err, info = ns.PlannerResults({ newOnly = true })
eq(#results, 2, "catalog adds only professions no recorded character has")
local gadget = find(results, "Gadget")
eq(gadget.recipe.catalog, true)
eq(gadget.recipe.known, false)
eq(gadget.recipe.profession, "Engineering")
eq(find(results, "Catalog alchemy"), nil, "a profession an alt has comes from the alt, not the catalog")
local listedProfessions = table.concat(info.professions, ",")
eq(listedProfessions, "Alchemy,Enchanting,Engineering,Tailoring", "profession filter lists every source")
eq(#assert(ns.PlannerResults({ profession = "Engineering" })), 1)
AHSnapshotDB.catalog = nil
eq(#assert(ns.PlannerResults({ profession = "Enchanting" })), 0)
results = assert(ns.PlannerResults({ search = "Piece", exit = "Sell on AH" }))
eq(results[1].net, nil, "an unverified gear exit does not inherit the vendor exit")
piece = results[1]
prices[11], prices[10], AHSnapshotDB.vendor[10] = nil, nil, nil
piece = find(assert(ns.PlannerResults()), "Piece")
eq(piece.cost, nil, "missing prices stay unknown")
local unknownBatch, budgetError = ns.CalculateBatch(piece, "budget", 1000)
eq(unknownBatch, nil)
assert(budgetError:find("every reagent", 1, true))
eq(assert(ns.CalculateBatch(piece, "crafts", 2)).cost, nil)
prices[11], prices[10] = 20, 5
reads = {}
results = assert(ns.PlannerResults())
eq(find(results, "Piece").cost, 30, "next refresh sees changed vendor/market data")
eq(reads[10], 1)

local function click(label)
    for _, w in ipairs(widgets) do
        if w.text == label and w.scripts.OnClick and w:IsShown() then
            assert(not w.disabled, "disabled choice must not be selectable")
            w.scripts.OnClick(w)
            return w
        end
    end
    error("missing button " .. label)
end
SlashCmdList.SHUFFLEDETECTOR("browse")
local browser
for _, w in ipairs(widgets) do if w.name == "ShuffleDetectorBrowser" then browser = w end end
assert(browser and browser.shown, "slash command opens the real browser")
click("Calculate")
click("Crafts")
click("Calculate")
click("Next >")
click("< Previous")
click("All professions v")
click("Tailoring")
click("Learned recipes v")
click("Unlearned patterns (learn later)")
local patternShown = false
for _, w in ipairs(widgets) do
    if w.text and w.text:find("Pattern to learn later", 1, true) then patternShown = true end
end
assert(patternShown, "explain that patterns are previews to learn, not action buttons")
click("Unlearned patterns v")
click("Professions to learn")
click("Tailoring v")
click("All professions")
local altRow
for _, w in ipairs(widgets) do
    if w:IsShown() and w.nameText and w.nameText.text and w.nameText.text:find("Other character", 1, true)
        and w.scripts.OnClick then altRow = w end
end
assert(altRow, "professions to learn lists another character's profession")
altRow.scripts.OnClick(altRow)
local newShown, learnedByShown = false, false
for _, w in ipairs(widgets) do
    if w.text and w.text:find("Profession not learned", 1, true) then newShown = true end
    if w.text and w.text:find("Learned by Other", 1, true) then learnedByShown = true end
end
assert(newShown and learnedByShown, "detail names the missing profession and who has it")
click("All professions v")
click("Tailoring")
click("Professions to learn v")
click("Learned recipes (shuffle previews)")
click("Best available exit v")
local disabledDE
for _, w in ipairs(widgets) do
    if w.text == "Disenchant - no trusted yield data" then disabledDE = w end
end
assert(disabledDE and disabledDE.disabled, "do not invite selecting an exit with no model")
click("Vendor")
click("Vendor v")
click("Best available exit")
local widgetCount = #widgets
for _ = 1, 3 do
    click("Best available exit v")
    click("Best available exit")
end
eq(#widgets, widgetCount, "reopening a dropdown reuses its frames")
click("Refresh / search")
local function visible(fragment)
    for _, w in ipairs(widgets) do
        if w:IsShown() and w.text and w.text:find(fragment, 1, true) then return w end
    end
end
local metadata = C_AddOns.GetAddOnMetadata
C_AddOns.GetAddOnMetadata = function() return "346" end
click("Refresh / search")
assert(visible("Auctionator 346 prices"), "any Auctionator version is used and named in the banner")
eq(visible("Missing reagent prices"), nil, "newer Auctionator prices reach the recipe browser")
eq(visible("Preview 346"), nil, "there is no preview switch")
eq(visible("UNTESTED"), nil, "newer versions are not labeled untested")
local api = Auctionator.API.v1
Auctionator.API.v1 = nil
click("Refresh / search")
assert(visible("does not expose Auctionator.API.v1"), "a missing API is explained in one banner")
local repeatsUnknown = false
for _, w in ipairs(widgets) do
    if w:IsShown() and w.text and w.text:find("unknown / craft - unknown", 1, true) then repeatsUnknown = true end
end
eq(repeatsUnknown, false, "incomplete rows say why instead of repeated unknown values")
assert(visible("no verified disenchant yield table"), "explain why disenchant is not estimated")
Auctionator.API.v1 = api
click("Refresh / search")
for _, w in ipairs(widgets) do
    if w.nameText and w.nameText.text and w.nameText.text:find("Piece", 1, true) and w.scripts.OnClick then
        w.scripts.OnClick(w)
        break
    end
end
local use
for _, w in ipairs(widgets) do
    if w.text == "Set active shuffle" and w.scripts.OnClick then use = w end
end
assert(use and use.scripts.OnClick, "set active shuffle button exists")
eq(use.disabled, true, "a 1 copper budget buys no crafts, so nothing to activate")
click("Budget (copper)")
eq(use.disabled, false, "a fully priced learned recipe can be activated without pressing Calculate")
click("Set active shuffle")
eq(ns.plan.item, 20, "explicit browser action replaces the active plan")
eq(AHSnapshotDB.activePlan.spell, 2, "the selected plan is saved in addon SavedVariables")
eq(AHSnapshotDB.activePlan.exit, "Vendor")
eq(AHSnapshotDB.activePlan.selectedAt, 1700000000, "selection timestamp is saved for companion precedence")
eq(selectedTarget, 2, "batch calculator target is set in finished items")
assert(visible("No purchases or crafts were started"), "activation never starts a protected action")
C_AddOns.GetAddOnMetadata = metadata
click("Best available exit v")
local cover
for _, w in ipairs(widgets) do
    if w.scripts.OnMouseDown and w:IsShown() then cover = w end
end
assert(cover, "dropdown has an outside-click dismissal layer")
cover.scripts.OnMouseDown(cover)
eq(cover:IsShown(), false)
click("Best available exit v")
SlashCmdList.SHUFFLEDETECTOR("browse")
eq(browser.shown, false)
eq(cover:IsShown(), false, "closing the browser closes its dropdown")
SlashCmdList.SHUFFLEDETECTOR("browse")
eq(browser.shown, true)
eq(ns.plan.item, 20, "browsing after activation preserves the selected execution plan")
eq(AHSnapshotDB.planSelection.preserve, true)
eq(ns.ValidateActivePlan({ version = 1, selectedAt = 1700000000, recipe = "Invalid" }), false,
    "malformed saved selections are ignored")
eq(ns.ValidateActivePlan(AHSnapshotDB.activePlan), true,
    "the saved in-game selection is valid for restore after reload (snatch harness covers ADDON_LOADED)")

local saved = AHSnapshotDB.characters
AHSnapshotDB.characters = nil
local empty, reason = ns.PlannerResults()
eq(empty, nil)
assert(reason:find("No recorded", 1, true))
AHSnapshotDB.characters = saved
local learned = saved["Test-Realm-Alliance"].professions.Tailoring.recipes
learned[#learned + 1] = {
    name = "Malformed reagents", item = 50, makes = 1,
    reagents = { [1] = { item = 10, qty = 1 }, [3] = { item = 11, qty = 1 } },
}
local malformed = recipe("Malformed makes", 50, 10, 1, 50)
malformed.makes = false
learned[#learned + 1] = malformed
local checked, _, checkedInfo = ns.PlannerResults({ knownOnly = true })
eq(#checked, 2, "malformed records never become free or partially costed recipes")
eq(checkedInfo.skipped, 4)

-- Reload only the browser module to discard its locals, as a UI reload would.
local function reloadBrowser()
    if browser:IsShown() then browser:Hide() end
    assert(loadfile("addon/ShuffleDetector/Browser.lua"))("ShuffleDetector", ns)
    ns.TogglePlanner()
    for _, w in ipairs(widgets) do
        if w.name == "ShuffleDetectorBrowser" and w:IsShown() then browser = w end
    end
end
local function editBox(width)
    for _, w in ipairs(widgets) do
        if w.template == "InputBoxTemplate" and w.width == width and w:IsShown() then return w end
    end
    error("missing edit box " .. width)
end
local key = ns.charKey()
local activePlan, activeSaved, target = ns.plan, AHSnapshotDB.activePlan, selectedTarget
local changesBeforeRestore = targetChanges
click("Tailoring v")
click("Tailoring")
click("Learned recipes v")
click("All recipes")
click("Best available exit v")
click("Vendor")
editBox(200):SetText("Piece")
editBox(120):SetText("75")
click("Crafts")
click("Refresh / search")
local state = AHSnapshotDB.plannerByCharacter[key]
eq(state.version, 1)
eq(state.profession, "Tailoring")
eq(state.recipes, "all")
eq(state.exit, "Vendor")
eq(state.search, "Piece")
eq(state.mode, "budget")
eq(state.amount, "75")
eq(state.selected, "Tailoring:2")
local costBefore = find(assert(ns.PlannerResults()), "Piece").cost
prices[10] = 6
reloadBrowser()
eq(editBox(200):GetText(), "Piece", "search survives module reload")
eq(editBox(120):GetText(), "75", "calculator input survives module reload")
assert(visible("Tailoring v") and visible("All recipes v") and visible("Vendor v"))
assert(visible("Budget (copper)"), "calculator mode survives reload")
assert(visible("> Piece"), "preview selection survives reload")
eq(visible("Batch estimate"), nil, "old calculated quotes are never restored")
assert(find(assert(ns.PlannerResults()), "Piece").cost ~= costBefore, "restored preview uses fresh prices")
click("Calculate")
assert(visible("2 crafts / 4 finished items"), "restored budget is calculated from fresh prices")
eq(ns.plan, activePlan, "restoring browser state never changes execution")
eq(AHSnapshotDB.activePlan, activeSaved)
eq(selectedTarget, target)
eq(targetChanges, changesBeforeRestore, "restoring browser settings never calls execution target setters")

local originalCharKey = ns.charKey
browser:Hide()
ns.charKey = function() return "Other-Realm-Alliance" end
reloadBrowser()
eq(editBox(200):GetText(), "", "another character gets its own default filters")
eq(editBox(120):GetText(), "1")
assert(visible("Learned recipes v") and visible("All professions v") and visible("Crafts"))
editBox(120):SetText("9")
browser:Hide()
ns.charKey = originalCharKey
reloadBrowser()
eq(editBox(120):GetText(), "75", "another character's input does not replace this character's settings")
eq(AHSnapshotDB.plannerByCharacter["Other-Realm-Alliance"].amount, "9")

-- A saved selection on a later page must be visible, not just used in the detail pane.
for i = 1, 12 do
    learned[#learned + 1] = recipe("Extra " .. i, 20, 10, i + 10, 100 + i)
end
browser:Hide()
state = AHSnapshotDB.plannerByCharacter[key]
state.search, state.selected = "", "Tailoring:112"
reloadBrowser()
assert(visible("> Extra 12"), "restored selection reveals its page")
prices[10] = 100
click("Refresh / search")
assert(visible("> Extra 12"), "refresh keeps the selected row visible when rankings change")
learned[#learned] = nil
reloadBrowser()
assert(AHSnapshotDB.plannerByCharacter[key].selected ~= "Tailoring:112",
    "a removed recipe falls back to a current matching preview")
eq(ns.plan, activePlan, "a missing preview recipe never clears the active plan")

editBox(120):SetText("bad")
reloadBrowser()
click("Calculate")
assert(visible("Enter a whole number"), "invalid typed amounts remain explicit calculator errors")
eq(editBox(120):GetText(), "bad", "draft input is not silently replaced with a valid amount")
local invalidStates = {
    false,
    { version = 99 },
    { version = 1, search = {}, recipes = "all", mode = "crafts", amount = "1" },
    { version = 1, search = "", recipes = "all", mode = "crafts", amount = "1", exit = "Disenchant" },
    { version = 1, search = "", recipes = "all", mode = "crafts", amount = "1", selected = {} },
    { version = 1, search = "", recipes = "all", mode = "other", amount = "1" },
    { version = 1, search = "", recipes = "all", mode = "crafts", amount = string.rep("1", 13) },
}
for _, invalidState in ipairs(invalidStates) do
    browser:Hide()
    AHSnapshotDB.plannerByCharacter[key] = invalidState
    assert(loadfile("addon/ShuffleDetector/Browser.lua"))("ShuffleDetector", ns)
    ns.TogglePlanner()
    for _, w in ipairs(widgets) do
        if w.name == "ShuffleDetectorBrowser" and w:IsShown() then browser = w end
    end
    assert(AHSnapshotDB.log[#AHSnapshotDB.log]:find("invalid or unsupported saved settings", 1, true))
    eq(editBox(120):GetText(), "1")
    eq(editBox(200):GetText(), "")
    assert(visible("Learned recipes v") and visible("Crafts"), "bad state restores safe browser defaults")
end
browser:Hide()
AHSnapshotDB.plannerByCharacter = false
reloadBrowser()
assert(AHSnapshotDB.log[#AHSnapshotDB.log]:find("invalid saved settings container", 1, true))
eq(editBox(120):GetText(), "1")
click("Learned recipes v")
click("Unlearned patterns (learn later)")
click("Best available exit v")
click("Sell on AH (verified item types)")
reloadBrowser()
assert(visible("Unlearned patterns v") and visible("Sell on AH v"),
    "unlearned and AH filters survive reload even without a priced exit")
assert(visible("> Unlearned"), "the unlearned preview selection survives reload")
eq(ns.plan, activePlan)
eq(AHSnapshotDB.activePlan, activeSaved)
eq(selectedTarget, target)
eq(targetChanges, changesBeforeRestore)

-- Custom costs are calculator-only estimates, persisted per character/item.
click("Unlearned patterns v")
click("Learned recipes (shuffle previews)")
click("Sell on AH v")
click("Vendor")
editBox(200):SetText("Piece")
editBox(120):SetText("75")
click("Refresh / search")
click("Crafts")
local marketPiece = find(assert(ns.PlannerResults({ search = "Piece", exit = "Vendor" })), "Piece")
eq(marketPiece.cost, 60)
click("Material costs")
assert(visible("Bolt (item 11)"))
local costInput = editBox(150)
costInput:SetText("99")
click("Set cost")
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[11], 99)
costInput:SetText("100000000000")
click("Set cost")
eq(costInput:GetText(), "100000000000", "maximum custom cost remains editable without scientific notation")
costInput:SetText("99")
click("Set cost")
costInput:SetText("-1")
click("Set cost")
assert(visible("Enter a whole copper amount"))
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[11], 99, "invalid edits never overwrite the existing override")
costInput:SetText("1.5")
click("Set cost")
assert(visible("Enter a whole copper amount"))
click("Next material >")
assert(visible("Raw (item 10)"), "raw inputs are configurable even when the direct material is cheaper")
costInput:SetText("1")
click("Set cost")
click("Done")
click("Calculate")
assert(visible("12 crafts / 24 finished items"), "budget uses custom raw cost")
assert(visible("72c; returns:"), "batch cost uses 6 raw per craft at 1 copper")
assert(visible("Raw: 72c (Custom)"), "shopping list labels the overridden raw price")
assert(visible("Custom cost not used: Bolt"), "cheaper alternative is explained")
eq(find(assert(ns.PlannerResults({ search = "Piece", exit = "Vendor" })), "Piece").cost, 60,
    "custom costs do not affect rankings")
eq(ns.plan, activePlan, "changing material costs never changes execution")
eq(targetChanges, changesBeforeRestore)
reloadBrowser()
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[10], 1)
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[11], 99)
click("Calculate")
assert(visible("12 crafts / 24 finished items"), "saved overrides affect batch after reload")
click("Set active shuffle")
eq(AHSnapshotDB.activePlan.estimate.cost, 6, "active plan freezes the custom batch estimate per craft")
eq(selectedTarget, 24)
eq(AHSnapshotDB.activePlan.reagents[1].raw.item, 10)
click("Material costs")
click("Next material >")
click("Use market")
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[10], nil)
eq(visible("12 crafts / 24 finished items"), nil, "changing a cost invalidates the previously calculated batch")
click("< Previous material")
costInput = editBox(150)
costInput:SetText("0")
click("Set cost")
click("Done")
click("Calculate")
assert(visible("100000 crafts / 200000 finished items"), "zero custom cost uses the explicit budget cap")
assert(visible("Bolt: 0c (Custom)"))
assert(visible("More than 100000 finished items"), "custom zero never bypasses the execution output limit")
eq(targetChanges, changesBeforeRestore + 1, "editing overrides never changes the active target")
eq(AHSnapshotDB.activePlan.estimate.cost, 6, "editing costs does not rewrite a frozen active estimate")

browser:Hide()
ns.charKey = function() return "Other-Realm-Alliance" end
reloadBrowser()
eq(AHSnapshotDB.plannerByCharacter["Other-Realm-Alliance"].materialCosts[11], nil,
    "custom costs are isolated to the selected character")
browser:Hide()
ns.charKey = originalCharKey
reloadBrowser()
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[11], 0, "zero override persists across character switches")

browser:Hide()
AHSnapshotDB.plannerByCharacter[key].materialCosts[11] = -1
reloadBrowser()
assert(AHSnapshotDB.log[#AHSnapshotDB.log]:find("invalid or unsupported saved settings", 1, true))
eq(AHSnapshotDB.plannerByCharacter[key].materialCosts[11], nil, "malformed overrides are not used in calculations")

-- A custom cost can complete a missing market input without changing the rank.
prices[10], prices[11] = nil, nil
editBox(200):SetText("Piece")
click("Refresh / search")
assert(visible("Missing reagent prices"), "ranking still shows missing market prices")
click("Material costs")
costInput = editBox(150)
costInput:SetText("2")
click("Set cost")
click("Done")
click("Set active shuffle")
eq(AHSnapshotDB.activePlan.estimate.cost, 6, "activation without Calculate uses custom input")
eq(selectedTarget, 2)
assert(visible("Missing reagent prices"), "custom estimate never fabricates market ranking prices")

-- Recipe catalog scan: a stubbed client knows a few recipe spell IDs across professions.
local said = {}
local say = ns.say
ns.say = function(msg) said[#said + 1] = msg end
GetTime = function() return 10 end
local timers = {}
C_Timer = { After = function(_, f) timers[#timers + 1] = f end }
GetItemInfo = function(id) return "Item " .. id, nil, 1, 1, nil, nil, nil, nil, nil, nil, 3, 7 end
local function schematic(item, reagent, qty, makes)
    return { name = "Schematic " .. item, outputItemID = item, quantityMin = makes,
        reagentSlotSchematics = { { reagentType = 1, quantityRequired = qty, reagents = { { itemID = reagent } } } } }
end
local schematics = {
    [1] = schematic(11, 10, 2),
    [4] = schematic(22, 10, 1),
    [30] = schematic(300, 301, 3, 2),
    [31] = schematic(302, 301, 1),
    [32] = schematic(303, 301, 1),
    [33] = { name = "Enchant without product", reagentSlotSchematics = {} },
    [40] = schematic(400, 401, 1),
}
local lines = { [1] = 197, [4] = 171, [30] = 202, [31] = 202, [32] = 202, [40] = 999 }
C_TradeSkillUI = {
    GetRecipeSchematic = function(id)
        if id == 50 then error("bad id") end
        return schematics[id]
    end,
    GetTradeSkillLineForRecipe = function(id) return lines[id], nil, lines[id] end,
    GetRecipeInfo = function(id) return id == 32 and { isDummyRecipe = true } or nil end,
}
assert(loadfile("addon/ShuffleDetector/Catalog.lua"))("ShuffleDetector", ns)
SlashCmdList.SHUFFLEDETECTOR("catalog nope")
assert(said[#said]:find("highest spell ID", 1, true), "bad scan limit is explained")
SlashCmdList.SHUFFLEDETECTOR("catalog 5000")
local scanner
for _, w in ipairs(widgets) do if w.scripts.OnUpdate then scanner = w end end
assert(scanner, "scan runs across frames")
scanner.scripts.OnUpdate(scanner)
SlashCmdList.SHUFFLEDETECTOR("catalog")
assert(said[#said]:find("scan running, 2001 of 5000", 1, true), "a second command reports progress")
for _ = 1, 3 do if scanner.scripts.OnUpdate then scanner.scripts.OnUpdate(scanner) end end
eq(scanner.scripts.OnUpdate, nil, "scan stops when done")
local catalog = AHSnapshotDB.catalog
eq(catalog.version, 1)
eq(catalog.maxSpell, 5000)
eq(catalog.build, "70888")
eq(catalog.professions.Tailoring, nil, "professions a character has are not stored")
eq(catalog.professions.Alchemy, nil, "an alt's profession is not stored")
local engineering = catalog.professions.Engineering.recipes
eq(#engineering, 2, "dummy and productless recipes are skipped")
eq(engineering[1].name, "Schematic 300")
eq(engineering[1].spell, 30)
eq(engineering[1].makes, 2)
eq(engineering[1].reagents[1].qty, 3)
eq(catalog.professions["999"], nil)
local text = table.concat(said, "\n")
assert(text:find("2 recipes from professions none of your characters has: Engineering 2", 1, true), text)
assert(text:find("Alchemy 1 of 1, Tailoring 1 of ", 1, true), "scan reports how many recorded recipes it found")
assert(text:find("1 recipes skipped", 1, true), "unknown skill lines are counted, not guessed")
eq(#timers, 1, "catalog items are requested")
timers[1]()
eq(AHSnapshotDB.items[300].name, "Item 300")
eq(AHSnapshotDB.items[301].sell, 3)
results = assert(ns.PlannerResults({ newOnly = true, profession = "Engineering" }))
eq(#results, 2, "scanned recipes reach the browser")
ns.say = say
print("planner workflow checks passed")
