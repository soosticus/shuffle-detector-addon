local _, ns = ...

-- Shared flat theme (ElvUI/Baganator style): solid dark fills, 1px borders, clean narrow font.
local UI = {}
ns.UI = UI

UI.colors = {
    window  = { 0.10, 0.08, 0.06, 0.95 }, -- warm brown-black, like the client's detail pane
    section = { 0.14, 0.11, 0.08, 1 },    -- title bars and sub-panels
    control = { 0.17, 0.14, 0.10, 1 },    -- buttons
    inset   = { 0.06, 0.05, 0.03, 0.90 }, -- edit boxes and list wells
    border  = { 0.30, 0.23, 0.10, 1 },    -- dim bronze trim, like the native inset outlines
    accent  = { 1.00, 0.82, 0.10 },       -- the client's gold for headers, focus and selection
    text    = { 0.92, 0.88, 0.80 },
    muted   = { 0.62, 0.57, 0.48 },
}

local FONT = "Fonts\\ARIALN.TTF"
local fonts = {}

-- Shared font objects; nil where CreateFont is unavailable (test harnesses), styling is skipped then.
function UI.FontObject(size, style)
    local key = size .. (style or "")
    if not fonts[key] and CreateFont then
        local font = CreateFont("ShuffleDetectorFont" .. key)
        font:SetFont(FONT, size, "")
        -- An invalid font path would render nothing; fall back to the client's standard font.
        if not font:GetFont() and STANDARD_TEXT_FONT then font:SetFont(STANDARD_TEXT_FONT, size, "") end
        font:SetShadowColor(0, 0, 0, 0.9)
        font:SetShadowOffset(1, -1)
        if style == "disabled" then font:SetTextColor(0.45, 0.45, 0.45)
        elseif style == "white" then font:SetTextColor(1, 1, 1)
        elseif style == "accent" then font:SetTextColor(UI.colors.accent[1], UI.colors.accent[2], UI.colors.accent[3])
        else font:SetTextColor(UI.colors.text[1], UI.colors.text[2], UI.colors.text[3]) end
        fonts[key] = font
    end
    return fonts[key]
end

local function solid(parent, layer, color, sublevel)
    local tex = parent:CreateTexture(nil, layer, nil, sublevel)
    tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return tex
end

-- 1px border and a solid fill; references kept for state recoloring.
function UI.Skin(frame, fill)
    frame.borderTex = solid(frame, "BACKGROUND", UI.colors.border, 0)
    frame.borderTex:SetAllPoints()
    frame.bgTex = solid(frame, "BACKGROUND", fill or UI.colors.window, 1)
    frame.bgTex:SetPoint("TOPLEFT", 1, -1)
    frame.bgTex:SetPoint("BOTTOMRIGHT", -1, 1)
    return frame
end

function UI.Label(parent, value, size, color)
    local label = parent:CreateFontString(nil, "OVERLAY")
    local font = UI.FontObject(size or 12)
    if font then label:SetFontObject(font) end
    local c = color or UI.colors.text
    label:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    label:SetJustifyH("LEFT")
    label:SetText(value or "")
    return label
end

function UI.Button(parent, caption, width, height)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width or 100, height or 24)
    UI.Skin(button, UI.colors.control)
    local normal = UI.FontObject(12)
    if normal then
        button:SetNormalFontObject(normal)
        button:SetHighlightFontObject(UI.FontObject(12, "white"))
        button:SetDisabledFontObject(UI.FontObject(12, "disabled"))
        button:SetPushedTextOffset(1, -1)
    end
    button.hoverTex = solid(button, "HIGHLIGHT", { 1, 0.82, 0.10, 0.07 })
    button.hoverTex:SetPoint("TOPLEFT", 1, -1)
    button.hoverTex:SetPoint("BOTTOMRIGHT", -1, 1)
    button:SetText(caption)
    return button
end

-- Left-aligns a themed button's caption by routing SetText into an anchored font string.
local function leftAlignText(button, rightInset)
    local fs = button:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("LEFT", 8, 0)
    fs:SetPoint("RIGHT", -rightInset, 0)
    fs:SetJustifyH("LEFT")
    if button.SetFontString then button:SetFontString(fs) end
end

