local _, ns = ...
local MAX_CRAFTS, MAX_ITEMS = 100000, 100000

local function integer(n, low, high)
    return type(n) == "number" and n >= low and n <= high and n == math.floor(n)
end

function ns.CalculateBatch(result, mode, amount)
    if mode ~= "crafts" and mode ~= "budget" then return nil, "Choose crafts or budget." end
    local limit = mode == "crafts" and MAX_CRAFTS or 100000000000
    if not integer(amount, 0, limit) then
        return nil, "Enter a whole number from 0 to " .. limit .. (mode == "budget" and " copper." or " crafts.")
    end
    if not result or result.invalid then return nil, "Recipe cannot be evaluated." end
    local crafts, capped = amount, false
    if mode == "budget" then
        if result.cost == nil then return nil, "Budget needs prices for every reagent." end
        if result.cost == 0 then
            crafts, capped = MAX_CRAFTS, true
        else
            crafts = math.floor(amount / result.cost)
            capped = crafts > MAX_CRAFTS
            crafts = math.min(crafts, MAX_CRAFTS)
        end
    end
    local batch = {
        crafts = crafts, items = crafts * result.makes, purchases = {}, outputs = {},
        seconds = crafts * result.seconds, capped = capped,
        marketDepth = "unknown", exit = result.exit,
    }
    if batch.items > MAX_ITEMS then
        batch.transferReason = "More than 100000 finished items: reduce crafts before sending to execution."
    end
    local purchases = {}
    for _, line in ipairs(result.reagents) do
        local raw = line.source == "Craft from raw"
        local id = raw and line.rawItem or line.item
        local qty = line.qty * crafts * (raw and line.rawQty or 1)
        local total = line.total and line.total * crafts
        local source = raw and line.rawSource or line.source
        local key = id .. ":" .. source
        local p = purchases[key]
        if not p then
            p = { item = id, qty = 0, source = source, total = total and 0 }
            purchases[key] = p
            batch.purchases[#batch.purchases + 1] = p
        end
        p.qty = p.qty + qty
        if raw then p.prepare = true end
        if total ~= nil and p.total ~= nil then p.total = p.total + total else p.total = nil end
    end
    if result.cost ~= nil then batch.cost = result.cost * crafts end
    if result.net ~= nil then batch.revenue = result.net * crafts end
    if batch.cost ~= nil and batch.revenue ~= nil then batch.profit = batch.revenue - batch.cost end
    if result.exit == "Disenchant" then
        for _, exit in ipairs(result.exits) do
            if exit.label == "Disenchant" then
                for _, y in ipairs(exit.yields or {}) do
                    batch.outputs[#batch.outputs + 1] = { item = y.item, expected = y.avg * crafts }
                end
            end
        end
    elseif result.recipe.item then
        batch.outputs[1] = { item = result.recipe.item, expected = batch.items }
    end
    return batch
end
