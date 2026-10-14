-- Copyright (C) 2026 ForeverAuras. Part of ForeverAuras, licensed under the GNU GPL v2 (see LICENSE).
-- Stand-ins for displays that are not Aura (Modern) in a Modern Aura Group.
-- Only frames created with DisableUntrustedLayoutScriptsTemplate may follow an
-- aura container, so such a display is drawn by copies made inside its chain
-- frame (flow.start). Every change to the display's own icon, cooldown, texts
-- and border is forwarded to its copy; the display itself is moved off screen.
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript = Private.TimedAPI("SecretAuraStand")
local Display = Private.BlizzardAuraDisplay

local standTypes = {icon = true, text = true}
-- Glow elements are mirrored by building the glow on the copy (MirrorGlow).
local mirrorTypes = {subtext = true, subborder = true, subglow = true}

local FRAME = {"ClearAllPoints", "SetPoint", "SetAllPoints", "SetSize", "SetWidth", "SetHeight", "Show", "Hide", "SetShown", "SetAlpha"}
local TEXTURE = {"ClearAllPoints", "SetPoint", "SetAllPoints", "Show", "Hide", "SetShown", "SetAlpha", "SetTexture", "SetAtlas",
  "SetTexCoord", "SetDesaturated", "SetDesaturation", "SetVertexColor", "SetBlendMode", "SetRotation", "SetColorTexture"}
local FONT = {"ClearAllPoints", "SetPoint", "SetAllPoints", "Show", "Hide", "SetShown", "SetAlpha", "SetText", "SetFormattedText",
  "SetTextColor", "SetFont", "SetFontObject", "SetShadowColor", "SetShadowOffset", "SetJustifyH", "SetJustifyV", "SetWordWrap",
  "SetNonSpaceWrap", "SetTextHeight", "SetWidth", "SetHeight", "SetSpacing"}
local COOLDOWN = {"ClearAllPoints", "SetPoint", "SetAllPoints", "Show", "Hide", "SetShown", "SetAlpha", "SetCooldown",
  "SetCooldownFromDurationObject", "SetCooldownDuration", "Clear", "Pause", "Resume", "SetReverse", "SetDrawSwipe", "SetDrawEdge",
  "SetDrawBling", "SetHideCountdownNumbers", "SetSwipeColor", "SetSwipeTexture", "SetEdgeTexture", "SetUseAuraDisplayTime",
  "SetCountdownFormatter", "SetMinimumCountdownDuration", "SetDrawSwipeOrg"}
local BORDER = {"SetBackdrop", "SetBackdropBorderColor", "SetBackdropColor"}
local SECURE = {"ClearAllPoints", "SetPoint", "SetAllPoints", "SetSize", "SetWidth", "SetHeight", "SetAlpha", "SetAttribute", "RegisterForClicks"}
local ATTRIBUTES = {"type", "type1", "type2", "spell", "spell1", "spell2", "item", "item1", "item2", "macro", "macrotext", "macrotext1",
  "macrotext2", "action", "unit", "unit1", "unit2", "target-slot", "target-item", "target-bag", "useOnKeyDown", "checkselfcast", "checkfocuscast"}
local POINTS = {SetPoint = true, SetAllPoints = true}

function Display.UsesStand(data)
  return data and standTypes[data.regionType] == true
end

local function Map(stand, value)
  if type(value) ~= "table" then return value end
  if value == stand.region then return stand.frame end
  if stand.copies[value] then return stand.copies[value] end
  if value.GetParent and value:GetParent() == stand.region then return stand.frame end
  return value
end

local function Forward(source, method, ...)
  local link = source.faStand
  if link and link.owner and link.owner:GetParent() ~= link.stand.region then return end
  local copy = link and link.stand.active and link.stand.copies[source]
  -- Icons mask SetDrawSwipe and draw the swipe through the original setter.
  if method == "SetDrawSwipeOrg" then method = "SetDrawSwipe" end
  if not copy or not copy[method] then return end
  if link.stand.secure[source] and InCombatLockdown() then return end
  if POINTS[method] then
    local stand = link.stand
    local a, b, c, d, e = ...
    if type(a) == "table" then a = Map(stand, a) end
    if type(b) == "table" then b = Map(stand, b) end
    pcall(copy[method], copy, a, b, c, d, e)
  else
    pcall(copy[method], copy, ...)
  end
end

