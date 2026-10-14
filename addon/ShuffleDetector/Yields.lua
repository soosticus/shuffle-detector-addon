-- Expected disenchant yields from Auctionator's in-game disenchant table (no site or web data involved).
-- Auctionator.Constants.DisenchantingProbability[itemClass][quality] is a list of entries
-- { lowItemLevel, highItemLevel, pct, count, itemID, pct, count, itemID, ... }. For each recorded armor or
-- weapon the expected count of each result is the sum of pct/100*count; the result is written to
-- AHSnapshotDB.deyields[itemID] = { quality, ilvl, yields = { { item, avg }, ... } } for the companion.

local ADDON, ns = ...

local function table_for(class, quality)
    local a = Auctionator
    local c = a and a.Constants and a.Constants.DisenchantingProbability
    local byClass = c and c[class]
    return byClass and byClass[quality]
end

local function expected(entry)
    local sums, order = {}, {}
    for i = 3, #entry - 2, 3 do
        local pct, count, id = entry[i], entry[i + 1], entry[i + 2]
        if type(pct) == "number" and type(count) == "number" and type(id) == "number" then
            if not sums[id] then
                sums[id] = 0
                order[#order + 1] = id
            end
            sums[id] = sums[id] + pct / 100 * count
        end
    end
    table.sort(order)
    local out = {}
    for _, id in ipairs(order) do out[#out + 1] = { item = id, avg = sums[id] } end
    return out
end

local function itemLevel(id)
    local ok, ilvl = pcall(function()
        return C_Item and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(id)
    end)
    if ok and type(ilvl) == "number" and ilvl > 0 then return ilvl end
end

local function itemClassQuality(id)
    local ok, _, _, rarity, _, _, _, _, _, _, _, _, class = pcall(C_Item and C_Item.GetItemInfo or GetItemInfo, id)
    if ok then return class, rarity end
end

function ns.RecordYields(quiet)
    local function report(msg)
        ns.log("yields: " .. msg)
        if not quiet then ns.say(msg) end
    end
    local armor = Enum and Enum.ItemClass and Enum.ItemClass.Armor or 4
    local weapon = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
    if not (Auctionator and Auctionator.Constants and Auctionator.Constants.DisenchantingProbability) then
        report("Auctionator's disenchant table is not available (is Auctionator installed and loaded?)")
        return
    end
    local out, found, considered = {}, 0, 0
    for id in pairs(AHSnapshotDB.items or {}) do
        local class, quality = itemClassQuality(id)
        if (class == armor or class == weapon) and type(quality) == "number" then
            local list = table_for(class, quality)
            local ilvl = list and itemLevel(id)
            if list then
                considered = considered + 1
                for _, entry in ipairs(list) do
                    if type(entry) == "table" and ilvl and ilvl >= entry[1] and ilvl <= entry[2] then
                        local y = expected(entry)
                        if #y > 0 then
                            out[id] = { quality = quality, ilvl = ilvl, yields = y }
                            found = found + 1
                        end
                        break
                    end
                end
            end
        end
    end
    AHSnapshotDB.deyields = out
    report(("recorded Auctionator disenchant yields for %d of %d recorded armor and weapon items"):format(found, considered))
end
