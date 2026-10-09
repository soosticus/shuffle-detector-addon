-- Auction house UI: a "ShuffleDetector" tab (via LibAHTab, shared with Auctionator) or, when
-- the tab library isn't available, a small panel docked to the auction house window.
local ADDON, ns = ...
local S = ns.scan

local TAB_ID = "ShuffleDetectorTab"
local panel, content, created

local function fmtDuration(sec)
    if not sec then return "--" end
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 60 then return ("%dm %02ds"):format(math.floor(sec / 60), sec % 60) end
    return ("%ds"):format(sec)
end

local function ahFrame()
    return AuctionHouseFrame or AuctionFrame
end

local function buildContent(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetAllPoints()

    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.title:SetPoint("TOP", 0, -24)
    c.title:SetText("ShuffleDetector")

    c.help = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.help:SetPoint("TOP", c.title, "BOTTOM", 0, -8)
    c.help:SetWidth(380)
    c.help:SetText("Scans the auction house for the ShuffleDetector companion app.")

    c.scan = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.scan:SetSize(180, 26)
    c.scan:SetPoint("TOP", c.help, "BOTTOM", 0, -16)
    c.scan:SetText("Full Scan")
    c.scan:SetScript("OnClick", function() ns.StartScan() end)

    c.import = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.import:SetSize(180, 26)
    c.import:SetPoint("TOP", c.scan, "BOTTOM", 0, -6)
    c.import:SetText("Use Auctionator Data")
    c.import:SetScript("OnClick", function() ns.ImportAuctionator() end)

    c.bar = CreateFrame("StatusBar", nil, c)
    c.bar:SetSize(340, 18)
    c.bar:SetPoint("TOP", c.import, "BOTTOM", 0, -18)
    c.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    c.bar:SetStatusBarColor(0.1, 0.7, 0.2)
    c.bar:SetMinMaxValues(0, 1)
    c.bar:SetValue(0)
    c.bar.bg = c.bar:CreateTexture(nil, "BACKGROUND")
    c.bar.bg:SetAllPoints()
    c.bar.bg:SetColorTexture(0, 0, 0, 0.5)
    c.bar.text = c.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.bar.text:SetPoint("CENTER")

    c.timing = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.timing:SetPoint("TOP", c.bar, "BOTTOM", 0, -8)

    c.status = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.status:SetPoint("TOP", c.timing, "BOTTOM", 0, -8)
    c.status:SetWidth(380)

    c.last = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    c.last:SetPoint("TOP", c.status, "BOTTOM", 0, -14)
    c.last:SetWidth(380)

    return c
end

function ns.UpdateUI()
    if not content then return end
    ns.LoadLastScanInfo()
    local busy = S.state ~= "idle"

    content.scan:SetEnabled(not busy)
    content.import:SetEnabled(not busy and ns.AuctionatorAvailable())
    content.import:SetShown(Auctionator ~= nil)

    content.bar:SetValue(S.progress or 0)
    content.bar.text:SetText(("%d%%"):format((S.progress or 0) * 100))
    if busy then
        content.timing:SetText(("Elapsed %s    ETA %s"):format(fmtDuration(S.elapsed), fmtDuration(S.eta)))
    else
        content.timing:SetText("")
    end
    content.status:SetText(S.message or "")

    if S.lastTime then
        local src = S.lastSource == "auctionator" and "Auctionator (min prices only)" or "full scan"
        content.last:SetText(("Last saved: %s, %s, %s listings/items"):format(
            date("%Y-%m-%d %H:%M", S.lastTime), src, tostring(S.lastListings or "?")))
    else
        content.last:SetText("No saved data for this realm yet.")
    end
end

local function createPanel()
    if created then return end
    local host = ahFrame()
    if not host then return false end
    created = true

    local LibAHTab = LibStub and LibStub("LibAHTab-1-0", true)
    if LibAHTab and AuctionHouseFrame then
        panel = CreateFrame("Frame", "ShuffleDetectorPanel", AuctionHouseFrame)
        panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 0, -60)
        panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", 0, 0)
        content = buildContent(panel)
        local ok, err = pcall(LibAHTab.CreateTab, LibAHTab, TAB_ID, panel, "ShuffleDetector")
        if ok then
            ns.UpdateUI()
            return
        end
        ns.say("could not add the auction house tab (" .. tostring(err) .. "); using a floating panel")
        panel:Hide()
    end

    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    panel = CreateFrame("Frame", "ShuffleDetectorFloatingPanel", host, template)
    panel:SetSize(420, 300)
    panel:SetPoint("TOPLEFT", host, "TOPRIGHT", 4, -20)
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end
    content = buildContent(panel)
    ns.UpdateUI()
end

-- The AH frame can appear after the open event (load-on-demand), and Forever may signal
-- the open via PLAYER_INTERACTION_MANAGER_FRAME_SHOW instead of AUCTION_HOUSE_SHOW.
local function tryCreate(attempt)
    if created then return end
    if ahFrame() then
        local ok, err = pcall(createPanel)
        if not ok then ns.say("UI error: " .. tostring(err)) end
        return
    end
    if attempt < 20 then
        C_Timer.After(0.25, function() tryCreate(attempt + 1) end)
    else
        ns.say("auction house frame not found; the tab could not be added")
    end
end

function ns.DebugUI()
    ns.say(("AuctionHouseFrame=%s AuctionFrame=%s LibAHTab=%s Auctionator=%s created=%s"):format(
        tostring(AuctionHouseFrame ~= nil), tostring(AuctionFrame ~= nil),
        tostring(LibStub and LibStub("LibAHTab-1-0", true) ~= nil), tostring(Auctionator ~= nil), tostring(created)))
end

local f = CreateFrame("Frame")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" then
        if arg == "Blizzard_AuctionHouseUI" or arg == "Blizzard_AuctionUI" then
            C_Timer.After(0, function() tryCreate(0) end)
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if Enum and Enum.PlayerInteractionType and arg == Enum.PlayerInteractionType.Auctioneer then
            C_Timer.After(0.1, function() tryCreate(0) end)
        end
    else
        C_Timer.After(0.1, function() tryCreate(0) end)
    end
end)
