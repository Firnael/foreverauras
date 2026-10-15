-- Modified for ForeverAuras, 2026-09-30.
-- Modifications Copyright (C) 2026 ForeverAuras. Licensed under the GNU GPL v2 (see LICENSE).
if not WeakAuras.IsLibsOK() then return end
local _, OptionsPrivate = ...

local function GetOptions(data, triggernum)
  local trigger = data.triggers[triggernum].trigger
  local display = OptionsPrivate.Private.BlizzardAuraDisplay
  local width = WeakAuras.normalWidth
  local function Save(key, value)
    trigger[key] = value
    OptionsPrivate.SaveAuraTrigger(data, triggernum)
    OptionsPrivate.QueueOptionsRefresh(data.id)
  end
  local auraTypes = {
    HELPFUL = "Buff", HARMFUL = "Debuff",
    Buff = "Blizzard: Buff", Debuff = "Blizzard: Debuff",
    Dispel = "Blizzard: Dispellable",
  }
  local classificationFilters = {Buff = "HELPFUL", Debuff = "HARMFUL", Dispel = "HARMFUL"}
  local function SelectedAuraType()
    local classification = trigger.processedAuraType
    if not classification or classification == "any" then return trigger.debuffType end
    if classificationFilters[classification] ~= trigger.debuffType then
      return classification .. ":" .. trigger.debuffType
    end
    return classification
  end
  local function AuraTypeValues()
    local values = {}
    for key, title in pairs(auraTypes) do values[key] = title end
    -- Preserve older independently selected filter/classification combinations.
    local selected = SelectedAuraType()
    if not values[selected] then
      values[selected] = (auraTypes[trigger.processedAuraType] or trigger.processedAuraType) .. " (" .. (auraTypes[trigger.debuffType] or trigger.debuffType) .. " filter)"
    end
    return values
  end
  local options = {
    -- The trigger is active whenever its unit exists; Blizzard shows the auras
    -- inside (SecretAuraTrigger.lua). Kept short on request.
    alwaysActive = {type = "description", order = 1.95, width = "full", fontSize = "medium",
      name = "|cffffffffNote: Trigger Always Active|r"},
    -- Green/red status for this trigger's own selection (Display.TriggerStatus).
    help = {type = "description", order = 2, width = "full", fontSize = "small",
      name = function() return display.TriggerStatus(data, trigger) end},
    unitLabel = {
      type = "toggle", name = "Unit", order = 3, width = width,
      disabled = true, get = function() return true end,
    },
    unit = {
      type = "select", name = "Unit", order = 3.01, width = width,
      -- Every unit stays selectable; the status line says when a unit does
      -- not work with the rest of the selection.
      values = display.units,
      get = function() return trigger.unit end, set = function(_, value) Save("unit", value) end,
    },
    specificUnitSpace = {
      type = "description", name = "", order = 3.02, width = width,
      hidden = function() return trigger.unit ~= "member" end,
    },
    specificUnit = {
      type = "input", name = "Specific Unit", order = 3.03, width = width,
      desc = "party1-4, partypet1-4, raid1-40, raidpet1-40, boss1-8 or arena1-5.",
      hidden = function() return trigger.unit ~= "member" end,
      validate = function(_, value)
        if display.SpecificUnit({specificUnit = value}) then return true end
        return "Enter a unit such as party1, raid5, boss1 or arena2."
      end,
      get = function() return trigger.specificUnit or "" end,
      set = function(_, value) Save("specificUnit", value:lower():match("^%s*(%S+)%s*$")) end,
    },
    auraTypeLabel = {
      type = "toggle", name = "Aura Type", order = 4, width = width,
      disabled = true, get = function() return true end,
    },
    debuffType = {
      type = "select", name = "Aura Type", order = 4.01, width = width, values = AuraTypeValues,
      sorting = function()
        local order = {"HELPFUL", "HARMFUL", "Buff", "Debuff", "Dispel"}
        local selected = SelectedAuraType()
        if not auraTypes[selected] then order[#order + 1] = selected end
        return order
      end,
      desc = "Buff and Debuff use your filters. Blizzard Classification also applies Blizzard's unit-frame visibility and dispel rules, so some auras may be hidden.",
      get = SelectedAuraType,
      set = function(_, value)
        if not auraTypes[value] then return end
        local classification = classificationFilters[value] and value or "any"
        trigger.debuffType = classificationFilters[value] or value
        if trigger.sortMethod == "UnitFrameDebuff" and classification ~= "Debuff" and classification ~= "Dispel" then
          trigger.sortMethod = "Default"
        end
        Save("processedAuraType", classification)
      end,
    },
    useUnitNames = {
      type = "toggle", name = "Player Name(s)", order = 4.1, width = width,
      desc = "Only track these group members. This also limits which units can play configured aura sounds.",
      hidden = function() return trigger.unit ~= "group" and trigger.unit ~= "party" and trigger.unit ~= "raid" end,
      get = function() return trigger.useUnitNames or false end,
      set = function(_, value) Save("useUnitNames", value) end,
    },
    unitNames = {
      type = "input", name = "Player Names", order = 4.2, width = "full",
      desc = "Enter character names separated by commas. Include both the first name and surname, keeping the space between them. Capitalization does not matter. Only group members whose names are available to addons can match.",
      hidden = function() return not trigger.useUnitNames or (trigger.unit ~= "group" and trigger.unit ~= "party" and trigger.unit ~= "raid") end,
      get = function() return table.concat(trigger.unitNames or {}, ", ") end,
      set = function(_, value)
        local names = {}
        for name in value:gmatch("[^,]+") do
          name = strtrim(name)
          if name ~= "" then names[#names + 1] = name end
        end
        Save("unitNames", names)
      end,
    },
    useUnitRoles = {
      type = "toggle", name = "Group Role", order = 4.3, width = width,
      desc = "Only track members with the selected assigned group roles. This also limits configured aura sounds. Player-name and role filters must both match when enabled.",
      hidden = function() return trigger.unit ~= "group" and trigger.unit ~= "party" and trigger.unit ~= "raid" end,
      get = function() return trigger.useUnitRoles or false end,
      set = function(_, value) Save("useUnitRoles", value) end,
    },
    unitRoles = {
      type = "multiselect", name = "Group Roles", order = 4.4, width = "full",
      values = {TANK = "Tank", HEALER = "Healer", DAMAGER = "Damage", NONE = "Unassigned"},
      desc = "Uses Blizzard's assigned group role. Members without a role assigned match Unassigned.",
      hidden = function() return not trigger.useUnitRoles or (trigger.unit ~= "group" and trigger.unit ~= "party" and trigger.unit ~= "raid") end,
      get = function(_, role) return (trigger.unitRoles or {})[role] or false end,
      set = function(_, role, value)
        trigger.unitRoles = trigger.unitRoles or {}
        trigger.unitRoles[role] = value or nil
        Save("unitRoles", trigger.unitRoles)
      end,
    },
    useIncludePets = {
      type = "toggle", name = "Include Pets", order = 4.45, width = width,
      hidden = function() return trigger.unit ~= "group" and trigger.unit ~= "party" and trigger.unit ~= "raid" end,
      get = function() return trigger.useIncludePets or false end,
      set = function(_, value) Save("useIncludePets", value) end,
    },
    includePets = {
      type = "select", name = "Include Pets", order = 4.46, width = width,
      values = OptionsPrivate.Private.include_pets_types,
      hidden = function() return trigger.unit ~= "group" and trigger.unit ~= "party" and trigger.unit ~= "raid" end,
      disabled = function() return not trigger.useIncludePets end,
      get = function() return trigger.includePets or "PlayersAndPets" end,
      set = function(_, value) Save("includePets", value) end,
    },
    ignoreDead = {
      type = "toggle", name = "Ignore Dead", order = 4.47, width = width,
      desc = "Hide this unit's part of the display while it is dead or a ghost.",
      get = function() return trigger.ignoreDead or false end,
      set = function(_, value) Save("ignoreDead", value or nil) end,
    },
    ignoreDisconnected = {
      type = "toggle", name = "Ignore Disconnected", order = 4.48, width = width,
      desc = "Hide this unit's part of the display while it is offline.",
      get = function() return trigger.ignoreDisconnected or false end,
      set = function(_, value) Save("ignoreDisconnected", value or nil) end,
    },
    filtersHeader = {type = "header", name = "Aura Filters", order = 10},
    -- Maximum Duration is now Total Duration "<=" (AuraTriggerOptions.lua).
    includeNameplateOnly = {
      type = "toggle", name = "Include nameplate-only auras", order = 21, width = "full",
      desc = "Also allows auras normally returned only for nameplate displays. Other filters still apply.",
      get = function() return trigger.includeNameplateOnly or false end, set = function(_, value) Save("includeNameplateOnly", value) end,
      hidden = function() return trigger.unit ~= "nameplate" end,
    },

  }
  options.spellSelectionHeader = {type = "header", name = "Spell Selection Filters", order = 4.5}
  local function SpellIDs(toggleKey, prefix, storageKey, title, inputName, order, Enabled, flag)
    options[toggleKey] = {
      type = "toggle", name = title, order = order, width = width - 0.2,
      get = function() return Enabled(trigger) end,
      set = function(_, value) Save(flag, value) end,
    }
    options[prefix .. "DisabledSpace"] = {
      type = "description", name = "", order = order + 0.001, width = width + 0.2,
      hidden = function() return Enabled(trigger) end,
    }
    local size = #(trigger[storageKey] or {}) + 1
    OptionsPrivate.CreateAuraSpellOptions(options, data, triggernum, size,
      true, false, prefix, order, flag, storageKey, inputName,
      nil,
      false, function() return Enabled(trigger) end)
    -- Unlike Legacy, these values are also sent to Blizzard's native filters.
    for i = 1, size do
      options[prefix .. i].validate = function(_, value)
        if value == "" then return true end
        local id = tonumber(value)
        if not id or id <= 0 or id >= 2147483647 or id ~= math.floor(id) then
          return "Enter a positive whole-number Spell ID."
        end
        return true
      end
    end
  end
  -- Rank matching has independent storage, so old exact selections keep their meaning.
  SpellIDs("useRankSpellIDs", "rankspellid", "auraRankSpellIDs", "Spell ID(s) (All Ranks)", "Spell ID", 4.95,
    display.UsesRankSpellIDs, "secretUseRankSpellIDs")
  options.useRankSpellIDs.desc = "Enter a Spell ID to track all ranks of that spell."
  -- Explain incomplete coverage without changing existing saved selections.
  local function UnsupportedRankIDs()
    local missing = {}
    for _, value in ipairs(trigger.auraRankSpellIDs or {}) do
      local id = tonumber(value)
      if id and not OptionsPrivate.Private.AuraSpellRankSupported(id) then
        missing[#missing + 1] = tostring(value)
      end
    end
    return missing
  end
  options.rankCoverage = {
    type = "description", order = 5.9, width = "full", fontSize = "small",
    hidden = function() return not display.UsesRankSpellIDs(trigger) or #UnsupportedRankIDs() == 0 end,
    name = function()
      return "Other ranks could not be found for: " .. table.concat(UnsupportedRankIDs(), ", ")
        .. ". Only the IDs you entered will be tracked. To track another rank, add its ID under Exact Spell ID(s)."
    end,
  }
  SpellIDs("useSpellIDs", "spellid", "auraspellids", "Exact Spell ID(s)", "Exact Spell ID", 6,
    display.UsesSpellIDs, "secretUseSpellIDs")
  -- Spell Lists (Display.SpellList) are set by importing a pack, not here: a
  -- trigger with secretSpellList shows a one-line note so the empty ID fields
  -- make sense, and keeps working as data.
  options.spellListNote = {
    type = "description", order = 6.9, width = WeakAuras.doubleWidth, fontSize = "small",
    hidden = function() return not display.UsesSpellList(trigger) end,
    name = function() return "Spell IDs come from the Spell List |cffffd100" .. tostring(trigger.secretSpellList) .. "|r, set by this pack's backend aura." end,
  }
  SpellIDs("useExcludedSpellIDs", "ignorespellid", "excludedAuraSpellIDs", "Ignored Exact Spell ID(s)", "Ignored Spell ID", 7,
    display.UsesExcludedSpellIDs, "secretUseExcludedSpellIDs")
  local function TriState(key, title, order, description, GetValue, SetValue)
    options[key] = {
      type = "toggle", width = "full", order = order,
      name = function()
        local value = GetValue()
        if value == nil then return title end
        return value and "|cFF00FF00" .. title .. "|r" or "|cFFFF0000Not " .. title .. "|r"
      end,
      desc = description,
      get = function()
        local value = GetValue()
        if value == nil then return false end
        return value and "true" or "false"
      end,
      set = function(_, checked)
        if checked then SetValue(true)
        elseif GetValue() == false then SetValue(nil)
        else SetValue(false) end
      end,
    }
  end
  for index, field in ipairs(display.booleanFilters) do
    local key = field[1]
    local title = field[2]
    TriState(key, title, 10 + index,
      field[3],
      function() return trigger[key] end, function(value) Save(key, value) end)
    if key == "nameplateShowAll" or key == "nameplateShowPersonal" then
      options[key].hidden = function() return trigger.unit ~= "nameplate" end
      options[key].desc = (key == "nameplateShowAll"
        and "Only match auras Blizzard marks for display on all nameplates."
        or "Only match auras marked for Blizzard's personal-debuff display on nameplates. This does not refer to your personal resource bar.")
        .. " This checks Blizzard's nameplate flag. It does not change where the icon appears or who cast the aura."
    end
  end
  for index, key in ipairs({"includeDispelTypes", "excludeDispelTypes"}) do
    options[key] = {
      type = "multiselect", name = index == 1 and "Include dispel types" or "Exclude dispel types", order = 23 + index, width = "full",
      values = display.dispelTypes,
      get = function(_, name) return trigger[key] and trigger[key][name] or false end,
      set = function(_, name, value)
        local values = {}
        for k, v in pairs(trigger[key] or {}) do values[k] = v end
        values[name] = value and true or nil
        Save(key, next(values) and values or nil)
      end,
    }
  end
  for index, field in ipairs(display.processingOptions) do
    local key = field[1]
    options[key] = {
      type = "toggle", name = field[2], order = 25 + index, width = width,
      disabled = function() return not trigger.processedAuraType or trigger.processedAuraType == "any" end,
      desc = key == "displayOnlyDispellableDebuffs"
        and "Changes Blizzard's unit-frame classification paths; priority and boss exceptions may still apply. To show only dispellable auras, use the dispel filters under Aura Filters."
        or "Controls Blizzard's classification pass. Ignoring the selected classification can hide all matching auras.",
      get = function() return trigger[key] or false end, set = function(_, value) Save(key, value) end,
    }
  end
  for index, field in ipairs(display.nativeFilters) do
    local key = field[1]
    TriState("native" .. key, field[2], 20 + index / 20, field[3],
      function() return (trigger.nativeFilters or {})[key] end,
      function(value)
        local filters = {}
        for k, v in pairs(trigger.nativeFilters or {}) do filters[k] = v end
        filters[key] = value
        Save("nativeFilters", next(filters) and filters or nil)
      end)
  end
  options.isFromPlayerOrPlayerPet.width = width
  options.nativePLAYER.width = width
  options.nativePLAYER.order = options.isFromPlayerOrPlayerPet.order
  options.isFromPlayerOrPlayerPet.order = options.nativePLAYER.order + 0.01
  for _, field in ipairs(display.processingOptions) do options[field[1]] = nil end
  for _, fields in ipairs({display.nativeFilters, display.booleanFilters}) do
    for _, field in ipairs(fields) do
      local key = field[1]
      local option = options[fields == display.nativeFilters and "native" .. key or key]
      if option then
        local hidden = option.hidden
        option.hidden = function()
          return not display.FilterApplies(key, trigger) or (type(hidden) == "function" and hidden()) or hidden == true
        end
      end
    end
  end
  OptionsPrivate.commonOptions.AddCommonTriggerOptions(options, data, triggernum, true)
  OptionsPrivate.AuraEditor.AddOptions(options, data, triggernum)
  OptionsPrivate.AddTriggerMetaFunctions(options, data, triggernum)
  return {["trigger." .. triggernum .. ".secretAura"] = options}
end

WeakAuras.RegisterTriggerSystemOptions({"secretAura"}, GetOptions)
