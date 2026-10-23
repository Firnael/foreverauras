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
-- A Texture element's own texture is linked like a Text element's string.
local mirrorTypes = {subtext = true, subborder = true, subglow = true, subtexture = true}

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

-- The copy takes the source's anchors, each relative frame mapped by `map`
-- (a frame it stands for, or nil for `fallback`); no anchors fill the fallback.
local function CopyPointsMapped(source, copy, map, fallback)
  pcall(copy.ClearAllPoints, copy)
  local count = NumPoints(source)
  for index = 1, count do
    local ok, point, relative, relativePoint, x, y = pcall(source.GetPoint, source, index)
    if ok and point then pcall(copy.SetPoint, copy, point, map(relative) or fallback, relativePoint, x, y) end
  end
  if count == 0 then pcall(copy.SetAllPoints, copy, fallback) end
end
local function CopyPoints(stand, source, copy)
  CopyPointsMapped(source, copy, function(value) return Map(stand, value) end, stand.frame)
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
  -- ForeverAuras: a copy drawn inside a Blizzard aura slot (CDMAuraProgress)
  -- reports a secret shown state, which cannot be tested; its pieces were
  -- hidden and shown above, which is what the scale change needs.
  local shown = copy:IsShown()
  if issecretvalue(shown) then return end
  copy:Hide()
  if shown then copy:Show() end
end

-- The copy helpers, for copies made elsewhere (the CDM slot look in
-- CDMAuraProgress.lua draws a display inside its aura slot the same way).
Display.CopyElementPoints, Display.CopyTextureLook, Display.MatchBorderScale = CopyPointsMapped, CopyTexture, MatchBorderScale
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

Display.CopyFontLook = CopyFont

-- ForeverAuras: a text's width and wrapping are set by the display from its
-- settings (SubText.lua, Text.lua), before the copy exists on first load, so
-- they were not carried over: a fixed-width label's copy was 0 wide. They
-- are set from the same settings here (the hooks forward later changes).
-- A text with automatic width is left at 0, so it keeps sizing itself to its
-- text rather than being frozen at the width measured now.
local function CopyTextSizing(copy, fixed, width, wrap)
  if fixed then
    copy:SetWidth(width or 0)
    copy:SetWordWrap(wrap ~= false)
    copy:SetNonSpaceWrap(wrap ~= false)
  else
    copy:SetWidth(0)
    copy:SetWordWrap(true)
    copy:SetNonSpaceWrap(true)
  end
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
  AddAuraAssignedAnimation = function(_, animation) animation:Play() end,
  RemoveAuraAssignedAnimation = function(_, animation) animation:Stop() end,
}
local function MirrorGlow(copy)
  local sub = copy.faGlowSource
  copy.faGlowEntry = copy.faGlowEntry or {}
  local width, height = copy:GetSize()
  -- ForeverAuras: a copy laid out by the aura container can report a secret
  -- size, which cannot be compared. The glow then takes the size of the
  -- element it mirrors, whose display is drawn off screen at its own size.
  if issecretvalue(width) or issecretvalue(height) then
    local okSize, sourceWidth, sourceHeight = pcall(sub and sub.GetSize or function() end, sub)
    width, height = nil, nil
    if okSize and type(sourceWidth) == "number" and type(sourceHeight) == "number"
      and not issecretvalue(sourceWidth) and not issecretvalue(sourceHeight) then
      width, height = sourceWidth, sourceHeight
    end
  end
  -- ForeverAuras: a copy nobody can see (its display hidden by its trigger,
  -- unloaded, or the copies hidden for the editor) carries no glow: the
  -- animations the copy plays itself would otherwise run on the hidden frame
  -- for as long as it stayed hidden. The stand frame's OnShow asks again.
  local visible = copy:IsVisible()
  if issecretvalue(visible) then visible = true end
  if not sub or not sub.glow or not visible or not (width and width >= 1 and height and height >= 1) then
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
    -- A released glow copy stops glowing; the element draws its own glow
    -- again (its SetVisible sees no active copy, Glow.lua).
    if copy.faGlowSource then
      local source = copy.faGlowSource
      copy.faGlowSource = nil
      MirrorGlow(copy)
      -- Only when the stand is released (not relinked, which mirrors again).
      if not stand.active and source.glow and source.SetVisible and not (keep and stand.secure[source]) then source:SetVisible(true) end
    end
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

