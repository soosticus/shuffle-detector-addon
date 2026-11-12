local _, ns = ...
local panel, summary, chart, rows
local MAX_HISTORY = 200

local function money(value)
    local sign = value < 0 and "-" or ""
    value = math.floor(math.abs(value) + 0.5)
    return ("%s%dg %ds %dc"):format(sign, math.floor(value / 10000), math.floor(value / 100) % 100, value % 100)
end

local function database()
    AHSnapshotDB.batchStats = AHSnapshotDB.batchStats or { nextId = 0, characters = {} }
    local db = AHSnapshotDB.batchStats
    local key = UnitGUID("player")
    if not key then return end
    db.characters[key] = db.characters[key] or { history = {} }
    return db, db.characters[key]
end

local function find(id)
    local _, character = database()
    if character then
        for _, batch in ipairs(character.history) do
            if batch.id == id then return batch end
        end
    end
end

function ns.BatchStatsEnsure(plan, state)
    if state.target == 0 then return end
    local db, character = database()
    if not character then return end
    local batch = find(state.statsId)
    if not batch or batch.closed then
        db.nextId = db.nextId + 1
        batch = { id = db.nextId, recipe = plan.recipe, item = plan.item, started = time(), target = state.target,
            crafts = 0, items = 0, available = 0, makes = plan.makes or 1, cost = 0, income = 0,
            manualCost = 0, manualIncome = 0, purchases = 0, sold = 0 }
        if plan.estimate then
            batch.estimate = { cost = plan.estimate.cost, income = plan.estimate.income }
        end
        character.history[#character.history + 1] = batch
        state.statsId = batch.id
        while #character.history > MAX_HISTORY do table.remove(character.history, 1) end
    end
    return batch
end

function ns.BatchStatsClose(state)
    local batch = find(state.statsId)
    if batch and batch.sale then
        ns.say("Batch has an unconfirmed vendor sale. Check bags and reload/resolve it before starting a new batch.")
        return false
    end
    if batch then batch.closed = time() end
    state.statsId = nil
    return true
end

function ns.BatchStatsPurchase(purchase)
    local batch = find(purchase.batch)
    if not batch then return end
    if type(purchase.total) ~= "number" then
        batch.incomplete = true
        ns.log("statistics: purchase cost unavailable (reservation from an older addon)")
        return
    end
    batch.cost = batch.cost + purchase.total
    batch.purchases = batch.purchases + purchase.qty
end

function ns.BatchStatsCraft(state, plan)
    local batch = ns.BatchStatsEnsure(plan, state)
    if not batch then return end
    local makes = plan.makes or 1
    batch.crafts, batch.items, batch.available = batch.crafts + 1, batch.items + makes, batch.available + makes
end

local function count(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    return fn and fn(id) or 0
end

-- units: how many of the item the press is selling in total (several stacks), default the stack at bag/slot.
function ns.BatchStatsSale(bag, slot, units)
    local _, character = database()
    if not character then return end
    local batch = character.history[#character.history]
    if not batch or batch.closed or batch.available == 0 or batch.sale then return end
    local c = C_Container
    local link = ((c and c.GetContainerItemLink) or GetContainerItemLink)(bag, slot)
    local id = link and tonumber(link:match("item:(%d+)"))
    if id ~= batch.item then return end
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local price = info and select(11, info(id))
    if type(price) ~= "number" then
        batch.incomplete = true
        ns.log("statistics: vendor sell price unavailable")
        return
    end
    local before = count(id)
    batch.sale = { before = before, gold = GetMoney(), price = price, at = GetTime(), left = units or nil }
    local sale = batch.sale
    C_Timer.After(5, function()
        if batch.sale == sale then
            batch.incomplete, batch.sale = true, nil
            ns.log("statistics: vendor sale unconfirmed; check gold/bags and enter income manually if needed")
            ns.say("Vendor sale statistics could not be confirmed. Check gold/bags and record verified income in Analytics if needed.")
            ns.RefreshBatchAnalytics()
        end
    end)
end

function ns.BatchStatsSaleFailed()
    local _, character = database()
    local batch = character and character.history[#character.history]
    if batch then batch.sale = nil end
end

function ns.BatchStatsDisenchanted(item)
    local _, character = database()
    local batch = character and character.history[#character.history]
    if batch and not batch.closed and item == batch.item then
        batch.available = math.max(0, batch.available - 1)
    end
end

function ns.BatchStatsTotals(batch)
    local cost, income = batch.cost + batch.manualCost, batch.income + batch.manualIncome
    return cost, income, income - cost, batch.items > 0 and (income - cost) / batch.items or nil
end

function ns.BatchStatsText(state)
    local batch = find(state.statsId)
    if not batch then return "Statistics start with a saved batch target." end
    local cost, income, net, average = ns.BatchStatsTotals(batch)
    local text = ("Spent %s | Income %s\nCash net %s | Avg/item %s"):format(
        money(cost), money(income), money(net), average and money(average) or "n/a")
    if batch.estimate then
        -- The whole batch target, with reagents at the saved price limits (the most the snatcher pays).
        local crafts = math.max(batch.crafts, math.ceil(batch.target / batch.makes))
        local plan = ns.plan
        local limitCost = plan and plan.item == batch.item and ns.SnatchLimitCostPerCraft and ns.SnatchLimitCostPerCraft()
        local cost = limitCost or batch.estimate.cost
        local profit = batch.estimate.income - cost
        text = text .. ("\nBatch of %d crafts, %s: cost %s%s | value %s\nEstimated profit %s%s (%s/item)"):format(
            crafts, limitCost and "reagents at your limits" or "market prices (set every limit to use them)",
            limitCost and "up to " or "", money(cost * crafts), money(batch.estimate.income * crafts),
            limitCost and "at least " or "", money(profit * crafts), money(profit / batch.makes))
    else
        text = text .. "\nEstimated profit: resend a priced plan."
    end
    return text .. (batch.incomplete and " [incomplete]" or "")
end

local function text(parent, x, y, width)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", x, y)
    label:SetWidth(width)
    label:SetJustifyH("LEFT")
    return label
end

local function button(parent, label, x, y, fn)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(130, 24)
    b:SetPoint("TOPLEFT", x, y)
    b:SetText(label)
    b:SetScript("OnClick", fn)
    return b
end

function ns.RefreshBatchAnalytics()
    if ns.RefreshBatchStatisticsDisplay then ns.RefreshBatchStatisticsDisplay() end
    if not panel or not panel:IsShown() then return end
    local _, character = database()
    local history = character and character.history or {}
    local cost, income, items = 0, 0, 0
    for _, batch in ipairs(history) do
        local spent, earned = ns.BatchStatsTotals(batch)
        cost, income, items = cost + spent, income + earned, items + batch.items
    end
    summary:SetText(("This character: %d retained batches (max %d)\nSpent %s | Income %s | Cash net %s | Avg/item %s"):format(
        #history, MAX_HISTORY, money(cost), money(income), money(income - cost),
        items > 0 and money((income - cost) / items) or "n/a"))
    local last = math.max(0, #history - (panel.historyOffset or 0))
    local first = math.max(1, last - 15)
    local maxCash, maxNet, cumulative = 1, 1, 0
    local points = {}
    for i = first, last do
        local spent, earned, net = ns.BatchStatsTotals(history[i])
        cumulative = cumulative + net
        maxCash, maxNet = math.max(maxCash, spent, earned), math.max(maxNet, math.abs(cumulative))
        points[#points + 1] = { spent, earned, cumulative }
    end
    for i = 1, 16 do
        local bars, point = chart[i], points[i]
        for _, bar in ipairs(bars) do bar:Hide() end
        if point then
            for j = 1, 2 do
                bars[j]:SetSize(12, math.max(1, point[j] / maxCash * 90))
                bars[j]:Show()
            end
            bars[3]:SetSize(22, math.max(1, math.abs(point[3]) / maxNet * 50))
            bars[3]:ClearAllPoints()
            bars[3]:SetPoint(point[3] >= 0 and "BOTTOMLEFT" or "TOPLEFT", panel, "TOPLEFT", 20 + (i - 1) * 35, -290)
            bars[3]:SetColorTexture(point[3] >= 0 and 0.2 or 0.9, point[3] >= 0 and 0.8 or 0.25, 0.3, 1)
            bars[3]:Show()
        end
    end
    local lines = { "Batches (newest first): recipe | crafts | cash net | avg/item" }
    for i = last, math.max(1, last - 5), -1 do
        local batch = history[i]
        local _, _, net, average = ns.BatchStatsTotals(batch)
        lines[#lines + 1] = ("#%d %s %s %s | %d | %s | %s%s"):format(
            batch.id, date("%m/%d", batch.started), batch.closed and "Closed" or "Active", batch.recipe, batch.crafts, money(net),
            average and money(average) or "n/a", batch.incomplete and " [incomplete]" or "")
    end
    rows:SetText(table.concat(lines, "\n"))
end

function ns.ToggleBatchAnalytics()
    if not panel then
        panel = CreateFrame("Frame", "ShuffleDetectorAnalytics", UIParent, "BasicFrameTemplateWithInset")
        panel:SetSize(600, 650)
        panel:SetPoint("CENTER")
        panel:SetMovable(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        panel:SetClampedToScreen(true)
        text(panel, 12, -30, 560):SetText("ShuffleDetector - batch analytics")
        summary = text(panel, 12, -55, 570)
        text(panel, 12, -100, 570):SetText("Cost (red) / income (green) per batch; oldest to newest, up to 16")
        text(panel, 12, -225, 570):SetText("Cumulative cash net across displayed batches; zero at chart midpoint")
        local zero = panel:CreateTexture(nil, "ARTWORK")
        zero:SetSize(560, 1)
        zero:SetPoint("TOPLEFT", 20, -290)
        zero:SetColorTexture(0.6, 0.6, 0.6, 1)
        chart = {}
        for i = 1, 16 do
            chart[i] = {}
            for j = 1, 3 do
                local bar = panel:CreateTexture(nil, "ARTWORK")
                bar:SetPoint("BOTTOMLEFT", panel, "TOPLEFT", 20 + (i - 1) * 35 + (j == 2 and 14 or 0), -210)
                bar:SetColorTexture(j == 1 and 0.9 or 0.2, j == 1 and 0.25 or 0.8, 0.3, 1)
                chart[i][j] = bar
            end
        end
        rows = text(panel, 12, -365, 570)
        text(panel, 12, -475, 570):SetText("Cash net is not economic profit: existing materials and unsold loot are excluded.\nAH proceeds are manual. Trends do not prove income improvement caused by this addon.")
        local amount = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        panel.amount = amount
        amount:SetSize(140, 24)
        amount:SetPoint("TOPLEFT", 20, -550)
        amount:SetAutoFocus(false)
        amount:SetMaxLetters(40)
        text(panel, 12, -510, 570):SetText("Add verified untracked amounts; never re-enter auto-tracked totals.")
        text(panel, 12, -530, 570):SetText("Amount (g/s/c)                          Batch ID (blank = active)")
        local batchId = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        batchId:SetSize(100, 24)
        batchId:SetPoint("TOPLEFT", 200, -550)
        batchId:SetAutoFocus(false)
        batchId:SetMaxLetters(12)
        panel.batchId = batchId
        local function selectedBatch()
            local id = batchId:GetText()
            if id and id ~= "" then return find(tonumber(id)) end
            local _, character = database()
            local batch = character and character.history[#character.history]
            return batch and not batch.closed and batch or nil
        end
        local function adjust(kind)
            local value = ns.SnatchParseMoney(amount:GetText())
            local batch = selectedBatch()
            if not value or value <= 0 or not batch then
                ns.say("Enter a positive amount and a valid batch ID, or leave the ID blank for an active batch.")
                return
            end
            batch[kind] = batch[kind] + value
            batch.lastAdjustment = { kind = kind, value = value }
            amount:SetText("")
            ns.RefreshBatchAnalytics()
        end
        button(panel, "Add cost", 20, -585, function() adjust("manualCost") end)
        button(panel, "Add income", 170, -585, function() adjust("manualIncome") end)
        button(panel, "Undo last entry", 320, -585, function()
            local batch = selectedBatch()
            if not batch or not batch.lastAdjustment then
                ns.say("No manual entry to undo in the selected batch.")
                return
            end
            local entry = batch.lastAdjustment
            batch[entry.kind], batch.lastAdjustment = batch[entry.kind] - entry.value, nil
            ns.RefreshBatchAnalytics()
        end)
        button(panel, "Older batches", 20, -620, function()
            local _, character = database()
            local size = character and #character.history or 0
            panel.historyOffset = math.min(math.max(0, size - 1), (panel.historyOffset or 0) + 6)
            ns.RefreshBatchAnalytics()
        end)
        button(panel, "Newer batches", 170, -620, function()
            panel.historyOffset = math.max(0, (panel.historyOffset or 0) - 6)
            ns.RefreshBatchAnalytics()
        end)
        panel:SetScript("OnShow", ns.RefreshBatchAnalytics)
        panel:Hide()
    end
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local _, character = database()
        local batch = character and character.history[#character.history]
        if batch and batch.sale then
            batch.incomplete, batch.sale = true, nil
            ns.say("Statistics restored an unconfirmed vendor sale. Check income and record it manually in Analytics if needed.")
        end
        if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
            local settings = CreateFrame("Frame")
            text(settings, 16, -20, 550):SetText("ShuffleDetector statistics: confirmed cash flow and separate plan estimates.")
            button(settings, "Open analytics", 16, -60, ns.ToggleBatchAnalytics)
            local category = Settings.RegisterCanvasLayoutCategory(settings, "ShuffleDetector")
            Settings.RegisterAddOnCategory(category)
        end
    else
        local _, character = database()
        local batch = character and character.history[#character.history]
        if batch and batch.sale then
            local sale = batch.sale
            local removed = math.max(0, sale.before - count(batch.item))
            local sold = math.min(batch.available, removed)
            if sold > 0 and GetMoney() - sale.gold == removed * sale.price then
                batch.income, batch.sold = batch.income + sold * sale.price, batch.sold + sold
                batch.available = batch.available - sold
                -- A multi-stack sale can arrive over several bag updates; keep counting until all of it is in.
                sale.left = sale.left and sale.left - removed
                if sale.left and sale.left > 0 and batch.available > 0 then
                    sale.before, sale.gold = count(batch.item), GetMoney()
                else
                    batch.sale = nil
                end
            end
        end
    end
    ns.RefreshBatchAnalytics()
end)
