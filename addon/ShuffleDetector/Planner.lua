local _, ns = ...

local function integer(n, low, high)
    return type(n) == "number" and n >= low and n <= high and n == math.floor(n)
end

local function finite(n)
    return type(n) == "number" and n == n and math.abs(n) < math.huge
end

local function validPlan(plan)
    if type(plan) ~= "table" or plan.version ~= 1 or type(plan.recipe) ~= "string"
        or not integer(plan.item, 1, 10000000) or not integer(plan.spell, 1, 10000000)
        or not integer(plan.selectedAt, 0, 9007199254740991)
        or (plan.exit ~= "Vendor" and plan.exit ~= "Sell on AH")
        or (plan.itemName ~= nil and type(plan.itemName) ~= "string")
        or (plan.makes ~= nil and not integer(plan.makes, 1, 100000))
        or type(plan.reagents) ~= "table" or #plan.reagents == 0
        or type(plan.estimate) ~= "table" then return false end
    local count = 0
    for key, reagent in pairs(plan.reagents) do
        if not integer(key, 1, #plan.reagents) or type(reagent) ~= "table" then return false end
        count = count + 1
    end
    if count ~= #plan.reagents then return false end
    local seen = {}
    for _, reagent in ipairs(plan.reagents) do
        if not integer(reagent.item, 1, 10000000) or not integer(reagent.qty, 1, 100000) then return false end
        if seen[reagent.item] then return false end
        seen[reagent.item] = true
        for key in pairs(reagent) do
            if key ~= "item" and key ~= "qty" and key ~= "raw" then return false end
        end
        if reagent.raw and (type(reagent.raw) ~= "table"
            or not integer(reagent.raw.item, 1, 10000000) or reagent.raw.item == reagent.item
            or not integer(reagent.raw.qty, 1, 100000)) then return false end
    end
    return finite(plan.estimate.cost) and plan.estimate.cost >= 0
        and finite(plan.estimate.income) and plan.estimate.income >= 0
end
ns.ValidateActivePlan = validPlan

local function recipeCopy(row, profession, known)
    if type(row) ~= "table" or type(row.name) ~= "string" or not integer(row.item, 1, 10000000)
        or type(row.reagents) ~= "table" or #row.reagents == 0 then return end
    local makes = row.makes
    if makes == nil then makes = 1 end
    if not integer(makes, 1, 100000) or (row.spell ~= nil and not integer(row.spell, 1, 10000000)) then return end
    local count = 0
    for key in pairs(row.reagents) do
        if not integer(key, 1, #row.reagents) then return end
        count = count + 1
    end
    if count ~= #row.reagents then return end
    local reagents, seen = {}, {}
    for _, r in ipairs(row.reagents) do
        if type(r) ~= "table" or not integer(r.item, 1, 10000000) or not integer(r.qty, 1, 100000)
            or seen[r.item] then return end
        seen[r.item] = true
        reagents[#reagents + 1] = { item = r.item, qty = r.qty }
    end
    return {
        name = row.name, spell = row.spell, item = row.item, makes = makes,
        reagents = reagents, profession = profession, known = known,
        key = profession .. ":" .. tostring(row.spell or (row.item .. ":" .. row.name)),
    }
end

-- A refresh uses a bounded quote snapshot. Never retain it across scans or require
-- live GetItemInfo. Weapons (2) and armor (4) can carry suffix variants an item ID cannot
-- tell apart, so they get no AH value; other recorded classes are priced by item ID.
function ns.PlannerResults(options)
    options = options or {}
    local db = AHSnapshotDB
    if type(db) ~= "table" or type(db.characters) ~= "table" then
        return nil, "No recorded characters. Open a profession window first."
    end
    local character = db.characters[ns.charKey()]
    if type(character) ~= "table" or type(character.professions) ~= "table" then
        return nil, "No professions recorded for this character. Open a profession window first."
    end
    local items = type(db.items) == "table" and db.items or {}
    local vendors = type(db.vendor) == "table" and db.vendor or {}
    local quotes, recipes, skipped, professions = {}, {}, 0, {}
    local ctx = {
        settings = { exits = options.exit and { [options.exit] = true } or nil },
        price = function(id)
            if not quotes[id] then
                local info = items[id]
                local class = type(info) == "table" and info.class
                local kind = type(class) == "number" and class ~= 2 and class ~= 4 and "commodity" or "unverified"
                quotes[id] = ns.AuctionatorQuote(id, kind)
            end
            return quotes[id].unit
        end,
        vendorBuy = function(id) return vendors[id] end,
        vendorSell = function(id)
            local info = items[id]
            return type(info) == "table" and info.sell or nil
        end,
    }
    local seen = {}
    for profession, data in pairs(character.professions) do
        if type(profession) == "string" and type(data) == "table" then
            professions[#professions + 1] = profession
            for _, category in ipairs({ "recipes", "available" }) do
                local rows = data[category]
                for _, row in ipairs(type(rows) == "table" and rows or {}) do
                    local recipe = recipeCopy(row, profession, category == "recipes")
                    if not recipe then
                        skipped = skipped + 1
                    elseif not seen[recipe.key] then
                        seen[recipe.key] = true
                        recipes[#recipes + 1] = recipe
                    end
                end
            end
        end
    end
    table.sort(professions)
    local refined, ambiguous = {}, {}
    for _, recipe in ipairs(recipes) do
        if recipe.known and #recipe.reagents == 1 then
            local raw = recipe.reagents[1]
            local per = raw.qty / recipe.makes
            local product = items[recipe.item]
            if type(product) == "table" and product.class == 7 and raw.item ~= recipe.item
                and integer(per, 1, 100000) then
                local previous = refined[recipe.item]
                if previous and (previous.raw ~= raw.item or previous.per ~= per) then ambiguous[recipe.item] = true end
                refined[recipe.item] = { raw = raw.item, per = per }
            end
        end
    end
    for item in pairs(ambiguous) do refined[item] = nil end
    ctx.refined = refined
    local results = {}
    local search = (options.search or ""):lower()
    for _, recipe in ipairs(recipes) do
        if (not options.profession or recipe.profession == options.profession)
            and (not options.knownOnly or recipe.known)
            and (not options.unlearnedOnly or not recipe.known)
            and (search == "" or recipe.name:lower():find(search, 1, true)) then
            results[#results + 1] = ns.Evaluate(recipe, ctx)
        end
    end
    return ns.RankEvaluations(results), nil, {
        quotes = quotes, skipped = skipped, professions = professions, provider = ns.PriceProviderStatus(), context = ctx,
    }
end

function ns.PlannerBatchResult(result, info, costs)
    if not result or type(info) ~= "table" or type(info.context) ~= "table" then return nil end
    local base = info.context
    return ns.Evaluate(result.recipe, {
        price = base.price, vendorBuy = base.vendorBuy, vendorSell = base.vendorSell,
        refined = base.refined, settings = base.settings, customCosts = costs,
    })
end

function ns.CanActivatePlannerResult(result, batch)
    local recipe = result and result.recipe
    if not recipe or not recipe.known then return nil, "Only a learned recipe can become the active shuffle." end
    if result.invalid or result.exploratory
        or not finite(result.cost) or result.cost < 0 or not finite(result.net) or result.net < 0
        or not finite(result.profit) then
        return nil, "Needs a price for every reagent and a priced sale exit (Vendor or AH)."
    end
    if (result.exit ~= "Vendor" and result.exit ~= "Sell on AH")
        or not integer(recipe.item, 1, 10000000) or not integer(recipe.spell, 1, 10000000)
        or type(recipe.reagents) ~= "table" or #recipe.reagents == 0 then
        return nil, "This recipe is missing a supported product, spell, reagents, or sale exit."
    end
    if not batch or not integer(batch.crafts, 1, 100000) or not integer(batch.items, 1, 100000)
        or batch.items ~= batch.crafts * (recipe.makes or 1)
        or not finite(batch.cost) or batch.cost < 0 or not finite(batch.revenue) or batch.revenue < 0
        or not finite(batch.profit) then
        return nil, "Enter 1 to 100000 finished items (crafts or budget) in the batch calculator."
    end
    if type(ns.PrepareShufflePlanChange) ~= "function" or type(ns.SetSnatchTarget) ~= "function" then
        return nil, "Shuffle execution is not ready yet; reload the addon and try again."
    end
    return true
end

function ns.ActivatePlannerResult(result, batch)
    local allowed, reason = ns.CanActivatePlannerResult(result, batch)
    if not allowed then return nil, reason end
    local recipe = result.recipe
    local items = type(AHSnapshotDB.items) == "table" and AHSnapshotDB.items or {}
    local plan = {
        version = 1, selectedAt = time(), recipe = recipe.name, spell = recipe.spell, item = recipe.item,
        itemName = type(items[recipe.item]) == "table" and items[recipe.item].name or recipe.name,
        exit = result.exit, makes = recipe.makes, reagents = {},
        estimate = { cost = result.cost, income = result.net },
    }
    for _, reagent in ipairs(recipe.reagents) do
        local copy = { item = reagent.item, qty = reagent.qty }
        for _, line in ipairs(result.reagents) do
            if line.item == reagent.item and line.rawItem and line.rawQty then
                copy.raw = { item = line.rawItem, qty = line.rawQty }
                break
            end
        end
        plan.reagents[#plan.reagents + 1] = copy
    end
    if not validPlan(plan) then return nil, "The generated shuffle plan failed validation." end

    local ok, reason = ns.PrepareShufflePlanChange()
    if not ok then return nil, reason end
    local previousPlan, previousSaved = ns.plan, AHSnapshotDB.activePlan
    ns.plan, AHSnapshotDB.activePlan = plan, plan
    ok, reason = ns.SetSnatchTarget(batch.items)
    if not ok then
        ns.plan, AHSnapshotDB.activePlan = previousPlan, previousSaved
        return nil, reason
    end
    if ns.RefreshShuffleTracker then ns.RefreshShuffleTracker() end
    if ns.RefreshSnatcher then ns.RefreshSnatcher() end
    if ns.RefreshBatchAnalytics then ns.RefreshBatchAnalytics() end
    return true
end
