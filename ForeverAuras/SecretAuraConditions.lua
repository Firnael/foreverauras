-- Copyright (C) 2026 ForeverAuras. Part of ForeverAuras, licensed under the GNU GPL v2 (see LICENSE).
-- Public trigger conditions can style native widgets without observing secret aura state.
if not WeakAuras.IsLibsOK() then return end
local _, Private = ...
-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript = Private.TimedAPI("SecretAuraConditions")
local Display = Private.BlizzardAuraDisplay
local conditionActions = {chat = "chat", sound = "sound", customcode = "customcode", glowexternal = "glowexternal"}
local rootProperties = {
  icon = {color = 'color', desaturate = 'bool', zoom = 'number', inverse = 'bool', cooldownSwipe = 'bool', cooldownEdge = 'bool', cooldownTextDisabled = 'bool'},
  aurabar = {barColor = 'color', backgroundColor = 'color', icon_color = 'color', desaturate = 'bool'},
  text = {color = 'color', fontSize = 'number', displayText = 'string'},
  progresstexture = {foregroundColor = 'color', backgroundColor = 'color', desaturateForeground = 'bool'},
}
local elementProperties = {
  subtext = {text_color = 'color', text_visible = 'bool', text_text = 'string', text_fontSize = 'number', text_anchorXOffset = 'number', text_anchorYOffset = 'number', text_alpha = 'number'},
  subglow = {glow = 'bool'},
}

-- These checks are declarations consumed by Blizzard, never Lua state predicates.
local durationVariables = {
  faAuraRemaining = {"RemainingDuration", "Remaining Time", 1},
  faAuraRemainingPercent = {"RemainingPercent", "Remaining Time (%)", 100},
  faAuraElapsed = {"ElapsedDuration", "Elapsed Time", 1},
  faAuraElapsedPercent = {"ElapsedPercent", "Elapsed Time (%)", 100},
  faAuraTotal = {"TotalDuration", "Total Duration", 1},
  -- Game-clock timestamps (GetTime), not countdowns. Offered only where a
  -- display already uses them (Display.FilterConditionTemplates).
  faAuraStart = {"StartTime", "Start Time (game clock)", 1},
  faAuraEnd = {"EndTime", "End Time (game clock)", 1},
}
-- True when a condition (or a nested check) on this trigger uses the variable.
local function UsesVariable(check, trigger, variable)
  if not check then return false end
  if check.trigger == trigger and check.variable == variable then return true end
  for _, child in ipairs(check.checks or {}) do
    if UsesVariable(child, trigger, variable) then return true end
  end
  return false
end
local nativeVariables = {faAuraPandemic = true, faAuraStealable = true, faAuraNotStealable = true,
  faAuraDispel = true, faAuraType = true, faAuraPresent = true, faAuraApplications = true,
  -- The Missing look of Show On: Aura(s) Missing or Always. Unlike the others
  -- it styles our own static icon, never a live aura (Display.MissingDesaturated).
  faAuraMissing = true}
for key in pairs(durationVariables) do nativeVariables[key] = true end
Display.missingRootProperties = {
  icon = {desaturate = true, color = true, zoom = true},
  aurabar = {barColor = true, backgroundColor = true, icon_color = true, desaturate = true},
  progresstexture = {foregroundColor = true, backgroundColor = true, desaturateForeground = true},
  text = {color = true},
}
local indicatorProperties = {faAuraHighlightColor = true, faAuraHighlightStyle = true, faAuraHighlightSize = true, faAuraHighlightTexture = true, faAuraHighlightPulse = true}
function Display.IsNativeDurationCondition(check) return check and durationVariables[check.variable] ~= nil end
function Display.NativeConditionKind(data, check)
  local entry = check and data.triggers and data.triggers[check.trigger]
  local trigger = type(entry) == "table" and entry.trigger
  -- Multi-selection trigger slots can be placeholders rather than trigger entries.
  return type(trigger) == "table" and trigger.type == "secretAura" and nativeVariables[check.variable] and check.variable or nil
end
function Display.ContainsNativeCondition(data, check)
  if Display.NativeConditionKind(data, check) then return true end
  for _, child in ipairs(check and check.checks or {}) do
    if Display.ContainsNativeCondition(data, child) then return true end
  end
  return false
end
function Display.SupportsDurationColorCondition()
  return C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor
    and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step ~= nil
    and Enum.DurationTextBindingProperty and Enum.DurationTextBindingProperty.RemainingDuration ~= nil
end
local function TextProperty(data, property, kind)
  if data.regionType == "text" and Display.TextKind(data.displayText) == kind then
    if property == "color" then return "color", "color" end
    if property == "displayText" then return "color", "text" end
  end
  local index, field
  if property then index, field = property:match("^sub%.(%d+)%.(.*)$") end
  local element = index and data.subRegions and data.subRegions[tonumber(index)]
  if element and element.type == "subtext" and not Display.IsDetachedElement(data, element) and Display.TextKind(element.text_text) == kind then
    local channel = ({text_color = "color", text_visible = "visible", text_text = "text"})[field]
    if channel then return "sub." .. index .. ".text_color", channel end
  end
end
-- "Remaining Time < X" may also turn on a Glow element: SecretAuraSingle.lua
-- draws it as a glow that opens when X seconds are left (Display.LateGlowSpec).
local function IsGlowProperty(data, property)
  local index = property and property:match("^sub%.(%d+)%.glow$")
  local element = index and data.subRegions and data.subRegions[tonumber(index)]
  return element ~= nil and element.type == "subglow" and not Display.IsDetachedElement(data, element)
