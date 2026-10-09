-- Scan engine: full AH scan with progress/ETA, plus import of Auctionator's price database.
local ADDON, ns = ...
local say, realmKey = ns.say, ns.realmKey

local BATCH = 500
local SERVER_TIMEOUT = 180
local WAIT_SHARE = 0.2 -- share of the progress bar for waiting on the server

-- state: "idle" | "waiting" | "processing"
ns.scan = { state = "idle", progress = 0, eta = nil, elapsed = 0, message = "" }
local S = ns.scan

local frame = CreateFrame("Frame")
local ticker

local function timing()
    AHSnapshotDB.timing = AHSnapshotDB.timing or {}
    return AHSnapshotDB.timing
end

local function notify()
    if ns.UpdateUI then ns.UpdateUI() end
end

local function setState(state, message)
    S.state = state
    S.message = message or S.message
    notify()
end

local function stopTicker()
    if ticker then ticker:Cancel() ticker = nil end
end

local function reset(message)
    stopTicker()
    frame:UnregisterAllEvents()
    S.progress, S.eta = 0, nil
    setState("idle", message)
end

-- Aggregates listings per item: min unit price, total quantity, and the cheapest
-- 40 {unitPrice, qty} entries so consumers can compute robust prices.
local function addListing(items, itemID, unitPrice, qty)
    if not itemID or itemID == 0 or not unitPrice or unitPrice <= 0 or not qty or qty <= 0 then return end
    local e = items[itemID]
    if not e then
        e = { min = unitPrice, qty = 0, prices = {} }
        items[itemID] = e
    end
    if unitPrice < e.min then e.min = unitPrice end
    e.qty = e.qty + qty
    e.prices[#e.prices + 1] = { unitPrice, qty }
end

local function finish(items, count)
    local n = 0
    for _, e in pairs(items) do
        table.sort(e.prices, function(a, b) return a[1] < b[1] end)
        for i = #e.prices, 41, -1 do e.prices[i] = nil end
        n = n + 1
    end
    AHSnapshotDB.scans = AHSnapshotDB.scans or {}
    AHSnapshotDB.scans[realmKey()] = { time = time(), listings = count, items = items, source = "scan" }
    S.lastTime, S.lastListings, S.lastItems = time(), count, n
    reset(("Done: %d listings, %d distinct items. /reload (or log out) to write to disk."):format(count, n))
    S.progress = 1
    notify()
    say(S.message)
end

-- Reads listing i (1-based) as itemID, quantity, total buyout.
local function readModern(i)
    local info = { C_AuctionHouse.GetReplicateItemInfo(i - 1) }
    return info[17], info[3], info[10]
end

local function readLegacy(i)
    local _, _, qty, _, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
    local link = GetAuctionItemLink("list", i)
    return link and tonumber(link:match("item:(%d+)")), qty, buyout
end

local function process(total, read, waited)
    local items, count, index = {}, 0, 1
    local startedAt = GetTime()
    setState("processing", "Processing listings...")
    stopTicker()
    ticker = C_Timer.NewTicker(0, function()
        local last = math.min(index + BATCH - 1, total)
        for i = index, last do
            local itemID, qty, buyout = read(i)
            if buyout and buyout > 0 and qty and qty > 0 then
                addListing(items, itemID, math.floor(buyout / qty), qty)
                count = count + 1
            end
        end
        index = last + 1
        local done = (index - 1) / math.max(total, 1)
        local spent = GetTime() - startedAt
        S.progress = WAIT_SHARE + (1 - WAIT_SHARE) * done
        S.eta = done > 0 and spent * (1 - done) / done or nil
        S.elapsed = waited + spent
        notify()
        if index > total then
            stopTicker()
            timing().wait, timing().process = waited, spent
            timing().total = waited + spent
            finish(items, count)
        end
    end)
end

local function beginWaiting()
    local startedAt = GetTime()
    local expectWait = timing().wait or 5
    local expectProcess = timing().process or 10
    setState("waiting", "Waiting for the auction house...")
    stopTicker()
    ticker = C_Timer.NewTicker(0.25, function()
        local spent = GetTime() - startedAt
        S.elapsed = spent
        S.progress = WAIT_SHARE * math.min(spent / expectWait, 0.95)
        S.eta = math.max(expectWait - spent, 1) + expectProcess
        if spent > SERVER_TIMEOUT then
            reset("Timed out waiting for the auction house (full scans have a cooldown; try later).")
            say(S.message)
            return
        end
        notify()
    end)
    return startedAt
end

function ns.StartScan()
    if S.state ~= "idle" then say("scan already in progress") return end

    if C_AuctionHouse and C_AuctionHouse.ReplicateItems then
        if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
            say("open the auction house first") return
        end
        local startedAt = beginWaiting()
        frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
        frame:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
        frame:SetScript("OnEvent", function(_, event)
            if event == "AUCTION_HOUSE_CLOSED" then
                reset("Scan cancelled: auction house closed.")
                say(S.message)
            else
                frame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
                process(C_AuctionHouse.GetNumReplicateItems(), readModern, GetTime() - startedAt)
            end
        end)
        C_AuctionHouse.ReplicateItems()
    elseif QueryAuctionItems then
        local canQuery, canQueryAll = CanSendAuctionQuery()
        if not canQuery then say("cannot query right now, try again shortly") return end
        if not canQueryAll then say("full scan is on cooldown, try again later") return end
        local startedAt = beginWaiting()
        frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
        frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
        frame:SetScript("OnEvent", function(_, event)
            if event == "AUCTION_HOUSE_CLOSED" then
                reset("Scan cancelled: auction house closed.")
                say(S.message)
            else
                frame:UnregisterEvent("AUCTION_ITEM_LIST_UPDATE")
                process(GetNumAuctionItems("list"), readLegacy, GetTime() - startedAt)
            end
        end)
        QueryAuctionItems("", nil, nil, 0, false, 0, true)
    else
        say("no supported auction house API found; open the auction house first")
    end
end

-- Auctionator keeps only a minimum price per item (no depth), so imported entries are
-- flagged shallow=true and the companion estimates quantity cost as min * quantity.
function ns.AuctionatorAvailable()
    return Auctionator and Auctionator.Database and type(Auctionator.Database.db) == "table"
end

function ns.ImportAuctionator()
    if not ns.AuctionatorAvailable() then
        say("Auctionator is not loaded or has no price data yet.")
        return false
    end
    local items, count = {}, 0
    for key, data in pairs(Auctionator.Database.db) do
        local price = type(data) == "table" and tonumber(data.m)
        if price and price > 0 then
            -- keys are "itemID" or, for gear, "g:itemID:itemLevel"
            local id = tonumber(tostring(key):match("^(%d+)$") or tostring(key):match("^g:(%d+):"))
            if id then
                local e = items[id]
                if not e then
                    items[id] = { min = price, qty = 0, prices = { { price, 1 } } }
                    count = count + 1
                elseif price < e.min then
                    e.min = price
                    e.prices[1][1] = price
                end
            end
        end
    end
    if count == 0 then
        say("Auctionator has no prices to import. Run an Auctionator scan first.")
        return false
    end
    AHSnapshotDB.scans = AHSnapshotDB.scans or {}
    AHSnapshotDB.scans[realmKey()] = {
        time = time(), listings = count, items = items, source = "auctionator", shallow = true,
    }
    S.lastTime, S.lastListings, S.lastItems = time(), count, count
    S.message = ("Imported %d item prices from Auctionator."):format(count)
    notify()
    say(S.message .. " /reload (or log out) to write to disk.")
    return true
end

-- Remember what the saved scan looked like so the UI can show it on login.
function ns.LoadLastScanInfo()
    local sc = AHSnapshotDB.scans and AHSnapshotDB.scans[realmKey()]
    if sc then
        S.lastTime, S.lastListings, S.lastSource = sc.time, sc.listings, sc.source or "scan"
    end
end
