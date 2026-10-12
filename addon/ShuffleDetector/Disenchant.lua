-- Disenchant: logs what a Disenchant cast returns (the item disenchanted, plus what dropped), so the
-- companion can show real average yields and sample counts instead of hand-written guesses.
-- SpellTargetItem(bag, slot) is how a bag click completes an item-targeted spell; hooking it is the
-- usual way addons such as Enchantrix see what item a cast like Disenchant targeted. The loot window
-- that opens shortly after a successful cast is treated as its result.
local ADDON, ns = ...

local DISENCHANT_ID = 13262
local RESULT_WINDOW = 3 -- seconds: how soon after targeting/casting a loot window still counts as the result
local MAX_SAMPLES = 500 -- cap AHSnapshotDB.disenchants so it cannot grow without bound

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
    local _, _, quality, ilvl = fn(id)
    return quality, ilvl
end

-- The item last passed to SpellTargetItem, kept until a Disenchant cast succeeds or this goes stale.
local targeted
hooksecurefunc("SpellTargetItem", function(bag, slot)
    local id = itemIdFromLink(containerItemLink(bag, slot))
    if id then targeted = { item = id, at = GetTime() } end
end)

-- The disenchanted item, waiting for the loot window that should follow the successful cast.
local pending

local ev = CreateFrame("Frame")
ev:RegisterEvent("LOOT_OPENED")
pcall(ev.RegisterUnitEvent, ev, "UNIT_SPELLCAST_SUCCEEDED", "player")
ev:SetScript("OnEvent", function(_, event, _, _, spellID)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if spellID ~= DISENCHANT_ID then return end
        if not (targeted and GetTime() - targeted.at < RESULT_WINDOW) then return end
        local quality, ilvl = itemInfo(targeted.item)
        pending = { item = targeted.item, quality = quality, ilvl = ilvl, at = GetTime(), when = time() }
        targeted = nil
    elseif event == "LOOT_OPENED" then
        if not (pending and GetTime() - pending.at < RESULT_WINDOW) then return end
        local loot = {}
        for i = 1, GetNumLootItems() do
            local id = itemIdFromLink(GetLootSlotLink(i))
            if id then
                local _, _, qty = GetLootSlotInfo(i)
                loot[#loot + 1] = { item = id, qty = qty or 1 }
                ns.RecordItem(id)
            end
        end
        AHSnapshotDB.disenchants = AHSnapshotDB.disenchants or {}
        local log = AHSnapshotDB.disenchants
        log[#log + 1] = { item = pending.item, quality = pending.quality, ilvl = pending.ilvl,
                          loot = loot, time = pending.when }
        while #log > MAX_SAMPLES do table.remove(log, 1) end
        ns.RecordItem(pending.item)
        pending = nil
    end
end)
