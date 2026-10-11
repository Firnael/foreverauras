-- Copyright (C) 2026 ForeverAuras. Part of ForeverAuras, licensed under the GNU GPL v2 (see LICENSE).
-- Preserve countdown and desaturation timers during Shoot's shared cooldown.
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript, C_Timer = Private.TimedAPI("WandCooldown")
local expiryTimer, refreshQueued
local snapshots, castAfterShot = {}, {}
local lastCast = {}
local shotAt, lastShotUpdate = -math.huge, -math.huge
local window = 3

local function PublicSpell(id)
  return not issecretvalue(id) and type(id) == "number"
end

local function Refresh()
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0, function()
    refreshQueued = nil
    Private.ScanEvents("FA_WAND_TEXT_REFRESH")
    Private.ScanEvents("FA_CDM_REFRESH")
  end)
end

local function Clear()
  wipe(snapshots)
  wipe(castAfterShot)
  shotAt, lastShotUpdate = -math.huge, -math.huge
  if expiryTimer then expiryTimer:Cancel(); expiryTimer = nil end
end

local function Holding()
  return GetTime() - shotAt < window
end

local function NoteShot()
  local now = GetTime()
  local changed = not Holding()
  -- Duplicate shot events must not clear a subsequent cast.
  if now - lastShotUpdate > 0.05 then
    shotAt = now
    if next(castAfterShot) then changed = true end
    wipe(castAfterShot)
  end
  lastShotUpdate = now
  if expiryTimer then expiryTimer:Cancel() end
  expiryTimer = C_Timer.NewTimer(window, function()
    expiryTimer = nil
    Refresh()
  end)
  if changed then Refresh() end
end

local function OnEvent(_, event, unit, baseSpellID, spellID)
  -- A shot or cast changes what the cooldown reads below return.
  if Private.InvalidateSpellCooldownCache then Private.InvalidateSpellCooldownCache() end
  if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
    -- Copies taken across a combat change may be stale restricted timers.
    wipe(snapshots)
  elseif event == "PLAYER_ENTERING_WORLD" then
    Clear()
    Refresh()
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
    local holding = Holding()
    if not PublicSpell(spellID) then
      -- An unidentified cast cannot safely be attributed to a tracked spell.
      Clear()
      if holding then Refresh() end
    elseif spellID == 5019 then
      NoteShot()
    else
      lastCast[spellID] = GetTime()
      local released = holding and not castAfterShot[spellID]
      castAfterShot[spellID] = true
      if released then Refresh() end
    end
  elseif event == "SPELL_UPDATE_COOLDOWN" and ((PublicSpell(unit) and unit == 5019) or (PublicSpell(baseSpellID) and baseSpellID == 5019)) then
    -- Only an active public flag identifies a new shot rather than its expiry.
    local info = C_Spell.GetSpellCooldown(5019)
    if info and not issecretvalue(info.isActive) and info.isActive == true then NoteShot() end
  end
end

function Private.IsWandHeldSpell(spellID)
  return PublicSpell(spellID) and spellID ~= 5019 and Holding() and not castAfterShot[spellID]
end

function Private.GetSpellLastCast(spellID)
  return lastCast[spellID]
end

-- Only a wand shot can hold a cooldown, so without one no copies are kept.
local wandEquipped
local function WandEquipped()
  if wandEquipped == nil then
    -- Forever has no global IsEquippedItemType; it lives under C_Item.
    local isEquippedType = (C_Item and C_Item.IsEquippedItemType) or IsEquippedItemType
    local ok, equipped = pcall(isEquippedType, "Wands")
    wandEquipped = not ok or issecretvalue(equipped) or equipped == true
  end
  return wandEquipped
end

-- Select before recharge/loss-of-control timers; Blizzard expires the copied duration.
function Private.GetWandCooldownDuration(spellID, duration, source)
  if not PublicSpell(spellID) or spellID == 5019 then return duration end
  -- Keep CDM and Spell trigger samples separate.
  local key = (source or "spell") .. ":" .. spellID
  local holding = GetTime() - shotAt < window and not castAfterShot[spellID]
  if holding then
    -- The second return identifies a copied timer without reading its contents.
    return snapshots[key] or duration, snapshots[key] ~= nil
  end
  if duration and duration.Copy and WandEquipped() then
    snapshots[key] = duration:Copy()
  else
    snapshots[key] = nil
  end
  return duration
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", OnEvent)
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

local equipment = CreateFrame("Frame")
equipment:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
equipment:SetScript("OnEvent", function() wandEquipped = nil end)
