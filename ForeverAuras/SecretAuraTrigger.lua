-- Modified for ForeverAuras, 2026-09-30.
-- Modifications Copyright (C) 2026 ForeverAuras. Licensed under the GNU GPL v2 (see LICENSE).
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript = Private.TimedAPI("SecretAuraTrigger")
local Display = Private.BlizzardAuraDisplay
local Trigger = {}
local displays = {}
local loaded = {}

-- Whether a display's settings can be drawn natively (Display.Enabled and
-- Validate agree), kept per data table: Validate copies the settings to check
-- them, and the unit-change handler asks this for every display on every
-- target change. Cleared when the display's settings are saved (Trigger.Add).
local drawable = setmetatable({}, {__mode = "k"})
local function Drawable(data)
  local result = drawable[data]
  if result == nil then
    result = Display.Enabled(data) and Display.Validate(data) == nil
    drawable[data] = result
  end
  return result
end

-- An Aura (Modern) trigger only draws when it is the display's Dynamic
-- Information trigger (Display.GetSavedTrigger). Whenever the display is
-- saved with such a trigger that is not selected, Dynamic Information is
-- pointed at the first one, and a progress source naming another trigger goes
-- back to Automatic, so adding the trigger is enough.
local function SelectModernTrigger(data)
  if not data or type(data.triggers) ~= "table" then return end
  -- "First active trigger" would pick one at run time, which can be another
  -- trigger whenever this one is not active; an explicit choice is needed.
  local mode = tonumber(data.triggers.activeTriggerMode) or -1
  local chosen = mode > 0 and data.triggers[mode]
  chosen = type(chosen) == "table" and chosen.trigger
  local source = data.progressSource and data.progressSource[1]
  if chosen and chosen.type == "secretAura" and not (source and source > 0 and source ~= mode) then return end
  local first
  for index, entry in ipairs(data.triggers) do
    if type(entry) == "table" and entry.trigger and entry.trigger.type == "secretAura" then first = index; break end
  end
  if not first then return end
  data.triggers.activeTriggerMode = first
  if source and source > 0 and source ~= first then data.progressSource = {-1, ""} end
end

function Trigger.Add(data)
  SelectModernTrigger(data)
  Display.MigrateNativeConditions(data)
  Display.MigrateFallback(data)
  drawable[data] = nil
  displays[data.id] = nil
  for _, entry in ipairs(data.triggers) do
    if entry.trigger.type == "secretAura" then displays[data.id] = data; break end
  end
end

-- Units that may not exist. As with Aura (Legacy), the trigger is inactive
-- while such a unit does not exist, unless Show If Unit Does Not Exist
-- (trigger.unitExists, the Legacy field) is ticked. Whether a unit exists is
-- public; whether it has the aura is not, so this is the only case in which
-- the trigger goes inactive. Mouseover has no event when it clears, so it
-- stays active, as before.
local optionalUnits = {target = true, focus = true, pet = true, targettarget = true, focustarget = true, member = true}
local function UnitMissing(trigger)
  if type(trigger) ~= "table" or not optionalUnits[trigger.unit] or trigger.unitExists then return false end
  return not Display.SingleUnitExists(trigger)
end

-- A display drawn by native containers does not go inactive without its
-- unit: it stays shown, its containers enabled, and is faded out instead
-- (Private.SetRegionUnitGone). Hiding and showing a dozen such displays on
-- every target change made the client enable and lay out every container
-- again, a visible stutter; an enabled container without a unit draws
-- nothing by itself. Displays without native containers (the framework's
-- fallback drawing) go inactive as before.
local function FadesWithoutUnit(data)
  return Drawable(data)
end

-- Whether this Aura (Modern) trigger is active. The editor always shows its
-- samples, so there the unit does not matter.
local function IsActive(data, triggernum)
  if Display.Enabled(data) and not Drawable(data) then return false end
  local entry = data.triggers[triggernum]
  return WeakAuras.IsOptionsOpen() or Drawable(data) or not UnitMissing(entry and entry.trigger)
end

