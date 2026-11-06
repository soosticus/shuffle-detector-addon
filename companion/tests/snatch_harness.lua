local ns, bags, calls, now, balance, commodity, items, merchants, ready, frames
local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function frame()
    local f = { scripts = {}, shown = true }
    local noop = function() end
    for _, method in ipairs({ "SetSize", "SetPoint", "SetWidth", "SetHeight", "SetJustifyH", "SetMovable",
        "SetClampedToScreen", "EnableMouse", "RegisterForDrag", "SetAutoFocus", "SetMaxLetters",
        "SetScrollChild", "RegisterEvent", "RegisterUnitEvent", "StartMoving", "StopMovingOrSizing",
        "SetFrameStrata", "RegisterForClicks", "SetAllPoints", "SetColorTexture", "SetTextColor" }) do f[method] = noop end
    function f:SetScript(event, fn) self.scripts[event] = fn end
    function f:CreateFontString() return frame() end
    function f:CreateTexture() return frame() end
    function f:HookScript(event, fn) self.scripts[event] = fn end
    function f:SetAttribute(key, value) self[key] = value end
    function f:GetAttribute(key) return self[key] end
    function f:SetText(value) self.value = value end
    function f:GetText() return self.value end
    function f:SetEnabled(value) self.enabled = value end
    function f:IsShown() return self.shown end
    function f:Show() self.shown = true end
    function f:SetShown(value) self.shown = value end
    function f:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    return f
end

