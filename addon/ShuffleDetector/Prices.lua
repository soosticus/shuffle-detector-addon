local ADDON, ns = ...

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function read(fn, ...)
    if type(fn) ~= "function" then return nil, "unavailable" end
    local ok, result = pcall(fn, ...)
    if not ok then
        ns.log("prices: provider error: " .. tostring(result))
        return nil, "provider-error"
    end
    return result
end

-- Callers must establish commodity identity separately; an item ID alone does not
-- establish gear variant semantics. No cache or callback contract is assumed.
function ns.AuctionatorQuote(itemID, kind)
    local quote = {
        status = "unknown", source = "Auctionator.API.v1", currency = "copper",
        item = itemID, identity = kind, depth = "unknown", exactness = "unknown",
        ageUnits = "unknown",
    }
    if not finite(itemID) or itemID < 1 or itemID > 10000000 or itemID ~= math.floor(itemID) then
        quote.reason = "invalid-item-id"
        return quote
    end
    if kind ~= "commodity" then
        quote.reason = "unsupported-item-identity"
        return quote
    end
    local version, build, interface
    if type(GetBuildInfo) == "function" then
        local ok, v, b, _, i = pcall(GetBuildInfo)
        if not ok then
            ns.log("prices: client identity error: " .. tostring(v))
            quote.reason = "client-identity-error"
            return quote
        end
        version, build, interface = v, b, i
    end
    quote.client = { version = version, build = build, interface = interface, project = WOW_PROJECT_ID }
    if version ~= "1.60.1" or (tostring(build) ~= "70862" and tostring(build) ~= "70888")
        or interface ~= 16001 or WOW_PROJECT_ID ~= 18 then
        quote.reason = "unsupported-client"
        return quote
    end
    local metadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local providerVersion, metadataError = read(metadata, "Auctionator", "Version")
    quote.providerVersion = providerVersion
    if metadataError then quote.reason = metadataError; return quote end
    if tostring(providerVersion) ~= "344" then
        quote.reason = "unsupported-provider-version"
        return quote
    end
    local api = type(Auctionator) == "table" and Auctionator.API
    api = type(api) == "table" and api.v1
    if type(api) ~= "table" then quote.reason = "unavailable"; return quote end
    quote.scope = ns.realmKey()
    local price, priceError = read(api.GetAuctionPriceByItemID, ADDON, itemID)
    if priceError then quote.reason = priceError; return quote end
    if price == nil then quote.reason = "no-price"; return quote end
    if not finite(price) or price <= 0 or price > 9007199254740991 or price ~= math.floor(price) then
        quote.reason = "invalid-price"
        ns.log("prices: invalid copper quote for item " .. itemID .. ": " .. tostring(price))
        return quote
    end
    quote.status, quote.unit = "estimate", price
    local age, ageError = read(api.GetAuctionAgeByItemID, ADDON, itemID)
    if finite(age) and age >= 0 then
        quote.rawAge = age
    elseif ageError then
        quote.ageReason = ageError
    elseif age ~= nil then
        quote.ageReason = "invalid-age"
        ns.log("prices: invalid raw age for item " .. itemID .. ": " .. tostring(age))
    end
    return quote
end
