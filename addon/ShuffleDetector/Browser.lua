local _, ns = ...
local panel, detail, scroll, summary, providerLabel, countLabel, professionMenu, exitMenu, recipeMenu, amount, searchBox
local rows, results, info, selected, batch, calculationError = {}, {}, {}, nil, nil, nil
local options, page, mode = { knownOnly = true }, 1, "crafts"
local PAGE_SIZE = 10
local refresh, render, menuCover

local function money(value)
    if value == nil then return "Not priced" end
    local n = math.floor(math.abs(value) + 0.5)
    local gold, silver, copper = math.floor(n / 10000), math.floor(n / 100) % 100, n % 100
    return (value < 0 and "-" or "") .. (gold > 0 and (gold .. "g ") or "")
        .. ((gold > 0 or silver > 0) and (silver .. "s ") or "") .. copper .. "c"
end

local function heading(value) return "|cffffcc00" .. value .. "|r" end

local function itemName(id)
    local item = type(AHSnapshotDB.items) == "table" and AHSnapshotDB.items[id]
    return (type(item) == "table" and item.name) or ("Item " .. tostring(id))
end

local function current()
    for _, result in ipairs(results) do
        if result.recipe.key == selected then return result end
    end
end

local function quoteReason(quote)
    local reasons = {
        ["unsupported-item-identity"] = "AH value not verified for this item type",
        ["unsupported-provider-version"] = "AH provider version not verified (see banner)",
        ["unsupported-client"] = "Client version not verified (see banner)",
        ["unavailable"] = "Auctionator price API unavailable",
        ["no-price"] = "No Auctionator quote; scan and Refresh",
        ["invalid-price"] = "Auctionator returned an invalid price (see log)",
        ["provider-error"] = "Auctionator API error (see log)",
        ["client-identity-error"] = "Cannot read client version (see log)",
    }
    return reasons[quote.reason] or quote.reason or "AH estimate"
end

local function blocked(result)
    if result.cost == nil then return "Missing reagent prices - see breakdown" end
    if result.net == nil then return "No priced exit for this filter - see breakdown" end
end