-- Fades a native display out while the unit of the trigger that draws it does
-- not exist (see FadesWithoutUnit); nothing else about it changes.
local function ApplyUnitGone(id, data)
  local region = Private.regions[id] and Private.regions[id].region
  if not region or not Private.SetRegionUnitGone then return end
  local gone = not WeakAuras.IsOptionsOpen() and FadesWithoutUnit(data) and UnitMissing(Display.GetSavedTrigger(data))
  Private.SetRegionUnitGone(region, gone)
end

-- Also the framework's fallback state when this trigger supplies a shown
-- display's information; that one is always shown.
function Trigger.CreateFallbackState(data, triggernum, state)
  state.show = not Display.Enabled(data) or Display.Validate(data) == nil
  state.changed = true
  state.progressType = "static"
  state.value, state.total = 1, 1
  state.name, state.icon = Trigger.GetNameAndIcon(data, triggernum)
  state.unit = WeakAuras.IsOptionsOpen() and Display.GetPreviewUnit(data) or nil
  if WeakAuras.IsOptionsOpen() then
    state.progressType = "timed"
    -- Standard sample duration, independent of active aura timers.
    state.duration, state.expirationTime = 6, GetTime() + 6
    state.stacks = 3
  end
end

function Trigger.CreateFakeStates(id, triggernum)
  local states = WeakAuras.GetTriggerStateForTrigger(id, triggernum)
  wipe(states)
  states[""] = {}
  local data = WeakAuras.GetData(id)
  Trigger.CreateFallbackState(data, triggernum, states[""])
  -- The trigger's own state follows its unit (IsActive).
  states[""].show = IsActive(data, triggernum)
end

function Trigger.LoadDisplays(toLoad)
  for id in pairs(toLoad) do
    local data = displays[id]
    if data then
      loaded[id] = true
      drawable[data] = nil
      if Private.regions[id] then Display.Activate(Private.regions[id].region, data) end
      for index, entry in ipairs(data.triggers) do
        if entry.trigger.type == "secretAura" then Trigger.CreateFakeStates(id, index) end
      end
      ApplyUnitGone(id, data)
      Private.UpdatedTriggerState(id)
    end
  end
end

-- Unit changes that can make a unit appear or disappear, and the units they
-- affect (UNIT_TARGET and UNIT_PET are keyed by the unit that changed).
local unitChangeEvents = {
  PLAYER_TARGET_CHANGED = {target = true, targettarget = true},
  PLAYER_FOCUS_CHANGED = {focus = true, focustarget = true},
  UNIT_TARGET = {target = {targettarget = true}, focus = {focustarget = true}},
  UNIT_PET = {player = {pet = true}},
  PLAYER_ENTERING_WORLD = {target = true, focus = true, pet = true, targettarget = true, focustarget = true, member = true},
  GROUP_ROSTER_UPDATE = {member = true},
  INSTANCE_ENCOUNTER_ENGAGE_UNIT = {member = true},
  ARENA_OPPONENT_UPDATE = {member = true},
}
local unitFrame = CreateFrame("Frame")
for event in pairs(unitChangeEvents) do unitFrame:RegisterEvent(event) end
unitFrame:SetScript("OnEvent", function(_, event, unit)
  -- The editor keeps its sample states until it closes.
  if WeakAuras.IsOptionsOpen() then return end
  local affected = unitChangeEvents[event]
  if event == "UNIT_TARGET" then affected = unit and affected[unit] end
  if event == "UNIT_PET" then
    affected = unit == "player" and affected.player or (unit and {member = true})
  end
  if not affected then return end
  -- Collect the displays this unit change switches, then apply them with
  -- their dynamic groups suspended: a target change can show or hide a dozen
  -- icons of one group, which otherwise re-sorts and re-positions after each.
  local switched = {}
  for id in pairs(loaded) do
    local data = displays[id]
    local changed, touched = false, false
    for index, entry in ipairs(data and data.triggers or {}) do
      if entry.trigger.type == "secretAura" and affected[entry.trigger.unit] then
        touched = true
        local state = WeakAuras.GetTriggerStateForTrigger(id, index)[""]
        local show = IsActive(data, index)
        if not state then
          -- The framework removes hidden states after each update
          -- (Private.UpdatedTriggerState), so a trigger that started without
          -- its unit has no state left to switch on: build it again.
          if show then
            Trigger.CreateFakeStates(id, index)
            changed = true
          end
        elseif state.show ~= show then
          state.show, state.changed = show, true
          changed = true
        end
      end
    end
    if changed then switched[id] = true end
    -- A native display only fades (its state does not change).
    if touched then ApplyUnitGone(id, data) end
  end
  if not next(switched) then return end
  local suspended = Private.SuspendGroupsOf(switched)
  for id in pairs(switched) do
    xpcall(Private.UpdatedTriggerState, geterrorhandler(), id)
  end
  Private.ResumeGroups(suspended)
end)

