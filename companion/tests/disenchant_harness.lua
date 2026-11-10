local ns, clock, timers, eventFrame, counts, loot, logs, stats
local function eq(actual, expected, message)
    assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function setup(manual)
    clock, timers, counts, loot, logs, stats = 0, {}, { [20] = 1 }, { { item = 30, qty = 2 } }, {}, {}
    AHSnapshotDB = {}
    GetTime = function() return clock end
    time = function() return 1000 + math.floor(clock) end
    GetBuildInfo = function() return "test-version", "test-build", "date", 16001 end
    WOW_PROJECT_ID = 99
    C_Container = { GetContainerItemLink = function() return "item:20" end }
    C_Item = {
        GetItemCount = function(id, bank) assert(not bank); return counts[id] or 0 end,
        GetItemInfo = function(id) return "Test", "item:" .. id, 2, 15, nil, nil, nil, nil, nil, nil, nil, 4 end,
    }
    GetNumLootItems = function() return #loot end
    GetLootSlotLink = function(i) return loot[i].item and ("item:" .. loot[i].item) end
    GetLootSlotInfo = function(i) return nil, "Material", loot[i].qty end
    C_Timer = { After = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end }
    CreateFrame = function()
        eventFrame = {
            RegisterEvent = function() end,
            RegisterUnitEvent = function() end,
            SetScript = function(self, _, fn) self.onEvent = fn end,
        }
        return eventFrame
    end
    SpellTargetItem = manual and function() end or nil
    hooksecurefunc = function(name, fn)
        local original = _G[name]
        _G[name] = function(...) original(...); fn(...) end
    end
    ns = {
        log = function(text) logs[#logs + 1] = text end,
        RecordItem = function() end,
        BatchStatsDisenchanted = function(item) stats[#stats + 1] = item end,
    }
    assert(loadfile("addon/ShuffleDetector/Disenchant.lua"))("ShuffleDetector", ns)
end

local function event(name, ...)
    eventFrame.onEvent(eventFrame, name, ...)
end

local function advance(seconds)
    local finish = clock + seconds
    while #timers > 0 do
        table.sort(timers, function(a, b) return a.at < b.at end)
        if timers[1].at > finish then break end
        local timer = table.remove(timers, 1)
        clock = timer.at
        timer.fn()
    end
    clock = finish
end

local function start()
    ns.NoteDisenchantTarget(0, 1, "shuffle")
    event("UNIT_SPELLCAST_START", "player", "cast", 13262)
end

local function succeed()
    event("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 13262)
end

local function sampleCount()
    return #(AHSnapshotDB.disenchants or {})
end

setup()
local legacy = { item = 99, loot = { { item = 88, qty = 1 } }, time = 1 }
AHSnapshotDB.disenchants = { legacy }
start()
advance(4)
succeed()
counts[20] = 0
event("LOOT_OPENED")
eq(sampleCount(), 2, "cast duration does not expire its captured target")
eq(AHSnapshotDB.disenchants[1], legacy, "legacy observations are unchanged")
eq(legacy.capture, nil, "legacy client identity is not fabricated")
local sample = AHSnapshotDB.disenchants[2]
eq(sample.item, 20)
eq(sample.loot[1].item, 30)
eq(sample.loot[1].qty, 2)
eq(sample.class, 4)
eq(sample.complete, true)
eq(sample.capture.target, "shuffle")
eq(sample.capture.client.build, "test-build")
succeed()
event("LOOT_OPENED")
advance(5)
eq(sampleCount(), 2, "duplicate success and loot events cannot double count")
eq(#stats, 1, "duplicate success cannot double count statistics")

setup(true)
event("UNIT_SPELLCAST_START", "player", "cast", 13262)
SpellTargetItem(0, 1)
advance(4)
succeed()
counts[20] = 0
event("LOOT_OPENED")
eq(sampleCount(), 1, "manual hook may arrive after cast start")
eq(AHSnapshotDB.disenchants[1].capture.target, "SpellTargetItem")

setup(true)
start()
counts[21] = 1
C_Container.GetContainerItemLink = function() return "item:21" end
SpellTargetItem(0, 2)
succeed()
counts[20] = 0
event("LOOT_OPENED")
eq(AHSnapshotDB.disenchants[1].item, 20, "rejected targeting attempts cannot replace a bound cast target")
eq(stats[1], 20)

setup()
start()
succeed()
counts[20] = 0
loot = { { qty = 2 } }
event("LOOT_OPENED")
eq(sampleCount(), 0, "missing item links never become zero-yield observations")
advance(0.2)
loot[1].item = 30
advance(0.2)
eq(sampleCount(), 1, "delayed complete loot is retried")

setup()
start()
succeed()
counts[20] = 0
loot = { { item = 30, qty = 2 }, { qty = 1 } }
event("LOOT_OPENED")
event("LOOT_SLOT_CLEARED", 1)
loot = { { item = 40, qty = 1 } }
advance(1)
eq(sampleCount(), 0, "cleared partial windows cannot masquerade as full outcomes")
assert(logs[#logs]:find("sample skipped", 1, true))

setup()
start()
succeed()
loot = {}
event("LOOT_OPENED")
event("LOOT_CLOSED")
advance(4)
eq(sampleCount(), 0, "empty/closed loot is incomplete, not a measured zero")

setup()
start()
succeed()
event("LOOT_OPENED")
eq(sampleCount(), 0, "unconfirmed consumption cannot attribute unrelated loot")
counts[20] = 0
event("BAG_UPDATE_DELAYED")
eq(sampleCount(), 1, "late bag confirmation can complete the capture")

setup()
start()
succeed()
counts[20] = 0
loot[1].qty = nil
event("LOOT_OPENED")
advance(4)
loot[1].qty = 2
event("LOOT_OPENED")
eq(sampleCount(), 0, "unknown quantities time out rather than defaulting to one")
assert(logs[#logs]:find("sample skipped", 1, true))

setup()
start()
event("UNIT_SPELLCAST_SUCCEEDED", "other", "cast", 13262)
event("UNIT_SPELLCAST_SUCCEEDED", "player", "different-cast", 13262)
eq(#stats, 0)
event("UNIT_SPELLCAST_INTERRUPTED", "player", "cast", 13262)
succeed()
counts[20] = 0
event("LOOT_OPENED")
eq(sampleCount(), 0, "interrupted/mismatched casts cannot capture later loot")

setup()
ns.NoteDisenchantTarget(0, 1, "shuffle")
advance(4)
event("UNIT_SPELLCAST_START", "player", "cast", 13262)
succeed()
counts[20] = 0
event("LOOT_OPENED")
eq(sampleCount(), 0, "a stale target is not reused by a later cast")

print("disenchant checks passed")
