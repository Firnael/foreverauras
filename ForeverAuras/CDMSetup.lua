-- Copyright (C) 2026 ForeverAuras. Part of ForeverAuras, licensed under the GNU GPL v2 (see LICENSE).
-- Save class-pack CDM settings for Blizzard to apply on reload, after asking.
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript, C_Timer = Private.TimedAPI("CDMSetup")
local pending, timer, needsReload, confirmed, asked
local attempts = 0

local function RecordPending(self, value)
  self.hasPendingChanges = value
end

local function StageLayout()
  -- Isolated layout objects avoid sending updates to live Blizzard frames.
  local provider = CreateFromMixins(CooldownViewerSettingsDataProviderMixin)
  local manager = CreateFromMixins(CooldownViewerLayoutManagerMixin)
  local serializer = CreateFromMixins(CooldownViewerDataStoreSerializationMixin)
  manager.SetHasPendingChanges = RecordPending
  manager.NotifyListeners = function() end
  manager:Init(provider, serializer)
  provider:SetLayoutManager(manager)
  serializer:Init(manager)
  manager:SwitchToBestLayoutForSpec()
  provider:CheckBuildDisplayData()
  manager:SetShouldCheckAddLayoutStatus(true)
  manager:SetHasPendingChanges(false)

  -- Configure every catalog rank, including unlearned and currently invisible entries.
  local count = 0
  local categories = Enum.CooldownViewerCategory
  for _, key in ipairs({"TrackedBuff", "TrackedBar", "EquipSlotTracked", "SpecAgnosticTracked"}) do
    local category = categories[key]
    if category then
      for _, id in ipairs(C_CooldownViewer.GetCooldownViewerCategorySet(category, true)) do
        local info = provider:GetCooldownInfoForID(id)
        if info and info.category ~= categories.TrackedBuff then
          local status = provider:SetCooldownToCategory(id, categories.TrackedBuff)
          if status ~= Enum.CooldownLayoutStatus.Success then
            error("Could not update Tracked Buffs (layout status " .. tostring(status) .. ").")
          end
          count = count + 1
        end
      end
    end
  end
  -- Restore only hidden spell entries to their catalog category; keep item entries and visible placements.
  -- Spell entries can have buffSlot metadata too; only equipment slots and item categories exclude them.
  local cooldownCount = 0
  for _, key in ipairs({"Essential", "Utility"}) do
    local category = categories[key]
    for _, id in ipairs(C_CooldownViewer.GetCooldownViewerCategorySet(category, true)) do
      local info = provider:GetCooldownInfoForID(id)
      if info and info.category == categories.HiddenActive and type(info.spellID) == "number" and info.spellID > 0 and info.equipSlot == nil and info.spellCategoryID == nil then
        local status = provider:SetCooldownToCategory(id, category)
        if status ~= Enum.CooldownLayoutStatus.Success then
          error("Could not update " .. key .. " cooldowns (layout status " .. tostring(status) .. ").")
        end
        cooldownCount = cooldownCount + 1
      end
    end
  end
  return count + cooldownCount > 0 and serializer:SerializeLayouts() or nil, count, cooldownCount
end