local function Hook(source, methods)
  source.faStandHooked = source.faStandHooked or {}
  for _, method in ipairs(methods) do
    if source[method] and not source.faStandHooked[method] then
      source.faStandHooked[method] = true
      hooksecurefunc(source, method, function(self, ...)
        if not self.faStand then return end
        Private.StartProfileSystem("aura (modern) - group copies")
        Forward(self, method, ...)
        Private.StopProfileSystem("aura (modern) - group copies")
      end)
    end
  end
end

local function NumPoints(source)
  local ok, count = false, 0
  if source.GetNumPoints then ok, count = pcall(source.GetNumPoints, source) end
  return ok and type(count) == "number" and count or 0
end

local function CopyPoints(stand, source, copy)
  pcall(copy.ClearAllPoints, copy)
  local count = NumPoints(source)
  for index = 1, count do
    local ok, point, relative, relativePoint, x, y = pcall(source.GetPoint, source, index)
    if ok and point then pcall(copy.SetPoint, copy, point, Map(stand, relative) or stand.frame, relativePoint, x, y) end
  end
  if count == 0 then pcall(copy.SetAllPoints, copy, stand.frame) end
end

local function Try(target, method, ...)
  if target[method] then pcall(target[method], target, ...) end
end

local function Apply(copy, setter, ok, ...)
  if ok then Try(copy, setter, ...) end
end

local function Pass(copy, setter, source, getter)
  if copy[setter] and source[getter] then Apply(copy, setter, pcall(source[getter], source)) end
end

local function CopyTexture(source, copy)
  Pass(copy, "SetTexture", source, "GetTexture")
  Pass(copy, "SetTexCoord", source, "GetTexCoord")
  Pass(copy, "SetDesaturated", source, "IsDesaturated")
  Pass(copy, "SetVertexColor", source, "GetVertexColor")
  Pass(copy, "SetBlendMode", source, "GetBlendMode")
end

-- A pixel-perfect border keeps 1 px edges: same scale and snapping as its source.
local function MatchBorderScale(sub, copy)
  if not (copy.ForEachPiece and sub.IsIgnoringParentScale) then return end
  local ok, ignore = pcall(sub.IsIgnoringParentScale, sub)
  local pixelPerfect = ok and ignore == true
  local scale = pixelPerfect and sub:GetScale() or 1
  copy:SetIgnoreParentScale(pixelPerfect)
  copy:SetScale(scale)
  -- The pieces follow the frame's scale (scaling them again would shrink the
  -- edges); hiding and showing makes the new scale take effect.
  copy:ForEachPiece(function(_, piece)
    piece:SetIgnoreParentScale(false)
    piece:SetScale(1)
    piece:Hide()
    piece:Show()
    -- Drawn exactly like the Border element draws it.
    if pixelPerfect then
      piece:SetSnapToPixelGrid(false)
      piece:SetTexelSnappingBias(0)
    end
  end)
  local shown = copy:IsShown()
  copy:Hide()
  if shown then copy:Show() end
end

local function CopyFont(source, copy)
  Pass(copy, "SetFont", source, "GetFont")
  Pass(copy, "SetJustifyH", source, "GetJustifyH")
  Pass(copy, "SetJustifyV", source, "GetJustifyV")
  Pass(copy, "SetWordWrap", source, "CanWordWrap")
  Pass(copy, "SetShadowColor", source, "GetShadowColor")
  Pass(copy, "SetShadowOffset", source, "GetShadowOffset")
  Pass(copy, "SetTextColor", source, "GetTextColor")
  Pass(copy, "SetText", source, "GetText")
end

local function CopyCooldown(stand, source, copy, data)
  Try(copy, "SetDrawBling", false)
  Pass(copy, "SetReverse", source, "GetReverse")
  Pass(copy, "SetDrawSwipe", source, "GetDrawSwipe")
  Pass(copy, "SetDrawEdge", source, "GetDrawEdge")
  Try(copy, "SetHideCountdownNumbers", data and data.cooldownTextDisabled ~= false)
  local region = stand.region
  local durationObject = region.durationObject
  if durationObject and type(durationObject) == "table" and durationObject.EvaluateRemainingDuration then
    Try(copy, "SetCooldownFromDurationObject", durationObject, true)
  elseif source.GetCooldownTimes then
    local ok, start, duration = pcall(source.GetCooldownTimes, source)
    if ok and type(start) == "number" and type(duration) == "number" and not issecretvalue(start) and not issecretvalue(duration) then
      Try(copy, "SetCooldown", start / 1000, duration / 1000)
    end
  end
end

