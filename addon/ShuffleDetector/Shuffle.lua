-- Shuffle: runs the loaded shuffle (ns.plan, from Plan.lua) one step per macro press, and shows a
-- tracker with the step you are on. Protected actions (casting, using items) can only come from a
-- secure button on a hardware event, so a chat command cannot craft or disenchant by itself.
-- Instead, an invisible secure button does the action and /shuffle prepares it. Macro:
--     /shuffle
--     /click ShuffleDetectorShuffleButton
local ADDON, ns = ...
local say = ns.say

local BUTTON_NAME = "ShuffleDetectorShuffleButton"
local DISENCHANT_ID = 13262
local PLAN_VERSION = 1
local MACRO = "/shuffle\n/click " .. BUTTON_NAME

BINDING_HEADER_SHUFFLEDETECTOR = "ShuffleDetector"
_G["BINDING_NAME_CLICK " .. BUTTON_NAME .. ":LeftButton"] = "Next shuffle step"

local btn, tracker
local lastClick -- GetTime() of the last click on the button, shown by /shuffle for diagnosing macros

local function spellName(id, fallback)
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(id)
    elseif GetSpellInfo then
        name = GetSpellInfo(id)
    end
    return name or fallback
end

local function itemName(id)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    return (info and info(id)) or ("item " .. tostring(id))
end

-- This client has no global GetItemCount; it lives in C_Item.
local function itemCount(id)
    local count = (C_Item and C_Item.GetItemCount) or GetItemCount
    return count and count(id) or 0
end

local function currentPlan()
    local plan = ns.plan
    if type(plan) == "table" and plan.version == PLAN_VERSION and plan.recipe then return plan end
end

-- First bag slot holding the crafted item (by id, or by name when the plan has no item id), and how many are held.
local function findCrafted(plan)
    local c = C_Container
    local numSlots = (c and c.GetContainerNumSlots) or GetContainerNumSlots
    local itemLink = (c and c.GetContainerItemLink) or GetContainerItemLink
    local wantName = plan.itemName or plan.recipe
    local firstBag, firstSlot, slots = nil, nil, 0
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, numSlots(bag) or 0 do
            local link = itemLink(bag, slot)
            if link then
                local match
                if plan.item then
                    match = tonumber(link:match("item:(%d+)")) == plan.item
                else
                    match = link:match("%[(.-)%]") == wantName
                end
                if match then
                    firstBag, firstSlot = firstBag or bag, firstSlot or slot
                    slots = slots + 1
                end
            end
        end
    end
    local count = slots
    if plan.item and slots > 0 then count = itemCount(plan.item) end
    return firstBag, firstSlot, count
end

local function missingReagent(plan)
    for _, r in ipairs(plan.reagents or {}) do
        if itemCount(r.item) < r.qty then return r end
    end
end

-- How many crafts the reagents in your bags allow.
local function craftableCount(plan)
    local n
    for _, r in ipairs(plan.reagents or {}) do
        if r.qty > 0 then
            local k = math.floor(itemCount(r.item) / r.qty)
            if not n or k < n then n = k end
        end
    end
    return n or 0
end

-- Decides what the next press should do.
-- Returns { kind = "craft" | "disenchant" | "idle", label, stage = 1 (craft) | 2 (disenchant/sell) | nil,
--           crafted = pieces in bags, craftable = crafts the reagents allow, bag, slot }.
function ns.NextShuffleStep()
    local plan = currentPlan()
    if not plan then
        return { kind = "idle", label = "No shuffle loaded", crafted = 0, craftable = 0 }
    end
    local bag, slot, crafted = findCrafted(plan)
    local step = { crafted = crafted, craftable = craftableCount(plan) }
    if plan.exit == "Disenchant" and bag then
        if IsSpellKnown and not IsSpellKnown(DISENCHANT_ID) then
            step.kind, step.label, step.stage = "idle", "Disenchant not known", 2
            return step
        end
        step.kind, step.label, step.stage = "disenchant", "Disenchant " .. plan.recipe, 2
        step.bag, step.slot = bag, slot
        return step
    end
    local missing = missingReagent(plan)
    if missing then
        step.kind, step.stage = "idle", 2
        step.label = "Out of " .. itemName(missing.item)
        if plan.exit ~= "Disenchant" then step.label = step.label .. " - sell: " .. tostring(plan.exit or "?") end
        return step
    end
    step.kind, step.label, step.stage = "craft", "Craft " .. plan.recipe, 1
    return step