-- Another aura anchored to a display drawn by a stand-in must follow the
-- stand, since the display itself is parked off screen. The chain frame
-- cannot be the anchor (it follows an aura container, which only frames made
-- from DisableUntrustedLayoutScriptsTemplate may do), so a proxy frame on
-- UIParent copies the stand's screen rectangle while the stand is active, the
-- way the Clickable auras place their buttons over a display. The rectangle
-- can be secret in combat; the proxy then keeps its last place.
local function PlaceProxy(proxy)
  local frame = proxy.standFrame
  local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
  if not ok or type(left) ~= "number" or type(bottom) ~= "number" or type(width) ~= "number" or type(height) ~= "number" then return end
  if issecretvalue(left) or issecretvalue(bottom) or issecretvalue(width) or issecretvalue(height) then return end
  local scale = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
  if proxy.placedScale ~= scale then proxy:SetScale(scale); proxy.placedScale = scale end
  if proxy.placedLeft == left and proxy.placedBottom == bottom and proxy.placedWidth == width and proxy.placedHeight == height then return end
  proxy.placedLeft, proxy.placedBottom, proxy.placedWidth, proxy.placedHeight = left, bottom, width, height
  proxy:ClearAllPoints()
  proxy:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
  proxy:SetSize(math.max(width, 1), math.max(height, 1))
end

-- ForeverAuras: the proxy stops following while the stand frame is not
-- visible (display hidden, unloaded, or its region discarded on conversion)
-- and follows again from the stand frame's OnShow; before, it ran on for the
-- session once its display had gone. It stays shown throughout: auras
-- anchored to the display are parented to it, and would vanish with it.
local function ProxyUpdate(self, elapsed)
  self.elapsed = (self.elapsed or 0) + elapsed
  if self.elapsed < 0.1 then return end
  self.elapsed = 0
  local shown = self.standFrame and self.standFrame:IsVisible()
  if not issecretvalue(shown) and not shown then self:SetScript("OnUpdate", nil); return end
  PlaceProxy(self)
end

local function EnsureProxy(stand)
  local proxy = stand.proxy
  if not proxy then
    proxy = CreateFrame("Frame", nil, UIParent)
    proxy:EnableMouse(false)
    proxy.standFrame = stand.frame
    proxy:SetScript("OnUpdate", ProxyUpdate)
    stand.proxy = proxy
  end
  proxy.standFrame = stand.frame
  proxy:SetScript("OnUpdate", ProxyUpdate)
  PlaceProxy(proxy)
  proxy:Show()
  return proxy
end