end
Display.IsGlowProperty = IsGlowProperty

-- True when an "In Pandemic Window" condition turns on the Glow element at
-- index and the glow is off otherwise. data may be the prepared copy, whose
-- conditional glows are all on; the saved setting is read from its original.
local function PandemicGlow(data, index)
  local original = data.nativeConditionBaseData or data
  local element = original.subRegions and original.subRegions[index]
  if not element or element.type ~= "subglow" or element.glow then return false end
  for _, condition in ipairs(data.conditions or {}) do
    if not condition.linked and Display.NativeConditionKind(data, condition.check) == "faAuraPandemic" then
      for _, change in ipairs(condition.changes or {}) do
        if change.property == "sub." .. index .. ".glow" and change.value == true then return true end
      end
    end
  end
  return false
end

-- Called by StyleAppearance for each Glow element. Returns the frame a
-- pandemic glow is drawn in, or nil for an ordinary glow. The frame sits
-- outside the element's own frame, whose alpha follows the glow's saved
-- setting; Blizzard shows it during the pandemic window once
-- StyleNativeConditionIndicators registers it.
function Display.PandemicGlowHolder(native, data, index, frame)
  if not PandemicGlow(data, index) then return end
  native.pandemicGlowFrames = native.pandemicGlowFrames or {}
  local holder = native.pandemicGlowFrames[index]
  if not holder then
    -- Inside the Total Duration / Stack Count clip, so a rejected aura never glows.
    holder = CreateFrame("Frame", nil, native.gateClip or native.button)
    native.pandemicGlowFrames[index] = holder
  end
  holder:ClearAllPoints()
  holder:SetAllPoints(native.button)
  holder:SetFrameLevel(frame:GetFrameLevel() + 1)
  -- Hidden until the window (or the preview sample) shows it.
  holder:Hide()
  native.pandemicGlows = native.pandemicGlows or {}
  native.pandemicGlows[index] = holder
  return holder
end

-- Forgets last styling's pandemic glows before the elements are rebuilt.
function Display.ResetPandemicGlows(native)
  for _, holder in pairs(native.pandemicGlowFrames or {}) do holder:Hide() end
  native.pandemicGlows = {}
end

function Display.NativeConditionAllowsProperty(data, check, property)
  local kind = Display.NativeConditionKind(data, check)
  if kind == "faAuraRemaining" and IsGlowProperty(data, property) then return true end
  -- Blizzard shows and hides a frame for the pandemic window, so a Glow can
  -- live in one (Display.PandemicGlowHolder).
  if kind == "faAuraPandemic" and IsGlowProperty(data, property) then return true end
  if durationVariables[kind] then
    local target, channel = TextProperty(data, property, "duration")
    return target ~= nil and channel ~= "text"
  end
  if kind == "faAuraApplications" then return TextProperty(data, property, "stack") ~= nil end
  -- only while the aura is missing (its clip hides it otherwise).
  if kind == "faAuraMissing" then
    local allowed = Display.missingRootProperties[data.regionType]
    if not allowed then return false end
    if indicatorProperties[property] or allowed[property] then return true end
    local index, key = (property or ""):match("^sub%.(%d+)%.(.+)$")
    local element = index and data.subRegions and data.subRegions[tonumber(index)]
    if not element or Display.IsDetachedElement(data, element) then return false end
    return (element.type == "subglow" and key == "glow")
      or (element.type == "subtext" and (key == "text_visible" or key == "text_color"))
  end
  if kind then return indicatorProperties[property] == true end
  return not indicatorProperties[property]
end
-- True when an "Aura Missing" condition turns Desaturate on for the icon drawn
-- while the aura is missing.
function Display.MissingDesaturated(data)
  for _, condition in ipairs(data.conditions or {}) do
    if Display.NativeConditionKind(data, condition.check) == "faAuraMissing" then
      for _, change in ipairs(condition.changes or {}) do
        if change.property == "desaturate" and change.value == true then return true end
      end
    end
  end
  return false
end

function Display.MigrateNativeConditions(data)
  local settings = data.blizzardAuraDisplay or {}
  -- The trigger's former "Desaturate while missing" box becomes an "Aura
  -- Missing" condition on the first Aura (Modern) trigger.
  if settings.missingDesaturate then
    for index, entry in ipairs(data.triggers or {}) do
      if type(entry) == "table" and entry.trigger and entry.trigger.type == "secretAura" then
        data.conditions = data.conditions or {}
        table.insert(data.conditions, {check = {trigger = index, variable = "faAuraMissing"},
          changes = {{property = "desaturate", value = true}}})
        settings.missingDesaturate = nil
        break
      end
    end
  end
  if settings.remainingTimeColorEnabled then
    local property
    if data.regionType == "text" and Display.TextKind(data.displayText) == "duration" then property = "color" end
    for index, element in ipairs(data.subRegions or {}) do
      if not property and element.type == "subtext" and element.text_visible ~= false
          and not Display.IsDetachedElement(data, element) and Display.TextKind(element.text_text) == "duration" then
        property = "sub." .. index .. ".text_color"
      end
    end
    local triggerIndex
    for index, entry in ipairs(data.triggers or {}) do if entry.trigger.type == "secretAura" then triggerIndex = index; break end end
    if triggerIndex and property then
      data.conditions = data.conditions or {}
      table.insert(data.conditions, {check = {trigger = triggerIndex, variable = "faAuraRemaining", op = "<", value = settings.remainingTimeColorThreshold or 10},
        changes = {{property = property, value = settings.remainingTimeColor or {1, 0, 0, 1}}}})
      settings.remainingTimeColorEnabled = nil
    end
  end
