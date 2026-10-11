-- Modified for ForeverAuras, 2026-10-08.
-- Modifications Copyright (C) 2026 ForeverAuras. Licensed under the GNU GPL v2 (see LICENSE).
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript, C_Timer = Private.TimedAPI("BlizzardAuraDisplay")
local SharedMedia = LibStub("LibSharedMedia-3.0")
local Display = {}
Private.BlizzardAuraDisplay = Display
local pending = setmetatable({}, {__mode = "k"})
-- Containers locked in combat: hidden, or given their units, once it ends.
local lockedHide = setmetatable({}, {__mode = "k"})
local lockedUnits = setmetatable({}, {__mode = "k"})
local pendingSounds = {}
local activeRegions = {}
-- For the hitch report: how many Modern displays are active and how many
-- native aura containers they hold (shown ones counted separately).
function Display.CountContainers()
  local displays, containers, shown = 0, 0, 0
  for region in pairs(activeRegions) do
    displays = displays + 1
    local native = region.blizzardAuraDisplay
    for _, instance in ipairs(native and native.instances or {}) do
      containers = containers + 1
      if instance.visible then shown = shown + 1 end
    end
  end
  return displays, containers, shown
end
local unitGlowFrameLevel = 8

Display.units = {
  player = "Player", target = "Target", focus = "Focus", pet = "Pet", mouseover = "Mouseover",
  targettarget = "Target of Target", focustarget = "Target of Focus", group = "Smart Group",
  party = "Party", raid = "Raid", boss = "Boss", arena = "Arena", nameplate = "Nameplate",
  member = "Specific Unit",
}

local specificUnitPatterns = {
  {"^party[1-4]$", "party"}, {"^partypet[1-4]$", "party"},
  {"^raid(%d+)$", "raid", 40}, {"^raidpet(%d+)$", "raid", 40},
  {"^boss[1-8]$", "boss"}, {"^arena[1-5]$", "arena"},
}

function Display.SpecificUnit(trigger)
  local text = type(trigger) == "table" and type(trigger.specificUnit) == "string" and trigger.specificUnit:lower():match("^%s*(%S+)%s*$")
  if not text then return end
  for _, pattern in ipairs(specificUnitPatterns) do
    local number = text:match(pattern[1])
    if number then
      local n = tonumber(number)
      if not pattern[3] or (n and n >= 1 and n <= pattern[3]) then return text, pattern[2] end
    end
  end
end

function Display.UnitCategory(trigger)
  if type(trigger) ~= "table" then return end
  if trigger.unit == "member" then return select(2, Display.SpecificUnit(trigger)) end
  return trigger.unit
end

Display.booleanFilters = {
  {"isFromPlayerOrPlayerPet", "Cast by a Player", "Auras cast by any player or player pet, not only yours. For your own auras, use Own Only."},
  {"canApplyAura", "Can Apply Aura", "Auras Blizzard says your character can apply."},
  {"isStealable", "Is Stealable", "Buffs that can be stolen with abilities such as Spellsteal."},
  {"isBossAura", "Is Boss Aura", "Auras Blizzard identifies as boss auras."},
  {"isRoleAura", "Role aura", "Auras Blizzard marks as relevant to your role."},
  {"isBossOrRoleAura", "Boss or role aura", "Auras Blizzard identifies as boss auras or marks as relevant to your role."},
  {"isPriorityAura", "Priority debuff", "Debuffs Blizzard marks as high priority."},
  {"nameplateShowAll", "Marked for all nameplates", "Auras Blizzard marks for display on all nameplates."},
  {"nameplateShowPersonal", "Marked for personal debuff display", "Auras Blizzard marks for its personal-debuff display on nameplates."},
}

-- The saved Aura (Modern) trigger that drives the display. Options write to
-- this table; GetTrigger below may return a working copy.
-- A cut that starts between screen pixels redraws what it holds blurred; the
-- engine rounds it to whole pixels, also where its place cannot be read.
function Display.ClipChildren(frame)
  frame:SetClipsChildren(true)
  if frame.SetRoundLayoutToNearestPixel then frame:SetRoundLayoutToNearestPixel(true) end
end

function Display.GetSavedTrigger(data)
  if not data or type(data.triggers) ~= "table" then return end
  local source = data.progressSource and data.progressSource[1] or -1
  if source == 0 then return end
  if source < 0 then source = data.triggers.activeTriggerMode or -1 end
  if source < 0 then source = (Private.GetActiveTriggerFor and Private.GetActiveTriggerFor(data.id)) or 1 end
  local entry = data.triggers[source]
  local trigger = type(entry) == "table" and entry.trigger
  if trigger and trigger.type == "secretAura" then return trigger end
end

function Display.GetTrigger(data, displayFilters)
  local trigger = Display.GetSavedTrigger(data)
  if trigger then
    if displayFilters then
      trigger = CopyTable(trigger)
      trigger.processedAuraType = nil
      if trigger.sortMethod == "UnitFrameDebuff" then trigger.sortMethod = "Default" end
      for _, field in ipairs(Display.processingOptions) do trigger[field[1]] = nil end
    end
    if trigger.processedAuraType or trigger.sortMethod == "UnitFrameDebuff" then
      trigger = CopyTable(trigger)
      trigger.processedAuraType = nil
      if trigger.sortMethod == "UnitFrameDebuff" then trigger.sortMethod = "Default" end
    end
    return trigger
  end
end

function Display.HasTrigger(data)
  for _, entry in ipairs(data and data.triggers or {}) do
    if type(entry) == "table" and entry.trigger and entry.trigger.type == "secretAura" then return true end
  end
  return false
end

function Display.UsesNameplates(data)
  local trigger = Display.GetTrigger(data)
  return (trigger and trigger.unit == "nameplate") or data.anchorFrameType == "NAMEPLATE"
end

local function IsNameplateFilter(key)
  return key == "nameplateShowAll" or key == "nameplateShowPersonal"
end
Display.dispelTypes = {Magic = "Magic", Curse = "Curse", Disease = "Disease", Poison = "Poison", Bleed = "Bleed", [""] = "Enrage"}
Display.nativeFilters = {
  {"PLAYER", "Own Only", "Auras cast by you, your pet or your vehicle."},
  {"RAID", "Can apply / dispel", "Buffs you can apply, or debuffs you can dispel."},
  {"CANCELABLE", "Cancelable", "Auras that the player can cancel."},
  {"EXTERNAL_DEFENSIVE", "External defensive", "Auras Blizzard classifies as external defensives."},
  {"CROWD_CONTROL", "Crowd control", "Auras with a crowd-control effect, such as a stun or fear."},
  {"RAID_IN_COMBAT", "Shown on raid frames in combat", "Auras flagged by Blizzard for raid-frame display in combat."},
  {"RAID_PLAYER_DISPELLABLE", "Dispellable by someone in your raid", "Includes helpful enrages on enemies."},
  {"BIG_DEFENSIVE", "Big defensive", "Auras Blizzard classifies as big defensives."},
  {"IMPORTANT", "Important aura", "Blizzard's important-aura flag, including non-stealable enemy buffs shown on nameplates."},
  {"DISPELLABLE", "Dispellable", "Dispellable regardless of your or your raid's current abilities."},
}

function Display.FilterApplies(key, trigger)
  local buffOnly = {CANCELABLE=true, EXTERNAL_DEFENSIVE=true, BIG_DEFENSIVE=true, IMPORTANT=true, isStealable=true}
  local debuffOnly = {CROWD_CONTROL=true, isPriorityAura=true, isBossAura=true, isRoleAura=true, isBossOrRoleAura=true}
  return not (buffOnly[key] and trigger.debuffType ~= "HELPFUL") and not (debuffOnly[key] and trigger.debuffType ~= "HARMFUL")
end

