-- =============================================================================
-- VAS Copy Station Logistic Config -- Lua side
-- =============================================================================
-- Listens for the MD-raised event "VAS_CSL.Apply" (param: target station) and
-- copies the SOURCE station's per-ware logistic config onto the target:
-- storage allocation, buy/sell offers, prices, trade rules, and (optionally)
-- the shared drone-pool configuration. SOURCE, the selected-ware filter and
-- the copyDroneConfig flag live on the player blackboard
-- (player.entity.$vas_csl_data) — set up by the MD before raising the event.
--
-- The companion file simple_menu_checkbox_bridge.lua handles a SirNukes
-- Simple_Menu_API workaround for checkbox state updates; see its header.
--
-- Debug logging is driven by the MD-side `$debugchance` value
-- (player.entity.$vas_csl_debug_chance) — any value > 0 emits a single
-- multi-line DebugError block per apply pass. Defaults to 0 (silent).
-- =============================================================================

local ffi = require("ffi")
local C = ffi.C

-- ----------------------------------------------------------------------------
-- FFI cdefs. Only the calls we actually use. Signatures lifted verbatim from
-- ui/addons/ego_detailmonitorhelper/helper.lua so the LuaJIT FFI matches the
-- engine's symbols.
-- ----------------------------------------------------------------------------
ffi.cdef[[
    typedef uint64_t UniverseID;
    typedef int32_t  TradeRuleID;

    // Storage info per transport type (solid / liquid / container / condensate)
    typedef struct {
        const char* name;
        const char* transport;
        uint32_t spaceused;
        uint32_t capacity;
    } StorageInfo;

    // Per-ware manual storage-allocation override (in units, not m^3)
    typedef struct {
        const char* ware;
        const char* macro;
        int amount;
    } UIWareInfo;

    typedef struct {
        const char* macro;
        int amount;
    } SupplyOverride;

    typedef struct {
        float x;
        float y;
        float z;
        float yaw;
        float pitch;
        float roll;
    } UIPosRot;

    typedef struct {
        size_t idx;
        const char* macroid;
        UniverseID componentid;
        UIPosRot offset;
        const char* connectionid;
        size_t predecessoridx;
        const char* predecessorconnectionid;
        bool isfixed;
    } UIConstructionPlanEntry;

    // Storage capacity enumeration (used for the capacity-clamp check below)
    uint32_t GetNumCargoTransportTypes(UniverseID containerid, bool merge);
    uint32_t GetCargoTransportTypes(StorageInfo* result, uint32_t resultlen,
                                    UniverseID containerid, bool merge, bool aftertradeorders);

    // Per-ware manual storage-allocation overrides (read)
    uint32_t GetNumContainerStockLimitOverrides(UniverseID containerid);
    uint32_t GetContainerStockLimitOverrides(UIWareInfo* result, uint32_t resultlen,
                                             UniverseID containerid);

    // Construction-plan enumeration. Used to mirror the vanilla LSO's planned
    // production/processing ware rows for under-construction stations.
    size_t   GetNumBuildMapConstructionPlan(UniverseID holomapid, bool usestoredplan);
    size_t   GetBuildMapConstructionPlan(UniverseID holomapid, UniverseID defensibleid,
                                         bool usestoredplan, UIConstructionPlanEntry* result,
                                         uint32_t resultlen);
    size_t   GetNumPlannedStationModules(UniverseID defensibleid, bool includeall);
    size_t   GetPlannedStationModules(UIConstructionPlanEntry* result, uint32_t resultlen,
                                      UniverseID defensibleid, bool includeall);
    uint32_t GetNumRemovedConstructionPlanModules2(UniverseID holomapid, UniverseID defensibleid,
                                                   uint32_t* newIndex, bool usestoredplan,
                                                   uint32_t* numChangedIndices, bool checkupgrades);
    uint32_t GetRemovedConstructionPlanModules2(UniverseID* result, uint32_t resultlen,
                                                uint32_t* changedIndices,
                                                uint32_t* numChangedIndices);
    uint32_t GetNumRemovedStationModules2(UniverseID defensibleid, uint32_t* newIndex,
                                          uint32_t* numChangedIndices, bool checkupgrades);
    uint32_t GetRemovedStationModules2(UniverseID* result, uint32_t resultlen,
                                       uint32_t* changedIndices,
                                       uint32_t* numChangedIndices);

    // read: amounts + override flags
    int32_t  GetContainerBuyLimit(UniverseID containerid, const char* wareid);
    int32_t  GetContainerSellLimit(UniverseID containerid, const char* wareid);
    bool     HasContainerBuyLimitOverride(UniverseID containerid, const char* wareid);
    bool     HasContainerSellLimitOverride(UniverseID containerid, const char* wareid);

    // read: per-ware buy/sell offer toggle (does the station expose an offer for this ware)
    bool     GetContainerWareIsBuyable(UniverseID containerid, const char* wareid);
    bool     GetContainerWareIsSellable(UniverseID containerid, const char* wareid);

    // read: trade rule per ware x type
    TradeRuleID GetContainerTradeRuleID(UniverseID containerid, const char* ruletype, const char* wareid);
    bool        HasContainerOwnTradeRule(UniverseID containerid, const char* ruletype, const char* wareid);

    // (GetWareCapacity is NOT an FFI symbol -- it's a Lua global wrapper. Do not
    //  cdef it here; call it as plain GetWareCapacity(...) from Lua code below.)

    // write: (step 3, declared now for completeness)
    void  SetContainerBuyLimitOverride(UniverseID containerid, const char* wareid, int32_t amount);
    void  SetContainerSellLimitOverride(UniverseID containerid, const char* wareid, int32_t amount);
    void  ClearContainerBuyLimitOverride(UniverseID containerid, const char* wareid);
    void  ClearContainerSellLimitOverride(UniverseID containerid, const char* wareid);
    void  SetContainerWareIsBuyable(UniverseID containerid, const char* wareid, bool allowed);
    void  SetContainerWareIsSellable(UniverseID containerid, const char* wareid, bool allowed);
    void  SetContainerTradeRule(UniverseID containerid, TradeRuleID id, const char* ruletype, const char* wareid, bool value);
    void  AddTradeWare(UniverseID containerid, const char* wareid);
    void  RemoveTradeWare(UniverseID containerid, const char* wareid);

    bool     IsSupplyManual(UniverseID containerid, const char* type);
    void     SetSupplyManual(UniverseID containerid, const char* type, bool onoff);
    uint32_t GetNumSupplyOrders(UniverseID containerid, bool defaultorders);
    uint32_t GetSupplyOrders(SupplyOverride* result, uint32_t resultlen,
                             UniverseID containerid, bool defaultorders);
    void     UpdateSupplyOverrides(UniverseID containerid, SupplyOverride* overrides,
                                   uint32_t numoverrides);
    void     UpdateProductionTradeOffers(UniverseID containerid);
]]

