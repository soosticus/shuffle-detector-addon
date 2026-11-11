-- Pure shuffle evaluation core; price/vendor providers are injected by Planner.lua.
local _, ns = ...

local DEFAULTS = { ahCut = 0.05, craftSeconds = 30, disenchantSeconds = 3, exploratory = false }

local function value(v)
    -- Zero is a valid value; nil, negative, NaN and infinite numbers are unknown.
    return type(v) == "number" and v >= 0 and v == v and v ~= math.huge
end

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok and value(result) then return result end
    return nil
end

local function setting(settings, key)
    local v = settings and settings[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

local function exitEnabled(settings, label)
    local exits = settings and settings.exits
    return exits == nil or exits[label] == true
end

-- Finds the bundle DE model for an item. Returns:
--   false, reason       the item is documented as not disenchantable
--   model               { status, source, expected = { [material] = avg per disenchant } }
--   nil, "unknown"      no applicable model; never an implicit zero yield
-- A trusted band wins over an exploratory one; exploratory models stay labeled as such.
function ns.DisenchantModel(bundle, info)
    if type(bundle) ~= "table" or type(info) ~= "table" then return nil, "unknown" end
    for _, ex in ipairs(bundle.exclusions or {}) do
        if ex.item == info.item then return false, ex.reason or "excluded" end
    end
    if not (info.class and info.quality and info.ilvl) then return nil, "unknown" end
    local found
    for _, row in ipairs(bundle.disenchant or {}) do
        if row.class == info.class and row.quality == info.quality
            and info.ilvl >= row.low and info.ilvl <= row.high then
            if row.status == "trusted" then found = row; break end
            if row.status == "exploratory" and not found then found = row end
        end
    end
    if not found then return nil, "unknown" end
    local expected = {}
    if found.expected then
        for _, m in ipairs(found.expected) do expected[m.item] = (expected[m.item] or 0) + m.avg end
    else
        for _, o in ipairs(found.outcomes or {}) do
            for _, m in ipairs(o.loot) do
                expected[m.item] = (expected[m.item] or 0) + o.probability * m.qty
            end
        end
    end
    return { status = found.status, source = found.source, expected = expected }
end

-- Cheapest known way to obtain qty of an item: AH, vendor, or crafting it from its raw item.
local function reagentLine(r, ctx)
    local line = { item = r.item, qty = r.qty }
    local options = {}
    local ah = call(ctx.price, r.item)
    local vendor = call(ctx.vendorBuy, r.item)
    line.ahUnit, line.vendorUnit = ah, vendor
    if ah then options[#options + 1] = { total = ah * r.qty, source = "AH" } end
    if vendor then options[#options + 1] = { total = vendor * r.qty, source = "Vendor" } end
    local refined = ctx.refined and ctx.refined[r.item]
    if refined then
        local need = refined.per * r.qty
        local rawAh, rawVendor = call(ctx.price, refined.raw), call(ctx.vendorBuy, refined.raw)
        local best, rawSource = rawAh and rawAh * need, "AH"
        if rawVendor and (not best or rawVendor * need < best) then best, rawSource = rawVendor * need, "Vendor" end
        if best then
            line.rawItem, line.rawUnit, line.rawQty = refined.raw, best / r.qty, refined.per
            line.rawSource = rawSource
            options[#options + 1] = { total = best, source = "Craft from raw" }
        end
    end
    local best
    for _, o in ipairs(options) do
        if not best or o.total < best.total then best = o end
    end
    if best then
        line.total, line.unit, line.source = best.total, best.total / r.qty, best.source
    else
        line.source = "unavailable"
    end
    return line
end

local function disenchantExit(recipe, ctx, settings, makes)
    local model, reason = recipe.disenchant, nil
    if model == false then return nil end
    if model == nil then
        return { label = "Disenchant", reason = "unknown yields" }
    end
    local exit = { label = "Disenchant", status = model.status, source = model.source, yields = {} }
    local gross, missing, any = 0, {}, false
    local items = {}
    for item in pairs(model.expected or {}) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
        local avg = model.expected[item] * makes
        local price = call(ctx.price, item)
        exit.yields[#exit.yields + 1] = { item = item, avg = avg, unit = price, total = price and price * avg }
        any = true
        if price then gross = gross + price * avg else missing[#missing + 1] = item end
    end
    if not any then
        exit.reason = "unknown yields"
    elseif #missing > 0 then
        -- A partly priced disenchant is not a lower bound worth ranking; it is unknown.
        exit.reason, exit.missing = "unpriced yields", missing
    else
        exit.gross = gross
        exit.net = gross * (1 - setting(settings, "ahCut"))
    end
    if model.status ~= "trusted" then exit.exploratory = true end
    return exit
end

-- Evaluates one craft of a recipe.
-- recipe: { name, spell, item, makes, reagents = {{item, qty}}, craftSeconds,
--           disenchant = model from ns.DisenchantModel | false (not disenchantable) | nil (unknown) }
-- ctx:    { price(item), vendorBuy(item), vendorSell(item), refined = {[item] = {raw, per}}, settings }
-- Each provider returns a non-negative number or nil for unknown. Results keep nil
-- for anything unknown instead of treating it as free or worthless.
function ns.Evaluate(recipe, ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}
    local makes = recipe.makes or 1
    local res = { recipe = recipe, reagents = {}, exits = {}, missing = {}, makes = makes }
    if type(makes) ~= "number" or makes < 1 or makes ~= math.floor(makes) then
        res.invalid = "makes"
        return res
    end
    local cost, complete = 0, true
    for _, r in ipairs(recipe.reagents or {}) do
        local line = reagentLine(r, ctx)
        res.reagents[#res.reagents + 1] = line
        if line.total then cost = cost + line.total
        else complete = false; res.missing[#res.missing + 1] = r.item end
    end
    if complete then res.cost = cost end

    local de = disenchantExit(recipe, ctx, settings, makes)
    if de then res.exits[#res.exits + 1] = de end
    if recipe.item then
        local ah = call(ctx.price, recipe.item)
        res.exits[#res.exits + 1] = ah
            and { label = "Sell on AH", net = ah * makes * (1 - setting(settings, "ahCut")), status = "trusted" }
            or { label = "Sell on AH", reason = "no price" }
        local vendor = call(ctx.vendorSell, recipe.item)
        if vendor == nil then
            res.exits[#res.exits + 1] = { label = "Vendor", reason = "unknown vendor price" }
        elseif vendor == 0 then
            res.exits[#res.exits + 1] = { label = "Vendor", reason = "cannot be sold to a vendor" }
        else
            res.exits[#res.exits + 1] = { label = "Vendor", net = vendor * makes, status = "trusted" }
        end
    end

    local allowExploratory = setting(settings, "exploratory") == true
    local best
    for _, e in ipairs(res.exits) do
        if e.net and exitEnabled(settings, e.label) and (allowExploratory or not e.exploratory)
            and (not best or e.net > best.net) then
            best = e
        end
    end
    if best then
        res.exit, res.net, res.exploratory = best.label, best.net, best.exploratory == true
    end
    if res.cost and res.net then
        res.profit = res.net - res.cost
        if res.cost > 0 then res.roi = res.profit / res.cost end
    end
    res.seconds = (recipe.craftSeconds or setting(settings, "craftSeconds"))
        + (res.exit == "Disenchant" and setting(settings, "disenchantSeconds") * makes or 0)
    if res.profit and res.seconds > 0 then res.profitPerHour = res.profit / res.seconds * 3600 end
    return res
end

-- Sorts in place: complete profits first (highest first), then incomplete results; ties by name.
function ns.RankEvaluations(results)
    table.sort(results, function(a, b)
        local pa, pb = a.profit, b.profit
        if (pa == nil) ~= (pb == nil) then return pa ~= nil end
        if pa and pa ~= pb then return pa > pb end
        return tostring(a.recipe.name or "") < tostring(b.recipe.name or "")
    end)
    return results
end
