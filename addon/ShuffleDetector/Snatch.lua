local _, ns = ...

local MAX_TARGET, POLL_SECONDS = 100000, 3
local panel, rows, statusText, pollButton
local running, ahOpen, pending, search, offer
local nextSearch, cursor, ownCall = 0, 0, false
local lastCast
local restored
local collectingUntil
local snapshots = {}
local seen = {}
local refresh
local populate

local function integer(n, min, max)
    return type(n) == "number" and n == n and n >= min and n <= max and n == math.floor(n)
end

local function message(text)
    if statusText then statusText:SetText(text) end
    ns.log("snatch: " .. text)
end

local function invoke(name, ...)
    local api = C_AuctionHouse
    if not api or type(api[name]) ~= "function" then
        message("Unavailable auction API: " .. name)
        return false
    end
    ownCall = true
    local ok, err = pcall(api[name], ...)
    ownCall = false
    if not ok then message(name .. " failed: " .. tostring(err)) end
    return ok
end

local function plan()
    local p = ns.plan
    if type(p) ~= "table" or p.version ~= 1 or not p.spell or not p.item
        or type(p.reagents) ~= "table" or #p.reagents == 0 then return end
    if not integer(p.makes or 1, 1, MAX_TARGET) then return end
    for _, r in ipairs(p.reagents) do
        if not integer(r.item, 1, 10000000) or not integer(r.qty, 1, MAX_TARGET) then return end
        if r.raw and (type(r.raw) ~= "table" or not integer(r.raw.item, 1, 10000000)
            or r.raw.item == r.item or not integer(r.raw.qty, 1, MAX_TARGET)) then return end
    end
    return p
end