local function FilterString(trigger)
  local filters = {trigger.debuffType}
  for _, field in ipairs(Display.nativeFilters) do
    local value = (trigger.nativeFilters or {})[field[1]]
    if value ~= nil and Display.FilterApplies(field[1], trigger) then filters[#filters + 1] = (value and "" or "!") .. field[1] end
  end
  if trigger.includeNameplateOnly and trigger.unit == "nameplate" then filters[#filters + 1] = "INCLUDE_NAME_PLATE_ONLY" end
  return table.concat(filters, "|")
end
Display.sortMethods = {
  Default = "Blizzard default", BigDefensive = "Big defensives", UnitFrameDebuff = "Unit-frame debuffs",
  ImportantOnly = "Importance only", Expiration = "Remaining time (Blizzard priority)",
  ExpirationOnly = "Remaining time", Name = "Name (Blizzard priority)", NameOnly = "Name",
  AuraInstanceIDOnly = "Aura instance ID",
}
Display.processedTypes = {any = "Any (no classification)", Buff = "Buff", Debuff = "Debuff", Dispel = "Dispellable raid debuff"}
Display.processingOptions = {
  {"displayOnlyDispellableDebuffs", "Use dispellable-debuff classification"},
  {"ignoreBuffs", "Ignore buff classification"},
  {"ignoreDebuffs", "Ignore debuff classification"},
  {"ignoreDispelDebuffs", "Ignore dispel classification"},
}

function Display.UsesSpellIDs(trigger)
  return trigger.secretUseSpellIDs ~= false and (#(trigger.auraspellids or {}) > 0 or trigger.secretUseSpellIDs == true)
end

-- Keep the original exact-ID flag and storage unchanged for existing auras.
function Display.UsesRankSpellIDs(trigger)
  return trigger.secretUseRankSpellIDs == true
end

function Display.GetSpellIDs(trigger, expandRanks)
  local ids, seen = {}, {}
  local function Add(value)
    local id = tonumber(value)
    if id and id > 0 and id < 2147483647 and id == math.floor(id) and not seen[id] then
      seen[id] = true; ids[#ids + 1] = id
    end
  end
  if Display.UsesRankSpellIDs(trigger) then
    for _, value in ipairs(trigger.auraRankSpellIDs or {}) do
      local id = tonumber(value)
      if id and id > 0 and id < 2147483647 and id == math.floor(id) then
        Add(id)
        if expandRanks then
          for _, rankID in ipairs(Private.GetAuraSpellRanks(id) or {}) do Add(rankID) end
        end
      end
    end
  end
  if Display.UsesSpellIDs(trigger) then
    for _, value in ipairs(trigger.auraspellids or {}) do Add(value) end
  end
  return ids
end

function Display.UsesExcludedSpellIDs(trigger)
  return trigger.secretUseExcludedSpellIDs ~= false and (#(trigger.excludedAuraSpellIDs or {}) > 0 or trigger.secretUseExcludedSpellIDs == true)
end

function Display.HasAdditionalFilters(trigger)
  if next(trigger.nativeFilters or {}) then return true end
  if Display.UsesExcludedSpellIDs(trigger) or next(trigger.includeDispelTypes or {})
    or next(trigger.excludeDispelTypes or {}) or Display.TotalFilter(trigger) ~= nil
    or (trigger.processedAuraType and trigger.processedAuraType ~= "any") then return true end
  for _, field in ipairs(Display.booleanFilters) do
    if trigger[field[1]] ~= nil and (not IsNameplateFilter(field[1]) or trigger.unit == "nameplate") then return true end
  end
  return false
end

-- Elements are ordered back to front, independently of the aura's frame strata.
function Display.Elements(settings)
  if not settings.elements then
    settings.elements = {"border"}
    if settings.glow then table.insert(settings.elements, "glow") end
    if settings.duration ~= false then table.insert(settings.elements, "duration") end
    if settings.stacks ~= false then table.insert(settings.elements, "stack") end
    if settings.label and settings.label ~= "" then table.insert(settings.elements, "label") end
  end
  return settings.elements
end

local function ElementFrame(native, key)
  native.elementFrames = native.elementFrames or {}
  if not native.elementFrames[key] then
    -- Icons: every element lives in the Total Duration gate clip (SecretAuraSingle.lua).
    local frame = CreateFrame("Frame", nil, native.gateClip or native.button)
    frame:SetAllPoints(native.button)
    frame:EnableMouse(false)
    native.elementFrames[key] = frame
  end
  return native.elementFrames[key]
end

function Display.Migrate(data)
  local legacy = data.blizzardAuraDisplay
  if data.blizzardAuraDisplay and data.blizzardAuraDisplay.enabled and data.triggers and #data.triggers == 1
    and data.triggers[1].trigger.type == "aura2" then
    data.triggers[1].trigger.type = "secretAura"
    data.blizzardAuraDisplay.enabled = nil
  end
  for _, entry in ipairs(data.triggers or {}) do
    if type(entry) == "table" and entry.trigger and entry.trigger.type == "secretAura" then
      entry.trigger.unit = entry.trigger.unit or "player"
      entry.trigger.debuffType = entry.trigger.debuffType or "HELPFUL"
      entry.trigger.auraspellids = entry.trigger.auraspellids or {}
      entry.trigger.useExactSpellId = true
      entry.trigger.onlyMaw = nil
      -- Settings from pre-release test builds (SecretAuraSingle.lua).
      Display.MigrateSingle(data, entry.trigger)
      -- Maximum Duration becomes Total Duration.
      Display.MigrateTotal(entry.trigger)
      data.blizzardAuraDisplay = data.blizzardAuraDisplay or {}
      data.blizzardAuraDisplay.enabled = nil
    end
  end
  if Display.HasTrigger(data) then
    Display.MigrateAppearance(data, legacy)
    for _, element in ipairs(data.subRegions or {}) do
      if element.type == "subtext" then
        if element.text_alpha == nil then element.text_alpha = 1 end
        if element.text_anchorXOffset == nil then element.text_anchorXOffset = element.anchorXOffset or 0 end
        if element.text_anchorYOffset == nil then element.text_anchorYOffset = element.anchorYOffset or 0 end
      end
    end
    Display.MigrateSounds(data)
    data.blizzardAuraDisplay.soundSpellIDs = nil
    data.blizzardAuraDisplay.soundIgnoreDisplayFilters = nil
  end
end

function Display.Eligible(data)
  return data and (data.regionType == "icon" or data.regionType == "aurabar" or data.regionType == "text" or data.regionType == "progresstexture") and Display.GetTrigger(data) ~= nil
end

function Display.Enabled(data)
  return Display.Eligible(data)
end

local function UnitCount(unit)
  if unit == "group" or unit == "raid" or unit == "nameplate" then return 40 end
  if unit == "party" or unit == "arena" then return 5 end
  if unit == "boss" then return 10 end
  return 1
end

local groupModes = {group = true, party = true, raid = true}

-- "PlayersAndPets" or "PetsOnly" when a group trigger includes pets, else nil.
function Display.IncludesPets(trigger)
  if type(trigger) ~= "table" or not trigger.useIncludePets or not groupModes[trigger.unit] then return end
  return trigger.includePets == "PetsOnly" and "PetsOnly" or "PlayersAndPets"
end

local function PetToken(token)
  if token == "player" then return "pet" end
  local kind, index = token:match("^(%a+)(%d+)$")
  if kind == "party" or kind == "raid" then return kind .. "pet" .. index end
end

local function Capacity(trigger, data)
  -- Missing and Always watch exactly one unit token, except on unit frames and
  -- nameplates. (Remaining Time on Icons is validated to single units, which
  -- give 1 below; on other display types it is a list.)
  if Display.ShowOn and Display.ShowOn(trigger) ~= "showOnActive"
    and not (data and Display.UnitPlacedMissing and Display.UnitPlacedMissing(data, trigger)) then return 1 end
  local count = UnitCount(trigger.unit)
  if Display.IncludesPets(trigger) == "PlayersAndPets" then count = count * 2 end
  return count
end

local function MatchesUnitName(trigger, unit)
  if not trigger.useUnitNames then return true end
  local name = Private.ExecEnv.UnitName(unit)
  if issecretvalue(name) or not name then return false end
  name = strlower(name)
  for _, wanted in ipairs(trigger.unitNames or {}) do
    if name == strlower(wanted) then return true end
  end
  return false
end

local function UnitTokens(trigger)
  local unit = trigger.unit
  local result = {}
  if unit == "member" then
    result[1] = Display.SpecificUnit(trigger)
    return result
  end
  if unit == "group" then unit = IsInRaid() and "raid" or "party" end
  if unit == "party" then
    result[1] = "player"
    for i = 1, GetNumSubgroupMembers() do result[#result + 1] = "party" .. i end
  elseif unit == "raid" then
    if IsInRaid() then for i = 1, GetNumGroupMembers() do result[i] = "raid" .. i end end
  elseif unit == "boss" or unit == "arena" or unit == "nameplate" then
    for i = 1, UnitCount(unit) do result[i] = unit .. i end
  else
    result[1] = unit
  end
  if (trigger.useUnitNames or trigger.useUnitRoles) and groupModes[trigger.unit] then
    local filtered = {}
    for _, token in ipairs(result) do
      local role = trigger.useUnitRoles and UnitGroupRolesAssigned(token)
      if MatchesUnitName(trigger, token) and (not trigger.useUnitRoles
        or (not issecretvalue(role) and (trigger.unitRoles or {})[role])) then
        filtered[#filtered + 1] = token
      end
    end
    result = filtered
  end
  local pets = Display.IncludesPets(trigger)
  if pets then
    local withPets = {}
    for _, token in ipairs(result) do
      if pets == "PlayersAndPets" then withPets[#withPets + 1] = token end
      withPets[#withPets + 1] = PetToken(token)
    end
    result = withPets
  end
  return result
end

Display.UnitTokens = UnitTokens

function Display.GetPreviewUnit(data)
  local trigger = Display.GetTrigger(data)
  if not trigger then return "player" end
  for _, unit in ipairs(UnitTokens(trigger)) do
    if UnitExists(unit) and (data.anchorFrameType ~= "UNITFRAME" or WeakAuras.GetUnitFrame(unit)) then return unit end
  end
  return "player"
end

function Display.Validate(data)
  if not Display.Eligible(data) then
    return "Select an Aura (Modern) trigger as the progress source of an Icon, Progress Bar, Progress Texture or Text."
  end
  if data.regionType == "progresstexture" and Private.ProgressTextureNative.IsCircular(data.orientation) and not Enum.StatusBarRenderMode then
    return "This client does not support native circular Progress Textures."
  end
  local appearanceProblem = Display.ValidateAppearance(Display.PrepareConditionAppearance(data))
  if appearanceProblem then return appearanceProblem end
  local trigger = Display.GetTrigger(data, true)
  if Display.UsesSpellIDs(trigger) and #(trigger.auraspellids or {}) == 0 then return "Enter an exact spell ID, or untick Exact Spell IDs to show all matching auras." end
  if Display.UsesRankSpellIDs(trigger) and #(trigger.auraRankSpellIDs or {}) == 0 then return "Enter a spell ID, or untick Spell ID(s) (All Ranks)." end
  if Display.UsesExcludedSpellIDs(trigger) and #(trigger.excludedAuraSpellIDs or {}) == 0 then return "Enter an ignored spell ID, or untick Ignored Exact Spell IDs." end
  if not Display.units[trigger.unit] or (trigger.debuffType ~= "HELPFUL" and trigger.debuffType ~= "HARMFUL") then
    return "Choose a supported unit and Buff or Debuff."
  end
  if trigger.unit == "member" and not Display.SpecificUnit(trigger) then
    return "Enter a Specific Unit such as party1, raid5, boss1 or arena2."
  end
  if trigger.unit == "nameplate" and (not C_NamePlate or not C_NamePlate.GetNamePlateForUnit) then
    return "This client does not expose nameplate frames."
  end
  for _, list in ipairs({trigger.auraspellids or {}, trigger.auraRankSpellIDs or {}, trigger.excludedAuraSpellIDs or {}}) do
    for _, value in ipairs(list) do
      local id = tonumber(value)
      if not id or id <= 0 or id == math.huge or id ~= math.floor(id) then
        return "Each aura spell ID must be a positive whole number."
      end
    end
  end
  for _, field in ipairs(Display.booleanFilters) do
    if trigger[field[1]] ~= nil and type(trigger[field[1]]) ~= "boolean" then return "Invalid aura filter: " .. field[2] end
  end
  for _, field in ipairs(Display.processingOptions) do
    if trigger[field[1]] ~= nil and type(trigger[field[1]]) ~= "boolean" then return "Invalid classification option: " .. field[2] end
  end
  if trigger.maxDuration ~= nil and (type(trigger.maxDuration) ~= "number" or trigger.maxDuration <= 0
    or trigger.maxDuration == math.huge or trigger.maxDuration ~= trigger.maxDuration) then return "Maximum total duration must be a positive number." end
  if trigger.sortMethod and not Display.sortMethods[trigger.sortMethod] then return "Choose a supported sort order." end
  if trigger.sortMethod == "UnitFrameDebuff" and trigger.processedAuraType ~= "Debuff" and trigger.processedAuraType ~= "Dispel" then
    return "Unit-frame debuff sorting requires the Debuff or Dispellable raid debuff classification."
  end
  if trigger.processedAuraType and not Display.processedTypes[trigger.processedAuraType] then return "Choose a supported Blizzard classification." end
  local nativeKeys = {}
  for _, field in ipairs(Display.nativeFilters) do nativeKeys[field[1]] = true end
  for key, value in pairs(trigger.nativeFilters or {}) do
    if not nativeKeys[key] or type(value) ~= "boolean" then return "Choose supported Blizzard aura filters." end
  end
  if AuraUtil and AuraUtil.IsValidFilterString and not AuraUtil.IsValidFilterString(FilterString(trigger)) then
    return "This client does not support the selected Blizzard aura filters."
  end
  for _, field in ipairs({"includeDispelTypes", "excludeDispelTypes"}) do
    for name, value in pairs(trigger[field] or {}) do
      if not Display.dispelTypes[name] or value ~= true then return "Choose supported dispel types." end
    end
  end
  -- Show On and Remaining Time have their own unit and display rules.
  local singleProblem = Display.ValidateSingle(data, trigger)
  if singleProblem then return singleProblem end
  -- A Dynamic Group is allowed, with a warning (DynamicGroupWarning). A
  -- Modern Aura Group has its own rules (SecretAuraFlow.lua).
  local flowProblem = Display.FlowProblem(data, trigger)
  if flowProblem then return flowProblem end
  local conditionProblem = Display.ValidateConditions(data)
  if conditionProblem then return conditionProblem end
  for when, action in pairs(data.actions or {}) do
    if when ~= "init" then
      for key, value in pairs(action) do
        if key:match("^do_") and key ~= "do_sound" and key ~= "do_message" and value then
          return "Secret Aura trigger detected. Only Chat Message, Play Sound and Hide Glows are supported in On Show/On Hide. Custom Init is available."
        end
      end
      if action.stop_sound or (action.do_sound and action.sound == " KitID") then
        return "Secret aura sounds support sound files, not Sound Kit IDs or Stop Sound."
      end
    end
  end
  for _, animation in pairs(data.animation or {}) do
    if animation.type and animation.type ~= "none" then
      return "Secret Aura trigger detected. You cannot use Animations on this aura."
    end
  end
end

local function Restricted()
  return InCombatLockdown() or (C_Secrets and C_Secrets.ShouldAurasBeSecret())
end

function Display.Locked(frame)
  if frame == nil or not frame.GetParent then return false end
  if frame.IsForbidden and frame:IsForbidden() then return true end
  return not pcall(frame.GetParent, frame)
end
-- Locked, or protected in combat (a secure button, or anything it hangs from).
function Display.Busy(frame)
  if Display.Locked(frame) then return true end
  return frame ~= nil and InCombatLockdown() and frame.IsProtected ~= nil and frame:IsProtected()
end
local Locked = Display.Busy

local function Warn(data, message)
  Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_display", message and "warning" or nil, message)
end

local function SoundWarning(data, message)
  Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_sound", message and "warning" or nil, message)
end

function Private.ResolveFojjiRecordedSound(value)
  local db = FojjiCoreDB
  if not FojjiCore or not db then return nil, "FojjiCore is not loaded." end
  if db.disableTTS then return nil, "Speech is disabled in FojjiCore." end
  if db.ttsVoiceType ~= "custom" or db.ttsRandomFavorites then
    return nil, "Select one recorded voice pack in FojjiCore. Recorded sounds cannot use synthesized TTS or random favorites."
  end
  local pack = FojjiCore.voicePacks and FojjiCore.voicePacks[db.ttsVoicePack]
  local file = pack and pack[value]
  if not file then return nil, "No recording for '" .. value .. "' in the selected FojjiCore voice pack." end
  return file
end

local function SoundChannel()
  local channel = FojjiCore and FojjiCoreDB and FojjiCoreDB.ttsSoundChannel
  if channel == "Sound Effects" then channel = "SFX" end
  if channel == "Master" or channel == "SFX" or channel == "Music" or channel == "Ambience" or channel == "Dialog" then return channel end
  return "Master"
end

-- Migrate once; Actions becomes the single source of sound settings.
function Display.MigrateSounds(data)
  local settings = data.blizzardAuraDisplay
  if settings.actionSounds then return end
  data.actions = data.actions or {}
  for _, event in ipairs({"Added", "Removed"}) do
    local when = event == "Added" and "start" or "finish"
    data.actions[when] = data.actions[when] or {}
    local action = data.actions[when]
    local value = settings.soundMode == "file" and (settings["sound" .. event .. "File"] or settings["sound" .. event]) or settings["sound" .. event]
    if not action.do_sound and settings.soundMode and settings.soundMode ~= "none" and value and value ~= "" and value ~= 1 then
      action.do_sound = true
      action.sound_channel = SoundChannel()
      if settings.soundMode == "fojji" then
        action.sound = " Fojji"
        action.sound_fojji = value
      else
        action.sound = " custom"
        action.sound_path = tostring(value)
      end
    end
  end
  settings.soundMode, settings.soundAdded, settings.soundRemoved = nil, nil, nil
  settings.soundAddedFile, settings.soundRemovedFile = nil, nil
  settings.actionSounds = true
end

local function IsPreview()
  return WeakAuras.IsOptionsOpen() and not InCombatLockdown()
end

local function SyncSounds(region)
  if Restricted() then
    pendingSounds[region] = true
    return
  end
  pendingSounds[region] = nil
  local native = region.blizzardAuraDisplay
  if not native then return end
  -- Unchanged units, spells and sound actions: the registrations stand.
  local signature
  local live = native.active and Display.GetTrigger(native.data) ~= nil and region:IsShown() and not IsPreview()
  if live then
    local trigger = Display.GetTrigger(native.data)
    local actions = native.data.actions or {}
    local parts = {}
    for _, key in ipairs({"start", "finish"}) do
      local action = actions[key] or {}
      parts[#parts + 1] = table.concat({tostring(action.do_sound), tostring(action.sound), tostring(action.sound_path),
        tostring(action.sound_fojji), tostring(action.sound_channel)}, ",")
    end
    parts[#parts + 1] = table.concat(UnitTokens(trigger), ",")
    parts[#parts + 1] = table.concat(Display.GetSpellIDs(trigger, true), ",")
    parts[#parts + 1] = table.concat(trigger.excludedAuraSpellIDs or {}, ",")
    signature = table.concat(parts, "|")
    if signature == native.soundSignature then return end
  end
  native.soundSignature = signature
  for _, id in ipairs(native.soundIDs or {}) do C_UnitAuras.RemoveAuraSound(id) end
  native.soundIDs = {}
  local data = native.data
  SoundWarning(data)
  if not live then return end
  local actions = data.actions or {}
  if not ((actions.start or {}).do_sound or (actions.finish or {}).do_sound) then return end
  if not C_UnitAuras or not C_UnitAuras.AddAuraSound or not C_UnitAuras.RemoveAuraSound
    or not Enum.UnitAuraSoundTrigger then
    SoundWarning(data, "This client does not provide native aura sound registration.")
    return
  end
  local trigger = Display.GetTrigger(data)
  local spellIDs = {}
  for _, value in ipairs(Display.GetSpellIDs(trigger, true)) do
    local id = tonumber(value)
    if id and id > 0 and id < math.huge and id == math.floor(id) then spellIDs[id] = true end
  end
  if Display.UsesExcludedSpellIDs(trigger) then
    for _, value in ipairs(trigger.excludedAuraSpellIDs or {}) do
      local id = tonumber(value)
      if id then spellIDs[id] = nil end
    end
  end
  if not next(spellIDs) then
    SoundWarning(data, "Enable Spell ID(s) or Exact Spell ID(s) in Trigger and enter an ID that is not ignored to use aura sounds.")
    return
  end
  local failure
  local units = UnitTokens(trigger)
  for _, event in ipairs({"Added", "Removed"}) do
    local action = actions[event == "Added" and "start" or "finish"] or {}
    if action.do_sound then
      local file, message
      if action.sound == " Fojji" then
        file, message = Private.ResolveFojjiRecordedSound(action.sound_fojji or "")
      elseif action.sound == " custom" then
        file = tonumber(action.sound_path) or action.sound_path
      elseif action.sound ~= " KitID" then
        file = action.sound
      end
      if not file or file == "" or file == 1 then
        file = nil
        message = message or "Choose a sound file in Actions."
      end
      if file then
        for _, unit in ipairs(units) do
          for spellID in pairs(spellIDs) do
            local ok, id = pcall(C_UnitAuras.AddAuraSound, Enum.UnitAuraSoundTrigger[event], {
              unitToken = unit, spellID = spellID,
              soundFileName = type(file) == "string" and file or nil,
              soundFileID = type(file) == "number" and file or nil,
              outputChannel = action.sound_channel or "Master",
            })
            if ok and id then
              native.soundIDs[#native.soundIDs + 1] = id
            else
              failure = "Blizzard could not register the " .. event:lower() .. " sound for spell " .. spellID .. "."
            end
          end
        end
      else
        failure = message
      end
    end
  end
  SoundWarning(data, failure)
end

local function UpdatePreviewNotice(region)
  local data = region.blizzardAuraDisplay and region.blizzardAuraDisplay.data
  local trigger = Display.GetTrigger(data)
  local warning
  -- Same rule as the trigger's status line: only a selection Blizzard always
  -- refuses (not Approximate Match, not never-secret spells) gets the notice.
  if trigger and Display.SpellIDFilterNote(trigger) == "error" then
    warning = "Preview only: these auras will not display in combat with spell ID filters.\nConfigured sounds in Actions can still play."
  end
  if warning then
    if not region.secretAuraPreviewNotice then
      local text = region:CreateFontString(nil, "OVERLAY")
      text:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
      text:SetPoint("TOP", region, "BOTTOM", 0, -6)
      text:SetWidth(300)
      text:SetTextColor(1, 0.8, 0.2)
      region.secretAuraPreviewNotice = text
    end
    region.secretAuraPreviewNotice:SetText(warning)
    region.secretAuraPreviewNotice:Show()
  elseif region.secretAuraPreviewNotice then
    region.secretAuraPreviewNotice:Hide()
  end
end

local function Suppress(region)
  local native = region.blizzardAuraDisplay
  if IsPreview() and not region.secretAuraSamplesActive and not (native and native.previewHasAuras) then
    for frame, alpha in pairs(region.blizzardSuppressed or {}) do frame:SetAlpha(alpha) end
    region.blizzardSuppressed = nil
    UpdatePreviewNotice(region)
    return
  end
  if region.secretAuraPreviewNotice then region.secretAuraPreviewNotice:Hide() end
  region.blizzardSuppressed = region.blizzardSuppressed or {}
  local saved = region.blizzardSuppressed
  for _, key in ipairs({"icon", "cooldown", "button", "bar", "secretBar", "text", "background"}) do
    local frame = region[key]
    if frame and frame.SetAlpha then
      if saved[frame] == nil then saved[frame] = frame:GetAlpha() end
      frame:SetAlpha(0)
    end
  end
  -- Progress Texture stores drawable textures inside its geometry wrappers.
  if region.regionType == "progresstexture" then
    local function SuppressTexture(texture)
      if saved[texture] == nil then saved[texture] = texture:GetAlpha() end
      texture:SetAlpha(0)
    end
    SuppressTexture(region.foreground.texture)
    SuppressTexture(region.background.texture)
    for _, spinner in ipairs({region.foregroundSpinner, region.backgroundSpinner}) do
      for _, texture in ipairs(spinner.textures) do SuppressTexture(texture) end
    end
    for _, texture in ipairs(region.extraTextures) do SuppressTexture(texture.texture) end
    for _, spinner in ipairs(region.extraSpinners) do
      for _, texture in ipairs(spinner.textures) do SuppressTexture(texture) end
    end
    if region.nativeProgress then SuppressTexture(region.nativeProgress.bar) end
  end
  -- AuraBar stores its background on bar, but parents the texture to the region.
  local background = region.bar and region.bar.bg
  if background then
    if saved[background] == nil then saved[background] = background:GetAlpha() end
    background:SetAlpha(0)
  end
  for _, frame in ipairs(region.subRegions or {}) do
    if frame.SetAlpha and not frame.secretAuraDetached then
      if saved[frame] == nil then saved[frame] = frame:GetAlpha() end
      frame:SetAlpha(0)
    end
  end
end

function Display.Restore(region)
  -- Pooled samples must never survive release or a trigger switch.
  if Display.HidePreview then Display.HidePreview(region) end
  if Display.RestorePreviewRegion then Display.RestorePreviewRegion(region) end
  if region.secretAuraPreviewNotice then region.secretAuraPreviewNotice:Hide() end
  region.secretAuraConditionValues = nil
  for frame, alpha in pairs(region.blizzardSuppressed or {}) do frame:SetAlpha(alpha) end
  region.blizzardSuppressed = nil
  if region.blizzardOriginalUpdate then
    region.Update = region.blizzardOriginalUpdate.func
    region.blizzardOriginalUpdate = nil
  end
  if region.blizzardOriginalPreShow then
    region.PreShow = region.blizzardOriginalPreShow.func
    region.blizzardOriginalPreShow = nil
  end
end

function Display.HideUnitGlows(region)
  local native = region.blizzardAuraDisplay
  if not native then return end
  native.unitGlowsHidden = true
  for _, instance in ipairs(native.instances) do
    if instance.unitGlow and not Locked(instance.unitGlow.container) then
      instance.unitGlow.container:SetEnabled(false)
      instance.unitGlow.container:Hide()
    end
  end
end

function Display.Release(region)
  Display.ReleaseAuraLearning(region)
  Display.HideUnitGlows(region)
  Display.Restore(region)
  pending[region] = nil
  if Display.CancelEditorApply then Display.CancelEditorApply(region) end
  local native = region.blizzardAuraDisplay
  if native then
    native.active = false
    native.instanceQueue = nil
    for _, instance in ipairs(native.instances) do
      if Locked(instance.container) then
        lockedHide[region] = true
      else
        instance.container:SetEnabled(false)
        instance.container:Hide()
      end
      Display.RefreshSingle(instance, nil, false)
    end
    -- A released display draws nothing, so no Missing or Remaining Time part can be failing.
    Private.AuraWarnings.UpdateWarning(native.data.uid, "blizzard_aura_single", nil)
    Private.AuraWarnings.UpdateWarning(native.data.uid, "blizzard_aura_dynamicgroup", nil)
    activeRegions[region] = nil
    SyncSounds(region)
    -- The next display in a Modern Aura Group starts where this one did.
    Display.RechainFlow(Display.FlowGroup(native.data))
    Display.RefreshGridFor(region)
  end
end

local function StyleText(text, native, settings, key, size, anchor, x, y)
  local button = native.button
  local font = settings[key .. "Font"]
  local outline = settings[key .. "Outline"]
  -- Native aura bindings and their previews must inherit shadows just like subtext.
  Private.ApplyTextFont(text, nil, font and SharedMedia:Fetch("font", font) or "Fonts\\ARIALN.TTF",
    settings[key .. "Size"] or size, (outline == "None" and "" or outline) or "OUTLINE",
    settings[key .. "ShadowColor"] or {0, 0, 0, 0}, settings[key .. "ShadowX"] or 1, settings[key .. "ShadowY"] or -1)
  text:SetTextColor(unpack(settings[key .. "Color"] or {1, 1, 1, 1}))
  local point = settings[key .. "Anchor"] or anchor
  -- Preserve the original same-point anchors until a self point is chosen.
  local selfPoint = settings[key .. "SelfPoint"]
  local target = button
  local area = point:sub(1, 6)
  if area == "INNER_" or area == "OUTER_" then
    target = area == "INNER_" and native.inner or native.outer
    point = point:sub(7)
  end
  selfPoint = selfPoint or ((area == "INNER_" or area == "OUTER_") and "AUTO" or point)
  if selfPoint == "AUTO" then
    selfPoint = area == "INNER_" and point or area == "OUTER_" and Private.inverse_point_types[point] or "CENTER"
  end
  text:ClearAllPoints()
  text:SetPoint(selfPoint, target, point, settings[key .. "X"] or x, settings[key .. "Y"] or y)
  text:SetJustifyH(settings[key .. "Justify"] or "CENTER")
end

local function CreateGlow(native, unitGlow)
  local glow = {}
  for _, kind in ipairs({"proc", "pulse"}) do
    local texture = (unitGlow and native.overlay or ElementFrame(native, "glow")):CreateTexture(nil, "OVERLAY", nil, -1)
    texture:SetBlendMode("ADD")
    texture:SetDesaturated(true)
    texture:Hide()
    local group = texture:CreateAnimationGroup()
    group:SetLooping("REPEAT")
    group:SetToFinalAlpha(true)
    local entry = {texture = texture, group = group, animations = {}}
    glow[kind] = entry
    if kind == "proc" then
      texture:SetAtlas("UI-HUD-ActionBar-Proc-Loop-Flipbook")
      -- Keep the atlas hidden unless the native animation supplies its opacity.
      local opacity = group:CreateAnimation("Alpha")
      opacity:SetTarget(texture)
      opacity:SetOrder(1)
      opacity:SetFromAlpha(1)
      opacity:SetToAlpha(1)
      opacity:SetDuration(0.001)
      local animation = group:CreateAnimation("FlipBook")
      animation:SetTarget(texture)
      animation:SetOrder(1)
      animation:SetFlipBookRows(6)
      animation:SetFlipBookColumns(5)
      animation:SetFlipBookFrames(30)
      animation:SetFlipBookFrameWidth(0)
      animation:SetFlipBookFrameHeight(0)
      entry.animations[1] = animation
    else
      texture:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
      texture:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
      for index = 1, 2 do
        local animation = group:CreateAnimation("Alpha")
        animation:SetTarget(texture)
        animation:SetOrder(index)
        animation:SetFromAlpha(index == 1 and 0.25 or 1)
        animation:SetToAlpha(index == 1 and 1 or 0.25)
        entry.animations[index] = animation
      end
    end
  end
  native.glow = glow
  return glow
end

local function StyleGlow(native, data, unitGlow)
  local settings = data.blizzardAuraDisplay
  if unitGlow then
    settings = {
      glow = settings.unitGlow, glowType = settings.unitGlowType, glowColor = settings.unitGlowColor,
      glowDuration = settings.unitGlowDuration, glowX = settings.unitGlowX, glowY = settings.unitGlowY, useGlowColor = settings.unitUseGlowColor,
      padding = settings.unitGlowPadding or 0,
    }
  end
  local glow = native.glow
  if not glow and not settings.glow then return end
  glow = glow or CreateGlow(native, unitGlow)
  if glow.registered then
    native.button:RemoveAuraShownAnimation(glow.registered)
    glow.registered = nil
  end
  for _, kind in ipairs({"proc", "pulse"}) do
    glow[kind].group:Stop()
    glow[kind].texture:Hide()
  end
  if not settings.glow then return end
  local entry = glow[settings.glowType or "proc"] or glow.proc
  local scale = math.max(0.5, settings.glowScale or 1)
  local duration = math.max(0.1, settings.glowDuration or 1)
  entry.texture:ClearAllPoints()
  if unitGlow then
    entry.texture:SetPoint("TOPLEFT", native.button, "TOPLEFT", (settings.glowX or 0) - settings.padding, (settings.glowY or 0) + settings.padding)
    entry.texture:SetPoint("BOTTOMRIGHT", native.button, "BOTTOMRIGHT", (settings.glowX or 0) + settings.padding, (settings.glowY or 0) - settings.padding)
  else
    entry.texture:SetPoint("CENTER", native.glowAnchor or native.button, "CENTER", settings.glowX or 0, settings.glowY or 0)
    entry.texture:SetSize(math.max(4, native.glowWidth or data.width or data.fixedWidth or 200) * 1.4 * scale, math.max(4, native.glowHeight or data.height or data.fontSize or 18) * 1.4 * scale)
  end
  entry.texture:SetVertexColor(unpack(settings.useGlowColor ~= false and settings.glowColor or {1, 0.82, 0, 1}))
  entry.texture:SetAlpha(entry == glow.pulse and 0.25 or 0)
  for _, animation in ipairs(entry.animations) do animation:SetDuration(duration / #entry.animations) end
  entry.texture:Show()
  -- Blizzard owns animation playback as secret aura visibility changes.
  native.button:AddAuraShownAnimation(entry.group)
  glow.registered = entry.group

end

local function Style(native, data, region)
  Display.StyleAppearance(native, Display.PrepareConditionAppearance(data), ElementFrame, StyleText, StyleGlow)
  Display.ApplyConditionAppearance(native, region, data)
  if Display.StyleEraser then Display.StyleEraser(native, data) end
end

local function SpellIDMap(values)
  local ids = {}
  for _, value in ipairs(values or {}) do ids[tonumber(value)] = true end
  return next(ids) and ids or nil
end

local function RawCandidateFilters(data)
  local trigger = Display.GetTrigger(data)
  -- Total Duration: "<=" is Blizzard's own limit; "=" also narrows the
  -- candidates before the gate (StyleDurationGate) picks the exact one.
  local totalOp, total = Display.TotalFilter(trigger)
  local filters = {maxDuration = totalOp == "<=" and total + 0.05 or totalOp == "=" and total + 0.5 or nil}
  -- Rank and exact selections form one union; ignored exact IDs still win.
  if Display.UsesSpellIDs(trigger) or Display.UsesRankSpellIDs(trigger) then
    filters.includeSpellIDs = SpellIDMap(Display.GetSpellIDs(trigger, true)) or {}
  end
  if Display.UsesExcludedSpellIDs(trigger) then filters.excludeSpellIDs = SpellIDMap(trigger.excludedAuraSpellIDs) end
  for _, field in ipairs(Display.booleanFilters) do
    if Display.FilterApplies(field[1], trigger) and (not IsNameplateFilter(field[1]) or trigger.unit == "nameplate") then filters[field[1]] = trigger[field[1]] end
  end
  for _, field in ipairs({"includeDispelTypes", "excludeDispelTypes"}) do
    if next(trigger[field] or {}) then
      filters[field] = {}
      for name, value in pairs(trigger[field]) do filters[field][name] = value end
    end
  end
  -- Approximate Match swaps spell IDs for learned properties (SecretAuraSingle.lua).
  return Display.ApproximateFilters(trigger, filters)
end
Display.RawCandidateFilters = RawCandidateFilters

local function CandidateFilters(data)
  return Display.MergedCandidateFilters and Display.MergedCandidateFilters(data) or RawCandidateFilters(data)
end

-- The editor always renders public samples; live containers remain disabled.
-- Samples depend only on the settings, which Apply restyles; unit and roster
-- changes keep samples already drawn for the same settings.
local function RefreshPreview(region)
  local native = region.blizzardAuraDisplay
  native.previewHasAuras = IsPreview()
  if native.previewHasAuras then
    if not (region.secretAuraSamplesActive and native.previewStyled == native.data) then
      Display.ShowPreview(region, native.data, function(sample, data)
        Display.StyleAppearance(sample, Display.PrepareConditionAppearance(data), ElementFrame, StyleText, StyleGlow)
      end)
      native.previewStyled = native.data
    end
    -- In a Modern Aura Group the samples line up like the live auras.
    Display.ArrangeFlowPreview(Display.FlowGroup(native.data))
  else
    -- The editor's boxes go back to their own places.
    Display.RestorePreviewRegion(region)
    Display.RestoreGroupPreview(Display.FlowGroup(native.data))
    Display.HidePreview(region)
  end
  Suppress(region)
  if IsPreview() then UpdatePreviewNotice(region) end
end

local function ConfigureProcessing(container, trigger)
  container:SetAuraProcessingPolicy(CustomAuraContainerAuraProcessingPolicy.None)
end

local function ConfigureUnitGlow(instance, region, data)
  local native = instance.unitGlow
  if data.anchorFrameType ~= "UNITFRAME" or not data.blizzardAuraDisplay.unitGlow then
    if native then native.container:SetEnabled(false); native.container:Hide() end
    return
  end
  local trigger = Display.GetTrigger(data)
  if not native then
    native = {container = CreateFrame("AuraContainer", nil, region, "CustomAuraContainerTemplate")}
    instance.unitGlow = native
    native.container:SetEnabled(false)
    ConfigureProcessing(native.container, trigger)
    native.container:AddAuraSlot("UnitGlow", FilterString(trigger), {
      candidateFilters = CandidateFilters(data),
      initializeFrame = function(button)
        native.button = button
        button:SetFrameLevel(native.container:GetFrameLevel() + 1)
        button:SetAllPoints(native.container)
        button:EnableMouse(false)
        native.overlay = CreateFrame("Frame", nil, button)
        native.overlay:SetAllPoints(button)
        native.overlay:SetFrameLevel(native.container:GetFrameLevel() + 2)
        StyleGlow(native, data, true)
      end,
    })
  else
    native.container:SetEnabled(false)
    StyleGlow(native, data, true)
  end
  ConfigureProcessing(native.container, trigger)
  native.container:SetAuraSlotSortMethod("UnitGlow", Display.SortOrder(data, trigger))
  native.container:SetAuraSlotFilterString("UnitGlow", FilterString(trigger))
  native.container:SetAuraSlotCandidateFilters("UnitGlow", CandidateFilters(data))
end

local function CompactUnits(data)
  -- In a Modern Aura Group on the screen, units are always chained.
  if Display.FlowGroup(data) and not Display.FlowFrameMode(data) then return Capacity(Display.GetTrigger(data), data) > 1 end
  return data.anchorFrameType ~= "UNITFRAME" and not Display.UsesNameplates(data)
    and Capacity(Display.GetTrigger(data), data) > 1
end

function Display.IconsPerRow(data)
  if Display.FlowGroup(data) or Display.DrawsOne(data) or Display.UsesGate(data) or CompactUnits(data) then return end
  local count = tonumber(data.blizzardAuraDisplay and data.blizzardAuraDisplay.perRow)
  if count and count >= 1 then return math.floor(count) end
end

-- direction: RIGHT, LEFT, UP, DOWN, CENTER_HORIZONTAL or CENTER_VERTICAL.
-- rows: where new rows go (UP or DOWN for rows, LEFT or RIGHT for columns).
-- Returns the corner the flow starts from, the point that places the
-- container, and the horizontal and vertical directions.
function Display.WrapLayout(direction, rows)
  local vertical = direction == "UP" or direction == "DOWN" or direction == "CENTER_VERTICAL"
  local horizontal, verticalDirection
  if vertical then
    horizontal = rows == "LEFT" and "LEFT" or "RIGHT"
    verticalDirection = direction == "UP" and "UP" or "DOWN"
  else
    horizontal = direction == "LEFT" and "LEFT" or "RIGHT"
    verticalDirection = rows == "UP" and "UP" or "DOWN"
  end
  local corner = (verticalDirection == "UP" and "BOTTOM" or "TOP") .. (horizontal == "LEFT" and "RIGHT" or "LEFT")
  local point = corner
  if direction == "CENTER_HORIZONTAL" then point = verticalDirection == "UP" and "BOTTOM" or "TOP"
  elseif direction == "CENTER_VERTICAL" then point = horizontal == "LEFT" and "RIGHT" or "LEFT" end
  return corner, point, horizontal, verticalDirection, vertical
end

function Display.ApplyFlowWrap(container, corner, horizontal, verticalDirection, vertical, perRow, width, height, spacing)
  container:SetFlowLayoutAxis(vertical and AnchorUtil.FlowLayoutAxis.Vertical or AnchorUtil.FlowLayoutAxis.Horizontal)
  container:SetFlowLayoutAnchorPoint(corner)
  container:SetFlowLayoutGrowthDirection(horizontal == "LEFT" and AnchorUtil.FlowDirection.Left or AnchorUtil.FlowDirection.Right,
    verticalDirection == "UP" and AnchorUtil.FlowDirection.Up or AnchorUtil.FlowDirection.Down)
  local size = vertical and height or width
  if container.SetFlowLayoutMaximumLineSize then
    container:SetFlowLayoutMaximumLineSize(perRow and perRow * size + (perRow - 1) * spacing + 0.5 or nil)
  end
end

local function ApplyWrap(container, direction, rows, perRow, width, height, spacing)
  local corner, _, horizontal, verticalDirection, vertical = Display.WrapLayout(direction, rows)
  Display.ApplyFlowWrap(container, corner, horizontal, verticalDirection, vertical, perRow, width, height, spacing)
end
Display.ApplyWrap = ApplyWrap

local function AnchorWrappedList(container, region, data)
  local settings = data.blizzardAuraDisplay
  local _, point = Display.WrapLayout(Display.Growth(data), settings.rowGrowth)
  container:ClearAllPoints()
  container:SetPoint(point, region, point)
end

local function Layout(native, region, data)
  local width, height = Display.Dimensions(data)
  local settings = data.blizzardAuraDisplay
  -- The single-aura drawing pins the one slot to the region's top-left corner.
  local direction = Display.Growth(data)
  local vertical = direction == "UP" or direction == "DOWN" or direction == "CENTER_VERTICAL"
  local anchor = direction == "LEFT" and "TOPRIGHT" or direction == "UP" and "BOTTOMLEFT" or "TOPLEFT"
  local container = native.container
  local perRow = Display.IconsPerRow(data)
  if perRow then
    local spacing = settings.spacing or 6
    AnchorWrappedList(container, region, data)
    ApplyWrap(container, direction, settings.rowGrowth, perRow, width, height, spacing)
    container:SetAuraGroupLayout("Auras", {elementWidth = width, elementHeight = height, elementSpacing = spacing, lineSpacing = spacing})
    container:SetAuraGroupMaxFrameCount("Auras", Display.MaxAuras(data))
    return
  end
  if container.SetFlowLayoutMaximumLineSize then container:SetFlowLayoutMaximumLineSize(nil) end
  container:ClearAllPoints()
  local centered = direction == "CENTER_HORIZONTAL" or direction == "CENTER_VERTICAL"
  -- In a Modern Aura Group the content starts where the previous display ends.
  if centered then container:SetPoint("CENTER", region, "CENTER")
  else Display.AnchorToContent(container, anchor, region, anchor) end
  -- An aura slot's button is placed here, where the group's one button would
  -- be laid out; a slot has no group layout or count to set.
  if native.slotMain then
    for _, entry in ipairs(native.buttons) do
      local button = entry.button
      if not pcall(function()
        button:SetSize(width, height)
        button:ClearAllPoints()
        if centered then button:SetPoint("CENTER", region, "CENTER")
        else button:SetPoint(anchor, Display.ContentAnchor(region), anchor) end
      end) then
        -- Access denied (restricted): placed again by the next Apply.
        native.slotLayoutPending = true
      end
    end
    return
  end
  container:SetFlowLayoutAxis(vertical and AnchorUtil.FlowLayoutAxis.Vertical or AnchorUtil.FlowLayoutAxis.Horizontal)
  container:SetFlowLayoutAnchorPoint(anchor)
  container:SetFlowLayoutGrowthDirection(direction == "LEFT" and AnchorUtil.FlowDirection.Left or AnchorUtil.FlowDirection.Right,
    direction == "UP" and AnchorUtil.FlowDirection.Up or AnchorUtil.FlowDirection.Down)
  local _, flowSpacing = Display.FlowGrowth(data)
  local spacing = flowSpacing or settings.spacing or 6
  -- A Modern Aura Group measures a list by its container, so it uses the compact
  -- layout whose width is exactly the icons shown.
  -- Only an Aura(s) Found list without a gate or Remaining Time is measured that way;
  -- a fixed icon keeps slots of exactly its size.
  local trigger = Display.GetTrigger(data)
  local measured = trigger and Display.ShowOn(trigger) == "showOnActive" and not Display.UsesGate(data)
    and not (Display.RemainingRange and Display.RemainingRange(trigger))
  local compact = not centered and (CompactUnits(data) or flowSpacing ~= nil and measured)
  -- The Total Duration and Stack Count gates stack every candidate on the same
  -- spot: only the one that passes is drawn, so the others must not take space.
  if Display.UsesGate(data) then spacing = -(vertical and height or width) end
  -- Empty native containers are one pixel wide/high. Reserve that pixel after
  -- occupied content too, then subtract it in the anchor chain, without reading sizes.
  container:SetAuraGroupLayout("Auras", {
    elementWidth = width + (compact and not vertical and spacing + 1 or 0),
    elementHeight = height + (compact and vertical and spacing + 1 or 0),
    elementSpacing = compact and -1 or spacing,
  })
  container:SetAuraGroupMaxFrameCount("Auras", Display.MaxAuras(data))
end

local function BuildButton(container, button)
  local native = {container = container}
  native.button = button
  button:EnableMouse(false)
  -- Gate clip (Total Duration, Remaining Time, Stack Count): created before
  -- any element on every display type (StyleDurationGate). It does not
  -- clip while no gate is used.
  native.gateClip = CreateFrame("Frame", nil, button, "DisableUntrustedLayoutScriptsTemplate")
  Display.ClipChildren(native.gateClip)
  native.gateClip:SetAllPoints(button)
  native.gateText = button:CreateFontString(nil, "BACKGROUND")
  for _, area in ipairs({"inner", "outer"}) do
    native[area] = CreateFrame("Frame", nil, button)
    native[area]:SetPoint("CENTER", button, "CENTER")
    native[area]:EnableMouse(false)
  end
  native.border = (native.gateClip or button):CreateTexture(nil, "BACKGROUND")
  native.border:SetAllPoints(button)
  -- Eraser for the Missing look (SecretAuraSingle.lua, Display.StyleEraser):
  -- drawn with blending disabled inside a frame buffer, it overwrites what is
  -- beneath the button with nothing while the button is shown. On the button
  -- itself, outside the gate clip, so it can reach past the icon.
  native.eraser = button:CreateTexture(nil, "BACKGROUND", nil, -8)
  native.eraser:SetColorTexture(0, 0, 0, 0)
  native.eraser:SetBlendMode("DISABLE")
  native.eraser:Hide()
  local base = ElementFrame(native, "sharedBase")
  native.icon = base:CreateTexture(nil, "ARTWORK")
  -- Placed like the icons of other displays (not rounded to whole pixels), so rows line up.
  native.icon:SetSnapToPixelGrid(false)
  native.icon:SetTexelSnappingBias(0)
  button:SetIcon(native.icon)
  native.cooldown = CreateFrame("Cooldown", nil, base, "CooldownFrameTemplate")
  native.cooldown:SetAllPoints(native.icon)
  native.cooldown:SetDrawBling(false)
  native.cooldown:SetHideCountdownNumbers(true)
  button:SetDurationCooldown(native.cooldown)
  local overlay = CreateFrame("Frame", nil, native.gateClip or button)
  native.overlay = overlay
  overlay:SetAllPoints(button)
  overlay:SetFrameLevel(native.cooldown:GetFrameLevel() + 1)
  return native
end
Display.BuildNativeButton = BuildButton

-- A display that draws one aura (DrawsOne: Always, Missing, Remaining Time
-- on an icon, or a list limited to one) gets an aura slot instead of an aura
-- group: a group is built as a batch of buttons the client sizes and lays
-- out, a slot is one button placed by this file (Layout), so the container
-- is cheaper to build and to re-read. Lists, gated displays (which stack
-- candidates) and Modern Aura Group containers keep the group.
local function WantsSlot(data, inFlow, container)
  return not inFlow and container.AddAuraSlot ~= nil and Display.MaxAuras(data) == 1
end
Display.WantsSlot = WantsSlot

local function Create(region, data)
  local display = {buttons = {}, data = data}
  local container, inFlow = Display.CreateAuraContainer(region, data)
  display.container = container
  -- Made for a Modern Aura Group (SecretAuraFlow.lua); Apply replaces it on a change.
  display.flowContainer = inFlow
  container:SetEnabled(false)
  local trigger = Display.GetTrigger(data)
  ConfigureProcessing(container, trigger)
  container:SetPoint("TOPLEFT", region, "TOPLEFT")
  local function initializeFrame(button)
    local native = BuildButton(container, button)
    Style(native, display.data, region)
    display.buttons[#display.buttons + 1] = native
  end
  if WantsSlot(data, inFlow, container) then
    local ok = pcall(container.AddAuraSlot, container, "Auras", FilterString(trigger), {
      candidateFilters = CandidateFilters(data),
      sortMethod = Display.SortOrder(data, trigger),
      initializeFrame = initializeFrame,
    })
    if ok and display.buttons[1] then
      display.slotMain = true
      return display
    end
    -- The client refused the slot: the group below draws instead.
    wipe(display.buttons)
  end
  display.slotMain = false
  container:AddAuraGroup("Auras", FilterString(trigger), {
    maxFrameCount = Display.MaxAuras(data),
    candidateFilters = CandidateFilters(data),
    initializeFrame = initializeFrame,
  })
  return display
end

-- Frames cannot be destroyed. Ones no longer used are hidden under a hidden
-- holder, outside every display's frame tree.
local retiredHolder
function Display.RetireFrame(frame)
  if not frame then return end
  retiredHolder = retiredHolder or CreateFrame("Frame")
  retiredHolder:Hide()
  if frame.SetEnabled then frame:SetEnabled(false) end
  frame:Hide()
  frame:ClearAllPoints()
  frame:SetParent(retiredHolder)
end

-- True when a frame's current strata or level differs from the wanted one.
-- Containers made for a Modern Aura Group report secret values; those are
-- always set, as they cannot be compared.
local function Changed(current, wanted)
  return issecretvalue(current) or current ~= wanted
end

-- Like Changed, for a native container whose strata or level this file sets.
-- A secret current value is compared with the value last set here (stored on
-- the instance under key), so a Modern Aura Group container is not re-layered,
-- walking all of its buttons, on every refresh. The stored values are cleared
-- whenever the container changes parent, which resets its layering.
local function LayerChanged(instance, key, current, wanted)
  if issecretvalue(current) then return instance[key] ~= wanted end
  return current ~= wanted
end

local unitFrameGlowSizes = setmetatable({}, {__mode = "k"})

local function AnchorUnitGlow(container, frame)
  local size = unitFrameGlowSizes[frame]
  if not size then
    size = {x = 0, y = 0}
    unitFrameGlowSizes[frame] = size
    TimedHookScript(frame, "OnSizeChanged", function() Display.UnitFramesChanged() end)
  end
  local width, height = frame:GetSize()
  if not issecretvalue(width) and not issecretvalue(height) then
    -- Proc artwork has a transparent inset. Use fixed layout margins, not a
    -- looping Scale animation. Keep the last public margins if layout is secret.
    size.x, size.y = width * 0.2, height * 0.2
  end
  container:SetPoint("TOPLEFT", frame, "TOPLEFT", -size.x, size.y)
  container:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", size.x, -size.y)
end

function Display.UpdateDetachedFrameLevels(region)
  local native = region.blizzardAuraDisplay
  if not native or not native.active then return end
  local level = region:GetFrameLevel()
  for _, instance in ipairs(native.instances) do
    -- A Modern Aura Group's containers may report a secret level; they sit
    -- just above the region, which the reserve below covers.
    if not Locked(instance.container) then
      local containerLevel = instance.container:GetFrameLevel()
      if not issecretvalue(containerLevel) then level = math.max(level, containerLevel) end
    end
  end
  -- Reserve the native button, three levels per element, and glow/cooldown children.
  -- Only container frames are inspected; native aura buttons may be inaccessible.
  level = level + #(native.data.subRegions or {}) * 3 + 8
  for index, element in ipairs(region.subRegions or {}) do
    if element.secretAuraDetached and not Locked(element) then element:SetFrameLevel(level + index) end
  end
end

-- Ignore Dead / Ignore Disconnected: that unit's part of the display is hidden.
local function UnitIgnored(trigger, unit)
  if not unit or not trigger then return false end
  if trigger.ignoreDisconnected then
    local ok, connected = pcall(UnitIsConnected, unit)
    if ok and not issecretvalue(connected) and connected == false then return true end
  end
  if trigger.ignoreDead then
    local ok, dead = pcall(UnitIsDeadOrGhost, unit)
    if ok and not issecretvalue(dead) and dead == true then return true end
  end
  return false
end

local function ApplyUnitStatus(instance, trigger)
  local hidden = UnitIgnored(trigger, instance.visible and instance.boundUnit)
  instance.statusHidden = hidden or nil
  if not Locked(instance.container) then instance.container:SetAlpha(hidden and 0 or instance.baseAlpha or 1) end
end

-- unitChanged: the event that asked for this refresh can have changed which
-- unit a token stands for (a new target, focus, mouseover, pet or group
-- member). The Missing look and the group shadow are refreshed on it; the
-- aura slot is not (see below).
local function RefreshUnits(region, removedUnit, changedUnit, unitChanged)
  local native = region.blizzardAuraDisplay
  if not native or not native.active then return end
  if native.instanceQueue and not IsPreview() and Display.FlushInstanceQueue then Display.FlushInstanceQueue(region) end
  local data = native.data
  local trigger = Display.GetTrigger(data)
  -- No Aura (Modern) trigger drives the display right now: nothing to bind.
  if not trigger then return end
  local settings = data.blizzardAuraDisplay
  local units = UnitTokens(trigger)
  local growth = Display.Growth(data)
  local vertical = growth == "UP" or growth == "DOWN" or growth == "CENTER_VERTICAL"
  -- A Modern Aura Group grouped by frame places these on unit frames or
  -- nameplates itself (RelinkFlowUnits, below).
  local frameMode = Display.FlowFrameMode(data)
  for index, instance in ipairs(native.instances) do
    local container = instance.container
    local unit = units[index]
    if Locked(container) then
      lockedUnits[region] = true
    elseif not changedUnit or unit == changedUnit then
      -- In a Modern Aura Group the group's mode decides (screen, unit frames or
      -- nameplates); the display's own anchor is not used for its auras.
      local unitFrames, nameplates
      if Display.FlowGroup(data) then
        unitFrames, nameplates = frameMode == "UNITFRAME", frameMode == "NAMEPLATE"
      else
        unitFrames = data.anchorFrameType == "UNITFRAME"
        nameplates = not unitFrames and Display.UsesNameplates(data)
      end
      local anchorFrame
      if unit then
        if unitFrames then
          anchorFrame = WeakAuras.GetUnitFrame(unit)
        elseif nameplates and unit ~= removedUnit then
          anchorFrame = C_NamePlate.GetNamePlateForUnit(unit)
        end
      end
      if anchorFrame and anchorFrame:IsForbidden() then anchorFrame = nil end
      -- Live aura visibility must not affect the editor samples.
      local shown = not IsPreview() and unit ~= nil and region:IsShown() and (not (unitFrames or nameplates) or anchorFrame ~= nil)
        and not native.gridMember
      -- An erased Missing look (SecretAuraSingle.lua) draws the aura slot and
      -- the Missing look in one frame buffer: the slot's parent is that stage.
      local parent = unitFrames and data.anchorFrameParent ~= false and anchorFrame
        or (Display.MissingStage and Display.MissingStage(instance)) or region
      -- Nothing about the container's content changes when it keeps its unit,
      -- parent, enabled state and visibility, and no nameplate was reassigned
      -- (removedUnit/changedUnit): Blizzard keeps a live container current from
      -- UNIT_AURA itself, so the enable and full refresh below are skipped then.
      -- The same holds for its anchors: they are set again only when the frame
      -- they hang from changed (unit frames and nameplates come and go).
      -- unitChanged alone does not force this refresh: enabling and refreshing
      -- every aura slot on each target change was a visible stutter; a kept
      -- token's slot is re-read in place instead (below).
      local unchanged = instance.boundUnit == unit and container:GetParent() == parent
        and container.faEnabled == true and instance.visible == true and not removedUnit and not changedUnit
      local reanchor = not unchanged or instance.anchoredTo ~= (anchorFrame or region) or not instance.anchored
      instance.anchoredTo, instance.anchored = anchorFrame or region, true
      -- Disabling clears native aura assignments and restarts their animations.
      if instance.boundUnit ~= unit or container:GetParent() ~= parent then
        container:SetEnabled(false)
        if unit then container:SetUnit(unit); Private.HitchCount("container SetUnit") end
        instance.boundUnit = unit
        if container:GetParent() ~= parent then
          container:SetParent(parent)
          Private.HitchCount("container SetParent")
          instance.appliedStrata, instance.appliedLevel = nil, nil
        end
      end
      instance.baseAlpha = parent == region and 1 or data.alpha or 1
      -- Strata and level are set only when they change: each change walks
      -- every button of the container.
      local strata = (data.frameStrata == nil or data.frameStrata == 1) and parent:GetFrameStrata() or region:GetFrameStrata()
      if LayerChanged(instance, "appliedStrata", container:GetFrameStrata(), strata) then
        container:SetFrameStrata(strata)
        Private.HitchCount("container SetFrameStrata")
        instance.appliedStrata = strata
      end
      -- Kept for the Missing look: containers in a Modern Aura Group report secret levels.
      instance.drawStrata, instance.drawLevel = strata, nil
      if unitFrames then
        -- Keep native aura content above the unit glow and its two child layers.
        local level = anchorFrame and settings.unitGlow and anchorFrame:GetFrameLevel() + unitGlowFrameLevel + 3 or parent:GetFrameLevel() + 1
        if LayerChanged(instance, "appliedLevel", container:GetFrameLevel(), level) then
          container:SetFrameLevel(level)
          instance.appliedLevel = level
        end
        instance.drawLevel = level
        if not frameMode and reanchor then
          container:ClearAllPoints()
          container:SetPoint(data.selfPoint or "CENTER", anchorFrame or region, data.anchorPoint or "CENTER", data.xOffset or 0, data.yOffset or 0)
        end
      elseif frameMode then
        -- Placed by RelinkFlowUnits.
      elseif not reanchor then
        -- Same anchor frame as before: the points stand.
      elseif nameplates then
        container:ClearAllPoints()
        if data.anchorFrameType == "NAMEPLATE" then
          -- Anchored to nameplates: the display's Position and Size settings.
          container:SetPoint(data.selfPoint or "BOTTOM", anchorFrame or region, data.anchorPoint or "TOP", data.xOffset or 0, data.yOffset or 0)
        else
          -- Nameplate unit on a screen anchor: above the plate (older auras
          -- may still carry their own offsets).
          container:SetPoint("BOTTOM", anchorFrame or region, "TOP", settings.nameplateX or 0, settings.nameplateY or 8)
        end
      else
        local direction = growth
        local anchor = direction == "LEFT" and "TOPRIGHT" or direction == "UP" and "BOTTOMLEFT" or "TOPLEFT"
        container:ClearAllPoints()
        if Display.IconsPerRow(data) then
          AnchorWrappedList(container, region, data)
        elseif direction == "CENTER_HORIZONTAL" or direction == "CENTER_VERTICAL" then
          container:SetPoint("CENTER", region, "CENTER")
        elseif CompactUnits(data) and index > 1 then
          local previous = native.instances[index - 1].container
          local edge = direction == "LEFT" and "TOPLEFT" or direction == "UP" and "TOPLEFT"
            or direction == "DOWN" and "BOTTOMLEFT" or "TOPRIGHT"
          container:SetPoint(anchor, previous, edge,
            vertical and 0 or (direction == "LEFT" and 1 or -1),
            vertical and (direction == "UP" and -1 or 1) or 0)
        else
          -- In a Modern Aura Group the content starts where the previous display ends.
          Display.AnchorToContent(container, anchor, region, anchor)
        end
      end
      if instance.missingSlot and reanchor then
        local slotPoint
        if frameMode then slotPoint = Display.FlowUnitStart(Display.FlowGroup(data))
        elseif unitFrames then slotPoint = data.selfPoint or "CENTER"
        elseif nameplates then slotPoint = data.anchorFrameType == "NAMEPLATE" and (data.selfPoint or "BOTTOM") or "BOTTOM" end
        instance.missingSlot:ClearAllPoints()
        if not (slotPoint and pcall(instance.missingSlot.SetPoint, instance.missingSlot, slotPoint, container, slotPoint)) then
          instance.missingSlot:SetPoint("TOPLEFT", region, "TOPLEFT")
        end
      end
      instance.visible = shown
      ApplyUnitStatus(instance, trigger)
      if container:IsShown() ~= shown then container:SetShown(shown) end
      -- Enabled only when the state changes: a hidden display's container is
      -- already disabled when its unit events are handled, and a shown one
      -- that kept unit, parent and anchors needs no full refresh.
      if container.faEnabled ~= shown or (shown and not unchanged) then
        container:SetEnabled(shown)
        if shown then container:UpdateAllAuras(); Private.HitchCount("UpdateAllAuras") end
      elseif shown and unitChanged then
        -- A new unit behind a kept token: the client only re-reads a container
        -- on UNIT_AURA for its unit or when it is shown or enabled again, so
        -- it would keep showing the previous unit's auras. Re-read in place,
        -- without the enable cycle (which clears and lays out again).
        container:UpdateAllAuras(); Private.HitchCount("UpdateAllAuras")
      end
      -- The Missing container follows the same unit and visibility as the aura
      -- slot, and is refreshed with it when the unit behind the token can have
      -- changed: left alone, it kept the previous target's state (the Missing
      -- look stayed closed after de-targeting, and flickered on re-targeting).
      Display.RefreshSingle(instance, unit, shown, unitChanged or not unchanged)
      -- So does a centred Modern Aura Group's half-size shadow.
      Display.RefreshFlowShadow(instance, unit, shown, unitChanged or not unchanged)
      if instance.unitGlow then
        local glowContainer = instance.unitGlow.container
        local frame = unitFrames and unit and settings.unitGlow and anchorFrame
        if frame and frame:IsForbidden() then frame = nil end
        local glowShown = not IsPreview() and frame ~= nil and frame ~= false and region:IsShown() and not native.unitGlowsHidden and settings.unitGlow == true
        local glowParent = frame or region
        if instance.unitGlow.boundUnit ~= unit or glowContainer:GetParent() ~= glowParent then
          glowContainer:SetEnabled(false)
          if unit then glowContainer:SetUnit(unit) end
          instance.unitGlow.boundUnit = unit
          if glowContainer:GetParent() ~= glowParent then glowContainer:SetParent(glowParent) end
        end
        glowContainer:ClearAllPoints()
        if frame then AnchorUnitGlow(glowContainer, frame) else glowContainer:SetAllPoints(glowParent) end
        if Changed(glowContainer:GetFrameStrata(), glowParent:GetFrameStrata()) then glowContainer:SetFrameStrata(glowParent:GetFrameStrata()) end
        local glowLevel = glowParent:GetFrameLevel() + unitGlowFrameLevel
        if Changed(glowContainer:GetFrameLevel(), glowLevel) then glowContainer:SetFrameLevel(glowLevel) end
        glowContainer:SetShown(glowShown)
        glowContainer:SetEnabled(glowShown)
        if glowShown then glowContainer:UpdateAllAuras() end
      end
    end
  end
  -- Every display in the group relinks all of them, so the order in which
  -- they rebind their units does not matter.
  if frameMode then Display.RelinkFlowUnits(Display.FlowGroup(data)) end
  Display.UpdateDetachedFrameLevels(region)
  RefreshPreview(region)
  Display.RefreshGridFor(region)
end
Display.RefreshUnits = RefreshUnits

local unitFrameRefreshPending
function Display.UnitFramesChanged()
  if unitFrameRefreshPending then return end
  local needed
  for region in pairs(activeRegions) do
    local data = region.blizzardAuraDisplay.data
    if data.anchorFrameType == "UNITFRAME" or Display.FlowFrameMode(data) == "UNITFRAME" then needed = true; break end
  end
  if not needed then return end
  unitFrameRefreshPending = true
  -- LibGetFrame can report several frame changes together during a roster update.
  C_Timer.After(0, function()
    unitFrameRefreshPending = nil
    for region in pairs(activeRegions) do
      local data = region.blizzardAuraDisplay.data
      if data.anchorFrameType == "UNITFRAME" or Display.FlowFrameMode(data) == "UNITFRAME" then RefreshUnits(region) end
    end
  end)
end

-- The display's frames stay shown (their contents cannot be known in combat),
-- so a Dynamic Group keeps its place even when no aura is there.
Display.dynamicGroupWarning = "Aura (Modern) in a Dynamic Group: It keeps its position even when no aura is shown. Use a Modern Aura Group to keep dynamic behaviour."
local function DynamicGroupWarning(data)
  local inGroup = Display.Enabled(data) and Display.InDynamicGroup(data)
  Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_dynamicgroup", inGroup and "warning" or nil,
    inGroup and Display.dynamicGroupWarning or nil)
end

local function ApplyInstance(region, data, index, instance)
  instance.data = data
  -- New settings may place the container elsewhere: RefreshUnits anchors again.
  instance.anchored = nil
  instance.container:SetEnabled(false)
  for _, button in ipairs(instance.buttons) do Style(button, data, region) end
  Layout(instance, region, data)
  local trigger = Display.GetTrigger(data)
  ConfigureProcessing(instance.container, trigger)
  if instance.slotMain then
    instance.container:SetAuraSlotSortMethod("Auras", Display.SortOrder(data, trigger))
    instance.container:SetAuraSlotFilterString("Auras", FilterString(trigger))
    instance.container:SetAuraSlotCandidateFilters("Auras", CandidateFilters(data))
  else
    instance.container:SetAuraGroupSortMethod("Auras", Display.SortOrder(data, trigger))
    instance.container:SetAuraGroupFilterString("Auras", FilterString(trigger))
    instance.container:SetAuraGroupCandidateFilters("Auras", CandidateFilters(data))
  end
  ConfigureUnitGlow(instance, region, data)
  Display.ConfigureSingle(instance, region, data, index)
end

local EDITOR_INSTANCES_NOW, EDITOR_INSTANCES_PER_FRAME = 2, 4
-- Only the units present now are built at once; the rest of the reserve
-- follows in the background, a few milliseconds per frame.
local BACKGROUND_BUDGET = 4
local instanceQueues = {}
local instanceDraining = false

-- The units a display needs right away, at login.
local function UnitsNow(trigger)
  local unit = trigger and trigger.unit
  if unit == "boss" or unit == "arena" then return UnitCount(unit) end
  if unit == "nameplate" then
    -- Plate tokens are not packed: build up to the highest one shown now.
    local highest = 1
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    for _, plate in ipairs(ok and plates or {}) do
      local token = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
      local index = type(token) == "string" and not issecretvalue(token) and tonumber(token:match("^nameplate(%d+)$"))
      if index and index > highest then highest = index end
    end
    return highest
  end
  return math.max(1, #UnitTokens(trigger))
end

local function FinishApply(region, data)
  local native = region.blizzardAuraDisplay
  -- Where the next display in a Modern Aura Group starts, then the whole chain.
  local single = native.instances[1] and native.instances[1].single
  Display.EnsureFlowShadows(region, data)
  Display.EnsureFlowRemaining(region, data)
  Display.SetFlowEnd(region, data, single and single.missing and single.missing.active and single.missing.presenceActive and single.missing.presence)
  Display.RechainFlow(Display.FlowGroup(data))
  RefreshUnits(region)
  pending[region] = nil
  SyncSounds(region)
  Warn(data)
end

local function DrainInstanceQueues()
  instanceDraining = false
  local more = false
  local deadline = debugprofilestop() + BACKGROUND_BUDGET
  for region in pairs(instanceQueues) do
    local native = region.blizzardAuraDisplay
    local queue = native and native.instanceQueue
    if not queue or not native.active or native.data ~= queue.data then
      instanceQueues[region] = nil
    elseif Restricted() then
      -- Kept; the end of restrictions restarts the drain.
      if not queue.background then
        native.instanceQueue, instanceQueues[region] = nil, nil
        pending[region] = queue.data
      end
    elseif debugprofilestop() > deadline then
      more = true
    else
      local last = queue.background and queue.total or math.min(queue.nextIndex + EDITOR_INSTANCES_PER_FRAME - 1, queue.total)
      local index = queue.nextIndex
      while index <= last do
        local ok, instance = true, native.instances[index]
        if not instance then ok, instance = pcall(Create, region, queue.data) end
        if ok then
          native.instances[index] = instance
          xpcall(ApplyInstance, geterrorhandler(), region, queue.data, index, instance)
        else
          geterrorhandler()(instance)
          index = queue.total
        end
        index = index + 1
        if queue.background and debugprofilestop() > deadline then break end
      end
      queue.nextIndex = index
      if index > queue.total then
        native.instanceQueue, instanceQueues[region] = nil, nil
        if queue.background then FinishApply(region, queue.data) else RefreshUnits(region) end
      else
        more = true
      end
    end
  end
  if more and not instanceDraining then
    instanceDraining = true
    C_Timer.After(0, DrainInstanceQueues)
  end
end

function Display.FlushInstanceQueue(region)
  local native = region.blizzardAuraDisplay
  local queue = native and native.instanceQueue
  if not queue or queue.background then return end
  native.instanceQueue, instanceQueues[region] = nil, nil
  if Restricted() then pending[region] = queue.data; return end
  if native.data ~= queue.data then return end
  for index = queue.nextIndex, queue.total do
    native.instances[index] = native.instances[index] or Create(region, queue.data)
    ApplyInstance(region, queue.data, index, native.instances[index])
  end
end

local ApplyDisplay
function Display.Apply(region, data)
  if Display.ForgetAppearanceKey then Display.ForgetAppearanceKey(data) end
  local profile = Private.loadProfile
  if not profile or profile.done then
    Private.StartProfileSystem("aura (modern) - build")
    ApplyDisplay(region, data)
    Private.StopProfileSystem("aura (modern) - build")
    return
  end
  local started = debugprofilestop()
  ApplyDisplay(region, data)
  profile.modern[data.id] = (profile.modern[data.id] or 0) + debugprofilestop() - started
end

function ApplyDisplay(region, data)
  DynamicGroupWarning(data)
  if not Display.Enabled(data) then Display.Release(region); Warn(data); SoundWarning(data); return end
  Suppress(region)
  local problem = Display.Validate(data)
  if problem then Display.Release(region); Warn(data, problem); return end
  -- Public editor frames can update while native container changes are deferred.
  -- They never bind units or consume live aura state.
  if IsPreview() then
    Display.ShowPreview(region, data, function(sample, appearance)
      Display.StyleAppearance(sample, Display.PrepareConditionAppearance(appearance), ElementFrame, StyleText, StyleGlow)
    end)
    Display.ArrangeFlowPreview(Display.FlowGroup(data))
    Suppress(region)
  else
    Display.HidePreview(region)
    Display.RestorePreviewRegion(region)
    Display.RestoreGroupPreview(Display.FlowGroup(data))
  end
  -- Built right after login, a few per frame, instead of during the loading screen.
  if not IsPreview() and not WeakAuras.IsLoginFinished() then
    pending[region] = data
    return
  end
  if Restricted() then
    pending[region] = data
    Warn(data, "Display > Secret Aura Settings changes will apply when aura restrictions end.")
    return
  end
  if not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
    local loaded, reason = C_AddOns.LoadAddOn("Blizzard_AuraContainer")
    if not loaded then Warn(data, "Cannot load Blizzard_AuraContainer: " .. tostring(reason)); return end
  end
  local native = region.blizzardAuraDisplay
  if not native then
    native = {instances = {}, data = data}
    region.blizzardAuraDisplay = native
    TimedHookScript(region, "OnHide", function()
      Display.HideUnitGlows(region)
      for _, instance in ipairs(native.instances) do
        if Locked(instance.container) then
          lockedHide[region] = true
        else
          instance.container:SetEnabled(false)
          instance.container:Hide()
        end
        Display.RefreshSingle(instance, nil, false)
      end
      SyncSounds(region)
      Display.RefreshGridFor(region)
    end)
    TimedHookScript(region, "OnShow", function()
      native.unitGlowsHidden = false
      if native.active then RefreshUnits(region); SyncSounds(region) end
    end)
  end
  native.data = data
  -- A Modern Aura Group child draws from its start frame (SecretAuraFlow.lua).
  Display.EnsureFlowStart(region, data)
  -- The samples were styled above; RefreshPreview keeps them.
  native.previewStyled = IsPreview() and data or nil
  if IsPreview() then UpdatePreviewNotice(region) end
  native.unitGlowsHidden = false
  -- Joining or leaving a Modern Aura Group needs containers made for it: the old
  -- ones are retired (frames cannot be destroyed, so they stay hidden).
  -- The same when the display changes between one aura (a slot) and a list
  -- or a gated display (a group): the slot or group is fixed at creation.
  local wantsFlow = Display.FlowGroup(data) ~= nil
  local first = native.instances[1]
  if first and (first.flowContainer ~= wantsFlow
    or (first.slotMain ~= nil and first.slotMain ~= WantsSlot(data, wantsFlow, first.container))) then
    for _, instance in ipairs(native.instances) do
      instance.container:SetEnabled(false)
      instance.container:Hide()
      Display.RefreshSingle(instance, nil, false)
      if instance.single and instance.single.missing then instance.single.missing.active = false end
      -- Retired frames leave the region: every frame under it is walked again
      -- whenever its parent, strata or level is set.
      Display.RetireFrame(instance.container)
      if instance.flowShadow then Display.RetireFrame(instance.flowShadow) end
      if instance.unitGlow then Display.RetireFrame(instance.unitGlow.container) end
    end
    native.instances = {}
  end
  -- Reserve containers before combat; roster and plate events only rebind existing ones.
  local trigger = Display.GetTrigger(data)
  local total = math.max(Capacity(trigger, data), #native.instances)
  local now, background = total, false
  if IsPreview() then
    now = math.min(total, EDITOR_INSTANCES_NOW)
  else
    now = math.min(total, UnitsNow(trigger))
    background = true
  end
  for index = 1, now do
    if not native.instances[index] then native.instances[index] = Create(region, data) end
  end
  Display.ClearSingleWarning(data)
  native.instanceQueue, instanceQueues[region] = nil, nil
  if now < total then
    native.instanceQueue = {data = data, nextIndex = now + 1, total = total, background = background}
    instanceQueues[region] = true
  end
  for index = 1, now do ApplyInstance(region, data, index, native.instances[index]) end
  native.active = true
  native.appliedTrigger = Display.GetSavedTrigger(data)
  activeRegions[region] = true
  FinishApply(region, data)
  if native.instanceQueue and not instanceDraining then
    instanceDraining = true
    C_Timer.After(0, DrainInstanceQueues)
  end
end

-- Shared with SecretAuraSingle.lua.
Display.FilterString = FilterString
Display.CandidateFilters = CandidateFilters
Display.StyleNative = Style
Display.StyleText = StyleText

local function Install(region)
  if not region.blizzardOriginalUpdate then
    local update = region.Update
    region.blizzardOriginalUpdate = {func = update}
    region.Update = function(self, ...)
      if update then update(self, ...) end
      Suppress(self)
      if Display.UpdateMissingSource then Display.UpdateMissingSource(self) end
    end
  end
  if not region.blizzardOriginalPreShow then
    region.blizzardOriginalPreShow = {func = region.PreShow}
    region.PreShow = function(self) Suppress(self) end
  end
  Suppress(region)
end

function Display.Activate(region, data)
  if not Display.Enabled(data) then Display.Release(region); return end
  Install(region)
  local native = region.blizzardAuraDisplay
  if native and native.data == data and not pending[region] and Display.Validate(data) == nil
    and #native.instances >= Capacity(Display.GetTrigger(data), data) then
    Display.FlushInstanceQueue(region)
    -- Reloading an existing display must restore its learning subscription too.
    local trigger = Display.GetTrigger(data)
    Display.WatchAuraLearning(region, data, trigger, Display.LateGlowSpec(data, trigger))
    native.unitGlowsHidden = false
    native.active = true
    activeRegions[region] = true
    Display.RechainFlow(Display.FlowGroup(data))
    RefreshUnits(region)
    SyncSounds(region)
  else
    Display.Apply(region, data)
  end
end

function Display.SyncProgressSource(region, data)
  if not data then return end
  local trigger = Display.GetTrigger(data)
  local key = trigger and (data.progressSource and data.progressSource[1] or -1) or 0
  if key < 0 then key = (data.triggers.activeTriggerMode and data.triggers.activeTriggerMode > 0 and data.triggers.activeTriggerMode)
    or (Private.GetActiveTriggerFor and Private.GetActiveTriggerFor(data.id)) or 1 end
  if region.secretAuraProgressSourceIndex ~= key then
    -- Another trigger turning on or off can change the index while the same
    -- Aura (Modern) trigger still drives the display: nothing to rebuild.
    local native = region.blizzardAuraDisplay
    if native and native.active and native.data == data and native.appliedTrigger
      and native.appliedTrigger == Display.GetSavedTrigger(data) then
      region.secretAuraProgressSourceIndex = key
      return
    end
    -- The same Aura (Modern) trigger selected again after another trigger
    -- supplied the information (its unit did not exist): the display is still
    -- built, so it is only switched back on. This also works in combat, where
    -- a rebuild waits for restrictions to end.
    if native and not native.active and native.data == data and native.appliedTrigger
      and native.appliedTrigger == Display.GetSavedTrigger(data) then
      region.secretAuraProgressSourceIndex = key
      Display.Activate(region, data)
      return
    end
    Display.Modify(region, data)
  end
end

-- In the editor one action can modify a display several times in one frame, and
-- many displays at once: multi-select setters, texture pickers, paste. A display
-- that is already built is rebuilt once, on the next frame, a few per frame.
local EDITOR_APPLIES_PER_FRAME = 2
local editorQueue = {}
local editorDraining = false
local function DrainEditorQueue()
  local regions = {}
  for region in pairs(editorQueue) do regions[#regions + 1] = region end
  local done = 0
  for _, region in ipairs(regions) do
    if done >= EDITOR_APPLIES_PER_FRAME then break end
    local data = editorQueue[region]
    editorQueue[region] = nil
    -- Skip displays deleted, renamed or replaced since they were queued.
    local entry = Private.regions[data.id]
    if entry and entry.region == region and (WeakAuras.GetData(data.id) or data) == data and Display.Enabled(data) then
      xpcall(Display.Apply, geterrorhandler(), region, data)
      done = done + 1
    end
  end
  if next(editorQueue) then C_Timer.After(0, DrainEditorQueue) else editorDraining = false end
end

function Display.CancelEditorApply(region)
  editorQueue[region] = nil
end

function Display.Modify(region, data)
  local flowProblem = Display.FlowNormalProblem(data)
  Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_flow_member", flowProblem and "warning" or nil, flowProblem)
  local trigger = Display.GetTrigger(data)
  local key = trigger and (data.progressSource and data.progressSource[1] or -1) or 0
  if key < 0 then key = (data.triggers.activeTriggerMode and data.triggers.activeTriggerMode > 0 and data.triggers.activeTriggerMode)
    or (Private.GetActiveTriggerFor and Private.GetActiveTriggerFor(data.id)) or 1 end
  region.secretAuraProgressSourceIndex = key
  region.secretAuraConditionValues = nil
  if not Display.Enabled(data) then Display.Release(region); Warn(data); SoundWarning(data); return end
  Install(region)
  local native = region.blizzardAuraDisplay
  if WeakAuras.IsOptionsOpen() and native and native.active and native.data == data and not Restricted() then
    editorQueue[region] = data
    if not editorDraining then
      editorDraining = true
      C_Timer.After(0, DrainEditorQueue)
    end
    return
  end
  editorQueue[region] = nil
  Display.Apply(region, data)
end

-- Native containers watch UNIT_AURA themselves. Only rebind when their unit can change.
local unitEvents = {
  GROUP_ROSTER_UPDATE = {group = true, party = true, raid = true, member = true},
  PLAYER_ROLES_ASSIGNED = {group = true, party = true, raid = true},
  PLAYER_TARGET_CHANGED = {target = true, targettarget = true},
  PLAYER_FOCUS_CHANGED = {focus = true, focustarget = true},
  UPDATE_MOUSEOVER_UNIT = {mouseover = true},
  INSTANCE_ENCOUNTER_ENGAGE_UNIT = {boss = true, member = true},
  ARENA_OPPONENT_UPDATE = {arena = true, member = true},
  -- Names only matter to group displays filtered by player name.
  UNIT_NAME_UPDATE = {group = true, party = true, raid = true},
  -- Combat and restriction changes do not change which units are watched.
  PLAYER_REGEN_ENABLED = {},
  ADDON_RESTRICTION_STATE_CHANGED = {},
}

local function NeedsUnitRefresh(mode, event, unit, trigger)
  if event == "UNIT_TARGET" then
    return (mode == "targettarget" and unit == "target") or (mode == "focustarget" and unit == "focus")
  elseif event == "UNIT_PET" then
    return (mode == "pet" and unit == "player") or mode == "member" or Display.IncludesPets(trigger) ~= nil
  end
  local modes = unitEvents[event]
  return modes == nil or modes[mode] == true
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
-- Reconfigure physical-pixel borders when the screen's pixel-to-UI ratio changes.
events:RegisterEvent("UI_SCALE_CHANGED")
events:RegisterEvent("DISPLAY_SIZE_CHANGED")
for _, event in ipairs({"PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED",
  "UPDATE_MOUSEOVER_UNIT", "UNIT_TARGET", "UNIT_PET", "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "ARENA_OPPONENT_UPDATE",
  "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_NAME_UPDATE", "PLAYER_ROLES_ASSIGNED"}) do events:RegisterEvent(event) end
-- Deaths, releases and disconnects only change the affected unit's alpha.
local statusEvents = CreateFrame("Frame")
for _, event in ipairs({"UNIT_CONNECTION", "UNIT_HEALTH", "UNIT_FLAGS", "PLAYER_FLAGS_CHANGED"}) do statusEvents:RegisterEvent(event) end
statusEvents:SetScript("OnEvent", function(_, _, unit)
  if type(unit) ~= "string" then return end
  for region in pairs(activeRegions) do
    local native = region.blizzardAuraDisplay
    -- Read only: the saved trigger, without the copy GetTrigger may make.
    local trigger = Display.GetSavedTrigger(native.data)
    if trigger and (trigger.ignoreDead or trigger.ignoreDisconnected) then
      local single = #native.instances == 1
      for _, instance in ipairs(native.instances) do
        local bound = instance.visible and instance.boundUnit
        if bound and (bound == unit or (single and Private.ExecEnv.UnitIsUnit(bound, unit)))
          and (UnitIgnored(trigger, bound) or nil) ~= instance.statusHidden then
          ApplyUnitStatus(instance, trigger)
          Display.RefreshSingleStatus(instance)
        end
      end
    end
  end
end)

-- Displays waiting for restrictions to end are rebuilt a few per frame, so
-- the end of combat does not rebuild every display in one frame.
-- The budget covers only the Lua side; each rebuild also costs the client
-- drawing time afterwards, so it is kept small.
local PENDING_BUDGET = 4
local draining = false
local function DrainPending()
  -- Before login completes, the login callback starts the drain.
  if Restricted() or not WeakAuras.IsLoginFinished() then draining = false; return end
  local started = debugprofilestop()
  -- Modern Aura Groups re-anchor once per group after this batch, not once
  -- per rebuilt display (the same batching a load scan uses).
  if Display.BeginFlowLoad then Display.BeginFlowLoad() end
  for region, data in pairs(pending) do
    pending[region] = nil
    if WeakAuras.GetData(data.id) == data and Private.regions[data.id] and Private.regions[data.id].region == region then
      xpcall(Display.Apply, geterrorhandler(), region, data)
      if debugprofilestop() - started > PENDING_BUDGET then break end
    end
  end
  if Display.EndFlowLoad then Display.EndFlowLoad() end
  local profile = Private.loadProfile
  if profile and profile.done and not profile.deferredDone then
    profile.deferred = (profile.deferred or 0) + debugprofilestop() - started
    profile.deferredFrames = (profile.deferredFrames or 0) + 1
    if not next(pending) then profile.deferredDone = true end
  end
  if next(pending) then C_Timer.After(0, DrainPending) else draining = false end
end

Private.callbacks:RegisterCallback("WEAKAURAS_LOGIN_COMPLETE", function()
  if next(pending) and not draining then
    draining = true
    C_Timer.After(0, DrainPending)
  end
end)

events:SetScript("OnEvent", function(_, event, unit)
  if event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
    for region in pairs(activeRegions) do pending[region] = region.blizzardAuraDisplay.data end
    if not draining then
      draining = true
      DrainPending()
    end
    return
  end
  -- Only the target's and focus's targets are watched.
  if event == "UNIT_TARGET" and unit ~= "target" and unit ~= "focus" then return end
  -- Modern Aura Groups re-anchor once after all their displays rebound units.
  Display.BeginFlowBatch()
  for region in pairs(activeRegions) do
    local trigger = Display.GetSavedTrigger(region.blizzardAuraDisplay.data)
    local mode = trigger and trigger.unit
    if event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
      if Display.UsesNameplates(region.blizzardAuraDisplay.data) then
        if mode == "nameplate" then
          RefreshUnits(region, event == "NAME_PLATE_UNIT_REMOVED" and unit or nil, unit, true)
        else
          RefreshUnits(region, nil, nil, true)
        end
      end
    elseif pending[region] and not Restricted() then
      -- Rebuilt below; refreshing it first would be wasted.
    elseif NeedsUnitRefresh(mode, event, unit, trigger) then
      RefreshUnits(region, nil, nil, true)
    end
    if trigger and (event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED"
      or (event == "UNIT_NAME_UPDATE" and trigger.useUnitNames)) and unitEvents.GROUP_ROSTER_UPDATE[mode] then
      SyncSounds(region)
    end
  end
  Display.EndFlowBatch()
  if Restricted() then return end
  if event == "PLAYER_REGEN_ENABLED" or event == "ADDON_RESTRICTION_STATE_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
    for region in pairs(activeRegions) do Display.RefreshConditionAppearance(region) end
  end
  for region in pairs(pendingSounds) do SyncSounds(region) end
  for region in pairs(lockedHide) do
    lockedHide[region] = nil
    local native = region.blizzardAuraDisplay
    if native and not (native.active and region:IsShown()) then
      for _, instance in ipairs(native.instances) do
        if not Locked(instance.container) then
          instance.container:SetEnabled(false)
          instance.container:Hide()
        end
      end
    end
  end
  for region in pairs(lockedUnits) do
    lockedUnits[region] = nil
    if region.blizzardAuraDisplay and region.blizzardAuraDisplay.active then RefreshUnits(region, nil, nil, true) end
  end
  if next(pending) and not draining then
    draining = true
    DrainPending()
  end
  if next(instanceQueues) and not instanceDraining then
    instanceDraining = true
    C_Timer.After(0, DrainInstanceQueues)
  end
end)

for _, frame in ipairs({events, statusEvents}) do
  frame:SetScript("OnEvent", Private.Profiled("aura (modern) - events", frame:GetScript("OnEvent")))
end