-- ----------------------------------------------------------------------------
-- Engine-provided Lua wrappers (no C. prefix). Listed here for reference; we
-- just call them by their global name.
--
--   GetContainerWarePrice(container, ware, isBuy)         -> price (int, in cents)
--   HasContainerWarePriceOverride(container, ware, isBuy) -> bool
--   SetContainerWarePriceOverride(container, ware, isBuy, price)
--   ClearContainerWarePriceOverride(container, ware, isBuy)
--   SetContainerStockLimitOverride(container, ware, amount)
--   ClearContainerStockLimitOverride(container, ware)
--   GetWareProductionLimit(container, ware) -> int (auto allocation when override off)
--   GetComponentData(component_id, key) -> any -- generic property accessor
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Debug logging
-- ----------------------------------------------------------------------------
-- Every line is buffered into logBuffer; flushDebug() concatenates and emits
-- a single DebugError call, so the in-game log shows ONE multi-line block per
-- apply pass instead of dozens of separate "..." entries that are tedious to
-- copy-paste. flushDebug is called at the end of applyCopy and before every
-- early-return inside it; an outer pcall in the event handler guarantees the
-- buffer is flushed even on unexpected errors.
-- ----------------------------------------------------------------------------
-- Debug toggle is driven from the MD side via player.entity.$vas_csl_debug_chance
-- (int 0..100, the conventional debug_to_file `chance` value used across X4
-- modding). Any value > 0 enables logging.
local cachedPlayerID
local function isDebugEnabled()
    if not cachedPlayerID then
        cachedPlayerID = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    end
    local chance = GetNPCBlackboard(cachedPlayerID, "$vas_csl_debug_chance")
    return type(chance) == "number" and chance > 0
end

local logBuffer = {}

local function debug(msg)
    if not isDebugEnabled() then return end
    table.insert(logBuffer, "[VAS-CSL] " .. tostring(msg))
end

local function flushDebug()
    if #logBuffer == 0 then return end
    if type(DebugError) == "function" then
        DebugError(table.concat(logBuffer, "\n"))
    end
    logBuffer = {}
end

-- ----------------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------------

-- Safely convert a station handle (whatever the MD sends) to a 64-bit
-- UniverseID. The MD param arrives as a Lua string like "[component:0x12345]"
-- and ConvertStringTo64Bit + tostring is the canonical wrap.
local function toUID(handle)
    if handle == nil then return nil end
    local ok, uid = pcall(ConvertStringTo64Bit, tostring(handle))
    if not ok or uid == nil then return nil end
    return uid
end