local function identity(p)
    local parts = { tostring(p.spell), tostring(p.item), tostring(p.makes or 1) }
    for _, r in ipairs(p.reagents) do parts[#parts + 1] = r.item .. ":" .. r.qty end
    return table.concat(parts, "/")
end

local function count(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    return fn and fn(id, false) or 0
end

local function itemName(id)
    local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    return (fn and fn(id)) or ("Item " .. id)
end

local function money(n)
    return ("%dg %ds %dc"):format(math.floor(n / 10000), math.floor(n / 100) % 100, n % 100)
end

local function parseMoney(text)
    text = text:lower():gsub("%s", "")
    if text:match("^%d+$") then
        local n = tonumber(text)
        if integer(n, 0, 100000000000) then return n end
        return
    end
    local total, seen = 0, {}
    while text ~= "" do
        local digits, unit, rest = text:match("^(%d+)([gsc])(.*)$")
        if not digits or seen[unit] then return end
        seen[unit] = true
        total = total + tonumber(digits) * ({ g = 10000, s = 100, c = 1 })[unit]
        text = rest
    end
    if next(seen) and integer(total, 0, 100000000000) then return total end
end
ns.SnatchParseMoney = parseMoney

local function state()
    local p = plan()
    if not p then return end
    local key = UnitGUID("player")
    if not key then return end
    AHSnapshotDB.snatcher = AHSnapshotDB.snatcher or {}
    local s = AHSnapshotDB.snatcher[key]
    if not s then
        s = { prices = {}, awaiting = {}, bags = {}, target = 0, completed = 0 }
        AHSnapshotDB.snatcher[key] = s
    end
    local signature = identity(p)
    if s.recipe ~= signature then
        if ns.BatchStatsClose and not ns.BatchStatsClose(s) then return end
        s.recipe, s.target, s.completed = signature, 0, 0
    end
    if not restored then
        restored = true
        if s.inFlight then
            pending = s.inFlight
            pending.kind = "uncertain"
            if pending.vendor then
                pending.at = GetTime()
                message("Unconfirmed vendor purchase restored. Checking bags.")
            else
                message("Unconfirmed purchase restored. Check bags and mail, then resolve it.")
            end
        end
    end
    if ns.BatchStatsEnsure then ns.BatchStatsEnsure(p, s) end
    return s, p
end

function ns.PrepareShufflePlanChange()
    local s = state()
    if pending or (s and s.inFlight) then
        return nil, "Resolve the pending purchase before changing the active shuffle."
    end
    if s and ns.BatchStatsClose and not ns.BatchStatsClose(s) then
        return nil, "Confirm or resolve the pending sale before changing the active shuffle."
    end
    if s then
        s.recipe, s.target, s.completed, s.statsId = nil, 0, 0, nil
    end
    return true
end

function ns.SetSnatchTarget(target)
    if not integer(target, 1, MAX_TARGET) then
        return nil, "The batch target must be 1 to 100000 finished items."
    end
    local s = state()
    if not s then return nil, "No valid active shuffle is loaded." end
    if pending or s.inFlight then
        return nil, "Resolve the pending purchase before changing the batch target."
    end
    s.target, s.completed = target, 0
    if ns.BatchStatsEnsure then ns.BatchStatsEnsure(ns.plan, s) end
    if refresh then refresh() end
    return true
end

local function syncBags(s)
    for id, qty in pairs(s.awaiting) do
        local now = count(id)
        local received = collectingUntil and GetTime() <= collectingUntil
            and math.max(0, now - (s.bags[id] or now)) or 0
        s.awaiting[id] = math.max(0, qty - received)
        s.bags[id] = now
    end
end

local function refinement(id)
    local character = ns.charKey and (AHSnapshotDB.characters or {})[ns.charKey()]
    for _, profession in pairs(character and character.professions or {}) do
        for _, recipe in ipairs(profession.recipes or {}) do
            local reagents = recipe.reagents
            if recipe.item == id and type(reagents) == "table" and #reagents == 1 then
                local raw, makes = reagents[1], recipe.makes or 1
                if integer(raw.item, 1, 10000000) and raw.item ~= id
                    and integer(raw.qty, 1, MAX_TARGET) and makes == 1
                    and type(recipe.name) == "string" and integer(recipe.spell, 1, 10000000) then
                    return { item = raw.item, qty = raw.qty, recipe = recipe.name, spell = recipe.spell }
                end
            end
        end
    end
end

function ns.SnatchNeeds()
    local s, p = state()
    if not s then return {} end
    syncBags(s)
    local crafts = math.max(0, math.ceil(s.target / (p.makes or 1)) - s.completed)
    local needs, byItem = {}, {}
    for _, r in ipairs(p.reagents) do
        if not byItem[r.item] then
            local row = { item = r.item, required = 0 }
            byItem[r.item] = row
            needs[#needs + 1] = row
        end
        byItem[r.item].required = byItem[r.item].required + crafts * r.qty
        byItem[r.item].rawHint = r.raw
    end
    for _, r in ipairs(needs) do
        r.bags, r.awaiting = count(r.item), s.awaiting[r.item] or 0
        local reserved = s.inFlight and s.inFlight.item == r.item and s.inFlight.qty or 0
        r.missing = math.max(0, r.required - r.bags - r.awaiting - reserved)
        r.cap = s.prices[r.item] or 0
    end
    local rawUses = {}
    for _, r in ipairs(needs) do
        r.raw = refinement(r.item)
        if r.rawHint and (not r.raw or r.raw.item ~= r.rawHint.item or r.raw.qty ~= r.rawHint.qty) then
            r.note, r.raw = "Open this character's profession window to verify the raw recipe.", nil
        end
        if r.raw then rawUses[r.raw.item] = (rawUses[r.raw.item] or 0) + 1 end
    end
    local directCount = #needs
    for i = 1, directCount do
        local r = needs[i]
        if r.raw and (byItem[r.raw.item] or rawUses[r.raw.item] > 1) then
            r.note, r.raw = "Shared raw material: buy the intermediate directly.", nil
        end
        if r.raw then
            local raw = r.raw
            r.cap = (s.prices[raw.item] or 0) * raw.qty
            local child = { item = raw.item, parent = r.item, per = raw.qty, required = r.missing * raw.qty,
                bags = count(raw.item), awaiting = s.awaiting[raw.item] or 0, cap = s.prices[raw.item] or 0 }
            local reserved = s.inFlight and s.inFlight.item == raw.item and s.inFlight.qty or 0
            local held = child.bags + child.awaiting + reserved
            child.missing = math.max(0, child.required - held)
            child.remainder = held % raw.qty
            r.missing = math.ceil(child.missing / raw.qty)
            r.toCraft = math.min(child.required / raw.qty, math.floor(child.bags / raw.qty))
            needs[#needs + 1] = child
        end
    end
    return needs
end

local function need(id)
    for _, r in ipairs(ns.SnatchNeeds()) do if r.item == id then return r end end
end

function ns.SnatchTargetReached()
    local s, p = state()
    return s and s.target > 0 and s.completed >= math.ceil(s.target / (p.makes or 1))
end

function ns.SnatchCraftsRemaining()
    local s, p = state()
    if s and s.target > 0 then
        return math.max(0, math.ceil(s.target / (p.makes or 1)) - s.completed)
    end
end

function ns.NextSnatchRefinement(id)
    local s = state()
    if not s or s.target == 0 or ns.SnatchTargetReached() then return end
    local r = need(id)
    if r and r.raw and r.toCraft > 0 then
        local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local stack = info and select(8, info(id))
        local quantity = C_TradeSkillUI and C_TradeSkillUI.CraftRecipe
            and type(stack) == "number" and stack > 1 and r.raw.qty > 1 and r.toCraft or 1
        return { spell = r.raw.spell, recipe = r.raw.recipe,
            quantity = quantity,
            label = ("Make %d x %s from %s"):format(quantity, r.raw.recipe, itemName(r.raw.item)) }
    end
end

function ns.SnatchCraftCompleted(spell, cast)
    local s, p = state()
    if not s or s.target == 0 or spell ~= p.spell then return end
    if cast and cast == lastCast then return end
    lastCast = cast
    syncBags(s)
    s.completed = s.completed + 1
    if ns.BatchStatsCraft then ns.BatchStatsCraft(s, p) end
    offer = nil
    if refresh then refresh() end
end

local function clearQuote()
    if pending and (pending.kind == "quote" or pending.kind == "quoted") then
        invoke("CancelCommoditiesPurchase")
        pending = nil
    end
end

local function stop(text)
    running, search, offer = false, nil, nil
    snapshots = {}
    clearQuote()
    if pollButton then pollButton:SetText("Start AH polling") end
    if text then message(text) end
end

local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        if pending and (pending.kind == "buyingCommodity" or pending.kind == "buyingItem") then
            pending.kind = "uncertain"
        end
        stop("Error: " .. tostring(err) .. ". Check bags/mail before retrying.")
        ns.say("snatcher error: " .. tostring(err))
    end
end

local function recordPurchase(id, qty)
    local s = state()
    if not s then return end
    syncBags(s)
    s.awaiting[id] = (s.awaiting[id] or 0) + qty
    s.bags[id] = count(id)
    message(("Bought %d x %s; collect it from mail."):format(qty, itemName(id)))
end

local function reservePurchase()
    local s = state()
    pending.batch = s.statsId
    s.inFlight = pending
    pending.at = GetTime()
end

-- Vendor goods land in the bags at once, so the bag count settles the outcome.
local function settleVendor()
    if not (pending and pending.vendor) then return end
    local p, s = pending, state()
    if count(p.item) >= p.before + p.qty then
        if ns.BatchStatsPurchase then ns.BatchStatsPurchase(p) end
        message("Vendor purchase received.")
    else
        message(("Vendor purchase of %d x %s did not arrive; nothing was charged."):format(p.qty, itemName(p.item)))
    end
    if s then s.inFlight = nil end
    pending = nil
end

local function finishPurchase()
    local s = state()
    local p = pending
    s.inFlight, pending = nil, nil
    if ns.BatchStatsPurchase then ns.BatchStatsPurchase(p) end
    recordPurchase(p.item, p.qty)
end

local function equivalent(o, r)
    if r.parent then return math.floor((o.qty + r.remainder) / r.per) end
    return o.qty
end

local function completeQuantity(qty, r)
    if not r.parent then return qty end
    return math.max(0, math.floor((qty + r.remainder) / r.per) * r.per - r.remainder)
end

local function merchantOffer(id)
    if not (MerchantFrame and MerchantFrame:IsShown() and GetMerchantNumItems
        and GetMerchantItemLink and BuyMerchantItem) then return end
    local r = need(id)
    if not r or r.missing == 0 or r.cap == 0 then return end
    local best
    for i = 1, GetMerchantNumItems() do
        local link = GetMerchantItemLink(i)
        if link and tonumber(link:match("item:(%d+)")) == id then
            local price, bundle, stock, extended, purchasable
            if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
                local info = C_MerchantFrame.GetItemInfo(i)
                if info then
                    price, bundle, stock, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
                    purchasable = info.isPurchasable
                end
            elseif GetMerchantItemInfo then
                local _, _, p, q, n, _, canBuy, ext = GetMerchantItemInfo(i)
                price, bundle, stock, extended = p, q, n, ext
                purchasable = canBuy
            end
            if purchasable and price and bundle and bundle > 0 and not extended and stock
                and price <= r.cap * bundle and (stock == -1 or stock >= bundle) then
                local qty = math.floor(r.missing / bundle) * bundle
                local max = GetMerchantItemMaxStack and GetMerchantItemMaxStack(i) or bundle
                qty = math.min(qty, math.floor(max / bundle) * bundle)
                local capacity = ns.BagOutputCapacity and ns.BagOutputCapacity(id)
                if capacity then qty = math.min(qty, math.floor(capacity / bundle) * bundle) end
                if stock ~= -1 then qty = math.min(qty, math.floor(stock / bundle) * bundle) end
                qty = math.min(qty, math.floor(GetMoney() / price) * bundle)
                while qty > 0 and qty ~= completeQuantity(qty, r) do qty = qty - bundle end
                local total = qty / bundle * price
                local units = equivalent({ qty = qty }, r)
                if qty > 0 and total <= GetMoney() and (not best or total / units < best.total / best.units) then
                    best = { slot = i, item = id, qty = qty, total = total, units = units }
                end
            end
        end
    end
    return best
end

local function prefer(a, b)
    if not a then return b end
    if not b then return a end
    return b.total / b.units < a.total / a.units and b or a
end

local function vendorChoice(id)
    local r = need(id)
    if not r then return end
    local parent = r.parent or id
    local best
    for _, row in ipairs(ns.SnatchNeeds()) do
        if row.item == parent or row.parent == parent then
            local candidate = merchantOffer(row.item)
            if candidate then
                candidate.units = equivalent(candidate, row)
                if candidate.units > 0 then best = prefer(best, candidate) end
            end
        end
    end
    return best
end

function ns.SnatchBuyVendor(id)
    if pending or InCombatLockdown() then message("Finish the current purchase and leave combat first."); return end
    local o = vendorChoice(id)
    if not o or o.item ~= id then message("No cheapest vendor bundle for this row within your limits."); return end
    stop()
    pending = { kind = "vendor", vendor = true, item = id, before = count(id), qty = o.qty, total = o.total }
    reservePurchase()
    local ok, err = pcall(BuyMerchantItem, o.slot, o.qty)
    if not ok then
        pending.kind = "uncertain"
        message("Vendor purchase failed: " .. tostring(err) .. ". Check bags and resolve it.")
    else
        message("Waiting for vendor bag update.")
    end
    if refresh then refresh() end
end

local function results(id, key, commodity)
    local r = need(id)
    if not r or r.cap == 0 or r.missing == 0 then return end
    local api = C_AuctionHouse
    if commodity then
        local n = api.GetNumCommoditySearchResults(id)
        local list = {}
        for i = 1, n do
            local v = api.GetCommoditySearchResultInfo(id, i)
            if v and v.quantity > 0 then
                if v.containsOwnerItem or v.containsAccountItem then return end
                list[#list + 1] = v
            end
        end
        table.sort(list, function(a, b) return a.unitPrice < b.unitPrice end)
        -- Buy what the limit and current gold allow rather than nothing when the whole batch is unaffordable.
        local qty, total, gold = 0, 0, GetMoney()
        for _, v in ipairs(list) do
            if v.unitPrice > r.cap then break end
            local take = math.min(v.quantity, r.missing - qty, math.floor((gold - total) / v.unitPrice))
            if take <= 0 then break end
            qty, total = qty + take, total + take * v.unitPrice
            if qty == r.missing then break end
        end
        local complete = completeQuantity(qty, r)
        if complete ~= qty then
            qty, total = complete, 0
            local remaining = qty
            for _, v in ipairs(list) do
                local take = math.min(v.quantity, remaining)
                total, remaining = total + take * v.unitPrice, remaining - take
                if remaining == 0 then break end
            end
        end
        if qty > 0 and total <= GetMoney() then
            local candidate = { kind = "commodity", item = id, key = key, qty = qty, total = total, at = GetTime() }
            candidate.units = equivalent(candidate, r)
            return candidate
        end
    else
        local best
        for i = 1, api.GetNumItemSearchResults(key) do
            local v = api.GetItemSearchResultInfo(key, i)
            if v and v.itemKey.itemID == id and not v.containsOwnerItem and not v.containsAccountItem
                and v.buyoutAmount and v.buyoutAmount > 0 and v.quantity > 0 and v.quantity <= r.missing
                and v.quantity == completeQuantity(v.quantity, r)
                and v.buyoutAmount <= r.cap * v.quantity and v.buyoutAmount <= GetMoney() then
                local candidate = { kind = "item", item = id, key = key, qty = v.quantity,
                    total = v.buyoutAmount, auction = v.auctionID, at = GetTime() }
                candidate.units = equivalent(candidate, r)
                best = prefer(best, candidate)
            end
        end
        return best
    end
end

-- What the last search for an item found, so a poll that buys nothing can say why.
local function observe(id, key, commodity)
    local r, api = need(id), C_AuctionHouse
    if not r then return end
    local low, own = nil, false
    if commodity then
        for i = 1, api.GetNumCommoditySearchResults(id) do
            local v = api.GetCommoditySearchResultInfo(id, i)
            if v and v.quantity > 0 then
                if v.containsOwnerItem or v.containsAccountItem then own = true end
                if not low or v.unitPrice < low then low = v.unitPrice end
            end
        end
    else
        for i = 1, api.GetNumItemSearchResults(key) do
            local v = api.GetItemSearchResultInfo(key, i)
            if v and v.buyoutAmount and v.buyoutAmount > 0 and v.quantity > 0 then
                local unit = v.buyoutAmount / v.quantity
                if not low or unit < low then low = unit end
            end
        end
    end
    local text
    if low and low <= r.cap and GetMoney() < low then
        text = ("%s: not enough gold to buy one at %s"):format(itemName(id), money(math.floor(low + 0.5)))
    elseif own then
        text = ("%s: your own listing is in the results; cancel it to buy"):format(itemName(id))
    elseif not low then
        text = ("%s: none listed"):format(itemName(id))
    else
        text = ("%s: cheapest %s, limit %s"):format(itemName(id), money(math.floor(low + 0.5)), money(r.cap))
    end
    if not seen[id] or seen[id].text ~= text then ns.log("snatch poll: " .. text) end
    seen[id] = { text = text, at = GetTime() }
end

local function ahChoice(id)
    local r = need(id)
    if not r then return end
    local parent, best = r.parent or id, nil
    for _, row in ipairs(ns.SnatchNeeds()) do
        if (row.item == parent or row.parent == parent) and row.missing > 0 and row.cap > 0 then
            local snapshot = snapshots[row.item]
            if not snapshot or GetTime() - snapshot.at > 10 then return end
            local candidate = results(row.item, snapshot.key, snapshot.commodity)
            if candidate then
                candidate.at = snapshot.at
                best = prefer(best, candidate)
            end
        end
    end
    return best
end

local function quotePreferred(purchase)
    local r = need(purchase.item)
    if not r or purchase.qty ~= completeQuantity(purchase.qty, r) then return false end
    local units = equivalent(purchase, r)
    local parent = r.parent or r.item
    for _, row in ipairs(ns.SnatchNeeds()) do
        if row.item ~= r.item and (row.item == parent or row.parent == parent)
            and row.missing > 0 and row.cap > 0 then
            local snapshot = snapshots[row.item]
            if not snapshot or GetTime() - snapshot.at > 10 then return false end
            local alternative = results(row.item, snapshot.key, snapshot.commodity)
            if alternative and alternative.total / alternative.units < purchase.total / units then return false end
        end
    end
    return units > 0
end

function ns.SnatchPoll()
    if not running or not ahOpen or pending or offer or InCombatLockdown() or GetTime() < nextSearch then return end
    if search then
        if GetTime() - search.at > 15 then stop("AH search timed out. Restart polling to retry.") end
        return
    end
    local api = C_AuctionHouse
    for _, name in ipairs({ "IsThrottledMessageSystemReady", "MakeItemKey", "GetItemKeyInfo", "SendSearchQuery",
        "GetNumCommoditySearchResults", "GetCommoditySearchResultInfo", "GetNumItemSearchResults",
        "GetItemSearchResultInfo", "GetQuoteDurationRemaining", "StartCommoditiesPurchase",
        "ConfirmCommoditiesPurchase", "CancelCommoditiesPurchase", "PlaceBid" }) do
        if not api or type(api[name]) ~= "function" then stop("Unavailable auction API: " .. name); return end
    end
    if not api.IsThrottledMessageSystemReady() then
        if not seen.throttled then ns.log("snatch poll: waiting for the AH to accept searches") end
        seen.throttled = true
        return
    end
    seen.throttled = nil
    local needs = ns.SnatchNeeds()
    for _ = 1, #needs do
        cursor = cursor % #needs + 1
        local r = needs[cursor]
        if r.missing > 0 and r.cap > 0 then
            local key = api.MakeItemKey(r.item)
            local info = api.GetItemKeyInfo(key)
            if not info then
                nextSearch = GetTime() + POLL_SECONDS
                message("Waiting for item information: " .. itemName(r.item))
                return
            end
            search = { item = r.item, key = key, commodity = info.isCommodity, at = GetTime() }
            nextSearch = GetTime() + POLL_SECONDS
            if not invoke("SendSearchQuery", key, {}, true) then search = nil; stop() end
            return
        end
    end
    stop("No materials need buying at an enabled price. Check bags and awaiting mail.")
end

function ns.SnatchBuyAH()
    if not ahOpen or InCombatLockdown() then message("Open the AH and leave combat first."); return end
    if pending then
        if pending.kind ~= "quoted" then message("Waiting for purchase confirmation."); return end
        local r = need(pending.item)
        local duration = C_AuctionHouse.GetQuoteDurationRemaining()
        if not r or pending.qty > r.missing or pending.total > r.cap * pending.qty
            or pending.total > GetMoney() or duration <= 0 or GetTime() - pending.at > 10
            or not quotePreferred(pending) then
            clearQuote()
            message("Quote expired, limits changed or another source is cheaper. Poll for a new offer.")
            return
        end
        pending.kind = "buyingCommodity"
        reservePurchase()
        if not invoke("ConfirmCommoditiesPurchase", pending.item, pending.qty) then
            pending.kind = "uncertain"
            stop("Purchase failed. Check mail before restarting.")
        end
        if refresh then refresh() end
        return
    end
    local o = offer
    if not o or GetTime() - o.at > 10 then
        offer = nil
        message("Offer expired. Wait for a fresh search.")
        return
    end
    local live = ahChoice(o.item)
    if not live or live.item ~= o.item or live.qty ~= o.qty or live.total ~= o.total or live.auction ~= o.auction then
        offer = nil
        message("Listing changed. Wait for a fresh search.")
        return
    end
    offer = nil
    pending = o
    if o.kind == "commodity" then
        pending.kind, pending.at = "quote", GetTime()
        if not invoke("StartCommoditiesPurchase", o.item, o.qty) then pending = nil; stop() end
    else
        pending.kind = "buyingItem"
        reservePurchase()
        if not invoke("PlaceBid", o.auction, o.total) then
            pending.kind = "uncertain"
            stop("Purchase failed. Check mail before restarting.")
        end
    end
    if refresh then refresh() end
end

function ns.NextSnatchPurchase()
    local s = state()
    if not s or s.target == 0 then return end
    if pending then
        if pending.kind == "quoted" then
            return { kind = "purchase", blocking = true, action = "ah", item = pending.item, qty = pending.qty, total = pending.total,
                label = ("Confirm %d x %s for %s"):format(pending.qty, itemName(pending.item), money(pending.total)) }
        end
        return { kind = "idle", blocking = true, label = pending.kind == "uncertain"
            and "Resolve uncertain purchase in the snatcher panel" or "Waiting for purchase confirmation or bag update" }
    end
    if ns.SnatchTargetReached() then return end
    if MerchantFrame and MerchantFrame:IsShown() then
        for _, r in ipairs(ns.SnatchNeeds()) do
            local o = vendorChoice(r.item)
            if o then
                return { kind = "purchase", action = "vendor", item = o.item, qty = o.qty, total = o.total,
                    label = ("Buy %d x %s from vendor for %s"):format(o.qty, itemName(o.item), money(o.total)) }
            end
        end
    elseif ahOpen then
        if offer and GetTime() - offer.at <= 10 then
            return { kind = "purchase", action = "ah", item = offer.item, qty = offer.qty, total = offer.total,
                label = ("%s %d x %s for %s"):format(offer.kind == "commodity" and "Quote" or "Buy",
                    offer.qty, itemName(offer.item), money(offer.total)) }
        end
        local notes = {}
        for _, r in ipairs(ns.SnatchNeeds()) do
            if r.missing > 0 and r.cap > 0 and seen[r.item] and GetTime() - seen[r.item].at <= 30 then
                notes[#notes + 1] = seen[r.item].text
            end
        end
        for _, r in ipairs(ns.SnatchNeeds()) do
            if r.missing > 0 and r.cap > 0 then
                local label = running and "Waiting for AH offers within saved limits" or "Start AH polling with saved limits"
                if running and seen.throttled then label = label .. " (AH busy)" end
                if #notes > 0 then label = label .. "\n" .. table.concat(notes, "\n") end
                return { kind = running and "idle" or "purchase", action = "poll", label = label }
            end
        end
        for _, r in ipairs(ns.SnatchNeeds()) do
            if r.awaiting > 0 then return { kind = "idle", label = "Collect purchased materials from mail" } end
        end
    end
end

function ns.SnatchPurchaseStep(expected)
    guarded(function()
        if InCombatLockdown() then message("Leave combat before purchasing."); return end
        local current = ns.NextSnatchPurchase()
        if not current or current.kind ~= "purchase" or current.action ~= expected.action
            or current.item ~= expected.item or current.qty ~= expected.qty or current.total ~= expected.total then
            message("Purchase step changed. Press again to review the next step.")
            return
        end
        if current.action == "vendor" then ns.SnatchBuyVendor(current.item)
        elseif current.action == "ah" then ns.SnatchBuyAH()
        else
            running = true
            ns.SnatchPoll()
            if refresh then refresh() end
        end
    end)
end

local function onEvent(_, event, a, b)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        stop("AH closed. Polling stopped.")
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
        local id = type(a) == "table" and a.itemID or a
        if search and id == search.item then
            snapshots[id] = search
            observe(id, search.key, search.commodity)
            offer = ahChoice(id)
            search = nil
            if offer then
                local r = need(offer.item)
                local suffix = r.parent and ("; craft " .. offer.units .. " x " .. itemName(r.parent)) or ""
                message(("AH offer: %d x %s for %s%s"):format(offer.qty, itemName(offer.item), money(offer.total), suffix))
            end
        end
    elseif event == "COMMODITY_PRICE_UPDATED" and pending and (pending.kind == "quote" or pending.kind == "quoted") then
        local r = need(pending.item)
        if not r or pending.qty > r.missing or a > r.cap or b > r.cap * pending.qty
            or b > pending.total or b > GetMoney() then
            clearQuote()
            message("Quote rose or exceeded your limits; cancelled.")
        else
            pending.kind, pending.total, pending.at = "quoted", b, GetTime()
            message("Quote ready: " .. money(b) .. ". Click Confirm AH purchase.")
        end
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" or event == "COMMODITY_PURCHASE_FAILED" then
        if pending and (pending.kind == "quote" or pending.kind == "quoted" or pending.kind == "buyingCommodity") then
            clearQuote()
            local s = state()
            if s then s.inFlight = nil end
            pending = nil
            stop("Commodity purchase unavailable or failed. Check mail before retrying.")
        end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and pending and pending.kind == "buyingCommodity" then
        finishPurchase()
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and pending and pending.kind == "buyingItem" and a == pending.auction then
        finishPurchase()
    elseif event == "BAG_UPDATE_DELAYED" then
        if pending and pending.vendor and (pending.kind == "uncertain"
            or count(pending.item) >= pending.before + pending.qty) then
            settleVendor()
        end
        local s = state()
        if s then syncBags(s) end
    elseif event == "UI_ERROR_MESSAGE" and pending then
        if pending.vendor then
            pending.kind, pending.at = "uncertain", GetTime()
            message("Game purchase error: " .. tostring(b) .. ". Checking bags.")
        else
            message("Game purchase error: " .. tostring(b) .. ". Check bags/mail; purchases remain blocked.")
        end
        running = false
    elseif event == "PLAYER_REGEN_DISABLED" then
        stop("In combat. Polling stopped.")
    end
    if refresh then refresh() end
end
ns.SnatchOnEvent = onEvent

function ns.SnatchResolvePurchase(received)
    if not pending or pending.kind ~= "uncertain" then return end
    if pending.vendor then
        settleVendor()
        if refresh then refresh() end
        return
    end
    local p, s = pending, state()
    s.inFlight, pending = nil, nil
    if received and ns.BatchStatsPurchase then ns.BatchStatsPurchase(p) end
    if received and not p.vendor then recordPurchase(p.item, p.qty) end
    stop("Purchase reconciled. Review quantities before restarting.")
    if refresh then refresh() end
end

local function button(parent, text, width, x, y, fn)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(text)
    b:SetScript("OnClick", function(...) guarded(fn, ...) end)
    return b
end

local function edit(parent, width, x, y)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 22)
    e:SetPoint("TOPLEFT", x, y)
    e:SetAutoFocus(false)
    e:SetMaxLetters(32)
    return e
end

local function text(parent, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    return fs
end

local function saveInputs()
    if pending then message("Finish the pending purchase before changing limits."); return false end
    local target = tonumber(panel.target:GetText())
    if not integer(target, 0, MAX_TARGET) then message("Target must be a whole number from 0 to 100000."); return false end
    local prices = {}
    for _, row in ipairs(rows) do
        if not row.derived then
            local price = parseMoney(row.price:GetText())
            if not price then message("Invalid price for " .. itemName(row.item) .. ". Use 1g 20s 5c, or copper."); return false end
            prices[row.item] = price
        end
    end
    local s = state()
    if not s then message("Send a recipe with item, spell and reagents from the companion first."); return false end
    stop()
    s.target = target
    for id, price in pairs(prices) do s.prices[id] = price end
    message("Limits saved. Zero disables purchasing; target is total newly crafted items for this batch.")
    refresh()
    return true
end

function ns.RefreshBatchStatisticsDisplay()
    if panel and panel.statistics then
        local s = state()
        panel.statistics:SetText(s and ns.BatchStatsText(s) or "")
    end
end

refresh = function()
    if ns.RefreshBatchAnalytics then ns.RefreshBatchAnalytics() end
    if ns.RefreshShuffleTracker then ns.RefreshShuffleTracker() end
    if not panel then return end
    local s, p = state()
    if not s then
        panel.title:SetText("Send a shuffle from the companion to configure a batch")
        panel.progress:SetText("")
        if panel.statistics then panel.statistics:SetText("") end
        for _, row in ipairs(rows) do row.frame:Hide() end
        rows = {}
        panel.content:SetHeight(1)
        panel.buy:SetEnabled(false)
        pollButton:SetEnabled(false)
        return
    end
    pollButton:SetEnabled(true)
    panel.title:SetText("Batch: " .. p.recipe)
    panel.progress:SetText(("%d / %d crafts completed; %d items per craft"):format(s.completed,
        math.ceil(s.target / (p.makes or 1)), p.makes or 1))
    if panel.statistics then panel.statistics:SetText(ns.BatchStatsText(s)) end
    local needs = ns.SnatchNeeds()
    if #rows ~= #needs then populate(); return end
    for i, r in ipairs(needs) do
        local row = rows[i]
        if row then
            if row.item ~= r.item or row.derived ~= (r.raw ~= nil) then populate(); return end
            if row.derived then
                row.price:SetText(("Derived: %s (%d x raw cap)"):format(money(r.cap), r.raw.qty))
            end
            local note = r.parent and ("For %d unfilled %s"):format(r.required / r.per, itemName(r.parent))
                or r.raw and ("Craft " .. r.toCraft .. " from bag stock via " .. r.raw.recipe) or r.note or ""
            row.info:SetText(("%s\n%s %d | bags %d | awaiting %d | buy %d\n%s"):format(
                itemName(r.item), r.parent and "Raw need" or "Need",
                r.required, r.bags, r.awaiting, r.missing, note))
        end
    end
    panel.buy:SetText(pending and pending.kind == "quoted" and "Confirm AH purchase" or "Buy AH offer")
    panel.buy:SetEnabled(ahOpen and not InCombatLockdown() and
        ((pending and pending.kind == "quoted") or (not pending and offer ~= nil)) or false)
    pollButton:SetText(running and "Stop AH polling" or "Start AH polling")
end

ns.RefreshSnatcher = function()
    if refresh then refresh() end
end

populate = function()
    for _, row in ipairs(rows) do row.frame:Hide() end
    rows = {}
    local s = state()
    panel.target:SetText(tostring(s and s.target or 0))
    for i, r in ipairs(ns.SnatchNeeds()) do
        local f = CreateFrame("Frame", nil, panel.content)
        f:SetSize(400, 60)
        f:SetPoint("TOPLEFT", 0, -(i - 1) * 60)
        local row = { frame = f, item = r.item, derived = r.raw ~= nil }
        row.info = text(f, 0, 0, 220)
        if row.derived then
            row.price = text(f, 266, -5, 130)
            row.price:SetText(("Derived: %s (%d x raw cap)"):format(money(r.cap), r.raw.qty))
        else
            row.price = edit(f, 110, 266, -5)
            row.price:SetText(money(r.cap))
        end
        rows[#rows + 1] = row
    end
    panel.content:SetHeight(math.max(1, #rows * 60))
    refresh()
end

local function createPanel()
    if not panel then
        panel = CreateFrame("Frame", "ShuffleDetectorSnatcher", UIParent, "BasicFrameTemplateWithInset")
        if panel.TitleText then panel.TitleText:SetText("ShuffleDetector") end
        local compactHeight = ns.BatchStatsText and 600 or 510
        panel:SetSize(450, compactHeight)
        panel:SetPoint("CENTER")
        panel:SetMovable(true)
        panel:SetClampedToScreen(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            local point, _, relPoint, x, y = self:GetPoint()
            AHSnapshotDB.shuffleTracker = { point = point, relPoint = relPoint, x = x, y = y }
        end)
        panel.title = text(panel, 12, -30, 420)
        text(panel, 12, -52, 170):SetText("Finished-item target (0 = off)")
        panel.target = edit(panel, 80, 200, -48)
        button(panel, "Save limits", 110, 310, -48, saveInputs)
        panel.progress = text(panel, 12, -78, 420)
        panel.controls = CreateFrame("Frame", nil, panel)
        panel.controls:SetSize(450, 95)
        panel.controls:SetPoint("TOPLEFT", 0, -compactHeight)
        panel.controls:Hide()
        button(panel, "More controls", 130, 300, -(compactHeight - 30), function(self)
            local show = not panel.controls:IsShown()
            panel.controls:SetShown(show)
            panel:SetHeight(compactHeight + (show and 95 or 0))
            self:SetText(show and "Less controls" or "More controls")
        end)
        if ns.BatchStatsText then
            panel.statistics = text(panel, 12, -485, 420)
            button(panel.controls, "Analytics", 105, 12, -56, ns.ToggleBatchAnalytics)
        end
        text(panel, 12, -202, 420):SetText("Maximum price per unit: g/s/c or copper; 0 = do not buy")
        local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -224)
        scroll:SetSize(402, 210)
        panel.content = CreateFrame("Frame", nil, scroll)
        panel.content:SetSize(400, 1)
        scroll:SetScrollChild(panel.content)
        pollButton = button(panel.controls, "Start AH polling", 130, 12, 0, function()
            if running then stop("Polling stopped.")
            elseif saveInputs() then
                if ahOpen then running = true; ns.SnatchPoll()
                else message("Open the auction house first.") end
            end
            refresh()
        end)
        panel.buy = button(panel.controls, "Buy AH offer", 160, 155, 0, ns.SnatchBuyAH)
        button(panel.controls, "New batch", 105, 325, 0, function()
            if pending then message("Pending purchase: check bags/mail before starting a new batch."); return end
            local s = state()
            if s then
                if ns.BatchStatsClose and not ns.BatchStatsClose(s) then return end
                s.completed = 0
                stop("New batch started. Awaiting mail is still reserved.")
                refresh()
            end
        end)
        button(panel.controls, "Resolve uncertain purchase", 200, 12, -28, function()
            if not pending or pending.kind ~= "uncertain" then
                message("No uncertain purchase. Wait for confirmation or reload after checking bags/mail.")
                return
            end
            StaticPopupDialogs["SHUFFLEDETECTOR_SNATCH_RESOLVE"] = {
                text = pending.vendor and ("Settle the vendor purchase of %d x %s from your current bag count?"):format(
                    pending.qty, itemName(pending.item))
                    or ("Check bags AND mail for %d x %s. Is this purchase still in mail? Choose No only after confirming it is already in your bags or the purchase failed."):format(
                        pending.qty, itemName(pending.item)),
                button1 = pending.vendor and "Check bags" or "Yes, in mail",
                button2 = pending.vendor and "Cancel" or "No, checked",
                button3 = not pending.vendor and "Cancel" or nil,
                OnAccept = function() ns.SnatchResolvePurchase(true) end,
                OnCancel = function(_, _, reason)
                    if reason == "clicked" and pending and not pending.vendor then ns.SnatchResolvePurchase(false) end
                end,
                timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
            }
            StaticPopup_Show("SHUFFLEDETECTOR_SNATCH_RESOLVE")
        end)
        button(panel.controls, "Reconcile collected mail", 205, 225, -28, function()
            if pending then message("Resolve the pending purchase first."); return end
            StaticPopupDialogs["SHUFFLEDETECTOR_SNATCH_MAIL"] = {
                text = "Only clear awaiting quantities after ALL purchased materials have been collected from mail. Clear the awaiting-mail ledger?",
                button1 = "All collected", button2 = "Cancel",
                OnAccept = function()
                    local s = state()
                    if s and not pending then
                        s.awaiting, s.bags = {}, {}
                        stop("Awaiting-mail ledger cleared. Review quantities before restarting.")
                        refresh()
                    end
                end,
                timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
            }
            StaticPopup_Show("SHUFFLEDETECTOR_SNATCH_MAIL")
        end)
        statusText = text(panel, 12, -440, 420)
        statusText:SetHeight(36)
        rows = {}
        panel:Hide()
        panel:SetScript("OnShow", function() AHSnapshotDB.shuffleTrackerShown = true end)
        panel:SetScript("OnHide", function()
            AHSnapshotDB.shuffleTrackerShown = false
            stop("Shuffle window hidden. Polling stopped.")
        end)
        if ns.AttachShuffleTracker then panel.shuffleStatus = ns.AttachShuffleTracker(panel) end
    end
end

function ns.ToggleSnatcher()
    createPanel()
    if panel:IsShown() then panel:Hide()
    else populate(); panel:Show(); message("Save batch limits, then use your shuffle macro for the next action.") end
end

function ns.RestoreShuffleWindow()
    createPanel()
    local position = AHSnapshotDB.shuffleTracker
    if position and position.point then
        panel:ClearAllPoints()
        panel:SetPoint(position.point, UIParent, position.relPoint or position.point, position.x or 0, position.y or 0)
    end
    populate()
    if AHSnapshotDB.shuffleTrackerShown ~= false and ns.plan and ns.plan.version == 1 and ns.plan.recipe then
        panel:Show()
    end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_SEARCH_RESULTS_UPDATED",
    "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
    "BAG_UPDATE_DELAYED", "MERCHANT_SHOW", "MERCHANT_UPDATE", "MERCHANT_CLOSED", "UI_ERROR_MESSAGE",
    "PLAYER_REGEN_DISABLED" }) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(...) guarded(onEvent, ...) end)
local elapsed = 0
local function update(_, delta)
    elapsed = elapsed + delta
    if elapsed < 0.5 then return end
    elapsed = 0
    if offer and GetTime() - offer.at > 10 then offer = nil; refresh() end
    if pending and (pending.kind == "quote" or pending.kind == "quoted") and GetTime() - pending.at > 10 then
        clearQuote()
        message("Commodity quote expired.")
        refresh()
    end
    if pending and pending.vendor and (pending.kind == "uncertain" and GetTime() - pending.at > 1
        or GetTime() - pending.at > 15) then
        settleVendor()
        refresh()
    end
    if pending and (pending.kind == "buyingCommodity" or pending.kind == "buyingItem")
        and GetTime() - pending.at > 15 then
        pending.kind = "uncertain"
        stop("Purchase confirmation timed out. Check bags/mail, then resolve the uncertain purchase.")
        refresh()
    end
    ns.SnatchPoll()
end
events:SetScript("OnUpdate", function(...) guarded(update, ...) end)

-- Commodity events have no item ID. Other addons must not replace a quote we might confirm.
if C_AuctionHouse and hooksecurefunc then
    for _, name in ipairs({ "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "CancelCommoditiesPurchase",
        "SendSearchQuery", "SendSellSearchQuery", "PlaceBid" }) do
        if type(C_AuctionHouse[name]) == "function" then
            hooksecurefunc(C_AuctionHouse, name, function()
                if ownCall then return end
                if pending then
                    running = false
                    message("Another AH action interrupted this purchase. Check mail; reload before retrying.")
                    if pending.kind == "quote" or pending.kind == "quoted" then pending = nil
                    elseif pending.kind ~= "vendor" then pending.kind = "uncertain" end
                end

                search, offer = nil, nil
                if name == "SendSearchQuery" or name == "SendSellSearchQuery" then
                    stop("Another addon searched the AH. Polling stopped to avoid interference.")
                end
                if refresh then refresh() end
            end)
        end
    end
end

-- Bag gains from crafting, trades or vendors must not consume the awaiting-mail ledger.
if hooksecurefunc then
    for _, name in ipairs({ "TakeInboxItem", "AutoLootMailItem" }) do
        if type(_G[name]) == "function" then
            hooksecurefunc(name, function() collectingUntil = GetTime() + 5 end)
        end
    end
end