end
local function Color(values, fallback)
  if type(values) ~= "table" then values = fallback end
  local result = {}
  for i = 1, 4 do
    local value = values[i]
    result[i] = type(value) == "number" and value == value and math.max(0, math.min(1, value)) or fallback[i]
  end
  return CreateColor(unpack(result))
end
local function NumericRules(data, property, stack)
  local rules = {}
  for _, condition in ipairs(data.conditions or {}) do
    local kind = Display.NativeConditionKind(data, condition.check)
    if not condition.linked and ((stack and kind == "faAuraApplications") or (not stack and durationVariables[kind])) then
      local check = condition.check
      local value = tonumber(check.value)
      if value and value == value and value >= 0 and value < math.huge then
        local supported = stack and ({['<']=true,['>=']=true,['>']=true,['<=']=true,['==']=true,['~=']=true}) or {['<']=true,['>=']=true}
        if supported[check.op] then
          for _, change in ipairs(condition.changes or {}) do
            local target, channel = TextProperty(data, change.property, stack and "stack" or "duration")
            if target == property and (stack or channel ~= "text") then
              rules[#rules + 1] = {threshold = value / (not stack and durationVariables[kind][3] or 1), op = check.op,
                value = change.value, channel = channel, kind = kind}
            end
          end
        end
      end
    end
  end
  return rules
end
local function Matches(value, rule)
  if rule.op == '<' then return value < rule.threshold
  elseif rule.op == '>=' then return value >= rule.threshold
  elseif rule.op == '>' then return value > rule.threshold
  elseif rule.op == '<=' then return value <= rule.threshold
  elseif rule.op == '==' then return value == rule.threshold
  elseif rule.op == '~=' then return value ~= rule.threshold end
end
local function BaseTextVisible(data, property)
  local index = property and property:match("^sub%.(%d+)%.text_color$")
  local original = data.nativeConditionBaseData or data
  local element = index and original.subRegions and original.subRegions[tonumber(index)]
  return not element or element.text_visible ~= false
