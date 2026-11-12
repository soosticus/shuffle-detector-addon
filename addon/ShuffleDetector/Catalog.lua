local _, ns = ...

-- Reads recipes of professions none of your characters has from the game client's own recipe data:
-- the modern schematic API answers for a recipe spell ID without its profession window. Results are
-- saved in AHSnapshotDB.catalog and appear in the browser as patterns of professions to learn.

-- Profession skill line IDs are game constants; the names must match GetProfessionInfo's (English client).
local SKILL_LINES = {
    [129] = "First Aid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy",
    [185] = "Cooking", [186] = "Mining", [197] = "Tailoring", [202] = "Engineering",
    [333] = "Enchanting", [755] = "Jewelcrafting", [773] = "Inscription",
}
local DEFAULT_MAX, LIMIT, FRAME_MS, FRAME_IDS = 500000, 2000000, 8, 2000

local scanning
local driver
local failed -- an automatic scan that errored is not retried until /reload

local function integer(n, low, high)
    return type(n) == "number" and n >= low and n <= high and n == math.floor(n)
end

local function professionOf(T, id)
    if T.GetTradeSkillLineForRecipe then
        local ok, line, name, parent = pcall(T.GetTradeSkillLineForRecipe, id)
        if ok then
            if SKILL_LINES[parent] then return SKILL_LINES[parent] end
            if SKILL_LINES[line] then return SKILL_LINES[line] end
            if (parent == nil or parent == 0) and type(name) == "string" and name ~= "" then return name end
        end
    end
    if T.GetProfessionInfoByRecipeID then
        local ok, info = pcall(T.GetProfessionInfoByRecipeID, id)
        if ok and type(info) == "table" then
            local line = info.parentProfessionID or info.professionID
            if SKILL_LINES[line] then return SKILL_LINES[line] end
            local name = info.parentProfessionName or info.professionName
            if type(name) == "string" and name ~= "" then return name end
        end
    end
end

local function spellName(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, id)
        if ok and type(name) == "string" then return name end
    end
end

