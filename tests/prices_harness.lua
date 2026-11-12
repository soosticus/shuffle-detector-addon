local function eq(actual, expected, message)
    assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local logs, prices, ages, build, provider, fail = {}, { [2589] = 20 }, { [2589] = 2 }, "70888", "344", false
local ns = {
    log = function(text) logs[#logs + 1] = text end,
    realmKey = function() return "TestRealm-Alliance" end,
}
GetBuildInfo = function() return "1.60.1", build, "date", 16001 end
WOW_PROJECT_ID = 18
C_AddOns = { GetAddOnMetadata = function(addon, key)
    eq(addon, "Auctionator"); eq(key, "Version"); return provider
end }
GetItemInfo = function() error("ID quotes must not request cached item information") end
C_Item = { GetItemInfo = GetItemInfo }
Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(addon, item)
        eq(addon, "ShuffleDetector")
        if fail then error("test failure") end
        return prices[item]
    end,
    GetAuctionAgeByItemID = function(addon, item)
        eq(addon, "ShuffleDetector")
        return ages[item]
    end,
} } }
assert(loadfile("addon/ShuffleDetector/Prices.lua"))("ShuffleDetector", ns)
local function quote(item, kind) return ns.AuctionatorQuote(item or 2589, kind or "commodity") end
local q = quote()
eq(q.status, "estimate")
eq(q.unit, 20)
eq(q.currency, "copper")
eq(q.rawAge, 2)
eq(q.ageUnits, "unknown")
eq(q.depth, "unknown")
eq(q.exactness, "unknown")
eq(q.scope, "TestRealm-Alliance")
prices[2589], ages[2589] = 26, 0
q = quote()
eq(q.unit, 26, "on-demand reads see changed prices without callback or reload")
eq(q.rawAge, 0)
eq(quote(7054).reason, "no-price")
eq(quote(7054).unit, nil, "missing prices are not free")
for _, bad in ipairs({ 0, -1, 0 / 0, math.huge, 1.5, "20" }) do
    prices[2589] = bad
    eq(quote().reason, "invalid-price")
    eq(quote().unit, nil)
end
prices[2589] = 26
eq(quote(2589, "gear").reason, "unsupported-item-identity")
eq(ns.AuctionatorQuote(2589).reason, "unsupported-item-identity")
eq(quote(-1).reason, "invalid-item-id")
fail = true
eq(quote().reason, "provider-error")
assert(logs[#logs]:find("test failure", 1, true))
fail = false
local api = Auctionator.API.v1
Auctionator.API.v1 = nil
eq(quote().reason, "unavailable")
Auctionator.API.v1 = api
for _, version in ipairs({ "345", 346, " \t347\r\n", "400.1", "343", "unexpected" }) do
    provider = version
    q = quote()
    eq(q.unit, 26, "any Auctionator version with the v1 API is used: " .. tostring(version))
    eq(q.status, "estimate")
end
provider = " \t347\r\n"
eq(ns.PriceProviderStatus().normalizedVersion, "347", "the detected version is recorded for diagnosis")
provider = nil
eq(quote().unit, 26, "missing version metadata does not block prices")
eq(ns.PriceProviderStatus().normalizedVersion, "unknown version")
build = "99999"
eq(quote().unit, 26, "no client build gate")
eq(ns.PriceProviderStatus().client.build, "99999", "client build is recorded")
build, provider = "70888", "346"
prices[2589] = nil
eq(quote().reason, "no-price", "a missing price is not free")
prices[2589] = 0
eq(quote().reason, "invalid-price", "an invalid price is not free")
prices[2589] = 26
Auctionator.API.v1 = nil
eq(quote().reason, "unavailable")
assert(ns.PriceProviderStatus().detail:find("346", 1, true), "unavailable API names the installed version")
local logCount = #logs
quote()
eq(#logs, logCount, "an unavailable API is logged once, not once per recipe")
Auctionator.API.v1 = api
eq(quote().unit, 26)
local metadata = C_AddOns.GetAddOnMetadata
C_AddOns = nil
GetAddOnMetadata = metadata
eq(quote().unit, 26, "legacy metadata API uses the same contract")
C_AddOns = { GetAddOnMetadata = metadata }
api.GetAuctionAgeByItemID = nil
q = quote()
eq(q.unit, 26, "unknown age does not erase the price estimate")
eq(q.rawAge, nil)
eq(q.ageReason, "unavailable")
api.GetAuctionAgeByItemID = function() error("age failure") end
eq(quote().ageReason, "provider-error")
assert(logs[#logs]:find("age failure", 1, true))
print("price provider checks passed")
