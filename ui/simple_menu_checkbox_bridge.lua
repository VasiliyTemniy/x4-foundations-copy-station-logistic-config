-- =============================================================================
-- VAS Copy Station Logistic Config -- Simple_Menu checkbox bridge
-- =============================================================================
-- Workaround for a known limitation in SirNukes Simple_Menu_API: the
-- documented Update_Widget path silently skips checkbox state updates in some
-- cases (notably setting checked = false from MD), which breaks the
-- "select all" / "select only target wares" buttons in our ware picker.
--
-- The workaround reaches into Simple_Menu_API's internal `menu_data.user_rows`
-- table to find the checkbox widget by (row, col) and calls the engine's
-- C.SetCheckBoxChecked directly. This is a deliberate internal-API touch and
-- the only place in this mod that bypasses Simple_Menu_API. If/when SN ships
-- a fix for Update_Widget this bridge becomes unnecessary and can be removed.
--
-- Failure mode is soft: the require is wrapped in pcall, and a missing table
-- emits one DebugError and the file early-returns. The rest of the mod still
-- functions; only the checkbox-state-sync buttons go silent.
-- =============================================================================

local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
    void SetCheckBoxChecked(const int checkboxid, bool checked);
]]

local okTables, Tables = pcall(require, "extensions.sn_mod_support_apis.ui.simple_menu.Tables")
if not okTables or type(Tables) ~= "table" or type(Tables.menu_data) ~= "table" then
    DebugError("[VAS-CSL] checkbox bridge: failed to load Simple_Menu tables")
    return
end

local menu_data = Tables.menu_data

local function setSimpleMenuCheckbox(_, payload)
    local row, col, checked = string.match(tostring(payload or ""), "^(%d+);(%d+);([01])$")
    row = tonumber(row)
    col = tonumber(col)
    checked = checked == "1"

    local cell = row and col and menu_data.user_rows[row] and menu_data.user_rows[row][col]
    if not cell or not cell.id then
        DebugError(string.format("[VAS-CSL] checkbox bridge: no checkbox cell at row=%s col=%s", tostring(row), tostring(col)))
        return
    end

    C.SetCheckBoxChecked(cell.id, checked)
end

RegisterEvent("VAS_CSL.SetSimpleMenuCheckbox", setSimpleMenuCheckbox)

