-- Overwritten by the companion app ("Send to game"); read by Shuffle.lua after /reload.
-- Format: see common/docs/FORMAT.md. Shuffle.lua resolves timestamp precedence
-- between a generated plan and an in-game selection.
local _, ns = ...
if not ns.plan and type(AHSnapshotDB) == "table" and type(AHSnapshotDB.activePlan) == "table"
    and ns.ValidateActivePlan and ns.ValidateActivePlan(AHSnapshotDB.activePlan) then
    ns.plan = AHSnapshotDB.activePlan
end
