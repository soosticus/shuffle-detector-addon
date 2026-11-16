local _, ns = ...
local panel, detail, scroll, summary, providerLabel, countLabel, professionMenu, exitMenu, recipeMenu, amount, searchBox, useButton, costButton
local rows, results, info, selected, batch, calculationError, activationNotice = {}, {}, {}, nil, nil, nil, nil
local options, page, mode = { knownOnly = true }, 1, "crafts"
local PAGE_SIZE = 10
local PANEL_WIDTH, PANEL_HEIGHT = 980, 645
-- Docked padding: the professions window's CraftingPage rect includes the native header band,
-- so the browser starts below it and keeps a margin from the side and bottom borders.
local DOCK_TOP, DOCK_SIDE, DOCK_BOTTOM = 46, 10, 10
local refresh, render, menuCover
local stateReady = false
local materialCosts, costPanel = {}, nil
local MAX_CUSTOM_COST = 100000000000
-- Professions-window docking (shell page, side tab and state) via the ForeverCore addon.
local shell, dockTab, docked = nil, nil, false

-- The shared side-tab registry of the ForeverCore addon (the framework SkillUp Forever uses).
local function professionTabs()
    local core = _G.ForeverCore
    local api = core and core.ProfessionTabs
    if api and type(api.Register) == "function" and type(api.Select) == "function"
        and type(api.Selected) == "function" and type(api.ShowNative) == "function" then
        return api
    end
end

local function integer(n, low, high)
    return type(n) == "number" and n >= low and n <= high and n == math.floor(n)
end

local function boundedText(value, limit, optional)
    return (optional and value == nil) or (type(value) == "string" and #value <= limit)
end

local function validState(state)
    if type(state) ~= "table" or (state.materialCosts ~= nil and type(state.materialCosts) ~= "table") then return false end
    for id, cost in pairs(state.materialCosts or {}) do
        if not integer(id, 1, 10000000) or not integer(cost, 0, MAX_CUSTOM_COST) then return false end
    end
    return state.version == 1
        and boundedText(state.profession, 100, true)
        and boundedText(state.search, 100)
        and boundedText(state.selected, 300, true)
        and (state.recipes == "learned" or state.recipes == "unlearned" or state.recipes == "new" or state.recipes == "all")
        and (state.exit == nil or state.exit == "Vendor" or state.exit == "Sell on AH")
        and (state.mode == "crafts" or state.mode == "budget")
        and boundedText(state.amount, 12)
end

local function savedStates()
    if AHSnapshotDB.plannerByCharacter == nil then AHSnapshotDB.plannerByCharacter = {} end
    if type(AHSnapshotDB.plannerByCharacter) ~= "table" then
        ns.log("planner: invalid saved settings container; resetting browser settings")
        AHSnapshotDB.plannerByCharacter = {}
    end
    return AHSnapshotDB.plannerByCharacter
end

local function restoreState()
    local state = savedStates()[ns.charKey()]
    if state ~= nil and not validState(state) then
        ns.log("planner: invalid or unsupported saved settings for " .. ns.charKey() .. "; using browser defaults")
        state = nil
    end
    options = {
        knownOnly = not state or state.recipes == "learned",
        unlearnedOnly = state and state.recipes == "unlearned",
        newOnly = state and state.recipes == "new",
        profession = state and state.profession,
        exit = state and state.exit,
        search = state and state.search or "",
    }
    selected, mode = state and state.selected, state and state.mode or "crafts"
    materialCosts = {}
    for id, cost in pairs(state and state.materialCosts or {}) do materialCosts[id] = cost end
    return state and state.amount or "1"
end

local function saveState()
    if not stateReady then return end
    savedStates()[ns.charKey()] = {
        version = 1, profession = options.profession, search = searchBox:GetText(),
        recipes = options.knownOnly and "learned" or options.unlearnedOnly and "unlearned"
            or options.newOnly and "new" or "all",
        exit = options.exit, selected = selected, mode = mode, amount = amount:GetText(),
        materialCosts = materialCosts,
    }
end

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
        ["unsupported-item-identity"] = "No AH value for weapons/armor (suffix variants) or unrecorded items",
        ["unsupported-provider-version"] = "AH provider version not verified (see banner)",
        ["unavailable"] = "Auctionator price API unavailable (see banner)",
        ["no-price"] = "No Auctionator quote; scan and Refresh",
        ["invalid-price"] = "Auctionator returned an invalid price (see log)",
        ["provider-error"] = "Auctionator API error (see log)",
    }
    return reasons[quote.reason] or quote.reason or "AH estimate"
