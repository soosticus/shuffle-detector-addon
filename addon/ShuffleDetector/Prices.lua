local ADDON, ns = ...
local lastRejection
local TESTED_PROVIDER = 344
-- Session-only: a newer, untested Auctionator release is never used by default.
local allowUntested = false

function ns.SetUntestedProviderAllowed(allowed)
    allowUntested = allowed and true or false
end

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

function ns.PriceProviderStatus()
    local status = { source = "Auctionator.API.v1", currency = "copper" }
    local version, build, interface
    if type(GetBuildInfo) == "function" then
        local ok, v, b, _, i = pcall(GetBuildInfo)
        if not ok then
            ns.log("prices: client identity error: " .. tostring(v))
            status.reason = "client-identity-error"
            return status
        end
        version, build, interface = v, b, i
    end
    status.client = { version = version, build = build, interface = interface, project = WOW_PROJECT_ID }
    if version ~= "1.60.1" or (tostring(build) ~= "70862" and tostring(build) ~= "70888")
        or interface ~= 16001 or WOW_PROJECT_ID ~= 18 then
        status.reason = "unsupported-client"
        status.detail = ("Detected %s build %s / interface %s / project %s; tested: Forever 1.60.1 builds 70862/70888, interface 16001, project 18."):format(
            tostring(version), tostring(build), tostring(interface), tostring(WOW_PROJECT_ID))
        return status
    end
    local metadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local providerVersion, metadataError = read(metadata, "Auctionator", "Version")
    status.providerVersion = providerVersion
    if metadataError then status.reason = metadataError; return status end
    local normalized = (type(providerVersion) == "string" or type(providerVersion) == "number")
        and tostring(providerVersion):match("^%s*(.-)%s*$")
    local release = normalized and normalized:match("^%d+$") and tonumber(normalized)
    if release ~= TESTED_PROVIDER then
        if release and release > TESTED_PROVIDER then
            status.reason = "untested-provider-version"
            status.untestedVersion = normalized
            status.detail = ("Auctionator %s is newer than the tested %d; its prices are off unless you choose to preview them, labeled untested."):format(
                normalized, TESTED_PROVIDER)
        else
            status.reason = "unsupported-provider-version"
            status.detail = ("Detected Auctionator Version %q (%s); tested: %d. Run /shuffledetector prices to capture the installed API."):format(
                tostring(providerVersion), type(providerVersion), TESTED_PROVIDER)
        end
        if lastRejection ~= status.detail then
            ns.log("prices: " .. status.detail)
            lastRejection = status.detail
        end
        if status.reason ~= "untested-provider-version" or not allowUntested then return status end
        status.provisional = true
    end
    status.normalizedVersion = normalized
    local api = type(Auctionator) == "table" and Auctionator.API
    api = type(api) == "table" and api.v1
    if type(api) ~= "table" or type(api.GetAuctionPriceByItemID) ~= "function" then
        status.reason = "unavailable"
        return status
    end
    if not status.provisional then lastRejection = nil end
    status.reason = nil
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
    quote.provisional = provider.provisional
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
