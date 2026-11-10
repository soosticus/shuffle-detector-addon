local ADDON, ns = ...

local function report(text)
    ns.log("prices: " .. text)
end

local function probe(label, fn, ...)
    if type(fn) ~= "function" then
        report(label .. ": unavailable")
        return
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        report(label .. ": error: " .. tostring(value))
    else
        report(label .. ": " .. tostring(value) .. " (" .. type(value) .. ")")
    end
end

function ns.DebugPrices(arg)
    local ids = {}
    for token in (arg or ""):gmatch("%S+") do
        local id = tonumber(token)
        if not token:match("^%d+$") or not id or id < 1 or id > 10000000 or #ids >= 8 then
            ns.say("usage: /shuffledetector prices [up to 8 positive item IDs]")
            return
        end
        ids[#ids + 1] = id
    end
    if #ids == 0 then ids = { 2589, 2996, 7054 } end

    report("begin; read-only capability probe, not a verified price adapter")
    if type(GetBuildInfo) == "function" then
        local ok, version, build, _, interface = pcall(GetBuildInfo)
        if ok then
            report(("client=%s build=%s interface=%s project=%s"):format(
                tostring(version), tostring(build), tostring(interface), tostring(WOW_PROJECT_ID)))
        else
            report("GetBuildInfo error: " .. tostring(version))
        end
    else
        report("GetBuildInfo: unavailable")
    end
    report("realm/faction=" .. ns.realmKey())
    local addons = C_AddOns or {}
    local metadata = addons.GetAddOnMetadata or GetAddOnMetadata
    probe("ShuffleDetector version", metadata, ADDON, "Version")
    probe("Auctionator version", metadata, "Auctionator", "Version")
    probe("Auctionator loaded", addons.IsAddOnLoaded or IsAddOnLoaded, "Auctionator")

    local api = type(Auctionator) == "table" and Auctionator.API
    local v1 = type(api) == "table" and api.v1
    if type(v1) ~= "table" then
        report("Auctionator.API.v1: unavailable; no price conclusions can be drawn")
    else
        local names = {}
        for name, fn in pairs(v1) do
            if type(name) == "string" and type(fn) == "function" then names[#names + 1] = name end
        end
        table.sort(names)
        report("v1 functions: " .. table.concat(names, ", "))
        report("candidate calls use (addonName, itemID/link); verify signature and units before use")
        for _, id in ipairs(ids) do
            local label = "item " .. id
            probe(label .. " price by ID", v1.GetAuctionPriceByItemID, ADDON, id)
            probe(label .. " age (raw; units unverified)", v1.GetAuctionAgeByItemID, ADDON, id)
            local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            if type(info) == "function" then
                local ok, name, link, quality, ilvl = pcall(info, id)
                if not ok then
                    report(label .. " item info: error: " .. tostring(name))
                elseif type(link) == "string" then
                    report(("%s cached quality=%s ilvl=%s"):format(label, tostring(quality), tostring(ilvl)))
                    probe(label .. " price by link", v1.GetAuctionPriceByItemLink, ADDON, link)
                else
                    report(label .. " link comparison: item not cached")
                end
            else
                report(label .. " item info: unavailable")
            end
        end
    end
    report("nil/zero/errors are not free items; age, stock depth and variant semantics remain unverified")
    report("end")
    ns.say("Price diagnostic saved. /shuffledetector log 80 shows results; compare before/after an Auctionator scan.")
end
