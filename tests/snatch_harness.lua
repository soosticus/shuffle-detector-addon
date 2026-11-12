local ns, bags, calls, now, balance, commodity, items, merchants, ready, frames
local unpack = table.unpack or unpack
local function eq(actual, expected, label)
    assert(actual == expected, (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function frame()
    local f = { scripts = {}, shown = true }
    local noop = function() end
    for _, method in ipairs({ "SetSize", "SetPoint", "SetWidth", "SetHeight", "SetJustifyH", "SetMovable",
        "SetClampedToScreen", "EnableMouse", "RegisterForDrag", "SetAutoFocus", "SetMaxLetters",
        "SetScrollChild", "RegisterEvent", "UnregisterEvent", "RegisterUnitEvent", "StartMoving", "StopMovingOrSizing",
        "SetFrameStrata", "RegisterForClicks", "SetAllPoints", "SetColorTexture", "SetTextColor" }) do f[method] = noop end
    function f:SetScript(event, fn) self.scripts[event] = fn end
    function f:SetParent(parent) self.parent = parent end
    function f:ClearAllPoints() self.point = nil end
    function f:SetPoint(...) self.point = { ... } end
    function f:GetPoint() return unpack(self.point or { "CENTER", UIParent, "CENTER", 0, 0 }) end
    function f:SetSize(width, height) self.width, self.height = width, height end
    function f:SetHeight(height) self.height = height end
    function f:CreateFontString()
        local label = frame()
        frames[#frames + 1] = label
        return label
    end
    function f:CreateTexture() return frame() end
    function f:HookScript(event, fn) self.scripts[event] = fn end
    function f:SetAttribute(key, value) self[key] = value end
    function f:GetAttribute(key) return self[key] end
    function f:SetText(value) self.value = value end
    function f:GetText() return self.value end
    function f:SetEnabled(value) self.enabled = value end
    function f:IsShown() return self.shown and (not self.parent or self.parent:IsShown()) end
    function f:Show()
        local wasShown = self.shown
        self.shown = true
        if not wasShown and self.scripts.OnShow then self.scripts.OnShow(self) end
    end
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
    CreateFrame = function(_, name, parent)
        local f = frame()
        f.parent = parent
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

local function linen()
    local s = setup()
    ns.charKey = function() return "Tailor-Realm-Alliance" end
    ns.plan.reagents = { { item = 2996, qty = 3, raw = { item = 2589, qty = 2 } } }
    AHSnapshotDB.characters = {
        ["Tailor-Realm-Alliance"] = { professions = { Tailoring = { recipes = {
            { name = "Bolt of Linen Cloth", item = 2996, spell = 2963, reagents = { { item = 2589, qty = 2 } } },
        } } } },
    }
    ns.SnatchNeeds()
    s.target, s.prices[2996], s.prices[2589] = 2, 100, 100
    return s
end

local s = setup()
eq(ns.SnatchParseMoney("1g 20s 5c"), 12005)
eq(ns.SnatchParseMoney("123"), 123)
eq(ns.SnatchParseMoney(""), nil)
eq(ns.SnatchParseMoney("-1"), nil)
eq(ns.SnatchParseMoney("1g1g"), nil)
eq(ns.SnatchParseMoney("nan"), nil)
s.target, s.prices[1], bags[1] = 5, 100, 3
eq(ns.SnatchPriceLimits()[1], 100, "saved limits are readable for any recipe")
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
eq(s.inFlight, nil, "vendor timeout settles from the bag count")
eq(s.awaiting[1], nil, "vendor reconciliation never creates a mail reservation")
eq(ns.NextSnatchPurchase().action, "vendor", "an undelivered vendor buy can be retried")

s = setup()
s.target, s.prices[1] = 5, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 150, stackCount = 2, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
event("UI_ERROR_MESSAGE", 3, "Inventory is full.")
eq(s.inFlight.kind, "uncertain", "a game error waits briefly for bags")
eq(ns.NextSnatchPurchase().blocking, true)
advance(0.5)
eq(s.inFlight.kind, "uncertain")
advance(1)
eq(s.inFlight, nil, "a failed vendor buy releases its reservation without manual resolution")

s = setup()
s.target, s.prices[1] = 5, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 150, stackCount = 2, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
event("UI_ERROR_MESSAGE", 3, "Some unrelated error.")
bags[1] = 10
event("BAG_UPDATE_DELAYED")
eq(s.inFlight, nil, "a vendor buy that arrives after an error still counts as received")

s = setup()
s.target, s.prices[1] = 5, 100
s.inFlight = { kind = "vendor", vendor = true, item = 1, before = 0, qty = 10, total = 750, at = 3174 }
assert(loadfile("addon/ShuffleDetector/Snatch.lua"))("ShuffleDetector", ns)
ns.SnatchNeeds()
eq(s.inFlight.kind, "uncertain", "a restored vendor purchase is checked against bags")
advance(2)
eq(s.inFlight, nil, "a restored undelivered vendor purchase settles after reload")

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
commodity[1] = { { quantity = 20, unitPrice = 120 } }
start(s)
result(1)
assert(ns.NextSnatchPurchase().label:find("Item 1: cheapest 0g 1s 20c, limit 0g 1s 0c", 1, true),
    "a poll with nothing under the limit says what it saw")
commodity[1] = { { quantity = 20, unitPrice = 60, containsOwnerItem = true } }
advance(3)
result(1)
assert(ns.NextSnatchPurchase().label:find("your own listing", 1, true), "own listings blocking a buy are reported")
commodity[1] = {}
advance(3)
result(1)
assert(ns.NextSnatchPurchase().label:find("Item 1: none listed", 1, true))
ready = false
advance(3)
assert(ns.NextSnatchPurchase().label:find("(AH busy)", 1, true), "throttled searches are reported")
ready = true

s = setup()
s.target, s.prices[1], balance = 500, 100, 5000
commodity[1] = { { quantity = 2000, unitPrice = 80 } }
start(s)
result(1)
ns.SnatchBuyAH()
eq(calls[2][1], "quote", "an unaffordable batch still offers what gold covers")
eq(calls[2][3], 62, "commodity quantity limited to current gold")

s = setup()
s.target, s.prices[1], balance = 500, 100, 50
commodity[1] = { { quantity = 2000, unitPrice = 80 } }
start(s)
result(1)
assert(ns.NextSnatchPurchase().label:find("not enough gold", 1, true), "no affordable unit is explained")

s = setup()
s.target, s.prices[1], balance = 500, 100, 1000
MerchantFrame.shown = true
merchants = { { id = 1, price = 150, stackCount = 2, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
eq(calls[1][3], 12, "vendor quantity limited to whole affordable bundles")
MerchantFrame.shown, balance = false, 100000

s = setup()
s.target, s.prices[1] = 500, 100
C_Item.GetItemInfo = function(id) return "Item " .. id, nil, nil, nil, nil, nil, nil, 20 end
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true, max = 20 } }
eq(ns.NextSnatchPurchase().qty, 100, "vendor buys stop at five stacks, not at one purchase's limit")
ns.SnatchBuyVendor(1)
eq(#calls, 5, "a five-stack buy is split into per-call stacks")
for i = 1, 5 do eq(calls[i][3], 20) end
eq(s.inFlight.qty, 100, "one reservation covers every split call")
bags[1] = 100
event("BAG_UPDATE_DELAYED")
eq(s.inFlight, nil, "the split buy settles once all of it arrives")
bags[1] = 0
ns.SnatchBuyVendor(1)
event("UI_ERROR_MESSAGE", 3, "Inventory is full.")
bags[1] = 60
event("BAG_UPDATE_DELAYED")
eq(s.inFlight, nil, "a partly delivered split buy settles")
eq(ns.NextSnatchPurchase().qty, 40, "the undelivered stacks can be bought again")
bags[1] = 0
bags[1] = 70
eq(ns.NextSnatchPurchase().qty, 30, "held stock counts toward the five stacks")
bags[1] = 100
eq(ns.NextSnatchPurchase(), nil, "no vendor buy while five stacks are held")
MerchantFrame.shown = false

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
eq(calls[2][3], 9, "quote only the affordable part of an offer")

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

s = linen()
eq(ns.SnatchNeeds()[1].missing, 6, "linen bag requires six bolts")
eq(ns.SnatchNeeds()[2].missing, 12, "two cloth per bolt")
bags[2996], bags[2589] = 1, 3
eq(ns.SnatchNeeds()[1].missing, 4, "existing bolts and complete raw units cover demand")
eq(ns.SnatchNeeds()[2].missing, 7, "partial raw stock reduces cloth purchase")
eq(ns.SnatchNeeds()[1].toCraft, 1, "manual bolt crafting from bags")
eq(ns.SnatchNeeds()[2].required, 10, "raw requirement excludes the already-created bolt")
ns.ToggleSnatcher()
local function displayed(fragment)
    for _, f in ipairs(frames) do
        if type(f.value) == "string" and f:IsShown() and f.value:find(fragment, 1, true) then return true end
    end
    return false
end
assert(displayed("Raw need 10 | bags 3 | awaiting 0 | buy 7"), "panel uses the same net cloth demand as purchasing")
assert(displayed("For 5 unfilled Item 2996"), "raw demand explains that existing bolts were subtracted")
bags[2996], bags[2589] = 2, 1
event("BAG_UPDATE_DELAYED")
assert(displayed("Raw need 8 | bags 1 | awaiting 0 | buy 7"), "crafting a bolt immediately reduces displayed raw requirement")
bags[2996], bags[2589] = 1, 3
event("BAG_UPDATE_DELAYED")
s.awaiting[2589], s.bags[2589] = 7, 3
eq(ns.SnatchNeeds()[1].missing, 0, "raw mail prevents duplicate bolt purchases")
eq(ns.SnatchNeeds()[2].missing, 0)
TakeInboxItem(1, 1)
bags[2589] = 10
event("BAG_UPDATE_DELAYED")
eq(s.awaiting[2589], 0)
bags[2589], bags[2996] = 0, 6
event("BAG_UPDATE_DELAYED")
eq(ns.SnatchNeeds()[1].missing, 0, "converting collected cloth does not reopen demand")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996)
ns.SnatchBuyAH()
eq(#calls, 1, "must search cloth before offering bolts")
advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][1], "quote")
eq(calls[#calls][2], 2589, "30c cloth beats 80c bolts at 2:1")
eq(calls[#calls][3], 12)
event("COMMODITY_PRICE_UPDATED", 30, 360)
ns.SnatchBuyAH()
eq(ns.SnatchNeeds()[1].missing, 0, "raw in-flight reserves bolt shortfall")
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(s.awaiting[2589], 12)
eq(ns.SnatchNeeds()[1].missing, 0)
eq(ns.SnatchNeeds()[2].missing, 0)

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 4, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 30, 120)
ns.SnatchBuyAH()
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(ns.SnatchNeeds()[1].missing, 4, "partial raw purchase covers only its produced bolts")
commodity[2996][1].unitPrice = 40
advance(3); result(2996); ns.SnatchBuyAH()
eq(calls[#calls][2], 2996, "can switch to cheaper bolts for remaining demand")
eq(calls[#calls][3], 4, "bolt purchase excludes previously purchased raw coverage")
event("COMMODITY_PRICE_UPDATED", 40, 160)
ns.SnatchBuyAH()
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(ns.SnatchNeeds()[1].missing, 0)
eq(ns.SnatchNeeds()[2].missing, 0, "mixed-source purchases do not duplicate the batch")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 50 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][2], 2996, "50c bolts beat two 30c cloth")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 60 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][2], 2996, "prefer no extra crafting at equal cost")

s = linen()
s.prices[2589] = 25
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(#calls, 2, "raw and derived bolt caps both reject over-limit prices")

s = linen()
commodity[2996] = {}
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][2], 2589, "use raw when bolts unavailable")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589)
commodity[2996][1].unitPrice = 40
ns.SnatchBuyAH()
eq(#calls, 2, "reject raw offer when live bolts become cheaper")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(11); result(2589); ns.SnatchBuyAH()
eq(#calls, 2, "expired counterpart cannot authorize raw purchase")

s = linen()
bags[2589] = 1
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 6, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][2], 2589)
eq(calls[#calls][3], 5, "partial cloth offer finishes whole bolts using existing cloth")

s = linen()
bags[2589] = 1
C_AuctionHouse.GetItemKeyInfo = function() return { isCommodity = false } end
items[2996] = { { itemKey = { itemID = 2996 }, quantity = 6, buyoutAmount = 480, auctionID = 90 } }
items[2589] = {
    { itemKey = { itemID = 2589 }, quantity = 1, buyoutAmount = 8, auctionID = 91 },
    { itemKey = { itemID = 2589 }, quantity = 3, buyoutAmount = 21, auctionID = 92 },
    { itemKey = { itemID = 2589 }, quantity = 2, buyoutAmount = 1, auctionID = 93 },
}
start(s)
event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 2996 })
advance(3)
event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 2589 })
ns.SnatchBuyAH()
eq(calls[#calls][1], "buyout")
eq(calls[#calls][2], 91, "individual raw auctions compare incremental cost per completed bolt")
event("AUCTION_HOUSE_PURCHASE_COMPLETED", 91)
eq(s.awaiting[2589], 1)
eq(ns.SnatchNeeds()[1].missing, 5, "individual raw buyout covers one bolt")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 1, unitPrice = 1 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][2], 2996, "do not buy unusable incomplete raw amount")

s = linen()
MerchantFrame.shown = true
merchants = {
    { id = 2996, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true },
    { id = 2589, price = 30, stackCount = 1, numAvailable = -1, isPurchasable = true },
}
ns.SnatchBuyVendor(2996)
eq(#calls, 0, "do not buy expensive vendor bolts")
ns.SnatchBuyVendor(2589)
eq(calls[1][2], 2)
eq(calls[1][3], 12, "vendor raw buys converted requirement")

s = linen()
AHSnapshotDB.characters["Tailor-Realm-Alliance"].professions.Tailoring.recipes = {}
eq(#ns.SnatchNeeds(), 1, "do not assume character can refine")
assert(ns.SnatchNeeds()[1].note:find("profession"), "explain unknown conversion recipe")

s = linen()
ns.plan.reagents[1].raw.qty = 3
eq(#ns.SnatchNeeds(), 1, "do not use a mismatched conversion hint")

s = linen()
ns.plan.reagents[1].raw = nil
eq(#ns.SnatchNeeds(), 2, "old plan discovers learned conversion in game")

s = linen()
ns.plan.reagents[#ns.plan.reagents + 1] = { item = 2589, qty = 1 }
eq(#ns.SnatchNeeds(), 2, "shared raw remains separate direct demand")
assert(ns.SnatchNeeds()[1].note:find("Shared"), "explain unsupported shared raw allocation")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 30, 360)
commodity[2996][1].unitPrice = 40
ns.SnatchBuyAH()
eq(calls[#calls][1], "cancel", "cheaper bolts cancel raw quote at confirmation")

s = linen()
bags[2589] = 1
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 11, unitPrice = 30 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 30, 330)
bags[2589] = 0
ns.SnatchBuyAH()
eq(calls[#calls][1], "cancel", "do not confirm a now-incomplete raw purchase")

s = linen()
ns.ToggleSnatcher()
AHSnapshotDB.characters["Tailor-Realm-Alliance"].professions.Tailoring.recipes = {}
event("BAG_UPDATE_DELAYED")
click("Save limits")
eq(#ns.SnatchNeeds(), 1, "panel follows available conversion recipes")

s = linen()
bags[2589] = 12
local timers, casting = {}, false
C_Timer = { After = function(delay, fn) timers[#timers + 1] = { delay, fn } end }
UnitCastingInfo = function() if casting then return "Bolt of Linen Cloth" end end
C_TradeSkillUI = {
    GetRecipeInfo = function() return { learned = true } end,
    CraftRecipe = function(spell, qty) calls[#calls + 1] = { "craft", spell, qty }; casting = true end,
}
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
local shuffleEvents = frames[#frames]
local function shuffleEvent(name, ...)
    shuffleEvents.scripts.OnEvent(shuffleEvents, name, ...)
end
local function press()
    now = now + 0.5
    local b = ShuffleDetectorShuffleButton
    b.scripts.PreClick(b, "LeftButton", false)
    b.scripts.PostClick(b, "LeftButton", false)
end
eq(ns.NextShuffleStep().spell, 2963, "prepare learned linen conversion")
eq(#calls, 0, "no unattended raw casting")
InCombatLockdown = function() return true end
press()
eq(#calls, 0, "no conversion request in combat")
InCombatLockdown = function() return false end
for i = 1, 3 do
    press()
    eq(calls[#calls][1], "craft")
    eq(calls[#calls][2], 2963, "macro crafts bolts first")
    eq(calls[#calls][3], 1, "one intermediate cast per hardware press")
    local n = #calls
    press()
    eq(#calls, n, "fast presses cannot repeat conversion")
    casting = false
    shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "bolt" .. i, 2963)
    eq(s.completed, 0, "bolts do not count toward linen bag target")
    press()
    eq(#calls, n, "wait for conversion bag update")
    bags[2589], bags[2996] = bags[2589] - 2, i
    shuffleEvent("BAG_UPDATE_DELAYED")
end
eq(ns.NextShuffleStep().recipe, nil, "return to primary recipe after enough bolts")
press()
eq(calls[#calls][2], 10, "macro now crafts the selected bag")
casting = false
shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "bag1", 10)
eq(s.completed, 1)
bags[2996] = 0
shuffleEvent("BAG_UPDATE_DELAYED")
eq(ns.NextShuffleStep().spell, 2963, "prepare next bag's bolts without shopping again")
s.completed = 2
eq(ns.NextShuffleStep().label, "Craft target reached", "no excess conversion after batch target")

do
    s = linen()
    bags[2589] = 4
    casting = false
    event("AUCTION_HOUSE_SHOW")
    assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
    local craftEvents = frames[#frames]
    press()
    eq(calls[1][1], "craft", "first press crafts bolts from the cloth in bags")
    eq(calls[2][1], "search", "starting a craft starts AH polling for the rest of the batch")
    eq(calls[2][2], 2996)
    commodity[2996] = { { quantity = 40, unitPrice = 500 } }
    commodity[2589] = { { quantity = 40, unitPrice = 50 } }
    result(2996)
    advance(3)
    eq(calls[#calls][1], "search", "polling continues during the craft")
    eq(calls[#calls][2], 2589)
    result(2589)
    assert(ns.NextSnatchPurchase().label:find("Quote", 1, true), "an offer is ready while casting")
    ns.RefreshShuffleTracker()
    local foot = ShuffleDetectorTracker.foot:GetText()
    assert(foot:find("Working...", 1, true) and foot:find("Quote", 1, true), foot)
    local n = #calls
    press()
    eq(calls[#calls][1], "quote", "a press during the craft cast quotes the AH offer")
    eq(#calls, n + 1, "the press does not repeat the craft")
    event("COMMODITY_PRICE_UPDATED", 50, calls[#calls][3] * 50)
    press()
    eq(calls[#calls][1], "confirm", "and the next press buys it, still while casting")
    eq(casting, true)
    casting = false
    craftEvents.scripts.OnEvent(craftEvents, "UNIT_SPELLCAST_SUCCEEDED", "player", "bolt-ah", 2963)
end

s = linen()
s.prices[2589] = 24
eq(ns.SnatchLimitCostPerCraft(), 144, "bolts are costed at twice the linen limit")
s.prices[2589] = nil
local _, unpriced = ns.SnatchLimitCostPerCraft()
eq(unpriced, 2996, "a reagent without a limit gives no limit cost")

s = linen()
bags[2589] = 20
C_Item.GetItemInfo = function(id)
    return "Item " .. id, nil, nil, nil, nil, nil, nil, 20
end
eq(ns.NextSnatchRefinement(2996).quantity, 6, "queue only remaining batch's bolts despite excess cloth")
s.target, bags[2589] = 20, 200
eq(ns.NextSnatchRefinement(2996).quantity, 60, "mass creation can span multiple output stacks")
s.target, bags[2589] = 2, 20
bags[2996] = 1
s.awaiting[2996] = 2
eq(ns.NextSnatchRefinement(2996).quantity, 3, "existing and reserved bolts reduce queue")
bags[2589] = 3
eq(ns.NextSnatchRefinement(2996).quantity, 1, "queue limited to whole conversions from bagged raw")
s.awaiting[2589] = 100
eq(ns.NextSnatchRefinement(2996).quantity, 1, "raw mail is not craftable")
C_Item.GetItemInfo = function() return "Nonstackable", nil, nil, nil, nil, nil, nil, 1 end
bags[2589] = 20
eq(ns.NextSnatchRefinement(2996).quantity, 1, "nonstackable output keeps single crafting")
C_Item.GetItemInfo = function() return nil end
eq(ns.NextSnatchRefinement(2996).quantity, 1, "unknown stack size keeps single crafting")
C_Item.GetItemInfo = function() return "Bolts", nil, nil, nil, nil, nil, nil, 20 end
local rawRecipe = AHSnapshotDB.characters["Tailor-Realm-Alliance"].professions.Tailoring.recipes[1]
rawRecipe.reagents[1].qty = 1
ns.plan.reagents[1].raw.qty = 1
eq(ns.NextSnatchRefinement(2996).quantity, 1, "one-for-one conversion is not inventory compression")
rawRecipe.reagents[1].qty = 2
ns.plan.reagents[1].raw.qty = 2
bags[2996], s.awaiting[2996], s.awaiting[2589] = 0, 0, 0
timers, casting = {}, false
C_TradeSkillUI = {
    GetRecipeInfo = function() return { learned = true } end,
    CraftRecipe = function(spell, qty) calls[#calls + 1] = { "craft", spell, qty }; casting = true end,
}
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
shuffleEvents = frames[#frames]
eq(ns.NextShuffleStep().quantity, 6, "quantity propagated to shuffle action")
assert(ns.NextShuffleStep().label:find("6 x"), "tracker previews queue quantity")
press()
eq(calls[#calls][3], 6, "one hardware press queues six bolts")
local queuedCalls = #calls
for i = 1, 6 do
    shuffleEvent("UNIT_SPELLCAST_START", "player", "queued" .. i, 2963)
    casting = false
    shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "queued" .. i, 2963)
    shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "queued" .. i, 2963)
    eq(s.completed, 0, "queued bolts do not count as bags")
    if i == 1 then
        now = now + 20
        timers[2][2]()
    end
    press()
    eq(#calls, queuedCalls, "queue locked pending each bag update")
    if i < 6 then
        shuffleEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "unrelated", 99)
    end
    bags[2589], bags[2996] = bags[2589] - 2, i
    shuffleEvent("BAG_UPDATE_DELAYED")
    if i < 6 then
        for _, timer in ipairs(timers) do
            if timer[1] == 2 then timer[2]() end
        end
        press()
        eq(#calls, queuedCalls, "queue locked even between casts after bag updates")
    end
end
press()
eq(calls[#calls][2], 10, "completed queue returns to bag crafting")
eq(calls[#calls][3], 1, "finished recipe remains one cast per press")
casting = false
shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "queuedbag", 10)
bags[2996] = 3
shuffleEvent("BAG_UPDATE_DELAYED")
eq(s.completed, 1, "only main craft advances target after batch preparation")
eq(ns.NextShuffleStep().recipe, nil, "prepared enough bolts for next bag too")

s = linen()
bags[2589] = 12
C_Item.GetItemInfo = function() return "Bolts", nil, nil, nil, nil, nil, nil, 20 end
timers, casting = {}, false
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
shuffleEvents = frames[#frames]
press()
eq(calls[#calls][3], 6)
shuffleEvent("UNIT_SPELLCAST_START", "player", "interrupted1", 2963)
casting = false
shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "interrupted1", 2963)
bags[2589], bags[2996] = 10, 1
shuffleEvent("BAG_UPDATE_DELAYED")
shuffleEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "interrupted2", 2963)
press()
eq(calls[#calls][3], 5, "interrupted queue recalculates missing bolts on next press")
casting = false
shuffleEvent("UNIT_SPELLCAST_FAILED", "player", "failedretry", 2963)
press()
eq(calls[#calls][3], 5, "failed queue unlocks for retry")
casting = false

s = linen()
s.awaiting[2996], bags[2589] = 6, 12
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
eq(ns.SnatchNeeds()[1].toCraft, 0, "do not refine redundant raw while bought bolts are in mail")
eq(ns.NextSnatchRefinement(2996), nil)
eq(ns.NextShuffleStep().kind, "idle", "mail is not craftable bag stock")

s = linen()
bags[2589] = 1
eq(ns.NextSnatchRefinement(2996), nil, "partial raw stack cannot start a bolt")
s.target, bags[2589] = 0, 12
eq(ns.NextSnatchRefinement(2996), nil, "no auto refinement with target disabled")

s = linen()
bags[2589] = 12
C_TradeSkillUI = nil
C_Item.GetItemInfo = function() return "Bolts", nil, nil, nil, nil, nil, nil, 20 end
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
ns.ShuffleStep()
eq(ns.NextSnatchRefinement(2996).quantity, 1, "legacy tracker previews a single conversion")
eq(ShuffleDetectorShuffleButton:GetAttribute("type"), "spell", "legacy conversion uses secure spell action")
eq(ShuffleDetectorShuffleButton:GetAttribute("spell"), "Bolt of Linen Cloth")

s = linen()
AHSnapshotDB.characters["Tailor-Realm-Alliance"].professions.Tailoring.recipes[1].makes = 2
eq(#ns.SnatchNeeds(), 1, "multi-output intermediate is not mispriced as single-output")

local function macro()
    C_Timer = { After = function() end }
    UnitCastingInfo = function() return nil end
    C_TradeSkillUI = {
        CraftRecipe = function(spell, qty) calls[#calls + 1] = { "craft", spell, qty } end,
        GetRecipeInfo = function() return { learned = true } end,
    }
    assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
    return function()
        now = now + 0.5
        local b = ShuffleDetectorShuffleButton
        b.scripts.PreClick(b, "LeftButton", true)
        b.scripts.PostClick(b, "LeftButton", true)
        b.scripts.PreClick(b, "LeftButton", false)
        b.scripts.PostClick(b, "LeftButton", false)
    end
end

s = setup()
s.target, s.prices[1] = 5, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
local pressPurchase = macro()
eq(ns.NextShuffleStep().kind, "purchase")
pressPurchase()
eq(#calls, 1, "down/up only buys one vendor batch")
eq(calls[1][1], "vendor")
eq(calls[1][3], 10)
pressPurchase()
eq(#calls, 1, "macro waits for vendor receipt")
bags[1] = 10
event("BAG_UPDATE_DELAYED")
MerchantFrame.shown = false
pressPurchase()
eq(calls[2][1], "craft", "same macro proceeds to craft after buying")

s = setup()
s.target, s.prices[1], bags[1] = 50, 100, 2
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
pressPurchase = macro()
eq(ns.NextSnatchPurchase().kind, "purchase", "the whole batch still needs more materials")
eq(ns.NextShuffleStep().kind, "craft", "craft available materials before stockpiling the rest of the batch")
pressPurchase()
eq(calls[1][1], "craft", "vendor presence does not starve crafting")

s = setup()
s.target, s.prices[1] = 50, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
pressPurchase = macro()
pressPurchase()
eq(calls[1][1], "vendor")
local bought = #calls
event("UI_ERROR_MESSAGE", 3, "Inventory is full.")
pressPurchase()
eq(#calls, bought, "macro waits while the failed vendor buy is checked")
advance(2)
bags[1] = 2
pressPurchase()
eq(calls[bought + 1][1], "craft", "macro crafts after an inventory-full vendor error")

s = linen()
bags[2589] = 12
ns.plan.reagents[#ns.plan.reagents + 1] = { item = 2320, qty = 3 }
ns.SnatchNeeds()
s.target = 50
s.prices[2320] = 10
MerchantFrame.shown = true
merchants = { { id = 2320, price = 10, stackCount = 1, numAvailable = -1, isPurchasable = true } }
pressPurchase = macro()
eq(ns.NextShuffleStep().spell, 2963, "prepare owned cloth before filling bags with thread")
pressPurchase()
eq(calls[1][1], "craft")
eq(calls[1][2], 2963)

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
pressPurchase = macro()
event("AUCTION_HOUSE_SHOW")
eq(ns.NextShuffleStep().purchase.action, "poll")
pressPurchase()
eq(#calls, 1)
eq(calls[1][1], "search", "macro starts polling without opening shopping panel")
pressPurchase()
eq(#calls, 1, "macro waits for search instead of overlapping")
result(1)
eq(ns.NextShuffleStep().purchase.action, "ah")
pressPurchase()
eq(calls[2][1], "quote")
pressPurchase()
eq(#calls, 2, "cannot buy while quote is pending")
event("COMMODITY_PRICE_UPDATED", 80, 800)
eq(ns.NextShuffleStep().label, "Confirm 10 x Item 1 for 0g 8s 0c")
bags[1] = 2
eq(ns.NextShuffleStep().kind, "purchase", "a pending quote retains confirmation priority over bagged materials")
bags[1] = nil
pressPurchase()
eq(calls[3][1], "confirm", "same macro confirms on a separate press")
eq(#calls, 3, "one confirmation for down/up")
ns.SnatchBuyAH()
pressPurchase()
eq(#calls, 3, "panel and macro share the purchase lock")
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(ns.NextShuffleStep().label, "Collect purchased materials from mail")
pressPurchase()
eq(#calls, 3, "does not buy purchased mail again")

s = setup()
ns.plan.reagents = { { item = 2, qty = 1 } }
ns.SnatchNeeds()
s.target, s.prices[2] = 3, 100
items[2] = { { itemKey = { itemID = 2 }, quantity = 3, buyoutAmount = 240, auctionID = 101 } }
pressPurchase = macro()
event("AUCTION_HOUSE_SHOW")
pressPurchase(); result(2); pressPurchase()
eq(calls[2][1], "buyout", "macro supports individual auction buyouts")
event("AUCTION_HOUSE_PURCHASE_COMPLETED", 101)
eq(s.awaiting[2], 3)
eq(ns.NextShuffleStep().kind, "idle")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
pressPurchase = macro()
event("AUCTION_HOUSE_SHOW")
pressPurchase(); result(1)
commodity[1][1].unitPrice = 120
pressPurchase()
eq(#calls, 1, "macro rejects changed over-cap listings")
eq(s.inFlight, nil)

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
pressPurchase = macro()
event("AUCTION_HOUSE_SHOW")
pressPurchase(); result(1); pressPurchase()
event("COMMODITY_PRICE_UPDATED", 80, 800)
InCombatLockdown = function() return true end
pressPurchase()
eq(#calls, 2, "macro cannot confirm purchases in combat")
InCombatLockdown = function() return false end
pressPurchase()
eq(calls[3][1], "confirm")
advance(16)
eq(ns.NextShuffleStep().label, "Resolve uncertain purchase in the snatcher panel")
bags[1] = 10
eq(ns.NextShuffleStep().kind, "idle", "uncertain purchases still block crafting even with materials")
pressPurchase()
eq(#calls, 3, "unknown outcomes cannot be retried with macro")
ns.SnatchResolvePurchase(false)
eq(ns.NextShuffleStep().kind, "craft", "explicitly resolving uncertainty restores crafting instead of more shopping")

s = setup()
s.target, s.prices[1] = 0, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
pressPurchase = macro()
pressPurchase()
eq(#calls, 0, "disabled target never spends through macro")

s = linen()
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 30 } }
pressPurchase = macro()
event("AUCTION_HOUSE_SHOW")
pressPurchase(); result(2996); advance(3); result(2589); pressPurchase()
eq(calls[#calls][2], 2589, "single button keeps cheaper raw selection")
eq(calls[#calls][3], 12)
event("COMMODITY_PRICE_UPDATED", 30, 360)
pressPurchase()
eq(calls[#calls][1], "confirm")
event("COMMODITY_PURCHASE_SUCCEEDED")
TakeInboxItem(1, 1)
bags[2589] = 12
event("BAG_UPDATE_DELAYED")
event("AUCTION_HOUSE_CLOSED")
eq(ns.NextShuffleStep().spell, 2963, "single button proceeds from raw buying to bolt preparation")
pressPurchase()
eq(calls[#calls][1], "craft")
eq(calls[#calls][2], 2963)

s = setup()
s.target, s.prices[1] = 5, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
pressPurchase = macro()
local expected = ns.NextShuffleStep().purchase
merchants[1].price = 90
ns.SnatchPurchaseStep(expected)
eq(#calls, 0, "dispatch rejects price changes between selection and execution")
pressPurchase()
eq(calls[1][1], "vendor")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
pressPurchase = macro()
event("AUCTION_HOUSE_SHOW")
pressPurchase(); result(1)
local b = ShuffleDetectorShuffleButton
now = now + 0.5
b.scripts.PreClick(b, "LeftButton", false)
event("AUCTION_HOUSE_CLOSED")
b.scripts.PostClick(b, "LeftButton", false)
eq(#calls, 1, "closing AH before execution cannot spend")

s = setup()
s.target, s.prices[1] = 5, 100
SlashCmdList = {}
date = os.date
UnitName = function() return "Tailor" end
GetRealmName = function() return "Realm" end
UnitFactionGroup = function() return "Alliance" end
assert(loadfile("addon/ShuffleDetector/ShuffleDetector.lua"))("ShuffleDetector", ns)
pressPurchase = macro()
ns.RestoreShuffleWindow()
local window = ShuffleDetectorSnatcher
eq(window:IsShown(), true, "existing default tracker visibility opens the shared window")
eq(window.shuffleStatus, ShuffleDetectorTracker)
eq(ShuffleDetectorTracker.parent, window, "live tracker is embedded, not another window")
eq(window.width, 450)
eq(window.height, 510)
eq(window.progress.value, "0 / 5 crafts completed; 1 items per craft")
eq(window.target:GetText(), "5", "batch controls share state with tracker")
eq(ShuffleDetectorTracker.foot.value, "Out of Item 1", "shared window shows live shuffle action")
SlashCmdList.SHUFFLEDETECTOR("shuffle")
eq(window:IsShown(), false, "shuffle slash command toggles the shared window")
eq(ShuffleDetectorTracker:IsShown(), false, "embedded tracker hides with batch options")
eq(AHSnapshotDB.shuffleTrackerShown, false, "close visibility persists")
SlashCmdList.SHUFFLEDETECTOR("snatch")
eq(window:IsShown(), true, "snatch remains an alias for the same window")
eq(ShuffleDetectorSnatcher, window, "aliases do not create another panel")
window:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -50)
window.scripts.OnDragStop(window)
eq(AHSnapshotDB.shuffleTracker.x, 40)
eq(AHSnapshotDB.shuffleTracker.y, -50)
window:Hide()
ns.RestoreShuffleWindow()
eq(window:IsShown(), false, "hidden state remains hidden on restoration")
eq(window.point[4], 40, "restores old tracker position to merged window")
eq(window.point[5], -50)
SlashCmdList.SHUFFLEDETECTOR("shuffle")
event("AUCTION_HOUSE_SHOW")
pressPurchase()
eq(calls[1][1], "search")
window:Hide()
advance(20)
eq(#calls, 1, "hiding merged window stops polling")
eq(window:IsShown(), false)
pressPurchase()
eq(calls[2][1], "search", "action macro remains usable while merged window is hidden")
eq(window:IsShown(), false, "action macro does not reopen options")
bags[1] = 10
event("BAG_UPDATE_DELAYED")
event("AUCTION_HOUSE_CLOSED")
SlashCmdList.SHUFFLEDETECTOR("snatch")
eq(ShuffleDetectorTracker.foot.value, "Run your shuffle macro", "live state updates after bag acquisition")
eq(window.target:GetText(), "5", "toggling does not reset batch target")
ns.plan = nil
event("BAG_UPDATE_DELAYED")
eq(window.progress.value, "", "no stale batch progress after plan removal")
eq(ShuffleDetectorTracker.title.value, "Shuffle")
eq(window.buy.enabled, false, "missing plans cannot buy")

s = setup()
s.target, s.prices[1] = 5, 100
commodity[1] = { { quantity = 10, unitPrice = 80 } }
pressPurchase = macro()
ns.ToggleSnatcher()
window = ShuffleDetectorSnatcher
event("AUCTION_HOUSE_SHOW")
pressPurchase(); result(1); pressPurchase()
event("COMMODITY_PRICE_UPDATED", 80, 800)
window:Hide()
eq(calls[#calls][1], "cancel", "hiding shared window cancels only an unconfirmed quote")
eq(s.target, 5)
eq(s.prices[1], 100)
pressPurchase()
advance(3); result(1); pressPurchase()
event("COMMODITY_PRICE_UPDATED", 80, 800)
pressPurchase()
local countBeforeHide = #calls
ns.ToggleSnatcher()
window:Hide()
eq(#calls, countBeforeHide, "hiding window does not cancel an already submitted purchase")
eq(s.inFlight.qty, 10, "submitted reservation survives window visibility changes")
pressPurchase()
eq(#calls, countBeforeHide, "hidden macro still respects purchase reservation")

local free, outputStack, contents
local function batchSetup(exit)
    local state = setup()
    state.target, bags[1] = 50, 100
    ns.plan.exit = exit
    free, outputStack, contents = 32, 1, {}
    C_Item.GetItemInfo = function() return "Output", nil, nil, nil, nil, nil, nil, outputStack end
    C_Container = {
        GetContainerNumFreeSlots = function(bag)
            if bag == 0 then return free, 0 end
            return 50, 32 -- specialized slots must not count as general output space
        end,
        GetContainerNumSlots = function(bag) return bag == 0 and 40 or 0 end,
        GetContainerItemInfo = function(bag, slot) return contents[slot] end,
        GetContainerItemLink = function(bag, slot)
            local item = contents[slot]
            return item and "item:" .. item.itemID or nil
        end,
        UseContainerItem = function(bag, slot) calls[#calls + 1] = { "sell", bag, slot } end,
    }
    local clickBatch = macro()
    shuffleEvents = frames[#frames]
    return state, clickBatch
end

local batchPress
s, batchPress = batchSetup("Disenchant")
eq(ns.NextShuffleStep().quantity, 30, "no ten-item cap: leave two general slots open")
free = 7
eq(ns.NextShuffleStep().quantity, 5, "batch adapts to free bag slots")
bags[1] = 6
eq(ns.NextShuffleStep().quantity, 3, "batch limited by available materials")
bags[1], s.target, s.completed = 100, 50, 48
eq(ns.NextShuffleStep().quantity, 2, "batch limited by remaining target")
s.target, s.completed, ns.plan.makes = 5, 0, 3
eq(ns.NextShuffleStep().quantity, 1, "multi-output craft must fit entire output")
free = 8
eq(ns.NextShuffleStep().quantity, 2, "multi-output target rounded up within space limit")
s.target, ns.plan.makes = 50, 1
free = 2
eq(ns.NextShuffleStep().kind, "idle", "do not consume two reserved slots")
assert(ns.NextShuffleStep().label:find("2 slots"), "full-bag waiting state explains reserve")
batchPress()
eq(#calls, 0, "no protected craft request without reserved space")
outputStack = 20
contents[1] = { itemID = 20, stackCount = 17 }
ns.plan.exit = ""
eq(ns.NextShuffleStep().quantity, 3, "partial stack room usable with two empty slots")
contents[1].isLocked = true
eq(ns.NextShuffleStep().kind, "idle", "locked stack cannot provide output space")
contents[1].isLocked = false
free = 1
eq(ns.NextShuffleStep().kind, "idle", "partial stacks cannot substitute for two empty slots")
free = 3
eq(ns.NextShuffleStep().quantity, 23, "combine partial stack room and spare general slot")
s.target = 0
bags[1] = 10
eq(ns.NextShuffleStep().quantity, 5, "batching also works without a snatcher target")
C_TradeSkillUI = nil
eq(ns.NextShuffleStep().quantity, 1, "legacy crafting stays one cast per press")

s, batchPress = batchSetup("Vendor")
bags[1], s.target, s.prices[1] = 0, 100, 100
MerchantFrame.shown = true
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
free, outputStack = 3, 5
eq(ns.NextShuffleStep().purchase.qty, 5, "vendor buy reserves two general slots")
contents[1] = { itemID = 1, stackCount = 3 }
eq(ns.NextShuffleStep().purchase.qty, 7, "vendor buy includes unlocked partial material stacks")
contents[1].isLocked = true
eq(ns.NextShuffleStep().purchase.qty, 5, "vendor buy excludes locked partial stacks")
contents[1].isLocked = false
free = 2
eq(ns.NextShuffleStep().purchase.qty, 2, "with only reserve slots free, fill the partial stack only")
free = 1
eq(ns.NextShuffleStep().kind, "idle", "vendor buy never consumes the reserved slots")
batchPress()
eq(#calls, 0, "no vendor buy when general bag reserve cannot be preserved")
free, outputStack, contents = 3, 5, {}
merchants[1].stackCount, merchants[1].price = 2, 160
eq(ns.NextShuffleStep().purchase.qty, 4, "capacity is rounded down to whole vendor bundles")

for _, exit in ipairs({ "Disenchant", "Vendor" }) do
    s, batchPress = batchSetup(exit)
    free = 6
    MerchantFrame.shown = exit == "Vendor"
    batchPress()
    eq(calls[1][1], "craft")
    eq(calls[1][3], 4, "queue all crafts fitting spare capacity")
    for i = 1, 4 do
        shuffleEvent("UNIT_SPELLCAST_START", "player", "batch" .. i, 10)
        shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "batch" .. i, 10)
        bags[1], bags[20], free = bags[1] - 2, i, free - 1
        contents[i] = { itemID = 20, stackCount = 1 }
        shuffleEvent("BAG_UPDATE_DELAYED")
        if i < 4 then
            batchPress()
            eq(#calls, 1, "do not exit or craft again during queued batch")
        end
    end
    eq(s.completed, 4, "every finished craft advances target")
    eq(ns.NextShuffleStep().kind, exit == "Vendor" and "sell" or "disenchant", "exit after entire queue")
    if exit == "Vendor" then
        local before = #calls
        batchPress()
        eq(#calls, before + 4, "one press sells every crafted stack")
        for i = 1, 4 do eq(calls[before + i][1], "sell"); eq(calls[before + i][3], i) end
        batchPress()
        eq(#calls, before + 4, "a fast second press does not sell again before the bags update")
        contents, bags[20], free = {}, 0, free + 4
        shuffleEvent("BAG_UPDATE_DELAYED")
    end
    for i = 1, exit == "Vendor" and 0 or 4 do
        batchPress()
        if exit == "Disenchant" then
            eq(ShuffleDetectorShuffleButton:GetAttribute("type"), nil, "DE disarmed until loot bags update")
            shuffleEvent("UNIT_SPELLCAST_START", "player", "de" .. i, 13262)
            shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "de" .. i, 13262)
        else
            eq(calls[#calls][1], "sell")
        end
        contents[i], bags[20], free = nil, 4 - i, free + 1
        shuffleEvent("BAG_UPDATE_DELAYED")
        eq(s.completed, 4, "exit actions never advance craft target")
        if i < 4 then
            eq(ns.NextShuffleStep().kind, exit == "Vendor" and "sell" or "disenchant", "drain entire batch before crafting")
        end
    end
    eq(ns.NextShuffleStep().quantity, 4, "next batch rechecks space after exit phase")
    batchPress()
    eq(calls[#calls][1], "craft", "return to crafting after all outputs processed")
end

s, batchPress = batchSetup("Disenchant")
free = 6
batchPress()
shuffleEvent("UNIT_SPELLCAST_START", "player", "partial", 10)
shuffleEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "partial", 10)
bags[1], bags[20], free = 98, 1, 5
contents[1] = { itemID = 20, stackCount = 1 }
shuffleEvent("BAG_UPDATE_DELAYED")
shuffleEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cancelled", 10)
eq(ns.NextShuffleStep().kind, "disenchant", "interrupted primary queue processes partial output batch")
eq(s.completed, 1, "interruption does not count unmade queued crafts")
contents[1], bags[20], free = nil, 0, 6
shuffleEvent("BAG_UPDATE_DELAYED")
eq(ns.NextShuffleStep().quantity, 4, "retry recalculates space after partial batch")
C_Container.GetContainerNumFreeSlots = nil
eq(ns.NextShuffleStep().quantity, 1, "missing capacity API keeps conservative single craft")

local function statisticsSetup()
    local state = setup()
    time = function() return 1700000000 + math.floor(now) end
    date = os.date
    C_Timer = { After = function() end }
    assert(loadfile("addon/ShuffleDetector/Statistics.lua"))("ShuffleDetector", ns)
    local statsEvents = frames[#frames]
    state.target = 2
    ns.plan.estimate = { cost = 100, income = 180 }
    ns.SnatchNeeds()
    return state, statsEvents, AHSnapshotDB.batchStats.characters.char.history[1]
end

local statsEvents, stat
s, statsEvents, stat = statisticsSetup()
eq(stat.crafts, 0)
local estimate = ns.BatchStatsText(s)
assert(estimate:find("Batch of 2 crafts, market prices", 1, true), estimate)
assert(estimate:find("cost 0g 2s 0c | value 0g 3s 60c", 1, true), "estimate covers the whole batch before any craft")
s.prices[1] = 30
estimate = ns.BatchStatsText(s)
assert(estimate:find("reagents at your limits: cost up to 0g 1s 20c | value 0g 3s 60c", 1, true), estimate)
assert(estimate:find("Estimated profit at least 0g 2s 40c (0g 1s 20c/item)", 1, true), estimate)
s.prices[1] = nil
ns.plan.estimate.income = 999
eq(stat.estimate.income, 180, "price estimates frozen at batch start")
ns.SnatchCraftCompleted(10, "stat1")
ns.SnatchCraftCompleted(10, "stat1")
eq(stat.items, 1, "stats deduplicate main recipe successes")
eq(stat.crafts, 1)
ns.SnatchCraftCompleted(2963, "bolt")
eq(stat.crafts, 1, "intermediates do not inflate statistics")
MerchantFrame.shown = true
s.prices[1] = 100
merchants = { { id = 1, price = 80, stackCount = 1, numAvailable = -1, isPurchasable = true } }
ns.SnatchBuyVendor(1)
eq(stat.cost, 0, "no spending before confirmed vendor receipt")
bags[1] = 2
event("BAG_UPDATE_DELAYED")
eq(stat.cost, 160, "confirmed vendor purchase records actual bundle cost")
event("BAG_UPDATE_DELAYED")
eq(stat.cost, 160, "purchase confirmations cannot double count")

bags[20] = 1
C_Item.GetItemInfo = function() return "Output", nil, nil, nil, nil, nil, nil, 1, nil, nil, 300 end
C_Container.GetContainerItemLink = function() return "item:20" end
ns.BatchStatsSale(0, 1)
local notices = {}
ns.say = function(message) notices[#notices + 1] = message end
eq(ns.BatchStatsClose(s), false, "unconfirmed sale prevents batch rollover")
eq(#notices, 1, "unconfirmed sale explicitly notifies user")
bags[20] = 0
statsEvents.scripts.OnEvent(statsEvents, "BAG_UPDATE_DELAYED")
eq(stat.income, 0, "bag loss alone is not sale income")
balance = balance + 300
statsEvents.scripts.OnEvent(statsEvents, "PLAYER_MONEY")
eq(stat.income, 300, "matching gold and output loss confirm sale income")
statsEvents.scripts.OnEvent(statsEvents, "PLAYER_MONEY")
eq(stat.income, 300, "sale receipt cannot be counted twice")
stat.available, bags[20] = 3, 3
ns.BatchStatsSale(0, 1, 3)
bags[20], balance = 2, balance + 300
statsEvents.scripts.OnEvent(statsEvents, "PLAYER_MONEY")
eq(stat.income, 600, "the first stack of a multi-stack sale is counted")
assert(stat.sale, "the rest of the press's sale is still expected")
bags[20], balance = 0, balance + 600
statsEvents.scripts.OnEvent(statsEvents, "BAG_UPDATE_DELAYED")
eq(stat.income, 1200, "later stacks of the same press are counted")
eq(stat.sale, nil, "the sale settles once everything sold")
stat.income, stat.sold = 300, stat.sold - 3
local cost, income, net, average = ns.BatchStatsTotals(stat)
eq(cost, 160)
eq(income, 300)
eq(net, 140)
eq(average, 140)
eq(stat.available, 0)
ns.ToggleBatchAnalytics()
eq(ShuffleDetectorAnalytics:IsShown(), true, "separate analytics window opens")
ShuffleDetectorAnalytics.amount:SetText("1g")
click("Add income")
eq(stat.manualIncome, 10000)
click("Undo last entry")
eq(stat.manualIncome, 0, "mistaken manual entry can be undone")
ShuffleDetectorAnalytics.amount:SetText("bad")
click("Add cost")
eq(stat.manualCost, 0, "invalid adjustment rejected")
ShuffleDetectorAnalytics.amount:SetText("2s")
click("Add cost")
eq(stat.manualCost, 200)
assert(ns.BatchStatsClose(s))
eq(stat.closed, time(), "closing batch persists history")
ShuffleDetectorAnalytics.batchId:SetText(tostring(stat.id))
ShuffleDetectorAnalytics.amount:SetText("1s")
click("Add income")
eq(stat.manualIncome, 100, "late AH proceeds can be attributed to closed batch")
click("Undo last entry")
eq(stat.manualIncome, 0, "closed batch manual adjustment supports undo")
ShuffleDetectorAnalytics.batchId:SetText("")
ns.BatchStatsEnsure(ns.plan, s)
eq(#AHSnapshotDB.batchStats.characters.char.history, 2)
eq(ns.BatchStatsTotals(stat), 360, "closed batch retains actual and manual expenses")
assert(loadfile("addon/ShuffleDetector/Statistics.lua"))("ShuffleDetector", ns)
eq(ns.BatchStatsEnsure(ns.plan, s).id, s.statsId, "reload resumes existing batch without duplicate history")
for i = 1, 205 do
    ns.BatchStatsClose(s)
    ns.BatchStatsEnsure(ns.plan, s)
end
eq(#AHSnapshotDB.batchStats.characters.char.history, 200, "history is bounded")

s, statsEvents, stat = statisticsSetup()
s.prices[1] = 100
commodity[1] = { { quantity = 4, unitPrice = 80 } }
start(s); result(1); ns.SnatchBuyAH()
event("COMMODITY_PRICE_UPDATED", 80, 320)
ns.SnatchBuyAH()
eq(stat.cost, 0, "pending AH quote is not spending")
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(stat.cost, 320, "AH confirmation records quote total")
eq(stat.purchases, 4)
event("COMMODITY_PURCHASE_SUCCEEDED")
eq(stat.cost, 320, "AH success counted once")
ns.SnatchCraftCompleted(10, "de-stat")
ns.BatchStatsDisenchanted(99)
eq(stat.available, 1, "other disenchant ignored")
ns.BatchStatsDisenchanted(20)
eq(stat.available, 0, "disenchant removes produced stock from sale allocation")
eq(stat.income, 0, "unsold DE loot is not cash income")

s, statsEvents, stat = statisticsSetup()
ns.plan.makes = 3
ns.SnatchNeeds()
s.target = 6
ns.SnatchCraftCompleted(10, "multi-stat")
local multi = AHSnapshotDB.batchStats.characters.char.history[#AHSnapshotDB.batchStats.characters.char.history]
eq(multi.items, 3, "multi-output statistics count produced items")
ns.BatchStatsPurchase({ batch = multi.id, total = 90, qty = 2 })
local _, _, _, perItem = ns.BatchStatsTotals(multi)
eq(perItem, -30, "average cash net divides by items rather than casts")
local oldId = multi.id
assert(ns.BatchStatsClose(s))
ns.BatchStatsEnsure(ns.plan, s)
ns.BatchStatsPurchase({ batch = oldId, total = 10, qty = 1 })
eq(multi.cost, 100, "delayed receipt attributed to original closed batch")
eq(AHSnapshotDB.batchStats.characters.char.history[#AHSnapshotDB.batchStats.characters.char.history].cost, 0)
UnitGUID = function() return "other" end
local other = ns.BatchStatsEnsure(ns.plan, { target = 2 })
eq(other.cost, 0, "statistics isolated per character")
eq(#AHSnapshotDB.batchStats.characters.other.history, 1)

s, statsEvents, stat = statisticsSetup()
local registered
Settings = {
    RegisterCanvasLayoutCategory = function(frame, name) return { frame = frame, name = name } end,
    RegisterAddOnCategory = function(category) registered = category end,
}
statsEvents.scripts.OnEvent(statsEvents, "PLAYER_LOGIN")
eq(registered.name, "ShuffleDetector", "analytics linked from native AddOn Settings")
ns.ToggleBatchAnalytics()
click("Older batches")
click("Newer batches")
Settings = nil
stat.available, bags[20] = 1, 1
C_Item.GetItemInfo = function() return "Output", nil, nil, nil, nil, nil, nil, 1, nil, nil, 300 end
C_Container.GetContainerItemLink = function() return "item:20" end
local saleTimers = {}
C_Timer = { After = function(delay, fn) saleTimers[#saleTimers + 1] = { delay, fn } end }
ns.say = function() end
ns.BatchStatsSale(0, 1)
saleTimers[1][2]()
eq(stat.income, 0, "timed-out sale never invents income")
eq(stat.incomplete, true, "unconfirmed sale flagged incomplete")
eq(stat.sale, nil)
ns.BatchStatsSale(0, 1)
statsEvents.scripts.OnEvent(statsEvents, "PLAYER_LOGIN")
eq(stat.sale, nil, "reload uncertainty cleared with explicit notice, not guessed")
eq(stat.income, 0)

s, batchPress = batchSetup("Vendor")
assert(loadfile("addon/ShuffleDetector/Statistics.lua"))("ShuffleDetector", ns)
statsEvents = frames[#frames]
ns.SnatchNeeds()
stat = AHSnapshotDB.batchStats.characters.char.history[1]
ns.SnatchCraftCompleted(10, "macro-stat")
bags[20], contents[1] = 1, { itemID = 20, stackCount = 1 }
C_Item.GetItemInfo = function() return "Output", nil, nil, nil, nil, nil, nil, 1, nil, nil, 250 end
MerchantFrame.shown = true
batchPress()
assert(stat.sale, "shuffle macro arms sale attribution before vendor request")
bags[20], contents[1], balance = 0, nil, balance + 250
statsEvents.scripts.OnEvent(statsEvents, "BAG_UPDATE_DELAYED")
eq(stat.income, 250, "macro sale integration records matching income")
ns.plan = nil
event("BAG_UPDATE_DELAYED")

s = linen()
s.prices[2996], s.prices[2589] = 99999, 37
eq(ns.SnatchNeeds()[1].cap, 74, "bolt cap derived from two cloth regardless of obsolete saved bolt cap")
s.prices[2589] = 0
eq(ns.SnatchNeeds()[1].cap, 0, "zero raw cap disables intermediate purchases too")
s.prices[2589] = 37
ns.ToggleSnatcher()
local derived, rawInput
for _, f in ipairs(frames) do
    if f.value == "Derived: 0g 0s 74c (2 x raw cap)" then derived = f end
    if f.value == "0g 0s 37c" then rawInput = f end
end
assert(derived and rawInput, "UI has read-only derived label and editable raw price")
eq(rawInput.point[2], 266, "price input occupies former vendor-button column")
eq(rawInput.point[3], -5, "price input is at top of compact row")
eq(derived.point[2], 266, "derived cap occupies same right-hand column")
eq(ShuffleDetectorSnatcher.content.height, 120, "two material rows use sixty pixels each")
eq(ShuffleDetectorSnatcher.controls:IsShown(), false, "secondary controls hidden by default")
click("More controls")
eq(ShuffleDetectorSnatcher.controls:IsShown(), true)
eq(ShuffleDetectorSnatcher.height, 605, "expanding controls allocates space without overlap")
click("Less controls")
eq(ShuffleDetectorSnatcher.controls:IsShown(), false)
eq(ShuffleDetectorSnatcher.height, 510, "collapsing controls returns compact height")
for _, f in ipairs(frames) do
    assert(f.value ~= "Buy vendor", "material rows no longer create vendor buttons")
end
derived:SetText("not a price") -- labels are never parsed as inputs
rawInput:SetText("40c")
click("Save limits")
eq(s.prices[2589], 40, "only raw price input saved")
eq(ns.SnatchNeeds()[1].cap, 80)
eq(derived.value, "Derived: 0g 0s 80c (2 x raw cap)", "derived label refreshes after saving")
rawInput:SetText("0")
click("Save limits")
eq(ns.SnatchNeeds()[1].cap, 0)
eq(ns.SnatchNeeds()[2].cap, 0)
rawInput:SetText("50")
click("Save limits")
commodity[2996] = { { quantity = 6, unitPrice = 80 } }
commodity[2589] = { { quantity = 12, unitPrice = 50 } }
start(s); result(2996); advance(3); result(2589); ns.SnatchBuyAH()
eq(calls[#calls][1], "quote")
eq(calls[#calls][2], 2996, "derived cap permits cheaper direct bolts")
s.prices[2589] = 30
event("COMMODITY_PRICE_UPDATED", 80, 480)
eq(calls[#calls][1], "cancel", "lower raw cap cancels now-overpriced bolt quote")

s = linen()
s.prices[2589] = 30
MerchantFrame.shown = true
merchants = {
    { id = 2996, price = 61, stackCount = 1, numAvailable = -1, isPurchasable = true },
}
ns.SnatchBuyVendor(2996)
eq(#calls, 0, "vendor bolts above derived ceiling rejected")
merchants[1].price = 60
ns.SnatchBuyVendor(2996)
eq(calls[1][1], "vendor", "vendor bolts at exact raw-derived ceiling allowed")

do
    s, batchPress = batchSetup("Disenchant")
    bags[20], contents[1] = 1, { itemID = 20, stackCount = 1 }
    local targets = {}
    ns.NoteDisenchantTarget = function(bag, slot, method)
        targets[#targets + 1] = { bag, slot, method }
    end
    ns.RefreshShuffleTracker()
    eq(#targets, 0, "passive tracker refresh cannot mark a disenchant target")
    batchPress()
    eq(#targets, 1, "hardware press records a secure-button target without relying on SpellTargetItem")
    eq(targets[1][1], 0)
    eq(targets[1][2], 1)
    eq(targets[1][3], "shuffle")
    batchPress()
    eq(#targets, 1, "busy presses do not record another target")
end

do
    s = setup()
    s.awaiting[2589] = 3
    s.inFlight = { item = 2589, qty = 2, kind = "uncertain" }
    local oldPlan, oldPurchase = ns.plan, s.inFlight
    assert(loadfile("addon/ShuffleDetector/ShuffleDetector.lua"))("ShuffleDetector", ns)
    assert(loadfile("addon/ShuffleDetector/Diagnostics.lua"))("ShuffleDetector", ns)
    local notices, reads = {}, {}
    ns.say = function(text) notices[#notices + 1] = text end
    GetBuildInfo = function() return "1.60.1", "12345", "date", 16001 end
    WOW_PROJECT_ID = 99
    C_AddOns = {
        GetAddOnMetadata = function(addon, key) return addon .. "-" .. key end,
        IsAddOnLoaded = function(addon) return addon == "Auctionator" end,
    }
    Auctionator = { API = { v1 = {
        GetAuctionPriceByItemID = function(caller, id)
            eq(caller, "ShuffleDetector")
            reads[#reads + 1] = id
            if id == 2589 then return 123 end
            if id == 7054 then return 0 end
        end,
        GetAuctionAgeByItemID = function() return 4 end,
        GetAuctionPriceByItemLink = function(caller, link)
            eq(caller, "ShuffleDetector")
            eq(link, "item:7054:variant", "link probe retains variant rather than collapsing to item ID")
            return 500
        end,
        IsAuctionDataExactByItemID = function(caller, id)
            eq(caller, "ShuffleDetector")
            return id == 2589
        end,
        GetDisenchantPriceByItemID = function(caller, id)
            eq(caller, "ShuffleDetector")
            if id == 7054 then error("DE table unavailable") end
        end,
        GetAuctionAgeByItemLink = function(caller, link)
            eq(caller, "ShuffleDetector")
            eq(link, "item:7054:variant")
            return 7
        end,
        IsAuctionDataExactByItemLink = function() return false end,
        GetDisenchantPriceByItemLink = function(caller, link)
            eq(caller, "ShuffleDetector")
            eq(link, "item:7054:variant")
            return 750
        end,
    } } }
    C_Item.GetItemInfo = function(id)
        if id == 7054 then return "Robe", "item:7054:variant", 2, 35 end
    end
    local function logged(text)
        for _, line in ipairs(AHSnapshotDB.log or {}) do
            if line:find(text, 1, true) then return true end
        end
        return false
    end
    SlashCmdList.SHUFFLEDETECTOR("prices")
    eq(#reads, 3, "default probe checks all three sample items")
    assert(logged("client=1.60.1 build=12345 interface=16001 project=99"))
    assert(logged("item 2589 price by ID: 123 (number)"))
    assert(logged("item 2996 price by ID: nil (nil)"), "absent quotes are not converted to zero")
    assert(logged("item 7054 price by ID: 0 (number)"), "zero is reported raw, not accepted as a free item")
    assert(logged("item 7054 price by link: 500 (number)"))
    assert(logged("age (raw; units unverified): 4"))
    assert(logged("item 2589 exactness by ID (raw): true (boolean)"))
    assert(logged("item 2996 exactness by ID (raw): false (boolean)"), "false exactness is not a missing value")
    assert(logged("DE table unavailable"), "DE valuation errors cannot abort price diagnostics")
    assert(logged("item 7054 age by link (raw; units unverified): 7"))
    assert(logged("item 7054 exactness by link (raw): false (boolean)"))
    assert(logged("item 7054 DE value by link (raw; model unverified): 750 (number)"), "opaque DE values are reported without applying fees")
    assert(logged("not loot distributions or verified Forever yields"), "a scalar valuation is not a yield table")
    eq(ns.plan, oldPlan, "diagnostics never replace the active plan")
    eq(s.inFlight, oldPurchase, "diagnostics never resolve a purchase")
    eq(s.awaiting[2589], 3, "diagnostics preserve the mail ledger")
    eq(#calls, 0, "diagnostics perform no AH searches or purchase actions")

    AHSnapshotDB.log = {}
    Auctionator = nil
    SlashCmdList.SHUFFLEDETECTOR("prices 2589")
    assert(logged("Auctionator.API.v1: unavailable"), "missing API is an explicit compatibility gap")
    eq(#reads, 3, "missing API does not try another price source")

    AHSnapshotDB.log = {}
    C_AddOns = nil
    GetAddOnMetadata = function() return "legacy-version" end
    IsAddOnLoaded = function() return true end
    Auctionator = { API = { v1 = {
        GetAuctionPriceByItemID = function() error("price API not ready") end,
    } } }
    C_Item.GetItemInfo = function() error("item data unavailable") end
    SlashCmdList.SHUFFLEDETECTOR("prices 7054")
    assert(logged("Auctionator version: legacy-version"), "legacy metadata API still supported")
    assert(logged("price API not ready"), "price error is recorded instead of a zero fallback")
    assert(logged("item data unavailable"), "item metadata failure is explicit")
    assert(logged("age (raw; units unverified): unavailable"))
    assert(logged("exactness by ID (raw): unavailable"))
    assert(logged("DE value by ID (raw; model unverified): unavailable"))
    assert(notices[#notices]:find("Price diagnostic saved", 1, true), "probe remains readable after API failures")

    for _, invalid in ipairs({ "-1", "0", "1e2", "10000001", "1 2 3 4 5 6 7 8 9" }) do
        AHSnapshotDB.log = {}
        SlashCmdList.SHUFFLEDETECTOR("prices " .. invalid)
        eq(#AHSnapshotDB.log, 0, "invalid IDs are rejected before probing")
        assert(notices[#notices]:find("usage:", 1, true))
    end
end

s = setup()
s.target = 4
assert(ns.PrepareShufflePlanChange(), "plan change is allowed with no outstanding actions")
eq(s.target, 0, "plan change clears the previous batch target")
ns.plan = { version = 1, spell = 11, item = 21, recipe = "New shuffle",
    reagents = { { item = 2, qty = 3 } } }
assert(ns.SetSnatchTarget(6), "validated batch target is saved")
eq(s.target, 6)
eq(s.completed, 0)
eq(#calls, 0, "setting an active plan and target never buys or crafts")
for _, invalid in ipairs({ 0, -1, 100001, 1.5, math.huge, 0 / 0 }) do
    local ok = ns.SetSnatchTarget(invalid)
    eq(ok, nil, "invalid batch targets are rejected")
end
s.inFlight = { item = 2, qty = 3 }
local allowed, blocked = ns.PrepareShufflePlanChange()
eq(allowed, nil, "pending purchases block active-plan changes")
assert(blocked:find("pending purchase", 1, true))
allowed, blocked = ns.SetSnatchTarget(8)
eq(allowed, nil, "pending purchases block target changes")
assert(blocked:find("pending purchase", 1, true))

-- Like the game: the addon's files run before its SavedVariables exist, then ADDON_LOADED fires.
local function loadLikeGame(db)
    AHSnapshotDB = nil
    assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
    local events = frames[#frames]
    AHSnapshotDB = db
    events.scripts.OnEvent(events, "ADDON_LOADED", "Auctionator")
    return events
end
s = setup()
local db = AHSnapshotDB
local activePlan = { version = 1, recipe = "In-game choice", selectedAt = 200 }
db.activePlan = activePlan
ns.plan = nil
ns.ValidateActivePlan = function(candidate) return candidate == activePlan end
local events = loadLikeGame(db)
eq(ns.plan, nil, "another addon's ADDON_LOADED does not restore")
events.scripts.OnEvent(events, "ADDON_LOADED", "ShuffleDetector")
eq(ns.plan, activePlan, "the in-game selection survives a reload")

s = setup()
db = AHSnapshotDB
db.activePlan = { version = 1, recipe = "Broken" }
ns.plan = nil
ns.ValidateActivePlan = function() return false end
events = loadLikeGame(db)
events.scripts.OnEvent(events, "ADDON_LOADED", "ShuffleDetector")
eq(ns.plan, nil, "an invalid saved selection is not loaded")

print("snatcher checks passed")