-- Dropdown selector: left-aligned current value with a down arrow. The caller owns the menu.
function UI.DropdownButton(parent, width, height)
    local button = CreateFrame("Button", nil, parent)
    button.isDropdown = true
    button:SetSize(width, height or 24)
    UI.Skin(button, UI.colors.control)
    local normal = UI.FontObject(12)
    if normal then
        button:SetNormalFontObject(normal)
        button:SetHighlightFontObject(UI.FontObject(12, "white"))
        button:SetDisabledFontObject(UI.FontObject(12, "disabled"))
    end
    leftAlignText(button, 20)
    button.hoverTex = solid(button, "HIGHLIGHT", { 1, 0.82, 0.10, 0.07 })
    button.hoverTex:SetPoint("TOPLEFT", 1, -1)
    button.hoverTex:SetPoint("BOTTOMRIGHT", -1, 1)
    local arrow = button:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetPoint("RIGHT", -5, 0)
    if arrow.SetTexture then arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow") end
    if arrow.SetRotation then arrow:SetRotation(-math.pi / 2) end
    button.arrowTex = arrow
    return button
end

-- Flat menu row: no border, hover tint, accent color for the selected entry.
function UI.MenuItem(parent, width, height)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height or 24)
    local normal, accent = UI.FontObject(12), UI.FontObject(12, "accent")
    if normal then
        button:SetNormalFontObject(normal)
        button:SetHighlightFontObject(UI.FontObject(12, "white"))
        button:SetDisabledFontObject(UI.FontObject(12, "disabled"))
    end
    leftAlignText(button, 8)
    local hover = solid(button, "HIGHLIGHT",
        { UI.colors.accent[1], UI.colors.accent[2], UI.colors.accent[3], 0.15 })
    hover:SetAllPoints()
    function button:SetAccented(on)
        if normal then self:SetNormalFontObject(on and accent or normal) end
    end
    return button
end

function UI.EditBox(parent, width, height, placeholder)
    local box = CreateFrame("EditBox", nil, parent)
    box:SetSize(width, height or 24)
    box:SetAutoFocus(false)
    UI.Skin(box, UI.colors.inset)
    local font = UI.FontObject(12)
    if font then box:SetFontObject(font) end
    box:SetTextInsets(6, 6, 0, 0)
    if placeholder then
        box.placeholder = UI.Label(box, placeholder, 12, UI.colors.muted)
        box.placeholder:SetPoint("LEFT", 6, 0)
        function box:UpdatePlaceholder()
            if not self.focused and (self:GetText() or "") == "" then self.placeholder:Show()
            else self.placeholder:Hide() end
        end
    end
    box:SetScript("OnEditFocusGained", function(self)
        self.focused = true
        self.borderTex:SetColorTexture(UI.colors.accent[1], UI.colors.accent[2], UI.colors.accent[3], 1)
        if self.placeholder then self.placeholder:Hide() end
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self.focused = nil
        local border = UI.colors.border
        self.borderTex:SetColorTexture(border[1], border[2], border[3], border[4] or 1)
        if self.UpdatePlaceholder then self:UpdatePlaceholder() end
    end)
    return box
end

-- A themed top-level window: title bar, title text (frame.TitleText) and a close button.
function UI.Window(name, width, height, title, parent)
    local frame = CreateFrame("Frame", name, parent or UIParent)
    frame:SetSize(width, height)
    UI.Skin(frame)
    local bar = solid(frame, "BORDER", UI.colors.section)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(22)
    frame.TitleBar = bar
    frame.TitleText = UI.Label(frame, title, 13, UI.colors.accent)
    frame.TitleText:SetPoint("TOPLEFT", 9, -6)
    local close = UI.Button(frame, "X", 22, 22)
    close:SetPoint("TOPRIGHT", -1, -1)
    close.hoverTex:SetColorTexture(0.75, 0.15, 0.15, 0.5)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.CloseButton = close
    return frame
end

-- Flatten a stock scrollbar: hidden arrow buttons, solid track, solid thumb. Best effort per client.
function UI.SkinScrollBar(scroll)
    pcall(function()
        local bar = scroll.ScrollBar
        if not bar and scroll.GetChildren then
            for _, child in ipairs({ scroll:GetChildren() }) do
                if child.GetObjectType and child:GetObjectType() == "Slider" then bar = child; break end
            end
        end
        if not bar then return end
        for _, key in ipairs({ "ScrollUpButton", "ScrollDownButton" }) do
            local arrow = bar[key] or (bar.GetName and bar:GetName() and _G[bar:GetName() .. key])
            if arrow then arrow:SetAlpha(0); arrow:EnableMouse(false) end
        end
        local track = bar:CreateTexture(nil, "BACKGROUND")
        track:SetColorTexture(0.05, 0.04, 0.03, 0.9)
        track:SetAllPoints()
        local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
        if thumb then thumb:SetColorTexture(0.35, 0.28, 0.16, 1) end
    end)
end

function UI.Scroll(parent, width, height)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetSize(width, height)
    UI.SkinScrollBar(scroll)
    return scroll
end