end

local GREEN, GREY = { 0.35, 1, 0.35 }, { 0.6, 0.6, 0.6 }

local function refreshTracker(step)
    if not tracker then return end
    local plan = currentPlan()
    if not plan then
        tracker.title:SetText("Shuffle")
        tracker.line1:SetText("")
        tracker.line2:SetText("")
        tracker.foot:SetText(step.label .. ". Send one from the companion app, then /reload.")
        return
    end
    local exit = plan.exit
    if not exit or exit == "" then exit = "craft only" end
    tracker.title:SetText(plan.recipe .. " -> " .. exit)
    local second = plan.exit == "Disenchant" and "Disenchant" or ("Sell: " .. exit)
    local rows = {
        { tracker.line1, ("Craft %s  (%d possible)"):format(plan.recipe, step.craftable), 1 },
        { tracker.line2, ("%s  (%d in bags)"):format(second, step.crafted), 2 },
    }
    for i, row in ipairs(rows) do
        local fs, text, stage = row[1], row[2], row[3]
        local active = step.stage == stage
        fs:SetText((active and "> " or "   ") .. i .. ". " .. text)
        local c = active and GREEN or GREY
        fs:SetTextColor(c[1], c[2], c[3])
    end
    if InCombatLockdown() then
        tracker.foot:SetText("In combat - the next step is set when it ends")
    elseif step.kind == "idle" then
        tracker.foot:SetText(step.label)
    else
        tracker.foot:SetText("Run your /shuffle macro")
    end
end

local dirty = false -- a refresh was requested during combat

-- Attributes of a secure button can only change out of combat; the tracker can always update.
local function apply()
    if not btn then return end
    local ok, step = pcall(ns.NextShuffleStep)
    if not ok then
        if tracker then tracker.foot:SetText("Error: " .. tostring(step)) end
        say("error: " .. tostring(step))
        return
    end
    if InCombatLockdown() then
        dirty = true
    else
        dirty = false
        btn:SetAttribute("type", nil)
        btn:SetAttribute("spell", nil)
        btn:SetAttribute("macrotext", nil)
        btn.craftRecipe = nil
        if step.kind == "craft" then
            local plan = ns.plan
            if plan.spell and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe then
                -- Casting a recipe by name does nothing in the modern profession UI; craft through it instead.
                btn.craftRecipe = plan.spell
            else
                btn:SetAttribute("type", "spell")
                btn:SetAttribute("spell", plan.recipe)
            end
        elseif step.kind == "disenchant" then
            btn:SetAttribute("type", "macro")
            btn:SetAttribute("macrotext", ("/cast %s\n/use %d %d"):format(spellName(DISENCHANT_ID, "Disenchant"), step.bag, step.slot))
        end
    end
    refreshTracker(step)
end

local function savePosition()
    local point, _, relPoint, x, y = tracker:GetPoint()
    AHSnapshotDB.shuffleTracker = { point = point, relPoint = relPoint, x = x, y = y }
end

local function restorePosition()
    local p = AHSnapshotDB.shuffleTracker
    if p and p.point then
        tracker:ClearAllPoints()
        tracker:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
    end
end