-- A Glow element's glow on its copy. The glow library re-parents pooled
-- frames, which the chain frame refuses (UntrustedLayoutScriptExecution), so
-- the glow is built in place from the element's settings by SecretAuraGlow.lua,
-- as on Aura (Modern) icons; the copy itself plays the animations.
local player = {
  AddAuraShownAnimation = function(_, animation) animation:Play() end,
  RemoveAuraShownAnimation = function(_, animation) animation:Stop() end,
}
local function MirrorGlow(copy)
  local sub = copy.faGlowSource
  copy.faGlowEntry = copy.faGlowEntry or {}
  local width, height = copy:GetSize()
  if not sub or not sub.glow or not (width and width >= 1 and height and height >= 1) then
    Display.ClearElementGlow(copy.faGlowEntry)
    return
  end
  Display.StyleElementGlow(copy.faGlowEntry, player, copy, copy, sub, width, height)
end

local function Link(stand, source, copy, methods, owner)
  stand.copies[source] = copy
  stand.sources[#stand.sources + 1] = source
  source.faStand = {stand = stand, owner = owner}
  Hook(source, methods)
end

local function Pooled(stand, key, make)
  local copy = stand.pool[key]
  if not copy then
    copy = make()
    stand.pool[key] = copy
  end
  return copy
end

local function Unlink(stand)
  local keep = InCombatLockdown()
  local kept = {}
  for _, source in ipairs(stand.sources) do
    if keep and stand.secure[source] then
      kept[#kept + 1] = source
    elseif source.faStand and source.faStand.stand == stand then
      source.faStand = nil
    end
  end
  wipe(stand.sources)
  for source in pairs(stand.copies) do
    if not (keep and stand.secure[source]) then stand.copies[source] = nil end
  end
  if not keep then wipe(stand.secure) end
  for _, source in ipairs(kept) do stand.sources[#stand.sources + 1] = source end
  for _, copy in pairs(stand.pool) do
    if not (keep and copy.faSecure) then copy:Hide() end
    -- A released glow copy stops glowing.
    if copy.faGlowSource then copy.faGlowSource = nil; MirrorGlow(copy) end
  end
end

local function SecureSource(child)
  local okType, kind = pcall(child.GetObjectType, child)
  if not okType or (kind ~= "Button" and kind ~= "CheckButton") then return false end
  local okProtected, protected = pcall(child.IsProtected, child)
  if okProtected and protected then return true end
  local okAttribute, value = pcall(child.GetAttribute, child, "type")
  return okAttribute and value ~= nil
end

local function LinkSecure(stand, region)
  if InCombatLockdown() or not region.GetChildren then return end
  local count = 0
  for _, child in ipairs({region:GetChildren()}) do
    if child ~= stand.frame and SecureSource(child) then
      count = count + 1
      local frame = stand.frame
      local copy = Pooled(stand, "secure" .. count, function()
        local button = CreateFrame("Button", nil, frame, "SecureActionButtonTemplate")
        button.faSecure = true
        return button
      end)
      stand.secure[child] = copy
      Link(stand, child, copy, SECURE)
      Try(copy, "RegisterForClicks", "AnyUp", "AnyDown")
      for _, name in ipairs(ATTRIBUTES) do
        local ok, value = pcall(child.GetAttribute, child, name)
        if ok then Try(copy, "SetAttribute", name, value) end
      end
    end
  end
end

function Display.SyncStandSecure(region, normal)
  local stand = normal and normal.stand
  if not stand or not stand.active or InCombatLockdown() or not region.GetChildren then return end
  for _, child in ipairs({region:GetChildren()}) do
    if child ~= stand.frame and not stand.secure[child] and SecureSource(child) then
      xpcall(function() Display.EnsureStand(region, normal) end, geterrorhandler())
      return
    end
  end
end

function Display.StandLocked(normal)
  local stand = normal and normal.stand
  return InCombatLockdown() and stand ~= nil and next(stand.secure) ~= nil
end

function Display.EnsureStand(region, normal)
  local stand = normal.stand
  if not stand then
    stand = {frame = normal.flow.start, region = region, copies = {}, sources = {}, pool = {}, secure = {}}
    normal.stand = stand
  end
  Unlink(stand)
  stand.active = true
  local frame = stand.frame
  if region.icon then
    local icon = Pooled(stand, "icon", function() return frame:CreateTexture(nil, "ARTWORK") end)
    Link(stand, region.icon, icon, TEXTURE)
    CopyTexture(region.icon, icon)
    -- Snapped like the row's Aura (Modern) icons (Display.SnapTexture).
    if Display.SnapTexture then Display.SnapTexture(icon, true) end
  end
  if region.cooldown then
    local cooldown = Pooled(stand, "cooldown", function() return CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate") end)
    Link(stand, region.cooldown, cooldown, COOLDOWN)
  end
  if region.text then
    local text = Pooled(stand, "text", function() return frame:CreateFontString(nil, "OVERLAY") end)
    Link(stand, region.text, text, FONT)
    CopyFont(region.text, text)
  end
  for index, sub in ipairs(region.subRegions or {}) do
    if mirrorTypes[sub.type] then
      local copy = Pooled(stand, sub.type .. index, function()
        return CreateFrame("Frame", nil, frame, sub.type == "subborder" and "BackdropTemplateWeakAuras" or nil)
      end)
      local methods = FRAME
      if sub.type == "subborder" then
        methods = {}
        for _, method in ipairs(FRAME) do methods[#methods + 1] = method end
        for _, method in ipairs(BORDER) do methods[#methods + 1] = method end
      end
      Link(stand, sub, copy, methods, sub)
      -- The glow is started and stopped by SetVisible, a plain function on the
      -- element, so it is hooked once; the copy restarts its glow when resized
      -- (the lines of a Pixel Glow are laid out for a size).
      if sub.type == "subglow" then
        copy.faGlowSource = sub
        if not sub.faStandGlowHooked then
          sub.faStandGlowHooked = true
          hooksecurefunc(sub, "SetVisible", function(self)
            local link = self.faStand
            local glowCopy = link and link.stand.active and link.stand.copies[self]
            if glowCopy and glowCopy.faGlowSource == self then MirrorGlow(glowCopy) end
          end)
        end
        if not copy.faGlowSizeHooked then
          copy.faGlowSizeHooked = true
          copy:SetScript("OnSizeChanged", function(self)
            local source = self.faGlowSource
            if source and source.faStand and source.faStand.stand.copies[source] == self then MirrorGlow(self) end
          end)
        end
      end
      if sub.text then
        local text = Pooled(stand, "subtextText" .. index, function() return copy:CreateFontString(nil, "OVERLAY") end)
        Link(stand, sub.text, text, FONT, sub)
        CopyFont(sub.text, text)
      end
      if sub.type == "subborder" and sub.GetBackdrop and copy.SetBackdrop then
        Pass(copy, "SetBackdrop", sub, "GetBackdrop")
        Pass(copy, "SetBackdropBorderColor", sub, "GetBackdropBorderColor")
        copy.faBorderSource = sub
        MatchBorderScale(sub, copy)
        if not copy.faBorderScaleHooked and copy.SetBackdrop then
          copy.faBorderScaleHooked = true
          hooksecurefunc(copy, "SetBackdrop", function(self)
            if self.faBorderSource then MatchBorderScale(self.faBorderSource, self) end
          end)
        end
      end
    end
  end
  LinkSecure(stand, region)
  local combat = InCombatLockdown()
  for _, source in ipairs(stand.sources) do
    local copy = stand.copies[source]
    if not (combat and stand.secure[source]) then
      CopyPoints(stand, source, copy)
      local okType, kind = pcall(source.GetObjectType, source)
      -- Texts size themselves to their text; only an explicit width is forwarded.
      if source.GetSize and copy.SetSize and NumPoints(source) < 2 and not (okType and kind == "FontString") then
        local ok, width, height = pcall(source.GetSize, source)
        if ok and type(width) == "number" and type(height) == "number" and not issecretvalue(width) and not issecretvalue(height) then
          Try(copy, "SetSize", width, height)
        end
      end
      Pass(copy, "SetAlpha", source, "GetAlpha")
      Pass(copy, "SetShown", source, "IsShown")
    end
  end
  if region.cooldown then CopyCooldown(stand, region.cooldown, stand.copies[region.cooldown], normal.data) end
  -- Glows are replayed once the copies are placed and sized.
  for _, source in ipairs(stand.sources) do
    local copy = stand.copies[source]
    if copy and copy.faGlowSource == source then MirrorGlow(copy) end
  end
end

local pending = {}
local releaser = CreateFrame("Frame")
releaser:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_REGEN_ENABLED")
  for stand in pairs(pending) do
    if not stand.active then Unlink(stand) end
  end
  wipe(pending)
end)

function Display.ReleaseStand(normal)
  local stand = normal and normal.stand
  if not stand then return end
  stand.active = false
  Unlink(stand)
  if next(stand.secure) then
    pending[stand] = true
    releaser:RegisterEvent("PLAYER_REGEN_ENABLED")
  end
end

function Display.RefreshStand(region)
  local normal = region.flowNormal
  if normal and normal.active and normal.stand and normal.stand.active then xpcall(function() Display.EnsureStand(region, normal) end, geterrorhandler()) end
end
