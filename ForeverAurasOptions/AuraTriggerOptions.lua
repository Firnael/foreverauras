-- Copyright (C) 2026 ForeverAuras. Part of ForeverAuras, licensed under the GNU GPL v2 (see LICENSE).
if not WeakAuras.IsLibsOK() then return end
local _, OptionsPrivate = ...
local Editor = {}
OptionsPrivate.AuraEditor = Editor

local auraTypes = {
  HELPFUL = "Buff", HARMFUL = "Debuff", BOTH = "Buff or Debuff",
  Buff = "Blizzard: Buff", Debuff = "Blizzard: Debuff", Dispel = "Blizzard: Dispellable",
}
local classificationFilters = {Buff = "HELPFUL", Debuff = "HARMFUL", Dispel = "HARMFUL"}

function Editor.Mode(trigger)
  if trigger.auraTracking == "native" or trigger.auraTracking == "readable" then return trigger.auraTracking end
  return trigger.type == "secretAura" and "native" or "readable"
end

function Editor.Resolve(data, triggernum)
  local trigger = data.triggers[triggernum].trigger
  if trigger.type ~= "aura2" and trigger.type ~= "secretAura" then return end
  local mode = Editor.Mode(trigger)
  local native = mode == "native"
  local wanted = native and "secretAura" or "aura2"
  if wanted == trigger.type then return end
  if native then
    trigger.auraReadableSettings = {
      onlyMaw = trigger.onlyMaw, automaticWidth = data.automaticWidth, debuffType = trigger.debuffType,
    }
    if trigger.debuffType == "BOTH" then trigger.debuffType = "HELPFUL" end
    trigger.secretUseSpellIDs = trigger.useExactSpellId or false
    trigger.type = wanted
    OptionsPrivate.Private.BlizzardAuraDisplay.Migrate(data)
  else
    local previous = trigger.auraReadableSettings
    trigger.useExactSpellId = OptionsPrivate.Private.BlizzardAuraDisplay.UsesSpellIDs(trigger)
    if previous then
      trigger.onlyMaw = previous.onlyMaw
      data.automaticWidth = previous.automaticWidth
      if previous.debuffType == "BOTH" then trigger.debuffType = "BOTH" end
    end
    trigger.type = wanted
    trigger.auraReadableSettings = nil
  end
  OptionsPrivate.QueueOptionsRefresh(data.id)
end

function OptionsPrivate.SaveAuraTrigger(data, triggernum)
  Editor.Resolve(data, triggernum)
  WeakAuras.Add(data)
end