-- One spell ID: a recipe with a product and reagents, or nil.
local function read(T, id)
    local reagents, item, makes, name = ns.RecipeSchematic(T, id)
    if not (reagents and #reagents > 0 and integer(item, 1, 10000000)) then return end
    if T.GetRecipeInfo then
        local ok, info = pcall(T.GetRecipeInfo, id)
        if ok and type(info) == "table" then
            if info.isDummyRecipe then return end
            name = name or info.name
        end
    end
    name = type(name) == "string" and name ~= "" and name or spellName(id)
    if not name then return end
    return { name = name, spell = id, item = item, makes = integer(makes, 2, 100000) and makes or nil,
        reagents = reagents }
end

local function recordedProfessions()
    local anyone, spells = {}, {}
    for _, character in pairs(type(AHSnapshotDB.characters) == "table" and AHSnapshotDB.characters or {}) do
        for name, prof in pairs(type(character) == "table" and type(character.professions) == "table"
            and character.professions or {}) do
            anyone[name] = true
            spells[name] = spells[name] or {}
            for _, category in ipairs({ "recipes", "available" }) do
                for _, r in ipairs(type(prof) == "table" and type(prof[category]) == "table" and prof[category] or {}) do
                    if type(r) == "table" and r.spell then spells[name][r.spell] = true end
                end
            end
        end
    end
    return anyone, spells
end

local function finish(s)
    local anyone, spells = recordedProfessions()
    local catalog = { version = 1, scanned = time(), maxSpell = s.max, professions = {} }
    if GetBuildInfo then catalog.build = select(2, GetBuildInfo()) end
    local added, parts, checks, items = 0, {}, {}, {}
    local names = {}
    for name in pairs(s.found) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local list = s.found[name]
        if anyone[name] then
            local recorded, matched = 0, 0
            for _ in pairs(spells[name]) do recorded = recorded + 1 end
            for _, r in ipairs(list) do if spells[name][r.spell] then matched = matched + 1 end end
            checks[#checks + 1] = ("%s %d of %d"):format(name, matched, recorded)
        else
            catalog.professions[name] = { recipes = list }
            added = added + #list
            parts[#parts + 1] = ("%s %d"):format(name, #list)
            for _, r in ipairs(list) do
                items[#items + 1] = r.item
                for _, x in ipairs(r.reagents) do items[#items + 1] = x.item end
            end
        end
    end
    AHSnapshotDB.catalog = catalog
    ns.say(("catalog: %d recipes from professions none of your characters has%s"):format(added,
        #parts > 0 and (": " .. table.concat(parts, ", ")) or ""))
    if #checks > 0 then
        ns.say("catalog check, recorded recipes also found by the scan: " .. table.concat(checks, ", "))
    end
    if s.unnamed > 0 then
        ns.say(("catalog: %d recipes skipped because the game did not name their profession"):format(s.unnamed))
    end
    ns.log(("catalog: scanned 1-%d in %.1fs, %d recipes, %d unnamed"):format(s.max, GetTime() - s.started,
        s.total, s.unnamed))
    local requested = ns.RequestItems and ns.RequestItems(items) or 0
    if requested > 0 then ns.say(("catalog: requesting %d item names and prices"):format(requested)) end
    if added == 0 and s.total == 0 then
        ns.say("catalog: the game answered no recipe IDs; this client may only describe recipes of open professions")
    end
end

local function step()
    local s, T = scanning, C_TradeSkillUI
    local clock = debugprofilestop
    local deadline = clock and clock() + FRAME_MS
    local n = 0
    while s.id <= s.max do
        local recipe = read(T, s.id)
        if recipe then
            local profession = professionOf(T, s.id)
            if profession then
                s.found[profession] = s.found[profession] or {}
                table.insert(s.found[profession], recipe)
                s.total = s.total + 1
            else
                s.unnamed = s.unnamed + 1
            end
        end
        s.id, n = s.id + 1, n + 1
        if s.id % 100000 == 0 and not s.auto then ns.say(("catalog: scanned %d of %d spell IDs"):format(s.id, s.max)) end
        if (deadline and clock() >= deadline) or (not deadline and n >= FRAME_IDS) then return end
    end
    scanning = nil
    driver:SetScript("OnUpdate", nil)
    finish(s)
    if s.onDone then s.onDone() end
end

local function currentBuild()
    return GetBuildInfo and select(2, GetBuildInfo())
end

-- Percent done while a scan runs, else nil.
function ns.RecipeCatalogProgress()
    return scanning and math.floor(100 * scanning.id / scanning.max)
end

-- The browser starts a scan when there is no catalog for this client build; onDone runs when it finishes.
function ns.EnsureRecipeCatalog(onDone)
    if scanning or failed then return end
    local catalog = AHSnapshotDB.catalog
    if type(catalog) == "table" and catalog.version == 1 and catalog.build == currentBuild() then return end
    ns.ScanRecipeCatalog(nil, onDone)
end

function ns.ScanRecipeCatalog(arg, onDone)
    if scanning then
        ns.say(("catalog: scan running, %d of %d spell IDs"):format(scanning.id, scanning.max))
        return
    end
    local T = C_TradeSkillUI
    if not (T and T.GetRecipeSchematic and ns.RecipeSchematic) then
        ns.say("catalog: this client has no recipe schematic API")
        return
    end
    local max = DEFAULT_MAX
    if arg and arg ~= "" then
        max = tonumber(arg)
        if not integer(max, 1, LIMIT) then
            ns.say(("catalog: give the highest spell ID to scan, 1 to %d"):format(LIMIT))
            return
        end
    end
    scanning = { id = 1, max = max, found = {}, total = 0, unnamed = 0, started = GetTime(), onDone = onDone,
        auto = onDone ~= nil }
    driver = driver or CreateFrame("Frame")
    driver:SetScript("OnUpdate", function()
        local ok, err = pcall(step)
        if not ok then
            if scanning and scanning.auto then failed = true end
            scanning = nil
            driver:SetScript("OnUpdate", nil)
            ns.say("catalog: scan failed: " .. tostring(err))
        end
    end)
    ns.say(onDone and "catalog: reading recipes of professions none of your characters has from the game, once per game build"
        or ("catalog: scanning spell IDs 1-%d for recipes; this takes a few seconds"):format(max))
end