function Trigger.UnloadDisplays(toUnload)
  for id in pairs(toUnload) do
    loaded[id] = nil
    if displays[id] and Private.regions[id] then Display.Release(Private.regions[id].region) end
  end
end

function Trigger.UnloadAll()
  Trigger.UnloadDisplays(loaded)
end

function Trigger.Delete(id)
  Trigger.UnloadDisplays({[id] = true})
  displays[id] = nil
end

function Trigger.Rename(oldid, newid)
  displays[newid], loaded[newid] = displays[oldid], loaded[oldid]
  displays[oldid], loaded[oldid] = nil, nil
end

function Trigger.FinishLoadUnload() end
function Trigger.GetName() return "Aura (Modern)" end
function Trigger.CanHaveTooltip() return false end
function Trigger.SetToolTip() return false end
function Trigger.GetOverlayInfo() return {} end
function Trigger.GetAdditionalProperties() return {} end
function Trigger.GetProgressSources(data, triggernum, values)
  table.insert(values, {trigger = triggernum, property = "value", type = "number", display = "Aura (Modern)", total = "total"})
end
function Trigger.GetTriggerConditions() return {} end

function Trigger.GetNameAndIcon(data, triggernum)
  local trigger = data.triggers[triggernum].trigger
  -- Preview metadata follows the configured selections, without expanding ranks.
  local id = Display.GetSpellIDs(trigger, false)[1]
  local info = id and C_Spell.GetSpellInfo(id)
  return info and info.name or "Secret Auras", info and info.iconID or 134400
end

-- The hover summary uses unwrapped double-column rows. Bound each ID list here
-- so large selections cannot stretch it off-screen; the editor retains the full list.
local function SpellIDSummary(ids, enabled)
  if not enabled or not ids or #ids == 0 then return "None" end
  local shown = {}
  for index = 1, math.min(#ids, 3) do
    shown[#shown + 1] = tostring(ids[index])
  end
  local summary = table.concat(shown, ", ")
  if #ids > #shown then
    summary = summary .. " (+" .. (#ids - #shown) .. " more)"
  end
  return summary
end

function Trigger.GetTriggerDescription(data, triggernum, lines)
  local trigger = data.triggers[triggernum].trigger
  lines[#lines + 1] = {"Secret Auras", trigger.unit == "member" and (Display.SpecificUnit(trigger) or "Specific Unit") or Display.units[trigger.unit] or trigger.unit}
  -- What makes the display appear.
  local showOn = Display.showOnValues[Display.ShowOn(trigger)]
  local op, seconds = Display.RemainingWindow(trigger)
  if op then showOn = showOn .. ", remaining " .. op .. " " .. seconds .. " s" end
  lines[#lines + 1] = {"Show On", showOn}
  -- Describe both modes without relabelling existing exact selections.
  lines[#lines + 1] = {"Spell IDs (All Ranks)", SpellIDSummary(trigger.auraRankSpellIDs, Display.UsesRankSpellIDs(trigger))}
  lines[#lines + 1] = {"Exact Spell IDs", SpellIDSummary(trigger.auraspellids, Display.UsesSpellIDs(trigger))}
end

WeakAuras.RegisterTriggerSystem({"secretAura"}, Trigger)

unitFrame:SetScript("OnEvent", Private.Profiled("aura (modern) - trigger", unitFrame:GetScript("OnEvent")))
