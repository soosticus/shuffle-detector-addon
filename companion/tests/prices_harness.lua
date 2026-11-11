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
provider = "345"
eq(quote().reason, "untested-provider-version", "a newer release is reported as untested")
eq(quote().unit, nil, "untested provider prices are off by default")
assert(quote().detail:find("345", 1, true), "show the actual detected version")
eq(ns.PriceProviderStatus().untestedVersion, "345")
local logCount = #logs
quote()
eq(#logs, logCount, "a rejected version is logged once, not once per recipe")
ns.SetUntestedProviderAllowed(true)
q = quote()
eq(q.unit, 26, "explicit opt-in previews untested prices")
eq(q.provisional, true, "opted-in quotes stay labeled untested")
eq(ns.PriceProviderStatus().provisional, true)
eq(#logs, logCount, "opting in does not repeat the rejection log")
provider = "343"
eq(quote().reason, "unsupported-provider-version", "opt-in never covers an older release")
provider = "345.1"
eq(quote().reason, "unsupported-provider-version", "opt-in never covers a non-release version string")
provider = "344"
eq(quote().provisional, nil, "the tested release is never labeled untested")
ns.SetUntestedProviderAllowed(false)
provider = "345"
eq(quote().unit, nil, "turning the preview off restores the gate")
provider = 344
eq(quote().unit, 26, "numeric metadata is supported")
provider = "344"
eq(quote().unit, 26, "string metadata is supported")
provider = " \t344\r\n"
eq(quote().unit, 26, "TOC whitespace is not a different Auctionator version")
provider = "344.1"
eq(quote().reason, "unsupported-provider-version", "do not broaden support to a different release")
provider = nil
eq(quote().reason, "unsupported-provider-version")
assert(quote().detail:find('"nil" (nil)', 1, true))
provider, build = "344", "99999"
eq(quote().reason, "unsupported-client")
build = "70862"
eq(quote().unit, 26, "baseline supported build shares confirmed copper contract")
build = "70888"
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
