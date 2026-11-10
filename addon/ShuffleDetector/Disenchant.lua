local ADDON, ns = ...

local DISENCHANT_ID = 13262
local TARGET_WINDOW, RESULT_WINDOW = 3, 3
local targeted, casting, pending

local function itemIdFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function containerItemLink(bag, slot)
    local fn = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
    return fn and fn(bag, slot)
end

local function itemInfo(id)
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not fn then return end
    local _, _, quality, ilvl, _, _, _, _, _, _, _, class = fn(id)
    return quality, ilvl, class
end

local function count(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    return fn and fn(id, false)
end

local function discard(reason)
    if pending then ns.log("disenchant sample skipped: " .. reason) end
    pending = nil
end

function ns.NoteDisenchantTarget(bag, slot, method)
    local id = itemIdFromLink(containerItemLink(bag, slot))
    if casting and casting.target then
        if id ~= casting.target.item then ns.log("disenchant: ignored new target during active cast") end
        return
    end
    local before = id and count(id)
    if not (id and type(before) == "number" and before > 0) then
        ns.log("disenchant target unavailable; no sample will be inferred")
        targeted = nil
        if casting then casting.target = nil end
        return
    end
    local quality, ilvl, class = itemInfo(id)
    targeted = { item = id, before = before, quality = quality, ilvl = ilvl, class = class,
                 at = GetTime(), method = method }
    if casting then casting.target = targeted end
end

if type(SpellTargetItem) == "function" then
    hooksecurefunc("SpellTargetItem", function(bag, slot)
        ns.NoteDisenchantTarget(bag, slot, "SpellTargetItem")
    end)
else
    ns.log("disenchant: SpellTargetItem unavailable; manual target capture disabled")
end

local function capture(token)
    if pending ~= token or not token.open then return end
    if GetTime() - token.at >= RESULT_WINDOW then discard("loot data timed out"); return end
    if not (GetNumLootItems and GetLootSlotLink and GetLootSlotInfo) then
        discard("loot APIs unavailable")
        return
    end
    local after = count(token.target.item)
    if type(after) ~= "number" or token.target.before - after ~= 1 then return end
    local n = GetNumLootItems()
    if not n or n < 1 then return end
    local loot = {}
    for i = 1, n do
        local id = itemIdFromLink(GetLootSlotLink(i))
        local _, _, qty = GetLootSlotInfo(i)
        if not (id and type(qty) == "number" and qty > 0 and qty == math.floor(qty)) then return end
        loot[#loot + 1] = { item = id, qty = qty }
    end
    local target = token.target
    local client = {}
    if GetBuildInfo then
        local ok, version, build, _, interface = pcall(GetBuildInfo)
        if ok then
            client.version, client.build, client.interface = version, build, interface
        else
            ns.log("disenchant client identity unavailable: " .. tostring(version))
        end
    end
    client.project = WOW_PROJECT_ID
    client.realm = ns.realmKey and ns.realmKey()
    local sample = { item = target.item, quality = target.quality, ilvl = target.ilvl, class = target.class,
                     loot = loot, time = token.when, complete = true,
                     capture = { version = 2, target = target.method, client = client } }
    pending = nil
    ns.RecordDisenchantSample(sample)
    ns.RecordItem(target.item)
    for _, material in ipairs(loot) do ns.RecordItem(material.item) end
end

local function retry(token)
    if pending ~= token then return end
    capture(token)
    if pending == token then
        if GetTime() - token.at >= RESULT_WINDOW then
            discard("no complete loot and matching item consumption")
        else
            C_Timer.After(0.1, function() retry(token) end)
        end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_CLOSED")
ev:RegisterEvent("LOOT_SLOT_CLEARED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED",
                         "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
    local ok, err = pcall(ev.RegisterUnitEvent, ev, event, "player")
    if not ok then ns.log("disenchant event unavailable: " .. event .. ": " .. tostring(err)) end
end
ev:SetScript("OnEvent", function(_, event, unit, castID, spellID)
    if event:find("^UNIT_SPELLCAST_") then
        if unit ~= "player" or spellID ~= DISENCHANT_ID then return end
        if event == "UNIT_SPELLCAST_START" then
            discard("another disenchant started before loot was captured")
            local target = targeted and GetTime() - targeted.at < TARGET_WINDOW and targeted or nil
            casting = { id = castID, target = target }
            targeted = nil
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            if not casting or casting.id ~= castID then
                ns.log("disenchant success without matching cast start; sample not inferred")
                return
            end
            local target = casting.target
            casting, targeted = nil, nil
            if not target then ns.log("disenchant success without captured target"); return end
            if ns.BatchStatsDisenchanted then ns.BatchStatsDisenchanted(target.item) end
            pending = { target = target, at = GetTime(), when = time() }
            retry(pending)
        elseif casting and casting.id == castID then
            casting, targeted = nil, nil
        end
    elseif event == "LOOT_OPENED" then
        if pending then pending.open = true; capture(pending) end
    elseif event == "LOOT_CLOSED" or event == "LOOT_SLOT_CLEARED" then
        -- Once a slot is gone, a later partial window must not look like the entire result.
        discard("loot cleared or closed before the full result was available")
    elseif event == "BAG_UPDATE_DELAYED" and pending then
        capture(pending)
    end
end)