local function StageVisibility()
  local saved = C_EditMode.GetLayouts()
  local presets = EditModePresetLayoutManager:GetCopyOfPresetLayouts()
  local layouts = CopyTable(presets)
  for _, layout in ipairs(saved.layouts) do layouts[#layouts + 1] = CopyTable(layout) end
  local active = layouts[saved.activeLayout]
  if not active then error("The active Edit Mode layout is not ready.") end
  local settings = Enum.EditModeCooldownViewerSetting
  local always = Enum.CooldownViewerVisibleSetting.Always
  local count = 0
  local found = {}
  local indices = Enum.EditModeCooldownViewerSystemIndices
  local viewers = {[indices.Essential] = true, [indices.Utility] = true, [indices.BuffIcon] = true, [indices.BuffBar] = true}
  -- Older layouts may need missing CDM systems copied from the preset.
  for _, system in ipairs(active.systems) do
    if system.system == Enum.EditModeSystem.CooldownViewer and viewers[system.systemIndex] then found[system.systemIndex] = true end
  end
  for _, system in ipairs(presets[1].systems) do
    if system.system == Enum.EditModeSystem.CooldownViewer and viewers[system.systemIndex] and not found[system.systemIndex] then
      active.systems[#active.systems + 1] = CopyTable(system)
      found[system.systemIndex] = true
      count = count + 1
    end
  end
  for _, key in ipairs({"Essential", "Utility", "BuffIcon", "BuffBar"}) do
    if not found[indices[key]] then error("Edit Mode has no settings for " .. key .. ".") end
  end
  -- Every viewer also gets its tooltips turned off (Essential, Utility and
  -- both Tracked Buffs displays): the class packs' own auras show what each
  -- icon is, and consume auras follow this setting for their own tooltips.
  -- Clients without the setting skip it.
  local tooltipBars = settings.ShowTooltips and viewers or {}
  for _, system in ipairs(active.systems) do
    if system.system == Enum.EditModeSystem.CooldownViewer and viewers[system.systemIndex] then
      local visible, tooltips
      for _, setting in ipairs(system.settings) do
        if setting.setting == settings.VisibleSetting then
          visible = setting
          if setting.value ~= always then setting.value = always; count = count + 1 end
        elseif tooltipBars[system.systemIndex] and setting.setting == settings.ShowTooltips then
          tooltips = setting
          if setting.value ~= 0 then setting.value = 0; count = count + 1 end
        end
      end
      if not visible then
        system.settings[#system.settings + 1] = {setting = settings.VisibleSetting, value = always}
        count = count + 1
      end
      if tooltipBars[system.systemIndex] and not tooltips then
        system.settings[#system.settings + 1] = {setting = settings.ShowTooltips, value = 0}
        count = count + 1
      end
    end
  end
  if count == 0 then return end
  -- Built-in presets require a character copy before saving changes.
  if active.layoutType == Enum.EditModeLayoutType.Preset then
    local name = "ForeverAuras"
    local index = 1
    local used = {}
    for _, layout in ipairs(layouts) do used[layout.layoutName] = true end
    while used[name] do index = index + 1; name = "ForeverAuras " .. index end
    local copy = CopyTable(active)
    copy.layoutType = Enum.EditModeLayoutType.Character
    copy.layoutName = name
    layouts[saved.activeLayout] = presets[saved.activeLayout]
    layouts[#layouts + 1] = copy
    saved.activeLayout = #layouts
  end
  saved.layouts = layouts
  return saved
end

local function ApplySetup()
  local settings = CooldownViewerSettings
  if not settings or not settings.GetDataProvider or not settings.GetLayoutManager then return false end
  local manager = settings:GetLayoutManager()
  if not manager or not manager:IsLoaded() then return false end
  if settings:IsShown() or EditModeManagerFrame:IsShown() or manager:HasPendingChanges() then return false end
  if not C_EditMode or not EditModePresetLayoutManager or not CooldownViewerDataStoreSerializationMixin then
    error("This client does not expose the required CDM layout APIs.")
  end
  local serialized, count, cooldownCount = StageLayout()
  local editLayouts = StageVisibility()
  local enable = not C_CVar.GetCVarBool("cooldownViewerEnabled")
  local hide = Private.db.cdmHideBlizzard ~= true
  if not serialized and not editLayouts and not enable and not hide then return true end

  -- Preserve the character's original settings for recovery.
  local character = UnitGUID("player")
  if issecretvalue(character) or type(character) ~= "string" then error("The character is not ready for CDM setup.") end
  if not confirmed then
    if asked or (Private.db.cdmClassPackSetupSkip or {})[character] then return true end
    asked = true
    StaticPopup_Show("FOREVERAURAS_CDM_SETUP_ASK", count, cooldownCount, {character = character})
    return true
  end
  Private.db.cdmClassPackSetupBackups = Private.db.cdmClassPackSetupBackups or {}
  Private.db.cdmClassPackSetupBackups[character] = Private.db.cdmClassPackSetupBackups[character] or {
    cooldownLayout = C_CooldownViewer.GetLayoutData(),
    editLayouts = C_EditMode.GetLayouts(),
    enabled = not enable,
    hideBlizzard = not hide,
  }
  needsReload = true
  if serialized then
    C_CooldownViewer.SetLayoutData(serialized)
    if C_CooldownViewer.GetLayoutData() ~= serialized then error("CDM did not save the layout.") end
  end
  if editLayouts then
    C_EditMode.SaveLayouts(editLayouts)
    C_EditMode.SetActiveLayout(editLayouts.activeLayout)
    if StageVisibility() then error("Edit Mode did not save CDM visibility.") end
  end
  Private.db.cdmHideBlizzard = true
  if enable then C_CVar.SetCVar("cooldownViewerEnabled", "1") end
  Private.ApplyCDMBackground()
  print("ForeverAuras: CDM setup saved. " .. count .. " buffs and " .. cooldownCount .. " spell cooldowns added; viewers set to Always visible with tooltips off. Reload to apply.")
  StaticPopup_Show("FOREVERAURAS_CDM_SETUP_RELOAD")
  return true
end

local RunSetup

StaticPopupDialogs["FOREVERAURAS_CDM_SETUP_ASK"] = {
  text = "A ForeverAuras class pack can set up Blizzard's Cooldown Manager for its auras (%d buffs, %d spell cooldowns). This changes your CDM and Edit Mode settings and needs a reload.",
  button1 = "Apply",
  button2 = "Not now",
  button3 = "Don't ask again",
  OnAccept = function()
    confirmed, pending, attempts = true, true, 0
    if not timer then timer = C_Timer.NewTimer(0, RunSetup) end
  end,
  OnAlt = function(_, info)
    Private.db.cdmClassPackSetupSkip = Private.db.cdmClassPackSetupSkip or {}
    if info and info.character then Private.db.cdmClassPackSetupSkip[info.character] = true end
    print("ForeverAuras: CDM setup won't be offered again on this character. Type /fa cdmsetup to run it.")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

StaticPopupDialogs["FOREVERAURAS_CDM_SETUP_RELOAD"] = {
  text = "ForeverAuras has changed CDM settings. Reload to apply them.",
  button1 = RELOADUI,
  button2 = LATER,
  OnAccept = function() ReloadUI() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

function RunSetup()
  timer = nil
  if not pending or needsReload then return end
  if InCombatLockdown() then return end
  attempts = attempts + 1
  -- Stop retries if setup fails after partially applying settings.
  local ok, done = pcall(ApplySetup)
  if not ok then
    pending = nil
    print("ForeverAuras: CDM setup stopped: " .. tostring(done))
    if needsReload then StaticPopup_Show("FOREVERAURAS_CDM_SETUP_RELOAD") end
  elseif done then
    pending = nil
  elseif attempts < 60 then
    timer = C_Timer.NewTimer(1, RunSetup)
  else
    pending = nil
    print("ForeverAuras: CDM setup is waiting for saved layouts. Close CDM and Edit Mode settings, then reload to retry.")
  end
end

function WeakAuras.SetupClassPackCDM(class)
  -- Init also runs when inspecting auras whose Load conditions are unmet.
  local _, playerClass = UnitClass("player")
  if type(class) ~= "string" or class ~= playerClass then return false end
  if needsReload then return true end
  -- Every explicit call can recheck the saved layout after a previous no-op.
  if not pending then attempts = 0 end
  pending = true
  if not timer then timer = C_Timer.NewTimer(0, RunSetup) end
  return true
end

-- /fa cdmsetup: run it now, also after "Don't ask again".
function Private.RunCDMSetup()
  local character = UnitGUID("player")
  if Private.db.cdmClassPackSetupSkip and type(character) == "string" and not issecretvalue(character) then
    Private.db.cdmClassPackSetupSkip[character] = nil
  end
  if needsReload then StaticPopup_Show("FOREVERAURAS_CDM_SETUP_RELOAD") return end
  confirmed, pending, attempts = true, true, 0
  if not timer then timer = C_Timer.NewTimer(0, RunSetup) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Only resume an explicit request that was deferred by combat.
events:SetScript("OnEvent", function()
  if pending and not needsReload and not timer then timer = C_Timer.NewTimer(0, RunSetup) end
end)
