local _, ns = ...
local MAX_SAMPLES = 500
local MAX_EXACT_INTEGER = 9007199254740991

local function integer(value, minimum)
    return type(value) == "number" and value >= minimum and value <= MAX_EXACT_INTEGER and value == math.floor(value)
end

local function materials(sample)
    if type(sample) ~= "table" or sample.complete ~= true or not integer(sample.item, 1)
        or type(sample.loot) ~= "table" or #sample.loot == 0 then return nil, "incomplete sample" end
    local quantities, ids = {}, {}
    for _, material in ipairs(sample.loot) do
        if type(material) ~= "table" or not integer(material.item, 1) or not integer(material.qty, 1) then
            return nil, "invalid loot"
        end
        if not quantities[material.item] then ids[#ids + 1] = material.item end
        quantities[material.item] = (quantities[material.item] or 0) + material.qty
    end
    table.sort(ids)
    return quantities, ids
end

local function identity(sample)
    local capture = sample.capture
    local client = type(capture) == "table" and capture.client
    if sample.complete ~= true or type(capture) ~= "table" or capture.version ~= 2
        or type(client) ~= "table" then return nil, "legacy or incomplete capture identity" end
    for _, key in ipairs({ "version", "build", "realm" }) do
        if type(client[key]) ~= "string" or client[key] == "" then return nil, "missing client " .. key end
    end
    if not integer(client.interface, 1) or not integer(client.project, 1) then return nil, "missing client identifiers" end
    if not integer(sample.item, 1) or not integer(sample.class, 0)
        or not integer(sample.quality, 0) or not integer(sample.ilvl, 1) then return nil, "missing item identity" end
    local parts = {}
    for _, value in ipairs({ client.version, client.build, client.interface, client.project, client.realm }) do
        local text = tostring(value)
        parts[#parts + 1] = #text .. ":" .. text
    end
    return table.concat(parts), table.concat({ sample.item, sample.class, sample.quality, sample.ilvl }, "/"), client
end

local function aggregate(db, sample)
    if type(sample) ~= "table" then return false, "invalid sample" end
    local clientKey, itemKey, client = identity(sample)
    if not clientKey then return false, itemKey end
    local quantities, ids = materials(sample)
    if not quantities then return false, ids end
    local realm = db.clients[clientKey]
    if realm == nil then
        realm = { client = { version = client.version, build = client.build, interface = client.interface,
                            project = client.project, realm = client.realm }, items = {} }
        db.clients[clientKey] = realm
    end
    if type(realm) ~= "table" or type(realm.items) ~= "table" then return false, "invalid saved client aggregate" end
    local group = realm.items[itemKey]
    if group == nil then
        group = { item = sample.item, class = sample.class, quality = sample.quality, ilvl = sample.ilvl,
                  samples = 0, sums = {}, products = {}, outcomes = {} }
        realm.items[itemKey] = group
    end
    if type(group) ~= "table" or not integer(group.samples, 0)
        or type(group.sums) ~= "table" or type(group.products) ~= "table" or type(group.outcomes) ~= "table" then
        return false, "invalid saved item aggregate"
    end
    if not integer(group.samples + 1, 1) then return false, "sample count exceeds exact numeric range" end
    local outcome = {}
    for _, id in ipairs(ids) do
        if group.sums[id] ~= nil and not integer(group.sums[id], 0) then return false, "invalid material sum" end
        if not integer((group.sums[id] or 0) + quantities[id], 1) then return false, "material sum exceeds exact numeric range" end
        if group.products[id] ~= nil and type(group.products[id]) ~= "table" then return false, "invalid product sums" end
        for _, other in ipairs(ids) do
            local value = group.products[id] and group.products[id][other]
            if value ~= nil and not integer(value, 0) then return false, "invalid product sum" end
            if not integer((value or 0) + quantities[id] * quantities[other], 1) then
                return false, "product sum exceeds exact numeric range"
            end
        end
        outcome[#outcome + 1] = id .. ":" .. quantities[id]
    end
    local key = table.concat(outcome, ",")
    if group.outcomes[key] ~= nil and not integer(group.outcomes[key], 0) then return false, "invalid outcome count" end
    if not integer((group.outcomes[key] or 0) + 1, 1) then return false, "outcome count exceeds exact numeric range" end
    group.samples = group.samples + 1
    for _, id in ipairs(ids) do
        group.sums[id] = (group.sums[id] or 0) + quantities[id]
        group.products[id] = group.products[id] or {}
        for _, other in ipairs(ids) do
            group.products[id][other] = (group.products[id][other] or 0) + quantities[id] * quantities[other]
        end
    end
    group.outcomes[key] = (group.outcomes[key] or 0) + 1
    return true
end

local function statistics(history)
    local db = AHSnapshotDB.disenchantStats
    if db == nil then
        db = { version = 1, clients = {}, seeded = 0, unversioned = 0 }
        for _, sample in ipairs(history) do
            if aggregate(db, sample) then db.seeded = db.seeded + 1
            else db.unversioned = db.unversioned + 1 end
        end
        AHSnapshotDB.disenchantStats = db
        if db.unversioned > 0 then
            ns.log("disenchant: preserved " .. db.unversioned .. " legacy/incomplete samples outside versioned aggregates")
        end
    elseif type(db) ~= "table" or db.version ~= 1 or type(db.clients) ~= "table" then
        ns.log("disenchant aggregates unavailable: unsupported or invalid saved format; raw history retained")
        return
    end
    return db
end

function ns.RecordDisenchantSample(sample)
    local quantities, reason = materials(sample)
    if not quantities then
        ns.log("disenchant sample not saved: " .. reason)
        return false
    end
    local history = AHSnapshotDB.disenchants
    if history == nil then
        history = {}
        AHSnapshotDB.disenchants = history
    elseif type(history) ~= "table" then
        ns.log("disenchant sample not saved: invalid history; existing value preserved")
        return false
    end
    local db = statistics(history)
    if db then
        local ok, reason = aggregate(db, sample)
        if not ok then ns.log("disenchant sample not aggregated: " .. reason) end
    end
    history[#history + 1] = sample
    while #history > MAX_SAMPLES do table.remove(history, 1) end
    return true
end