end
-- window = {op, x}: the trigger's Remaining Time filter. It adds its own
-- step points and forces alpha 0 outside the range, so it only combines with
-- conditions on Remaining Time in seconds (Display.ValidateSingle enforces this).
function Display.DurationColorCondition(data, baseColor, property, window)
  if not Display.SupportsDurationColorCondition() then return end
  local rules = NumericRules(data, property)
  if #rules == 0 and not window then return end
  local kind = rules[1] and rules[1].kind or "faAuraRemaining"
  if window and kind ~= "faAuraRemaining" then return end
  local definition = durationVariables[kind]
  local bindingProperty = Enum.DurationTextBindingProperty[definition[1]]
  if bindingProperty == nil then return end
  local points, seen = {0}, {[0] = true}
  for _, rule in ipairs(rules) do
    if rule.kind ~= kind then return end -- One native binding samples one time property.
    if not seen[rule.threshold] then points[#points + 1] = rule.threshold; seen[rule.threshold] = true end
  end
  for _, value in ipairs(window and Display.RemainingWindowPoints(window[1], window[2]) or {}) do
    if not seen[value] then points[#points + 1] = value; seen[value] = true end
  end
  table.sort(points)
  local curve = C_CurveUtil.CreateColorCurve()
  curve:SetType(Enum.LuaCurveType.Step)
  for _, value in ipairs(points) do
    local color, visible = baseColor, BaseTextVisible(data, property)
    for _, rule in ipairs(rules) do
      if Matches(value, rule) then
        if rule.channel == "color" then color = rule.value
        elseif rule.channel == "visible" then visible = rule.value ~= false end
      end
    end
    if window and not Display.InRemainingWindow(value, window[1], window[2]) then visible = false end
    local result = Color(color, {1, 1, 1, 1})
    if not visible then local r,g,b = result:GetRGB(); result = CreateColor(r,g,b,0) end
    curve:AddPoint(value, result)
  end
  return {curve = curve, property = bindingProperty}
end
-- The stack text's breakpoints from the display's Stack Count conditions, or
-- nil without any.
local function StackBreakpoints(data, property)
  local rules = NumericRules(data, property, true)
  if #rules == 0 then return end
  local points, seen = {0, 2}, {[0]=true,[2]=true}
  for _, rule in ipairs(rules) do
    for _, value in ipairs({math.floor(rule.threshold), math.ceil(rule.threshold), math.floor(rule.threshold) + 1}) do
      if value >= 0 and not seen[value] then points[#points + 1] = value; seen[value] = true end
    end
  end
  table.sort(points)
  local breakpoints = {}
  for _, value in ipairs(points) do
    local format, visible, color = "%d", value >= 2 and BaseTextVisible(data, property), nil
    for _, rule in ipairs(rules) do
      if Matches(value, rule) then
        if rule.channel == "color" then color = rule.value
        elseif rule.channel == "visible" then visible = rule.value ~= false
        elseif rule.channel == "text" and type(rule.value) == "string" then format = rule.value:gsub("%%", "%%%%"); visible = true end
      end
    end
    if not visible then format = ""
    elseif color then
      local c = Color(color, {1,1,1,1})
      local r,g,b = c:GetRGB()
      format = ("|cff%02x%02x%02x"):format(math.floor(r*255+0.5),math.floor(g*255+0.5),math.floor(b*255+0.5)) .. format .. "|r"
    end
    breakpoints[#breakpoints + 1] = {threshold = value, format = format}
  end
  return breakpoints
end
-- The stack text for a known count (Stack Count "=" in the trigger): what the
-- formatter would write, or Blizzard's default of the number from 2 stacks.
function Display.StackTextFor(data, property, count)
  local breakpoints = StackBreakpoints(data, property)
  if not breakpoints then return count >= 2 and tostring(count) or "" end
  local format = ""
  for _, point in ipairs(breakpoints) do
    if point.threshold <= count then format = point.format end
  end
  -- %d is the count and %% a literal percent sign.
  local parts = {}
  for piece in (format .. "%%"):gmatch("(.-)%%%%") do parts[#parts + 1] = (piece:gsub("%%d", tostring(count))) end
  return table.concat(parts, "%")
end
function Display.StackTextCondition(data, property)
  if not (C_StringUtil and C_StringUtil.CreateNumericRuleFormatter) then return end
  local breakpoints = StackBreakpoints(data, property)
  if not breakpoints then return end
  local formatter = C_StringUtil.CreateNumericRuleFormatter()
  formatter:SetBreakpoints(breakpoints)
  return formatter
end
local function OwnsDurationColor(data, property)
  local target = TextProperty(data, property, "duration")
  if target and Display.SupportsDurationColorCondition() and #NumericRules(data, target) > 0 then return true end
  target = TextProperty(data, property, "stack")
  return target and C_StringUtil and C_StringUtil.CreateNumericRuleFormatter and #NumericRules(data, target, true) > 0
end

local function PropertyType(data, property)
  if conditionActions[property] then return conditionActions[property] end
  local index, key = property:match('^sub%.(%d+)%.(.+)$')
  if index then
    local element = data.subRegions and data.subRegions[tonumber(index)]
    if Display.IsDetachedElement(data, element) then
      local definition = Private.subRegionTypes[element.type]
      local properties = definition and definition.properties
      properties = type(properties) == 'function' and properties(data, element) or properties
      local property = properties and properties[key]
      if property and not property.valueFromBoolean and not property.colorFromBoolean then return property.type end
      return
    end
    if element and key == 'text_text' and Display.TextKind(element.text_text) ~= 'literal' then return end
    return element and elementProperties[element.type] and elementProperties[element.type][key]
  end
  if property == 'displayText' and Display.TextKind(data.displayText) ~= 'literal' then return end
  return rootProperties[data.regionType] and rootProperties[data.regionType][property]
end

function Display.FilterConditionProperties(data, properties)
  if Display.Enabled(data) then
    properties.faAuraHighlightColor = {display = "Aura Highlight Color", type = "color", default = {1, 0.82, 0, 1}}
    properties.faAuraHighlightStyle = {display = "Aura Highlight Style", type = "list", default = "border",
      values = {border = "Border", glow = "Glow (Static)", pulseBorder = "Border (Pulsing)", pulseGlow = "Glow (Pulsing)", overlay = "Overlay", texture = "Custom Texture"}}
    -- A cycle is a complete fade out/in on the highlight's own parent frame.
    properties.faAuraHighlightPulse = {display = "Aura Highlight Pulse Duration", type = "number", default = 1, min = 0.2, max = 5, step = 0.1}
    properties.faAuraHighlightSize = {display = "Aura Highlight Thickness / Padding", type = "number", default = 2, min = 1, max = 64, step = 1}
    properties.faAuraHighlightTexture = {display = "Aura Highlight Texture", type = "string", default = "Interface\\Buttons\\UI-ActionButton-Border"}
  end
  return properties
end

function Display.IsNativeConditionProperty(data, property)
  return not conditionActions[property]
    and not Display.IsDetachedProperty(data, property)
    and PropertyType(data, property) ~= nil
end

-- Keep borders inside the aura with a visible center, even for oversized imports.
function Display.HighlightBorderLimit(data)
  local width, height = Display.Dimensions(data)
  return math.max(1, math.floor(math.min(width, height) / 4))
end

-- The size control describes the highlight, not the icon. Its bounds and label
-- follow the style selected in this same condition without changing saved data.
function Display.HighlightPropertyOptions(data, condition, property, definition)
  if property ~= "faAuraHighlightSize" or not definition then return definition end
  local style = "border"
  for _, change in ipairs(condition.changes or {}) do
    if change.property == "faAuraHighlightStyle" then style = change.value end
  end
  local result = CopyTable(definition)
  if style == "pulseBorder" then style = "border" end
  result.display = style == "border" and "Aura Highlight Border Thickness" or "Aura Highlight Padding"
  result.max = style == "border" and Display.HighlightBorderLimit(data) or 64
  result.description = style == "border"
    and "Border thickness in UI units, limited to one quarter of the aura's smaller dimension so the center stays visible. Set style and color in this same condition."
    or "Extra space around a glow or custom texture, in UI units. Overlay always fills the aura and ignores padding. Set style and color in this same condition."
  return result
end

function Display.FilterConditionTemplates(data, templates)
  if not Display.Enabled(data) then return templates end
  for index, fields in pairs(templates) do
    local trigger = data.triggers[index] and data.triggers[index].trigger
    -- Secret aura state cannot be used as a condition input.
    if trigger and trigger.type == 'secretAura' then
      local native = {
        faAuraPandemic = {display = "In Pandemic Window", type = "alwaystrue"},
        faAuraStealable = {display = "Buff Is Stealable", type = "alwaystrue"},
        faAuraNotStealable = {display = "Buff Is Not Stealable", type = "alwaystrue"},
        faAuraPresent = {display = "Aura Present", type = "alwaystrue"},
        faAuraMissing = {display = "Aura Missing", type = "alwaystrue"},
        faAuraType = {display = "Aura Type", type = "select", operator_types = "native_aura_dispel", values = {HELPFUL = "Buff", HARMFUL = "Debuff"}},
        faAuraDispel = {display = "Dispel Type", type = "select", operator_types = "native_aura_dispel",
          values = {Magic = "Magic", Curse = "Curse", Disease = "Disease", Poison = "Poison", Bleed = "Bleed", Enrage = "Enrage", None = "None"}},
      }
      if Display.SupportsDurationColorCondition() then
        for key, definition in pairs(durationVariables) do
          -- Start and End Time are kept for displays that already use them.
          local offered = (key ~= "faAuraStart" and key ~= "faAuraEnd")
          if not offered then
            for _, condition in ipairs(data.conditions or {}) do
              if UsesVariable(condition.check, index, key) then offered = true end
            end
          end
          if offered and Enum.DurationTextBindingProperty[definition[1]] ~= nil then
            native[key] = {display = definition[2], type = "number", operator_types = "native_aura_duration"}
          end
        end
      end
      if C_StringUtil and C_StringUtil.CreateNumericRuleFormatter then
        native.faAuraApplications = {display = "Stack Count", type = "number"}
      end
      templates[index] = native
    else templates[index] = fields end
  end
  return templates
end

function Display.FilterGlobalConditions(data, templates)
  return templates
end

local function ValidCheck(data, check)
  if not check or not check.variable then return true end -- Unfinished editor row.
  if check.variable == 'AND' or check.variable == 'OR' then
    for _, child in ipairs(check.checks or {}) do
      if not ValidCheck(data, child) then return false end
    end
    return true
  end
  if check.trigger == -1 then return true end
  local trigger = data.triggers[check.trigger] and data.triggers[check.trigger].trigger
  return trigger and (trigger.type ~= 'secretAura' or Display.NativeConditionKind(data, check) ~= nil)
end

function Display.ValidateConditions(data)
  local timeProperties = {}
  for index, condition in ipairs(data.conditions or {}) do
    if Display.ContainsNativeCondition(data, condition.check) then
      local kind = Display.NativeConditionKind(data, condition.check)
      if not kind or condition.linked or (data.conditions[index + 1] and data.conditions[index + 1].linked) then
        return "Aura (Modern) conditions cannot use AND, OR, or Else If."
      end
      if durationVariables[kind] and condition.check.op and condition.check.op ~= "<" and condition.check.op ~= ">=" then
        return "Aura (Modern) time conditions support < and >=."
      end
      if (kind == "faAuraDispel" or kind == "faAuraType") and condition.check.op
        and condition.check.op ~= "==" and condition.check.op ~= "~=" then
        return "Aura (Modern) type conditions support = and !=."
      end
      if kind == "faAuraMissing" then
        local showOn = Display.ShowOn(Display.GetTrigger(data))
        if not Display.missingRootProperties[data.regionType] then
          return "Aura Missing works on Icon, Bar, Progress Texture and Text displays."
        end
        if showOn ~= "showOnMissing" and showOn ~= "showAlways" then
          return "Aura Missing needs the trigger's Show On set to Aura(s) Missing or Always."
        end
      end
      for _, change in ipairs(condition.changes or {}) do
        if kind == "faAuraRemaining" and IsGlowProperty(data, change.property)
          and (condition.check.op ~= "<" or change.value ~= true) then
          return "A Remaining Time glow condition must use < and turn the glow on."
        end
        if kind == "faAuraPandemic" and IsGlowProperty(data, change.property) then
          if change.value ~= true then return "An In Pandemic Window glow condition must turn the glow on." end
          -- One glow follows one timer: Remaining Time's clip or the pandemic frame.
          local _, _, lateIndex = Display.LateGlowSpec(data, Display.GetTrigger(data))
          if lateIndex and change.property == "sub." .. lateIndex .. ".glow" then
            return "A Glow can follow Remaining Time or the pandemic window, not both."
          end
        end
        if durationVariables[kind] and change.property then
          local target = TextProperty(data, change.property, "duration")
          if target then
            if timeProperties[target] and timeProperties[target] ~= kind then
              return "Use one time basis per countdown text: seconds, percentage, elapsed, total, start, or end."
            end
            timeProperties[target] = kind
          end
        end
        if change.property and not Display.NativeConditionAllowsProperty(data, condition.check, change.property) then
          return "Choose a supported property for this Aura (Modern) condition."
        end
      end
    end
    if not ValidCheck(data, condition.check) then
      return 'Use another trigger or a global condition. Aura (Modern) does not expose aura state to conditions.'
    end
  end
end

-- Allocate and bind conditional elements during configuration, never from combat updates.
function Display.PrepareConditionAppearance(data)
  local result
  for _, condition in ipairs(data.conditions or {}) do
    for _, change in ipairs(condition.changes or {}) do
      local index, key = (change.property or ''):match('^sub%.(%d+)%.(.+)$')
      index = tonumber(index)
      if index and not Display.IsDetachedProperty(data, change.property) and (key == 'glow' or key == 'text_visible') and PropertyType(data, change.property) then
        if not result then
          result = {}
          for field, value in pairs(data) do result[field] = value end
          result.subRegions = {}
          for elementIndex, element in ipairs(data.subRegions) do result.subRegions[elementIndex] = element end
        end
        if result.subRegions[index] == data.subRegions[index] then result.subRegions[index] = CopyTable(data.subRegions[index]) end
        result.subRegions[index][key] = true
      end
    end
  end
  if result then result.nativeConditionBaseData = data end
  return result or data
end

local function SetFontSize(text, size)
  local font, _, flags = text:GetFont()
  text:SetFont(font, size, flags)
end

local function ApplyProperty(button, data, property, value, overrides)
  -- Native aura children deny addon access while aura information is secret.
  -- Sample icons (the preview and the static Missing icon) are the addon's own.
  if OwnsDurationColor(data, property) then return end
  if not button.preview and (InCombatLockdown() or C_Secrets.ShouldAurasBeSecret()) then return end
  local index, key = property:match('^sub%.(%d+)%.(.+)$')
  if index then
    index = tonumber(index)
    local entry = button.sharedElements and button.sharedElements[index]
    if not entry then return end
    if key == 'text_color' and entry.text then entry.text:SetTextColor(unpack(value))
    elseif (key == 'text_visible' or key == 'text_alpha') and entry.text then
      local prefix = 'sub.' .. index .. '.'
      local visible = overrides[prefix .. 'text_visible']
      if visible == nil then visible = data.subRegions[index].text_visible ~= false end
      local alpha = overrides[prefix .. 'text_alpha'] or data.subRegions[index].text_alpha or 1
      entry.text:SetAlpha(visible and alpha or 0)
    elseif key == 'text_text' and entry.text then entry.text:SetText((value:gsub('%%%%', '%%')))
    elseif key == 'text_fontSize' and entry.text then SetFontSize(entry.text, value)
    elseif (key == 'text_anchorXOffset' or key == 'text_anchorYOffset') and entry.text then
      local point, target, relativePoint, x, y = entry.text:GetPoint(1)
      entry.text:ClearAllPoints()
      entry.text:SetPoint(point, target, relativePoint, key == 'text_anchorXOffset' and value or x, key == 'text_anchorYOffset' and value or y)
    elseif key == 'glow' then
      local frame = entry.elementFrames and entry.elementFrames.glow
      if frame then frame:SetAlpha(value and 1 or 0) end
    end
  elseif property == 'color' then
    if data.regionType == 'text' then
      if button.mainText then button.mainText:SetTextColor(unpack(value)) end
    else button.icon:SetVertexColor(unpack(value)) end
  elseif property == 'foregroundColor' and button.progressTexture then button.progressTexture.texture:SetVertexColor(unpack(value))
  elseif property == 'desaturateForeground' and button.progressTexture then button.progressTexture.texture:SetDesaturated(value)
  elseif property == 'backgroundColor' and button.progressBackground then button.progressBackground:SetColor(unpack(value))
  elseif property == 'barColor' and button.bar then button.bar:SetStatusBarColor(unpack(value))
  elseif property == 'backgroundColor' and button.barBackground then button.barBackground:SetColorTexture(unpack(value))
  elseif property == 'desaturate' then button.icon:SetDesaturated(value)
  elseif property == 'icon_color' then button.icon:SetVertexColor(unpack(value))
  elseif property == 'zoom' then
    -- Preserve the configured aspect ratio and texture offsets on condition edits.
    Display.StyleIconTexCoords(button, data, value)
  elseif property == 'inverse' then button.cooldown:SetReverse(value)
  elseif property == 'cooldownSwipe' then button.cooldown:SetDrawSwipe(value)
  elseif property == 'cooldownEdge' then button.cooldown:SetDrawEdge(value)
  elseif property == 'cooldownTextDisabled' then button.cooldown:SetHideCountdownNumbers(value)
  elseif property == 'fontSize' and button.mainText then SetFontSize(button.mainText, value)
  elseif property == 'displayText' and button.mainText then button.mainText:SetText((value:gsub('%%%%', '%%'))) end
end

-- Applies the "Aura Missing" conditions to the static Missing icon: its
-- colour, desaturation, zoom, glows and texts. Called when it is styled and
-- after other conditions changed the same properties. Highlights are drawn by
-- StyleNativeConditionIndicators and shown by StyleMissingIcon.
function Display.ApplyMissingConditions(native, data)
  local values = {}
  for _, condition in ipairs(data.conditions or {}) do
    if Display.NativeConditionKind(data, condition.check) == "faAuraMissing" then
      for _, change in ipairs(condition.changes or {}) do
        if change.property and not indicatorProperties[change.property] and change.value ~= nil
          and Display.NativeConditionAllowsProperty(data, condition.check, change.property) then
          values[change.property] = change.value
        end
      end
    end
  end
  for property, value in pairs(values) do ApplyProperty(native, data, property, value, values) end
end

function Display.ApplyConditionAppearance(button, region, data)
  local overrides = region.secretAuraConditionValues or {}
  for index, element in ipairs(data.subRegions or {}) do
    if not Display.IsDetachedElement(data, element) then
      if element.type == 'subglow' then ApplyProperty(button, data, 'sub.' .. index .. '.glow', element.glow == true, overrides)
      elseif element.type == 'subtext' then ApplyProperty(button, data, 'sub.' .. index .. '.text_visible', element.text_visible ~= false, overrides) end
    end
  end
  for property, value in pairs(region.secretAuraConditionValues or {}) do
    ApplyProperty(button, data, property, value, overrides)
  end
end

function Display.SetConditionProperty(region, property, ...)
  local native = region.blizzardAuraDisplay
  if not native or not native.active then return end
  local kind = PropertyType(native.data, property)
  if not kind then return end
  local value = kind == 'color' and {...} or ...
  region.secretAuraConditionValues = region.secretAuraConditionValues or {}
  region.secretAuraConditionValues[property] = value
  -- While access to the native buttons is denied the values below are not
  -- applied; RefreshConditionAppearance applies them once access returns.
  if InCombatLockdown() or C_Secrets.ShouldAurasBeSecret() then region.secretAuraConditionDirty = true end
  for _, instance in ipairs(native.instances) do
    for _, button in ipairs(instance.buttons) do ApplyProperty(button, native.data, property, value, region.secretAuraConditionValues) end
    -- The Missing look follows the same non-aura conditions.
    local missing = instance.single and instance.single.missing
    if missing and missing.native then
      ApplyProperty(missing.native, native.data, property, value, region.secretAuraConditionValues)
      Display.KeepMissingDesaturated(missing.native, native.data)
    end
  end
end

-- Condition evaluation continues while access is denied; restore only its latest result.
-- Only displays whose values changed while access was denied are touched: this
-- runs for every active display at each combat or restriction change, and each
-- property applied re-lays out text or textures on all of the display's buttons.
function Display.RefreshConditionAppearance(region)
  local native = region.blizzardAuraDisplay
  if not native or not native.active or not region.secretAuraConditionValues then return end
  if not region.secretAuraConditionDirty then return end
  region.secretAuraConditionDirty = nil
  for _, instance in ipairs(native.instances) do
    for _, button in ipairs(instance.buttons) do
      Display.ApplyConditionAppearance(button, region, native.data)
    end
    -- Keep the Missing look in step with the live aura slot.
    local missing = instance.single and instance.single.missing
    if missing and missing.native then
      Display.ApplyConditionAppearance(missing.native, region, native.data)
      Display.KeepMissingDesaturated(missing.native, native.data)
    end
  end
end

function Display.StyleNativeConditionIndicators(native, data)
  local button = native.button
  if not native.preview and button.ClearPandemicRegions then button:ClearPandemicRegions() end
  for _, textures in pairs(native.conditionIndicators or {}) do for _, texture in ipairs(textures) do texture:Hide() end end
  native.conditionIndicators = native.conditionIndicators or {}
  -- Stop and reset pooled animation hosts before changing native registrations.
  native.conditionHosts = native.conditionHosts or {}
  for _, host in pairs(native.conditionHosts) do
    if host.pulse then host.pulse:Stop() end
    host:SetAlpha(1)
  end
  -- Bindings are removed by texture reference; AddDispelTypeTexture returns no
  -- index. Keep these separate from the display's normal dispel indicator.
  for _, texture in ipairs(native.conditionDispelTextures or {}) do button:RemoveDispelTypeTexture(texture) end
  native.conditionDispelTextures = {}
  native.conditionPreview = {}
  native.conditionData = native.preview and data or nil
  -- Glows turned on by "In Pandemic Window" (Display.PandemicGlowHolder):
  -- Blizzard shows their frames during the window; previews use the sample.
  for _, holder in pairs(native.pandemicGlows or {}) do
    if native.preview then
      native.conditionPreview[#native.conditionPreview + 1] = {texture = holder, kind = "faAuraPandemic"}
    elseif button.AddPandemicRegion then
      button:AddPandemicRegion(holder)
    end
  end
  -- Highlight textures must be above the icon and swipe. The button itself is
  -- below both; placing textures there hid thin borders and exposed only overflow.
  -- Inside the Total Duration gate clip, when there is one, so a rejected aura
  -- shows no highlight either.
  native.conditionOverlay = native.conditionOverlay or CreateFrame("Frame", nil, native.gateClip or button)
  native.conditionOverlay:SetAllPoints(button)
  local base = native.elementFrames and native.elementFrames.sharedBase
  native.conditionOverlay:SetFrameLevel(math.max(native.cooldown:GetFrameLevel(), native.bar and native.bar:GetFrameLevel() or 0,
    base and base:GetFrameLevel() or button:GetFrameLevel()) + 1)
  local dispelKeys = {"None", "Magic", "Curse", "Disease", "Poison", "Bleed", "Enrage", ""}
  for index, condition in ipairs(data.conditions or {}) do
    local kind = Display.NativeConditionKind(data, condition.check)
    if kind and not durationVariables[kind] and kind ~= "faAuraApplications" and not condition.linked then
      local settings, configured = {}, false
      for _, change in ipairs(condition.changes or {}) do
        if indicatorProperties[change.property] then settings[change.property] = change.value; configured = true end
      end
      local check = condition.check
      -- Type checks accept = and ~= (the other types).
      local equal = check.op == "=="
      if kind == "faAuraType" and ((check.op ~= "==" and check.op ~= "~=") or (check.value ~= "HELPFUL" and check.value ~= "HARMFUL")) then configured = false end
      if kind == "faAuraDispel" and ((check.op ~= "==" and check.op ~= "~=") or type(check.value) ~= "string") then configured = false end
      -- Aura Missing highlights belong to the static Missing icon only.
      if kind == "faAuraMissing" and not native.preview then configured = false end
      if configured then
        local host = native.conditionHosts[index]
        if not host then
          host = CreateFrame("Frame", nil, native.conditionOverlay)
          host:SetAllPoints(button)
          native.conditionHosts[index] = host
        end
        local textures = native.conditionIndicators[index]
        if not textures then
          textures = {}
          for i = 1, 4 do textures[i] = host:CreateTexture(nil, "OVERLAY", nil, 7) end
          native.conditionIndicators[index] = textures
        end
        local style = settings.faAuraHighlightStyle or "border"
        local pulsing = style == "pulseBorder" or style == "pulseGlow"
        if pulsing then
          style = style == "pulseBorder" and "border" or "glow"
          local seconds = tonumber(settings.faAuraHighlightPulse) or 1
          seconds = seconds == seconds and math.max(0.2, math.min(5, seconds)) or 1
          if not host.pulse then
            host.pulse = host:CreateAnimationGroup()
            host.pulse:SetLooping("REPEAT")
            host.fadeOut = host.pulse:CreateAnimation("Alpha")
            host.fadeOut:SetOrder(1)
            host.fadeOut:SetFromAlpha(1); host.fadeOut:SetToAlpha(0.2)
            host.fadeIn = host.pulse:CreateAnimation("Alpha")
            host.fadeIn:SetOrder(2)
            host.fadeIn:SetFromAlpha(0.2); host.fadeIn:SetToAlpha(1)
          end
          host.fadeOut:SetDuration(seconds / 2)
          host.fadeIn:SetDuration(seconds / 2)
          host.pulse:Play()
        end
        local color = Color(settings.faAuraHighlightColor, {1, 0.82, 0, 1})
        local r,g,b,alpha = color:GetRGBA()
        local size = tonumber(settings.faAuraHighlightSize) or 2
        size = size == size and math.max(1, math.min(64, size)) or 2
        -- Render old exports safely without overwriting their configured size.
        if style == "border" then size = math.min(size, Display.HighlightBorderLimit(data)) end
        local asset = "Interface\\Buttons\\WHITE8X8"
        if style == "glow" then asset = "Interface\\Buttons\\UI-ActionButton-Border"
        elseif style == "texture" and type(settings.faAuraHighlightTexture) == "string" and settings.faAuraHighlightTexture ~= "" then
          asset = settings.faAuraHighlightTexture
        end
        for side, texture in ipairs(textures) do
          texture:ClearAllPoints(); texture:Hide()
          if style == "border" or side == 1 then
            texture:SetTexture(asset)
            texture:SetVertexColor(r,g,b,1)
            texture:SetAlpha(alpha)
            texture:SetDesaturated(style == "glow")
            texture:SetBlendMode(style == "glow" and "ADD" or "BLEND")
            if style == "border" then
              if side <= 2 then
                local point = side == 1 and "TOP" or "BOTTOM"
                texture:SetPoint(point .. "LEFT", button, point .. "LEFT")
                texture:SetPoint(point .. "RIGHT", button, point .. "RIGHT"); texture:SetHeight(size)
              else
                local point = side == 3 and "LEFT" or "RIGHT"
                texture:SetPoint("TOP" .. point, button, "TOP" .. point)
                texture:SetPoint("BOTTOM" .. point, button, "BOTTOM" .. point); texture:SetWidth(size)
              end
            else
              local padding = style == "glow" and (size + 8) or style == "texture" and size or 0
              texture:SetPoint("TOPLEFT", button, "TOPLEFT", -padding, padding)
              texture:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", padding, -padding)
            end
            if native.preview then
              -- Only ordinary preview textures use a public sample predicate.
              native.conditionPreview[#native.conditionPreview + 1] = {texture = texture, kind = kind, value = check.value, equal = equal}
            elseif kind == "faAuraPandemic" and button.AddPandemicRegion then
              button:AddPandemicRegion(texture)
            elseif button.AddDispelTypeTexture then
              local options = {showWhenHelpful = true, showWhenHarmful = true, showWithoutDispelType = true,
                style = Enum.CustomAuraButtonDispelTypeTextureStyle.CustomAsset, customDispelAssetMap = {}, customDispelColorMap = {}}
              if kind == "faAuraType" then
                -- ~= Buff is Debuff and the other way round.
                local wanted = check.value
                if not equal then wanted = wanted == "HELPFUL" and "HARMFUL" or "HELPFUL" end
                options.showWhenHelpful, options.showWhenHarmful = wanted == "HELPFUL", wanted == "HARMFUL"
              elseif kind == "faAuraStealable" or kind == "faAuraNotStealable" then
                options.showWhenHarmful = false
                options.stealableFilter = Enum.CustomAuraButtonDispelTypeStealableFilter[kind == "faAuraStealable" and "Stealable" or "NotStealable"]
              end
              for _, key in ipairs(dispelKeys) do
                -- Blizzard represents Enrage as an empty dispel name.
                local dispelKey = check.value == "Enrage" and "" or check.value
                -- = maps only the chosen type; ~= maps every other one.
                if kind ~= "faAuraDispel" or (dispelKey == key) == equal then
                  options.customDispelAssetMap[key] = {asset = asset}
                  options.customDispelColorMap[key] = CreateColor(r,g,b,1)
                end
              end
              button:AddDispelTypeTexture(texture, options)
              native.conditionDispelTextures[#native.conditionDispelTextures + 1] = texture
            end
          end
        end
      end
    end
  end
  if native.preview then Display.UpdateConditionPreview(native, data, 6) end
end

-- A six-second Magic sample follows the configured aura type. The final 30%
-- illustrates pandemic styling; these sample values never come from live auras.
function Display.UpdateConditionPreview(native, data, remaining)
  local trigger = Display.GetTrigger(data)
  local helpful = not trigger or trigger.debuffType ~= "HARMFUL"
  for _, entry in ipairs(native.conditionPreview or {}) do
    -- ~= checks (entry.equal == false) show for every other type.
    local show = entry.kind == "faAuraPresent"
      or entry.kind == "faAuraType" and (entry.value == (helpful and "HELPFUL" or "HARMFUL")) == (entry.equal ~= false)
      or entry.kind == "faAuraDispel" and (entry.value == "Magic") == (entry.equal ~= false)
      or entry.kind == "faAuraNotStealable" and helpful
      or entry.kind == "faAuraPandemic" and remaining <= 1.8 and remaining > 0
    entry.texture:SetShown(show == true)
  end
end
