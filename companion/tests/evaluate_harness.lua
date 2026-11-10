local function eq(actual, expected, message)
    assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function near(actual, expected, message)
    assert(type(actual) == "number" and math.abs(actual - expected) < 1e-9,
        (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local ns = {}
assert(loadfile("addon/ShuffleDetector/Evaluate.lua"))("ShuffleDetector", ns)

local function exit(res, label)
    for _, e in ipairs(res.exits) do if e.label == label then return e end end
end

-- Synthetic values only; no real game data.
local prices, vendorBuy, vendorSell = {}, {}, {}
local ctx = {
    price = function(id) return prices[id] end,
    vendorBuy = function(id) return vendorBuy[id] end,
    vendorSell = function(id) return vendorSell[id] end,
    refined = { [11] = { raw = 10, per = 2 } },
    settings = {},
}

local bundle = {
    disenchant = {
        { class = 4, quality = 2, low = 5, high = 15, status = "exploratory", source = "x",
          expected = { { item = 30, avg = 2 } } },
        { class = 4, quality = 2, low = 5, high = 15, status = "trusted", source = "t",
          outcomes = { { probability = 0.75, loot = { { item = 30, qty = 1 } } },
                       { probability = 0.25, loot = { { item = 30, qty = 2 }, { item = 31, qty = 1 } } } } },
        { class = 2, quality = 2, low = 5, high = 15, status = "exploratory", source = "x",
          expected = { { item = 30, avg = 1 } } },
    },
    exclusions = { { item = 99, reason = "wand", source = "t", status = "trusted" } },
}

local model = ns.DisenchantModel(bundle, { item = 20, class = 4, quality = 2, ilvl = 10 })
eq(model.status, "trusted", "trusted band wins over an overlapping exploratory band")
near(model.expected[30], 1.25, "outcome distribution gives expected quantities")
near(model.expected[31], 0.25)
local excluded, why = ns.DisenchantModel(bundle, { item = 99, class = 4, quality = 2, ilvl = 10 })
eq(excluded, false, "documented exclusions are not disenchantable")
eq(why, "wand")
local unknown, reason = ns.DisenchantModel(bundle, { item = 21, class = 4, quality = 3, ilvl = 10 })
eq(unknown, nil, "no band is unknown, not an empty yield")
eq(reason, "unknown")
eq((ns.DisenchantModel(bundle, { item = 21, class = 4, quality = 2 })), nil, "missing item level is unknown")
eq(ns.DisenchantModel(bundle, { item = 22, class = 2, quality = 2, ilvl = 6 }).status, "exploratory")

local recipe = { name = "Piece", item = 20, makes = 1, reagents = { { item = 11, qty = 3 } }, disenchant = model }

-- Reagent cost: AH, vendor or crafting from the raw item, cheapest wins.
prices[11], prices[10] = 50, 10
local res = ns.Evaluate(recipe, ctx)
eq(res.cost, 60, "making the refined reagent from raw is cheaper")
eq(res.reagents[1].source, "Craft from raw")
vendorBuy[11] = 15
eq(ns.Evaluate(recipe, ctx).cost, 45, "vendor price wins when cheapest")
vendorBuy[11], prices[11], prices[10] = nil, nil, nil
res = ns.Evaluate(recipe, ctx)
eq(res.cost, nil, "an unpriced reagent leaves cost unknown, not free")
eq(res.missing[1], 11)
eq(res.profit, nil)

-- Disenchant exit: partially priced yields are unknown, never a partial value.
prices[11] = 10
prices[30] = 100
res = ns.Evaluate(recipe, ctx)
eq(exit(res, "Disenchant").net, nil, "partly priced DE has no value")
eq(exit(res, "Disenchant").reason, "unpriced yields")
eq(exit(res, "Disenchant").missing[1], 31)
eq(res.exit, nil, "no exit is chosen from incomplete data")
prices[31] = 0
res = ns.Evaluate(recipe, ctx)
near(exit(res, "Disenchant").gross, 125, "a zero price is a value, unlike nil")
near(res.net, 125 * 0.95)
eq(res.exit, "Disenchant")
near(res.profit, 125 * 0.95 - 30)
near(res.roi, (125 * 0.95 - 30) / 30)
eq(res.seconds, 33)

-- Multi-output crafts scale DE output and disenchant time with makes.
recipe.makes = 2
res = ns.Evaluate(recipe, ctx)
near(exit(res, "Disenchant").gross, 250, "two pieces disenchant twice")
eq(res.seconds, 36, "two disenchants per craft")
recipe.makes = 1.5
eq(ns.Evaluate(recipe, ctx).invalid, "makes", "fractional makes is rejected")
recipe.makes = 1

-- Unknown and not-disenchantable recipes.
recipe.disenchant = nil
res = ns.Evaluate(recipe, ctx)
eq(exit(res, "Disenchant").reason, "unknown yields", "unknown yields are shown, not zero")
eq(res.exit, nil)
recipe.disenchant = false
eq(exit(ns.Evaluate(recipe, ctx), "Disenchant"), nil, "excluded items have no DE exit")

-- AH and vendor exits; vendor sell price 0 means unsellable, nil means unknown.
prices[20] = 40
vendorSell[20] = 0
res = ns.Evaluate(recipe, ctx)
eq(exit(res, "Vendor").reason, "cannot be sold to a vendor")
eq(res.exit, "Sell on AH", "vendor-only or AH exits work without DE yields")
near(res.net, 38)
vendorSell[20] = nil
eq(exit(ns.Evaluate(recipe, ctx), "Vendor").reason, "unknown vendor price")
prices[20] = nil
vendorSell[20] = 50
res = ns.Evaluate(recipe, ctx)
eq(res.exit, "Vendor", "vendor exit needs no AH price for the product")
eq(res.net, 50)

-- Exploratory models never enter the normal ranking unless explicitly enabled.
recipe.disenchant = { status = "exploratory", source = "x", expected = { [30] = 2 } }
res = ns.Evaluate(recipe, ctx)
near(exit(res, "Disenchant").net, 190)
eq(exit(res, "Disenchant").exploratory, true)
eq(res.exit, "Vendor", "exploratory DE is not chosen in the normal view")
ctx.settings = { exploratory = true }
res = ns.Evaluate(recipe, ctx)
eq(res.exit, "Disenchant", "exploratory view may choose it")
eq(res.exploratory, true, "and labels the result")
ctx.settings = { exits = { Vendor = true } }
eq(ns.Evaluate(recipe, ctx).exit, "Vendor", "disabled exits are skipped")
ctx.settings = {}

-- Providers that error or return invalid numbers count as unknown.
ctx.price = function(id) if id == 20 then error("boom") end return 0 / 0 end
res = ns.Evaluate(recipe, ctx)
eq(res.cost, nil, "NaN is not a price")
eq(exit(res, "Sell on AH").reason, "no price", "provider errors are unknown")

-- Ranking: complete profits first, best first, then incomplete; ties by name.
local ranked = ns.RankEvaluations({
    { recipe = { name = "c" } },
    { recipe = { name = "b" }, profit = 5 },
    { recipe = { name = "a" }, profit = 5 },
    { recipe = { name = "d" }, profit = -1 },
    { recipe = { name = "e" }, profit = 9 },
})
eq(ranked[1].recipe.name, "e")
eq(ranked[2].recipe.name, "a")
eq(ranked[3].recipe.name, "b")
eq(ranked[4].recipe.name, "d")
eq(ranked[5].recipe.name, "c", "incomplete results rank last")

print("evaluate checks passed")