-- The frame other auras anchor to for this display: its stand's proxy while
-- the stand draws it, otherwise nil (the display's own region serves).
function Display.StandAnchor(region)
  local normal = region and region.flowNormal
  local stand = normal and normal.stand
  if stand and stand.active and stand.proxy then return stand.proxy end
  return nil
end

function Display.EnsureStand(region, normal)
  local stand = normal.stand
  if not stand then
    stand = {frame = normal.flow.start, region = region, copies = {}, sources = {}, pool = {}, secure = {}}
    normal.stand = stand
  end
  -- ForeverAuras: the chain frame was replaced after the client forbade it
  -- (FreshFrame, SecretAuraFlow.lua). The copies on the old frame can neither
  -- be moved nor measured, and may refuse to be hidden: they are let go
  -- before the ordinary unlinking below (which hides copies outright), and
  -- made again on the new frame (the sources' hooks reach copies through
  -- stand.copies, so they follow the new ones).
  if stand.frame ~= normal.flow.start then
    for _, copy in pairs(stand.pool) do
      -- ForeverAuras: a copy's mirrored glow stops with it; the glow's
      -- frames are the copy's own, so they can still be reached.
      if copy.faGlowEntry then Display.ClearElementGlow(copy.faGlowEntry) end
      pcall(copy.Hide, copy)
    end
    for _, source in ipairs(stand.sources) do
      if source.faStand and source.faStand.stand == stand then source.faStand = nil end
    end
    wipe(stand.sources); wipe(stand.copies); wipe(stand.secure)
    stand.pool = {}
    stand.frame = normal.flow.start
  end
  Unlink(stand)
  stand.active = true
  EnsureProxy(stand)
  -- The copies are hidden in the editor and shown live (PlaceNormalRegion):
  -- the mirrored Glow elements draw their own glow while the copies are
  -- hidden and stop it when the copies show (SubRegionTypes/Glow.lua).
  if not stand.frame.faGlowToggleHooked then
    stand.frame.faGlowToggleHooked = true
    local function RefreshSourceGlows(frame)
      local current = frame.faStandForGlows
      if not current then return end
      for _, source in ipairs(current.sources) do
        if source.type == "subglow" and source.glow and source.SetVisible then source:SetVisible(true) end
      end
    end
    stand.frame:HookScript("OnShow", RefreshSourceGlows)
    stand.frame:HookScript("OnHide", RefreshSourceGlows)
    -- ForeverAuras: the positioning proxy follows the stand frame's
    -- visibility (see EnsureProxy); the copies' mirrored glows are cleared
    -- or restyled by RefreshSourceGlows above (MirrorGlow).
    stand.frame:HookScript("OnShow", function(frame)
      local current = frame.faStandForGlows
      if current and current.active and current.proxy then
        current.proxy:SetScript("OnUpdate", ProxyUpdate)
        PlaceProxy(current.proxy)
      end
    end)
    stand.frame:HookScript("OnHide", function(frame)
      local current = frame.faStandForGlows
      if current and current.proxy then current.proxy:SetScript("OnUpdate", nil) end
    end)
  end
  stand.frame.faStandForGlows = stand
  if Private.ReanchorAttachedTo then Private.ReanchorAttachedTo(region.id) end
  local frame = stand.frame
  if region.icon then
    local icon = Pooled(stand, "icon", function() return frame:CreateTexture(nil, "ARTWORK") end)
    Link(stand, region.icon, icon, TEXTURE)
    CopyTexture(region.icon, icon)
    -- Pixel snapping follows the region's own icon, which the Icon display
    -- leaves unsnapped (a snapped copy rounded a 34x32 icon to a pixel less
    -- at the bottom than its unsnapped neighbours in a dynamic group).
    if region.icon.GetSnapToPixelGrid then
      Pass(icon, "SetSnapToPixelGrid", region.icon, "GetSnapToPixelGrid")
      Pass(icon, "SetTexelSnappingBias", region.icon, "GetTexelSnappingBias")
    elseif Display.SnapTexture then
      Display.SnapTexture(icon, false)
    end
  end
  if region.cooldown then
    local cooldown = Pooled(stand, "cooldown", function() return CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate") end)
    Link(stand, region.cooldown, cooldown, COOLDOWN)
  end
  -- The icon's Inner and Outer anchor areas (80% and 110% of the icon), which
  -- texts and borders may anchor to. Linked before the elements, so their
  -- copies' points resolve to these copies; unmapped, an area fell back to
  -- the icon's own box, and an Outer text sat 10% of the icon too high.
  for _, area in ipairs({"inner", "outer"}) do
    if region[area] then
      local copy = Pooled(stand, area, function() return CreateFrame("Frame", nil, frame) end)
      copy:EnableMouse(false)
      Link(stand, region[area], copy, FRAME)
    end
  end
  if region.text then
    local text = Pooled(stand, "text", function() return frame:CreateFontString(nil, "OVERLAY") end)
    Link(stand, region.text, text, FONT)
    CopyFont(region.text, text)
    local data = normal.data
    CopyTextSizing(text, data.automaticWidth == "Fixed", data.fixedWidth, data.wordWrap == "WordWrap")
  end
  -- ForeverAuras: the copies are levelled in sub element order, as
  -- Private.ApplyFrameLevel levels the display's own elements. Left at the
  -- chain frame's level plus one, every copy shared one level and a Glow
  -- (drawn in a child frame of its copy) sat above Borders listed after it.
  -- Two levels per element leave room for that child frame.
  local okLevel, baseLevel = pcall(frame.GetFrameLevel, frame)
  if not okLevel or type(baseLevel) ~= "number" or issecretvalue(baseLevel) then baseLevel = nil end
  for index, sub in ipairs(region.subRegions or {}) do
    if mirrorTypes[sub.type] then
      local copy = Pooled(stand, sub.type .. index, function()
        return CreateFrame("Frame", nil, frame, sub.type == "subborder" and "BackdropTemplateWeakAuras" or nil)
      end)
      if baseLevel then pcall(copy.SetFrameLevel, copy, baseLevel + 2 + index * 2) end
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
        -- The element's own animated glow stops while the copy draws it
        -- (SubRegionTypes/Glow.lua, SetVisible), which the element decides
        -- from the stand frame's visibility: asked again once linked.
        if sub.glow and sub.SetVisible then sub:SetVisible(true) end
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
        local element = normal.data.subRegions and normal.data.subRegions[index]
        if element and element.type == "subtext" then
          CopyTextSizing(text, element.text_automaticWidth == "Fixed", element.text_fixedWidth, element.text_wordWrap == "WordWrap")
        end
      end
      -- A Texture element draws through a TextureBase wrapper (sub.texture)
      -- around the real texture (sub.texture.texture): every change, including
      -- rotation and mirroring (texture coordinates), reaches that texture.
      if sub.type == "subtexture" and type(sub.texture) == "table" and sub.texture.texture then
        local texture = Pooled(stand, "subtextureTexture" .. index, function() return copy:CreateTexture(nil, "ARTWORK") end)
        Link(stand, sub.texture.texture, texture, TEXTURE, sub)
        CopyTexture(sub.texture.texture, texture)
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
  -- ForeverAuras: the display's alpha is applied again now that the stand
  -- frame is the gate's owner (RegionPrototype.lua, SetAlpha): the frame
  -- takes the gate, the display its asked-for alpha.
  if region.requestedAlpha ~= nil and region.SetAlpha then pcall(region.SetAlpha, region, region.requestedAlpha) end
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
  -- ForeverAuras: the gate alpha the frame carried (RegionPrototype.lua,
  -- SetAlpha) is dropped, so a later stand on this frame starts clean, and
  -- the display takes its gate back itself.
  if stand.frame then pcall(stand.frame.SetAlpha, stand.frame, 1); stand.frame.cdmGateApplied = nil end
  if stand.region.requestedAlpha ~= nil and stand.region.SetAlpha then pcall(stand.region.SetAlpha, stand.region, stand.region.requestedAlpha) end
  -- Auras anchored to the display go back to its own region.
  if stand.proxy then stand.proxy:Hide() end
  if Private.ReanchorAttachedTo then Private.ReanchorAttachedTo(stand.region.id) end
  if next(stand.secure) then
    pending[stand] = true
    releaser:RegisterEvent("PLAYER_REGEN_ENABLED")
  end
end

function Display.RefreshStand(region)
  local normal = region.flowNormal
  if normal and normal.active and normal.stand and normal.stand.active then xpcall(function() Display.EnsureStand(region, normal) end, geterrorhandler()) end
end
