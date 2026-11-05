-- Copyright (C) 2026 ForeverAuras. Part of ForeverAuras, licensed under the GNU GPL v2 (see LICENSE).
-- Modern Aura Group: a normal Group whose Aura (Modern) children grow together.
--
-- Nothing in Lua can know in combat which of these displays has an aura, so
-- the group cannot move its children like a Dynamic Group. Instead each child
-- draws from a "start" frame anchored to the end of the previous child's
-- content, and Blizzard's own frame sizes decide where that end is:
--   Aura(s) Found: the child's aura container, one icon (and spacing) wide per
--     aura shown, one pixel when empty.
--   Aura(s) Missing: a second, invisible container that is one icon wide when
--     the aura is present; it is anchored backwards, so the end moves back.
--   Always, and Total Duration = / >= lists: a fixed icon.
-- The group applies the chain at safe time; Blizzard keeps it in step in combat.
-- Grouped by unit frame or nameplate, each display's aura area for a unit is
-- attached to the previous display's area for the same unit instead
-- (RelinkFlowUnits). The group also sets sort order and limit.
--
-- Centered growth: nothing can halve a secret size, so every part above also
-- gets an invisible "shadow" copy at half its size, with the same filters and
-- unit. The shadows are chained backwards from the centre point; their far
-- end is where the visible row starts, so the row stays centred.
if not WeakAuras.IsLibsOK() then return end
local L = WeakAuras.L
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript, C_Timer = Private.TimedAPI("SecretAuraFlow")
local Display = Private.BlizzardAuraDisplay
-- ForeverAuras: the rechain queue and the load-scan hold (see QueueRechain,
-- Display.BeginFlowLoad), declared here so the preview arrangement above
-- them can honour the hold as the rechain does (issue #136).
local afterCombat, queued, loadScan = {}, {}, 0
local function Locked(frame) return Display.Locked ~= nil and Display.Locked(frame) end
local function Busy(frame)
  if Locked(frame) then return true end
  return InCombatLockdown() and frame.IsProtected ~= nil and frame:IsProtected()
end
-- ForeverAuras (dev.70): under aura restrictions a placement already made
-- with exactly these arguments is not written again: a start prewired on a
-- chained member's end (PrewireFollower) must not be rewritten once that
-- end depends on a secret (the client refuses the write); out of
-- restrictions every placement is written (the callers clear the frame
-- first). The record is the frame's own and is dropped on a refusal.
local function RestrictedNow()
  return InCombatLockdown() or (C_Secrets and C_Secrets.ShouldAurasBeSecret())
end
local function Place(frame, point, rel, relPoint, x, y)
  -- ForeverAuras (dev.72): the placement record is consulted first: a frame
  -- placed with exactly these arguments needs no write, whether or not it
  -- could take one now (a prewired start that has since become protected)
  local last = frame.faPlace
  if last and RestrictedNow() and last[1] == point and last[2] == rel and last[3] == relPoint and last[4] == (x or 0) and last[5] == (y or 0) then return true end
  if Busy(frame) then return false, "busy" end
  local ok, err = pcall(frame.SetPoint, frame, point, rel, relPoint, x, y)
  frame.faPlace = ok and {point, rel, relPoint, x or 0, y or 0} or nil
  if not ok then frame.faPlaceError = err end
  return ok, err
end
local function SetShown(frame, shown)
  if not frame or Busy(frame) or frame:IsShown() == shown then return end
  if shown then frame:Show() else frame:Hide() end
end

-- A display's own X/Y Offset (Display settings) inside a Modern Aura Group:
-- added to that display's place in the row only. The next display keeps the
-- place the row gives it, so a nudged display does not drag the rest along.
local function OwnOffset(data)
  if type(data) ~= "table" then return 0, 0 end
  local x, y = tonumber(data.xOffset) or 0, tonumber(data.yOffset) or 0
  return x, y
end
-- A chained flow's own offset, none for the row's first flow (its region's
-- place, which already carries the offset, is where the row starts) or nil.
-- Only Aura (Modern) displays take it: an ordinary display in the row keeps
-- the placement it always had (its preview does not apply offsets either).
-- Relative to the first flow's own offset: the row already starts offset by
-- that much, so a later display with the same offset (members that all
-- anchor to one frame with one offset, say) adds nothing, and only the
-- difference between its offset and the first's moves it.
-- An ordinary display's own offset counts only as the row's first offset
-- (its region's place carries it like any first display's); chained, it
-- takes none (RowOffset).
local function FlowOwnOffset(flow)
  if not flow then return 0, 0 end
  if flow.normal then return OwnOffset(flow.normal.data) end
  local data = flow.region and flow.region.blizzardAuraDisplay and flow.region.blizzardAuraDisplay.data
  return OwnOffset(data)
end
local function RowOffset(flow, first)
  if not flow or flow == first or flow.normal then return 0, 0 end
  -- A row-start helper (the end of a centred row's shadows) is not a
  -- display and carries no offset of its own.
  if not flow.region then return 0, 0 end
  local x, y = FlowOwnOffset(flow)
  local fx, fy = FlowOwnOffset(first)
  return x - fx, y - fy
end

-- A chain frame (a display's start, or its shadow start) is anchored to
-- Blizzard's aura frames, and the client can make such a frame forbidden to
-- addon code once its position depends on their secret layout. After that
-- it can be neither re-anchored nor hidden (ClearAllPoints raised "Attempt
-- to access forbidden object"), so it is left where it is, drawing nothing,
-- and a fresh frame takes its place in the chain. Its size is kept on the
-- flow (sizeKey), since a forbidden frame cannot be measured either.
-- A start frame is where a display draws from. On a scaled group a step along
-- the row is a fraction of a pixel, so the engine rounds each start to the
-- pixel grid: every icon and its pixel-perfect border then land on whole
-- pixels, and the gaps vary by a pixel instead, as in a Dynamic Group.
local function OnPixels(frame)
  if frame.SetRoundLayoutToNearestPixel then frame:SetRoundLayoutToNearestPixel(true) end
  return frame
end

local function FreshFrame(flow, key, sizeKey, region)
  local frame = flow[key]
  if not frame or not Locked(frame) then return frame end
  frame = CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate")
  frame:EnableMouse(false)
  if key == "start" then OnPixels(frame) end
  local size = flow[sizeKey]
  frame:SetSize(size and size[1] or 1, size and size[2] or 1)
  if flow.endFrame == flow[key] then flow.endFrame = frame end
  flow[key] = frame
  return frame
end

Display.flowGrowths = {RIGHT = L["Right"], LEFT = L["Left"], DOWN = L["Down"], UP = L["Up"],
  CENTER_HORIZONTAL = L["Centered Horizontal"], CENTER_VERTICAL = L["Centered Vertical"]}

-- Per growth: the corner a child's content starts from, the corner of an
-- Aura(s) Found container where the next child starts (with the pixel an
-- empty container keeps), and the axis.
local GROWTH = {
  RIGHT = {start = "TOPLEFT", listEnd = "TOPRIGHT", pixel = {-1, 0}, far = "TOPRIGHT", sign = {1, 0}},
  LEFT = {start = "TOPRIGHT", listEnd = "TOPLEFT", pixel = {1, 0}, far = "TOPLEFT", sign = {-1, 0}},
  DOWN = {start = "TOPLEFT", listEnd = "BOTTOMLEFT", pixel = {0, 1}, far = "BOTTOMLEFT", sign = {0, -1}},
  UP = {start = "BOTTOMLEFT", listEnd = "TOPLEFT", pixel = {0, -1}, far = "TOPLEFT", sign = {0, 1}},
}
-- Centered: the visible row grows right (or down); its shadows grow the other
-- way from the centre point on the first display (top middle, or left middle).
local function Centered(visible, shadow, centerPoint)
  local result = CopyTable(GROWTH[visible])
  result.visible, result.shadow, result.centerPoint = visible, GROWTH[shadow], centerPoint
  result.shadowKey = shadow   -- ForeverAuras (dev.74): the shadows' growth by name (the chain's shadow geometry, ChainBound)
  return result
end
GROWTH.CENTER_HORIZONTAL = Centered("RIGHT", "LEFT", "TOP")
GROWTH.CENTER_VERTICAL = Centered("DOWN", "UP", "LEFT")
-- ForeverAuras (cell chain, SecretAuraChain.lua): the growth table and the
-- pixel scale, shared with the chain.
Display.GROWTH = GROWTH

-- The direction a display's own aura area grows in.
function Display.VisibleGrowth(growth)
  return GROWTH[growth] and GROWTH[growth].visible or growth
end

-- The Modern Aura Group this display belongs to, or nil.
function Display.FlowGroup(data)
  local parent = data and data.parent and WeakAuras.GetData(data.parent)
  if parent and parent.regionType == "group" and parent.blizzardFlow then return parent end
end

local function GrowthKey(group)
  local growth = GROWTH[group.blizzardFlowGrowth] and group.blizzardFlowGrowth or "RIGHT"
  local mode = group.blizzardFlowFrames
  if mode ~= "UNITFRAME" and mode ~= "NAMEPLATE" then return growth end
  local selfPoint = group.selfPoint or "CENTER"
  if growth == "CENTER_HORIZONTAL" then
    if selfPoint:find("LEFT") then return "RIGHT" end
    if selfPoint:find("RIGHT") then return "LEFT" end
  elseif growth == "CENTER_VERTICAL" then
    if selfPoint:find("TOP") then return "DOWN" end
    if selfPoint:find("BOTTOM") then return "UP" end
  end
  return growth
end
Display.FlowGrowthKey = GrowthKey

-- Screen pixels per UI unit where a region is drawn, or nil when unknown.
local function PixelsPerUnit(region)
  local factor = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor()
  local scale = region and region.GetEffectiveScale and region:GetEffectiveScale()
  if type(factor) ~= "number" or factor <= 0 or type(scale) ~= "number" or issecretvalue(scale) or scale <= 0 then return nil end
  return scale / factor
end

Display.PixelsPerUnit = PixelsPerUnit

-- The spacing the row uses after a display of the given size along it: the
-- group's spacing, made a whole number of screen pixels on top of a whole
-- pixel icon (the icon boxes round to pixels). On a scaled group a step of
-- 37 units is 44.4 pixels, which would round to 44 or 45 depending on where
-- the row sits; this way every gap comes out the same, as in a Dynamic Group.
function Display.FlowSpacing(group, region, size)
  local spacing = tonumber(group.blizzardFlowSpacing) or 2
  local px = PixelsPerUnit(region)
  if not px or type(size) ~= "number" then return spacing end
  local icon = math.floor(size * px + 0.5)
  local gap = math.floor(spacing * px + 0.5)
  return (icon + gap) / px - size
end

-- Half a step, in whole pixels where the scale is known.
function Display.FlowHalf(region, step)
  local px = PixelsPerUnit(region)
  if not px then return math.floor(step / 2) end
  return math.floor(step * px / 2 + 0.0001) / px
end

-- The offset that puts a frame's start corner on a whole screen pixel. The
-- row's origin is a display's own frame, whose place is readable; every step
-- after it is a whole number of pixels, so this one nudge grids the whole row.
local function SnapOffset(frame, point)
  local px = PixelsPerUnit(frame)
  if not px or not frame or not frame.GetLeft then return 0, 0 end
  local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
  -- Each checked by name: a frame not laid out yet returns nil, and a nil
  -- ends ipairs before the values after it are seen.
  for _, value in pairs({left = left, right = right, top = top, bottom = bottom}) do
    if type(value) ~= "number" or issecretvalue(value) then return 0, 0 end
  end
  if left == nil or right == nil or top == nil or bottom == nil then return 0, 0 end
  point = point or "TOPLEFT"
  local x = point:find("LEFT") and left or point:find("RIGHT") and right or (left + right) / 2
  local y = point:find("TOP") and top or point:find("BOTTOM") and bottom or (top + bottom) / 2
  x, y = x * px, y * px
  return (math.floor(x + 0.5) - x) / px, (math.floor(y + 0.5) - y) / px
end

function Display.FlowGrowth(data)
  local group = Display.FlowGroup(data)
  if not group then return end
  local g = GROWTH[GrowthKey(group)]
  local width, height = Display.Dimensions(data)
  local entry = Private.regions[data.id]
  local region = entry and entry.region
  return GrowthKey(group), Display.FlowSpacing(group, region, (g.sign[1] ~= 0) and width or height)
end

Display.flowFrameModes = {SCREEN = L["Screen"], UNITFRAME = L["Unit Frames"], NAMEPLATE = L["Nameplates"]}

-- "UNITFRAME" or "NAMEPLATE" when the group places its displays on each
-- unit's frame, else nil.
function Display.FlowFrameMode(data)
  local group = Display.FlowGroup(data)
  local mode = group and group.blizzardFlowFrames
  if mode == "UNITFRAME" or mode == "NAMEPLATE" then return mode end
end

Display.flowSortModes = {
  none = L["None"], ascending = L["Ascending"], descending = L["Descending"],
  expiration = L["Remaining time (Blizzard priority)"], name = L["Name"], namePriority = L["Name (Blizzard priority)"],
  blizzard = L["Blizzard default"], important = L["Importance only"], bigDefensive = L["Big defensives"], applied = L["Order applied"],
}
Display.flowSortOrder = {"ascending", "descending", "expiration", "name", "namePriority", "blizzard", "important", "bigDefensive", "applied", "none"}
-- ForeverAuras: the Sort list offers the orders that differ on this client.
-- The "Blizzard priority" orders put the game's important and big-defensive
-- auras first, and that classification is empty on WoW Forever (Divine
-- Shield, Shield Wall and Recklessness all unflagged, forever-bugs #99), so
-- they sort like their plain twins; a group that already uses one keeps it
-- and still sees it in the list.
Display.flowSortShown = {"ascending", "descending", "name", "blizzard", "important", "applied", "none"}
-- The list's entries and their order; the order names only entries that are
-- in the list (a named entry that is not in it draws as an empty line).
function Display.FlowSortValues(group)
  local values, order, current = {}, {}, Display.FlowSortMode(group)
  for _, mode in ipairs(Display.flowSortOrder) do
    if tContains(Display.flowSortShown, mode) or mode == current then
      values[mode] = Display.flowSortModes[mode]
      order[#order + 1] = mode
    end
  end
  return values, order
end
local sortModeMethods = {
  none = "Default", ascending = "ExpirationOnly", descending = "ExpirationOnly", expiration = "Expiration",
  name = "NameOnly", namePriority = "Name", blizzard = "Default", important = "ImportantOnly",
  bigDefensive = "BigDefensive", applied = "AuraInstanceIDOnly",
}
local legacySortModes = {
  Expiration = "expiration", Name = "namePriority", NameOnly = "name", ImportantOnly = "important",
  BigDefensive = "bigDefensive", AuraInstanceIDOnly = "applied",
}

function Display.FlowSortMode(group)
  if not group then return "none" end
  if Display.flowSortModes[group.blizzardFlowSortMode] then return group.blizzardFlowSortMode end
  local legacy = group.blizzardFlowSort
  if legacy == "ExpirationOnly" then return group.blizzardFlowReverse and "descending" or "ascending" end
  return legacySortModes[legacy] or "none"
end

-- The group's sort order for every display in it, else the trigger's own.
function Display.SortOrder(data, trigger)
  local group = Display.FlowGroup(data)
  local method, reverse
  if group then
    local mode = Display.FlowSortMode(group)
    method = sortModeMethods[mode]
    reverse = mode == "descending"
  else
    method, reverse = trigger.sortMethod, trigger.sortReverse
  end
  -- Blizzard classification is not applied, so its sort has no meaning here.
  if not Display.sortMethods[method or "Default"] or method == "UnitFrameDebuff" then method = "Default" end
  return AuraContainerSortMethod[method or "Default"],
    reverse and AuraContainerSortDirection.Reverse or AuraContainerSortDirection.Normal
end

-- The anchor type that decides where a display's auras go: its Modern Aura
-- Group's mode when it is in one (the group is authoritative), else its own.
function Display.FrameAnchorType(data)
  if Display.FlowGroup(data) then return Display.FlowFrameMode(data) or "SCREEN" end
  return data.anchorFrameType
end

-- The group's limit of auras per display (20 without a limit), or nil.
function Display.FlowLimit(data)
  local group = Display.FlowGroup(data)
  if not group then return end
  if not group.blizzardFlowUseLimit then return 20 end
  return math.max(1, math.floor(tonumber(group.blizzardFlowLimit) or 5))
end

-- Why this display cannot join its Modern Aura Group's growth, or nil.
function Display.FlowProblem(data, trigger)
  if not Display.FlowGroup(data) then return end
  if not Display.missingTypes[data.regionType] then return L["In a Modern Aura Group, use an Icon, Progress Bar, Progress Texture, Texture or Text display."] end
  if Display.RemainingWindow(trigger) and Display.FlowGrid(Display.FlowGroup(data)) then return L["In a Grid, Remaining Time is not available."] end
  local mode = Display.FlowFrameMode(data)
  if mode then
    if Display.IsSingle(trigger) and not Display.NeedsMissing(trigger) then return L["Grouped by unit frame or nameplate, use Show On: Aura(s) Found."] end
    if mode == "NAMEPLATE" and trigger.unit ~= "nameplate" then return L["Grouped by nameplate, choose the Nameplate unit."] end
    if mode == "UNITFRAME" and trigger.unit == "nameplate" then return L["Grouped by unit frame, choose a unit other than Nameplate."] end
  end
end

-- Aura containers in a Modern Aura Group depend on other displays' secret sizes,
-- so they also opt out of untrusted layout scripts, like every frame anchored
-- to an aura container must. Returns the container and whether it opted out.
-- Every native container made here remembers the last value passed to its
-- SetEnabled (faEnabled; nil until the first call). Enabling a container makes
-- Blizzard evaluate and lay out all of its auras again on the client side, so
-- RefreshUnits (BlizzardAuraDisplay.lua) skips an enable, and the refresh that
-- follows it, when nothing about the container changed. The counts feed the
-- /fa phitch report.
local function TrackEnabled(container)
  local setEnabled = container.SetEnabled
  container.SetEnabled = function(self, enabled)
    enabled = enabled and true or false
    -- (dev.94, diagnostic) a chained member's list disabled: where from (with "/fa cells debug on")
    if not enabled and self.faEnabled == true and self.faReportDisable and type(ForeverAurasSaved) == "table" and ForeverAurasSaved.rowCellsDebug and Display.BuildReport then
      local okS, stack = pcall(debugstack, 2, 5, 0)
      Display.BuildReport(("%s: list disabled by %s"):format(tostring(self.faReportDisable), okS and tostring(stack):gsub("\n", " | ") or "?"))
    end
    self.faEnabled = enabled
    if Private.HitchCount then Private.HitchCount(enabled and "container enable" or "container disable") end
    return setEnabled(self, enabled)
  end
  return container
end

function Display.CreateAuraContainer(parent, data, optOut)
  if optOut or Display.FlowGroup(data) then
    local ok, container = pcall(CreateFrame, "AuraContainer", nil, parent,
      "CustomAuraContainerTemplate, DisableUntrustedLayoutScriptsTemplate")
    if ok and container then
      -- ForeverAuras (combat-reload probe): noted at allocation (BlizzardAuraDisplay.lua, NoteAllocation).
      if Display.NoteAllocation then Display.NoteAllocation(parent, container) end
      return TrackEnabled(container), true
    end
  end
  local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
  if Display.NoteAllocation then Display.NoteAllocation(parent, container) end
  return TrackEnabled(container), false
end

-- Anchors a container to a Modern Aura Group start frame; falls back to the
-- region when Blizzard refuses the anchor.
function Display.AnchorToContent(container, point, region, relativePoint, x, y)
  -- ForeverAuras (independent carriers): the container is pinned to the
  -- group's frame instead; its artwork follows the row through its boxes
  -- (PlaceCarrierBox) and its end through TranslateEnd (SetFlowEnd).
  local native = region.blizzardAuraDisplay
  -- ForeverAuras (cell chain): a chained list's container is pinned too; its
  -- artwork follows the row through its chain, not through the carriers.
  local chained = native and native.data and Display.FlowChain ~= nil and Display.FlowChain(native.data) ~= nil
  if native and native.data and (chained or Display.FlowIndependent(native.data)) then
    local pin = Display.CarrierPin(native.data)
    local ok, err = false, "no group frame"
    if pin then ok, err = Place(container, point, pin, "TOPLEFT", 0, 0) end
    if ok then
      if native.flow then native.flow.carrierPinned, native.flow.carrierPinError = true, nil end
      return true
    end
    -- The refused operation is kept for the end's report (dev.19 review).
    if native.flow then native.flow.carrierPinned, native.flow.carrierPinError = false, "pin: " .. tostring(err or "locked") end
  end
  local anchor = Display.ContentAnchor(region)
  local refused
  if anchor ~= region then
    if Place(container, point, anchor, relativePoint, x or 0, y or 0) then return true end
    refused = container.faPlaceError or "busy"
  end
  if Busy(container) then return false end
  -- ForeverAuras (dev.87, Dan's D after a combat reload; Astra's dev.85 review P1): under restrictions nothing
  -- is cleared before a write that may be refused (a container left with no anchors has no place and draws
  -- nothing: D's container, "left nil"); the fallback is written under protection and a refused content
  -- placement is said. (dev.88: a display whose content IS its region - an ordinary display - takes this
  -- write as its ordinary anchor, as before, and reports nothing.)
  if RestrictedNow() then
    local okF, errF = pcall(container.SetPoint, container, point, region, relativePoint, x or 0, y or 0)
    if refused and Display.BuildReport and native and native.data then
      Display.BuildReport(("%s: its container could not be placed on its content (%s)%s"):format(tostring(native.data.id), tostring(refused),
        okF and "; on the region instead" or ("; nor on the region: " .. tostring(errF))))
    end
    return anchor == region and okF
  end
  container:ClearAllPoints()
  container:SetPoint(point, region, relativePoint, x or 0, y or 0)
  return anchor == region
end

-- ForeverAuras (dev.70, Astra's dev.69 handoff): before a chained member's
-- records are bound (PrepareChain), the NEXT member's start frame is placed
-- on this member's prewired end, with the arguments RechainFlow will use for
-- it (so RechainFlow's own pass under restrictions skips the write: Place).
-- Only a group-owned row has chained members. The next member's flow is
-- made here if it does not exist yet (its own Apply comes later and keeps
-- the prewired place: EnsureFlowStart).
-- ForeverAuras (dev.72, Astra's dev.70 review): the members of a row that
-- take part in it are the LIVE ones: a member whose build is queued (a fresh
-- combat load has every member queued before any native state exists), or
-- one that is shown and built or being built. An unloaded or hidden member
-- that is not being built is not part of the row (RechainFlow skips it too),
-- so the next live member, not the next configured child, is prewired and
-- waited for. Returns the region, its data and its native state (which may
-- not exist yet).
-- ForeverAuras (dev.74, Astra's dev.73 review): an ordinary display copied
-- into the row (a text or icon with a stand, LinkFlowNormal) is a live
-- member too, in its place: it is prewired on the chained member before it
-- as the row's pass would place it, so that pass writes nothing new to a
-- bound end. One that leads the row at its own home (a bar, no stand) is not
-- a follower and is not listed. Returns region, data, native state (nil for
-- an ordinary member) and the ordinary member's flow state.
local function LiveMember(id, group)
  local entry = Private.regions[id]
  local region = entry and entry.region
  if not region then return nil end
  local d = WeakAuras.GetData(id)
  if not d then return nil end
  local native = region.blizzardAuraDisplay
  if Display.IsBuildPending and Display.IsBuildPending(region) then return region, d, native end
  if native and (native.active or native.applying) and region:IsShown() then return region, d, native end
  local normal = region.flowNormal
  if normal and normal.active and normal.flow and normal.flow.start and normal.stand and normal.stand.active
    and (not group or Display.FlowNormal(normal.data) == group) and region:IsShown() then return region, d, nil, normal end
  return nil
end
function Display.NextLiveMember(group, id)
  local order = Display.FlowOrder(group)
  local after = false
  for _, member in ipairs(order) do
    if after then
      local r, d, native, normal = LiveMember(member, group)
      if r then return r, d, native, member, normal end
    elseif member == id then after = true end
  end
  return nil
end
local prewireDepth = 0
function Display.PrewireFollower(region, data, endOwner)
  local group = Display.FlowGroup(data)
  if not group or not Display.FlowGroupOwned(group) then return true end
  local native = region.blizzardAuraDisplay
  -- (dev.78) the end the follower sits on: the member's chain, or its measurement chain (endOwner)
  local flow = endOwner and endOwner.flow or native and native.flow
  if not (flow and flow.chainEnd and flow.chainEndWired) then return false, "no prewired end" end
  local endFrame = endOwner and endOwner.out or flow.chainEnd
  local endPoint = endOwner and endOwner.outCorner or flow.chainCorner
  local nextRegion, nextData, nextNative, nextID, nextNormal = Display.NextLiveMember(group, data.id)
  if not nextRegion then return true end
  local nextFlow
  if nextNormal then
    -- (dev.74) an ordinary copied member: its own start, as the row's pass places it
    nextFlow = nextNormal.flow
  else
    -- (dev.72) a member queued at a fresh load has no native state yet: it is
    -- made here, owned by that member (its own Apply takes it over as is)
    if not nextNative then
      nextNative = {instances = {}, data = nextData}
      nextRegion.blizzardAuraDisplay = nextNative
    end
    nextFlow = nextNative.flow
    if not (nextFlow and nextFlow.start) then Display.EnsureFlowStart(nextRegion, nextData); nextFlow = nextNative.flow end
  end
  if not (nextFlow and nextFlow.start) then return true end
  local g = GROWTH[GrowthKey(group)] or GROWTH.RIGHT
  local px, py = OwnOffset(data)
  local point, rel, relPoint, x, y = g.start, endFrame, endPoint or g.start, 0 - px, 0 - py
  local last = nextFlow.start.faPlace
  if not (last and last[1] == point and last[2] == rel and last[3] == relPoint and last[4] == x and last[5] == y) then
    if not RestrictedNow() then nextFlow.start:ClearAllPoints() end
    local ok = Place(nextFlow.start, point, rel, relPoint, x, y)
    if not ok then return false, "the next member's start could not be prewired: " .. tostring(nextFlow.start.faPlaceError) end
  end
  nextFlow.startPrewired = true
  -- and the next member's own preparation, if it is chained: its content
  -- hangs from its start, its spine from its content, and all of it must be
  -- in place before THIS member's records bind (PrepareChain recurses along
  -- the row; a member already prepared is a no-op)
  if not nextNormal and Display.FlowChain and Display.FlowChain(nextData) and Display.PrepareChain then
    -- ForeverAuras (dev.75 watchdog): the preparation recurses along the
    -- row; a depth past any row's length is a loop, reported with its stack
    -- rather than a frozen client
    prewireDepth = prewireDepth + 1
    if prewireDepth > 64 then prewireDepth = 0; error("ForeverAuras watchdog: the row's preparation recursed past 64 members at " .. tostring(nextID)) end
    local okN, whyN = Display.PrepareChain(nextRegion, nextData, nextNative)
    prewireDepth = prewireDepth - 1
    if not okN then return false, tostring(nextID) .. ": " .. tostring(whyN) end
  end
  return true
end

-- ForeverAuras (dev.70): the member of this display's row that must be
-- whole before this (chained) display is built under restrictions: the next
-- member whose build is still pending, or the next chained member whose
-- records are not all made yet; nil when none (this display may be built
-- now). Only chained displays wait; ordinary members (Missing, Always) are
-- built as they come.
function Display.ChainOrderBlocker(region, data, pendingTable)
  if not ((Display.FlowChain and Display.FlowChain(data)) or (Display.MeasuresEnd and Display.MeasuresEnd(data))) then return nil end
  local group = Display.FlowGroup(data)
  if not group or not Display.FlowGroupOwned(group) then return nil end
  -- (dev.72) over the live members only, and a queued member blocks whether
  -- or not it has native state yet (a fresh combat load has none). Every
  -- queued live member after this one blocks, ordinary ones too: the chain
  -- pass that commits this member places the whole live row after it, and a
  -- member still queued then would be left out of that pass, so the member
  -- after it would be anchored afresh to this member's end, which the
  -- client refuses once the records are bound. Ordinary members never wait,
  -- so they are built first and the wait is bounded.
  local order = Display.FlowOrder(group)
  local after = false
  for _, id in ipairs(order) do
    if after then
      local r, d, native, normal = LiveMember(id, group)
      if r and not normal then
        if pendingTable[r] then return id end
        if Display.FlowChain(d) then
          if not native or #native.instances == 0 then return id end
          local instance = native.instances[1]
          if instance and #(instance.buttons or {}) < (Display.CHAIN_RECORDS or 10) then return id end
        elseif Display.MeasuresEnd and Display.MeasuresEnd(d) then
          -- (dev.78) a member whose end is a measurement chain is whole when that chain is
          local mc = native and native.flow and native.flow.measureChain
          if not (mc and #mc.buttons >= (Display.CHAIN_RECORDS or 10)) then return id end
        end
      end
    elseif id == data.id then after = true end
  end
  return nil
end

-- ForeverAuras: row layout ("Use old row layout", Modern Aura Group Settings). A group-owned row
-- ("group") starts at the group's own anchor point, as a Dynamic Group's
-- children start at the group; a member's own X/Y Offset moves that
-- member's content only (its content frame, FlowContent), never the row.
-- In both modes the ordinary displays that cannot be copied (bars and the
-- like) lead the row: a frame placed from a secret-length container must opt
-- out of untrusted layout scripts, which a display's own frames do not, and
-- a Centered row starts a secret distance back. The legacy row (nil) starts
-- at the first display's own anchor and takes offsets relative to the first
-- display. Imported groups keep the legacy row; new Modern Aura Groups get
-- the group-owned one.
function Display.FlowGroupOwned(group)
  return group ~= nil and group.blizzardFlowOrigin == "group"
end

-- The frame and point a group-owned row starts from: the group's region at
-- its own anchor point (its selfPoint corner sits on the anchor; the frame's
-- size changes around it, as a Dynamic Group's does).
local function RowOrigin(group)
  local entry = Private.regions[group.id]
  return entry and entry.region, group.selfPoint or "CENTER"
end

---------------------------------------------------------------------------- independent carriers (row cells)
-- Supported group-owned rows use independent carriers by default. An absent
-- group setting and the older "independent" value both enable them; explicit
-- false is the group's emergency override. A Found list's native container
-- (its "carrier")
-- is pinned to the group's own frame, a place no secret measurement ever
-- moves, and only the artwork follows the row: each button's box is placed at
--   member start + (button corner - carrier corner)
-- and the member's end at
--   member start + (list end - carrier corner)
-- by two helper frames per point that the client's anchor solver resolves
-- (Translate below): nothing in Lua reads a native position. The carrier then
-- never hangs from another member's secret measurement, which is what left
-- buttons the client added in combat unbuildable (FlowOrder's workaround).
-- Grid, legacy row origins, Group by Frame and multi-unit members retain their
-- existing layouts. Missing and gated members use their own supported paths.
-- The supported unit tokens have one container per display, so the
-- padding (CarrierPadding) can count one list per member. A row member of
-- any other unit (party, raid, boss, arena, nameplate, group) lays out one
-- list per unit ahead of the next member, which that bound does not cover,
-- so such a group keeps its existing layout as a whole.
local SINGLE_UNITS = {player = true, target = true, focus = true, pet = true, targettarget = true, focustarget = true}
local function SingleUnitMember(child)
  local trigger = child and Display.GetTrigger(child)
  if not trigger then return true end -- an ordinary display, or no trigger: one place in the row
  return SINGLE_UNITS[trigger.unit] == true
end
function Display.FlowIndependentGroup(group)
  if not group then return false end
  if not Display.FlowGroupOwned(group) or Display.FlowGrid(group) then return false end
  if group.blizzardFlowFrames == "UNITFRAME" or group.blizzardFlowFrames == "NAMEPLATE" then return false end
  -- ForeverAuras (dev.74): a Centered row is taken too: its members' shadows
  -- (a chained member's shadow chain among them, EnsureChainShadow) run back
  -- from the centre as in the legacy row, and the visible row starts at
  -- their end (RechainFlow).
  local g = GROWTH[GrowthKey(group)]
  if not g then return false end
  for _, childID in ipairs(group.controlledChildren or {}) do
    if not SingleUnitMember(WeakAuras.GetData(childID)) then return false end
  end
  return true
end

-- The same eligibility decision with its reason for the editor. Historical
-- experiment switches are ignored; Grid or legacy origin is "off".
-- Frame anchoring and multi-unit members keep their existing explanations.
function Display.FlowIndependentGroupProblem(group)
  if not group then return "off" end
  if not Display.FlowGroupOwned(group) or Display.FlowGrid(group) then return "off" end
  if group.blizzardFlowFrames == "UNITFRAME" or group.blizzardFlowFrames == "NAMEPLATE" then return "frame" end
  local g = GROWTH[GrowthKey(group)]
  if not g then return "growth" end   -- (dev.74) Centered is taken: see FlowIndependentGroup
  for _, childID in ipairs(group.controlledChildren or {}) do
    if not SingleUnitMember(WeakAuras.GetData(childID)) then return "unit" end
  end
end

function Display.FlowIndependent(data)
  local group = Display.FlowGroup(data)
  if not Display.FlowIndependentGroup(group) then return false end
  if Display.FlowFrameMode(data) then return false end
  if Display.IconsPerRow and Display.IconsPerRow(data) then return false end
  local trigger = Display.GetTrigger(data)
  if not trigger or Display.ShowOn(trigger) ~= "showOnActive" or Display.UsesGate(data) then return false end
  if Display.RemainingRange and Display.RemainingRange(trigger) then return false end
  return SingleUnitMember(data)
end

-- The frame a carrier is pinned to: the group's own region (non-secret).
function Display.CarrierPin(data)
  local group = Display.FlowGroup(data)
  local region = group and RowOrigin(group)
  return region
end

-- The padding M of the translation helpers, from settings only: both helper
-- sizes stay positive while M exceeds every distance a member start or a
-- native corner can be from the pin, in either direction; the whole
-- configured membership counts (a row's Limit only clips), with every
-- member's own offset. Recomputed whenever a member's end is recorded.
function Display.CarrierPadding(group)
  local total = 0
  for _, childID in ipairs(group and group.controlledChildren or {}) do
    local child = WeakAuras.GetData(childID)
    if child then
      local okD, w, h = pcall(Display.Dimensions, child)
      local size = okD and math.max(tonumber(w) or 0, tonumber(h) or 0, 1) or 64
      local okM, max = pcall(Display.MaxAuras, child)
      local count = math.max(1, okM and tonumber(max) or 1)
      local okS, _, spacing = pcall(Display.FlowGrowth, child)
      spacing = okS and math.abs(tonumber(spacing) or 0) or 0
      total = total + count * (size + spacing + 1) + math.abs(tonumber(child.xOffset) or 0) + math.abs(tonumber(child.yOffset) or 0)
    end
  end
  return 2 * total + 64
end

-- The helpers carry NO explicit size: a frame with one takes its width and
-- height from it, and only opposite-corner anchors (H's TOPLEFT/BOTTOMRIGHT)
-- override that; P's TOPLEFT + CENTER pair does not, so a sized P stayed
-- 1x1 and every output landed on one point up-left of the pin (dev.25 trace,
-- plain control: "P 1.0 x 1.0 (expected 162.0 x 240.0)"). The sizes of H and
-- P come from their anchors alone.
local function CarrierFrames(parent)
  local frames = {}
  for _, key in ipairs({"h", "p"}) do
    local frame = CreateFrame("Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
    frame:EnableMouse(false)
    frames[key] = frame
  end
  return frames
end

-- Places "out" so that its outPoint corner is at startPoint of startFrame plus
-- (nativePoint of nativeFrame minus the pin's TOPLEFT), through the helpers:
--   H: TOPLEFT = S, BOTTOMRIGHT = B + (M, -M)      so H.CENTER = (S + B + M) / 2
--   P: TOPLEFT = R, CENTER = H.CENTER             so P.BOTTOMRIGHT = S + B - R + M
--   out: outPoint = P.BOTTOMRIGHT + (-M, M)        = S + (B - R)
-- Returns true, or false, the operation that failed and the client's error
-- (a locked frame is "locked", not a refusal), so a native refusal can be
-- named exactly (dev.18 review). Every write is guarded.
local function Translate(frames, startFrame, startPoint, nativeFrame, nativePoint, pin, M, out, outPoint)
  local H, P = frames.h, frames.p
  for _, f in ipairs({H, P, out}) do
    if Busy(f) then return false, "locked", f == out and "box" or f == H and "helper H" or "helper P" end
  end
  -- ForeverAuras (dev.84, Dan's combat freeze): the TARGETS are checked before
  -- anything is cleared. The steps below clear H, P and out first and anchor
  -- them again; an anchor to a forbidden target (a start that depends on a
  -- bound end) is refused, and the three frames were then left with no
  -- anchors at all while the row still hung from out (the next shadow's
  -- start, the visible row's start): an unresolved dependency the client's
  -- layout walk revisits through every duplicate entry until it hangs (the
  -- same walk as the dev.77 import freezes). Nothing is cleared that cannot
  -- be anchored again.
  for _, pair in ipairs({{startFrame, "the member's start"}, {nativeFrame, "the native corner"}, {pin, "the pin"}}) do
    if Locked(pair[1]) then return false, "a forbidden target", pair[2] .. " is forbidden (it depends on a bound end); nothing cleared" end
  end
  -- (dev.89, Astra's dev.88 review P1) non-destructive: each anchor is written on the point it already has
  -- (replaced in one write); nothing is cleared first, so a refusal at any step leaves every frame with the
  -- anchors it had on the points not yet written - all resolvable, nothing to restore. A frame that carries
  -- a point of another name (the output's corner changed with the row's growth) is cleared first, out of
  -- restrictions only; under them it is refused and the caller keeps its old construction.
  do
    local wanted = {[H] = {TOPLEFT = true, BOTTOMRIGHT = true}, [P] = {TOPLEFT = true, CENTER = true}, [out] = {[outPoint] = true}}
    for _, f in ipairs({H, P, out}) do
      -- (a frame whose points cannot be read is written as it is: the writes below replace the points they name)
      local okN, n = pcall(function() return f:GetNumPoints() end)
      local stale = false
      -- A successful API call can still return secret values. They must not
      -- drive a loop or become a table key. Unknown points are left intact;
      -- the guarded writes below replace only the known points we own.
      local count = okN and not issecretvalue(n) and type(n) == "number" and n or 0
      for i = 1, count do
        local okP, point = pcall(function() return f:GetPoint(i) end)
        if okP and not issecretvalue(point) and type(point) == "string" and not wanted[f][point] then stale = true end
      end
      if stale then
        if RestrictedNow() then return false, "another corner", (f == out and "the output" or "a helper") .. " carries another point under restrictions; nothing written" end
        local okC, errC = pcall(f.ClearAllPoints, f)
        if not okC then return false, "clear", tostring(errC) end
      end
    end
  end
  local steps = {
    {"H to the member's start", function() H:SetPoint("TOPLEFT", startFrame, startPoint, 0, 0) end},
    {"H to the native corner", function() H:SetPoint("BOTTOMRIGHT", nativeFrame, nativePoint, M, -M) end},
    {"P to the pin", function() P:SetPoint("TOPLEFT", pin, "TOPLEFT", 0, 0) end},
    {"P centred on H", function() P:SetPoint("CENTER", H, "CENTER", 0, 0) end},
    {"output to P", function() out:SetPoint(outPoint, P, "BOTTOMRIGHT", -M, M) end},
  }
  for _, step in ipairs(steps) do
    local ok, err = pcall(step[2])
    if not ok then return false, step[1], tostring(err) end
  end
  return true
end

Display.TranslatePoint = Translate   -- ForeverAuras (dev.79): a measurement chain's end translated into the row (SecretAuraChain.lua)
-- The padding a member's boxes and end use: computed once per member per
-- layout (TranslateEnd) and kept on the flow, so a button's placement does
-- not scan the membership again.
local function CarrierM(flow, data)
  if not flow.carrierM then flow.carrierM = Display.CarrierPadding(Display.FlowGroup(data)) end
  return flow.carrierM
end

-- A list button's artwork box in an independent-carrier row: made with the
-- button (BuildButton, withBox) and placed here, inside the client's
-- initializeFrame and again by every layout (TranslateEnd), at the member's
-- content corner plus the button's own corner offset inside its carrier.
-- The placement is recorded as complete only when every write succeeded,
-- with the references it was made for (content frame, pin, corner, padding,
-- size): a later call with the same references and a complete placement
-- writes nothing (a locked, finished box is kept); any difference, or an
-- incomplete placement, is placed again. Returns true, or false and
-- "operation: error" (dev.18 review).
function Display.PlaceCarrierBox(native, region, data)
  local owner = region.blizzardAuraDisplay
  local flow = owner and owner.flow
  if not flow or not flow.content or not flow.growth then return false, "no row content frame" end
  if not native.box then return false, "no box" end
  local pin = Display.CarrierPin(data)
  if not pin then return false, "no group frame" end
  local g = flow.growth
  local M = CarrierM(flow, data)
  local width, height = Display.Dimensions(data)
  local placed = native.carrierPlaced
  if placed and placed.complete and placed.content == flow.content and placed.pin == pin and placed.start == g.start
    and placed.M == M and placed.width == width and placed.height == height and placed.box == native.box then
    return true
  end
  native.carrierPlaced = nil
  if not native.carrier then
    local ok, frames = pcall(CarrierFrames, native.button)
    if not ok then native.carrierFailure = {op = "helpers", err = tostring(frames)}; return false, "helpers: " .. tostring(frames) end
    native.carrier = frames
  end
  local okSize, errSize = pcall(native.box.SetSize, native.box, width, height)
  if not okSize then native.carrierFailure = {op = "box size", err = tostring(errSize)}; return false, "box size: " .. tostring(errSize) end
  local ok, op, err = Translate(native.carrier, flow.content, g.start, native.button, g.start, pin, M, native.box, g.start)
  if not ok then
    native.carrierFailure = {op = op, err = err}
    return false, tostring(op) .. ": " .. tostring(err)
  end
  native.carrierFailure = nil
  native.carrierPlaced = {complete = true, content = flow.content, pin = pin, start = g.start, M = M, width = width, height = height, box = native.box}
  return true
end

-- Every box of the member placed (or left as it is when complete and
-- current); returns the number of failures and the first failure's text.
-- Every box of the member placed (or left as it is when complete and
-- current). A failure is counted against its instance's build (NoteSlotFailure:
-- a probe build's finishing or late styling then rejects the build, as a
-- refused measurement does) and the display's paced re-apply is requested.
-- Returns the number of failures and the first failure's text.
local function PlaceCarrierBoxes(region, data)
  local native = region.blizzardAuraDisplay
  local failures, first = 0, nil
  for _, instance in ipairs(native and native.instances or {}) do
    for _, button in ipairs(instance.buttons or {}) do
      if button.box then
        local ok, why = Display.PlaceCarrierBox(button, region, data)
        if not ok then
          failures = failures + 1
          first = first or why
          if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "carrier box", why) end
        end
      end
    end
  end
  if failures > 0 and Display.NotePendingRelayout then Display.NotePendingRelayout(region) end
  -- ForeverAuras (dev.31 diagnostics): the build history notes each pass.
  if Display.NoteCarrierEvent then Display.NoteCarrierEvent(region, "boxes", ("%d failed"):format(failures)) end
  return failures, first
end

-- What the editor says about the experiment on this display, from the
-- CURRENT state: the boxes' recorded failures (so a late callback's refusal
-- shows at once, not after the next layout) and the end's problem. Called
-- by the row layout (SetFlowEnd) and by a late button's placement
-- (BlizzardAuraDisplay.lua, Create); cleared by both when nothing is wrong.
local function ClearMeasureOutputWarning(data)
  if data and data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then
    Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_row_measure", nil, nil)
  end
end
function Display.PublishCarrierWarnings(region, data, pending)
  if not Display.MeasuresEnd or not Display.MeasuresEnd(data) then ClearMeasureOutputWarning(data) end
  local native = region.blizzardAuraDisplay
  local flow = native and native.flow
  if not flow then return end
  local failures, first = 0, nil
  -- Outside the experiment nothing of it is reported, whatever old records
  -- the buttons still carry (their containers are made again on the change).
  local independent = Display.FlowIndependent(data)
  if not independent then flow.carrierProblem = nil end
  local seen = {}
  local function Note(button)
    if seen[button] then return end
    seen[button] = true
    if button.carrierFailure then
      failures = failures + 1
      first = first or (tostring(button.carrierFailure.op) .. ": " .. tostring(button.carrierFailure.err))
    end
  end
  for _, instance in ipairs(independent and native.instances or {}) do
    for _, button in ipairs(instance.buttons or {}) do Note(button) end
  end
  -- A record still being made (the client's callback has not returned it
  -- to its list yet) is counted with the rest (dev.20 review).
  if independent and pending then Note(pending) end
  flow.carrierBoxProblem = failures > 0 and (L["%d button(s): %s"]):format(failures, tostring(first)) or nil
  if Private and Private.AuraWarnings and data and data.uid then
    local problem = flow.carrierProblem and L["Row cells: %s. The next display is laid out from this display's carrier, which is the wrong place."]:format(tostring(flow.carrierProblem))
    Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_carrier", problem and "warning" or nil, problem)
    local boxes = flow.carrierBoxProblem and L["Row cells: a button's artwork could not be placed on the row: %s"]:format(tostring(flow.carrierBoxProblem))
    Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_carrier_box", boxes and "warning" or nil, boxes)
  end
  -- ForeverAuras (cell chain, dev.40 review): the chained list's own state
  -- (why a gated list is not chained; refused links; records past the batch).
  if Display.PublishChainWarnings then Display.PublishChainWarnings(region, data) end
end

-- The translated end of an independent carrier: where the next member starts,
-- from the member's start frame and the carrier's list end. Places the
-- member's boxes first (a failed or stale one is placed again; a failure is
-- reported in the editor and queues the display's paced re-apply, the same
-- path a refused style takes). Returns the end frame (its TOPLEFT is the
-- point) or nil and why when the client refused.
local function TranslateEnd(region, flow, container, g, data)
  local pin = Display.CarrierPin(data)
  if not pin then return nil, "no group frame" end
  -- The padding for this layout, from the current membership.
  flow.carrierM = Display.CarrierPadding(Display.FlowGroup(data))
  PlaceCarrierBoxes(region, data)
  if not flow.carrierEnd or Locked(flow.carrierEnd.h) or Locked(flow.carrierEnd.p) or Locked(flow.carrierEnd.out) then
    flow.carrierEnd = CarrierFrames(region)
    flow.carrierEnd.out = CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate")
    flow.carrierEnd.out:EnableMouse(false)
    flow.carrierEnd.out:SetSize(1, 1)
  end
  local ok, op, err = Translate(flow.carrierEnd, flow.start, g.start, container, g.listEnd, pin, flow.carrierM, flow.carrierEnd.out, "TOPLEFT")
  -- ForeverAuras (dev.31 diagnostics): the build history notes the end.
  if Display.NoteCarrierEvent then Display.NoteCarrierEvent(region, "end", ok and "ok" or tostring(op)) end
  if not ok then return nil, tostring(op) .. ": " .. tostring(err) end
  return flow.carrierEnd.out
end

-- ForeverAuras (development, dev.31): the build history of a display, for
-- the carrier diagnostics. An explicit record made AT each lifecycle event
-- (not a cache relabelled afterwards: native.previewStyled is kept up to
-- date by RefreshPreview as well, so it is no history of the build). Each
-- entry: the apply epoch (counted up by every apply), the time, the event,
-- and whether the editor was open, combat was on and auras were secret at
-- that moment. The last 16 are kept per display. Called from ApplyDisplay
-- ("apply"), Create ("container"), FinishApply ("finish"), TranslateEnd
-- ("end") and PlaceCarrierBoxes ("boxes").
local CARRIER_EVENTS = 16
-- A guarded read of a state flag: true, false, or nil for unknown (the read
-- was refused or returned a secret value), kept distinct in the history.
local function Flag(read)
  local ok, value = pcall(read)
  if not ok or issecretvalue(value) then return nil end
  return value and true or false
end
function Display.NoteCarrierEvent(region, what, detail)
  local native = region and region.blizzardAuraDisplay
  if not native then return end
  -- Development history for the opted-in groups only (their every member,
  -- so an import's ordering across B, C and D stays visible); an ordinary
  -- Modern display records nothing (dev.32 review).
  local data = native.data
  if not (data and Display.FlowIndependentGroup(Display.FlowGroup(data))) then return end
  if what == "apply" then native.carrierEpoch = (native.carrierEpoch or 0) + 1 end
  local events = native.carrierEvents or {}
  native.carrierEvents = events
  local okT, now = pcall(GetTime)
  events[#events + 1] = {epoch = native.carrierEpoch or 0, time = okT and not issecretvalue(now) and now or nil, what = what, detail = detail,
    editor = Flag(function() return WeakAuras.IsOptionsOpen() end),
    combat = Flag(InCombatLockdown),
    secret = Flag(function() return C_Secrets and C_Secrets.ShouldAurasBeSecret() end)}
  while #events > CARRIER_EVENTS do table.remove(events, 1) end
end

-- Development print (/fa carriers <group>, dev.29-31): per member, its
-- configured settings (growth, size, spacing, capacity, padding), then the
-- COMPLETE readable constraints of every frame this addon anchored for the
-- experiment: the member's start and content frames, every container, the
-- end helpers (H, P, out) and EVERY tracked button record (stable index =
-- its place in the instance's list, the same number the markers show) with
-- its button, H, P and box. For each frame: how many points it has and, for
-- each point, its own corner, the frame it hangs from (named by identity:
-- the pin, start, content, a numbered container/button/box/helper of this
-- display, the display's own frame, or OTHER with the frame's name or type),
-- the relative corner and the offsets. Every value is guarded: a refused or
-- secret answer prints as "?" and is never compared or treated as zero. The
-- build history (NoteCarrierEvent) follows. Nothing is read from a native
-- position; only the arguments this addon passed, as the client reports them.
local function Readable(v) return not issecretvalue(v) and v ~= nil end
local function Num(v)
  if not Readable(v) or type(v) ~= "number" then return "?" end
  if v == math.floor(v) then return ("%d"):format(v) end
  return ("%.2f"):format(v)
end
local function SafeName(frame)
  local okN, name = pcall(function() return frame.GetName and frame:GetName() end)
  if okN and Readable(name) and name ~= "" then return tostring(name) end
  local okT, kind = pcall(function() return frame.GetObjectType and frame:GetObjectType() end)
  return okT and Readable(kind) and tostring(kind) or "?"
end
-- The readable constraints of one frame, with a naming function for the
-- frames it hangs from. "none" = no points; "?" = unreadable.
local function Constraints(frame, Name)
  if not frame then return "missing" end
  local okN, n = pcall(function() return frame:GetNumPoints() end)
  if not okN or not Readable(n) then return "points ?" end
  if n == 0 then return "no points" end
  local parts = {}
  for i = 1, n do
    local ok, point, rel, relPoint, x, y = pcall(frame.GetPoint, frame, i)
    if not ok then parts[#parts + 1] = "[?]"
    else
      parts[#parts + 1] = ("[%s -> %s.%s %s,%s]"):format(Readable(point) and tostring(point) or "?",
        Readable(rel) and Name(rel) or "?", Readable(relPoint) and tostring(relPoint) or "?", Num(x), Num(y))
    end
  end
  local okS, shown = pcall(function() return frame:IsShown() end)
  return table.concat(parts, " ") .. (okS and Readable(shown) and (shown and " shown" or " hidden") or " shown?")
end
function Display.PrintCarriers(id)
  local group = WeakAuras.GetData(id)
  if not group or not group.blizzardFlow then print(L["FA carriers: %s is not a Modern Aura Group."]:format(tostring(id))); return end
  local okE, editor = pcall(function() return WeakAuras.IsOptionsOpen() end)
  print(L["FA carriers: %s: setting %s, growth %s, independent group %s, editor open now %s, combat now %s"]:format(id, "automatic",
    tostring(GrowthKey(group)), tostring(Display.FlowIndependentGroup(group)), tostring(okE and editor or false), tostring(InCombatLockdown())))
  local pin = Display.CarrierPin({parent = id})
  -- Names by identity, across the whole group, so a start frame that hangs
  -- from the previous member's end (or its container) is named as such.
  local names = {}
  if pin then names[pin] = "pin" end
  for _, childID in ipairs(Display.FlowOrder(group)) do
    local entry = Private.regions[childID]
    local region = entry and entry.region
    local native = region and region.blizzardAuraDisplay
    local flow = native and native.flow
    if region then names[region] = childID .. ".region" end
    if flow then
      if flow.start then names[flow.start] = childID .. ".start" end
      if flow.content then names[flow.content] = childID .. ".content" end
      if flow.remain then names[flow.remain] = childID .. ".remain" end
      if flow.carrierEnd then
        names[flow.carrierEnd.h] = childID .. ".endH"; names[flow.carrierEnd.p] = childID .. ".endP"
        if flow.carrierEnd.out then names[flow.carrierEnd.out] = childID .. ".endOut" end
      end
    end
    for index, instance in ipairs(native and native.instances or {}) do
      if instance.container then names[instance.container] = childID .. ".container" .. index end
      -- ForeverAuras (dev.34): a Missing member's presence container (its end), named.
      local missing = instance.single and instance.single.missing
      if missing and missing.presence then names[missing.presence] = childID .. ".presence" end
      for i, button in ipairs(instance.buttons or {}) do
        if button.button then names[button.button] = childID .. ".button" .. i end
        if button.box then names[button.box] = childID .. ".box" .. i end
        if button.carrier then names[button.carrier.h] = childID .. ".H" .. i; names[button.carrier.p] = childID .. ".P" .. i end
      end
    end
  end
  local function Name(frame)
    if frame == nil then return "nil" end
    return names[frame] or ("OTHER(" .. SafeName(frame) .. ")")
  end
  print(L["  pin (group frame): %s"]:format(Constraints(pin, Name)))
  for _, childID in ipairs(Display.FlowOrder(group)) do
    local data = WeakAuras.GetData(childID)
    local entry = Private.regions[childID]
    local region = entry and entry.region
    local native = region and region.blizzardAuraDisplay
    local flow = native and native.flow
    if data and native then
      local okD, width, height = pcall(Display.Dimensions, data)
      local okG, growth, spacing = pcall(Display.FlowGrowth, data)
      local okM, max = pcall(Display.MaxAuras, data)
      print(L["  %s: independent %s, pinned %s, end %s, boxes %s; configured: growth %s, size %sx%s, spacing %s, capacity %s, padding %s, own offset %s,%s"]:format(childID,
        tostring(Display.FlowIndependent(data)), tostring(flow and flow.carrierPinned), flow and flow.carrierProblem or L["ok"], flow and flow.carrierBoxProblem or L["ok"],
        okG and tostring(growth) or "?", okD and Num(width) or "?", okD and Num(height) or "?", okG and Num(spacing) or "?", okM and Num(max) or "?",
        flow and flow.carrierM and Num(flow.carrierM) or "none", Num(tonumber(data.xOffset) or 0), Num(tonumber(data.yOffset) or 0)))
      if flow then
        print(L["    start: %s"]:format(Constraints(flow.start, Name)))
        print(L["    content: %s"]:format(Constraints(flow.content, Name)))
        print(L["    end in use: %s at %s %s,%s; translated end %s"]:format(Name(flow.endFrame), tostring(flow.endPoint), Num(flow.x), Num(flow.y),
          flow.carrierEnd and (flow.endFrame == flow.carrierEnd.out and "in use" or "NOT in use") or "none"))
        if flow.carrierEnd then
          print(L["    endH: %s"]:format(Constraints(flow.carrierEnd.h, Name)))
          print(L["    endP: %s"]:format(Constraints(flow.carrierEnd.p, Name)))
          print(L["    endOut: %s"]:format(Constraints(flow.carrierEnd.out, Name)))
        end
      end
      for index, instance in ipairs(native.instances or {}) do
        print(L["    container%d: %s"]:format(index, Constraints(instance.container, Name)))
        local placed, failed = 0, 0
        for i, button in ipairs(instance.buttons or {}) do
          local record = button.carrierPlaced
          local state = record and record.complete and "complete" or record and "incomplete" or "none"
          if record and record.complete then placed = placed + 1 end
          if button.carrierFailure then failed = failed + 1 end
          if button.box or button.carrier or record or button.carrierFailure then
            print(L["    #%d record %s%s; button %s; H %s; P %s; box %s"]:format(i, state,
              button.carrierFailure and ("; failure " .. tostring(button.carrierFailure.op) .. ": " .. tostring(button.carrierFailure.err)) or "",
              Constraints(button.button, Name), Constraints(button.carrier and button.carrier.h, Name),
              Constraints(button.carrier and button.carrier.p, Name), Constraints(button.box, Name)))
            -- ForeverAuras (dev.34): the artwork's own state, for the "picture
            -- missing, countdown present" observation: the icon texture, its
            -- frame (sharedBase, on the gate clip) and the elements holder.
            -- Every read guarded; a secret answer is "?".
            local function Tex(t)
              if not t then return "missing" end
              local okS, shown = pcall(function() return t:IsShown() end)
              local okA, alpha = pcall(function() return t:GetAlpha() end)
              local okT, tex = pcall(function() return t:GetTexture() end)
              local okL, layer = pcall(function() return t:GetDrawLayer() end)
              return ("%s a=%s tex=%s %s %s"):format(okS and Readable(shown) and (shown and "shown" or "hidden") or "shown?",
                okA and Num(alpha) or "?", (okT and not issecretvalue(tex)) and (tex ~= nil and "set" or "none") or "?",
                okL and Readable(layer) and tostring(layer) or "?", Constraints(t, Name))
            end
            local base = button.elementFrames and button.elementFrames.sharedBase
            if base then names[base] = childID .. ".base" .. i end
            if button.elements then names[button.elements] = childID .. ".elements" .. i end
            if button.gateClip then names[button.gateClip] = childID .. ".clip" .. i end
            print(L["      art: icon %s; base %s; elements %s; clip %s"]:format(Tex(button.icon), Constraints(base, Name), Constraints(button.elements, Name), Constraints(button.gateClip, Name)))
          else
            print(L["    #%d no box (not an independent-carrier button); button %s"]:format(i, Constraints(button.button, Name)))
          end
        end
        local cb = instance.callbacks or {initial = {attempts = 0, constructed = 0, failed = 0, operations = 0},
          later = {attempts = 0, built = 0, failed = 0, operations = 0, restricted = 0, restrictedBuilt = 0, restrictedFailed = 0}}
        print(L["    container %d: %d buttons; callbacks with the container: %d attempted, %d constructed (styled afterwards), %d failed (%d refused operations); later: %d attempted, %d built, %d failed (%d refused operations); of the later ones under restrictions: %d attempted, %d built, %d failed; boxes now: %d placed, %d failed%s"]:format(index,
          #(instance.buttons or {}), cb.initial.attempts, cb.initial.constructed, cb.initial.failed, cb.initial.operations,
          cb.later.attempts, cb.later.built, cb.later.failed, cb.later.operations, cb.later.restricted, cb.later.restrictedBuilt, cb.later.restrictedFailed, placed, failed,
          instance.lastCallbackFailure and ("; last callback failure: " .. tostring(instance.lastCallbackFailure)) or ""))
      end
      local history = native.carrierHistory
      if history then
        print(L["    history since login (all containers of this display, not the current state): later callbacks %d attempted, %d built, %d failed; under restrictions %d attempted, %d built, %d failed"]:format(
          history.attempts, history.built or 0, history.failed, history.restricted, history.restrictedBuilt or 0, history.restrictedFailed or 0))
      end
      local events = {}
      for _, e in ipairs(native.carrierEvents or {}) do
        -- A flag: named when true, "?" when its read was refused, silent when false.
        local function Shown(flag, name) if flag == nil then return " " .. name .. "?" elseif flag then return " " .. name else return "" end end
        events[#events + 1] = ("%d:%s%s@%s%s%s%s"):format(e.epoch, e.what, e.detail and ("(" .. tostring(e.detail) .. ")") or "", Num(e.time),
          Shown(e.editor, "editor"), Shown(e.combat, "combat"), Shown(e.secret, "secret"))
      end
      print(L["    events (epoch:event@time, flags at that moment): %s"]:format(#events > 0 and table.concat(events, "; ") or L["nothing"]))
    elseif data then
      print(L["  %s: not built"]:format(childID))
    end
  end
end

-- Development markers (/fa carriermarks <group>, dev.29-31): coloured marks
-- on the ACTUAL frames of a row's independent lists, so a screenshot shows
-- where each stage of the construction lands. Red 10 px square = the pin
-- (the group's TOPLEFT); cyan 8 px square = each member's start corner;
-- white 14 px RING = its content corner (a ring, so that the cyan square it
-- normally coincides with stays visible inside it); yellow 10 px = each
-- container's TOPLEFT and orange 10 px = its BOTTOMRIGHT (the container's own
-- rectangle, by anchor); blue 8 px square = each tracked button's start
-- corner, with the record's index written under it; green 6 px square = the
-- box's start corner (bright for a complete placement record, dim for an
-- incomplete or missing one), with the index written above it; magenta 10 px
-- = the translated list end. The button and box marks are children of the
-- button, so only shown buttons show them. Nothing is read, no live frame is
-- re-anchored: markers are new frames anchored to existing ones. Every
-- creation and placement is guarded; the print says how many failed, and
-- "off" removes every mark of a run, a partial one included.
local marks, markFailures = {}, 0
local function Mark(parent, r, g, b, size, label, labelBelow)
  local ok, f = pcall(CreateFrame, "Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
  if not ok or not f then markFailures = markFailures + 1; return nil end
  marks[#marks + 1] = f
  local okS = pcall(function()
    f:SetSize(size or 8, size or 8)
    f:SetFrameStrata("TOOLTIP")
    f:EnableMouse(false)
    local tex = f:CreateTexture(nil, "OVERLAY"); tex:SetAllPoints(); tex:SetColorTexture(r, g, b, 0.9)
    if label then
      local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      text:SetText(tostring(label))
      text:SetTextColor(r, g, b, 1)
      if labelBelow then text:SetPoint("TOP", f, "BOTTOM", 0, -1) else text:SetPoint("BOTTOM", f, "TOP", 0, 1) end
    end
  end)
  if not okS then markFailures = markFailures + 1 end
  return f
end
-- A hollow square (four 1 px edges), for a mark that sits on another mark.
local function Ring(parent, r, g, b, size)
  local ok, f = pcall(CreateFrame, "Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")
  if not ok or not f then markFailures = markFailures + 1; return nil end
  marks[#marks + 1] = f
  local okS = pcall(function()
    f:SetSize(size, size)
    f:SetFrameStrata("TOOLTIP")
    f:EnableMouse(false)
    for _, edge in ipairs({{"TOPLEFT", "TOPRIGHT", 1, nil}, {"BOTTOMLEFT", "BOTTOMRIGHT", 1, nil}, {"TOPLEFT", "BOTTOMLEFT", nil, 1}, {"TOPRIGHT", "BOTTOMRIGHT", nil, 1}}) do
      local tex = f:CreateTexture(nil, "OVERLAY"); tex:SetColorTexture(r, g, b, 0.9)
      tex:SetPoint(edge[1]); tex:SetPoint(edge[2])
      if edge[3] then tex:SetHeight(1) else tex:SetWidth(1) end
    end
  end)
  if not okS then markFailures = markFailures + 1 end
  return f
end
local function Pin(mark, point, frame, relPoint)
  if not mark then return end
  local ok = pcall(mark.SetPoint, mark, point, frame, relPoint)
  if not ok then markFailures = markFailures + 1 end
end
function Display.MarkCarriers(id)
  Display.UnmarkCarriers()
  local group = WeakAuras.GetData(id)
  if not group or not group.blizzardFlow then print(L["FA carriermarks: %s is not a Modern Aura Group."]:format(tostring(id))); return end
  local pin = Display.CarrierPin({parent = id})
  local g = GROWTH[GrowthKey(group)]
  if pin then Pin(Mark(pin, 1, 0.2, 0.2, 10), "CENTER", pin, "TOPLEFT") end
  local boxes, containers = 0, 0
  for _, childID in ipairs(Display.FlowOrder(group)) do
    local entry = Private.regions[childID]
    local native = entry and entry.region and entry.region.blizzardAuraDisplay
    local flow = native and native.flow
    if flow and flow.start then
      Pin(Mark(entry.region, 0.2, 1, 1, 8), "CENTER", flow.start, g.start)
      if flow.content then Pin(Ring(entry.region, 1, 1, 1, 14), "CENTER", flow.content, g.start) end
      if flow.carrierEnd and flow.carrierEnd.out and flow.endFrame == flow.carrierEnd.out then
        Pin(Mark(entry.region, 1, 0.2, 1, 10), "CENTER", flow.carrierEnd.out, "TOPLEFT")
      end
      for _, instance in ipairs(native.instances or {}) do
        if instance.container and Display.FlowIndependent(native.data) then
          containers = containers + 1
          Pin(Mark(entry.region, 1, 0.9, 0.1, 10), "CENTER", instance.container, "TOPLEFT")
          Pin(Mark(entry.region, 1, 0.5, 0.1, 10), "CENTER", instance.container, "BOTTOMRIGHT")
        end
        for i, button in ipairs(instance.buttons or {}) do
          if button.button then Pin(Mark(button.button, 0.2, 0.4, 1, 8, i, true), "CENTER", button.button, g.start) end
          if button.box then
            local complete = button.carrierPlaced and button.carrierPlaced.complete
            Pin(Mark(button.button, complete and 0.3 or 0.1, complete and 1 or 0.5, complete and 0.3 or 0.1, 6, i, false), "CENTER", button.box, g.start)
            boxes = boxes + 1
          end
        end
      end
    end
  end
  print(L["FA carriermarks: %s: red pin, cyan member starts, white rings content corners, yellow/orange container TOPLEFT/BOTTOMRIGHT (%d containers), blue native button corners (index below), green box corners (index above; dim = no complete record; %d boxes), magenta translated list ends. %d marker operations failed. Type /fa carriermarks off to remove."]:format(id, containers, boxes, markFailures))
end
-- Removes every mark of the last run. Hide and ClearAllPoints are guarded
-- separately; a mark that refused either stays on the list and is tried
-- again by the next "off" or the next marking, so a partial run is never
-- forgotten (dev.32 review). Returns how many marks are still stuck.
function Display.UnmarkCarriers()
  local stuck = {}
  for _, f in ipairs(marks) do
    local hidden = pcall(f.Hide, f)
    local cleared = pcall(f.ClearAllPoints, f)
    if not (hidden and cleared) then stuck[#stuck + 1] = f end
  end
  marks, markFailures = stuck, 0
  if #stuck > 0 then print(L["FA carriermarks: %d mark(s) could not be removed yet; they will be tried again next time."]:format(#stuck)) end
  return #stuck
end

-- A member's content frame in a group-owned row: the same rectangle as its
-- start frame, moved by the member's own X/Y Offset. Containers, the Missing
-- look, samples and stand copies hang from it (ContentAnchor), so the offset
-- moves the content and the chain, which runs through the start frames, does
-- not see it. Made on demand; a locked one is replaced (FreshFrame).
function Display.FlowContent(flow, region)
  if not flow.content then
    flow.content = OnPixels(CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate"))
    flow.content:EnableMouse(false)
  end
  FreshFrame(flow, "content", "startSize", region)
  return flow.content
end

local function PlaceContent(flow, ox, oy)
  local content = flow.content
  if not content or Busy(content) then return end
  -- ForeverAuras (dev.70): under aura restrictions a content frame already
  -- on this start with these offsets is not written again (its start may
  -- hang from a chained member's end, which the client guards then).
  local last = content.faContent
  if last and RestrictedNow() and last[1] == flow.start and last[2] == (ox or 0) and last[3] == (oy or 0) then return end
  -- A child of the start frame, so it shows and hides with it (the editor
  -- hides a stand's start frame while its preview stands in).
  if content:GetParent() ~= flow.start and not InCombatLockdown() then content:SetParent(flow.start) end
  content:ClearAllPoints()
  content:SetPoint("TOPLEFT", flow.start, "TOPLEFT", ox or 0, oy or 0)
  content:SetPoint("BOTTOMRIGHT", flow.start, "BOTTOMRIGHT", ox or 0, oy or 0)
  content.faContent = {flow.start, ox or 0, oy or 0}
end

-- Where this display's content is drawn from: its content frame in a
-- group-owned row, its start frame in a legacy row, else the region itself.
function Display.ContentAnchor(region)
  local native = region.blizzardAuraDisplay
  local flow = native and native.flow
  return flow and (flow.content or flow.start) or region
end

-- Called by Apply before anything is laid out.
function Display.EnsureFlowStart(region, data)
  local native = region.blizzardAuraDisplay
  if not Display.FlowGroup(data) then
    ClearMeasureOutputWarning(data)
    if native.flow then SetShown(native.flow.start, false); native.flow = nil end
    return
  end
  Display.WatchFlowVisibility(region)
  local flow = native.flow or {}
  native.flow = flow
  if not flow.start then
    -- Anchored to other displays' aura containers, whose size is secret.
    flow.start = OnPixels(CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate"))
    flow.start:EnableMouse(false)
  end
  local width, height = Display.Dimensions(data)
  flow.startSize = {width, height}
  FreshFrame(flow, "start", "startSize", region)
  flow.start:SetSize(width, height)
  SetShown(flow.start, true)
  local growth = Display.FlowGrowth(data)
  flow.growth = GROWTH[growth]
  -- Until the chain is built, start where the region is. ForeverAuras
  -- (dev.70): a start prewired on the previous member's chained end
  -- (PrewireFollower) keeps that place; it is not reset here.
  if not flow.startPrewired then
    flow.start:ClearAllPoints()
    flow.start:SetPoint(flow.growth.start, region, flow.growth.start)
    flow.start.faPlace = nil   -- the placement record (Place) is stale now
  end
  -- ForeverAuras: group-owned row: the content frame carries the display's
  -- own offset (FlowContent); a legacy row draws from the start frame.
  local hadContent = flow.content ~= nil
  if Display.FlowGroupOwned(Display.FlowGroup(data)) then
    Display.FlowContent(flow, region)
    PlaceContent(flow, OwnOffset(data))
    flow.contentOn = flow.start
  elseif flow.content then
    SetShown(flow.content, false)
    flow.content = nil
  end
  -- The content anchor changed with the row mode: the containers must be
  -- anchored again (RefreshUnits re-anchors an instance marked unanchored;
  -- its anchor record names the region either way, so it would not notice).
  if hadContent ~= (flow.content ~= nil) then
    for _, instance in ipairs(native.instances or {}) do instance.anchored = false end
  end
end

-- Called by Apply once the display's parts exist: records where the next
-- child starts. presence: the Aura(s) Missing end container, when there is one.
function Display.SetFlowEnd(region, data, presence)
  local native = region.blizzardAuraDisplay
  local flow = native and native.flow
  if not flow then return end
  local g = flow.growth
  local trigger = Display.GetTrigger(data)
  local _, spacing = Display.FlowGrowth(data)
  local width, height = Display.Dimensions(data)
  local showOn = Display.ShowOn(trigger)
  -- ForeverAuras: group-owned row: only the aura containers hang from the
  -- content frame (AnchorToContent) and so carry the display's own offset;
  -- the Remaining Time text and the Missing presence container are measured
  -- from the start frame and carry none. The chain takes the offset back off
  -- only where it is (RechainFlow); taken off a presence end, a Missing
  -- display's offset moved every member after it the other way.
  flow.endInContent = false
  -- ForeverAuras (independent carriers): decided here for the whole display,
  -- so a display that left the experiment by any route (flag off, or its
  -- trigger changed to Missing or Remaining Time) drops the experiment's
  -- state and warnings whatever branch below it takes (dev.19 review).
  local independent = Display.FlowIndependent ~= nil and Display.FlowIndependent(data)
  if not independent then
    flow.carrierProblem, flow.carrierBoxProblem, flow.carrierM = nil, nil, nil
    if flow.carrierEnd then for _, key in ipairs({"h", "p", "out"}) do pcall(flow.carrierEnd[key].Hide, flow.carrierEnd[key]) end end
  end
  -- ForeverAuras (cell chain, SecretAuraChain.lua): a chained filtered list
  -- ends on its end frame's start corner (FinishChain); the chain's advances
  -- include the spacing, so nothing is added. The end lives in the content
  -- frame (the chain hangs from it), so the member's own offset is taken
  -- back off by the chain as for a list's container.
  local chainSpec = Display.FlowChain ~= nil and Display.FlowChain(data)
  local measure = flow.measureChain
  if chainSpec and flow.chainEndReady and flow.chainEnd then
    flow.endFrame, flow.endPoint, flow.x, flow.y = flow.chainEnd, flow.chainCorner or g.start, 0, 0
    flow.endInContent = true
    flow.remain = nil
  elseif not chainSpec and measure and measure.flow.chainEndReady and measure.flow.chainEnd then
    -- ForeverAuras (dev.78): an ordinary member of a row with cells ends on
    -- its measurement chain (EnsureFlowMeasure), never on a container's edge.
    -- Local measurements publish their translated end in the member's content.
    flow.endFrame, flow.endPoint, flow.x, flow.y = measure.out or measure.flow.chainEnd, measure.outCorner or measure.flow.chainCorner or g.start, 0, 0
    flow.endInContent = true
    flow.remain = nil
  elseif chainSpec then
    -- The chain is not in place (a refused link or end, dev.40 review): the
    -- display keeps one spot and draws nothing, until the bounded re-apply
    -- (NoteChainFailure, QuietChain); the editor says so (PublishChainWarnings,
    -- below). When the client refused to hide some of its cells (restricted
    -- records), what is drawn is unknown, so the display reserves its full
    -- length instead: a gap, never an overlap (dev.42 review).
    -- (native.chainReserve, NoteChainFailure: ten cells at the measured
    -- advance, the longest of every construction those frames may hold).
    local extent = native.chainReserve or (width + spacing)
    if g.sign[2] ~= 0 and not native.chainReserve then extent = height + spacing end
    flow.endFrame, flow.endPoint = flow.start, g.start
    flow.x, flow.y = g.sign[1] * extent, g.sign[2] * extent
    flow.remain = nil
  elseif flow.remain then
    -- The measured pixels back from the text's end (MeasureText), in the
    -- next display's units.
    local px = PixelsPerUnit(flow.start) or 1
    local back = (flow.remainBack or 1) / px
    flow.endFrame, flow.endPoint, flow.x, flow.y = flow.remain, g.far, -g.sign[1] * back, -g.sign[2] * back
  elseif showOn == "showOnMissing" and presence then
    flow.endFrame, flow.endPoint, flow.x, flow.y = presence, g.start, 0, 0
  -- A gate (Total Duration or Stack Count) keeps the candidates on one spot.
  elseif showOn == "showOnActive" and not Display.UsesGate(data) and native.instances[1] then
    -- Several units are chained one after another; the last one ends the display.
    local last = native.instances[#native.instances].container
    -- ForeverAuras (independent carriers): the pinned carrier's end is
    -- translated to the row (TranslateEnd); the pixel an empty container
    -- keeps is still taken off once, as below. The member's own offset is
    -- not in this end (it is measured from the start frame), so nothing is
    -- subtracted for it. A refused translation falls back to the carrier's
    -- own end, which is then the wrong place, and says so in the editor.
    local translated, why
    if independent and flow.carrierPinned then
      translated, why = TranslateEnd(region, flow, last, g, data)
    elseif independent then
      why = flow.carrierPinError or "the carrier could not be pinned to the group"
    end
    if translated then
      flow.endFrame, flow.endPoint = translated, "TOPLEFT"
      flow.x, flow.y = g.pixel[1], g.pixel[2]
      flow.endInContent = false
      flow.carrierProblem = nil
    else
      flow.endFrame, flow.endPoint = last, g.listEnd
      flow.x, flow.y = g.pixel[1], g.pixel[2]
      flow.endInContent = true
      if independent then
        -- A refused pin or end: the wrong end is in use until the paced
        -- re-apply; counted against the build like a refused box.
        flow.carrierProblem = why
        local instance = native.instances[#native.instances]
        if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "carrier end", why) end
        if Display.NotePendingRelayout then Display.NotePendingRelayout(region) end
      end
    end
  else
    -- A fixed icon: Always, or a Total Duration list whose candidates overlap.
    flow.endFrame, flow.endPoint = flow.start, g.start
    flow.x, flow.y = g.sign[1] * (width + spacing), g.sign[2] * (height + spacing)
  end
  -- ForeverAuras (independent carriers): what is wrong, if anything, said in
  -- the editor from the current state; cleared when nothing is.
  if Display.PublishCarrierWarnings then Display.PublishCarrierWarnings(region, data) end
end

-- The Aura(s) Missing end container: one icon plus spacing along the growth
-- axis per present aura.
function Display.FlowPresenceSize(data)
  local growth, spacing = Display.FlowGrowth(data)
  local width, height = Display.Dimensions(data)
  local along = GROWTH[growth].sign[1] ~= 0
  local size = (along and width or height) + spacing + 1
  return along and {elementWidth = size, elementHeight = height} or {elementWidth = width, elementHeight = size}
end

-- Anchors a presence container (one element of size along the growth axis)
-- so its start edge moves back by that size when the aura is present: empty,
-- it is one pixel, so what follows starts size - 1 further on. Only after its
-- aura group exists: Blizzard refuses the anchor before that.
local OPPOSITE = {TOPLEFT = "TOPRIGHT", TOPRIGHT = "TOPLEFT", BOTTOMLEFT = "TOPLEFT"}
local function AnchorBackwards(container, g, startFrame, size, region)
  local along = g.sign[1] ~= 0
  local point = along and OPPOSITE[g.start] or (g.start == "TOPLEFT" and "BOTTOMLEFT" or "TOPLEFT")
  container:ClearAllPoints()
  local ok = Place(container, point, startFrame, g.start, g.sign[1] * size, g.sign[2] * size)
  if not ok then
    container:ClearAllPoints()
    container:SetPoint("TOPLEFT", region, "TOPLEFT")
  end
  return ok
end

-- Returns false when Blizzard refuses it.
function Display.AnchorFlowPresence(region, data, container)
  local flow = region.blizzardAuraDisplay and region.blizzardAuraDisplay.flow
  if not flow then return false end
  local layout = Display.FlowPresenceSize(data)
  local along = flow.growth.sign[1] ~= 0
  -- The empty container is one unit wide (measured), so anchoring its far
  -- edge icon + spacing + 1 on puts its near edge, where the next display
  -- starts, at exactly icon + spacing.
  return AnchorBackwards(container, flow.growth, flow.start, along and layout.elementWidth or layout.elementHeight, region)
end

---------------------------------------------------------------------------- centered growth
-- An invisible container with the display's filters that measures presence:
-- maxCount elements of the given size, laid out towards g.
local SHADOW_GROUP = "FAShadow"
local function MeasureContainer(existing, region, data, g, layout, maxCount, filter, candidates)
  local container = existing
  if not container then
    container = Display.CreateAuraContainer(region, data)
    container:SetEnabled(false)
    container:SetAuraProcessingPolicy(CustomAuraContainerAuraProcessingPolicy.None)
    -- Placed on the region first, like every aura container; chained later.
    container:SetPoint("TOPLEFT", region, "TOPLEFT")
    local ok = pcall(container.AddAuraGroup, container, SHADOW_GROUP, filter, {
      candidateFilters = candidates, maxFrameCount = maxCount, layout = layout,
      initializeFrame = function(button)
        -- Draws nothing; only the container's size is used.
        button:SetSize(layout.elementWidth, layout.elementHeight)
        button:SetAlpha(0)
        button:EnableMouse(false)
      end,
    })
    if not ok then container:Hide(); Display.RetireFrame(container); return nil end
  else
    container:SetAuraGroupFilterString(SHADOW_GROUP, filter)
    container:SetAuraGroupCandidateFilters(SHADOW_GROUP, candidates)
    container:SetAuraGroupLayout(SHADOW_GROUP, layout)
    container:SetAuraGroupMaxFrameCount(SHADOW_GROUP, maxCount)
    container:SetAuraGroupEnabled(SHADOW_GROUP, true)
  end
  local vertical = g.sign[2] ~= 0
  container:SetFlowLayoutAxis(vertical and AnchorUtil.FlowLayoutAxis.Vertical or AnchorUtil.FlowLayoutAxis.Horizontal)
  container:SetFlowLayoutAnchorPoint(g.start)
  container:SetFlowLayoutGrowthDirection(g.sign[1] < 0 and AnchorUtil.FlowDirection.Left or AnchorUtil.FlowDirection.Right,
    g.sign[2] > 0 and AnchorUtil.FlowDirection.Up or AnchorUtil.FlowDirection.Down)
  return container
end

---------------------------------------------------------------------------- sort across displays
function Display.MergesAcross(group)
  return group and group.blizzardFlow and Display.FlowSortMode(group) ~= "none" and not Display.FlowGrid(group) or false
end

local function Serialize(value)
  if type(value) ~= "table" then return tostring(value) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. Serialize(value[key]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Merged displays are drawn by one host, so only identical looks may merge.
local notAppearance = {id = true, uid = true, parent = true, triggers = true, trigger = true, load = true, xOffset = true, yOffset = true,
  anchorPoint = true, anchorFrameType = true, anchorFrameFrame = true, selfPoint = true, information = true,
  authorOptions = true, config = true, actions = true, internalVersion = true, tocversion = true, semver = true,
  url = true, desc = true, version = true, preferToUpdate = true, sortHybridTable = true, controlledChildren = true,
  frameStrata = true, frameLevel = true, anchorFrameParent = true, anchorFramePoint = true, anchorFrameOffset = true,
  anchorPerUnit = true, useAnchorPerUnit = true, animation = true, source = true, wagoID = true,
  ignoreWagoUpdate = true, skipWagoUpdate = true}
local appearanceKeys = setmetatable({}, {__mode = "k"})

-- Data can change in place without the options (imports, other addons): Apply forgets its key.
function Display.ForgetAppearanceKey(data)
  if data then appearanceKeys[data] = nil end
end

local function AppearanceKey(data)
  -- Options edit data in place: no keys are kept while they are open.
  local editing = WeakAuras.IsOptionsOpen()
  if editing then wipe(appearanceKeys) elseif appearanceKeys[data] then return appearanceKeys[data] end
  local parts = {}
  for key, value in pairs(data) do
    if not notAppearance[key] and not (key == "displayIcon" and data.iconSource ~= 0) then
      parts[#parts + 1] = tostring(key) .. "=" .. Serialize(value)
    end
  end
  table.sort(parts)
  local key = table.concat(parts, ",")
  if not editing then appearanceKeys[data] = key end
  return key
end

function Display.MergeKey(data)
  local trigger = Display.GetTrigger(data)
  if type(trigger) ~= "table" or Display.ShowOn(trigger) ~= "showOnActive" or Display.IsSingle(trigger, data)
    or Display.UsesGate(data) or Display.UsesApproximate(trigger)
    or not (Display.UsesSpellIDs(trigger) or Display.UsesRankSpellIDs(trigger)) then return end
  local filters = CopyTable(Display.RawCandidateFilters(data))
  filters.includeSpellIDs = nil
  local op, x = Display.RemainingWindow(trigger)
  -- Which units a display watches is part of the key: displays with
  -- different unit filters (names, roles, class, self, dead, offline, range,
  -- hostility) must not merge, or the first one's units would govern both.
  -- An enabled filter with nothing selected matches no unit: distinct from off.
  local units = Serialize({
    names = trigger.useUnitNames and (trigger.unitNames or {}) or false,
    roles = trigger.useUnitRoles and (trigger.unitRoles or {}) or false,
    class = trigger.useUnitClass and (trigger.unitClass or {}) or false,
    self = trigger.ignoreSelf or false, dead = trigger.ignoreDead or false,
    offline = trigger.ignoreDisconnected or false, range = trigger.ignoreInvisible or false,
    hostility = Display.UsesHostility(trigger) and (trigger.hostility or "hostile") or false,
  })
  return table.concat({tostring(trigger.unit), tostring((Display.SpecificUnit(trigger))), tostring((Display.IncludesPets(trigger))),
    units, Display.FilterString(trigger), Serialize(filters), tostring(op), tostring(x), AppearanceKey(data)}, "|")
end

local merged = setmetatable({}, {__mode = "k"})

local function MergedFor(data)
  local entry = data and Private.regions[data.id]
  local info = entry and entry.region and merged[entry.region]
  -- A display that left its merging group draws with its own filters again.
  if info and not Display.MergesAcross(Display.FlowGroup(data)) then
    merged[entry.region] = nil
    return
  end
  return info
end

function Display.MergedCandidateFilters(data)
  local info = MergedFor(data)
  return info and info.filters
end

function Display.MergedMaxAuras(data)
  local info = MergedFor(data)
  return info and info.max
end

local function PushFilters(region, data, filters, max)
  local native = region.blizzardAuraDisplay
  local ok = true
  for _, instance in ipairs(native and native.instances or {}) do
    ok = pcall(instance.container.SetAuraGroupCandidateFilters, instance.container, "Auras", filters) and ok
    ok = pcall(instance.container.SetAuraGroupMaxFrameCount, instance.container, "Auras", max) and ok
    if instance.flowShadowActive and instance.flowShadow then
      ok = pcall(instance.flowShadow.SetAuraGroupCandidateFilters, instance.flowShadow, SHADOW_GROUP, filters) and ok
      ok = pcall(instance.flowShadow.SetAuraGroupMaxFrameCount, instance.flowShadow, SHADOW_GROUP, max) and ok
    end
  end
  return ok
end

function Display.RefreshFlowMerge(group)
  local sets, order = {}, {}
  if Display.MergesAcross(group) then
    for _, childID in ipairs(group.controlledChildren or {}) do
      local entry = Private.regions[childID]
      local region = entry and entry.region
      local native = region and region.blizzardAuraDisplay
      if native and native.active and native.data and region:IsShown() then
        local key = Display.MergeKey(native.data)
        if key then
          if not sets[key] then sets[key] = {}; order[#order + 1] = key end
          table.insert(sets[key], region)
        end
      end
    end
  end
  local wanted = {}
  local limit = group.blizzardFlowUseLimit and math.max(1, math.floor(tonumber(group.blizzardFlowLimit) or 5)) or nil
  for _, key in ipairs(order) do
    local set = sets[key]
    if #set > 1 then
      local host = set[1]
      local filters = CopyTable(Display.RawCandidateFilters(host.blizzardAuraDisplay.data))
      local union, total = {}, 0
      for _, region in ipairs(set) do
        local data = region.blizzardAuraDisplay.data
        for id in pairs(Display.RawCandidateFilters(data).includeSpellIDs or {}) do union[id] = true end
        total = total + Display.RawMaxAuras(data)
      end
      filters.includeSpellIDs = union
      wanted[host] = {filters = filters, max = limit or math.min(total, 40)}
      for index = 2, #set do
        local own = CopyTable(Display.RawCandidateFilters(set[index].blizzardAuraDisplay.data))
        own.includeSpellIDs = {}
        wanted[set[index]] = {filters = own, max = 1}
      end
    end
  end
  for _, childID in ipairs(group.controlledChildren or {}) do
    local entry = Private.regions[childID]
    local region = entry and entry.region
    local native = region and region.blizzardAuraDisplay
    if native and native.data then
      local info, old = wanted[region], merged[region]
      local signature = info and Serialize(info) or nil
      if signature ~= (old and old.signature) then
        if info then
          info.signature = signature
          if PushFilters(region, native.data, info.filters, info.max) then merged[region] = info end
        elseif PushFilters(region, native.data, Display.RawCandidateFilters(native.data), Display.RawMaxAuras(native.data)) then
          merged[region] = nil
        end
      end
    end
  end
end

local function HideShadow(holder, key)
  local container = holder and holder[key]
  if container and not Busy(container) then
    holder[key .. "Active"] = false
    container:SetEnabled(false)
    container:Hide()
  end
end

-- Called by Apply after the display's parts exist: builds or retires the
-- half-size shadows of a centred Modern Aura Group.
function Display.EnsureFlowShadows(region, data)
  local native = region.blizzardAuraDisplay
  local flow = native and native.flow
  local sh = flow and flow.growth.shadow
  local missing = native and native.instances[1] and native.instances[1].single and native.instances[1].single.missing
  for _, instance in ipairs(native and native.instances or {}) do
    if not sh then HideShadow(instance, "flowShadow") end
  end
  if not sh then
    HideShadow(missing, "flowShadow")
    if flow then SetShown(flow.shadowStart, false) end
    if flow and flow.shadowChain and Display.ReleaseChainSpine then Display.ReleaseChainSpine(flow.shadowChain); flow.shadowKind = nil end
    -- (dev.90, Astra's dev.89 review) no shadows here: a kept shadow explanation no longer applies
    if flow then flow.shadowChainProblem = nil end
    if data and data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_shadow", nil, nil) end
    return
  end
  if not flow.shadowStart then
    flow.shadowStart = CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate")
    flow.shadowStart:EnableMouse(false)
    flow.shadowStart:SetSize(1, 1)
  end
  SetShown(flow.shadowStart, true)
  local trigger = Display.GetTrigger(data)
  local _, spacing = Display.FlowGrowth(data)
  local width, height = Display.Dimensions(data)
  local along = sh.sign[1] ~= 0
  -- Whole units only: a half-unit shadow puts every icon after it between
  -- two pixels, where 1 px borders draw 2 px wide. The row may sit up to half
  -- a unit per display off centre instead, which nothing can see.
  flow.half = Display.FlowHalf(region, (along and width or height) + spacing)
  local size = flow.half + 1
  local layout = along and {elementWidth = size, elementHeight = height, elementSpacing = -1}
    or {elementWidth = width, elementHeight = size, elementSpacing = -1}
  local filter, candidates = Display.FilterString(trigger), Display.CandidateFilters(data)
  local showOn = Display.ShowOn(trigger)
  flow.shadowKind, flow.shadowList = "fixed", nil
  -- ForeverAuras (dev.74): a chained member's shadow is a shadow chain (its
  -- own half-step spine on a second invisible container, SecretAuraChain.lua
  -- EnsureChainShadow); when it cannot be made the member keeps a fixed spot.
  local chainShadow = false
  if Display.EnsureChainShadow and native.instances[1] then
    -- (dev.78) every member that measures (a chained member, a Found list of
    -- at most a batch, a Missing member) shadows with a measurement chain;
    -- a row with cells must not hang from a container's edge (Dan's freezes)
    local made, why = Display.EnsureChainShadow(region, data, native, native.instances[1])
    if made then flow.shadowKind = "chain"; chainShadow = true
    elseif why == "off" or why == "nothing to measure" then
      -- (1.2.0, Astra's audit 5) this member no longer measures (its settings changed): a kept failure
      -- and its editor warning are obsolete
      flow.shadowChainProblem = nil
      if data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_shadow", nil, nil) end
    else flow.shadowChainProblem = why end
    -- (dev.90, Astra's dev.89 review) an ordinary shadow BOUND whole drops a kept explanation and its editor
    -- warning (a prepared, still unbound scaffold does not: its binding decides, ActivateShadows)
    local sc = flow.shadowChain
    if made and sc and not sc.scaffold and sc.flow.chainEndReady then
      flow.shadowChainProblem = nil
      if data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_shadow", nil, nil) end
    end
    if Display.BuildReport and why ~= "off" and why ~= "nothing to measure" then
      local sc = flow.shadowChain
      -- (dev.82) under restrictions the shadow is prepared without its records (ActivateShadows binds them)
      if made and sc and sc.scaffold then Display.BuildReport(("%s shadow prepared: its records are bound once the whole row is in place"):format(tostring(data.id)))
      else
      Display.BuildReport(made and ("%s shadow measured: %d records, end %s"):format(tostring(data.id), sc and #sc.buttons or 0, (sc and sc.flow.chainEndReady) and "ready" or "NOT ready")
        or ("%s shadow not measured (%s): a fixed half step"):format(tostring(data.id), tostring(why)))
      end
    end
  end
  if chainShadow then
    for index = 2, #native.instances do HideShadow(native.instances[index], "flowShadow") end
  -- Gated lists (Total Duration, Stack Count) keep a fixed spot.
  elseif showOn == "showOnActive" and not Display.UsesGate(data) then
    flow.shadowList = {}
    for _, instance in ipairs(native.instances) do
      instance.flowShadow = MeasureContainer(instance.flowShadow, region, data, sh, layout, Display.MaxAuras(data), filter, candidates)
      instance.flowShadowActive = instance.flowShadow ~= nil
      if instance.flowShadow then flow.shadowList[#flow.shadowList + 1] = instance.flowShadow end
    end
    if #flow.shadowList > 0 then flow.shadowKind = "list" end
  else
    for _, instance in ipairs(native.instances) do HideShadow(instance, "flowShadow") end
  end
  if flow.shadowKind ~= "chain" and flow.shadowChain and Display.ReleaseChainSpine then Display.ReleaseChainSpine(flow.shadowChain) end
  if not chainShadow and showOn == "showOnMissing" and missing and missing.active and not missing.slot then
    local single = {elementWidth = along and size or width, elementHeight = along and height or size}
    missing.flowShadow = MeasureContainer(missing.flowShadow, region, data, sh, single, 1, filter, candidates)
    missing.flowShadowActive = missing.flowShadow ~= nil
      and AnchorBackwards(missing.flowShadow, sh, flow.shadowStart, size, region)
    missing.flowShadowBoundUnit = nil
    if missing.flowShadowActive then flow.shadowKind = "missing" end
  else
    HideShadow(missing, "flowShadow")
  end
end

-- Remaining Time: a hidden countdown text on its own aura slot is one display
-- (plus spacing) long inside the time window and empty outside it, or when
-- the aura is gone, so the next display follows the window.
local FLOW_REMAIN, FLOW_REMAIN_SHADOW = "FAFlowRemain", "FAFlowRemainShadow"
local measureCurve

-- ForeverAuras: everything drawn in the measure slot's button is made and
-- arranged in `setup`, inside the client's initializeFrame when the slot is
-- made and directly on later calls, since a slot button made under aura
-- restrictions is locked by the client, with every frame under it, the
-- moment AddAuraSlot returns (probed in game, 1.2.0-rc.7; the same rule as
-- the Remaining Time slots, SecretAuraSingle.lua EnsureSlot). Seen in game:
-- a Modern Aura Group member with a Remaining Time window stopped its build
-- in combat here ("finishing failed", CreateFrame on the locked button).
-- Only the bindings and the container's slot calls follow.
local function MeasureText(region, instance, key, data, trigger, g, startFrame, length, lower, upper, property)
  local container, store = instance.container, instance.flowRemainSlots
  local entry = store[key]
  local fill
  local function setup(button)
    -- Each frame made on its own, so a setup that failed part way is
    -- finished by the next one (rc.15 review).
    entry.complete = nil
    -- The text sits in a frame scaled so that one of its units is one screen
    -- pixel: the fill is then a whole number of pixels, and the one unit the
    -- text adds around it is exactly one pixel, so the next display's start
    -- needs no rounding (see SetFlowEnd). Only the creation is guarded: the
    -- settings are written every time, so a setup that failed between the
    -- two is finished by the next one (rc.17 review).
    entry.holder = entry.holder or CreateFrame("Frame", nil, button, "DisableUntrustedLayoutScriptsTemplate")
    entry.holder:EnableMouse(false)
    entry.holder:SetSize(1, 1)
    -- The fill is a plain texture that the text colour cannot hide; the holder
    -- is invisible (its size still measures), as the slot button is.
    entry.holder:SetAlpha(0)
    entry.text = entry.text or entry.holder:CreateFontString(nil, "ARTWORK")
    -- A plain copy of the text, to measure how wide the fill really renders.
    entry.probe = entry.probe or entry.holder:CreateFontString(nil, "ARTWORK")
    entry.probe:SetAlpha(0)
    button:ClearAllPoints()
    Place(button, g.start, startFrame, g.start)
    local holder, text = entry.holder, entry.text
    -- One holder unit is one screen pixel where the scale is known; the fill is
    -- the step in whole pixels. Unknown scale: units, as the row's own frames.
    local px = PixelsPerUnit(button)
    holder:SetScale(px and 1 / px or 1)
    holder:ClearAllPoints()
    if not Place(holder, g.start, startFrame, g.start) then return false end
    text:SetFont(STANDARD_TEXT_FONT, 12, "")
    text:SetWordWrap(false)
    text:SetJustifyH(g.sign[1] < 0 and "RIGHT" or "LEFT")
    -- Invisible: the fill texture ignores the text colour (seen as a dark line).
    text:SetAlpha(0)
    text:ClearAllPoints()
    -- Anchors see the text as exactly its fill, and as nothing when empty
    -- (GetRight reports a one-pixel minimum that anchors do not use), so the
    -- fill is the step in whole pixels and the text starts at the display.
    text:SetPoint(g.start, holder, g.start)
    local along = g.sign[1] ~= 0
    -- A texture in a text does not render at its stated size (a 44 pixel fill
    -- measured 43.27 on a scaled group), and an empty text is one pixel long.
    -- So the fill is chosen by measuring: the size whose rendered length is
    -- closest to the step plus one pixel; the next display then starts one
    -- pixel back from the text's end, filled or empty (SetFlowEnd), and any
    -- remainder of the match is folded into that offset.
    local target = math.max(1, math.floor(length * (px or 1) + 0.5)) + 1
    local probe = entry.probe
    probe:SetFont(STANDARD_TEXT_FONT, 12, "")
    probe:SetWordWrap(false)
    probe:ClearAllPoints()
    probe:SetPoint(g.start, holder, g.start)
    local function Markup(n) return ("|TInterface\\Buttons\\WHITE8X8:%d:%d|t"):format(along and 1 or n, along and n or 1) end
    local best, bestLength
    for n = math.max(1, target - 3), target + 3 do
      probe:SetText(Markup(n))
      local rendered = along and probe:GetStringWidth() or probe:GetStringHeight()
      if type(rendered) == "number" and not issecretvalue(rendered) and rendered > 0
        and (not best or math.abs(rendered - target) < math.abs(bestLength - target)) then
        best, bestLength = n, rendered
      end
    end
    probe:SetText("")
    if not best then best, bestLength = target, target end
    -- Pixels back from the text's end to the next display: one for the empty
    -- text, plus whatever the fill renders over the target.
    entry.back = 1 + (bestLength - target)
    fill = Markup(best)
    -- Stack Count: Blizzard writes the count through the formatter, also 0.
    if property == "stacks" then text:SetTextColor(0, 0, 0, 0) end
    text:Show()
    return true
  end
  local native = region.blizzardAuraDisplay
  local probeBuild = native and native.probeBuild
  if not entry then
    entry = {}
    local placed, setupErr = false, nil
    local ok = pcall(container.AddAuraSlot, container, key, Display.FilterString(trigger), {
      candidateFilters = Display.CandidateFilters(data),
      initializeFrame = function(button)
        entry.button = button
        button:EnableMouse(false)
        button:SetAlpha(0)
        button:SetSize(1, 1)
        -- The client calls this through an error boundary of its own, so a
        -- failed setup is recorded, not raised.
        local okSetup, result = pcall(setup, button)
        placed = okSetup and result == true
        if not placed then setupErr = okSetup and "measurement not placed" or result end
      end,
    })
    if not ok or not entry.button then
      if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "measure " .. tostring(key), ok and "no button" or "AddAuraSlot failed") end
      return
    end
    store[key] = entry
    container:SetAuraSlotEnabled(key, false)
    if not placed then
      -- Counted with the build's failures (SecretAuraSingle.lua, NoteSlotFailure).
      if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "measure " .. tostring(key), setupErr) end
      if probeBuild and Display.NotePendingRelayout then Display.NotePendingRelayout(region) end
      return
    end
  else
    if probeBuild then
      -- A slot made earlier is locked now: it keeps measuring as it is,
      -- untouched (tried before it is disabled, rc.15 review), and the
      -- display is applied again when the restrictions end
      -- (SecretAuraSingle.lua, SlotWrite).
      local wasComplete = entry.complete
      local okSetup, result = pcall(setup, entry.button)
      if not (okSetup and result == true) then
        -- A measurement that had finished keeps working as it is: no failure.
        -- One that had not is incomplete, counted with the build's failures.
        if not wasComplete and Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "measure " .. tostring(key), okSetup and "locked" or result) end
        if Display.NotePendingRelayout then Display.NotePendingRelayout(region) end
        -- Only a measurement whose setup had finished is kept (rc.17
        -- review: a partial one has unbound, unplaced text).
        entry.complete = wasComplete
        return wasComplete and entry or nil
      end
      container:SetAuraSlotEnabled(key, false)
    else
      container:SetAuraSlotEnabled(key, false)
      if not setup(entry.button) then return end
    end
  end
  container:SetAuraSlotFilterString(key, Display.FilterString(trigger))
  container:SetAuraSlotCandidateFilters(key, Display.CandidateFilters(data))
  container:SetAuraSlotSortMethod(key, Display.SortOrder(data, trigger))
  local text = entry.text
  local formatter, formatterErr = Display.GateFormatter(lower, upper, fill)
  if not formatter then
    -- A refused formatter counts like a refused binding (rc.52 review).
    if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "measure " .. tostring(key) .. " formatter", formatterErr) end
    return
  end
  if not measureCurve then
    measureCurve = C_CurveUtil.CreateColorCurve()
    measureCurve:SetType(Enum.LuaCurveType.Step)
    measureCurve:AddPoint(0, CreateColor(0, 0, 0, 0))
  end
  pcall(entry.button.ClearDurationText, entry.button)
  pcall(entry.button.ClearApplicationCount, entry.button)
  -- A refused binding is counted with the build's failures too
  -- (SecretAuraSingle.lua, NoteSlotFailure), so a measurement left unbound
  -- never passes as a finished build (rc.51 review).
  if property == "stacks" then
    local okBind, errBind = pcall(entry.button.SetApplicationCount, entry.button, text, {formatter = formatter})
    if not okBind then
      if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "measure " .. tostring(key) .. " count", errBind) end
      return
    end
  else
    property = Enum.DurationTextBindingProperty[property or "RemainingDuration"]
    local okBind, errBind = pcall(entry.button.SetDurationText, entry.button, text, {
      textFormat = {formatString = "{}", components = {{property = property, formatter = formatter}}},
      textColor = {curve = measureCurve, property = property},
    })
    if not okBind then
      if Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "measure " .. tostring(key) .. " text", errBind) end
      return
    end
  end
  container:SetAuraSlotEnabled(key, true)
  entry.enabledApplied = true   -- (dev.92) DisableMeasure writes the disable once
  -- Complete only now, bound and enabled (rc.18 review): a locked slot kept
  -- on a later build is one that measured.
  entry.complete = true
  return entry
end

local function DisableMeasure(instance, key)
  local entry = instance and instance.flowRemainSlots and instance.flowRemainSlots[key]
  -- (dev.92, Astra's dev.90 review) written once: the client refreshes the whole container on every
  -- SetAuraSlotEnabled, even to the state the slot already has, which hands the list's buttons out again
  if entry and entry.enabledApplied ~= false then
    if pcall(instance.container.SetAuraSlotEnabled, instance.container, key, false) then entry.enabledApplied = false end
  end
end

-- Called by Apply after the flow shadows, before the display's end is recorded.
function Display.EnsureFlowRemaining(region, data)
  local native = region.blizzardAuraDisplay
  local flow = native and native.flow
  local instance = native and native.instances[1]
  local trigger = Display.GetTrigger(data)
  local lower, upper
  local property
  -- ForeverAuras (cell chain): a chained list measures itself; no slot.
  local chained = Display.FlowChain ~= nil and Display.FlowChain(data) ~= nil
  if flow and instance and trigger and not chained and not Display.FlowFrameMode(data) and not Display.FlowGrid(Display.FlowGroup(data)) then
    lower, upper = Display.RemainingRange(trigger)
    -- Gated displays take space only while their gate is open.
    if not lower then
      local kind, n = Display.StackGate(data, trigger)
      if kind == "exactly" then lower, upper, property = n, n, "stacks"
      elseif kind == "atLeast" then lower, property = n, "stacks"
      elseif kind == "atMost" then lower, upper, property = 0, n, "stacks" end
    end
    if not lower then
      lower, upper = Display.DurationGate(data, trigger)
      if lower then property = "TotalDuration" end
    end
  end
  if flow then flow.remain, flow.shadowRemain = nil, nil end
  if not lower then
    DisableMeasure(instance, FLOW_REMAIN)
    DisableMeasure(instance, FLOW_REMAIN_SHADOW)
    return
  end
  instance.flowRemainSlots = instance.flowRemainSlots or {}
  local _, spacing = Display.FlowGrowth(data)
  local width, height = Display.Dimensions(data)
  local g = flow.growth
  local size = ((g.sign[1] ~= 0) and width or height) + spacing
  local main = MeasureText(region, instance, FLOW_REMAIN, data, trigger, g, flow.start, size, lower, upper, property)
  flow.remain = main and main.text
  flow.remainBack = main and main.back
  local shadow = main and g.shadow and flow.shadowStart
    and MeasureText(region, instance, FLOW_REMAIN_SHADOW, data, trigger, g.shadow, flow.shadowStart, Display.FlowHalf(region, size), lower, upper, property)
  if shadow then
    HideShadow(instance, "flowShadow")
    flow.shadowKind, flow.shadowList, flow.shadowRemain = "remain", nil, shadow.text
    flow.shadowRemainBack = shadow.back
  else
    DisableMeasure(instance, FLOW_REMAIN_SHADOW)
  end
end

-- The native content delegate can update a protected measurement without
-- moving or rebinding it. Only the currently active, same-token parts qualify.
function Display.RefreshFlowContent(instance, unit, shown, force)
  local accepted, refused = 0, 0
  if instance.flowMeasureActive and instance.flowMeasure then
    accepted, refused = Display.RequestBoundAuraRefresh(instance.flowMeasure, instance.flowMeasureUnit, unit, shown, force)
  end
  if instance.flowShadowActive and instance.flowShadow then
    local a, r = Display.RequestBoundAuraRefresh(instance.flowShadow, instance.flowShadowUnit, unit, shown, force)
    accepted, refused = accepted + a, refused + r
  end
  return accepted, refused
end

function Display.RefreshMeasureContainer(instance, container, unitKey, unit, shown, force)
  if Busy(container) then
    Display.RequestBoundAuraRefresh(container, instance[unitKey], unit, shown, force)
    return false
  end
  if unit and instance[unitKey] ~= unit then
    container:SetEnabled(false)
    container:SetUnit(unit)
    instance[unitKey] = unit
  end
  if container:IsShown() ~= shown then container:SetShown(shown) end
  if container.faEnabled ~= shown or (shown and force) then
    container:SetEnabled(shown)
    if shown then container:UpdateAllAuras() end
  end
end
-- Keeps a display's list shadow on the same unit as its aura area.
-- force: see Display.RefreshSingle.
function Display.RefreshFlowShadow(instance, unit, shown, force)
  -- ForeverAuras (dev.78): the end measurement's container follows the unit as the shadow does
  local ready = true
  if instance.flowMeasureActive and instance.flowMeasure then
    ready = Display.RefreshMeasureContainer(instance, instance.flowMeasure, "flowMeasureUnit", unit, shown, force) ~= false
  end
  local container = instance.flowShadowActive and instance.flowShadow
  if not container then return ready end
  if Busy(container) then
    Display.RequestBoundAuraRefresh(container, instance.flowShadowUnit, unit, shown, force)
    return false
  end
  if unit and instance.flowShadowUnit ~= unit then
    container:SetEnabled(false)
    container:SetUnit(unit)
    instance.flowShadowUnit = unit
  end
  -- Enabled and refreshed only when its state changes (faEnabled, TrackEnabled).
  if container:IsShown() ~= shown then container:SetShown(shown) end
  if container.faEnabled ~= shown or (shown and force) then
    container:SetEnabled(shown)
    if shown then container:UpdateAllAuras() end
  end
  return ready
end

-- Chains one display's shadows from its shadow start; returns where the next
-- display's shadows start.
local function ChainShadows(flow)
  local sh = flow.growth.shadow
  if flow.shadowKind == "list" then
    for index, container in ipairs(flow.shadowList) do
      if not InCombatLockdown() then container:ClearAllPoints() end
      local ok
      if index == 1 then
        ok = Place(container, sh.start, flow.shadowStart, sh.start)
      else
        ok = Place(container, sh.start, flow.shadowList[index - 1], sh.listEnd, sh.pixel[1], sh.pixel[2])
      end
      if not ok and not InCombatLockdown() then
        container:ClearAllPoints()
        container:SetPoint(sh.start, flow.region, sh.start)
      end
    end
    return {flow.shadowList[#flow.shadowList], sh.listEnd, sh.pixel[1], sh.pixel[2]}
  elseif flow.shadowKind == "remain" then
    -- The shadow measure's own pixels back (see SetFlowEnd).
    local px = PixelsPerUnit(flow.shadowStart) or 1
    local back = (flow.shadowRemainBack or 1) / px
    return {flow.shadowRemain, sh.far, -sh.sign[1] * back, -sh.sign[2] * back}
  elseif flow.shadowKind == "missing" then
    local single = flow.region.blizzardAuraDisplay.instances[1].single.missing
    return {single.flowShadow, sh.start, 0, 0}
  elseif flow.shadowKind == "chain" then
    -- ForeverAuras (dev.74): the shadow chain's end, once every shadow cell
    -- is bound (its start corner is the last shadow cell's point: half the
    -- member's length back); a fixed spot until then
    local sc = flow.shadowChain
    if sc and sc.flow.chainEndReady and sc.flow.chainEnd then
      -- (dev.79) a locally measured shadow: its end translated to the shadow start (EnsureMeasureChain)
      if sc.out and sc.outCorner then return {sc.out, sc.outCorner, 0, 0} end
      return {sc.flow.chainEnd, sc.flow.chainCorner or sh.start, 0, 0}
    end
    -- ForeverAuras (dev.82): a shadow prepared under restrictions without its
    -- records (EnsureChainShadow, opts.defer) is chained by its translated
    -- end all the same: that end depends on nothing yet, so what hangs from
    -- it can be anchored there now, and follows the records once they bind.
    if sc and sc.scaffold and sc.out and sc.outCorner and sc.flow.chainEndWired then return {sc.out, sc.outCorner, 0, 0} end
  end
  return {flow.shadowStart, sh.start, sh.sign[1] * flow.half, sh.sign[2] * flow.half}
end

-- ForeverAuras (dev.82): a Centered row under restrictions. Each member's
-- shadow is prepared during its build without its records (EnsureChainShadow,
-- opts.defer), the row's pass chains the shadows and places the visible start
-- on their end while every end still depends on nothing, and once no live
-- member of the row is queued any more (the row built last-to-first, its
-- first member last) the records are bound here, member by member: every
-- anchor into the shadows exists by then, so the client moves the finished
-- row onto the centre itself. Before anything binds, the placements are
-- checked (Astra's dev.81 review: a built row is not a centred one): every
-- shadow start on the shadows before it (the first on the row's centre) and
-- the row's start on the shadows' end; a missing one is said and nothing is
-- bound (the row then starts at the centre, as it did, until restrictions
-- end). Called by FinishApply after each build under restrictions. Returns
-- the members whose shadows were bound (their containers take the unit
-- next, RefreshUnits), or nil while a member is still queued, a placement
-- is missing, or the row is not a Centered row with cells.
function Display.ActivateShadows(group)
  if not (group and InCombatLockdown() and Display.FlowGroupOwned(group)) then return nil end
  local g = GROWTH[GrowthKey(group)]
  if not (g and g.shadow and Display.FlowIndependentGroup(group) and Display.ShadowDeferred) then return nil end
  local waiting = {}
  local rowFrame = RowOrigin(group)
  local previousEnd, first = nil, true
  for _, id in ipairs(Display.FlowOrder(group)) do
    local r, _, native, normal = LiveMember(id, group)
    if r and Display.IsBuildPending and Display.IsBuildPending(r) then return nil, id end
    local flow = native and native.active and native.flow or normal and normal.flow
    if flow and flow.shadowStart and flow.shadowKind and r:IsShown() then
      local place = flow.shadowStart.faPlace
      local expected = previousEnd and previousEnd[1] or rowFrame
      if not (place and place[2] == expected) then
        -- (quiet while a load batch holds the row's pass: that pass places it and asks again, Astra's dev.83 review)
        if Display.BuildReport and not (Display.FlowLoadHeld and Display.FlowLoadHeld()) then Display.BuildReport(("%s's shadow is not on the shadows before it (%s): the shadows stay unbound until the row's pass places it"):format(tostring(id), place and "on another frame" or "not placed yet")) end
        return nil, id
      end
      local ok, chained = pcall(ChainShadows, flow)
      if not ok then return nil, id end
      previousEnd = chained
      if first then
        first = false
        if not flow.startPlaced then
          if Display.BuildReport then Display.BuildReport(("%s: the row's start is not on the shadows' end: the shadows stay unbound until the row's pass places it"):format(tostring(id))) end
          return nil, id
        end
      end
    end
    if r and native and Display.ShadowDeferred(native) then waiting[#waiting + 1] = {r, native} end
  end
  local done = {}
  -- bound from the LAST member's shadow back to the first: a shadow's start hangs from the shadow before it, so
  -- the one before binds after the one after it (nothing is written to it then anyway: EnsureMeasureChain keeps
  -- a prepared chain as it is, but the order costs nothing and asks nothing of the client)
  for index = #waiting, 1, -1 do
    local w = waiting[index]
    local r, native = w[1], w[2]
    local data = native.data
    local instance = native.instances and native.instances[1]
    local made, why
    -- (dev.84, Astra's dev.83 review P2) each member's binding under its own protection: an exception in one is
    -- that member's failure, reported, its chain no longer "applying", and the members bound before it keep
    -- their result (their containers take the unit all the same)
    if instance and data then
      local okB, madeB, whyB = pcall(Display.EnsureChainShadow, r, data, native, instance, true)
      if okB then made, why = madeB, whyB else made, why = nil, "exception: " .. tostring(madeB); if native.flow and native.flow.shadowChain then native.flow.shadowChain.applying = nil end end
    else why = "no instance" end
    if Display.BuildReport then
      local sc = native.flow and native.flow.shadowChain
      Display.BuildReport(made and ("%s shadow measured: %d records, end %s (bound with the row in place)"):format(tostring(data and data.id), sc and #sc.buttons or 0, (sc and sc.flow.chainEndReady) and "ready" or "NOT ready")
        or ("%s shadow could not be bound (%s): a fixed half step until restrictions end"):format(tostring(data and data.id), tostring(why)))
    end
    if made then
      done[#done + 1] = r
      -- (dev.89) a repaired shadow drops its explanation
      if native.flow then native.flow.shadowChainProblem = nil end
      if data and data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_shadow", nil, nil) end
    elseif native.flow then
      native.flow.shadowKind, native.flow.shadowChainProblem = "fixed", why
      -- (dev.89, Astra's dev.88 review) said in the editor too, under its own key, until the repair
      if data and data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then
        Private.AuraWarnings.UpdateWarning(data.uid, "blizzard_aura_shadow", "warning", L["This display's share of the centred row could not be measured (%s); it keeps a fixed half step until restrictions end."]:format(tostring(why)))
      end
      if native.flow.shadowChain then native.flow.shadowChain.scaffold = nil end
      -- (dev.87, Astra's dev.85 review P2) a fixed half step until restrictions end, and then the member is
      -- applied again through the bounded relayout request (the restriction-end handler): its shadow is made
      -- anew then, out of restrictions
      if Display.NotePendingRelayout then Display.NotePendingRelayout(r, "shadow: " .. tostring(why)) end
    end
  end
  return done
end

-- Grouped by frame: for every unit, its aura area in the first display sits
-- on the unit's frame, and each later display's area follows the previous one.
-- Called after any display in the group rebinds its units, also in combat,
-- like the aura list's own unit anchoring.
-- The group's own frame: on the screen, the row starts (or centres) at its
-- anchor point, like a Dynamic Group's children. nil before it exists.
-- The editor's nameplate stand-in (the Personal Resource Display frame),
-- shown while the options are open, as for a Dynamic Group grouped by
-- nameplate. Released when the group no longer uses it.
local function NameplatePreview(group)
  if not (Private.ensurePRDFrame and WeakAuras.IsOptionsOpen()) then return end
  Private.ensurePRDFrame()
  local frame = Private.personalRessourceDisplayFrame
  if frame and frame.anchorFrame then frame:anchorFrame(group.id, "NAMEPLATE") end
  return frame
end

-- Grouped by frame, the editor's box for a display (the frame the mover and
-- selection outline use) is moved onto its preview icons, as a Dynamic Group
-- moves its children onto the nameplate stand-in. The display's own anchor is
-- kept and put back when the preview ends or the group stops using frames.
local function MovePreviewRegion(region, button)
  if not (region.SetAnchor and region.SetOffset) then return end
  -- Anchored anywhere else, the anchor is the display's own (set again by
  -- the editor after a change), so it is the one to keep.
  -- Only an anchor that is not one of the preview samples is the display's own.
  if region.relativeTo ~= button and not (type(region.relativeTo) == "table" and region.relativeTo.bindings) then
    region.flowPreviewSaved = {region.anchorPoint, region.relativeTo, region.relativePoint,
      region.GetXOffset and region:GetXOffset() or 0, region.GetYOffset and region:GetYOffset() or 0}
  end
  region:SetAnchor("TOPLEFT", button, "TOPLEFT")
  region:SetOffset(0, 0)
end

function Display.RestorePreviewRegion(region)
  local saved = region and region.flowPreviewSaved
  if not saved then return end
  region.flowPreviewSaved = nil
  if saved[1] and saved[2] then region:SetAnchor(saved[1], saved[2], saved[3]) end
  region:SetOffset(saved[4], saved[5])
end

-- The group's own editor box: its frame is placed by the addon on the frame
-- the preview uses (Private.AnchorFrame, FlowPreviewFrame), and its bounds
-- are set to cover the first unit's preview row, which starts at the group's
-- anchor. Put back when the group no longer previews on a frame.
-- The group's editor rectangle (GetBoundingRect), in the group's units from
-- its anchor point: bottom-left and top-right corners.
local function SetGroupPreviewRect(group, blx, bly, trx, try)
  local entry = Private.regions[group.id]
  local region = entry and entry.region
  if not region then return end
  if region.GetBoundingRect ~= region.flowPreviewBoundsFn then
    region.flowPreviewBoundsSaved = region.GetBoundingRect
  end
  local changed = region.blx ~= blx or region.bly ~= bly or region.trx ~= trx or region.try ~= try
  region.flowPreviewBoundsFn = function(self)
    self.blx, self.bly, self.trx, self.try = blx, bly, trx, try
    return blx, bly, trx, try
  end
  region.GetBoundingRect = region.flowPreviewBoundsFn
  region:GetBoundingRect()
  -- ForeverAuras: the editor's box (MoverSizer) reads the rectangle when the
  -- group is picked, and the arrangement that sets it often runs after that
  -- (next frame, or after a batched pick): a changed rectangle moves the box
  -- of the picked group at once.
  if changed and WeakAuras.RefreshMoverSizer then WeakAuras.RefreshMoverSizer(group.id) end
end

-- Grouped by frame: the rectangle from the row's length and depth.
local function SetGroupPreviewBounds(group, g, length, cross, ox, oy)
  local blx, bly, trx, try
  if g.sign[1] > 0 then blx, trx, try, bly = 0, length, 0, -cross
  elseif g.sign[1] < 0 then blx, trx, try, bly = -length, 0, 0, -cross
  elseif g.sign[2] < 0 then blx, trx, try, bly = 0, cross, 0, -length
  else blx, trx, bly, try = 0, cross, 0, length end
  SetGroupPreviewRect(group, blx + ox, bly + oy, trx + ox, try + oy)
end

function Display.RestoreGroupPreview(group)
  local entry = group and Private.regions[group.id]
  local region = entry and entry.region
  if not region then return end
  if region.flowPreviewBoundsSaved then
    if region.GetBoundingRect == region.flowPreviewBoundsFn then region.GetBoundingRect = region.flowPreviewBoundsSaved end
    region.flowPreviewBoundsSaved, region.flowPreviewBoundsFn = nil, nil
    region.boundingRect = false
    region:GetBoundingRect()
    if WeakAuras.RefreshMoverSizer then WeakAuras.RefreshMoverSizer(group.id) end
  end
end

-- ForeverAuras: the group's editor rectangle around the given frames (the
-- union of their rectangles, cut to `clip` when it is shown), in the group's
-- units from the group's anchored point (its selfPoint: CENTER for most
-- groups, BOTTOMLEFT for groups with a group offset), which is what the
-- editor's box measures from. Restores the plain rectangle when nothing can
-- be measured. Used by the row preview (ArrangeFlowPreviewNow) and the Grid
-- preview (SecretAuraGrid.lua).
function Display.SetGroupPreviewUnion(group, groupRegion, frames, clip)
  local anchorX, anchorY
  if groupRegion then
    local selfPoint = group.selfPoint or "CENTER"
    local ok, l, b, w, h = pcall(groupRegion.GetRect, groupRegion)
    if ok and type(l) == "number" and not issecretvalue(l) and not issecretvalue(b) and not issecretvalue(w) and not issecretvalue(h) then
      anchorX = selfPoint:find("LEFT") and l or selfPoint:find("RIGHT") and l + w or l + w / 2
      anchorY = selfPoint:find("BOTTOM") and b or selfPoint:find("TOP") and b + h or b + h / 2
    end
  end
  local groupScale = groupRegion and groupRegion:GetEffectiveScale()
  if anchorX and type(groupScale) == "number" and groupScale > 0 then
    local minX, minY, maxX, maxY
    local function Extend(frame)
      local ok, l, b, w, h = pcall(frame.GetRect, frame)
      if not ok or type(l) ~= "number" or issecretvalue(l) or issecretvalue(b) or issecretvalue(w) or issecretvalue(h) then return end
      local scale = frame:GetEffectiveScale()
      if type(scale) ~= "number" or issecretvalue(scale) or scale <= 0 then return end
      -- Screen pixels first, the group's units from its anchor at the end.
      local x1, y1 = l * scale, b * scale
      local x2, y2 = (l + w) * scale, (b + h) * scale
      minX, maxX = math.min(minX or x1, x1), math.max(maxX or x2, x2)
      minY, maxY = math.min(minY or y1, y1), math.max(maxY or y2, y2)
    end
    for _, frame in ipairs(frames) do Extend(frame) end
    if clip and clip:IsShown() and minX then
      local ok, l, b, w, h = pcall(clip.GetRect, clip)
      local scale = clip:GetEffectiveScale()
      if ok and type(l) == "number" and not issecretvalue(l) and type(scale) == "number" and scale > 0 then
        minX, maxX = math.max(minX, l * scale), math.min(maxX, (l + w) * scale)
        minY, maxY = math.max(minY, b * scale), math.min(maxY, (b + h) * scale)
      end
    end
    if minX and maxX > minX and maxY > minY then
      local ax, ay = anchorX * groupScale, anchorY * groupScale
      SetGroupPreviewRect(group, (minX - ax) / groupScale, (minY - ay) / groupScale, (maxX - ax) / groupScale, (maxY - ay) / groupScale)
    else
      Display.RestoreGroupPreview(group)
    end
  else
    Display.RestoreGroupPreview(group)
  end
end

function Display.ReleaseNameplatePreview(group)
  local frame = Private.personalRessourceDisplayFrame
  if group and frame and frame.anchorFrame then frame:anchorFrame(group.id, nil) end
end

-- Grouped by frame, the group's Position and Size settings (To Frame's point
-- and offsets) place the first aura on each frame.
local function FramePosition(group)
  return group.anchorPoint or "CENTER", tonumber(group.xOffset) or 0, tonumber(group.yOffset) or 0
end

-- Grouped by frame, the group's Anchor point places the row on the To
-- Frame's point across its growth direction (icon size, known here): top,
-- middle or bottom of a horizontal row; left, middle or right of a vertical
-- one. Along the growth, Centered growth centres it; the others start there.
local function CrossOffset(group, g, cross)
  local selfPoint = group.selfPoint or "CENTER"
  if g.sign[1] ~= 0 then
    if selfPoint:find("TOP") then return 0, 0 end
    if selfPoint:find("BOTTOM") then return 0, cross end
    return 0, cross / 2
  end
  if selfPoint:find("LEFT") then return 0, 0 end
  if selfPoint:find("RIGHT") then return -cross, 0 end
  return -cross / 2, 0
end

local function AlignedPoints(group, g)
  local selfPoint = group.selfPoint or "CENTER"
  local horizontal = g.sign[1] ~= 0
  local cross
  if horizontal then
    cross = selfPoint:find("TOP") and "TOP" or selfPoint:find("BOTTOM") and "BOTTOM" or ""
  else
    cross = selfPoint:find("LEFT") and "LEFT" or selfPoint:find("RIGHT") and "RIGHT" or ""
  end
  local function Align(point)
    if horizontal then return cross .. (point:find("LEFT") and "LEFT" or "RIGHT") end
    return (point:find("TOP") and "TOP" or "BOTTOM") .. cross
  end
  return Align(g.start), Align(g.listEnd), Align(g.far)
end

-- ForeverAuras: the plate's visible bar (WeakAuras.GetUnitNameplate: the
-- nameplate addon's health bar, or the client's unit frame inside the
-- plate), as a Dynamic Group grouped by nameplate uses. The NamePlate frame
-- itself is wider than the bar drawn in it, so a row anchored to its edge
-- sat well clear of the plate.
-- The client's own plates on this client keep their bar in an unnamed frame
-- (no UnitFrame field for the lookup to find), so the first status bar
-- inside the plate is taken as the bar; the plate itself when there is none.
local barOf = setmetatable({}, {__mode = "k"})
local function FirstStatusBar(frame, depth)
  for _, child in ipairs({frame:GetChildren()}) do
    if child:GetObjectType() == "StatusBar" then return child end
    if depth > 1 then
      local found = FirstStatusBar(child, depth - 1)
      if found then return found end
    end
  end
end
local function NameplateAnchor(unit)
  local frame = WeakAuras.GetUnitNameplate and WeakAuras.GetUnitNameplate(unit)
  if frame and frame.IsForbidden and not frame:IsForbidden() then return frame end
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate or plate:IsForbidden() then return plate end
  local unitFrame = plate.UnitFrame
  local bar = unitFrame and (unitFrame.healthBar or (unitFrame.HealthBarsContainer and unitFrame.HealthBarsContainer.healthBar))
  if not bar then
    bar = barOf[plate]
    if bar == nil then
      bar = FirstStatusBar(plate, 3) or false
      barOf[plate] = bar
    end
  end
  if bar and bar.IsForbidden and not bar:IsForbidden() then return bar end
  return plate
end
Display.NameplateAnchor = NameplateAnchor

local function UnitAnchor(mode, unit)
  local frame = mode == "UNITFRAME" and WeakAuras.GetUnitFrame(unit) or (mode == "NAMEPLATE" and NameplateAnchor(unit))
  if frame and not frame:IsForbidden() then return frame end
end

-- While an event refreshes many displays, each group is re-anchored once at
-- the end (EndFlowBatch) instead of once per display.
local batch, gridBatch
function Display.BeginFlowBatch() batch, gridBatch = batch or {}, gridBatch or {} end
function Display.EndFlowBatch()
  local groups, grids = batch, gridBatch
  batch, gridBatch = nil, nil
  for group in pairs(groups or {}) do Display.RelinkFlowUnits(group) end
  for group in pairs(grids or {}) do Display.RefreshGrid(group) end
end

-- During a batch, each grid is refreshed once at its end.
function Display.DeferGridRefresh(group)
  if not gridBatch then return false end
  gridBatch[group] = true
  return true
end

function Display.FlowUnitStart(group)
  return (AlignedPoints(group, GROWTH[GrowthKey(group)]))
end

function Display.RelinkFlowUnits(group)
  local mode = group and group.blizzardFlowFrames
  if mode ~= "UNITFRAME" and mode ~= "NAMEPLATE" then return end
  if batch then batch[group] = true; return end
  local g = GROWTH[GrowthKey(group)]
  -- The group's own Position and Size settings, relative to each frame.
  local point, frameX, frameY = FramePosition(group)
  local start, listEnd, far = AlignedPoints(group, g)
  local spacing = tonumber(group.blizzardFlowSpacing) or 2
  local halfSpacing = math.floor(spacing / 2)
  -- Centred: per unit, the shadows run backwards from the frame point first.
  local lastShadow = {}
  local sh = g.shadow
  local shStart, shEnd
  if sh then shStart, shEnd = AlignedPoints(group, sh) end
  if sh then
    for _, childID in ipairs(group.controlledChildren or {}) do
      local entry = Private.regions[childID]
      local native = entry and entry.region and entry.region.blizzardAuraDisplay
      if native and native.active then
        for _, instance in ipairs(native.instances) do
          local unit = instance.visible and instance.boundUnit
          local shadow = unit and instance.flowShadowActive and instance.flowShadow
          if shadow and not Busy(shadow) then
            shadow:ClearAllPoints()
            local linked = lastShadow[unit] and Place(shadow, shStart, lastShadow[unit], shEnd, sh.pixel[1], sh.pixel[2])
            local frame = not linked and UnitAnchor(mode, unit)
            if frame then shadow:SetPoint(shStart, frame, point, frameX, frameY) end
            lastShadow[unit] = shadow
          end
        end
      end
    end
  end
  local last = {}
  for _, childID in ipairs(group.controlledChildren or {}) do
    local entry = Private.regions[childID]
    local native = entry and entry.region and entry.region.blizzardAuraDisplay
    if native and native.active then
      local missingOnly = Display.ShowOn(Display.GetTrigger(native.data) or {}) == "showOnMissing"
      local width, height = Display.Dimensions(native.data)
      local along = g.sign[1] ~= 0
      local spacing = Display.FlowSpacing(group, entry.region, along and width or height)
      halfSpacing = Display.FlowHalf(entry.region, spacing)
      -- The display's own X/Y Offset moves its part of each unit's row only
      -- (OwnOffset): the next display's anchor takes it back off.
      local ox, oy = OwnOffset(native.data)
      for _, instance in ipairs(native.instances) do
        local unit = instance.visible and instance.boundUnit
        if unit and not Busy(instance.container) then
          local container = instance.container
          container:ClearAllPoints()
          local previous = last[unit]
          local linked = previous and Place(container, start, previous[1], previous[2], previous[3] + ox, previous[4] + oy)
          if not linked and lastShadow[unit] then
            -- Centred: start where the shadows end, half a spacing on.
            linked = Place(container, start, lastShadow[unit], shEnd,
              sh.pixel[1] + g.sign[1] * halfSpacing + ox, sh.pixel[2] + g.sign[2] * halfSpacing + oy)
          end
          if not linked then
            local frame = UnitAnchor(mode, unit)
            if frame then
              -- Centred without a list shadow on this unit (Show On: Missing,
              -- or a gated list): nothing ran backwards from the frame point,
              -- so the row would start there and sit half a display to the
              -- side. Start half a step back instead: half the display's
              -- step less half a spacing, each a whole number of pixels, the
              -- sum the options preview uses (ArrangeFlowPreview, Offset), so
              -- the live row lands on the preview's pixel.
              local back = 0
              if sh then
                back = Display.FlowHalf(entry.region, (along and width or height) + spacing)
                  - Display.FlowHalf(entry.region, Display.FlowSpacing(group, entry.region, 0))
              end
              container:ClearAllPoints()
              container:SetPoint(start, frame, point, frameX - g.sign[1] * back + ox, frameY - g.sign[2] * back + oy)
            end
          end
          last[unit] = {container, listEnd, g.pixel[1] - ox, g.pixel[2] - oy}
          local missing = instance.single and instance.single.missing
          local slot = missing and missing.active and missing.slot
          if slot then
            local size = (along and width or height) + spacing
            last[unit] = {slot, listEnd, g.sign[1] * spacing - ox, g.sign[2] * spacing - oy}
            local presence = missingOnly and missing.presenceActive and missing.presence
            if presence then
              presence:ClearAllPoints()
              if Place(presence, far, slot, start, g.sign[1] * (size + 1), g.sign[2] * (size + 1)) then
                last[unit] = {presence, start, -ox, -oy}
              end
            end
          end
        end
      end
    end
  end
end

-- Options preview: the samples are plain frames of known size, so they are
-- simply lined up in the group's order, on a nameplate or unit frame when the
-- group is grouped by frame (the first display's preview unit), else starting
-- at the first display.
-- The units a display previews on, grouped by unit frame: those of its unit
-- setting that exist and have a frame (Smart Group: you and your party),
-- like a Dynamic Group's preview clones. {false} otherwise: one row.
local MAX_PREVIEW_UNITS = 5
function Display.FlowPreviewUnits(data)
  if Display.FlowFrameMode(data) ~= "UNITFRAME" then return {false} end
  local units = {}
  for _, unit in ipairs(Display.UnitTokens(Display.GetTrigger(data) or {})) do
    if UnitExists(unit) and WeakAuras.GetUnitFrame(unit) then
      units[#units + 1] = unit
      if #units >= MAX_PREVIEW_UNITS then break end
    end
  end
  if #units == 0 then units[1] = "player" end
  return units
end

-- The frame a unit's preview row sits on: the editor's nameplate stand-in, or
-- the unit's frame.
local function PreviewFrame(group, unit)
  local frame
  if group.blizzardFlowFrames == "NAMEPLATE" then
    frame = NameplatePreview(group)
  elseif unit then
    frame = WeakAuras.GetUnitFrame(unit)
  end
  if frame and not frame:IsForbidden() then return frame end
end

-- The frame the group itself is anchored to in the editor, so its box and
-- Position and Size settings work on the frame, as for a Dynamic Group grouped
-- by frame. nil when the group is not grouped by frame or the options are closed.
function Display.FlowPreviewFrame(group)
  local mode = group and group.blizzardFlow and group.blizzardFlowFrames
  if (mode ~= "UNITFRAME" and mode ~= "NAMEPLATE") or not WeakAuras.IsOptionsOpen() then return end
  local unit
  for _, childID in ipairs(group.controlledChildren or {}) do
    local child = WeakAuras.GetData(childID)
    if child and Display.Enabled(child) then
      unit = Display.FlowPreviewUnits(child)[1]
      break
    end
  end
  return PreviewFrame(group, unit or "player")
end

-- ForeverAuras: a gated member of a row (a Remaining Time, Total Duration or
-- Stack Count filter) takes its row space from a measurement text inside a
-- locked aura slot. A member anchored after it hangs from that text, and the
-- client then treats the member's whole container as locked in combat: a
-- button the client adds to it then (a buff list growing, or the client's
-- own refresh making new buttons) cannot be built, an empty slot until the
-- fight ends (probed in game, 1.2.0-rc.28: the member after the Remaining
-- Time icon had an unreadable container in combat, the same member placed
-- before it did not).
function Display.FlowGated(data)
  if not data or not Display.Enabled(data) then return false end
  local trigger = Display.GetTrigger(data)
  if not trigger then return false end
  if Display.UsesGate(data) then return true end
  return Display.RemainingRange ~= nil and Display.RemainingRange(trigger) ~= nil
end

-- The order a row chains its members in: the group's order, with the gated
-- members moved to the end (keeping their order among themselves), so no
-- other member hangs from a locked measurement. Decided from the settings,
-- so the live row and the editor preview agree; only for the rows the
-- problem is known for: a Centered row's start hangs from every member's
-- shadow (the whole row would move), and Grid and Group by Frame rows are
-- laid out differently. Those keep the group's order.
function Display.FlowOrder(group)
  local ids = group and group.controlledChildren or {}
  if not group or Display.FlowGrid(group) or group.blizzardFlowFrames ~= nil then return ids end
  -- Supported independent-carrier rows preserve the configured member order.
  -- Other rows retain the ordinary filtered-last ordering below.
  if Display.FlowIndependentGroup and Display.FlowIndependentGroup(group) then return ids end
  if (GROWTH[group.blizzardFlowGrowth] or GROWTH.RIGHT).shadow then return ids end
  local order, gated = {}, nil
  for _, childID in ipairs(ids) do
    if Display.FlowGated(WeakAuras.GetData(childID)) then
      gated = gated or {}
      gated[#gated + 1] = childID
    else
      order[#order + 1] = childID
    end
  end
  if not gated then return ids end
  for _, childID in ipairs(gated) do order[#order + 1] = childID end
  return order
end

-- What the order above cannot solve, said in the editor: a second gated
-- member still hangs from the first one's measurement, and in a Centered
-- row the gated member's own shadow is in the chain every member's start
-- hangs from (the row's centre is a secret distance from its start).
function Display.FlowAfterGateProblem(data)
  local group = Display.FlowGroup(data)
  if not group or Display.FlowGrid(group) or group.blizzardFlowFrames ~= nil or not Display.FlowGated(data) then return end
  -- ForeverAuras (cell chain): a chained list hangs from no measurement.
  if Display.FlowChain and Display.FlowChain(data) then return end
  if (GROWTH[group.blizzardFlowGrowth] or GROWTH.RIGHT).shadow then
    return L["This aura's time or stack filter may leave it blank during combat in a Centered row.\n\nChoose another Grow setting, or move this aura out of the group."]
  end
  for _, childID in ipairs(group.controlledChildren or {}) do
    if childID == data.id then return end
    if Display.FlowGated(WeakAuras.GetData(childID)) then
      return L["Another aura in this row also uses a time or stack filter. This aura may appear blank or in the wrong place during combat.\n\nMove it to a separate row or group."]
    end
  end
end

function Display.FlowNormalProblem(data)
  local group = Display.FlowGroup(data)
  if not group or Display.Enabled(data) or Display.FlowNormal(data) then return end
  for _, entry in ipairs(data.triggers or {}) do
    if type(entry) == "table" and type(entry.trigger) == "table" and entry.trigger.type == "secretAura" then return end
  end
  if data.regionType == "group" or data.regionType == "dynamicgroup" then
    return L["Groups inside a Modern Aura Group keep their own position."]
  end
  if group.blizzardFlowFrames ~= nil or Display.FlowGrid(group) then
    return L["With Grid or Group by Frame, only Aura (Modern) displays line up. This display keeps its own position."]
  end
  return L["Anchored to a unit frame, nameplate, the mouse or a custom anchor, this display keeps its own position."]
end

local function NormalSize(region, data)
  local width, height = region.width, region.height
  if type(width) ~= "number" or issecretvalue(width) then width = tonumber(data.width) or 1 end
  if type(height) ~= "number" or issecretvalue(height) then height = tonumber(data.height) or 1 end
  return width * math.abs(region.scalex or 1), height * math.abs(region.scaley or 1)
end

-- Options preview: the samples are plain frames of known size, so they are
-- lined up in the group's order: per unit on its frame (or on the nameplate
-- stand-in) when grouped by frame, else starting at the first display.
local PlaceNormalRegion
local previewOrigins = {}
local ArrangeFlowPreviewNow
function Display.ArrangeFlowPreview(group)
  if not group then return end
  -- During a load scan or the editor's batched pick of a large group the
  -- arrangement waits for Display.EndFlowLoad, like the rechain: every
  -- display's refresh arranged the whole pack's samples again, which grew
  -- with the square of the pack's size over the pick (issue #136).
  if loadScan > 0 then queued[group] = true; return end
  -- Timed here, so every caller is counted (/fa pprint).
  Private.StartProfileSystem("aura (modern) - group layout: preview")
  ArrangeFlowPreviewNow(group)
  Private.StopProfileSystem("aura (modern) - group layout: preview")
end
function ArrangeFlowPreviewNow(group)
  if Display.FlowGrid(group) then
    Display.ReleaseNameplatePreview(group)
    -- ForeverAuras: a row's editor rectangle does not carry over to a Grid;
    -- the Grid preview sets its own (ArrangeGridPreview) or restores it.
    if not Display.ArrangeGridPreview(group) then Display.RestoreGroupPreview(group) end
    return
  end
  local mode = group.blizzardFlowFrames
  local framed = mode == "UNITFRAME" or mode == "NAMEPLATE"
  if mode ~= "NAMEPLATE" then Display.ReleaseNameplatePreview(group) end
  local g = GROWTH[GrowthKey(group)]
  local spacing = tonumber(group.blizzardFlowSpacing) or 2
  local along = g.sign[1] ~= 0
  -- The gap after a display of a size, in whole pixels as the live row has it
  -- (Display.FlowSpacing), so the preview is spaced like the live row.
  local groupEntry = Private.regions[group.id]
  local function Spaced(size) return Display.FlowSpacing(group, groupEntry and groupEntry.region, size) end
  local point, frameX, frameY = FramePosition(group)
  -- ForeverAuras: group-owned row (FlowGroupOwned): the samples and ordinary
  -- displays are lined up from the group's anchor in the group's order, each
  -- member's own offset on that member only, as the live chain places them.
  local owned = not framed and Display.FlowGroupOwned(group)
  local originFrame, originPoint
  if owned then originFrame, originPoint = RowOrigin(group) end
  if owned and not originFrame then owned = false end
  for _, childID in ipairs(group.controlledChildren or {}) do
    local entry = Private.regions[childID]
    local region = entry and entry.region
    local normal = region and region.flowNormal
    if normal and normal.active and normal.stand then PlaceNormalRegion(region, normal) end
  end
  local function Key(sample) return framed and mode == "UNITFRAME" and sample.previewUnit or "" end
  -- Each row's length and depth, known here; centred rows start half back.
  local length, cross, firstKey, sampleStep, iconStep, anyStep = {}, {}, nil, nil, nil, nil
  -- The row's cross size as the live chain takes it (RowStep: the first
  -- Modern display's, else the first copied icon's, else the first display's).
  local sampleCross, iconCross, anyCross
  local leadSteps = {}
  -- The last display's spacing is not part of the row; the row's lengths
  -- were summed with the pixel gaps, so the gap taken off is the same kind.
  local lastSpacing = {}
  -- Centred: the live row's shadows run back half a step per display, each
  -- half a whole number of pixels (Display.FlowHalf); summed here the same way.
  local halves = {}
  local groupRegionForHalf = Private.regions[group.id] and Private.regions[group.id].region
  local function Half(step) return Display.FlowHalf(groupRegionForHalf, step) end
  -- ForeverAuras: the row's order (Display.FlowOrder: gated members last), as
  -- the live row chains them. The first sample's step is the Limit's step, so
  -- this loop runs in that order too (rc.31 review: the preview cut at the
  -- gated first display's size, the live row at its first chained display's).
  local rowOrder = Display.FlowOrder(group)
  -- The old row layout starts at the group's first member's own frame, and
  -- measures own offsets from that member's, even when the row's order moved
  -- it behind the others (RechainFlow, rowFlow): that member's region here.
  -- Only when the two orders differ in their first such member (rc.33
  -- review: with a leading ordinary display first in both, the Modern
  -- display after it was taken for a moved reference).
  local referenceRegion, startedAtReference
  if not framed and not owned and not g.shadow then
    local function FirstInRow(ids)
      for _, childID in ipairs(ids) do
        local entry = Private.regions[childID]
        local region = entry and entry.region
        if region and region:IsShown() and (region.secretAuraSamplesActive
          or (region.flowNormal and region.flowNormal.active and region.flowNormal.stand)) then
          return region
        end
      end
    end
    local firstInGroup = FirstInRow(group.controlledChildren or {})
    if firstInGroup and firstInGroup.secretAuraSamplesActive and firstInGroup ~= FirstInRow(rowOrder) then
      referenceRegion = firstInGroup
      -- Its box may still sit on its sample from the last arrangement; the
      -- row starts at the box's own anchor, so that is put back first.
      Display.RestorePreviewRegion(referenceRegion)
    end
  end
  for _, childID in ipairs(rowOrder) do
    local entry = Private.regions[childID]
    local region = entry and entry.region
    if region and region.secretAuraSamplesActive and region:IsShown() then
      for _, sample in ipairs(region.secretAuraSamples or {}) do
        local button = sample.button
        if button:IsShown() then
          local key = Key(sample)
          firstKey = firstKey or key
          local width, height = button:GetWidth() or 0, button:GetHeight() or 0
          sampleStep = sampleStep or (along and width or height) + Spaced(along and width or height)
          sampleCross = sampleCross or (along and height or width)
          length[key] = (length[key] or 0) + (along and width or height) + Spaced(along and width or height)
          lastSpacing[key] = Spaced(along and width or height)
          halves[key] = (halves[key] or 0) + Half((along and width or height) + Spaced(along and width or height))
          cross[key] = math.max(cross[key] or 0, along and height or width)
        end
      end
    elseif region and region.flowNormal and region.flowNormal.active and region:IsShown()
      and (not g.shadow or region.flowNormal.stand) then
      local width, height = NormalSize(region, region.flowNormal.data)
      local step = (along and width or height) + Spaced(along and width or height)
      anyStep = anyStep or step
      anyCross = anyCross or (along and height or width)
      if region.flowNormal.stand and region.flowNormal.data.regionType == "icon" then
        iconStep = iconStep or step
        iconCross = iconCross or (along and height or width)
      end
      if not region.flowNormal.stand then leadSteps[#leadSteps + 1] = step end
      length[""] = (length[""] or 0) + (along and width or height) + Spaced(along and width or height)
      lastSpacing[""] = Spaced(along and width or height)
      halves[""] = (halves[""] or 0) + Half(step)
      cross[""] = math.max(cross[""] or 0, along and height or width)
    end
  end
  local limit = not framed and group.blizzardFlowUseLimit and math.max(1, math.floor(tonumber(group.blizzardFlowLimit) or 5))
  local firstStep = sampleStep or iconStep or anyStep
  -- ForeverAuras: a group-owned row's place across the row (RechainFlow,
  -- CrossOffset): added to the first member's offset and to the cut.
  local ownedCrossX, ownedCrossY = 0, 0
  if owned then ownedCrossX, ownedCrossY = CrossOffset(group, g, sampleCross or iconCross or anyCross or 0) end
  local rowStart
  -- How far back the row starts: the shadows' halves less half a spacing (the
  -- last display's gap is not part of the row; the live row steps forward by
  -- that half, RechainFlow), no further than half the limit's window, exactly
  -- as the live row is placed (see the shadow chain and CapRowStart), so the
  -- preview sits on the same pixel. Added instead, the preview sat a whole
  -- spacing behind the live row and the row jumped when the options closed.
  local function Offset(key)
    if not g.shadow then return 0, 0 end
    local half = (halves[key] or 0) - Half(Display.FlowSpacing(group, groupRegionForHalf, 0))
    if limit and firstStep then
      local window = (limit * firstStep - (lastSpacing[key] or spacing)) / 2
      local px = PixelsPerUnit(groupRegionForHalf)
      -- Half a pixel comes out a hair under it in floating point (109.49999
      -- for 109.5); the small addition rounds it up like the live cap.
      if px then window = math.floor(window * px + 0.5 + 0.001) / px end
      half = math.min(half, window)
    end
    half = math.max(0, half)
    return -g.sign[1] * half, -g.sign[2] * half
  end
  local previous = {}
  -- ForeverAuras: every frame the arrangement placed (samples, stands and
  -- ordinary displays in the row), for the group's editor rectangle below.
  local placed = {}
  -- The previous sample's own display offset per row key, taken back off (OwnOffset).
  local previousOwn = {}
  -- The first display's own offset per row key, off a frame (see PlaceSamples).
  local firstOwn = {}
  local onFrame = false
  -- A centred row starts half its length back, which can fall between two
  -- pixels; nothing here is secret, so the start is put on a whole pixel.
  local function WholePixel(object, frame, anchor, ox, oy)
    local factor = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor()
    if not factor or factor <= 0 or not object.GetEffectiveScale then return ox, oy end
    local ok, left, bottom, width, height = pcall(frame.GetRect, frame)
    if not ok or type(left) ~= "number" or issecretvalue(left) or issecretvalue(bottom)
      or issecretvalue(width) or issecretvalue(height) then return ox, oy end
    local frameScale, objectScale = frame:GetEffectiveScale(), object:GetEffectiveScale()
    local x = anchor:find("LEFT") and left or anchor:find("RIGHT") and left + width or left + width / 2
    local y = anchor:find("TOP") and bottom + height or anchor:find("BOTTOM") and bottom or bottom + height / 2
    local function Round(position, offset)
      local pixels = (position * frameScale + offset * objectScale) / factor
      return offset + (math.floor(pixels + 0.5) - pixels) * factor / objectScale
    end
    return Round(x, ox), Round(y, oy)
  end
  -- Where the first display's box is, so its sample can start there while the
  -- box itself moves onto the sample.
  local function Origin(region)
    local origin = previewOrigins[group.id] or CreateFrame("Frame", nil, UIParent)
    previewOrigins[group.id] = origin
    origin:ClearAllPoints()
    if region.anchorPoint and region.relativeTo then
      origin:SetPoint(region.anchorPoint, region.relativeTo, region.relativePoint,
        region.GetXOffset and region:GetXOffset() or 0, region.GetYOffset and region:GetYOffset() or 0)
    else
      origin:SetPoint("CENTER", region, "CENTER")
    end
    local width, height = region:GetWidth(), region:GetHeight()
    if issecretvalue(width) or issecretvalue(height) then width, height = region.width or 1, region.height or 1 end
    -- The origin lives under UIParent, so it takes the display's scale (a
    -- scaled group) to be the display's size: sized in UIParent units it was
    -- smaller, and its corners, where the row starts, sat inside the display.
    local scale, parentScale = region:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if type(scale) == "number" and type(parentScale) == "number" and not issecretvalue(scale)
      and not issecretvalue(parentScale) and parentScale > 0 then
      origin:SetScale(scale / parentScale)
    else
      origin:SetScale(1)
    end
    origin:SetSize(width, height)
    return origin
  end
  local function PlaceNormal(region)
    local normal = region.flowNormal
    local inRow = not g.shadow or normal.stand ~= nil
    -- Group-owned row: the display's own offset moves it alone, so it is put
    -- on and remembered for the next member to take back off.
    local ownX, ownY = 0, 0
    if owned then ownX, ownY = OwnOffset(normal.data) end
    if inRow and previous[""] then
      region:SetAnchor(g.start, previous[""], g.far)
      local gap = Spaced(along and previous[""]:GetWidth() or previous[""]:GetHeight())
      -- A preceding Modern sample's own offset is taken back off (OwnOffset),
      -- as the live row does; an ordinary display carries none itself.
      local back = previousOwn[""] or {0, 0}
      region:SetOffset(g.sign[1] * gap + ownX - back[1], g.sign[2] * gap + ownY - back[2])
      previousOwn[""] = owned and {ownX, ownY} or nil
    elseif inRow and owned then
      -- First member: on the group's anchor.
      local ox, oy = Offset("")
      ox, oy = WholePixel(region, originFrame, originPoint, ox + ownedCrossX, oy + ownedCrossY)
      region:SetAnchor(g.start, originFrame, originPoint)
      region:SetOffset(ox + ownX, oy + ownY)
      previousOwn[""] = {ownX, ownY}
    elseif inRow and g.shadow then
      local ox, oy = Offset("")
      ox, oy = WholePixel(region, normal.home, g.centerPoint, ox, oy)
      region:SetAnchor(g.start, normal.home, g.centerPoint)
      region:SetOffset(ox, oy)
    elseif inRow and normal.stand and referenceRegion and not previous[""] then
      -- ForeverAuras: a copied ordinary display starting the row when the
      -- group's first member (a gated Modern display) moved behind it: at
      -- that member's own anchor, as the live row starts (rowFlow). An
      -- ordinary display that leads the row starts at its own place, as live.
      startedAtReference = Origin(referenceRegion)
      region:SetAnchor(g.start, startedAtReference, g.start)
      region:SetOffset(0, 0)
    else
      region:SetAnchor(g.start, normal.home, g.start)
      region:SetOffset(0, 0)
    end
    if inRow then placed[#placed + 1] = region end
    if inRow and not previous[""] then
      rowStart = region
      -- An ordinary first display's offset is the row's first offset too
      -- (FlowOwnOffset), so a Modern sample after it adds the difference only.
      -- ForeverAuras: with a reference display, the offsets are measured
      -- from that display's (RowOffset), whichever display starts the row.
      local reference = normal.stand and referenceRegion and referenceRegion.blizzardAuraDisplay
      firstOwn[""] = {OwnOffset(reference and reference.data or normal.data)}
    end
    if inRow then previous[""] = region end
  end
  local function PlaceSamples(region)
    if not framed then Display.RestorePreviewRegion(region) end
    local moved = false
    local native = region.blizzardAuraDisplay
    local ownX, ownY = OwnOffset(native and native.data)
    for _, sample in ipairs(region.secretAuraSamples or {}) do
      local button = sample.button
      if button:IsShown() then
        local key = Key(sample)
        local frame = framed and PreviewFrame(group, sample.previewUnit or nil)
        local ox, oy = Offset(key)
        -- Off a frame, offsets are relative to the first display's, as in the
        -- live row (RowOffset): its place already carries its own offset, so
        -- it adds none, and a later display moves by the difference from the
        -- first's offset only, not by its whole offset again. The same
        -- relative offset is what the next display (a Modern sample or an
        -- ordinary display, PlaceNormal) takes back off.
        local addX, addY = ownX, ownY
        if not framed and not owned then
          if not previous[key] then
            -- ForeverAuras: measured from the reference display's offset when
            -- another display starts the row (see referenceRegion).
            local reference = referenceRegion and referenceRegion.blizzardAuraDisplay
            firstOwn[key] = {OwnOffset(reference and reference.data or native and native.data)}
          end
          local first = firstOwn[key] or {0, 0}
          addX, addY = ownX - first[1], ownY - first[2]
        end
        ox, oy = ox + addX, oy + addY
        -- The group's anchor point only places the row on a frame; on the
        -- screen the row sits on the first display's box, as the live auras do.
        local start, far = g.start, g.far
        if framed then
          local alignedStart, _, alignedFar = AlignedPoints(group, g)
          start, far = alignedStart, alignedFar
        end
        button:ClearAllPoints()
        if previous[key] then
          local gap = Spaced(along and previous[key]:GetWidth() or previous[key]:GetHeight())
          local back = previousOwn[key] or {0, 0}
          button:SetPoint(start, previous[key], far, g.sign[1] * gap + addX - back[1], g.sign[2] * gap + addY - back[2])
        elseif owned then
          -- Group-owned row: the first sample sits on the group's anchor, a
          -- centred row half its length back from it.
          ox, oy = WholePixel(button, originFrame, originPoint, ox + ownedCrossX, oy + ownedCrossY)
          button:SetPoint(g.start, originFrame, originPoint, ox, oy)
        elseif frame then
          button:SetPoint(start, frame, point, frameX + ox, frameY + oy)
        elseif g.shadow then
          -- Group by Frame with no frame found for this sample: the display's
          -- box may still sit on a sample from the last arrangement, and the
          -- origin follows the box, so anchoring the sample to it would be a
          -- cycle ("Cannot anchor to a region dependent on it"). Put the box
          -- back on its own anchor first; it is not moved again below.
          if framed then Display.RestorePreviewRegion(region) end
          local origin = Origin(region)
          ox, oy = WholePixel(button, origin, g.centerPoint, ox, oy)
          button:SetPoint(g.start, origin, g.centerPoint, ox, oy)
        else
          -- As above.
          if framed then Display.RestorePreviewRegion(region) end
          -- ForeverAuras: at the reference display's own anchor when another
          -- display starts the row (see referenceRegion), as the live row.
          -- Its own offset's difference from the reference display's is
          -- applied (addX/addY, in ox/oy), as the live row applies it to its
          -- first chained display.
          -- Only then: off a frame the own offset is already in the box's
          -- place (rc.33 review: it was added twice).
          if referenceRegion then
            startedAtReference = Origin(referenceRegion)
            button:SetPoint(g.start, startedAtReference, g.start, ox, oy)
          else
            button:SetPoint(g.start, Origin(region), g.start)
          end
        end
        -- The display's own box follows its first icon.
        if (frame or not framed) and not moved then
          MovePreviewRegion(region, button)
          moved = true
        end
        onFrame = onFrame or frame ~= nil and frame ~= false
        placed[#placed + 1] = button
        if not framed and not previous[key] then rowStart = button end
        previous[key] = button
        previousOwn[key] = {addX, addY}
      end
    end
    if not moved then Display.RestorePreviewRegion(region) end
  end
  -- Ordinary displays that are not copied lead the row (in both row modes:
  -- they cannot hang from a secret-length container), then samples and
  -- stands in the row's order (Display.FlowOrder, as the live row chains
  -- them: gated members last).
  for _, childID in ipairs(rowOrder) do
    local entry = Private.regions[childID]
    local region = entry and entry.region
    if region and not region.secretAuraSamplesActive and region.flowNormal and region.flowNormal.active
      and not region.flowNormal.stand and region:IsShown() then
      PlaceNormal(region)
    end
  end
  for _, childID in ipairs(rowOrder) do
    local entry = Private.regions[childID]
    local region = entry and entry.region
    if region and region.secretAuraSamplesActive and region:IsShown() then
      PlaceSamples(region)
    elseif region and region.flowNormal and region.flowNormal.active and region.flowNormal.stand and region:IsShown() then
      PlaceNormal(region)
    end
  end
  -- Group-owned row: the cut starts at the group's anchor (a centred row
  -- half the limit's window back, like the live cap), not at the first
  -- sample, whose own offset moves the sample alone (see UpdateFlowClip).
  local clipOrigin
  if owned and rowStart and limit then
    local ox, oy = 0, 0
    if g.shadow and firstStep then
      local window = (limit * firstStep - (lastSpacing[""] or spacing)) / 2
      local px = PixelsPerUnit(groupRegionForHalf)
      if px then window = math.floor(window * px + 0.5 + 0.001) / px end
      ox, oy = -g.sign[1] * window, -g.sign[2] * window
    end
    ox, oy = WholePixel(rowStart, originFrame, originPoint, ox + ownedCrossX, oy + ownedCrossY)
    clipOrigin = {originFrame, originPoint, ox, oy}
  elseif startedAtReference and rowStart and limit then
    -- ForeverAuras: the row started at the reference display's own anchor
    -- (referenceRegion); the live cut starts there too (UpdateFlowClip,
    -- flows.origin), not at the first display, which its offset may move.
    -- The origin frame as it was placed then (startedAtReference): placed
    -- again here it would follow the reference display's box, which has
    -- moved onto its sample since, a sample that hangs from this origin
    -- (an anchor loop; rc.34 review).
    clipOrigin = {startedAtReference, g.start, 0, 0}
  end
  if limit and Display.PreviewFlowClip then Display.PreviewFlowClip(group, g, rowStart, leadSteps, firstStep, clipOrigin) end
  if onFrame and firstKey then
    local ox, oy = Offset(firstKey)
    local cx, cy = CrossOffset(group, g, cross[firstKey] or 0)
    ox, oy = ox + cx, oy + cy
    SetGroupPreviewBounds(group, g, math.max(0, (length[firstKey] or 0) - (lastSpacing[firstKey] or spacing)), cross[firstKey] or 0, ox, oy)
  elseif not framed and #placed > 0 then
    -- ForeverAuras: the row's box in the editor (its selection outline and
    -- mover, from GetBoundingRect) covers the previewed row as a Dynamic
    -- Group's box covers its children: the rectangle around every frame the
    -- arrangement placed, offsets and sizes included, cut to the Limit's
    -- window when there is one (the clip frame, PreviewFlowClip), in the
    -- group's units from its anchor point. Without this the box was the
    -- children's own frames, all sitting on the anchor: one icon centred on
    -- the row's start, half of it beside the row. Shared with the Grid
    -- preview (SecretAuraGrid.lua, ArrangeGridPreview).
    local clip = limit and Display.PreviewClipFrame and Display.PreviewClipFrame(group)
    Display.SetGroupPreviewUnion(group, groupRegionForHalf, placed, clip)
  else
    Display.RestoreGroupPreview(group)
  end
end


-- Limit: nothing can count the shown auras in combat, so the row is cut off
-- by a clipping frame between the group and its displays. A centred row is
-- also kept from starting further back than the limit allows: a frame
-- stretched from that cap to the row start collapses onto the cap when the
-- row is longer, so its far edge is whichever is further on.
local clips, caps = {}, {}
-- ForeverAuras: the group's cut frame, for the editor rectangle (ArrangeFlowPreviewNow).
function Display.PreviewClipFrame(group)
  return group and clips[group.id]
end
local CLIP_MARGIN = 600

-- How to stretch a frame between the cap and the row start so that one of its
-- edges is whichever of the two is further along the row. Learned once from
-- plain frames, out of combat; nil when no way works.
local stretchRules = {}
Display.flowStretchRules = stretchRules
local EDGE_POINT = {LEFT = "TOPLEFT", RIGHT = "TOPRIGHT", TOP = "TOPLEFT", BOTTOM = "BOTTOMLEFT"}
local function StretchRule(vertical)
  if stretchRules[vertical] ~= nil then return stretchRules[vertical] or nil end
  if InCombatLockdown() then return end
  local edges = vertical and {"TOP", "BOTTOM"} or {"LEFT", "RIGHT"}
  local cap = CreateFrame("Frame", nil, UIParent)
  local start = CreateFrame("Frame", nil, UIParent)
  local probe = CreateFrame("Frame", nil, UIParent, "DisableUntrustedLayoutScriptsTemplate")
  cap:SetSize(1, 1); start:SetSize(1, 1); probe:SetSize(1, 1)
  cap:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  local function Read(frame, edge)
    if edge == "LEFT" then return frame:GetLeft() elseif edge == "RIGHT" then return frame:GetRight()
    elseif edge == "TOP" then return frame:GetTop() else return frame:GetBottom() end
  end
  local found = false
  for _, capEdge in ipairs(edges) do
    local startEdge = capEdge == edges[1] and edges[2] or edges[1]
    for _, capFirst in ipairs({true, false}) do
      for _, readEdge in ipairs(edges) do
        local good = true
        -- Further along the row: right, or down.
        for _, distance in ipairs({20, -20}) do
          start:ClearAllPoints()
          start:SetPoint("CENTER", cap, "CENTER", vertical and 0 or distance, vertical and -distance or 0)
          probe:ClearAllPoints()
          local function ToCap() probe:SetPoint(EDGE_POINT[capEdge], cap, "CENTER") end
          local function ToStart() probe:SetPoint(EDGE_POINT[startEdge], start, "CENTER") end
          if capFirst then ToCap(); ToStart() else ToStart(); ToCap() end
          local capX, capY = cap:GetCenter()
          local startX, startY = start:GetCenter()
          local value = Read(probe, readEdge)
          local wanted = vertical and math.min(capY, startY) or math.max(capX, startX)
          if not value or math.abs(value - wanted) > 1 then good = false break end
        end
        if good then
          found = {capPoint = EDGE_POINT[capEdge], startPoint = EDGE_POINT[startEdge], readPoint = EDGE_POINT[readEdge], capFirst = capFirst}
          break
        end
      end
      if found then break end
    end
    if found then break end
  end
  for _, frame in ipairs({cap, start, probe}) do frame:ClearAllPoints(); frame:Hide() end
  stretchRules[vertical] = found
  return found or nil
end

local function ClipWanted(group)
  if not group or not group.blizzardFlowUseLimit then return false end
  if Display.FlowGrid(group) or group.blizzardFlowFrames ~= nil then return false end
  local key = GrowthKey(group)
  if key == "CENTER_HORIZONTAL" or key == "CENTER_VERTICAL" then return StretchRule(key == "CENTER_VERTICAL") ~= nil end
  return true
end

local function GroupRegion(group)
  local entry = Private.regions[group.id]
  return entry and entry.region
end

-- Displays anchored to a chosen frame and parented to it keep that parent.
local function KeepsParent(data)
  return data and data.anchorFrameType == "SELECTFRAME" and data.anchorFrameParent ~= false
end

-- Keeps the display's own strata and level.
local function Reparent(region, parent)
  local strata = region:GetFrameStrata()
  -- Counted for /fa phitch: reparenting a display walks all of its frames.
  if Private.HitchCount then Private.HitchCount("display SetParent") end
  region:SetParent(parent)
  region:SetFrameStrata(strata)
  if Private.ApplyFrameLevel and region.id then Private.ApplyFrameLevel(region) end
end

-- A clip draws its children on its own strata, so it takes the lowest strata
-- its displays are set to; each display keeps its own strata and level.
local strataRank = {BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8}

local function MatchClipStrata(clip, groupRegion)
  local lowest
  for _, child in ipairs({clip:GetChildren()}) do
    local data = child.id and WeakAuras.GetData and WeakAuras.GetData(child.id)
    if data then
      local strata = Private.frame_strata_types and Private.frame_strata_types[data.frameStrata or 1]
      if not strataRank[strata] then strata = groupRegion:GetFrameStrata() end
      if strataRank[strata] and (not lowest or strataRank[strata] < strataRank[lowest]) then lowest = strata end
    end
  end
  lowest = lowest or groupRegion:GetFrameStrata()
  if clip:GetFrameStrata() == lowest then return end
  local children = {clip:GetChildren()}
  local strata = {}
  for index, child in ipairs(children) do strata[index] = child:GetFrameStrata() end
  clip:SetFrameStrata(lowest)
  for index, child in ipairs(children) do
    child:SetFrameStrata(strata[index])
    if Private.ApplyFrameLevel and child.id then Private.ApplyFrameLevel(child) end
  end
end

local function EnsureClip(group)
  local groupRegion = GroupRegion(group)
  if not groupRegion then return end
  local clip = clips[group.id]
  if not clip then
    clip = CreateFrame("Frame", nil, groupRegion)
    clip:EnableMouse(false)
    clip:SetAllPoints(groupRegion)
    clips[group.id] = clip
  end
  if not Busy(clip) then
    if clip:GetParent() ~= groupRegion then clip:SetParent(groupRegion) end
    Display.ClipChildren(clip)
    clip:Show()
  end
  return clip
end

-- The frame a display of the group is parented to, or nil for the group itself.
function Display.FlowClipParent(data)
  local group = Display.FlowGroup(data)
  if not ClipWanted(group) or KeepsParent(data) then return end
  -- With Centered growth only icons and texts join a legacy row; the rest keep
  -- their own place. A group-owned row takes every display (FlowGroupOwned).
  local inRow = Display.Enabled(data) or Display.FlowNormal(data)
    and (Display.FlowGroupOwned(group) or not GROWTH[GrowthKey(group)].shadow or Display.UsesStand ~= nil and Display.UsesStand(data))
  if inRow then return EnsureClip(group) end
end

local function FlowData(flow)
  return flow.normal and flow.normal.data or flow.region.blizzardAuraDisplay and flow.region.blizzardAuraDisplay.data
end

-- One icon and its spacing along the row: from the first Aura (Modern)
-- display, else the first copied icon, else the first display.
local function RowStep(group, g, flows)
  local pick
  for _, flow in ipairs(flows) do
    if not flow.normal then pick = flow break end
  end
  if not pick then
    for _, flow in ipairs(flows) do
      if flow.stand and flow.normal.data.regionType == "icon" then pick = flow break end
    end
  end
  pick = pick or flows[1]
  local width, height
  if pick.normal then
    width, height = NormalSize(pick.region, pick.normal.data)
  else
    width, height = Display.Dimensions(pick.region.blizzardAuraDisplay.data)
  end
  local spacing = Display.FlowSpacing(group, pick.region, (g.sign[1] ~= 0) and width or height)
  return ((g.sign[1] ~= 0) and width or height) + spacing, spacing, width, height
end

local function Limit(group)
  return math.max(1, math.floor(tonumber(group.blizzardFlowLimit) or 5))
end

-- How far the first `limit` displays reach: displays that lead the row count
-- with their own length, the rest with one icon each.
local function WindowLength(limit, leadSteps, step, spacing)
  local length, count = 0, 0
  for _, lead in ipairs(leadSteps) do
    if count >= limit then break end
    length, count = length + lead, count + 1
  end
  return length + (limit - count) * step - spacing
end

local function LeadSteps(flows)
  local steps = {}
  for _, flow in ipairs(flows) do
    if flow.home and not flow.stand then steps[#steps + 1] = math.abs(flow.x) + math.abs(flow.y) end
  end
  return steps
end

-- Centred: where the visible row starts, no further back than the limit.
-- originFrame/originPoint: a group-owned row's start (RowOrigin); nil for the
-- legacy row, which starts at the first display.
local function CapRowStart(group, g, flows, previous, combat, snapX, snapY, originFrame, originPoint)
  if not previous or not ClipWanted(group) then return previous end
  local vertical = g.sign[1] == 0
  local rule = StretchRule(vertical)
  if not rule then return previous end
  local parent = GroupRegion(group) or UIParent
  local cap = caps[group.id]
  if not cap then
    cap = {left = CreateFrame("Frame", nil, parent),
      joint = CreateFrame("Frame", nil, parent, "DisableUntrustedLayoutScriptsTemplate")}
    cap.left:SetSize(1, 1)
    cap.left:EnableMouse(false)
    cap.joint:SetSize(1, 1)
    cap.joint:EnableMouse(false)
    caps[group.id] = cap
  end
  if not combat then
    for _, frame in ipairs({cap.left, cap.joint}) do
      if frame:GetParent() ~= parent then frame:SetParent(parent) end
    end
  end
  local step, spacing = RowStep(group, g, flows)
  local origin = originFrame or flows[1].home or flows[1].region
  local centerPoint = originFrame and originPoint or g.centerPoint
  local back = WindowLength(Limit(group), {}, step, spacing) / 2
  -- A whole number of pixels, so the cap does not depend on engine rounding
  -- (the options preview caps its row the same way).
  local px = PixelsPerUnit(origin)
  if px then back = math.floor(back * px + 0.5 + 0.001) / px end
  if not combat then cap.left:ClearAllPoints() end
  -- From the same whole-pixel centre the shadows start from (snapX, snapY),
  -- so a capped row starts on the pixel the options preview puts it on.
  Place(cap.left, "TOPLEFT", origin, centerPoint, (vertical and 0 or -back) + (snapX or 0), (vertical and back or 0) + (snapY or 0))
  if not combat then cap.joint:ClearAllPoints() end
  local function ToCap() return Place(cap.joint, rule.capPoint, cap.left, "TOPLEFT") end
  local function ToStart() return Place(cap.joint, rule.startPoint, previous.endFrame, previous.endPoint, previous.x, previous.y) end
  local ok
  if rule.capFirst then ok = ToCap() and ToStart() else ok = ToStart() and ToCap() end
  if not ok then return previous end
  return {endFrame = cap.joint, endPoint = rule.readPoint, x = 0, y = 0}
end

-- The cut: from well before the row start (glows and texts of the first icon)
-- to the end of the last display within the limit plus its spacing.
-- How far to move the cut so its corner lands on a whole screen pixel: a cut
-- between pixels redraws what it holds blurred. 0 when the anchor's place is unknown.
local function PixelNudge(clip, anchor, point, offsetX, offsetY)
  local factor = PixelUtil and PixelUtil.GetPixelToUIUnitFactor and PixelUtil.GetPixelToUIUnitFactor()
  if not factor or factor <= 0 then return 0, 0 end
  -- ForeverAuras: the anchor's point may be a centre (a group-owned row
  -- starts at the group's CENTER), read as such.
  local ok, x, y = pcall(function()
    local cx, cy = anchor:GetCenter()
    return point:find("LEFT") and anchor:GetLeft() or point:find("RIGHT") and anchor:GetRight() or cx,
      point:find("TOP") and anchor:GetTop() or point:find("BOTTOM") and anchor:GetBottom() or cy
  end)
  if not ok or type(x) ~= "number" or type(y) ~= "number" or issecretvalue(x) or issecretvalue(y) then return 0, 0 end
  local anchorScale, clipScale = anchor:GetEffectiveScale(), clip:GetEffectiveScale()
  local function Nudge(value, offset)
    local pixels = (value * anchorScale + offset * clipScale) / factor
    return (math.floor(pixels + 0.5) - pixels) * factor / clipScale
  end
  return Nudge(x, offsetX), Nudge(y, offsetY)
end

-- relativePoint, ox, oy: where on the anchor the row starts, when not the
-- clip's own corner (a group-owned row starts at the group's anchor point).
local function SetWindow(clip, g, point, anchor, length, width, height, spacing, relativePoint, ox, oy)
  relativePoint, ox, oy = relativePoint or point, ox or 0, oy or 0
  -- The cut ends at the last display's far edge, not after its spacing: a cut
  -- that reaches the next display shows that display's first pixel column
  -- (its border) when the edge falls between pixels. The length is rounded to
  -- whole pixels so the edge is a pixel boundary (the start corner is nudged
  -- onto one below), also in the options preview, whose spacing is unrounded.
  local after = length + CLIP_MARGIN
  local px = PixelsPerUnit(clip)
  if px then after = math.floor(after * px + 0.5) / px end
  local horizontal = point:find("LEFT") and -1 or 1
  local vertical = point:find("TOP") and 1 or -1
  local nudgeX, nudgeY = PixelNudge(clip, anchor, relativePoint, horizontal * CLIP_MARGIN + ox, vertical * CLIP_MARGIN + oy)
  clip:ClearAllPoints()
  clip:SetPoint(point, anchor, relativePoint, horizontal * CLIP_MARGIN + ox + nudgeX, vertical * CLIP_MARGIN + oy + nudgeY)
  if g.sign[1] ~= 0 then
    clip:SetSize(after, height + 2 * CLIP_MARGIN)
  else
    clip:SetSize(width + 2 * CLIP_MARGIN, after)
  end
end

-- Options preview: the samples are placed in Lua, so the cut starts at the
-- first one. origin: a group-owned row's start (frame, point, x, y; see
-- ArrangeFlowPreviewNow), where the live cut starts too: the first sample's
-- own offset moves the sample, not the cut.
function Display.PreviewFlowClip(group, g, rowStart, leadSteps, step, origin)
  local clip = clips[group.id]
  if not clip or not ClipWanted(group) or not rowStart or not step or Busy(clip) then return end
  -- The same whole-pixel gap the samples are spaced by.
  local spacing = Display.FlowSpacing(group, rowStart, (g.sign[1] ~= 0) and rowStart:GetWidth() or rowStart:GetHeight())
  local length = WindowLength(Limit(group), leadSteps, step, spacing)
  if origin then
    SetWindow(clip, g, g.start, origin[1], length, rowStart:GetWidth() or 0, rowStart:GetHeight() or 0, spacing,
      origin[2], origin[3], origin[4])
  else
    SetWindow(clip, g, g.start, rowStart, length, rowStart:GetWidth() or 0, rowStart:GetHeight() or 0, spacing)
  end
end

function Display.UpdateFlowClip(group, flows, g)
  if not group then return end
  local wanted = ClipWanted(group)
  local clip = wanted and EnsureClip(group) or clips[group.id]
  if not clip or Busy(clip) then return end
  local groupRegion = GroupRegion(group)
  if not wanted or not groupRegion then
    if not InCombatLockdown() then
      for _, child in ipairs({clip:GetChildren()}) do Reparent(child, groupRegion or clip:GetParent()) end
    end
    -- In combat the displays may still be inside it; they leave after combat.
    if not InCombatLockdown() then
      clip:SetClipsChildren(false)
      clip:Hide()
    end
    return
  end
  if not InCombatLockdown() then
    local inRow = {}
    for _, flow in ipairs(flows or {}) do
      inRow[flow.region] = true
      if flow.region:GetParent() ~= clip and not KeepsParent(FlowData(flow)) then Reparent(flow.region, clip) end
    end
    -- A centred row's display that could not be copied keeps its own place.
    if g.shadow then
      for _, child in ipairs({clip:GetChildren()}) do
        local normal = child.flowNormal
        if not inRow[child] and normal and normal.active and not (normal.stand and normal.stand.active) and child:IsShown() then
          Reparent(child, groupRegion)
        end
      end
    end
    MatchClipStrata(clip, groupRegion)
  end
  -- ForeverAuras: the row's reference display (RechainFlow, rowFlow), where
  -- the old row layout starts; the first chained display when none is noted.
  local first = flows and (flows.origin or flows[1])
  -- The options preview places its own cut.
  if not first or WeakAuras.IsOptionsOpen() then return end
  local step, spacing, width, height = RowStep(group, g, flows)
  local owned = Display.FlowGroupOwned(group)
  local length = WindowLength(Limit(group), g.shadow and {} or LeadSteps(flows), step, spacing)
  local cap = caps[group.id]
  local origin, point = first.home or first.region, g.start
  if g.shadow and cap then origin, point = cap.left, "TOPLEFT" end
  if owned and not (g.shadow and cap) then
    -- ForeverAuras: a group-owned row starts at the group's anchor point
    -- (RowOrigin), where the cut starts too. The cut is an ordinary frame, so
    -- it cannot be anchored to a member's start frame, which follows
    -- secret-length containers (the same client rule as for bars); the group
    -- region is a plain frame.
    local originFrame, originPoint = RowOrigin(group)
    if originFrame then
      local snapX, snapY = SnapOffset(originFrame, originPoint)
      -- Across the row as the chain is (RechainFlow, CrossOffset).
      local crossX, crossY = CrossOffset(group, g, g.sign[1] ~= 0 and height or width)
      SetWindow(clip, g, g.start, originFrame, length, width, height, spacing, originPoint, snapX + crossX, snapY + crossY)
      return
    end
  end
  SetWindow(clip, g, point, origin, length, width, height, spacing)
end

local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function()
  local groups = afterCombat
  afterCombat = {}
  for group in pairs(groups) do Display.RechainFlow(group) end
end)

local flushing = false
-- When each group was last chained (GetTime is constant within a frame).
local lastFlush = setmetatable({}, {__mode = "k"})
local flushesAt, flushes = nil, 0
local activatingShadows = false   -- ForeverAuras (dev.83): the shadows' binding asked from the row's pass, never from itself
local function FlushQueued()
  -- ForeverAuras: during a load scan (and the editor's batched pick of a
  -- large group, OptionsFrame) the queue is kept for Display.EndFlowLoad:
  -- the per-frame timer below chained every queued group once a frame
  -- regardless of the hold, which made the hold worthless (issue #136).
  if flushing or loadScan > 0 then return end
  -- ForeverAuras (dev.75 watchdog): more than 200 flushes in one frame is a
  -- loop between a layout pass and what it queues; reported with its stack
  -- rather than a frozen client
  local now = GetTime()
  if flushesAt ~= now then flushesAt, flushes = now, 0 end
  flushes = flushes + 1
  if flushes > 200 then flushes = 0; error("ForeverAuras watchdog: the row layout was asked for " .. 200 .. " times in one frame") end
  flushing = true
  local groups = queued
  queued = {}
  local now = GetTime()
  for group in pairs(groups) do
    lastFlush[group] = now
    Private.StartProfileSystem("aura (modern) - group layout: rechains")
    -- ForeverAuras: one group's failing layout is reported and the others
    -- still chain; an error here used to leave the flag below set, so no
    -- later rechain (visibility, timers, load batches) did anything.
    xpcall(Display.RechainFlow, geterrorhandler(), group)
    Private.StopProfileSystem("aura (modern) - group layout: rechains")
    if WeakAuras.IsOptionsOpen() then xpcall(Display.ArrangeFlowPreview, geterrorhandler(), group) end
  end
  flushing = false
  -- Work queued by the rechain itself (a member it showed or hidden) waits
  -- for the timer QueueRechain set, so a rechain can never loop on itself.
end

local QueueRechain
Display.QueueRechain = function(region) return QueueRechain(region) end   -- ForeverAuras (dev.74): a shadow chain completed late asks for the row's pass
function QueueRechain(region)
  local native = region.blizzardAuraDisplay
  local normal = region.flowNormal
  local data = native and native.active and native.data or normal and normal.active and normal.data
  local group = data and Display.FlowGroup(data)
  if not group then return end
  if not next(queued) then C_Timer.After(0, FlushQueued) end
  queued[group] = true
  -- The row is chained again at once: a display shown or hidden now would
  -- otherwise draw for one frame where the row last put it, a visible jump
  -- sideways as it came in. During a load scan that happens once, at its end
  -- (Display.EndFlowLoad); the timer above catches a queue made while a
  -- rechain was already running.
  -- In the editor only, once per frame per group: selecting a pack shows
  -- every display in one frame, and a full rechain for each of them grew with
  -- the square of the pack's size and stalled the click; the first one chains
  -- the row at once and the rest wait for the timer, which chains it once more
  -- next frame. Live, every change still chains at once: a deferred chain
  -- could fall into combat, where a row with clickable copies cannot be moved,
  -- and leave a display where the row last put it until combat ends.
  if loadScan == 0 and not (WeakAuras.IsOptionsOpen() and lastFlush[group] == GetTime()) then FlushQueued() end
end

function Display.BeginFlowLoad()
  loadScan = loadScan + 1
end

function Display.EndFlowLoad()
  loadScan = math.max(0, loadScan - 1)
  if loadScan == 0 and next(queued) then FlushQueued() end
  -- Grid rebuilds that waited for this hold (BlizzardAuraDisplay.lua, DrainPending).
  if loadScan == 0 and Display.ResumeGridDrain then Display.ResumeGridDrain() end
end

-- Whether a flow hold is open (a rechain now would only join its batch).
function Display.FlowLoadHeld()
  return loadScan > 0
end

function Display.WatchFlowVisibility(region)
  if region.flowVisibilityHooked then return end
  region.flowVisibilityHooked = true
  TimedHookScript(region, "OnShow", QueueRechain)
  TimedHookScript(region, "OnHide", QueueRechain)
  TimedHookScript(region, "OnSizeChanged", function(self)
    -- Only a normal display's size moves the row (texts resize as they change).
    local normal = self.flowNormal
    if not (normal and normal.active and normal.flow and normal.flow.growth) then return end
    local width, height = NormalSize(self, normal.data)
    if normal.homeWidth and math.abs(width - normal.homeWidth) < 0.5 and math.abs(height - normal.homeHeight) < 0.5 then return end
    QueueRechain(self)
  end)
end

function Display.FlowNormal(data)
  if not data or data.regionType == "group" or data.regionType == "dynamicgroup" or Display.Enabled(data) then return end
  for _, entry in ipairs(data.triggers or {}) do
    if type(entry) == "table" and type(entry.trigger) == "table" and entry.trigger.type == "secretAura" then return end
  end
  local anchor = data.anchorFrameType
  if anchor == "UNITFRAME" or anchor == "NAMEPLATE" or anchor == "CUSTOM" or anchor == "MOUSE" then return end
  local group = Display.FlowGroup(data)
  if group and group.blizzardFlowFrames == nil and not Display.FlowGrid(group) then return group end
end

local function SizeFlowNormal(region, normal, g, group)
  local flow = normal.flow
  local width, height = NormalSize(region, normal.data)
  local along = g.sign[1] ~= 0
  local spacing = Display.FlowSpacing(group, region, along and width or height)
  local size = (along and width or height) + spacing
  flow.growth, flow.endFrame, flow.endPoint = g, flow.start, g.start
  flow.x, flow.y = g.sign[1] * size, g.sign[2] * size
  -- The home and stand frames are plain frames; only a stand carrying secure
  -- content is off limits in combat. A member that first loads in combat (an
  -- "In Combat" load condition) must be sized now, or its centred shadow is
  -- measured from a 1x1 frame and the row centres wrongly until the next fight.
  if (normal.homeWidth ~= width or normal.homeHeight ~= height) and not Display.StandLocked(normal) then
    normal.home:SetSize(width, height)
    if normal.stand then flow.start:SetSize(width, height); flow.startSize = {width, height} end
    normal.homeWidth, normal.homeHeight = width, height
  end
  if g.shadow then
    if not flow.shadowStart then
      flow.shadowStart = CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate")
      flow.shadowStart:EnableMouse(false)
      flow.shadowStart:SetSize(1, 1)
    end
    SetShown(flow.shadowStart, true)
    flow.shadowKind, flow.shadowList, flow.half = "fixed", nil, Display.FlowHalf(region, size)
  else
    SetShown(flow.shadowStart, false)
    flow.shadowKind = nil
  end
end

local function NormalWarning(normal, message)
  local uid = normal.data and normal.data.uid
  if uid then Private.AuraWarnings.UpdateWarning(uid, "flow_normal", message and "warning" or nil, message) end
end

-- ForeverAuras: originPoint names the point of the origin frame the region's
-- start corner goes on (a group-owned row chains an ordinary display to the
-- previous member's end, which can be any corner); a legacy row uses g.start.
function PlaceNormalRegion(region, normal, origin, x, y, originPoint)
  local g = normal.flow.growth
  if not g then return end
  if Busy(region) then return end
  if WeakAuras.IsOptionsOpen() then
    if normal.stand and not Display.StandLocked(normal) then
      SetShown(normal.flow.start, false)
      if region.relativeTo == UIParent then
        region:SetAnchor(g.start, normal.home, g.start)
        region:SetOffset(0, 0)
      end
    end
    return
  end
  if normal.stand and normal.stand.active then
    if not Display.StandLocked(normal) then SetShown(normal.flow.start, true) end
    region:SetOffset(0, 0)
    region:SetAnchor("BOTTOMRIGHT", UIParent, "TOPLEFT")
    return
  end
  region:SetOffset(x or 0, y or 0)
  region:SetAnchor(g.start, origin or normal.home, originPoint or g.start)
end

function Display.AnchorFlowNormal(data, region, anchorParent, anchorPoint)
  local normal = region.flowNormal
  local group = Display.FlowNormal(data)
  if not group then
    if normal and normal.active then
      normal.active = false
      NormalWarning(normal, nil)
      SetShown(normal.flow.shadowStart, false)
      if normal.stand then Display.ReleaseStand(normal); normal.stand = nil; SetShown(normal.flow.start, false) end
      local old = Display.FlowGroup(normal.data) or normal.group
      normal.group = nil
      if old then Display.RechainFlow(old) end
    end
    return false
  end
  if not normal then
    normal = {}
    normal.home = CreateFrame("Frame", nil, UIParent)
    normal.home:EnableMouse(false)
    normal.flow = {start = OnPixels(CreateFrame("Frame", nil, region, "DisableUntrustedLayoutScriptsTemplate")), startSize = {1, 1}}
    normal.flow.start:EnableMouse(false)
    normal.flow.start:SetSize(1, 1)
    region.flowNormal = normal
  end
  normal.data, normal.group, normal.active = data, group, true
  if not InCombatLockdown() then
    local parent = region:GetParent() or UIParent
    if normal.home:GetParent() ~= parent then normal.home:SetParent(parent) end
    normal.home:ClearAllPoints()
  end
  Place(normal.home, data.selfPoint or "CENTER", anchorParent, anchorPoint or "CENTER", data.xOffset or 0, data.yOffset or 0)
  local g = GROWTH[group.blizzardFlowGrowth] or GROWTH.RIGHT
  -- ForeverAuras: group-owned row: the content frame carries the display's
  -- own offset, and a stand's copies draw in it (SecretAuraStand.lua), so it
  -- exists, or is gone, before the stand is linked below.
  if Display.FlowGroupOwned(group) then
    Display.FlowContent(normal.flow, region)
    PlaceContent(normal.flow, OwnOffset(data))
    normal.flow.contentOn = normal.flow.start
  elseif normal.flow.content then
    SetShown(normal.flow.content, false)
    normal.flow.content = nil
  end
  if Display.UsesStand and Display.UsesStand(data) then
    if not xpcall(function() Display.EnsureStand(region, normal) end, geterrorhandler()) then
      Display.ReleaseStand(normal)
      normal.stand = nil
    end
    normal.homeWidth = nil
  elseif normal.stand then
    Display.ReleaseStand(normal)
    normal.stand = nil
  end
  SizeFlowNormal(region, normal, g, group)
  Display.WatchFlowVisibility(region)
  if WeakAuras.IsOptionsOpen() then
    SetShown(normal.flow.start, false)
    region:SetAnchor(g.start, normal.home, g.start)
    region:SetOffset(0, 0)
    Display.ArrangeFlowPreview(group)
  else
    if not normal.flow.start:GetPoint() then normal.flow.start:SetPoint(g.start, normal.home, g.start) end
    if not region.relativeTo then PlaceNormalRegion(region, normal) end
  end
  QueueRechain(region)
  return true
end

local staleRebuilds = {}
local function StaleGrowth(group, childID)
  local entry = Private.regions[childID]
  local native = entry and entry.region and entry.region.blizzardAuraDisplay
  return native and native.active and native.flow and native.flow.growth
    and native.flow.growth ~= GROWTH[GrowthKey(group)] or false
end

-- Re-anchors every child of a Modern Aura Group in the group's child order.
local function LocalOutputFailure(region, data, kind, why)
  local native = region.blizzardAuraDisplay
  if not native then return false end
  local flow = native.flow
  local ask = native.chainCommitPending
  local instance = ask and ask.instance or native.instances and native.instances[1]
  if kind == "main" and Display.FlowChain(data) then
    native.chainCommitPending, native.chainCommitResult = nil, false
    Display.NoteChainFailure(region, instance, "end", why, ask and ask.pending)
    Display.SetFlowEnd(region, data, nil)
    if Display.SettleProbeCommit then Display.SettleProbeCommit(region) end
  else
    -- Keep the old measurement graph resolvable until its paced repair.
    -- An ordinary measurement failure is not a failed gated display.
    local shadow = kind == "shadowChain"
    if shadow and flow then flow.shadowChainProblem, flow.localShadowOutputProblem = why, true end
    if data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then
      Private.AuraWarnings.UpdateWarning(data.uid, shadow and "blizzard_aura_shadow" or "blizzard_aura_row_measure", "warning", L["Blizzard could not create the Modern Aura Group spacing: %s"]:format(tostring(why)))
    end
    if instance and instance.finishing and Display.NoteSlotFailure then Display.NoteSlotFailure(instance, "local row measurement", why) end
    if Display.RequestReapply then Display.RequestReapply(region, "local row measurement: " .. tostring(why)) end
    if native.probeBuild and Display.SettleProbeCommit then
      native.chainCommitPending, native.chainCommitResult = nil, false
      Display.SettleProbeCommit(region)
    end
  end
  return false
end
local committingChains = false -- ForeverAuras (cell chain): a commit's own re-chain does not commit again
function Display.RechainFlow(group)
  if not group then return end
  if loadScan > 0 then queued[group] = true; return end
  -- Profiling breakdown of a rechain (no cost unless profiling runs).
  Private.StartProfileSystem("aura (modern) - group layout: merge")
  Display.RefreshFlowMerge(group)
  Private.StopProfileSystem("aura (modern) - group layout: merge")
  Private.StartProfileSystem("aura (modern) - group layout: grid")
  Display.RebuildGrid(group)
  Private.StopProfileSystem("aura (modern) - group layout: grid")
  if Display.FlowGrid(group) then Display.UpdateFlowClip(group) return end
  if group.blizzardFlowFrames == "UNITFRAME" or group.blizzardFlowFrames == "NAMEPLATE" then
    Display.UpdateFlowClip(group)
    if not InCombatLockdown() then
      for _, childID in ipairs(group.controlledChildren or {}) do
        if StaleGrowth(group, childID) and not staleRebuilds[childID] then
          staleRebuilds[childID] = true
          C_Timer.After(0, function()
            staleRebuilds[childID] = nil
            local child = WeakAuras.GetData(childID)
            if child and not InCombatLockdown() and StaleGrowth(group, childID) then WeakAuras.Add(child) end
          end)
        end
      end
    end
    Display.RelinkFlowUnits(group)
    return
  end
  local combat = InCombatLockdown()
  if combat then afterCombat[group] = true end
  local flows, modernFlows = {}, {}
  local g = GROWTH[group.blizzardFlowGrowth] or GROWTH.RIGHT
  -- ForeverAuras: a group-owned row (FlowGroupOwned) starts at the group's
  -- own anchor and chains every member in the group's order; ordinary
  -- displays join the chain like the rest (also with Centered growth), and
  -- the chain reads no member's own offset (their content frames carry it).
  local owned = Display.FlowGroupOwned(group)
  local originFrame, originPoint
  if owned then originFrame, originPoint = RowOrigin(group) end
  if owned and not originFrame then owned = false end
  -- Each child's own region, then its clones (multi-state triggers) in a stable order.
  -- ForeverAuras: in the row's order (Display.FlowOrder: gated members last).
  local members = {}
  -- ForeverAuras: each member's place in the group's own order, to find the
  -- row's reference display (rowFlow below) after the gated members moved.
  local groupPosition, memberPosition = {}, {}
  for index, childID in ipairs(group.controlledChildren or {}) do groupPosition[childID] = index end
  for _, childID in ipairs(Display.FlowOrder(group)) do
    local entry = Private.regions[childID]
    if entry and entry.region then members[#members + 1] = entry.region; memberPosition[entry.region] = groupPosition[childID] end
    local cloneIDs = {}
    for cloneId in pairs(Private.clones and Private.clones[childID] or {}) do cloneIDs[#cloneIDs + 1] = cloneId end
    table.sort(cloneIDs, function(a, b) return tostring(a) < tostring(b) end)
    for _, cloneId in ipairs(cloneIDs) do
      local clone = Private.clones[childID][cloneId]
      members[#members + 1] = clone
      memberPosition[clone] = groupPosition[childID]
    end
  end
  for _, region in ipairs(members) do
    local native = region.blizzardAuraDisplay
    local normal = region and region.flowNormal
    local flow = native and native.active and native.flow
    if not flow and normal and normal.active and Display.FlowNormal(normal.data) == group then
      SizeFlowNormal(region, normal, g, group)
      flow = normal.flow
      flow.home = normal.home
    end
    -- A display not yet rebuilt for the group's current growth joins the
    -- chain when its own rebuild runs.
    if flow and flow.endFrame and flow.growth == g and region:IsShown() then
      flow.region = region
      flow.stand = flow.home and normal.stand and normal.stand.active or nil
      if flow.stand then flow.normal = normal end
      -- Both row modes: ordinary displays that cannot be copied lead the row
      -- (see FlowGroupOwned), then every other member in the group's order.
      -- A Centered row starts a secret distance back (the shadows), where no
      -- ordinary display can be placed: such a display keeps its own position.
      if not flow.home or flow.stand then
        modernFlows[#modernFlows + 1] = flow
        if flow.stand then NormalWarning(normal, nil); Display.SyncStandSecure(region, normal); PlaceNormalRegion(region, normal) end
      elseif g.shadow then
        NormalWarning(normal, L["With Centered growth this display keeps its own position: only icons and texts join a centred row (with the old row layout off, also textures, bars and progress textures)."])
        PlaceNormalRegion(region, normal)
      else
        NormalWarning(normal, nil)
        flow.normal = normal
        flows[#flows + 1] = flow
      end
    end
  end
  -- ForeverAuras: the old row layout starts the row at its first display's
  -- own frame, and measures every member's own offset from that display's.
  -- That display stays the group's first member even when the row's order
  -- moved it behind the others (Display.FlowOrder: a gated first member), so
  -- the row keeps its place on the screen; the leading ordinary displays, if
  -- any, come before it as before. Carried on the chain for the clip.
  local rowFlow = flows[1]
  if not rowFlow then
    for _, flow in ipairs(modernFlows) do
      if not rowFlow or (memberPosition[flow.region] or math.huge) < (memberPosition[rowFlow.region] or math.huge) then rowFlow = flow end
    end
  end
  for _, flow in ipairs(modernFlows) do flows[#flows + 1] = flow end
  flows.origin = rowFlow
  -- Centred: the shadows run backwards from the first display's centre point,
  -- and the visible row starts where they end, half a spacing on.
  local previous, shadowEnd
  -- The row's centre (Centered growth) or start corner: the group's anchor
  -- for a group-owned row, else the reference display's own frame.
  local rowFrame = owned and originFrame or rowFlow and (rowFlow.home or rowFlow.region)
  local rowPoint = owned and originPoint or (g.shadow and g.centerPoint or g.start)
  local snapX, snapY = SnapOffset(rowFrame, rowPoint)
  -- ForeverAuras: a group-owned row lines up across the row with the group's
  -- anchor point like a Dynamic Group's children: the row's cross size (its
  -- first display's, RowStep) is centred on a CENTER/LEFT/RIGHT point, hangs
  -- from a TOP point and stands on a BOTTOM one (CrossOffset; the same
  -- rule as rows on unit frames). Before, the row's top-left corner sat on
  -- the point whatever it was, so a centred row hung below its anchor.
  if owned and flows[1] then
    local _, _, rowWidth, rowHeight = RowStep(group, g, flows)
    local crossX, crossY = CrossOffset(group, g, g.sign[1] ~= 0 and rowHeight or rowWidth)
    snapX, snapY = snapX + crossX, snapY + crossY
  end
  if g.shadow and flows[1] then
    local firstRegion = flows[1].region
    local spacing = Display.FlowSpacing(group, firstRegion, 0) - 0
    local halfSpacing = Display.FlowHalf(firstRegion, spacing)
    for _, flow in ipairs(flows) do
      if flow.shadowStart and flow.shadowKind then
        if not combat then FreshFrame(flow, "shadowStart", "shadowSize", flow.region) end
        local start = flow.shadowStart
        if combat then
          local placed
          if shadowEnd then placed = Place(start, g.shadow.start, shadowEnd[1], shadowEnd[2], shadowEnd[3], shadowEnd[4])
          else placed = Place(start, g.shadow.start, rowFrame, rowPoint, snapX, snapY) end
          -- ForeverAuras (dev.82, Astra's dev.81 review): a refused shadow placement is said (with
          -- "/fa cells debug on") instead of passing in silence; the row comes right when
          -- restrictions end (afterCombat), as every refused placement does
          if not placed and Display.BuildReport then
            Display.BuildReport(("%s's shadow could not be placed on the shadows before it: %s"):format(tostring(FlowData(flow) and FlowData(flow).id), tostring(start.faPlaceError)))
          end
          local ok, chained = pcall(ChainShadows, flow)
          if ok then shadowEnd = chained end
        else
          start:ClearAllPoints()
          if not (shadowEnd and Place(start, g.shadow.start, shadowEnd[1], shadowEnd[2], shadowEnd[3], shadowEnd[4])) then
            start:ClearAllPoints()
            start:SetPoint(g.shadow.start, rowFrame, rowPoint, snapX, snapY)
          end
          shadowEnd = ChainShadows(flow)
        end
      end
    end
    if shadowEnd then
      -- Whole units only (see the shadow sizes): the row starts a whole number
      -- of units after the shadows, so every icon lands on the pixel grid.
      previous = {endFrame = shadowEnd[1], endPoint = shadowEnd[2],
        x = shadowEnd[3] + g.sign[1] * halfSpacing, y = shadowEnd[4] + g.sign[2] * halfSpacing}
      previous = CapRowStart(group, g, flows, previous, combat, snapX, snapY, owned and originFrame or nil, owned and originPoint or nil)
    end
  end
  -- ForeverAuras (independent carriers, dev.32): the padding M of a member's
  -- translation comes from the group's membership (CarrierPadding), and a
  -- member imported with its group is built while the group's child list is
  -- still empty: its end and boxes were translated with the empty-membership
  -- padding (64), which does not cover a list growing left or up from the
  -- pin, and the client collapses a helper whose anchors cross (seen in
  -- game: the Left row's end 62 px from the pin whatever the list held,
  -- boxes 3+ astray; the row healed on a reload, which builds the member
  -- with the list already saved). The group's own modify re-chains the row
  -- once the list is saved: a member whose recorded padding differs from the
  -- current one has its end (and, through the placement records, its boxes)
  -- translated again here, before the chain hangs the next member from it.
  -- Out of combat only, like the rest of this pass; a refused translation
  -- falls back and reports as in SetFlowEnd.
  if owned and not combat and Display.FlowIndependentGroup(group) then
    local padding = Display.CarrierPadding(group)
    for _, flow in ipairs(flows) do
      if flow.carrierEnd and flow.endFrame == flow.carrierEnd.out and flow.carrierM ~= padding then
        local data = FlowData(flow)
        if data then Display.SetFlowEnd(flow.region, data, nil) end
      end
    end
  end
  local origin, lead = nil, 0
  -- ForeverAuras (cell chain, dev.44 review): whether the member hanging from
  -- each flow's end could be placed there in this chain (nil: no follower
  -- hangs from it); a completion outside an apply reads it (CompleteChain).
  for _, flow in ipairs(flows) do flow.followerPlaced, flow.startPlaced = nil, nil; if not combat then flow.startPrewired = nil end end   -- dev.70: out of restrictions every start is placed by this pass
  for _, flow in ipairs(flows) do
    local region = flow.region
    if not combat then
      local before = flow.start
      FreshFrame(flow, "start", "startSize", region)
      -- ForeverAuras: group-owned row: the content frame follows the start
      -- frame (replaced with it, or replaced itself when locked) and carries
      -- the member's own offset; a replaced one is noted so what hung from
      -- the old frame is made again below, like a replaced start frame.
      if owned and flow.content then
        local contentBefore = flow.content
        FreshFrame(flow, "content", "startSize", region)
        if flow.content ~= contentBefore or flow.start ~= flow.contentOn then
          PlaceContent(flow, OwnOffset(FlowData(flow)))
          flow.contentOn = flow.start
          if flow.content ~= contentBefore then flow.contentReplaced = true end
        end
      end
      -- ForeverAuras: a stand's copies are children of the chain frame; with
      -- the frame replaced they stayed on the abandoned one while the row
      -- placed the new, empty frame. The stand is rebuilt on the new frame.
      if (flow.start ~= before or flow.contentReplaced) and flow.stand and flow.normal and Display.RefreshStand then
        flow.contentReplaced = nil
        Display.RefreshStand(region)
      elseif (flow.start ~= before or flow.contentReplaced) and not flow.home then
        flow.contentReplaced = nil
        -- ForeverAuras: a Modern display's containers, Missing look and
        -- samples hang from its start frame, and its anchor record names the
        -- region, not the frame, so a replaced frame was never noticed: the
        -- content stayed on the abandoned frame while the row placed the new,
        -- empty one. The display is built again on the new frame, next frame
        -- (not inside this chain), out of combat (the replacement only runs
        -- then).
        local native = region.blizzardAuraDisplay
        if native and native.active and native.data and Display.Apply and not native.rebuildQueued then
          native.rebuildQueued = true
          C_Timer.After(0, function()
            native.rebuildQueued = nil
            -- Combat begun since: Apply itself defers a display that already
            -- has instances until restrictions end (its pending set), so the
            -- rebuild is kept rather than dropped; the frame stays replaced
            -- and no later chain would ask again.
            if native.active and region.blizzardAuraDisplay == native then
              Display.Apply(region, native.data)
            end
          end)
        end
      end
    end
    -- Refresh local outputs after any start/content replacement and before
    -- placing this member or its follower. The refresh keeps unchanged
    -- placements intact, and also repairs import-time translation padding.
    local native = region.blizzardAuraDisplay
    if native and native.data and Display.RefreshLocalChainOutputs then
      local ok, refreshed, why, kind = pcall(Display.RefreshLocalChainOutputs, region, native.data)
      if not ok then why, refreshed = refreshed, false end
      if refreshed == false then
        return LocalOutputFailure(region, native.data, kind or (Display.FlowChain(native.data) and "main" or "measureChain"), why)
      else
        ClearMeasureOutputWarning(native.data)
        if flow.localShadowOutputProblem then
          flow.localShadowOutputProblem, flow.shadowChainProblem = nil, nil
          if native.data.uid and Private.AuraWarnings and Private.AuraWarnings.UpdateWarning then Private.AuraWarnings.UpdateWarning(native.data.uid, "blizzard_aura_shadow", nil, nil) end
        end
      end
    end
    if owned then
      -- ForeverAuras: group-owned row. A leading ordinary display's start
      -- frame and region go on the group's anchor, a running lead along;
      -- every other member's start frame goes on the previous member's end.
      -- No member offset moves the chain: an ordinary display's offset is on
      -- its region only, and a Modern display's or stand's on its content
      -- frame (PlaceContent), whose offset is taken back off when the next
      -- member hangs from an end that lives in that content (the last aura
      -- container, SetFlowEnd; not the Missing presence or the Remaining
      -- Time text, which are measured from the start frame).
      local locked = combat and flow.stand and Display.StandLocked(flow.normal)
      if flow.home and not flow.stand then
        local x, y = g.sign[1] * lead, g.sign[2] * lead
        if not combat then flow.start:ClearAllPoints() end
        Place(flow.start, g.start, originFrame, originPoint, x + snapX, y + snapY)
        local ox, oy = OwnOffset(flow.normal.data)
        PlaceNormalRegion(region, flow.normal, originFrame, x + snapX + ox, y + snapY + oy, originPoint)
        lead = lead + math.abs(flow.x) + math.abs(flow.y)
        previous = flow
      elseif not locked then
        if not combat then flow.start:ClearAllPoints() end
        local px, py = 0, 0
        if previous and previous.region and previous.content and previous.endInContent then
          px, py = OwnOffset(FlowData(previous))
        end
        local chained = previous and Place(flow.start, g.start, previous.endFrame, previous.endPoint, previous.x - px, previous.y - py)
        if previous then previous.followerPlaced = chained and true or false end
        if not chained then
          -- (dev.80) said in chat with "/fa cells debug on"
          if previous and Display.BuildReport then Display.BuildReport(("%s could not be placed on %s's end: %s"):format(tostring(FlowData(flow) and FlowData(flow).id), tostring(previous.region and FlowData(previous) and FlowData(previous).id), tostring(flow.start.faPlaceError))) end
          if not combat then flow.start:ClearAllPoints() end
          -- The first member sits on the row's origin; a refused member too,
          -- which is then the wrong place (startPlaced = false).
          local onOrigin = Place(flow.start, g.start, originFrame, originPoint, snapX, snapY)
          flow.startPlaced = (previous == nil and onOrigin) and true or false
        else
          flow.startPlaced = true
        end
        previous = flow
      else
        -- A locked stand keeps its place: the member before it cannot know
        -- its follower sits on its end, nor the stand its own.
        if previous then previous.followerPlaced = false end
        flow.startPlaced = false
        previous = flow
      end
    elseif flow.home and not flow.stand then
      origin = origin or flow.home
      local x, y = g.sign[1] * lead, g.sign[2] * lead
      if not combat then flow.start:ClearAllPoints() end
      Place(flow.start, g.start, origin, g.start, x + snapX, y + snapY)
      PlaceNormalRegion(region, flow.normal, origin, x + snapX, y + snapY)
      lead = lead + math.abs(flow.x) + math.abs(flow.y)
      previous = flow
    elseif combat and flow.stand and Display.StandLocked(flow.normal) then
      previous = flow
    elseif combat then
      -- The display's own offset (OwnOffset) moves only this display; the
      -- previous one's is taken back off its end anchor. The first display's
      -- offset is already in its region's place, where the row starts.
      local ox, oy = RowOffset(flow, rowFlow)
      local px, py = RowOffset(previous, rowFlow)
      if previous then
        Place(flow.start, flow.growth.start, previous.endFrame, previous.endPoint, previous.x + ox - px, previous.y + oy - py)
      else
        -- ForeverAuras: at the reference display's frame (rowFlow), not
        -- necessarily this display's own.
        Place(flow.start, flow.growth.start, rowFrame, flow.growth.start, snapX + ox, snapY + oy)
      end
      previous = flow
    else
      flow.start:ClearAllPoints()
      -- As in combat above: this display's own offset on, the previous one's off.
      local ox, oy = RowOffset(flow, rowFlow)
      local px, py = RowOffset(previous, rowFlow)
      local chained = previous and Place(flow.start, flow.growth.start,
        previous.endFrame, previous.endPoint, previous.x + ox - px, previous.y + oy - py)
      if previous then previous.followerPlaced = chained and true or false end
      if not chained then
        -- First display: start at the reference display's frame (rowFlow,
        -- not necessarily this display's own); Blizzard refused the anchor:
        -- start at the display's own region.
        flow.start:ClearAllPoints()
        flow.start:SetPoint(flow.growth.start, previous and (flow.home or region) or rowFrame, flow.growth.start, snapX + ox, snapY + oy)
        flow.startPlaced = previous == nil
      else
        flow.startPlaced = true
      end
      previous = flow
    end
  end
  Display.UpdateFlowClip(group, flows, g)
  -- ForeverAuras (cell chain, dev.46 review): the members that asked this
  -- pass to take their prepared end are committed now, with this pass's
  -- placements (CommitChain); a refused one published its fallback, so the
  -- pass runs once more for the followers (not again from that pass).
  if Display.CommitChain and not committingChains then
    local again = false
    committingChains = true
    for _, flow in ipairs(flows) do
      local native = flow.region.blizzardAuraDisplay
      local ask = native and native.chainCommitPending
      if ask then
        native.chainCommitPending = nil
        if Display.CommitChain(flow.region, ask.instance, ask.pending) == false then again = true end
      end
    end
    committingChains = false
    if again then Display.RechainFlow(group) end
  end
  -- ForeverAuras (dev.82 -> dev.83, Dan's dev.82 combat reload): the shadows
  -- of a Centered row are bound once THIS pass has put everything in place.
  -- FinishApply asks too, but its own pass is deferred to the load batch
  -- during a reload (loadScan above), so at that moment nothing was placed
  -- yet ("T's shadow is not on the shadows before it") and no later build
  -- asked again; the batch's pass is where the placements happen, so it asks
  -- here. The activated members' new containers take the unit (RefreshUnits).
  if combat and Display.ActivateShadows and not activatingShadows then
    activatingShadows = true
    local okA, activated = pcall(Display.ActivateShadows, group)
    activatingShadows = false
    if okA and type(activated) == "table" and Display.RefreshUnits then
      for _, r in ipairs(activated) do Display.RefreshUnits(r) end
    end
  end
  return true -- the chain ran (nil: deferred to the batch, CompleteChain)
end

Display.RechainFlow = Private.Profiled("aura (modern) - group layout", Display.RechainFlow)