local function details()
    local result = current()
    if not result then
        detail:SetText("No matching item-producing recipes.\n\nOpen your profession windows to record recipes, then click Refresh. Try another profession or recipe filter. Records without a product or complete reagents cannot be ranked.")
    else
        local recipe = result.recipe
        local lines = {
            heading(recipe.name),
            recipe.profession .. " / " .. (recipe.known and "Learned recipe" or "Unlearned pattern"),
            recipe.known and "Preview a shuffle you can craft; this row does not start it."
                or "Pattern to learn later. This character cannot craft it yet; acquisition requirements are not verified.",
            ("Makes %d per craft; 30s assumed craft time."):format(recipe.makes),
            "",
            heading("Estimate per craft"),
            "Materials: " .. money(result.cost),
        }
        if result.net ~= nil then
            lines[#lines + 1] = (result.exit or "Exit") .. " returns: " .. money(result.net)
        else
            lines[#lines + 1] = "Sale return: no enabled exit can be valued."
        end
        if result.profit ~= nil then
            lines[#lines + 1] = "Profit: " .. money(result.profit)
            lines[#lines + 1] = "Casting-only profit/hour: " .. money(result.profitPerHour)
        else
            lines[#lines + 1] = blocked(result)
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = heading("Materials / total per craft")
        for _, line in ipairs(result.reagents) do
            lines[#lines + 1] = ("%d x %s: %s"):format(line.qty, itemName(line.item), money(line.total))
            if line.total ~= nil then
                lines[#lines + 1] = "  " .. line.source
                if line.source == "Craft from raw" then
                    lines[#lines + 1] = ("  Prepare from %d x %s (%s)"):format(
                        line.qty * line.rawQty, itemName(line.rawItem), line.rawSource)
                end
            else
                local quote = info.quotes and info.quotes[line.item]
                lines[#lines + 1] = "  " .. (quote and quoteReason(quote) or "No recorded purchase price")
                lines[#lines + 1] = "  No usable vendor/raw alternative recorded."
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = heading("Exit comparison / total per craft")
        for _, exit in ipairs(result.exits) do
            local reason
            if exit.label == "Disenchant" then
                reason = "Unavailable: no trusted yield baseline yet"
            elseif exit.reason == "no price" then
                local quote = info.quotes and info.quotes[recipe.item]
                reason = quote and quoteReason(quote) or "No Auctionator quote"
            elseif exit.reason == "unknown vendor price" then
                reason = "Vendor sell price not recorded"
            elseif exit.reason == "cannot be sold to a vendor" then
                reason = "Cannot be sold to a vendor"
            else
                reason = exit.reason
            end
            lines[#lines + 1] = exit.label .. ": " .. (exit.net ~= nil and money(exit.net) or reason or "Not priced")
        end
        lines[#lines + 1] = "AH sales assume 5% fee. Gear AH values and DE yields remain gated."
        if calculationError then
            lines[#lines + 1] = "\n" .. heading("Calculator") .. "\n" .. calculationError
        elseif batch then
            lines[#lines + 1] = ("\n%s\n%d crafts / %d finished items"):format(heading("Batch estimate"), batch.crafts, batch.items)
            lines[#lines + 1] = "Materials: " .. money(batch.cost) .. "; returns: " .. money(batch.revenue)
            lines[#lines + 1] = "Profit: " .. money(batch.profit)
            if batch.capped then lines[#lines + 1] = "Budget search capped at 100000 crafts." end
            if batch.transferReason then lines[#lines + 1] = batch.transferReason end
            for _, purchase in ipairs(batch.purchases) do
                lines[#lines + 1] = ("%d x %s: %s (%s)"):format(
                    purchase.qty, itemName(purchase.item), money(purchase.total), purchase.source)
                if purchase.prepare then lines[#lines + 1] = "  Raw preparation needed; extra craft time is not included." end
            end
            lines[#lines + 1] = "Required quantities, not confirmed auction stock."
        end
        detail:SetText(table.concat(lines, "\n"))
    end
    detail:GetParent():SetHeight(math.max(400, detail:GetStringHeight() + 16))
end

render = function()
    local pages = math.max(1, math.ceil(#results / PAGE_SIZE))
    page = math.max(1, math.min(page, pages))
    for i, button in ipairs(rows) do
        local result = results[(page - 1) * PAGE_SIZE + i]
        if result then
            button.key = result.recipe.key
            button.nameText:SetText((button.key == selected and "> " or "") .. result.recipe.name)
            local subtitle = blocked(result)
            if not subtitle then
                local color = result.profit >= 0 and "|cff33ff99" or "|cffff7777"
                subtitle = color .. money(result.profit) .. " profit/craft|r - " .. result.exit
            end
            button.valueText:SetText(subtitle)
            button:Show()
        else
            button:Hide()
        end
    end
    countLabel:SetText(("%d recipes / page %d of %d. %d non-item or incomplete records omitted."):format(
        #results, page, pages, info.skipped or 0))
    details()
end

local function providerText(provider)
    if not provider then return "No provider status available." end
    if provider.ready then
        return "Auctionator " .. provider.normalizedVersion .. ": copper commodity estimates. Stock and age units unverified."
    end
    return "|cffff7777AH prices unavailable:|r " .. (provider.detail or quoteReason(provider))
end

refresh = function()
    options.search = searchBox:GetText()
    local err
    results, err, info = ns.PlannerResults(options)
    info, results = info or {}, results or {}
    batch, calculationError = nil, nil
    if not current() then selected = results[1] and results[1].recipe.key end
    local meaning = options.knownOnly and "Learned recipes: shuffle previews, not action buttons."
        or (options.unlearnedOnly and "Unlearned patterns: compare recipes to learn later; not craftable yet."
            or "All recipes: learned shuffles and unlearned patterns; select a row for details.")
    summary:SetText(err or (ns.charKey() .. " - " .. meaning))
    providerLabel:SetText(providerText(info.provider))
    professionMenu:SetText((options.profession or "All professions") .. " v")
    recipeMenu:SetText((options.knownOnly and "Learned recipes" or (options.unlearnedOnly and "Unlearned patterns" or "All recipes")) .. " v")
    exitMenu:SetText((options.exit or "Best available exit") .. " v")
    scroll:SetVerticalScroll(0)
    render()
end

local function text(parent, value, x, y, width, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
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

-- A small anchored dropdown avoids depending on either client's menu API.
local function dropdown(x, width, entries)
    local selector
    selector = button(panel, "", x, -60, width, function()
        if not menuCover then
            menuCover = CreateFrame("Frame", nil, UIParent)
            menuCover:SetAllPoints(UIParent)
            menuCover:SetFrameStrata("FULLSCREEN_DIALOG")
            menuCover:EnableMouse(true)
            menuCover:SetScript("OnMouseDown", function(self) self:Hide() end)
        end
        if menuCover.popup then menuCover.popup:Hide() end
        local choices = entries()
        local popup = selector.popup
        if not popup then
            popup = CreateFrame("Frame", nil, menuCover)
            popup:SetPoint("TOPLEFT", selector, "BOTTOMLEFT", 0, -2)
            popup:EnableMouse(true)
            popup.buttons = {}
            local background = popup:CreateTexture(nil, "BACKGROUND")
            background:SetAllPoints()
            background:SetColorTexture(0.06, 0.06, 0.06, 1)
            selector.popup = popup
        end
        menuCover.popup = popup
        popup:SetSize(math.max(width, 280), #choices * 30 + 8)
        for _, pick in ipairs(popup.buttons) do pick:Hide() end
        for i, choice in ipairs(choices) do
            local entry = choice
            local pick = popup.buttons[i]
            if not pick then
                pick = button(popup, "", 4, -4 - (i - 1) * 30, math.max(width, 280) - 8, function(self)
                    if self.choice.disabled then return end
                    menuCover:Hide()
                    self.choice.choose()
                    page = 1
                    refresh()
                end)
                popup.buttons[i] = pick
            end
            pick.choice = entry
            pick:SetText(entry.text)
            if entry.disabled then pick:Disable() else pick:Enable() end
            pick:Show()
        end
        popup:Show()
        menuCover:Show()
    end)
    return selector
end

function ns.TogglePlanner()
    if panel then
        if panel:IsShown() then panel:Hide() else panel:Show(); refresh() end
        return
    end
    panel = CreateFrame("Frame", "ShuffleDetectorBrowser", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(980, 710)
    panel:SetPoint("CENTER")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetScript("OnHide", function() if menuCover then menuCover:Hide() end end)
    panel.TitleText:SetText("ShuffleDetector - read-only recipe browser")
    text(panel, "Profession", 15, -40, 175, "GameFontNormal")
    text(panel, "Recipes", 200, -40, 180, "GameFontNormal")
    text(panel, "Sell crafted item via", 390, -40, 190, "GameFontNormal")
    text(panel, "Recipe name", 600, -40, 180, "GameFontNormal")
    professionMenu = dropdown(15, 175, function()
        local choices = { { text = "All professions", choose = function() options.profession = nil end } }
        for _, profession in ipairs(info.professions or {}) do
            local name = profession
            choices[#choices + 1] = { text = name, choose = function() options.profession = name end }
        end
        return choices
    end)
    recipeMenu = dropdown(200, 180, function()
        return {
            { text = "Learned recipes (shuffle previews)", choose = function() options.knownOnly, options.unlearnedOnly = true, nil end },
            { text = "Unlearned patterns (learn later)", choose = function() options.knownOnly, options.unlearnedOnly = nil, true end },
            { text = "All recipes", choose = function() options.knownOnly, options.unlearnedOnly = nil, nil end },
        }
    end)
    exitMenu = dropdown(390, 195, function()
        return {
            { text = "Best available exit", choose = function() options.exit = nil end },
            { text = "Sell on AH (verified item types)", choose = function() options.exit = "Sell on AH" end },
            { text = "Vendor", choose = function() options.exit = "Vendor" end },
            { text = "Disenchant - no trusted yield data", disabled = true },
        }
    end)
    searchBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    searchBox:SetSize(200, 26)
    searchBox:SetPoint("TOPLEFT", 605, -60)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(100)
    searchBox:SetText("")
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); page = 1; refresh() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    button(panel, "Refresh / search", 825, -60, 140, refresh)
    summary = text(panel, "", 15, -98, 940)
    providerLabel = text(panel, "", 15, -124, 940)
    text(panel, "Recipe / estimated profit per craft", 15, -172, 375, "GameFontNormal")
    text(panel, "Recipe breakdown (scroll for exits and batch results)", 410, -172, 530, "GameFontNormal")
    for i = 1, PAGE_SIZE do
        rows[i] = CreateFrame("Button", nil, panel)
        rows[i]:SetSize(375, 39)
        rows[i]:SetPoint("TOPLEFT", 15, -195 - (i - 1) * 40)
        rows[i]:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        rows[i].nameText = text(rows[i], "", 5, -2, 365, "GameFontNormal")
        rows[i].valueText = text(rows[i], "", 5, -21, 365, "GameFontHighlightSmall")
        rows[i]:SetScript("OnClick", function(self)
            selected, batch, calculationError = self.key, nil, nil
            scroll:SetVerticalScroll(0)
            render()
        end)
    end
    scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetSize(530, 400)
    scroll:SetPoint("TOPLEFT", 410, -195)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(530, 400)
    detail = text(child, "", 0, 0, 520)
    detail:SetWordWrap(true)
    detail:SetSpacing(3)
    scroll:SetScrollChild(child)
    text(panel, "Batch calculator - requirement estimates only", 410, -610, 540, "GameFontNormal")
    amount = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    amount:SetSize(120, 26)
    amount:SetPoint("TOPLEFT", 415, -636)
    amount:SetAutoFocus(false)
    amount:SetMaxLetters(12)
    amount:SetText("1")
    amount:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local modeButton
    modeButton = button(panel, "Crafts", 550, -636, 115, function()
        mode = mode == "crafts" and "budget" or "crafts"
        modeButton:SetText(mode == "crafts" and "Crafts" or "Budget (copper)")
        batch, calculationError = nil, nil
        details()
    end)
    button(panel, "Calculate", 680, -636, 120, function()
        amount:ClearFocus()
        batch, calculationError = ns.CalculateBatch(current(), mode, tonumber(amount:GetText()))
        details()
        scroll:SetVerticalScroll(math.max(0, detail:GetStringHeight() - 380))
    end)
    button(panel, "< Previous", 15, -636, 120, function() page = page - 1; render() end)
    button(panel, "Next >", 145, -636, 120, function() page = page + 1; render() end)
    countLabel = text(panel, "", 15, -684, 940, "GameFontHighlightSmall")
    panel:Show()
    refresh()
end
