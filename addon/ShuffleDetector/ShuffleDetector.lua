-- ShuffleDetector core: shared namespace, profession/recipe snapshot, slash commands.
-- Scanning lives in Scan.lua, the auction house tab in UI.lua.
-- Data is written by the game to WTF/Account/<acct>/SavedVariables/ShuffleDetector.lua

local ADDON, ns = ...
AHSnapshotDB = AHSnapshotDB or {}
AHSnapshotDB.version = 1

local frame = CreateFrame("Frame")

function ns.say(msg)
    print("|cff33ff99" .. ADDON .. "|r: " .. tostring(msg))
end
local say = ns.say

function ns.realmKey()
    local faction = UnitFactionGroup and UnitFactionGroup("player") or "Neutral"
    return (GetRealmName() or "?") .. "-" .. (faction or "Neutral")
end
local realmKey = ns.realmKey

local function itemIdFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

-- Item names and vendor sell prices as the game reports them (GetItemInfo), keyed by item id.
-- Item data may not be cached yet, so ids it cannot answer for are retried on GET_ITEM_INFO_RECEIVED.
local awaiting = {}

local function recordItem(id)
    if not id then return end
    local name, sell, _
    if C_Item and C_Item.GetItemInfo then
        name, _, _, _, _, _, _, _, _, _, sell = C_Item.GetItemInfo(id)
    elseif GetItemInfo then
        name, _, _, _, _, _, _, _, _, _, sell = GetItemInfo(id)
    end
    if name then
        awaiting[id] = nil
        AHSnapshotDB.items = AHSnapshotDB.items or {}
        AHSnapshotDB.items[id] = { name = name, sell = sell or 0 }
    elseif not awaiting[id] then
        awaiting[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
end
ns.RecordItem = recordItem

-- Professions: skill levels and known recipes, recorded for every profession.
local function charKey()
    return (UnitName("player") or "?") .. "-" .. realmKey()
end

local function snapshotSkills()
    local profs = {}
    if GetProfessions and GetProfessionInfo then
        for _, idx in ipairs({ GetProfessions() }) do
            local name, _, rank, maxRank = GetProfessionInfo(idx)
            if name and name ~= "" then profs[name] = { skill = rank, max = maxRank } end
        end
    end
    if next(profs) == nil and GetNumSkillLines then
        for i = 1, GetNumSkillLines() do
            local name, header, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if not header and name then
                profs[name] = { skill = rank, max = maxRank }
            end
        end
    end
    AHSnapshotDB.characters = AHSnapshotDB.characters or {}
    local c = AHSnapshotDB.characters[charKey()] or { professions = {} }
    for name, p in pairs(profs) do
        local old = c.professions[name]
        p.recipes = old and old.recipes or {}
        c.professions[name] = p
    end
    AHSnapshotDB.characters[charKey()] = c
    return c
end

-- Reagents (item id and count) and the item made, from the modern profession schematic.
local function modernDetails(T, id)
    if not T.GetRecipeSchematic then return end
    local ok, s = pcall(T.GetRecipeSchematic, id, false)
    if not (ok and type(s) == "table") then return end
    local reagents = {}
    for _, slot in ipairs(s.reagentSlotSchematics or {}) do
        local first = slot.reagents and slot.reagents[1]
        if first and first.itemID and (slot.reagentType == nil or slot.reagentType == 1) then
            reagents[#reagents + 1] = { item = first.itemID, qty = slot.quantityRequired or 1 }
        end
    end
    return reagents, s.outputItemID, s.quantityMin
end

-- Modern profession UI (C_TradeSkillUI recipe IDs).
local function readModern()
    local T = C_TradeSkillUI
    if not (T and T.GetAllRecipeIDs and T.GetRecipeInfo) then return end
    local base = T.GetBaseProfessionInfo and T.GetBaseProfessionInfo()
    local ids = T.GetAllRecipeIDs()
    if not (base and base.professionName and ids and #ids > 0) then return end
    local recipes = {}
    for _, id in ipairs(ids) do
        local info = T.GetRecipeInfo(id)
        if info and info.learned and info.name then
            local reagents, item, makes = modernDetails(T, id)
            if not item and T.GetRecipeItemLink then
                local okLink, link = pcall(T.GetRecipeItemLink, id)
                item = okLink and itemIdFromLink(link) or nil
            end
            recipes[#recipes + 1] = { name = info.name, spell = id, item = item,
                                      makes = makes and makes > 1 and makes or nil,
                                      reagents = reagents and #reagents > 0 and reagents or nil }
        end
    end
    return base.professionName, base.skillLevel, base.maxSkillLevel, recipes
end

-- Classic profession UI (GetTradeSkill* functions).
local function readClassic()
    if not (GetTradeSkillLine and GetNumTradeSkills) then return end
    local name, rank, maxRank = GetTradeSkillLine()
    if not name or name == "UNKNOWN" then return end
    local recipes = {}
    for i = 1, GetNumTradeSkills() do
        local rname, kind = GetTradeSkillInfo(i)
        if rname and kind ~= "header" then
            local link = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
            local reagents = {}
            if GetTradeSkillNumReagents and GetTradeSkillReagentInfo and GetTradeSkillReagentItemLink then
                for j = 1, GetTradeSkillNumReagents(i) or 0 do
                    local _, _, count = GetTradeSkillReagentInfo(i, j)
                    local id = itemIdFromLink(GetTradeSkillReagentItemLink(i, j))
                    if id then reagents[#reagents + 1] = { item = id, qty = count or 1 } end
                end
            end
            local makes = GetTradeSkillNumMade and GetTradeSkillNumMade(i)
            recipes[#recipes + 1] = { name = rname, item = itemIdFromLink(link), difficulty = kind,
                                      makes = makes and makes > 1 and makes or nil,
                                      reagents = #reagents > 0 and reagents or nil }
        end
    end
    return name, rank, maxRank, recipes
end

local function snapshotRecipes(quiet)
    local ok, name, rank, maxRank, recipes = pcall(readModern)
    if not (ok and name) then
        ok, name, rank, maxRank, recipes = pcall(readClassic)
    end
    if not (ok and name and name ~= "" and recipes) then return end
    local c = snapshotSkills()
    -- Guard against the API reporting a stale profession name for another profession's recipe list.
    local sig = {}
    for _, r in ipairs(recipes) do sig[#sig + 1] = r.name end
    sig = table.concat(sig, "|")
    for pname, p in pairs(c.professions) do
        if pname ~= name and p.recipes and #p.recipes > 0 then
            local other = {}
            for _, r in ipairs(p.recipes) do other[#other + 1] = r.name end
            if table.concat(other, "|") == sig then
                p.recipes = {}
                return
            end
        end
    end
    c.professions[name] = { skill = rank, max = maxRank, recipes = recipes }
    for _, r in ipairs(recipes) do
        recordItem(r.item)
        for _, x in ipairs(r.reagents or {}) do recordItem(x.item) end
    end
    if not quiet then
        say(("saved %d %s recipes (skill %s/%s)"):format(#recipes, name, tostring(rank), tostring(maxRank)))
    end
end

local pending
local function scheduleSnapshot()
    if pending then return end
    pending = true
    C_Timer.After(1, function()
        pending = false
        snapshotRecipes(true)
    end)
end

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("TRADE_SKILL_SHOW")
frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:SetScript("OnEvent", function(_, event, itemId)
    if event == "GET_ITEM_INFO_RECEIVED" then
        if awaiting[itemId] then recordItem(itemId) end
    elseif event == "TRADE_SKILL_SHOW" then
        snapshotRecipes()
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        scheduleSnapshot()
    else
        snapshotSkills()
    end
end)

function ns.DebugRecipes()
    say(("GetProfessions=%s GetNumSkillLines=%s C_TradeSkillUI.GetAllRecipeIDs=%s GetNumTradeSkills=%s"):format(
        tostring(GetProfessions ~= nil), tostring(GetNumSkillLines ~= nil),
        tostring(C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs ~= nil), tostring(GetNumTradeSkills ~= nil)))
    local c = snapshotSkills()
    for name, p in pairs(c.professions) do
        local withReagents = 0
        for _, r in ipairs(p.recipes or {}) do
            if r.reagents then withReagents = withReagents + 1 end
        end
        say(("  %s skill %s/%s, %d recipes saved (%d with reagents)"):format(
            name, tostring(p.skill), tostring(p.max), #(p.recipes or {}), withReagents))
    end
    snapshotRecipes()
end

SLASH_SHUFFLEDETECTOR1 = "/shuffledetector"
SLASH_SHUFFLEDETECTOR2 = "/ahsnap"
SlashCmdList["SHUFFLEDETECTOR"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "scan" or msg == "" then
        ns.StartScan()
    elseif msg == "debug" then
        ns.DebugUI()
    elseif msg == "recipes" then
        ns.DebugRecipes()
    elseif msg == "import" then
        ns.ImportAuctionator()
    elseif msg == "shuffle" then
        ns.ToggleShuffleTracker()
    elseif msg == "step" then
        ns.ShuffleStep()
    elseif msg == "macro" then
        ns.PrintShuffleMacro()
    elseif msg == "plan" then
        ns.PrintPlan()
    elseif msg == "shuffledebug" then
        ns.ToggleShuffleDebug()
    elseif msg == "disenchant" then
        ns.DebugDisenchant()
    else
        say("usage: /shuffledetector scan | import | shuffle (show/hide the step tracker) | step | macro | plan | shuffledebug. Open a profession window to record its recipes.")
    end
end

SLASH_SHUFFLEDETECTORSTEP1 = "/shuffle"
SlashCmdList["SHUFFLEDETECTORSTEP"] = function() ns.ShuffleStep() end

