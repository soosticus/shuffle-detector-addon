local _, ns = ...

local function integer(n, low, high)
    return type(n) == "number" and n >= low and n <= high and n == math.floor(n)
end

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
-- live GetItemInfo: recorded class 7 (trade goods) establishes the supported identity.
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
                local kind = type(info) == "table" and info.class == 7 and "commodity" or "unverified"
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
        quotes = quotes, skipped = skipped, professions = professions, provider = ns.PriceProviderStatus(),
    }
end