function Editor.AddOptions(options, data, triggernum)
  local trigger = data.triggers[triggernum].trigger
  local native = trigger.type == "secretAura"
  local function Save() OptionsPrivate.SaveAuraTrigger(data, triggernum); OptionsPrivate.QueueOptionsRefresh(data.id) end
  if native then
    options.help.fontSize = "small"
  else
    options.auraCapabilities = {
      type = "description", order = 1.3, width = "full", fontSize = "small",
      name = "Legacy Auras rarely function in combat as most are Blizzard-controlled.",
    }
  end
  local auraType = options.debuffType
  auraType.values = native and {HELPFUL = "Buff", HARMFUL = "Debuff"} or {HELPFUL = "Buff", HARMFUL = "Debuff", BOTH = "Buff or Debuff"}
  auraType.sorting = native and {"HELPFUL", "HARMFUL"} or {"HELPFUL", "HARMFUL", "BOTH"}
  auraType.get = function() return trigger.debuffType end
  auraType.set = function(_, value)
    if not auraType.values[value] then return end
    trigger.processedAuraType = "any"
    trigger.debuffType = value
    if trigger.sortMethod == "UnitFrameDebuff" then trigger.sortMethod = "Default" end
    Save()
  end
  if native then
    local display = OptionsPrivate.Private.BlizzardAuraDisplay
    -- Seconds as typed, accepting a decimal comma ("1,5") as many locales write it.
    local function Seconds(value)
      return type(value) == "string" and (value:gsub(",", ".")) or value
    end
    -- Remaining Time heads the Aura Filters section, as it heads Legacy's
    -- Active Aura Filters; like Legacy, only with Show On: Aura(s) Found.
    local function RemainingHidden() return display.RawShowOn(trigger) ~= "showOnActive" end
    options.useRem = {type = "toggle", name = "Remaining Time", order = 10.01, width = WeakAuras.normalWidth,
      hidden = RemainingHidden,
      get = function() return trigger.secretUseRem or false end,
      set = function(_, value)
        trigger.secretUseRem = value or nil
        -- Start from "less than 5 seconds", the usual "about to run out" check.
        if value and trigger.secretRemOperator == nil then trigger.secretRemOperator = "<" end
        if value and tonumber(trigger.secretRem) == nil then trigger.secretRem = "5" end
        Save()
      end}
    options.remOperator = {type = "select", name = "Operator", order = 10.02, width = WeakAuras.halfWidth,
      values = display.remOperators, sorting = {"<", "<=", ">", ">="},
      hidden = function() return RemainingHidden() or not trigger.secretUseRem end,
      get = function() return trigger.secretRemOperator or "<" end,
      set = function(_, value) trigger.secretRemOperator = value; Save() end}
    options.rem = {type = "input", name = "Remaining Time", order = 10.03, width = WeakAuras.halfWidth,
      hidden = function() return RemainingHidden() or not trigger.secretUseRem end,
      validate = function(_, value)
        local seconds = tonumber(Seconds(value))
        if not seconds or seconds < 0 or seconds ~= seconds or seconds == math.huge then return "Enter a number of seconds, 0 or more." end
        return true
      end,
      get = function() return trigger.secretRem and tostring(trigger.secretRem) or "" end,
      set = function(_, value) trigger.secretRem = Seconds(value); Save() end}
    options.useRemSpace = {type = "description", name = "", order = 10.04, width = WeakAuras.normalWidth,
      hidden = function() return RemainingHidden() or trigger.secretUseRem end}
    local function ValidSeconds(value)
      local seconds = tonumber(Seconds(value))
      if not seconds or seconds <= 0 or seconds ~= seconds or seconds == math.huge then return "Enter a number of seconds above 0." end
      return true
    end
    -- Total Duration: a standard filter on the aura's full duration, laid out
    -- like Remaining Time. "<=" works everywhere; "=" and ">=" on Icons.
    options.useTotal = {type = "toggle", name = "Total Duration", order = 10.05, width = WeakAuras.normalWidth,
      get = function() return trigger.secretUseTotal or false end,
      set = function(_, value)
        trigger.secretUseTotal = value or nil
        if value and trigger.secretTotalOperator == nil then trigger.secretTotalOperator = "=" end
        Save()
      end}
    options.totalOperator = {type = "select", name = "Operator", order = 10.06, width = WeakAuras.halfWidth,
      values = display.totalOperators, sorting = {"=", "<=", ">="},
      hidden = function() return not trigger.secretUseTotal end,
      get = function() return trigger.secretTotalOperator or "=" end,
      set = function(_, value) trigger.secretTotalOperator = value; Save() end}
    options.total = {type = "input", name = "Total Duration", order = 10.07, width = WeakAuras.halfWidth,
      hidden = function() return not trigger.secretUseTotal end,
      validate = function(_, value) return ValidSeconds(value) end,
      get = function() return trigger.secretTotal and tostring(trigger.secretTotal) or "" end,
      set = function(_, value) trigger.secretTotal = Seconds(value); Save() end}
    options.useTotalSpace = {type = "description", name = "", order = 10.08, width = WeakAuras.normalWidth,
      hidden = function() return trigger.secretUseTotal end}
    -- Stack Count: laid out like Total Duration. Blizzard has no stack filter,
    -- so it is drawn by a clip around the display (SecretAuraSingle.lua).
    options.useStacks = {type = "toggle", name = "Stack Count", order = 10.085, width = WeakAuras.normalWidth,
      get = function() return trigger.secretUseStacks or false end,
      set = function(_, value)
        trigger.secretUseStacks = value or nil
        if value and trigger.secretStacksOperator == nil then trigger.secretStacksOperator = ">=" end
        Save()
      end}
    options.stacksOperator = {type = "select", name = "Operator", order = 10.086, width = WeakAuras.halfWidth,
      values = display.stackOperators, sorting = {"=", ">=", ">", "<=", "<"},
      hidden = function() return not trigger.secretUseStacks end,
      get = function() return trigger.secretStacksOperator or ">=" end,
      set = function(_, value) trigger.secretStacksOperator = value; Save() end}
    options.stacks = {type = "input", name = "Stack Count", order = 10.087, width = WeakAuras.halfWidth,
      hidden = function() return not trigger.secretUseStacks end,
      validate = function(_, value)
        local count = tonumber(value)
        if not count or count ~= math.floor(count) or count < 0 or count > display.STACK_LIMIT then
          return "Enter a whole number from 0 to " .. display.STACK_LIMIT .. "."
        end
        return true
      end,
      get = function() return trigger.secretStacks and tostring(trigger.secretStacks) or "" end,
      set = function(_, value) trigger.secretStacks = tonumber(value); Save() end}
    options.useStacksSpace = {type = "description", name = "", order = 10.088, width = WeakAuras.normalWidth,
      hidden = function() return trigger.secretUseStacks end}
    -- Debuffs on friendly units cannot be picked by spell ID in combat; this
    -- matches the entered spell by its known duration and type instead. Shown
    -- under Aura Type once a spell ID is entered.
    options.secretApproximate = {type = "toggle", name = "Approximate Match", order = 4.02, width = "full",
      desc = "Approximates the selected spell ID based on its duration and other learned information.",
      hidden = function()
        return not (display.approximateUnits[display.UnitCategory(trigger)] and trigger.debuffType == "HARMFUL"
          and #display.GetSpellIDs(trigger, true) > 0)
      end,
      get = function() return trigger.secretApproximate or false end,
      set = function(_, value) trigger.secretApproximate = value or nil; Save() end}
    options.show_settings_header = {type = "header", name = "Show and Clone Settings", order = 69.91}
    -- Same label/selector pair and values as Aura (Legacy). Aura(s) Found keeps
    -- the list behaviour; Missing and Always draw one aura (SecretAuraSingle.lua).
    options.use_matchesShowOn = {type = "toggle", name = "Show On", order = 71, width = WeakAuras.normalWidth,
      get = function() return true end, disabled = true}
    options.matchesShowOn = {type = "select", name = "Show On", order = 71.1, width = WeakAuras.normalWidth,
      values = display.showOnValues,
      sorting = {"showOnActive", "showOnMissing", "showAlways"},
      get = function() return display.RawShowOn(trigger) end,
      set = function(_, value)
        if not display.showOnValues[value] then return end
        trigger.secretShowOn = value ~= "showOnActive" and value or nil
        Save()
      end}
    -- The Missing icon's look is set with an "Aura Active = False" condition
    -- (SecretAuraConditions.lua); the former box here is migrated to one.
    -- As in Aura (Legacy): the trigger is inactive while its target, focus or
    -- pet does not exist (SecretAuraTrigger.lua), unless this is ticked.
    options.unitExists = {type = "toggle", name = "Show If Unit Does Not Exist", order = 71.3, width = WeakAuras.doubleWidth,
      desc = "Keep this trigger active while there is no such unit. Otherwise it is inactive then, so other triggers can supply the display.",
      hidden = function()
        local unit = trigger.unit
        return not (unit == "target" or unit == "focus" or unit == "pet" or unit == "targettarget" or unit == "focustarget" or unit == "member")
      end,
      get = function() return trigger.unitExists or false end,
      set = function(_, value) trigger.unitExists = value or nil; Save() end}
    options.showClones = {type = "toggle", name = "Auto-Clone (Show All Matches)", order = 72, width = "full",
      get = function() return trigger.showClones or false end, disabled = true}
    options.combineMode = {type = "select", name = "Preferred Match", order = 72.6, width = WeakAuras.normalWidth,
      values = OptionsPrivate.Private.bufftrigger_2_preferred_match_types, get = function() return trigger.combineMode or "showLowest" end, disabled = true}
    options.nativeShowNotice = {type = "description", order = 73, width = "full", fontSize = "small",
      name = function()
        if display.IsSingle(trigger, data) then
          return "One aura is shown, chosen by Sort by under Aura (Modern) Settings in Display."
        end
        return "You cannot control clones with an Aura (Modern). Use the Aura (Modern) Settings under Display."
      end}
  end
end
