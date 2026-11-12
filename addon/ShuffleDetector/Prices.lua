local ADDON, ns = ...
local lastRejection

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

-- No Auctionator or client version gate: addons update often, so any release exposing
-- the v1 price API is used. Versions are recorded so a future break can be diagnosed.
function ns.PriceProviderStatus()
    local status = { source = "Auctionator.API.v1", currency = "copper" }
    if type(GetBuildInfo) == "function" then
        local ok, version, build, _, interface = pcall(GetBuildInfo)
        if ok then
            status.client = { version = version, build = build, interface = interface, project = WOW_PROJECT_ID }
        end
    end
    local metadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local providerVersion = read(metadata, "Auctionator", "Version")
    status.providerVersion = providerVersion
    status.normalizedVersion = (type(providerVersion) == "string" or type(providerVersion) == "number")
        and tostring(providerVersion):match("^%s*(.-)%s*$") or "unknown version"
    local api = type(Auctionator) == "table" and Auctionator.API
    api = type(api) == "table" and api.v1
    if type(api) ~= "table" or type(api.GetAuctionPriceByItemID) ~= "function" then
        status.reason = "unavailable"
        status.detail = ("Auctionator %s does not expose Auctionator.API.v1.GetAuctionPriceByItemID; is it installed and enabled?"):format(
            status.normalizedVersion)
        if lastRejection ~= status.detail then
            ns.log("prices: " .. status.detail)
            lastRejection = status.detail
        end
        return status
    end
    lastRejection = nil
    status.ready = true
    return status
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
    local provider = ns.PriceProviderStatus()
    quote.client, quote.providerVersion = provider.client, provider.providerVersion
    if not provider.ready then
        quote.reason, quote.detail = provider.reason, provider.detail
        return quote
    end
    local api = Auctionator.API.v1
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
