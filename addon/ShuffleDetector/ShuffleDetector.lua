-- ShuffleDetector core: shared namespace, profession/recipe snapshot, slash commands.
-- Prices are not collected here: the companion reads Auctionator's saved price database directly.
-- Data is written by the game to WTF/Account/<acct>/SavedVariables/ShuffleDetector.lua

local ADDON, ns = ...
AHSnapshotDB = AHSnapshotDB or {}
AHSnapshotDB.version = 1

local frame = CreateFrame("Frame")

function ns.say(msg)
    print("|cff33ff99" .. ADDON .. "|r: " .. tostring(msg))
end
local say = ns.say

-- Quiet diagnostics (button clicks, casts, game errors) go to a ring buffer in AHSnapshotDB.log instead of
-- the chat window. Read it with /shuffledetector log; /shuffledetector log echo also prints new lines live.
local LOG_MAX = 300
AHSnapshotDB.shuffleDebug = nil -- replaced by log and logEcho
AHSnapshotDB.scans, AHSnapshotDB.timing = nil, nil -- the built-in AH scan was removed; prices come from Auctionator

function ns.log(msg)
    local log = AHSnapshotDB.log
    if not log then
        log = {}
        AHSnapshotDB.log = log
    end
    log[#log + 1] = date("%H:%M:%S") .. " " .. tostring(msg)
    if #log > LOG_MAX then table.remove(log, 1) end
    if AHSnapshotDB.logEcho then print("|cff888888" .. ADDON .. " log|r: " .. tostring(msg)) end
end

function ns.ShowLog(arg)
    local log = AHSnapshotDB.log or {}
    if arg == "clear" then
        AHSnapshotDB.log = {}
        say("log cleared")
    elseif arg == "echo" then
        AHSnapshotDB.logEcho = not AHSnapshotDB.logEcho
        say("live log output " .. (AHSnapshotDB.logEcho and "on" or "off"))
    else
        local n = math.min(tonumber(arg) or 20, #log)
        say(("log: last %d of %d lines (/shuffledetector log <n> | clear | echo)"):format(n, #log))
        for i = #log - n + 1, #log do print("  " .. log[i]) end
    end
end

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
    local name, quality, ilvl, sell, class, _
    if C_Item and C_Item.GetItemInfo then
        name, _, quality, ilvl, _, _, _, _, _, _, sell, class = C_Item.GetItemInfo(id)
    elseif GetItemInfo then
        name, _, quality, ilvl, _, _, _, _, _, _, sell, class = GetItemInfo(id)
    end
    if name then
        awaiting[id] = nil
        AHSnapshotDB.items = AHSnapshotDB.items or {}
        -- class, quality and ilvl let the companion look up disenchant yields (companion/deyields.py)
        AHSnapshotDB.items[id] = { name = name, sell = sell or 0, class = class, quality = quality, ilvl = ilvl }
    elseif not awaiting[id] then
        awaiting[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
end
ns.RecordItem = recordItem

-- Entries recorded by older versions have no class/quality/ilvl; record them again (the game has them cached).
function ns.RefreshItemDetails(quiet)
    local n = 0
    for id, e in pairs(AHSnapshotDB.items or {}) do
        if type(e) == "table" and e.class == nil then
            recordItem(id)
            n = n + 1
        end
    end
    if not quiet then say(("refreshed class and item level for %d recorded items"):format(n)) end
end

-- Ask the game for every item in ns.wantedItems (ItemList.lua, written by the companion) that is not recorded
-- yet. Requests go out in small batches; answers arrive on GET_ITEM_INFO_RECEIVED and are recorded by recordItem.
local BATCH, BATCH_DELAY = 40, 1
function ns.LoadWantedItems(quiet)
    -- Ids the game never answered for on an earlier run are skipped at login; /shuffledetector items retries them.
    local unanswered = AHSnapshotDB.unanswered or {}
    local list = ns.wantedItems
    if type(list) ~= "table" or #list == 0 then
        if not quiet then say("no item list; send items from the companion app, then /reload") end
        return
    end
    local known = AHSnapshotDB.items or {}
    local todo = {}
    for _, id in ipairs(list) do
        if not known[id] and (not quiet or not unanswered[id]) then
            todo[#todo + 1] = id
            awaiting[id] = nil
        end
    end
    if #todo == 0 then
        if not quiet then say(("all %d listed items are already recorded"):format(#list)) end
        return
    end
    say(("requesting %d of %d listed items from the game"):format(#todo, #list))
    local i = 1
    local function step()
        for _ = 1, BATCH do
            if not todo[i] then break end
            recordItem(todo[i])
            i = i + 1
        end
        if todo[i] then
            C_Timer.After(BATCH_DELAY, step)
        else
            C_Timer.After(10, function()
                local got = 0
                local miss = AHSnapshotDB.unanswered or {}
                for _, id in ipairs(todo) do
                    if AHSnapshotDB.items and AHSnapshotDB.items[id] then
                        got = got + 1
                        miss[id] = nil
                    else
                        miss[id] = true
                    end
                end
                AHSnapshotDB.unanswered = miss
                say(("received %d of %d requested items (the rest are not items in this client)"):format(got, #todo))
            end)
        end
    end
    step()
end

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
    c.professions[""] = nil
    for name, p in pairs(profs) do
        local old = c.professions[name]
        p.recipes = old and old.recipes or {}
        p.available = old and old.available
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
    local recipes, available = {}, {}
    for _, id in ipairs(ids) do
        local info = T.GetRecipeInfo(id)
        if info and info.name and not info.isDummyRecipe then
            local reagents, item, makes = modernDetails(T, id)
            if not item and T.GetRecipeItemLink then
                local okLink, link = pcall(T.GetRecipeItemLink, id)
                item = okLink and itemIdFromLink(link) or nil
            end
            local entry = { name = info.name, spell = id, item = item,
                            makes = makes and makes > 1 and makes or nil,
                            reagents = reagents and #reagents > 0 and reagents or nil }
            if info.learned then
                recipes[#recipes + 1] = entry
            else
                -- Recipes in the window that the character has not learned: what to acquire later.
                entry.trivial = info.maxTrivialLevel
                if T.GetRecipeSourceText then
                    local okSrc, text = pcall(T.GetRecipeSourceText, id)
                    if okSrc and type(text) == "string" and text ~= "" then entry.source = text end
                end
                available[#available + 1] = entry
            end
        end
    end
    local pname, skill, max = base.professionName, base.skillLevel, base.maxSkillLevel
    -- The window's profession name can lag behind its recipe list; the recipe itself knows its profession.
    if T.GetProfessionInfoByRecipeID and recipes[1] then
        local okInfo, owner = pcall(T.GetProfessionInfoByRecipeID, recipes[1].spell)
        if okInfo and type(owner) == "table" and owner.professionName and owner.professionName ~= "" then
            if owner.professionName ~= pname then
                pname, skill, max = owner.professionName, owner.skillLevel or skill, owner.maxSkillLevel or max
            end
        end
    end
    return pname, skill, max, recipes, available
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
    local ok, name, rank, maxRank, recipes, available = pcall(readModern)
    if not (ok and name) then
        ok, name, rank, maxRank, recipes = pcall(readClassic)
    end
    if not (ok and name and name ~= "" and recipes) then return false end
    local c = snapshotSkills()
    local old = c.professions[name]
    -- A window that has not finished loading reports no learned recipes; keep what was saved before.
    if #recipes == 0 and old and old.recipes and #old.recipes > 0 then return false end
    -- The API can briefly report one profession's name with another's recipe list. A list identical to
    -- another profession's is such a stale read: skip it (a retry picks up the real list).
    local sig = {}
    for _, r in ipairs(recipes) do sig[#sig + 1] = r.name end
    sig = table.concat(sig, "|")
    for pname, p in pairs(c.professions) do
        if pname ~= name and p.recipes and #p.recipes > 0 then
            local other = {}
            for _, r in ipairs(p.recipes) do other[#other + 1] = r.name end
            if table.concat(other, "|") == sig then return false end
        end
    end
    c.professions[name] = { skill = rank, max = maxRank, recipes = recipes,
                            available = available and #available > 0 and available or nil }
    for _, list in ipairs({ recipes, available or {} }) do
        for _, r in ipairs(list) do
            recordItem(r.item)
            for _, x in ipairs(r.reagents or {}) do recordItem(x.item) end
        end
    end
    if not quiet then
        say(("saved %d %s recipes (skill %s/%s)%s"):format(#recipes, name, tostring(rank), tostring(maxRank),
            available and #available > 0 and (" and %d not yet learned"):format(#available) or ""))
    end
    return true
end

-- Opening a profession window does not always deliver a final list event, so retry for a few seconds.
local RETRY_DELAYS = { 0, 0.5, 1.5, 3, 6 }
local attempt = 0
local function snapshotWithRetry()
    attempt = attempt + 1
    local mine = attempt
    local function try(i)
        if mine ~= attempt then return end
        if snapshotRecipes() or not RETRY_DELAYS[i + 1] then return end
        C_Timer.After(RETRY_DELAYS[i + 1] - RETRY_DELAYS[i], function() try(i + 1) end)
    end
    try(1)
end

-- Vendor buy prices, per single item, as the merchant window shows them (gold only; item-cost
-- vendors are skipped). Reputation discounts are baked into the price the game shows. Only unlimited-stock
-- items count as a standing price; a limited-stock listing is dropped so it is not mistaken for one.
local function snapshotMerchant()
    if not (GetMerchantNumItems and GetMerchantItemLink) then return end
    local n = GetMerchantNumItems() or 0
    for i = 1, n do
        local price, qty, extended, stock
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local okInfo, info = pcall(C_MerchantFrame.GetItemInfo, i)
            if okInfo and type(info) == "table" then
                price, qty, extended, stock = info.price, info.stackCount, info.hasExtendedCost, info.numAvailable
            end
        end
        if price == nil and GetMerchantItemInfo then
            local _, _, p, q, n, _, _, ext = GetMerchantItemInfo(i)
            price, qty, extended, stock = p, q, ext, n
        end
        local id = itemIdFromLink(GetMerchantItemLink(i))
        if id and price and price > 0 and not extended then
            AHSnapshotDB.vendor = AHSnapshotDB.vendor or {}
            if stock == nil or stock == -1 then
                AHSnapshotDB.vendor[id] = math.floor(price / math.max(qty or 1, 1) + 0.5)
                recordItem(id)
            else
                AHSnapshotDB.vendor[id] = nil
            end
        end
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
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_UPDATE")
frame:SetScript("OnEvent", function(_, event, itemId)
    if event == "GET_ITEM_INFO_RECEIVED" then
        if awaiting[itemId] then recordItem(itemId) end
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
        pcall(snapshotMerchant)
    elseif event == "TRADE_SKILL_SHOW" then
        snapshotWithRetry()
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        scheduleSnapshot()
    else
        snapshotSkills()
        if event == "PLAYER_LOGIN" then
            C_Timer.After(5, function() ns.LoadWantedItems(true) end)
            C_Timer.After(25, function() ns.RefreshItemDetails(true) end)
        end
    end
end)

function ns.DebugRecipes()
    say(("GetProfessions=%s GetNumSkillLines=%s C_TradeSkillUI.GetAllRecipeIDs=%s GetNumTradeSkills=%s"):format(
        tostring(GetProfessions ~= nil), tostring(GetNumSkillLines ~= nil),
        tostring(C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs ~= nil), tostring(GetNumTradeSkills ~= nil)))
    local T = C_TradeSkillUI
    if T and T.GetBaseProfessionInfo then
        local base = T.GetBaseProfessionInfo()
        local ids = T.GetAllRecipeIDs and T.GetAllRecipeIDs() or {}
        local learned, first = 0, nil
        for _, id in ipairs(ids) do
            local info = T.GetRecipeInfo(id)
            if info and info.learned then learned = learned + 1 end
            first = first or info
        end
        say(("window: profession=%s skill=%s, %d recipe ids, %d learned"):format(
            tostring(base and base.professionName), tostring(base and base.skillLevel), #ids, learned))
        if T.GetProfessionInfoByRecipeID and ids[1] then
            local okInfo, owner = pcall(T.GetProfessionInfoByRecipeID, ids[1])
            say("  first recipe belongs to: " .. tostring(okInfo and type(owner) == "table" and owner.professionName or owner))
        end
        if first then
            local keys = {}
            for k, v in pairs(first) do keys[#keys + 1] = k .. "=" .. tostring(v) end
            say("  first recipe: " .. table.concat(keys, ", "))
        end
    end
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
    if msg == "recipes" then
        ns.DebugRecipes()
    elseif msg == "shuffle" then
        ns.ToggleShuffleTracker()
    elseif msg == "step" then
        ns.ShuffleStep()
    elseif msg == "macro" then
        ns.PrintShuffleMacro()
    elseif msg == "plan" then
        ns.PrintPlan()
    elseif msg == "log" or msg:find("^log ") then
        ns.ShowLog(msg:match("^log%s*(.-)%s*$"))
    elseif msg == "disenchant" then
        ns.DebugDisenchant()
    elseif msg == "items" then
        ns.LoadWantedItems()
    elseif msg == "yields" then
        ns.RefreshItemDetails()
    else
        say("usage: /shuffledetector items (request recipe item names and prices) | yields (re-record item class and level for disenchant yields) | shuffle (show/hide the step tracker) | step | macro | plan | log (hidden diagnostics: log <n> | clear | echo). Open a profession window to record its recipes.")
    end
end

SLASH_SHUFFLEDETECTORSTEP1 = "/shuffle"
SlashCmdList["SHUFFLEDETECTORSTEP"] = function() ns.ShuffleStep() end