end

local function blocked(result)
    if result.cost == nil then return "Missing reagent prices - see breakdown" end
    if result.net == nil then return "No priced exit for this filter - see breakdown" end
end

-- The calculated batch, or one computed from the amount box so Set active shuffle
-- does not require pressing Calculate first.
local function activationBatch()
    if batch then return batch end
    local result = ns.PlannerBatchResult(current(), info, materialCosts)
    if not result or not amount then return nil end
    return (ns.CalculateBatch(result, mode, tonumber(amount:GetText())))
end

local function updateUseButton()
    if costButton then
        if current() then costButton:Enable() else costButton:Disable() end
    end
    if not useButton then return end
    local result = ns.PlannerBatchResult(current(), info, materialCosts)
    local allowed = ns.CanActivatePlannerResult and ns.CanActivatePlannerResult(result, activationBatch())
    if allowed then useButton:Enable() else useButton:Disable() end
end

local function details()
    local result = current()
    if not result then
        detail:SetText("No matching recipes.\n\nOpen your profession windows once to record recipes, then press Refresh / search, or change the filters.")
    else
        local recipe = result.recipe
        local lines = {
            heading(recipe.name),
            recipe.profession .. " / " .. (recipe.known and "Learned recipe"
                or not recipe.professionKnown and "Profession not learned" or "Unlearned pattern"),
            recipe.known and "Shuffle preview; nothing is crafted from here."
                or recipe.catalog and ("From the game's recipe data; no character has " .. recipe.profession .. ".")
                or recipe.learnedBy and not recipe.professionKnown and ("Learned by " .. recipe.learnedBy
                    .. "; this character does not have " .. recipe.profession .. ".")
                or recipe.learnedBy and ("Learned by " .. recipe.learnedBy .. "; not craftable by this character yet.")
                or not recipe.professionKnown and ("Recorded by another character; this character does not have "
                    .. recipe.profession .. ".")
                or "Pattern to learn later; not craftable yet.",
            ("Makes %d per craft; 30s assumed craft time."):format(recipe.makes),
        }
        if activationNotice then lines[#lines + 1] = "\n" .. activationNotice end
        lines[#lines + 1] = ""
        lines[#lines + 1] = heading("Per craft (market estimate)")
        lines[#lines + 1] = "Materials: " .. money(result.cost)
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
        lines[#lines + 1] = heading("Exits / total per craft")
        for _, exit in ipairs(result.exits) do
            local reason
            if exit.label == "Disenchant" then
                reason = "Not estimated: no verified disenchant yield table ships for this client yet"
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
        lines[#lines + 1] = "AH exits assume a 5% fee; weapons and armor get no AH value yet (suffix variants)."
        if calculationError then
            lines[#lines + 1] = "\n" .. heading("Calculator") .. "\n" .. calculationError
        elseif batch then
            lines[#lines + 1] = ("\n%s\n%d crafts / %d finished items"):format(heading("Batch estimate"), batch.crafts, batch.items)
            lines[#lines + 1] = "Materials: " .. money(batch.cost) .. "; returns: " .. money(batch.revenue)
            lines[#lines + 1] = "Profit: " .. money(batch.profit)
            local limited = ns.BatchLimitEstimate(result, batch, ns.SnatchPriceLimits and ns.SnatchPriceLimits(),
                info.context and info.context.refined)
            if limited and limited.cost then
                lines[#lines + 1] = ("At your price limits: materials up to %s; returns %s; profit at least %s"):format(
                    money(limited.cost), money(limited.value), money(limited.profit))
            elseif limited then
                local names = {}
                for _, id in ipairs(limited.missing) do names[#names + 1] = itemName(id) end
                lines[#lines + 1] = "No price limit saved for " .. table.concat(names, ", ")
                    .. "; set one in the shuffle window to estimate at your limits."
            end
            if batch.capped then lines[#lines + 1] = "Budget search capped at 100000 crafts." end
            if batch.transferReason then lines[#lines + 1] = batch.transferReason end
            for _, purchase in ipairs(batch.purchases) do
                lines[#lines + 1] = ("%d x %s: %s (%s)"):format(
                    purchase.qty, itemName(purchase.item), money(purchase.total), purchase.source)
                if purchase.prepare then lines[#lines + 1] = "  Raw preparation needed; extra craft time is not included." end
            end
            local used = {}
            for _, purchase in ipairs(batch.purchases) do
                if purchase.source == "Custom" then used[purchase.item] = true end
            end
            for _, reagent in ipairs(result.recipe.reagents) do
                local refined = info.context.refined[reagent.item]
                for _, id in ipairs({ reagent.item, refined and refined.raw }) do
                    if materialCosts[id] ~= nil and not used[id] then
                        lines[#lines + 1] = "Custom cost not used: " .. itemName(id) .. " (another source was chosen)."
                        used[id] = true
                    end
                end
            end
            lines[#lines + 1] = "Estimates only: custom costs never change rankings or purchase limits,"
            lines[#lines + 1] = "and quantities are not confirmed auction stock."
        end
        local batchResult = ns.PlannerBatchResult(result, info, materialCosts)
        local canActivate, activationReason = ns.CanActivatePlannerResult(batchResult, activationBatch())
        if not canActivate then
            lines[#lines + 1] = "\n" .. heading("Set active shuffle")
            lines[#lines + 1] = activationReason
        end
        detail:SetText(table.concat(lines, "\n"))
    end
    detail:GetParent():SetHeight(math.max(400, detail:GetStringHeight() + 16))
    updateUseButton()
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
    countLabel:SetText(("%d recipes - page %d/%d - %d incomplete records hidden"):format(
        #results, page, pages, info.skipped or 0))
    details()
end

local function providerText(provider)
    if not provider then return "No provider status available." end
    if provider.ready then
        return "Auctionator " .. provider.normalizedVersion .. " prices (lowest listing)."
    end
    return "|cffff7777AH prices unavailable:|r " .. (provider.detail or quoteReason(provider))
end

refresh = function()
    if costPanel then costPanel:Hide() end
    options.search = searchBox:GetText()
    local err
    results, err, info = ns.PlannerResults(options)
    info, results = info or {}, results or {}
    batch, calculationError, activationNotice = nil, nil, nil
    if not current() then selected = results[1] and results[1].recipe.key end
    for i, result in ipairs(results) do
        if result.recipe.key == selected then page = math.ceil(i / PAGE_SIZE); break end
    end
    saveState()
    local meaning = options.knownOnly and "Shuffle previews of learned recipes."
        or options.unlearnedOnly and "Unlearned patterns; not craftable yet."
        or options.newOnly and "Recipes from professions this character does not have."
        or "All learned and unlearned recipes."
    if ns.EnsureRecipeCatalog then
        ns.EnsureRecipeCatalog(function() if panel and panel:IsShown() then refresh() end end)
    end
    if ns.RecipeCatalogProgress and ns.RecipeCatalogProgress() then
        meaning = meaning .. " Reading other professions' recipes from the game..."
    end
    summary:SetText(err or (ns.charKey() .. " - " .. meaning))
    providerLabel:SetText(providerText(info.provider))
    professionMenu:SetText(options.profession or "All professions")
    recipeMenu:SetText(options.knownOnly and "Learned recipes" or options.unlearnedOnly and "Unlearned patterns"
        or options.newOnly and "Professions to learn" or "All recipes")
    exitMenu:SetText(options.exit or "Best available exit")
    scroll:SetVerticalScroll(0)
    render()
end

local function text(parent, value, x, y, width, style)
    local label = ns.UI.Label(parent, value, style == "small" and 11 or 12,
        style == "header" and ns.UI.colors.accent or style == "small" and ns.UI.colors.muted or nil)
    label:SetPoint("TOPLEFT", x, y)
    label:SetWidth(width)
    return label
end

local function button(parent, caption, x, y, width, fn)
    local widget = ns.UI.Button(parent, caption, width, 24)
    widget:SetPoint("TOPLEFT", x, y)
    widget:SetScript("OnClick", fn)
    return widget
end

-- A small anchored dropdown avoids depending on either client's menu API.
local function dropdown(x, width, entries)
    local selector = ns.UI.DropdownButton(panel, width, 24)
    selector:SetPoint("TOPLEFT", x, -32)
    selector:SetScript("OnClick", function()
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
            ns.UI.Skin(popup, ns.UI.colors.section)
            selector.popup = popup
        end
        menuCover.popup = popup
        local menuWidth = math.max(width, 280)
        popup:SetSize(menuWidth, #choices * 24 + 2)
        for _, pick in ipairs(popup.buttons) do pick:Hide() end
        for i, choice in ipairs(choices) do
            local pick = popup.buttons[i]
            if not pick then
                pick = ns.UI.MenuItem(popup, menuWidth - 2, 24)
                pick:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 24)
                pick:SetScript("OnClick", function(self)
                    if self.choice.disabled then return end
                    menuCover:Hide()
                    self.choice.choose()
                    page = 1
                    refresh()
                end)
                popup.buttons[i] = pick
            end
            pick.choice = choice
            pick:SetText(choice.text)
            pick:SetAccented(choice.selected)
            if choice.disabled then pick:Disable() else pick:Enable() end
            pick:Show()
        end
        popup:Show()
        menuCover:Show()
    end)
    return selector
end

local costItems, costIndex, costTitle, costEntry, costMessage = {}, 1

local function displayCostItem()
    local id = costItems[costIndex]
    costTitle:SetText(id and (itemName(id) .. " (item " .. id .. ")") or "No material selected")
    local cost = id and materialCosts[id]
    costEntry:SetText(cost ~= nil and ("%.0f"):format(cost) or "")
    costMessage:SetText(cost ~= nil and ("Custom: " .. money(cost) .. " per item.")
        or "Market/vendor estimate is used; enter whole copper to override.")
end

local function changeCost(clear)
    local id = costItems[costIndex]
    if not id then costMessage:SetText("Select a recipe with materials first."); return end
    local value
    if not clear then
        local textValue = costEntry:GetText()
        value = textValue:match("^%d+$") and tonumber(textValue)
        if not integer(value, 0, MAX_CUSTOM_COST) then
            costMessage:SetText("Enter a whole copper amount from 0 to 100000000000.")
            return
        end
    end
    materialCosts[id] = value
    saveState()
    batch, calculationError, activationNotice = nil, nil, nil
    displayCostItem()
    details()
end

local function showCosts()
    local result = current()
    if not result then return end
    costItems, costIndex = {}, 1
    local seen = {}
    for _, reagent in ipairs(result.recipe.reagents) do
        local refined = info.context.refined[reagent.item]
        for _, id in ipairs({ reagent.item, refined and refined.raw }) do
            if not seen[id] then costItems[#costItems + 1] = id; seen[id] = true end
        end
    end
    if not costPanel then
        costPanel = ns.UI.Window("ShuffleDetectorMaterialCosts", 470, 240, "Material costs", panel)
        costPanel:SetPoint("CENTER")
        costPanel:SetFrameStrata("DIALOG")
        costPanel:EnableMouse(true)
        costTitle = text(costPanel, "", 20, -32, 430, "header")
        button(costPanel, "< Previous material", 20, -58, 160, function()
            costIndex = (costIndex - 2) % #costItems + 1
            displayCostItem()
        end)
        button(costPanel, "Next material >", 190, -58, 160, function()
            costIndex = costIndex % #costItems + 1
            displayCostItem()
        end)
        text(costPanel, "Cost per item (whole copper)", 20, -96, 250)
        costEntry = ns.UI.EditBox(costPanel, 150, 24)
        costEntry:SetPoint("TOPLEFT", 25, -116)
        costEntry:SetMaxLetters(12)
        costEntry:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        button(costPanel, "Set cost", 190, -116, 105, function() changeCost(false) end)
        button(costPanel, "Use market", 305, -116, 135, function() changeCost(true) end)
        costMessage = text(costPanel, "", 20, -152, 430, "small")
        text(costPanel, "Batch estimates only; rankings and purchase limits are unchanged.", 20, -182, 430, "small")
        button(costPanel, "Done", 335, -206, 105, function() costPanel:Hide() end)
    end
    displayCostItem()
    costPanel:Show()
end

local function build()
    if panel then return end
    local savedAmount = restoreState()
    panel = ns.UI.Window("ShuffleDetectorBrowser", PANEL_WIDTH, PANEL_HEIGHT, "ShuffleDetector")
    panel:SetPoint("CENTER")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetScript("OnHide", function()
        saveState()
        if menuCover then menuCover:Hide() end
        if costPanel then costPanel:Hide() end
    end)
    professionMenu = dropdown(15, 175, function()
        local choices = { { text = "All professions", selected = options.profession == nil,
            choose = function() options.profession = nil end } }
        for _, profession in ipairs(info.professions or {}) do
            local name = profession
            choices[#choices + 1] = { text = name, selected = options.profession == name,
                choose = function() options.profession = name end }
        end
        return choices
    end)
    recipeMenu = dropdown(200, 180, function()
        return {
            { text = "Learned recipes (shuffle previews)", selected = options.knownOnly,
                choose = function() options.knownOnly, options.unlearnedOnly, options.newOnly = true, nil, nil end },
            { text = "Unlearned patterns (learn later)", selected = options.unlearnedOnly,
                choose = function() options.knownOnly, options.unlearnedOnly, options.newOnly = nil, true, nil end },
            { text = "Professions to learn", selected = options.newOnly,
                choose = function() options.knownOnly, options.unlearnedOnly, options.newOnly = nil, nil, true end },
            { text = "All recipes", selected = not (options.knownOnly or options.unlearnedOnly or options.newOnly),
                choose = function() options.knownOnly, options.unlearnedOnly, options.newOnly = nil, nil, nil end },
        }
    end)
    exitMenu = dropdown(390, 195, function()
        return {
            { text = "Best available exit", selected = options.exit == nil,
                choose = function() options.exit = nil end },
            { text = "Sell on AH (verified item types)", selected = options.exit == "Sell on AH",
                choose = function() options.exit = "Sell on AH" end },
            { text = "Vendor", selected = options.exit == "Vendor",
                choose = function() options.exit = "Vendor" end },
            { text = "Disenchant - no trusted yield data", disabled = true },
        }
    end)
    searchBox = ns.UI.EditBox(panel, 200, 24, "Search recipes")
    searchBox:SetPoint("TOPLEFT", 605, -32)
    searchBox:SetMaxLetters(100)
    searchBox:SetText(options.search)
    searchBox:UpdatePlaceholder()
    searchBox:SetScript("OnTextChanged", saveState)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); page = 1; refresh() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    button(panel, "Refresh / search", 825, -32, 140, refresh)
    summary = text(panel, "", 15, -64, 940)
    providerLabel = text(panel, "", 15, -86, 800, "small")
    costButton = button(panel, "Material costs", 825, -82, 140, showCosts)
    text(panel, "Recipes / profit per craft", 15, -116, 375, "header")
    text(panel, "Breakdown", 410, -116, 530, "header")
    for i = 1, PAGE_SIZE do
        rows[i] = CreateFrame("Button", nil, panel)
        rows[i]:SetSize(375, 39)
        rows[i]:SetPoint("TOPLEFT", 15, -136 - (i - 1) * 40)
        local hover = rows[i]:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetColorTexture(1, 0.82, 0.10, 0.07)
        rows[i].nameText = text(rows[i], "", 5, -2, 365)
        rows[i].valueText = text(rows[i], "", 5, -21, 365, "small")
        rows[i]:SetScript("OnClick", function(self)
            if costPanel then costPanel:Hide() end
            selected, batch, calculationError = self.key, nil, nil
            activationNotice = nil
            saveState()
            scroll:SetVerticalScroll(0)
            render()
        end)
    end
    scroll = ns.UI.Scroll(panel, 530, 400)
    scroll:SetPoint("TOPLEFT", 410, -136)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(530, 400)
    detail = text(child, "", 0, 0, 520)
    detail:SetWordWrap(true)
    detail:SetSpacing(3)
    scroll:SetScrollChild(child)
    text(panel, "Batch calculator", 410, -552, 540, "header")
    amount = ns.UI.EditBox(panel, 120, 24)
    amount:SetPoint("TOPLEFT", 415, -574)
    amount:SetMaxLetters(12)
    amount:SetText(savedAmount)
    amount:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    amount:SetScript("OnTextChanged", function()
        batch, calculationError, activationNotice = nil, nil, nil
        saveState()
        updateUseButton()
    end)
    local modeButton
    modeButton = button(panel, mode == "crafts" and "Crafts" or "Budget (copper)", 550, -574, 115, function()
        mode = mode == "crafts" and "budget" or "crafts"
        modeButton:SetText(mode == "crafts" and "Crafts" or "Budget (copper)")
        batch, calculationError = nil, nil
        saveState()
        details()
    end)
    button(panel, "Calculate", 680, -574, 120, function()
        amount:ClearFocus()
        local result = ns.PlannerBatchResult(current(), info, materialCosts)
        batch, calculationError = ns.CalculateBatch(result, mode, tonumber(amount:GetText()))
        activationNotice = nil
        details()
        scroll:SetVerticalScroll(math.max(0, detail:GetStringHeight() - 380))
    end)
    useButton = button(panel, "Set active shuffle", 810, -574, 155, function()
        amount:ClearFocus()
        batch = activationBatch()
        local result = ns.PlannerBatchResult(current(), info, materialCosts)
        local ok, reason = ns.ActivatePlannerResult(result, batch)
        if not ok then
            calculationError, activationNotice = reason, nil
        else
            calculationError = nil
            activationNotice = ("Active shuffle set for %d finished items. No purchases or crafts were started; run your shuffle macro to craft."):format(batch.items)
        end
        details()
    end)
    useButton:Disable()
    button(panel, "< Previous", 15, -574, 120, function() page = page - 1; render() end)
    button(panel, "Next >", 145, -574, 120, function() page = page + 1; render() end)
    countLabel = text(panel, "", 15, -612, 940, "small")
    -- While docked, closing hands the professions window back to its own page.
    panel.CloseButton:SetScript("OnClick", function()
        local api = professionTabs()
        if docked and api then api.ShowNative() else panel:Hide() end
    end)
    stateReady = true
end

-- Scale the docked browser down to the professions window's page area when it is smaller.
local function fit()
    if not (panel and shell) then return end
    local width = shell.GetWidth and shell:GetWidth()
    local height = shell.GetHeight and shell:GetHeight()
    local scale = 1
    if type(width) == "number" and width > 0 and type(height) == "number" and height > 0 then
        scale = math.min(1, (width - 2 * DOCK_SIDE) / PANEL_WIDTH,
            (height - DOCK_TOP - DOCK_BOTTOM) / PANEL_HEIGHT)
    end
    if panel.SetScale then panel:SetScale(scale) end
end

-- The native window already provides a header and close button, so the docked browser drops its own.
local function setChrome(shown)
    for _, part in ipairs({ panel.TitleBar, panel.TitleText, panel.CloseButton }) do
        if part then
            if shown then part:Show() else part:Hide() end
        end
    end
end

local function dock()
    build()
    docked = true
    setChrome(false)
    panel:SetParent(shell)
    panel:ClearAllPoints()
    panel:SetPoint("TOP", shell, "TOP", 0, -DOCK_TOP)
    panel:SetMovable(false)
    panel:RegisterForDrag()
    fit()
    panel:Show()
    refresh()
end

local function undock()
    docked = false
    if not panel then return end
    setChrome(true)
    if panel.SetScale then panel:SetScale(1) end
    panel:SetParent(UIParent)
    panel:ClearAllPoints()
    panel:SetPoint("CENTER")
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
end

-- Register the browser as a side-tab page of ProfessionsFrame, like SkillUp Forever's tabs.
-- ForeverCore is a dependency, but the guards keep the standalone window working if its
-- ProfessionTabs API changes or the client has not built the window yet.
local function ensureTab()
    if dockTab then return true end
    local api = professionTabs()
    local window = _G.ProfessionsFrame
    if not api or not window then return false end
    local ok, err = pcall(function()
        shell = CreateFrame("Frame", "ShuffleDetectorProfessionTabPage", window)
        if window.CraftingPage then
            shell:SetAllPoints(window.CraftingPage)
        else
            shell:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -60)
            shell:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 2)
        end
        shell:Hide()
        shell:SetScript("OnShow", dock)
        shell:SetScript("OnHide", function()
            if panel and docked then panel:Hide() end
        end)
        shell:SetScript("OnSizeChanged", function() if docked then fit() end end)
        dockTab = api.Register("shuffledetector", {
            icon = "Interface\\Icons\\INV_Misc_Coin_01",
            tooltip = "ShuffleDetector",
            page = shell,
            onSelect = function() end,
        })
        if type(api.SetMinWidth) == "function" then api.SetMinWidth("shuffledetector", PANEL_WIDTH + 2 * DOCK_SIDE) end
        -- Closing the window hands it back, so the tab is unchecked the next time it opens.
        window:HookScript("OnHide", function()
            local tabs = professionTabs()
            if tabs and tabs.Selected() == "shuffledetector" then tabs.ShowNative() end
        end)
    end)
    if not ok then
        ns.log("browser: profession tab registration failed: " .. tostring(err))
        shell, dockTab = nil, nil
    end
    return dockTab ~= nil
end
ns.EnsureProfessionTab = ensureTab

function ns.TogglePlanner()
    local api = professionTabs()
    local window = _G.ProfessionsFrame
    if api and dockTab and window and window:IsShown() then
        if api.Selected() == "shuffledetector" then api.ShowNative() else api.Select("shuffledetector") end
        return
    end
    if not panel then
        build()
        panel:Show()
        refresh()
        return
    end
    if docked then
        undock()
        panel:Show()
        refresh()
        return
    end
    if panel:IsShown() then panel:Hide() else panel:Show(); refresh() end
end

local tabDriver = CreateFrame("Frame")
tabDriver:RegisterEvent("PLAYER_LOGIN")
pcall(tabDriver.RegisterEvent, tabDriver, "TRADE_SKILL_SHOW")
tabDriver:SetScript("OnEvent", function() ensureTab() end)