local function create()
    -- Invisible: it only exists so a macro or key binding can trigger the protected action.
    btn = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    btn:SetSize(1, 1)
    btn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
    btn:EnableMouse(false)
    -- Macros /click with the key-down or key-up state of the action button, so accept both.
    btn:RegisterForClicks("AnyUp", "AnyDown")
    btn:HookScript("PostClick", function(self)
        local now = GetTime()
        if lastClick and now - lastClick < 0.2 then return end -- down + up of one press
        lastClick = now
        say(("click: %s (%s)"):format(self.craftRecipe and "tradeskill craft" or tostring(self:GetAttribute("type")),
            tostring(self:GetAttribute("spell") or self:GetAttribute("macrotext") or self.craftRecipe)))
        if self.craftRecipe then
            local T = C_TradeSkillUI
            if T.GetRecipeInfo and not T.GetRecipeInfo(self.craftRecipe) then
                say("the profession window has not loaded this recipe yet - open your profession window once, then try again.")
            end
            local ok, err = pcall(T.CraftRecipe, self.craftRecipe, 1)
            if not ok then say("craft failed: " .. tostring(err)) end
        end
    end)

    tracker = CreateFrame("Frame", "ShuffleDetectorTracker", UIParent)
    tracker:SetSize(300, 94)
    tracker:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    tracker:SetFrameStrata("MEDIUM")
    tracker:SetMovable(true)
    tracker:SetClampedToScreen(true)
    tracker:EnableMouse(true)
    tracker:RegisterForDrag("LeftButton")
    tracker:SetScript("OnDragStart", function(self) self:StartMoving() end)
    tracker:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition()
    end)
    local bg = tracker:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.65)
    local function text(template, y)
        local fs = tracker:CreateFontString(nil, "OVERLAY", template)
        fs:SetPoint("TOPLEFT", tracker, "TOPLEFT", 8, y)
        fs:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -8, y)
        fs:SetJustifyH("LEFT")
        return fs
    end
    tracker.title = text("GameFontNormal", -8)
    tracker.line1 = text("GameFontHighlight", -28)
    tracker.line2 = text("GameFontHighlight", -46)
    tracker.foot = text("GameFontHighlightSmall", -68)
    tracker.foot:SetTextColor(0.7, 0.7, 0.7)
    tracker:Hide()
end

function ns.ToggleShuffleTracker()
    local show = not tracker:IsShown()
    tracker:SetShown(show)
    AHSnapshotDB.shuffleTrackerShown = show
    if show then apply() end
end

-- /shuffle: prepare the next step. Meant to be the first line of a macro, before /click.
function ns.ShuffleStep()
    if not currentPlan() then
        say("no shuffle loaded. In the companion app choose a shuffle and use Addon > Send selected shuffle to game, then /reload.")
    end
    apply()
    local how = btn:GetAttribute("type") or (btn.craftRecipe and "tradeskill") or "none"
    local ago = lastClick and ("%.0fs ago"):format(GetTime() - lastClick) or "never"
    say(("next: %s [action: %s; button last clicked %s]"):format(ns.NextShuffleStep().label, how, ago))
end

function ns.PrintShuffleMacro()
    say("make a macro with these two lines and press it repeatedly:")
    for line in MACRO:gmatch("[^\n]+") do say("  " .. line) end
end

function ns.PrintPlan()
    local plan = ns.plan
    if not plan then
        say("no shuffle loaded. In the companion app choose a shuffle and use Addon > Send selected shuffle to game, then /reload.")
        return
    end
    if not currentPlan() then
        say("the loaded shuffle uses an unsupported format; update the addon and the companion app.")
        return
    end
    local reagents = {}
    for _, r in ipairs(plan.reagents or {}) do
        reagents[#reagents + 1] = ("%d x %s"):format(r.qty, itemName(r.item))
    end
    say(("shuffle: %s -> %s (%s)"):format(plan.recipe, tostring(plan.exit or "?"), table.concat(reagents, ", ")))
    say("next step: " .. ns.NextShuffleStep().label)
end

create()

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("SPELLS_CHANGED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        restorePosition()
        if AHSnapshotDB.shuffleTrackerShown ~= false and currentPlan() then tracker:Show() end
    end
    apply()
end)
