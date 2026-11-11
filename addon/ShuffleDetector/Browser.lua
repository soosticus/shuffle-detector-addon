local _, ns = ...
local panel, detail, summary, countLabel, professionButton, exitButton, knownButton, amount, searchBox
local rows, results, info, selected, batch, calculationError = {}, {}, {}, nil, nil, nil
local options, page, mode = { knownOnly = true }, 1, "crafts"
local PAGE_SIZE = 12

local function money(value)
    if value == nil then return "unknown" end
    local n = math.floor(math.abs(value) + 0.5)
    return (value < 0 and "-" or "") .. ("%dg %ds %dc"):format(
        math.floor(n / 10000), math.floor(n / 100) % 100, n % 100)
end

local function itemName(id)
    local item = type(AHSnapshotDB.items) == "table" and AHSnapshotDB.items[id]
    return (type(item) == "table" and item.name) or ("Item " .. tostring(id))
end

local function current()
    for _, result in ipairs(results) do
        if result.recipe.key == selected then return result end
    end
end

local function details()
    local result = current()
    if not result then
        detail:SetText("No matching item-producing recipes.\n\nOpen your profession windows to record recipes, then click Refresh. Recipes missing products or complete reagent data cannot be evaluated.")
        return
    end
    local recipe = result.recipe
    local lines = {
        recipe.name .. " (" .. recipe.profession .. ")",
        recipe.known and "Learned by this character" or "Unlearned: browse only; skill/source requirements unverified",
        ("Makes %d per craft; %d seconds assumed crafting time"):format(recipe.makes, 30),
        "",
        "Per craft (estimates, rounded to copper)",
        "Cost: " .. money(result.cost),
        "Best enabled exit: " .. (result.exit or "unknown") .. "; net: " .. money(result.net),
        "Profit: " .. money(result.profit),
        "Casting-only profit/hour: " .. money(result.profitPerHour),
        "",
        "Reagents",
    }
    for _, line in ipairs(result.reagents) do
        lines[#lines + 1] = ("%d x %s: %s (%s)"):format(line.qty, itemName(line.item), money(line.total), line.source)
        local quote = info.quotes and info.quotes[line.item]
        if quote then
            lines[#lines + 1] = "  AH: " .. (quote.reason or "commodity estimate")
                .. (quote.rawAge ~= nil and ("; raw age " .. quote.rawAge .. " (units unknown)") or "")
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Exit estimates (5% AH fee assumed)"
    for _, exit in ipairs(result.exits) do
        lines[#lines + 1] = exit.label .. ": " .. (exit.net ~= nil and money(exit.net) or (exit.reason or "unknown"))
    end
    lines[#lines + 1] = "No trusted disenchant baseline loaded; observations are not promoted automatically."
    if calculationError then
        lines[#lines + 1] = "\nCalculator: " .. calculationError
    elseif batch then
        lines[#lines + 1] = ("\nBatch: %d crafts / %d finished items"):format(batch.crafts, batch.items)
        lines[#lines + 1] = "Cost: " .. money(batch.cost) .. "; net: " .. money(batch.revenue) .. "; profit: " .. money(batch.profit)
        if batch.capped then lines[#lines + 1] = "Budget search capped at 100000 crafts." end
        if batch.transferReason then lines[#lines + 1] = batch.transferReason end
        for _, purchase in ipairs(batch.purchases) do
            lines[#lines + 1] = ("%d x %s: %s (%s)"):format(
                purchase.qty, itemName(purchase.item), money(purchase.total), purchase.source)
            if purchase.prepare then lines[#lines + 1] = "  Includes raw items to prepare a reagent; extra craft time is not included." end
        end
        lines[#lines + 1] = "Shopping quantities are requirements, not confirmed available AH stock."
    end
    lines[#lines + 1] = "\nRead-only preview: selection does not change your active shuffle, purchase caps or batch."
    detail:SetText(table.concat(lines, "\n"))
    detail:GetParent():SetHeight(math.max(425, detail:GetStringHeight() + 16))
end

local function render()
    local pages = math.max(1, math.ceil(#results / PAGE_SIZE))
    page = math.max(1, math.min(page, pages))
    for i, button in ipairs(rows) do
        local result = results[(page - 1) * PAGE_SIZE + i]
        if result then
            button.key = result.recipe.key
            button:SetText((button.key == selected and "> " or "") .. result.recipe.name
                .. "\n" .. money(result.profit) .. " / craft - " .. (result.exit or "unknown"))
            button:Show()
        else
            button:Hide()
        end
    end
    countLabel:SetText(("%d recipes; page %d/%d; %d incomplete records skipped"):format(
        #results, page, pages, info.skipped or 0))
    details()
end

local function refresh()
    options.search = searchBox:GetText()
    local err
    results, err, info = ns.PlannerResults(options)
    info, results = info or {}, results or {}
    batch, calculationError = nil, nil
    if not current() then selected = results[1] and results[1].recipe.key end
    summary:SetText(err or ("Character: " .. ns.charKey() .. ". Click Refresh after scans or recording recipes."))
    professionButton:SetText(options.profession or "All professions")
    exitButton:SetText(options.exit or "Best exit")
    knownButton:SetText(options.knownOnly and "Learned only" or "Learned + unlearned")
    render()
end

local function text(parent, value, x, y, width)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", x, y)
    label:SetWidth(width)
    label:SetJustifyH("LEFT")
    label:SetText(value)
    return label
end

local function button(parent, caption, x, y, width, fn)
    local widget = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    widget:SetSize(width, 26)
    widget:SetPoint("TOPLEFT", x, y)
    widget:SetText(caption)
    widget:SetScript("OnClick", fn)
    return widget
end

function ns.TogglePlanner()
    if panel then
        if panel:IsShown() then panel:Hide() else panel:Show(); refresh() end
        return
    end
    panel = CreateFrame("Frame", "ShuffleDetectorBrowser", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(960, 660)
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel.TitleText:SetText("ShuffleDetector - in-game preview")
    professionButton = button(panel, "All professions", 15, -38, 160, function()
        local nextProfession
        if not options.profession then nextProfession = (info.professions or {})[1]
        else
            for i, name in ipairs(info.professions or {}) do
                if name == options.profession then nextProfession = info.professions[i + 1]; break end
            end
        end
        options.profession, page = nextProfession, 1
        refresh()
    end)
    knownButton = button(panel, "Learned only", 180, -38, 165, function()
        options.knownOnly, page = not options.knownOnly, 1
        refresh()
    end)
    local exits = { "Disenchant", "Sell on AH", "Vendor" }
    exitButton = button(panel, "Best exit", 350, -38, 120, function()
        local nextExit = exits[1]
        for i, label in ipairs(exits) do
            if label == options.exit then nextExit = exits[i + 1]; break end
        end
        options.exit, page = nextExit, 1
        refresh()
    end)
    searchBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    searchBox:SetSize(265, 26)
    searchBox:SetPoint("TOPLEFT", 485, -38)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(100)
    searchBox:SetText("")
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); page = 1; refresh() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    button(panel, "Refresh / search", 765, -38, 175, refresh)
    summary = text(panel, "", 15, -72, 925)
    text(panel, "Shallow estimates only: stock, exactness and age units unknown. Gear AH prices gated; vendor quotes may be stale or character-specific.", 15, -93, 925)
    for i = 1, PAGE_SIZE do
        rows[i] = button(panel, "", 15, -125 - (i - 1) * 37, 365, function(self)
            selected, batch, calculationError = self.key, nil, nil
            render()
        end)
        rows[i]:SetHeight(35)
    end
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetSize(520, 425)
    scroll:SetPoint("TOPLEFT", 405, -125)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(520, 425)
    detail = text(child, "", 0, 0, 510)
    detail:SetWordWrap(true)
    scroll:SetScrollChild(child)
    text(panel, "Batch calculator (crafts or budget in copper, e.g. 5000)", 405, -565, 520)
    amount = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    amount:SetSize(120, 26)
    amount:SetPoint("TOPLEFT", 410, -585)
    amount:SetAutoFocus(false)
    amount:SetMaxLetters(12)
    amount:SetText("1")
    amount:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local modeButton
    modeButton = button(panel, "Crafts", 545, -585, 110, function()
        mode = mode == "crafts" and "budget" or "crafts"
        modeButton:SetText(mode == "crafts" and "Crafts" or "Budget (c)")
        batch, calculationError = nil, nil
        details()
    end)
    button(panel, "Calculate", 665, -585, 120, function()
        amount:ClearFocus()
        batch, calculationError = ns.CalculateBatch(current(), mode, tonumber(amount:GetText()))
        details()
    end)
    button(panel, "< Previous", 15, -590, 120, function() page = page - 1; render() end)
    button(panel, "Next >", 145, -590, 120, function() page = page + 1; render() end)
    countLabel = text(panel, "", 15, -630, 925)
    panel:Show()
    refresh()
end
