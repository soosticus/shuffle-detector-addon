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

s = linen()
eq(ns.SnatchNeeds()[1].missing, 6, "linen bag requires six bolts")
eq(ns.SnatchNeeds()[2].missing, 12, "two cloth per bolt")
bags[2996], bags[2589] = 1, 3
eq(ns.SnatchNeeds()[1].missing, 4, "existing bolts and complete raw units cover demand")
eq(ns.SnatchNeeds()[2].missing, 7, "partial raw stock reduces cloth purchase")
eq(ns.SnatchNeeds()[1].toCraft, 1, "manual bolt crafting from bags")
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
eq(calls[#calls][2], 2996, "raw price cap remains mandatory")

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
assert(loadfile("addon/ShuffleDetector/Shuffle.lua"))("ShuffleDetector", ns)
ns.ShuffleStep()
eq(ShuffleDetectorShuffleButton:GetAttribute("type"), "spell", "legacy conversion uses secure spell action")
eq(ShuffleDetectorShuffleButton:GetAttribute("spell"), "Bolt of Linen Cloth")

s = linen()
AHSnapshotDB.characters["Tailor-Realm-Alliance"].professions.Tailoring.recipes[1].makes = 2
eq(#ns.SnatchNeeds(), 1, "multi-output intermediate is not mispriced as single-output")

print("snatcher checks passed")