-- Get the list of wares this station "handles". Mirrors the LSO menu's union
-- (see vanilla menu_station_overview.lua, onExpandTradeWares):
--   allresources -- wares production CONSUMES (raw materials)
--   products     -- wares production OUTPUTS
--   cargo        -- table keyed by ware-id of current stock; we want the keys
--                  (use pairs, not ipairs)
--   tradewares   -- wares with explicit buy/sell offers (subset of the above
--                  for most stations, but can include user-added trade wares
--                  that have no production link)
--
-- A ware showing up in any of these four lists is "handled". This is broader
-- than tradewares alone, which is what we had before -- and matches what the
-- player sees in the Logical Station Overview.
local function getStationWares(stationid)
    local allresources, allproducts, cargo, rawtradewares = GetComponentData(
        stationid, "allresources", "products", "cargo", "tradewares")

    local seen = {}
    local wares = {}

    local function add(ware)
        if type(ware) == "string" and ware ~= "" and not seen[ware] then
            seen[ware] = true
            table.insert(wares, ware)
        end
    end

    if type(allresources) == "table" then
        for _, ware in ipairs(allresources) do add(ware) end
    end
    if type(allproducts) == "table" then
        for _, ware in ipairs(allproducts) do add(ware) end
    end
    if type(cargo) == "table" then
        -- cargo is keyed by ware-id, value is an info subtable; iterate keys.
        for ware, _ in pairs(cargo) do add(ware) end
    end
    if type(rawtradewares) == "table" then
        for _, ware in ipairs(rawtradewares) do add(ware) end
    end

    debug(string.format(
        "getStationWares: resources=%s products=%s cargo=%s tradewares=%s -> union=%d",
        tostring(allresources and #allresources or 0),
        tostring(allproducts and #allproducts or 0),
        tostring(cargo and "table" or "nil"),
        tostring(rawtradewares and #rawtradewares or 0),
        #wares))

    return wares
end

local droneTypes = {
    { unitType = "transport", supplyType = "units_trade" },
    { unitType = "defence",   supplyType = "units_defence" },
    { unitType = "repair",    supplyType = "units_repair" },
    { unitType = "build",     supplyType = "units_build" },
}

local function readSupplyOrders(container, defaultorders)
    local result = {}
    local okN, n = pcall(function()
        return C.GetNumSupplyOrders(container, defaultorders)
    end)
    if not okN then
        debug(string.format("drones: GetNumSupplyOrders(default=%s) failed: %s",
            tostring(defaultorders), tostring(n)))
        return result
    end

    local buf = ffi.new("SupplyOverride[?]", n)
    local okRead, count = pcall(function()
        return C.GetSupplyOrders(buf, n, container, defaultorders)
    end)
    if not okRead then
        debug(string.format("drones: GetSupplyOrders(default=%s) failed: %s",
            tostring(defaultorders), tostring(count)))
        return result
    end

    for i = 0, count - 1 do
        local macro = ffi.string(buf[i].macro)
        result[macro] = buf[i].amount
    end
    return result
end

local function readUnitStorage(container, unitType)
    local ok, units = pcall(GetUnitStorageData, container, unitType)
    if not ok or type(units) ~= "table" then
        debug(string.format("drones: GetUnitStorageData(%s) failed: %s",
            tostring(unitType), tostring(units)))
        return { list = {}, byMacro = {}, capacity = 0, stored = 0 }
    end

    local data = {
        list = {},
        byMacro = {},
        capacity = tonumber(units.capacity) or 0,
        stored = 0,
    }
    for _, entry in ipairs(units) do
        if type(entry.macro) == "string" then
            local normalized = {
                macro = entry.macro,
                name = entry.name or entry.macro,
                amount = tonumber(entry.amount) or 0,
            }
            table.insert(data.list, normalized)
            data.byMacro[normalized.macro] = normalized
            data.stored = data.stored + normalized.amount
        end
    end
    return data
end

local function readUnitStorageSummary(container)
    local ok, units = pcall(GetUnitStorageData, container)
    if not ok or type(units) ~= "table" then
        return { capacity = 0, stored = 0 }
    end
    return {
        capacity = tonumber(units.capacity) or 0,
        stored = tonumber(units.stored) or 0,
    }
end

local function makeCStringKeeper()
    local keepalive = {}
    local function keep(str)
        local cstr = ffi.new("char[?]", #str + 1)
        ffi.copy(cstr, str)
        table.insert(keepalive, cstr)
        return cstr
    end
    return keep, keepalive
end

local function updateSupplyOverrides(container, overrides)
    local count = 0
    for _, _ in pairs(overrides) do
        count = count + 1
    end

    local buf = ffi.new("SupplyOverride[?]", count)
    local keepCString = makeCStringKeeper()
    local idx = 0
    for macro, amount in pairs(overrides) do
        buf[idx].macro = keepCString(macro)
        buf[idx].amount = amount
        idx = idx + 1
    end

    C.UpdateSupplyOverrides(container, buf, count)
end

-- Drone storage uses a single shared pool across cargo/defence/repair (build is
-- internal and always zero for stations). Override semantics, lifted verbatim
-- from vanilla menu_station_overview.lua:
--   AUTO:   override = absolute projected total (stored + inbound)
--           pool usage for this macro = max(stored, override or default)
--   MANUAL: override = inbound delta; projected = stored + override
--           pool usage for this macro = stored + max(0, override)
--
-- Apply rules (per user spec):
--   * Process types in order: transport (cargo) -> defence -> repair.
--     Build type is left entirely alone (no mode sync, no override changes) --
--     it's station-internal and stations don't construct ships.
--   * Never destroy stored drones; if targetStored >= sourceProjected, keep
--     targetStored and zero the inbound (cancel pending orders).
--   * Pool budget is the shared capacity minus current pool usage of every
--     drone macro on target. When processing a macro we 'refund' its prior
--     usage so the macro can compete for its old slots again.
--   * Target-only drone macros (target has them, source doesn't) are left
--     completely alone -- their existing overrides are preserved.
--   * Non-drone overrides (e.g. missiles) are preserved as-is.
local function copyDroneConfig(source, target)
    debug("--- COPYING DRONE CONFIG ---")

    local sourceOverrides = readSupplyOrders(source, false)
    local sourceDefaults  = readSupplyOrders(source, true)
    local targetOverrides = readSupplyOrders(target, false)
    local targetDefaults  = readSupplyOrders(target, true)

    local sourceUnitsByType = {}
    local targetUnitsByType = {}
    for _, dt in ipairs(droneTypes) do
        sourceUnitsByType[dt.unitType] = readUnitStorage(source, dt.unitType)
        targetUnitsByType[dt.unitType] = readUnitStorage(target, dt.unitType)
    end

    -- Shared drone pool capacity (one number for the whole station).
    local capacity = readUnitStorageSummary(target).capacity
    debug(string.format("drones: target shared pool capacity=%d", capacity))

    -- Per-type manual flags BEFORE we touch anything; needed to interpret
    -- target's current overrides correctly when computing pool usage.
    local sourceManualByType, targetManualByType = {}, {}
    for _, dt in ipairs(droneTypes) do
        sourceManualByType[dt.unitType] = C.IsSupplyManual(source, dt.supplyType)
        targetManualByType[dt.unitType] = C.IsSupplyManual(target, dt.supplyType)
    end

    -- Map macro -> unitType on target, so we can look up the right mode when
    -- summing pool usage across all drone macros.
    local targetMacroType = {}
    for _, dt in ipairs(droneTypes) do
        for macro, _ in pairs(targetUnitsByType[dt.unitType].byMacro) do
            targetMacroType[macro] = dt.unitType
        end
    end

    -- Pool usage for one target macro in target's CURRENT (pre-switch) mode.
    local function poolUsageForMacro(macro)
        local unitType = targetMacroType[macro]
        if not unitType then return 0 end
        local entry = targetUnitsByType[unitType].byMacro[macro]
        local stored = (entry and entry.amount) or 0
        local manual = targetManualByType[unitType]
        local ovr = targetOverrides[macro]
        local def = targetDefaults[macro]
        if manual then
            return stored + math.max(0, ovr or 0)
        else
            return math.max(stored, ovr or def or 0)
        end
    end

    -- Subtract every drone macro's current pool usage from capacity to get the
    -- starting budget. Stored drones from macros source doesn't touch stay
    -- subtracted (we can't move physical drones around).
    local preSwitchUsage = {}
    local initialUsage = 0
    for macro, _ in pairs(targetMacroType) do
        preSwitchUsage[macro] = poolUsageForMacro(macro)
        initialUsage = initialUsage + preSwitchUsage[macro]
    end
    local remaining = math.max(0, capacity - initialUsage)
    debug(string.format(
        "drones: initial pool usage=%d / capacity=%d -> remaining=%d (before per-macro refunds)",
        initialUsage, capacity, remaining))

    -- newOverrides starts as a full copy of target's current override table.
    -- UpdateSupplyOverrides is a full replace -- anything not present becomes
    -- "no override". Preserving everything by default means target-only drone
    -- macros and non-drone (missile) overrides survive untouched; we only
    -- mutate entries for macros we actively process.
    local newOverrides = {}
    for macro, amount in pairs(targetOverrides) do
        newOverrides[macro] = amount
    end

    local appliedCount, skippedNoStorage, keptCount = 0, 0, 0

    for _, dt in ipairs(droneTypes) do
        local unitType, supplyType = dt.unitType, dt.supplyType
        if unitType == "build" then
            debug("drones: build type left untouched (mode + overrides preserved)")
            goto continueDroneType
        end
        local sourceManual = sourceManualByType[unitType]
        local prevTargetManual = targetManualByType[unitType]

        -- Sync target mode to source mode for this type (no-op if already so).
        if prevTargetManual ~= sourceManual then
            C.SetSupplyManual(target, supplyType, sourceManual)
            debug(string.format("drones: %s mode -> %s (was %s)",
                unitType,
                sourceManual and "manual" or "auto",
                prevTargetManual and "manual" or "auto"))
        else
            debug(string.format("drones: %s mode=%s (unchanged)",
                unitType, sourceManual and "manual" or "auto"))
        end

        -- Sort source entries by display name for deterministic iteration.
        local sList = {}
        for _, e in ipairs(sourceUnitsByType[unitType].list) do
            table.insert(sList, e)
        end
        table.sort(sList, function(a, b)
            return tostring(a.name or a.macro) < tostring(b.name or b.macro)
        end)

        for _, sEntry in ipairs(sList) do
            local macro = sEntry.macro
            local tEntry = targetUnitsByType[unitType].byMacro[macro]
            if not tEntry then
                skippedNoStorage = skippedNoStorage + 1
                debug(string.format("  %s (%s): skipped (target has no compatible storage)",
                    macro, unitType))
            else
                local tgtStored = tEntry.amount
                local srcStored = sEntry.amount
                local srcOvr = sourceOverrides[macro]
                local srcDef = sourceDefaults[macro]

                -- Source's desired projected total for this macro.
                local desired
                if sourceManual then
                    desired = srcStored + (srcOvr or 0)
                else
                    desired = srcOvr or srcDef or 0
                end
                desired = math.max(0, math.floor(desired))

                -- Refund this macro's pre-switch pool slots (we're rewriting it).
                local refund = preSwitchUsage[macro] or 0
                remaining = remaining + refund

                -- Decide the new projected total. Can't go below stored (no
                -- destroying), can't exceed desired (no over-ordering), can't
                -- exceed the available pool slots.
                local newProjected = math.max(tgtStored, math.min(desired, remaining))
                if newProjected > remaining then
                    -- Pool is tighter than the existing stored count. Can't
                    -- help that; leave stored in place, no extra inbound.
                    newProjected = math.min(tgtStored, remaining)
                end
                local newInbound = newProjected - tgtStored

                remaining = remaining - newProjected
                if remaining < 0 then remaining = 0 end

                -- Compute the override value in the post-switch (= source) mode.
                local overrideValue
                if sourceManual then
                    overrideValue = newInbound
                else
                    overrideValue = newProjected
                end
                newOverrides[macro] = overrideValue

                if newInbound == 0 and tgtStored >= desired then
                    keptCount = keptCount + 1
                    debug(string.format(
                        "  %s (%s): kept stored=%d (>= sourceDesired=%d), inbound zeroed, override=%s",
                        macro, unitType, tgtStored, desired, tostring(overrideValue)))
                else
                    appliedCount = appliedCount + 1
                    debug(string.format(
                        "  %s (%s): sourceDesired=%d targetStored=%d -> projected=%d inbound=%d override=%s [remaining=%d]",
                        macro, unitType, desired, tgtStored, newProjected, newInbound,
                        tostring(overrideValue), remaining))
                end
            end
        end

        -- Note: target-only macros for this unit type are intentionally NOT
        -- touched here -- their entries in newOverrides remain whatever
        -- targetOverrides had, so the player's existing orders survive.
        ::continueDroneType::
    end

    updateSupplyOverrides(target, newOverrides)
    C.UpdateProductionTradeOffers(target)

    -- Station-wide "Trade Rule for Supplies" (the row at the bottom of the LSO
    -- Drones expand block, with empty wareid). Single rule for the whole supply
    -- category -- drones AND missiles share it. We copy it as part of "drone
    -- config" since that's where the player sees it, even though missiles
    -- inherit the same rule.
    local supplyRuleLocal = C.HasContainerOwnTradeRule(source, "supply", "")
    if supplyRuleLocal then
        local supplyRuleId = C.GetContainerTradeRuleID(source, "supply", "")
        C.SetContainerTradeRule(target, supplyRuleId, "supply", "", true)
        debug(string.format("supply trade rule: local id=%s", tostring(supplyRuleId)))
    else
        C.SetContainerTradeRule(target, -1, "supply", "", false)
        debug("supply trade rule: inherit station default (no local rule)")
    end

    debug(string.format(
        "Drone config copy done: %d applied, %d kept (already >= source), %d skipped (no storage), remaining pool=%d.",
        appliedCount, keptCount, skippedNoStorage, remaining))
end

-- Return a set of wares that vanilla Logical Station Overview will render from
-- planned production/processing modules. This plugs the construction-station
-- gap where allresources/products/tradewares can be incomplete, but the LSO
-- still walks the construction plan and creates rows from module macro data.
local function getPlannedVisibleWares(stationid)
    local visible = {}
    local count = 0

    local function add(ware)
        if type(ware) == "string" and ware ~= "" and not visible[ware] then
            visible[ware] = true
            count = count + 1
        end
    end

    local okOwned, isplayerowned = pcall(GetComponentData, stationid, "isplayerowned")
    if not okOwned or not isplayerowned then
        debug("planned-visible wares: skipped (target is not player-owned or ownership unreadable)")
        return visible, count
    end

    local constructionplan = {}
    local changedModulesIndices = {}
    local newModulesIndex = 0

    local okPlan, err = pcall(function()
        local n = C.GetNumBuildMapConstructionPlan(0, true)
        if n > 0 then
            local buf = ffi.new("UIConstructionPlanEntry[?]", n)
            n = tonumber(C.GetBuildMapConstructionPlan(0, stationid, true, buf, n))
            for i = 0, n - 1 do
                table.insert(constructionplan, {
                    idx       = buf[i].idx,
                    macro     = ffi.string(buf[i].macroid),
                    component = buf[i].componentid,
                })
            end

            if #constructionplan > 0 then
                local newIndex = ffi.new("uint32_t[1]", 0)
                local numChangedIndices = ffi.new("uint32_t[1]", 0)
                local numRemoved = C.GetNumRemovedConstructionPlanModules2(0, stationid, newIndex, true, numChangedIndices, false)
                newModulesIndex = tonumber(newIndex[0]) + 1

                local removedLen = math.max(tonumber(numRemoved), 1)
                local changedLen = math.max(tonumber(numChangedIndices[0]), 1)
                local removedBuf = ffi.new("UniverseID[?]", removedLen)
                local changedBuf = ffi.new("uint32_t[?]", changedLen)
                C.GetRemovedConstructionPlanModules2(removedBuf, numRemoved, changedBuf, numChangedIndices)
                for i = 0, tonumber(numChangedIndices[0]) - 1 do
                    changedModulesIndices[changedBuf[i]] = true
                end
            end
        end

        if #constructionplan == 0 then
            local planned = C.GetNumPlannedStationModules(stationid, true)
            if planned > 0 then
                local buf = ffi.new("UIConstructionPlanEntry[?]", planned)
                planned = tonumber(C.GetPlannedStationModules(buf, planned, stationid, true))
                for i = 0, planned - 1 do
                    table.insert(constructionplan, {
                        idx       = buf[i].idx,
                        macro     = ffi.string(buf[i].macroid),
                        component = buf[i].componentid,
                    })
                end

                local newIndex = ffi.new("uint32_t[1]", 0)
                local numChangedIndices = ffi.new("uint32_t[1]", 0)
                local numRemoved = C.GetNumRemovedStationModules2(stationid, newIndex, numChangedIndices, false)
                newModulesIndex = tonumber(newIndex[0]) + 1

                local removedLen = math.max(tonumber(numRemoved), 1)
                local changedLen = math.max(tonumber(numChangedIndices[0]), 1)
                local removedBuf = ffi.new("UniverseID[?]", removedLen)
                local changedBuf = ffi.new("uint32_t[?]", changedLen)
                C.GetRemovedStationModules2(removedBuf, numRemoved, changedBuf, numChangedIndices)
                for i = 0, tonumber(numChangedIndices[0]) - 1 do
                    changedModulesIndices[changedBuf[i]] = true
                end
            end
        end
    end)

    if not okPlan then
        debug("planned-visible wares: construction plan read failed: " .. tostring(err))
        return visible, count
    end

    for i = newModulesIndex, #constructionplan do
        if changedModulesIndices[i] then
            local entry = constructionplan[i]
            local componentInConstruction = entry.component == 0
            if not componentInConstruction and type(IsComponentConstruction) == "function" then
                local okConstruction, result = pcall(IsComponentConstruction, ConvertStringTo64Bit(tostring(entry.component)))
                componentInConstruction = okConstruction and result
            end

            local okProduction, isproduction = pcall(IsMacroClass, entry.macro, "production")
            local okProcessing, isprocessingmodule = pcall(IsMacroClass, entry.macro, "processingmodule")
            if componentInConstruction
                and ((okProduction and isproduction) or (okProcessing and isprocessingmodule)) then
                local okMacro, macrodata = pcall(function()
                    return GetLibraryEntry(GetMacroData(entry.macro, "infolibrary"), entry.macro)
                end)
                if okMacro and type(macrodata) == "table" and type(macrodata.products) == "table" then
                    for _, productdata in ipairs(macrodata.products) do
                        add(productdata.ware)
                        if type(productdata.resources) == "table" then
                            for _, resourcedata in ipairs(productdata.resources) do
                                add(resourcedata.ware)
                            end
                        end
                    end
                end
            end
        end
    end

    debug(string.format("planned-visible wares: constructionplan=%d newIndex=%d -> %d ware(s)",
        #constructionplan, newModulesIndex, count))
    return visible, count
end

-- Snapshot of one ware's logistic config on a station. Read-only.
local function snapshotWare(stationid, ware)
    local snap = {
        ware = ware,

        -- buy offer
        buyOfferEnabled   = C.GetContainerWareIsBuyable(stationid, ware),
        buyLimit          = C.GetContainerBuyLimit(stationid, ware),
        buyLimitOverride  = C.HasContainerBuyLimitOverride(stationid, ware),
        buyPrice          = GetContainerWarePrice(stationid, ware, true),
        buyPriceOverride  = HasContainerWarePriceOverride(stationid, ware, true),
        buyRuleId         = C.GetContainerTradeRuleID(stationid, "buy", ware),
        buyRuleLocal      = C.HasContainerOwnTradeRule(stationid, "buy", ware),

        -- sell offer
        sellOfferEnabled  = C.GetContainerWareIsSellable(stationid, ware),
        sellLimit         = C.GetContainerSellLimit(stationid, ware),
        sellLimitOverride = C.HasContainerSellLimitOverride(stationid, ware),
        sellPrice         = GetContainerWarePrice(stationid, ware, false),
        sellPriceOverride = HasContainerWarePriceOverride(stationid, ware, false),
        sellRuleId        = C.GetContainerTradeRuleID(stationid, "sell", ware),
        sellRuleLocal     = C.HasContainerOwnTradeRule(stationid, "sell", ware),

        -- storage allocation (per ware, in units -- NOT m^3)
        --   stockLimit:         current EFFECTIVE allocation. Returns the manual value
        --                       when override is on, else the auto-calculated value.
        --                       Lua-global wrapper (no C. prefix).
        --   stockLimitOverride: true if user has manually set the value for this ware,
        --                       false if the game's auto-allocation is in effect.
        stockLimit         = GetWareProductionLimit(stationid, ware),
        stockLimitOverride = HasContainerStockLimitOverride(stationid, ware),

        -- theoretical max ("if this ware had the whole storage to itself"). Useful as
        -- the slider max in UI, and for the step-4 "target too small -> set to 0"
        -- check. NOT the same as actual allocation.
        wareCapacity      = GetWareCapacity(stationid, ware),
    }
    return snap
end

local function logSnapshot(stationid, snap)
    debug(string.format(
        "  %s | stock(amt=%s/ovr=%s) | buy(enabled=%s amt=%s/ovr=%s prc=%s/ovr=%s rule=%s/local=%s) | sell(enabled=%s amt=%s/ovr=%s prc=%s/ovr=%s rule=%s/local=%s) | cap=%s",
        snap.ware,
        tostring(snap.stockLimit),
        tostring(snap.stockLimitOverride),
        tostring(snap.buyOfferEnabled),
        tostring(snap.buyLimit),
        tostring(snap.buyLimitOverride),
        tostring(snap.buyPrice),
        tostring(snap.buyPriceOverride),
        tostring(snap.buyRuleId),
        tostring(snap.buyRuleLocal),
        tostring(snap.sellOfferEnabled),
        tostring(snap.sellLimit),
        tostring(snap.sellLimitOverride),
        tostring(snap.sellPrice),
        tostring(snap.sellPriceOverride),
        tostring(snap.sellRuleId),
        tostring(snap.sellRuleLocal),
        tostring(snap.wareCapacity)
    ))
end

-- ----------------------------------------------------------------------------
-- Compute remaining storage (in m^3) per transport type on the target, AFTER
-- accounting for manual overrides on wares we will NOT touch in this run.
-- Mirrors the vanilla "available storage" calc in helper.lua around the
-- automatic-storage rows (see "GetContainerStockLimitOverrides" usage there).
--
-- Returns a table keyed by transport string ("solid", "liquid", "container",
-- "condensate") -> m^3 remaining. The caller then decrements as it commits
-- each per-ware override in source order.
-- ----------------------------------------------------------------------------
local function getTargetRemainingCapacityM3(target, willOverwriteWares)
    -- Total physical capacity per transport type, m^3 (merge=true to fold
    -- universal storage into each compatible category, matching vanilla LSO).
    local nT = C.GetNumCargoTransportTypes(target, true)
    local bufT = ffi.new("StorageInfo[?]", nT)
    nT = C.GetCargoTransportTypes(bufT, nT, target, true, false)
    local capByTransport = {}
    for i = 0, nT - 1 do
        local transport = ffi.string(bufT[i].transport)
        capByTransport[transport] = (capByTransport[transport] or 0) + tonumber(bufT[i].capacity)
    end

    -- Subtract existing manual overrides on the target for wares we will NOT
    -- overwrite. Those allocations are "locked in" from our perspective. Guard
    -- with nO > 0 -- ffi.new("UIWareInfo[?]", 0) followed by the FFI call
    -- triggers "Stored StockLimitOverrides do not match the parameters" on a
    -- fresh station with no overrides.
    local nO = C.GetNumContainerStockLimitOverrides(target)
    if nO > 0 then
        local bufO = ffi.new("UIWareInfo[?]", nO)
        nO = C.GetContainerStockLimitOverrides(bufO, nO, target)
        for i = 0, nO - 1 do
            local ware = ffi.string(bufO[i].ware)
            if not willOverwriteWares[ware] then
                local transport, volume = GetWareData(ware, "transport", "volume")
                local occupied = tonumber(bufO[i].amount) * tonumber(volume or 0)
                capByTransport[transport] = (capByTransport[transport] or 0) - occupied
            end
        end
    end

    -- Floor at 0; never report negative remaining.
    for transport, m3 in pairs(capByTransport) do
        if m3 < 0 then capByTransport[transport] = 0 end
    end

    debug("target remaining storage (m^3) after existing-overrides:")
    for transport, m3 in pairs(capByTransport) do
        debug(string.format("  %s = %s", transport, tostring(m3)))
    end

    return capByTransport
end

-- ----------------------------------------------------------------------------
-- Per-ware apply: write the source's settings onto the target for one ware.
-- Order of operations matters slightly:
--   1. storage allocation override (set/clear) -- influences how the engine
--      sizes other limits
--   2. price overrides (set/clear, per buy/sell direction)
--   3. buy/sell limits (set/clear) -- before toggling the offer existence
--      so when the offer flips on, the engine already has the right amount
--   4. buy/sell offer existence (the toggle that shows/hides the offer)
--   5. trade rules (per direction)
--
-- Capacity clamp: if the source's manual allocation is larger than the target
-- physically can hold (target.wareCapacity), we apply 0 instead. The player
-- can revisit the value manually once storage modules finish building.
-- ----------------------------------------------------------------------------
local function applyWareToTarget(target, ware, srcSnap, tgtSnap, remainingCapM3)
    debug(string.format("APPLY %s:", ware))

    -- 1. Storage allocation (grouped-by-transport capacity check):
    --    Source amount is in UNITS; remainingCapM3 is in m^3 per transport type.
    --    Convert via ware.volume and see if the (already-decremented) remaining
    --    pool can absorb this ware. If not, write 0 -- player adjusts manually
    --    once storage modules finish building.
    if srcSnap.stockLimitOverride then
        local amt = srcSnap.stockLimit
        local transport, volume = GetWareData(ware, "transport", "volume")
        volume = tonumber(volume) or 1
        local neededM3 = amt * volume
        local availableM3 = remainingCapM3[transport] or 0
        if neededM3 > availableM3 then
            debug(string.format(
                "  stock: need %s m^3 of %s storage, %s m^3 remaining -> writing 0 (target too small for now)",
                tostring(neededM3), tostring(transport), tostring(availableM3)))
            amt = 0
        else
            remainingCapM3[transport] = availableM3 - neededM3
        end
        SetContainerStockLimitOverride(target, ware, amt)
        debug(string.format("  stock: override = %s (transport=%s, remaining=%s m^3)",
            tostring(amt), tostring(transport), tostring(remainingCapM3[transport] or 0)))
    else
        ClearContainerStockLimitOverride(target, ware)
        debug("  stock: override cleared (auto)")
    end

    -- 2. Prices
    if srcSnap.buyPriceOverride then
        SetContainerWarePriceOverride(target, ware, true, srcSnap.buyPrice)
        debug(string.format("  buy price: override = %s", srcSnap.buyPrice))
    else
        ClearContainerWarePriceOverride(target, ware, true)
        debug("  buy price: override cleared (auto)")
    end
    if srcSnap.sellPriceOverride then
        SetContainerWarePriceOverride(target, ware, false, srcSnap.sellPrice)
        debug(string.format("  sell price: override = %s", srcSnap.sellPrice))
    else
        ClearContainerWarePriceOverride(target, ware, false)
        debug("  sell price: override cleared (auto)")
    end

    -- 3. Buy/sell limits
    if srcSnap.buyLimitOverride then
        C.SetContainerBuyLimitOverride(target, ware, srcSnap.buyLimit)
        debug(string.format("  buy limit: override = %s", srcSnap.buyLimit))
    else
        C.ClearContainerBuyLimitOverride(target, ware)
        debug("  buy limit: override cleared (auto)")
    end
    if srcSnap.sellLimitOverride then
        C.SetContainerSellLimitOverride(target, ware, srcSnap.sellLimit)
        debug(string.format("  sell limit: override = %s", srcSnap.sellLimit))
    else
        C.ClearContainerSellLimitOverride(target, ware)
        debug("  sell limit: override cleared (auto)")
    end

    -- 4. Offer existence toggles.
    --
    -- C.GetContainerWareIsBuyable / IsSellable returns the *explicit player-
    -- toggle* flag, not "is there an offer visible in the LSO". For wares that
    -- production consumes (raw resources, intermediates), the LSO renders the
    -- offer regardless of this flag -- but calling Set..IsBuyable(target, ware,
    -- false) WILL kill the offer on target. So we can't just mirror source's
    -- flag literally; we'd lose the buy offers on raw resources whose source
    -- had IsBuyable=false but visible offers via overrides.
    --
    -- Instead, derive the effective enable state as the OR of all buy-side
    -- signals. If source has ANY indication of "I care about this offer"
    -- (explicit toggle, manual amount, manual price, or dedicated rule),
    -- enable it on target. If source has nothing on that side, disable.
    -- This mirrors what the LSO actually displays rather than the bare flag.
    local effectiveBuy = srcSnap.buyOfferEnabled
        or srcSnap.buyLimitOverride
        or srcSnap.buyPriceOverride
        or srcSnap.buyRuleLocal
    local effectiveSell = srcSnap.sellOfferEnabled
        or srcSnap.sellLimitOverride
        or srcSnap.sellPriceOverride
        or srcSnap.sellRuleLocal
    C.SetContainerWareIsBuyable(target, ware, effectiveBuy and true or false)
    debug(string.format(
        "  buy offer enabled: %s (raw=%s + limitOvr=%s + priceOvr=%s + ruleLocal=%s)",
        tostring(effectiveBuy and true or false),
        tostring(srcSnap.buyOfferEnabled),
        tostring(srcSnap.buyLimitOverride),
        tostring(srcSnap.buyPriceOverride),
        tostring(srcSnap.buyRuleLocal)))
    C.SetContainerWareIsSellable(target, ware, effectiveSell and true or false)
    debug(string.format(
        "  sell offer enabled: %s (raw=%s + limitOvr=%s + priceOvr=%s + ruleLocal=%s)",
        tostring(effectiveSell and true or false),
        tostring(srcSnap.sellOfferEnabled),
        tostring(srcSnap.sellLimitOverride),
        tostring(srcSnap.sellPriceOverride),
        tostring(srcSnap.sellRuleLocal)))

    -- 5. Trade rules. ruleLocal=true means "this ware has its own rule"; the
    --    ruleId selects which rule. ruleLocal=false means "inherit station default".
    --    Per vanilla code, the engine call is the same in both cases -- only the
    --    last bool flips.
    if srcSnap.buyRuleLocal then
        C.SetContainerTradeRule(target, srcSnap.buyRuleId, "buy", ware, true)
        debug(string.format("  buy rule: local id=%s", srcSnap.buyRuleId))
    else
        C.SetContainerTradeRule(target, -1, "buy", ware, false)
        debug("  buy rule: inherit station default")
    end
    if srcSnap.sellRuleLocal then
        C.SetContainerTradeRule(target, srcSnap.sellRuleId, "sell", ware, true)
        debug(string.format("  sell rule: local id=%s", srcSnap.sellRuleId))
    else
        C.SetContainerTradeRule(target, -1, "sell", ware, false)
        debug("  sell rule: inherit station default")
    end
end

-- ----------------------------------------------------------------------------
-- Main entry implementation. Buffers all debug() calls; applyCopy (below) is a
-- thin pcall-and-flush wrapper so the buffer always emits even if something
-- here throws.
-- ----------------------------------------------------------------------------
local function applyCopyImpl(targetHandle)
    debug("==== VAS_CSL.Apply received ====")

    local target = toUID(targetHandle)
    if target == nil then
        debug("ERROR: target handle could not be resolved to a UniverseID")
        return
    end
    debug(string.format("target = %s", tostring(target)))

    -- Read source + filter from blackboard
    local playerid = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
    local data = GetNPCBlackboard(playerid, "$vas_csl_data")
    if type(data) ~= "table" or data.source == nil then
        debug("ERROR: no source in player blackboard ($vas_csl_data.source)")
        return
    end
    local source = toUID(data.source)
    if source == nil then
        debug("ERROR: source handle in blackboard could not be resolved")
        return
    end
    -- filter:
    --   nil/'all' = copy every source ware
    --   string    = copy one ware (legacy one-click menu)
    --   table     = copy selected ware ids from the checkbox menu
    local filter = data.filter
    -- MD booleans round-trip through the blackboard as numbers (true -> 1,
     -- false -> 0), so a strict `== true` check misses the truthy case. Accept
     -- bool, number, and string forms.
    local cdRaw = data.copyDroneConfig
    local copyDrones = cdRaw == true
        or cdRaw == 1
        or cdRaw == "true"
        or cdRaw == "1"
    debug(string.format("copyDroneConfig raw = %s (%s) -> %s",
        tostring(cdRaw), type(cdRaw), tostring(copyDrones)))
    debug(string.format("source = %s, filter = %s, copyDrones = %s",
        tostring(source), tostring(filter), tostring(copyDrones)))

    -- Enumerate source's wares (full union -- larger than the MD popup's list,
    -- so 'all' copies wares the popup didn't list e.g. raw resources never
    -- yet in cargo).
    local sourceWaresFull = getStationWares(source)
    debug(string.format("source handles %d ware(s) (full union)", #sourceWaresFull))

    -- Narrow to the requested filter.
    local sourceWares
    if filter == nil or filter == "all" then
        sourceWares = sourceWaresFull
    elseif type(filter) == "table" then
        local requested = {}
        local requestedCount = 0
        for _, ware in ipairs(filter) do
            if type(ware) == "string" and ware ~= "" then
                requested[ware] = true
                requestedCount = requestedCount + 1
            end
        end
        if requestedCount == 0 then
            for _, ware in pairs(filter) do
                if type(ware) == "string" and ware ~= "" then
                    requested[ware] = true
                    requestedCount = requestedCount + 1
                end
            end
        end

        sourceWares = {}
        for _, ware in ipairs(sourceWaresFull) do
            if requested[ware] then
                table.insert(sourceWares, ware)
                requested[ware] = nil
            end
        end

        for ware, _ in pairs(requested) do
            debug(string.format("filter list ignored stale/unknown ware '%s'", ware))
        end
        debug(string.format("filter = selected list (%d requested, %d valid)", requestedCount, #sourceWares))
    else
        -- Single-ware filter. Only include it if source actually handles it
        -- (defence against stale/garbage filter values).
        local found = false
        for _, w in ipairs(sourceWaresFull) do
            if w == filter then found = true; break end
        end
        if found then
            sourceWares = { filter }
            debug(string.format("filter = single ware '%s'", filter))
        else
            debug(string.format("ERROR: filter '%s' is not in source's ware list; aborting", filter))
            return
        end
    end

    if #sourceWares == 0 and not copyDrones then
        debug("Nothing to copy.")
        return
    elseif #sourceWares == 0 then
        debug("No wares selected; continuing with drone config only.")
    end

    -- Snapshot + log each. pcall each ware so one FFI-restricted call doesn't
    -- abort the whole dry-run -- we want to see as much as possible per attempt
    -- so we know what works and what doesn't.
    debug("--- SOURCE snapshot ---")
    local snapshots = {}
    for _, ware in ipairs(sourceWares) do
        local ok, snap = pcall(snapshotWare, source, ware)
        if ok then
            snapshots[ware] = snap
            logSnapshot(source, snap)
        else
            debug(string.format("  %s | ERROR reading source: %s", ware, tostring(snap)))
        end
    end

    -- Snapshot target for EACH source ware (rather than only target's narrowly-
    -- enumerated handled-wares list). A freshly-built station returns a tiny
    -- subset from GetComponentData(allresources/products/cargo/tradewares) even
    -- when its storage modules physically support many more wares. The vanilla
    -- LSO lets the player open the row and click "Create Buy Offer" on such
    -- wares, so we should match: take any ware where wareCapacity > 0 on the
    -- target (= target has compatible storage modules) as fair game.
    local targetSnapshots = {}
    for _, ware in ipairs(sourceWares) do
        local ok, snap = pcall(snapshotWare, target, ware)
        if ok then targetSnapshots[ware] = snap end
    end

    -- Log target's BEFORE-state for visibility.
    debug("--- TARGET state BEFORE apply ---")
    for _, ware in ipairs(sourceWares) do
        local snap = targetSnapshots[ware]
        if snap then logSnapshot(target, snap) end
    end

    -- Compute remaining storage budget on target, grouped by transport type
    -- (solid/liquid/container/condensate). Wares we're about to overwrite
    -- count as "freed" -- their current target-side override allocation
    -- doesn't block us, because we're replacing it.
    local willOverwriteWares = {}
    for _, w in ipairs(sourceWares) do
        if snapshots[w] then willOverwriteWares[w] = true end
    end
    local remainingCapM3 = getTargetRemainingCapacityM3(target, willOverwriteWares)

    -- ---- FLUSH 1 ----
    -- Source snapshot + target before-state + capacity budget are large; emit
    -- as a self-contained block before the per-ware apply log so we don't
    -- overflow the in-game DebugError length cap mid-paragraph.
    flushDebug()

    -- Apply pass.
    debug("--- APPLYING SOURCE -> TARGET ---")
    local applied, skippedNoStorage, errored = 0, 0, 0
    local appliedWares = {}   -- track for the post-pass tradeware check below
    for _, ware in ipairs(sourceWares) do
        local srcSnap = snapshots[ware]
        local tgtSnap = targetSnapshots[ware]
        if srcSnap == nil then
            debug(string.format("  %s: SKIPPED (no source snapshot -- earlier read error)", ware))
        elseif tgtSnap == nil or (tgtSnap.wareCapacity or 0) <= 0 then
            -- Target has no compatible storage module for this ware. Vanilla
            -- LSO wouldn't even render a row for it -- safe to skip.
            debug(string.format("  %s: SKIPPED (target has no storage capacity for this ware -- cap=%s)",
                ware, tostring(tgtSnap and tgtSnap.wareCapacity)))
            skippedNoStorage = skippedNoStorage + 1
        else
            local ok, err = pcall(applyWareToTarget, target, ware, srcSnap, tgtSnap, remainingCapM3)
            if ok then
                applied = applied + 1
                table.insert(appliedWares, ware)
            else
                debug(string.format("  %s: ERROR during apply: %s", ware, tostring(err)))
                errored = errored + 1
            end
        end
    end
    debug(string.format("Apply done: %d applied, %d skipped (no target storage), %d errored.",
        applied, skippedNoStorage, errored))

    -- ---- FLUSH 2 ----
    flushDebug()

    -- ---- Post-pass: ensure each applied ware is registered as a TRADE WARE on
    -- the target only when it isn't already visible in the LSO. Wares that show
    -- up naturally (via production allresources / products / cargo) do NOT need
    -- AddTradeWare -- calling it anyway adds a redundant "manual" entry.
    --
    -- Three skip signals:
    --   (a) Ware is already in target's getStationWares union (same union the
    --       LSO uses). Means the ware appears in the LSO already, either
    --       because production references it or because it's an explicit
    --       tradeware. AddTradeWare would duplicate.
    --   (b) Target's PRE-APPLY snapshot showed existing overrides (price,
    --       limit, rule, or explicit Is{Buy,Sell}able). Means the player or
    --       a previous apply already set this ware up; redundant to add.
    --   (c) Target's construction plan already makes vanilla LSO render this
    --       ware from planned production/processing module macro data.
    --
    -- Only if all three signals are absent do we call C.AddTradeWare. This covers
    -- the "Solar Farm gets metallicmicrolattice for the first time" case
    -- without re-adding wares that the target station's production already
    -- exposes.
    debug("--- POST-APPLY: ensuring target tradewares ---")

    local targetUnion = getStationWares(target)
    local targetUnionSet = {}
    for _, w in ipairs(targetUnion) do targetUnionSet[w] = true end
    debug(string.format("target's union after apply: %d ware(s)", #targetUnion))

    -- Under-construction targets can show planned production/processing wares
    -- before allresources/products/tradewares know about them. Mirror the
    -- vanilla LSO construction-plan scan instead of using wareCapacity, which
    -- only means "compatible storage exists" and is far too broad.
    local targetPlannedVisibleWares, plannedVisibleCount = getPlannedVisibleWares(target)
    debug(string.format("target planned-visible ware set: %d ware(s)", plannedVisibleCount or 0))

    local added, skipInUnion, skipHadOverrides, skipPlannedVisible = 0, 0, 0, 0
    for _, ware in ipairs(appliedWares) do
        local tgtBefore = targetSnapshots[ware]
        local inUnion = targetUnionSet[ware] == true
        local plannedVisible = targetPlannedVisibleWares[ware] == true
        local hadOverrides = false
        if tgtBefore then
            hadOverrides = tgtBefore.buyOfferEnabled
                or tgtBefore.buyLimitOverride
                or tgtBefore.buyPriceOverride
                or tgtBefore.buyRuleLocal
                or tgtBefore.sellOfferEnabled
                or tgtBefore.sellLimitOverride
                or tgtBefore.sellPriceOverride
                or tgtBefore.sellRuleLocal
        end

        if inUnion then
            debug(string.format("  %s: skip (already in target's LSO union)", ware))
            skipInUnion = skipInUnion + 1
        elseif hadOverrides then
            debug(string.format("  %s: skip (target had pre-existing settings -- already handled)", ware))
            skipHadOverrides = skipHadOverrides + 1
        elseif plannedVisible then
            debug(string.format(
                "  %s: skip (target construction plan already makes this ware visible in LSO)",
                ware))
            skipPlannedVisible = skipPlannedVisible + 1
        else
            local ok, err = pcall(C.AddTradeWare, target, ware)
            if ok then
                added = added + 1
                debug(string.format("  %s: AddTradeWare called (not in union, no overrides, not planned-visible)", ware))
            else
                debug(string.format("  %s: AddTradeWare error: %s", ware, tostring(err)))
            end
        end
    end
    debug(string.format(
        "Post-apply tradeware pass: %d added, %d skipped-in-union, %d skipped-had-overrides, %d skipped-planned-visible.",
        added, skipInUnion, skipHadOverrides, skipPlannedVisible))

    -- ---- FLUSH 3 ----
    flushDebug()

    if copyDrones then
        local ok, err = pcall(copyDroneConfig, source, target)
        if not ok then
            debug("Drone config copy failed: " .. tostring(err))
        end
    end
end

-- ----------------------------------------------------------------------------
-- Thin wrapper for the event handler: ensures the log buffer is always flushed
-- as a single multi-line DebugError block, even if applyCopyImpl errors out.
-- This is what RegisterEvent is bound to.
-- ----------------------------------------------------------------------------
local function applyCopy(_, targetHandle)
    local ok, err = pcall(applyCopyImpl, targetHandle)
    if not ok then
        debug("FATAL during apply: " .. tostring(err))
    end
    flushDebug()
end

-- We also need PlayerID + GetNPCBlackboard. Add the minimum cdef to access them.
ffi.cdef[[
    UniverseID GetPlayerID(void);
]]

RegisterEvent("VAS_CSL.Apply", applyCopy)
debug("VAS_CSL Lua module loaded; VAS_CSL.Apply handler registered.")
flushDebug()
