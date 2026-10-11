-- Shuffle button: a secure button that performs the next step of the loaded shuffle (ns.plan,
-- from Plan.lua) on each press: disenchant a crafted piece if one is in the bags, otherwise
-- craft the next one. Protected actions need one hardware event each, so it is one step per
-- press; bind a key (Key Bindings > AddOns > ShuffleDetector) or /click the button to spam it.
local ADDON, ns = ...
local say = ns.say

local BUTTON_NAME = "ShuffleDetectorShuffleButton"
local DISENCHANT_ID = 13262
local PLAN_VERSION = 1

BINDING_HEADER_SHUFFLEDETECTOR = "ShuffleDetector"
BINDING_NAME_SHUFFLEDETECTOR_SHUFFLE = "Next shuffle step"

local btn

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
    return (GetItemInfo and GetItemInfo(id)) or ("item " .. tostring(id))
end

local function currentPlan()
    local plan = ns.plan
    if type(plan) == "table" and plan.version == PLAN_VERSION and plan.recipe then return plan end
end

-- First bag slot holding the crafted item (by id, or by name when the plan has no item id).
local function findCrafted(plan)
    local c = C_Container
    local numSlots = (c and c.GetContainerNumSlots) or GetContainerNumSlots
    local itemLink = (c and c.GetContainerItemLink) or GetContainerItemLink
    local wantName = plan.itemName or plan.recipe
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, numSlots(bag) or 0 do
            local link = itemLink(bag, slot)
            if link then
                if plan.item then
                    if tonumber(link:match("item:(%d+)")) == plan.item then return bag, slot end
                elseif link:match("%[(.-)%]") == wantName then
                    return bag, slot
                end
            end
        end
    end
end

local function missingReagent(plan)
    for _, r in ipairs(plan.reagents or {}) do
        if GetItemCount(r.item) < r.qty then return r end
    end
end

-- Decides what the next press should do. Returns { kind = "craft" | "disenchant" | "idle", label, ... }.
function ns.NextShuffleStep()
    local plan = currentPlan()
    if not plan then
        return { kind = "idle", label = "No shuffle loaded" }
    end
    if plan.exit == "Disenchant" then
        local bag, slot = findCrafted(plan)
        if bag then
            if IsSpellKnown and not IsSpellKnown(DISENCHANT_ID) then
                return { kind = "idle", label = "Disenchant not known" }
            end
            return { kind = "disenchant", label = "Disenchant " .. plan.recipe, bag = bag, slot = slot }
        end
    end
    local missing = missingReagent(plan)
    if missing then
        local label = "Out of " .. itemName(missing.item)
        if plan.exit ~= "Disenchant" then label = label .. " - sell: " .. tostring(plan.exit or "?") end
        return { kind = "idle", label = label }
    end
    return { kind = "craft", label = "Craft " .. plan.recipe }
end

local dirty = false -- a refresh was requested during combat

-- Attributes of a secure button can only change out of combat.
local function apply()
    if not btn then return end
    if InCombatLockdown() then dirty = true return end
    dirty = false
    local step = ns.NextShuffleStep()
    btn:SetAttribute("type", nil)
    btn:SetAttribute("spell", nil)
    btn:SetAttribute("macrotext", nil)
    if step.kind == "craft" then
        btn:SetAttribute("type", "spell")
        btn:SetAttribute("spell", ns.plan.recipe)
    elseif step.kind == "disenchant" then
        btn:SetAttribute("type", "macro")
        btn:SetAttribute("macrotext", ("/cast %s\n/use %d %d"):format(spellName(DISENCHANT_ID, "Disenchant"), step.bag, step.slot))
    end
    btn.step = step
    btn:SetText(step.label)
end

local function savePosition()
    local point, _, relPoint, x, y = btn:GetPoint()
    AHSnapshotDB.shuffleButton = { point = point, relPoint = relPoint, x = x, y = y }
end

local function restorePosition()
    local p = AHSnapshotDB.shuffleButton
    if p and p.point then
        btn:ClearAllPoints()
        btn:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
    end
end

local function create()
    btn = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    btn:SetSize(240, 32)
    btn:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    btn:SetText("Shuffle")
    btn:RegisterForClicks("AnyUp")
    btn:SetMovable(true)
    btn:SetClampedToScreen(true)
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() and not InCombatLockdown() then self:StartMoving() end
    end)
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition()
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local plan = currentPlan()
        if plan then
            GameTooltip:AddLine(plan.recipe .. " -> " .. tostring(plan.exit or "?"))
            if plan.generated then
                GameTooltip:AddLine("Sent " .. date("%Y-%m-%d %H:%M", plan.generated), 0.7, 0.7, 0.7)
            end
        else
            GameTooltip:AddLine("No shuffle loaded")
        end
        GameTooltip:AddLine("One step per press. Shift-drag to move.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:Hide()
end

function ns.ToggleShuffleButton()
    if InCombatLockdown() then say("can't show or hide the shuffle button in combat") return end
    local show = not btn:IsShown()
    btn:SetShown(show)
    AHSnapshotDB.shuffleButtonShown = show
    if show then apply() end
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
ev:RegisterEvent("SPELLS_CHANGED")
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        restorePosition()
        if AHSnapshotDB.shuffleButtonShown and not InCombatLockdown() then btn:Show() end
    end
    apply()
end)