local function setup()
    bags, calls, now, balance, commodity, items, merchants, ready, frames = {}, {}, 0, 100000, {}, {}, {}, true, {}
    AHSnapshotDB = {}
    UnitGUID = function() return "char" end
    GetTime = function() return now end
    GetMoney = function() return balance end
    InCombatLockdown = function() return false end
    C_Item = {
        GetItemCount = function(id, bank) assert(not bank, "bank excluded"); return bags[id] or 0 end,
        GetItemInfo = function(id) return "Item " .. id end,
    }
    CreateFrame = function(_, name)
        local f = frame()
        if name then _G[name] = f end
        frames[#frames + 1] = f
        return f
    end
    UIParent = frame()
    MerchantFrame = frame()
    MerchantFrame.shown = false
    GetMerchantNumItems = function() return #merchants end
    GetMerchantItemLink = function(i) return "item:" .. merchants[i].id end
    GetMerchantItemMaxStack = function(i) return merchants[i].max or 20 end
    C_MerchantFrame = { GetItemInfo = function(i) return merchants[i] end }
    BuyMerchantItem = function(i, qty) calls[#calls + 1] = { "vendor", i, qty } end
    C_AuctionHouse = {
        IsThrottledMessageSystemReady = function() return ready end,
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { isCommodity = key.itemID ~= 2 } end,
        SendSearchQuery = function(key) calls[#calls + 1] = { "search", key.itemID } end,
        GetNumCommoditySearchResults = function(id) return #(commodity[id] or {}) end,
        GetCommoditySearchResultInfo = function(id, i) return commodity[id][i] end,
        GetNumItemSearchResults = function(key) return #(items[key.itemID] or {}) end,
        GetItemSearchResultInfo = function(key, i) return items[key.itemID][i] end,
        StartCommoditiesPurchase = function(id, qty) calls[#calls + 1] = { "quote", id, qty } end,
        ConfirmCommoditiesPurchase = function(id, qty) calls[#calls + 1] = { "confirm", id, qty } end,
        CancelCommoditiesPurchase = function() calls[#calls + 1] = { "cancel" } end,
        PlaceBid = function(id, price) calls[#calls + 1] = { "buyout", id, price } end,
        GetQuoteDurationRemaining = function() return 20 end,
    }
    TakeInboxItem = function() end
    AutoLootMailItem = function() end
    hooksecurefunc = function(tbl, name, callback)
        if type(tbl) == "string" then callback, name, tbl = name, tbl, _G end
        local original = tbl[name]
        tbl[name] = function(...)
            original(...)
            callback(...)
        end
    end
    ns = {
        plan = { version = 1, spell = 10, item = 20, recipe = "Test", reagents = { { item = 1, qty = 2 } } },
        log = function() end,
        say = function(text) error(text) end,
    }
    assert(loadfile("addon/ShuffleDetector/Snatch.lua"))("ShuffleDetector", ns)
    ns.SnatchNeeds()
    return AHSnapshotDB.snatcher.char
end

local function event(name, ...)
    ns.SnatchOnEvent(nil, name, ...)
end

local function click(label)
    for _, f in ipairs(frames) do
        if f.value == label and f.scripts.OnClick then f.scripts.OnClick(f); return end
    end
    error("Missing button: " .. label)
end

local function start(s)
    event("AUCTION_HOUSE_SHOW")
    ns.ToggleSnatcher()
    click("Start AH polling")
end

local function result(id)
    event(id == 2 and "ITEM_SEARCH_RESULTS_UPDATED" or "COMMODITY_SEARCH_RESULTS_UPDATED",
        id == 2 and C_AuctionHouse.MakeItemKey(id) or id)
end

local function advance(seconds)
    now = now + seconds
    for _, f in ipairs(frames) do if f.scripts.OnUpdate then f.scripts.OnUpdate(f, seconds) end end
end

local s = setup()
eq(ns.SnatchParseMoney("1g 20s 5c"), 12005)
eq(ns.SnatchParseMoney("123"), 123)
eq(ns.SnatchParseMoney(""), nil)
eq(ns.SnatchParseMoney("-1"), nil)
eq(ns.SnatchParseMoney("1g1g"), nil)
eq(ns.SnatchParseMoney("nan"), nil)
s.target, s.prices[1], bags[1] = 5, 100, 3
eq(ns.SnatchNeeds()[1].missing, 7, "subtract bags")
ns.plan.makes = 3
ns.SnatchNeeds()
s.target = 5
eq(ns.SnatchNeeds()[1].required, 4, "round up crafts")
ns.SnatchCraftCompleted(11, "wrong")
eq(s.completed, 0, "ignore another spell")
ns.SnatchCraftCompleted(10, "cast1")
ns.SnatchCraftCompleted(10, "cast1")
eq(s.completed, 1, "deduplicate cast")
ns.SnatchCraftCompleted(10, "cast2")
eq(ns.SnatchTargetReached(), true)
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 1 or 0 end,
    GetContainerItemLink = function() return bags[20] and "item:20" or nil end,
}
IsSpellKnown = function() return true end
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
eq(ns.NextShuffleStep().label, "Craft target reached", "macro stops at target")
bags[20] = 1
ns.plan.exit = "Disenchant"
eq(ns.NextShuffleStep().kind, "disenchant", "still processes exit after target")
ns.plan.exit = "Vendor"
MerchantFrame.shown = true
eq(ns.NextShuffleStep().kind, "sell", "still sells after target")
MerchantFrame.shown = false
assert(ns.NextShuffleStep().label:find("Open a vendor"), "vendor prompt after target")
ns.plan.exit = "Sell on AH"
assert(ns.NextShuffleStep().label:find("Post "), "AH prompt after target")
bags[20] = nil
ns.plan.spell = 99
ns.SnatchNeeds()
eq(s.target, 0, "new recipe requires explicit target")
eq(ns.NextShuffleStep().kind, "craft", "without a target original macro behavior remains")

s = setup()
s.target, s.prices[1] = 5, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 150, stackCount = 2, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
eq(calls[1][1], "vendor")
eq(calls[1][3], 10, "vendor requested quantity")
eq(s.inFlight.qty, 10, "vendor reservation survives reload")
ns.SnatchBuyVendor(1)
eq(#calls, 1, "wait for bags")
bags[1] = 10
event("BAG_UPDATE_DELAYED")
ns.SnatchBuyVendor(1)
eq(#calls, 1, "do not buy beyond target")
eq(s.inFlight, nil, "vendor receipt releases reservation")

s = setup()
s.target, s.prices[1] = 5, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 150, stackCount = 2, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
advance(16)
eq(s.inFlight.kind, "uncertain", "vendor timeout is not silent")
ns.SnatchResolvePurchase(true)
eq(s.inFlight, nil)
eq(s.awaiting[1], nil, "vendor reconciliation never creates a mail reservation")

s = setup()
s.target, s.prices[1] = 2, 50
MerchantFrame.shown = true
merchants = { { id = 1, price = 101, stackCount = 2, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
eq(#calls, 0, "vendor cap exact, not rounded")
merchants[1].price, merchants[1].hasExtendedCost = 50, true
ns.SnatchBuyVendor(1)
eq(#calls, 0, "no currency purchases")
merchants[1].hasExtendedCost, merchants[1].numAvailable = false, 0
ns.SnatchBuyVendor(1)
eq(#calls, 0, "out of stock")
merchants[1].numAvailable, bags[1] = -1, 3
ns.SnatchBuyVendor(1)
eq(#calls, 0, "no bundle overshoot")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 4, unitPrice = 80 }, { quantity = 20, unitPrice = 120 } }
start(s)
eq(calls[1][1], "search")
result(1)
eq(#calls, 1, "no automatic AH purchase")
ns.SnatchBuyAH()
eq(calls[2][1], "quote")
eq(calls[2][3], 4, "only quantities below cap")
event("COMMODITY_PRICE_UPDATED", 80, 320)
eq(#calls, 2, "quote needs physical confirmation")
ns.SnatchBuyAH()
eq(calls[3][1], "confirm")
eq(s.inFlight.qty, 4, "persistent reservation before purchase")
eq(ns.SnatchNeeds()[1].missing, 6, "reserve unconfirmed purchase")
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(s.inFlight, nil)
eq(s.awaiting[1], 4, "reserve mailed purchase")
eq(ns.SnatchNeeds()[1].missing, 6)
TakeInboxItem(1, 1)
bags[1] = 4
event("BAG_UPDATE_DELAYED")
eq(s.awaiting[1], 0, "collect mail without double subtraction")
eq(ns.SnatchNeeds()[1].missing, 6)

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 110, 1100)
eq(calls[#calls][1], "cancel", "reject expensive quote")
ns.SnatchBuyAH()
eq(#calls, 3, "cannot confirm rejected quote")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1)
commodity[1][1].unitPrice = 90
ns.SnatchBuyAH()
eq(#calls, 1, "reject changed listing")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 800)
bags[1] = 10
ns.SnatchBuyAH()
eq(calls[#calls][1], "cancel", "recheck quantity before confirming")

s = setup()
ns.plan.reagents = { { item = 2, qty = 1 } }
ns.SnatchNeeds()
s.target, s.prices[2] = 5, 100
items[2] = {
    { itemKey = { itemID = 2 }, quantity = 6, buyoutAmount = 300, auctionID = 1 },
    { itemKey = { itemID = 2 }, quantity = 2, buyoutAmount = 150, auctionID = 2 },
    { itemKey = { itemID = 2 }, quantity = 1, buyoutAmount = 0, auctionID = 3 },
    { itemKey = { itemID = 2 }, quantity = 1, buyoutAmount = 1, auctionID = 4, containsAccountItem = true },
}
start(s); result(2); ns.SnatchBuyAH()
eq(calls[#calls][1], "buyout")
eq(calls[#calls][2], 2, "skip overshoot, bids and account auctions")
eq(calls[#calls][3], 150)
event("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
eq(s.awaiting[2], nil, "ignore unrelated success")
event("AUCTION_HOUSE_PURCHASE_COMPLETED", 2)
eq(s.awaiting[2], 2)

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
ready = false
start(s)
eq(#calls, 0, "respect server throttle")
ready = true
ns.SnatchPoll()
eq(#calls, 1)
advance(1)
eq(#calls, 1, "no overlapping searches")
result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 800)
advance(11)
eq(calls[#calls - 1][1], "cancel", "quote expiry")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 800)
C_AuctionHouse.StartCommoditiesPurchase(99, 1)
ns.SnatchBuyAH()
eq(calls[#calls][1], "quote", "never confirm another addon's quote")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 800)
ns.SnatchBuyAH()
advance(16)
eq(s.inFlight.kind, "uncertain", "unknown outcome remains reserved")
eq(ns.SnatchNeeds()[1].missing, 0)
ns.SnatchResolvePurchase(false)
eq(s.inFlight, nil)
eq(ns.SnatchNeeds()[1].missing, 10)

s = setup()
s.target, s.prices[1] = 5, 100
s.inFlight = { kind = "buyingCommodity", item = 1, qty = 10, at = 0 }
local old = ns
ns = { plan = old.plan, log = function() end }
assert(loadfile("addon/ShuffleDetector/Snatch.lua"))("ShuffleDetector", ns)
eq(ns.SnatchNeeds()[1].missing, 0, "reservation survives reload")
eq(s.inFlight.kind, "uncertain")
ns.SnatchResolvePurchase(true)
eq(s.awaiting[1], 10)
bags[1] = 2
event("BAG_UPDATE_DELAYED")
eq(s.awaiting[1], 10, "non-mail gains do not consume purchased reservation")

s = setup()
s.target, s.prices[1] = 5, 100
start(s)
C_AuctionHouse.SendSearchQuery({ itemID = 99 })
advance(20)
eq(#calls, 2, "stop if another addon searches")

s = setup()
s.target, s.prices[1] = 5, 0
start(s)
eq(#calls, 0, "zero price disables buying")

s = setup()
s.target, s.prices[1], balance = 5, 100, 799
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
eq(#calls, 1, "do not quote unaffordable offers")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 800)
balance = 799
ns.SnatchBuyAH()
eq(calls[#calls][1], "cancel", "recheck gold at confirmation")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 800)
ns.SnatchBuyAH()
event("COMMODITY_PURCHASE_FAILED")
eq(s.awaiting[1], nil, "failed purchases do not count as acquired")
eq(s.inFlight, nil, "explicit failure releases reservation")
eq(ns.SnatchNeeds()[1].missing, 10)

s = setup()
s.target, s.prices[1] = 5, 100
start(s)
event("AUCTION_HOUSE_CLOSED")
advance(20)
eq(#calls, 1, "closing AH stops polling")

s = setup()
ns.plan.reagents = { { item = 1, qty = 1 }, { item = 2, qty = 1 } }
ns.SnatchNeeds()
s.target, s.prices[1], s.prices[2] = 1, 100, 100
start(s); result(1)
advance(2)
eq(#calls, 1, "minimum polling interval enforced")
advance(1)
eq(#calls, 2, "next search at three seconds")
eq(calls[2][2], 2, "round-robin materials")

print("snatcher checks passed")
