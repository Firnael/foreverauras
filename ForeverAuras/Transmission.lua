-- Modified for ForeverAuras, 2026-09-18.
-- Modifications Copyright (C) 2026 ForeverAuras. Licensed under the GNU GPL v2 (see LICENSE).
--[[ Transmission.lua
This file contains all transmission related functionality, e.g. import/export and chat links.
For that it hooks into the chat frame and addon message channels.

Notable functions in this file are:

DisplayToString(id, forChat)
Converts the display id to a plain text string

DataToString(id)
Converts the display id to a formatted table

SerializeTable(data)
Converts the table data to a formatted table

Import(str, [target])
Imports an aura from a table, which may or may not be encoded as a B64 string.
If target is installed data, or is a uid which points to installed data, then the import will be an update to that aura

]]--
if not WeakAuras.IsLibsOK() then return end
---@type string
local AddonName = ...
---@class Private
local Private = select(2, ...)

-- Frames and hooks from this file are timed by the profiler (see Private.TimedAPI).
local CreateFrame, hooksecurefunc, TimedHookScript = Private.TimedAPI("Transmission")
-- Lua APIs
local tinsert = table.insert
local tostring, string_char, strsplit = tostring, string.char, strsplit
local pairs, type, unpack = pairs, type, unpack
local error = error
local bit_band, bit_lshift, bit_rshift = bit.band, bit.lshift, bit.rshift

---@class WeakAuras
local WeakAuras = WeakAuras;
local L = WeakAuras.L;

local versionString = WeakAuras.versionString;

-- Local functions
local decodeB64, GenerateUniqueID
local CompressDisplay, ShowTooltip, TableToString, StringToTable
local RequestDisplay, TransmitError, TransmitDisplay

local bytetoB64 = {
  [0]="a","b","c","d","e","f","g","h",
  "i","j","k","l","m","n","o","p",
  "q","r","s","t","u","v","w","x",
  "y","z","A","B","C","D","E","F",
  "G","H","I","J","K","L","M","N",
  "O","P","Q","R","S","T","U","V",
  "W","X","Y","Z","0","1","2","3",
  "4","5","6","7","8","9","(",")"
}

local B64tobyte = {
  a =  0,  b =  1,  c =  2,  d =  3,  e =  4,  f =  5,  g =  6,  h =  7,
  i =  8,  j =  9,  k = 10,  l = 11,  m = 12,  n = 13,  o = 14,  p = 15,
  q = 16,  r = 17,  s = 18,  t = 19,  u = 20,  v = 21,  w = 22,  x = 23,
  y = 24,  z = 25,  A = 26,  B = 27,  C = 28,  D = 29,  E = 30,  F = 31,
  G = 32,  H = 33,  I = 34,  J = 35,  K = 36,  L = 37,  M = 38,  N = 39,
  O = 40,  P = 41,  Q = 42,  R = 43,  S = 44,  T = 45,  U = 46,  V = 47,
  W = 48,  X = 49,  Y = 50,  Z = 51,["0"]=52,["1"]=53,["2"]=54,["3"]=55,
  ["4"]=56,["5"]=57,["6"]=58,["7"]=59,["8"]=60,["9"]=61,["("]=62,[")"]=63
}

-- This code is based on the Encode7Bit algorithm from LibCompress
-- Credit goes to Galmok (galmok@gmail.com)
local decodeB64Table = {}

function decodeB64(str)
  local bit8 = decodeB64Table;
  local decoded_size = 0;
  local ch;
  local i = 1;
  local bitfield_len = 0;
  local bitfield = 0;
  local l = #str;
  while true do
    if bitfield_len >= 8 then
      decoded_size = decoded_size + 1;
      bit8[decoded_size] = string_char(bit_band(bitfield, 255));
      bitfield = bit_rshift(bitfield, 8);
      bitfield_len = bitfield_len - 8;
    end
    ch = B64tobyte[str:sub(i, i)];
    bitfield = bitfield + bit_lshift(ch or 0, bitfield_len);
    bitfield_len = bitfield_len + 6;
    if i > l then
      break;
    end
    i = i + 1;
  end
  return table.concat(bit8, "", 1, decoded_size)
end

function GenerateUniqueID()
  -- generates a unique random 11 digit number in base64
  local s = {}
  for i=1,11 do
    tinsert(s, bytetoB64[math.random(0, 63)])
  end
  return table.concat(s)
end
WeakAuras.GenerateUniqueID = GenerateUniqueID

local function stripNonTransmissableFields(datum, fieldMap)
  for k, v in pairs(fieldMap) do
    if type(v) == "table" and type(datum[k]) == "table" then
      stripNonTransmissableFields(datum[k], v)
    elseif v == true then
      datum[k] = nil
    end
  end
end

function CompressDisplay(data, version)
  -- Clean up custom trigger fields that are unused
  -- Those can contain lots of unnecessary data.
  -- Also we warn about any custom code, so removing unnecessary
  -- custom code prevents unnecessary warnings
  for triggernum, triggerData in ipairs(data.triggers) do
    local trigger, untrigger = triggerData.trigger, triggerData.untrigger

    if (trigger and trigger.type ~= "custom") then
      trigger.custom = nil;
      trigger.customDuration = nil;
      trigger.customName = nil;
      trigger.customIcon = nil;
      trigger.customTexture = nil;
      trigger.customStacks = nil;
      if (untrigger) then
        untrigger.custom = nil;
      end
    end
  end

  local copiedData = CopyTable(data)
  -- External Display Changes (ExternalDisplay.lua) are session state: the export carries authored values.
  if Private.ExternalDisplayRestore then Private.ExternalDisplayRestore(copiedData) end
  local non_transmissable_fields = version >= 2000 and Private.non_transmissable_fields_v2000
                                                       or Private.non_transmissable_fields
  stripNonTransmissableFields(copiedData, non_transmissable_fields)
  copiedData.tocversion = WeakAuras.BuildInfo
  return copiedData;
end

-- ForeverAuras (1.4.3-dev.4, Dan's /fa comm results: Forever delivers addon messages
-- on PARTY and GUILD but drops addon whispers): the chat a link was seen in is the
-- channel its transfer uses. Keyed by "character - display", bounded.
-- ForeverAuras (1.4.3-dev.5, Dan's dev.4 report: still times out): "/fa comm trace"
-- prints every step of a link transfer on both sides.
local function Trace(...)
  if Private.transferTrace then print("|cff9900ffFA share|r", ...) end
end
local function Shown(value)
  if issecretvalue(value) then return "<hidden>" end
  return tostring(value)
end
local linkChannels, linkChannelCount = {}, 0
local chatEventChannels = {
  CHAT_MSG_PARTY = "PARTY", CHAT_MSG_PARTY_LEADER = "PARTY",
  CHAT_MSG_RAID = "RAID", CHAT_MSG_RAID_LEADER = "RAID",
  CHAT_MSG_GUILD = "GUILD", CHAT_MSG_OFFICER = "GUILD",
  CHAT_MSG_INSTANCE_CHAT = "INSTANCE_CHAT", CHAT_MSG_INSTANCE_CHAT_LEADER = "INSTANCE_CHAT",
}
local function RememberLinkChannel(event, characterName, displayName)
  local channel = chatEventChannels[event]
  if not channel then
    Trace("link seen in", event, "(no channel for it)")
    return
  end
  if linkChannels[characterName .. " - " .. displayName] ~= channel then
    Trace("link seen in", event, "key [" .. characterName .. " - " .. displayName .. "] channel", channel)
  end
  local key = characterName .. " - " .. displayName
  if linkChannels[key] == nil then
    if linkChannelCount >= 100 then
      wipe(linkChannels)
      linkChannelCount = 0
    end
    linkChannelCount = linkChannelCount + 1
  end
  linkChannels[key] = channel
end

local function filterFunc(_, event, msg, player, l, cs, t, flag, channelId, ...)
  if hasanysecretvalues(msg, player, t, flag, channelId, ...) then return end
  if flag == "GM" or flag == "DEV" then
    return
  end

  local newMsg = "";
  local remaining = msg;
  local done;
  local anyLinkFound = false
  repeat
    local start, finish, characterName, displayName = remaining:find("%[ForeverAuras: (.-) %- (.*)%]");
    if(characterName and characterName ~= "" and displayName) then
      characterName = characterName:gsub("|c[Ff][Ff]......", ""):gsub("|r", "");
      displayName = displayName:gsub("|c[Ff][Ff]......", ""):gsub("|r", "");
      RememberLinkChannel(event, characterName, displayName)
      newMsg = newMsg..remaining:sub(1, start-1);
      local url = remaining:sub(finish + 1):match("^ ([^%s|]+%.[^%s|]+)")
      if url then
        newMsg = newMsg.."|Haddon:ForeverAurasShare:url:"..url.."|h|cFF8800FF["..characterName.." |r|cFF8800FF- "..displayName.."]|h|r";
        finish = finish + 1 + #url
      else
        newMsg = newMsg.."|Haddon:ForeverAurasShare:import|h|cFF8800FF["..characterName.." |r|cFF8800FF- "..displayName.."]|h|r";
      end
      remaining = remaining:sub(finish + 1);
      anyLinkFound = true
    else
      newMsg = newMsg .. remaining
      done = true;
    end
  until(done)
  if anyLinkFound then
    local trimmedPlayer = Ambiguate(player, "none")
    local guid = select(5, ...)
    if event == "CHAT_MSG_WHISPER" and not UnitInRaid(trimmedPlayer) and not UnitInParty(trimmedPlayer) and not (IsGuildMember and IsGuildMember(guid)) then
      local _, num = BNGetNumFriends()
      for i=1, num do
        if C_BattleNet then -- introduced in 8.2.5 PTR
          local toon = C_BattleNet.GetFriendNumGameAccounts(i)
          for j=1, toon do
            local gameAccountInfo = C_BattleNet.GetFriendGameAccountInfo(i, j);
            if gameAccountInfo.characterName == trimmedPlayer and gameAccountInfo.clientProgram == "WoW" then
              return false, newMsg, player, l, cs, t, flag, channelId, ...; -- Player is a real id friend, allow it
            end
          end
        else -- keep old method for 8.2 and Classic
          local toon = BNGetNumFriendGameAccounts(i)
          for j=1, toon do
            local _, rName, rGame = BNGetFriendGameAccountInfo(i, j)
            if rName == trimmedPlayer and rGame == "WoW" then
              return false, newMsg, player, l, cs, t, flag, channelId, ...; -- Player is a real id friend, allow it
            end
          end
        end
      end
      return true -- Filter strangers
    else
      return false, newMsg, player, l, cs, t, flag, channelId, ...;
    end
  end
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_YELL", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_OFFICER", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_PARTY", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_PARTY_LEADER", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_RAID", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_RAID_LEADER", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER_INFORM", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_INSTANCE_CHAT", filterFunc)
ChatFrame_AddMessageEventFilter("CHAT_MSG_INSTANCE_CHAT_LEADER", filterFunc)

local Compresser = LibStub:GetLibrary("LibCompress")
local LibDeflate = LibStub:GetLibrary("LibDeflate")
local Serializer = LibStub:GetLibrary("AceSerializer-3.0")
-- The addon's own copy, whatever other addons registered (see Libs/LibSerialize).
local LibSerialize = ForeverAurasLibSerialize or LibStub("LibSerialize")
local Comm = LibStub:GetLibrary("AceComm-3.0")
local Chomp = LibStub:GetLibrary("Chomp")
-- the biggest bottleneck by far is in transmission and printing; so use maximal compression
local configForDeflate = {level = 9}
local configForLS = {
  errorOnUnserializableType =  false
}

local tooltipLoading;
local receivedData;
-- ForeverAuras (1.4.3-dev.2): the URL of the link being transferred, if it has one.
local fallbackUrl, fallbackLabel
local function ShowFallbackUrl()
  if not fallbackUrl then return end
  StaticPopup_Show("FOREVERAURAS_COPY_URL", fallbackLabel, nil, fallbackUrl)
  fallbackUrl, fallbackLabel = nil, nil
end

StaticPopupDialogs["FOREVERAURAS_COPY_URL"] = {
  text = L["%s\nPress Ctrl+C to copy the link."],
  button1 = CLOSE,
  hasEditBox = true,
  editBoxWidth = 320,
  OnShow = function(self, url)
    local editBox = self.GetEditBox and self:GetEditBox() or self.editBox
    editBox:SetText(url or "")
    editBox:HighlightText()
    editBox:SetFocus()
  end,
  EditBoxOnEnterPressed = function(editBox) editBox:GetParent():Hide() end,
  EditBoxOnEscapePressed = function(editBox) editBox:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

EventRegistry:RegisterCallback("SetItemRef", function(_, link, text)
  if hasanysecretvalues(link, text) then return end
  local url = type(link) == "string" and link:match("^addon:ForeverAurasShare:url:(.+)$")
  if url then
    local label = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if IsShiftKeyDown() then
      local editbox = GetCurrentKeyBoardFocus()
      local inner = label:match("%[(.-)%]")
      if editbox and inner then editbox:Insert("[ForeverAuras: " .. inner .. "] " .. url) end
      return
    end
    -- ForeverAuras (1.4.3-dev.2, Dan's dev.1 report): a link that carries a URL
    -- transfers the aura like any other link. The URL is the fallback, shown when
    -- the transfer cannot start or gets no answer.
    fallbackUrl, fallbackLabel = url, label
    link = "addon:ForeverAurasShare:import"
  elseif link == "addon:ForeverAurasShare:import" then
    fallbackUrl, fallbackLabel = nil, nil
  end
  if(link == "addon:ForeverAurasShare:import") then
    local label = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local characterName, displayName = label:match("%[(.-) %- (.*)%]")
    if(characterName and characterName ~= "" and displayName) then
      characterName = characterName:gsub("|c[Ff][Ff]......", ""):gsub("|r", "");
      displayName = displayName:gsub("|c[Ff][Ff]......", ""):gsub("|r", "");
      if(IsShiftKeyDown()) then
        local editbox = GetCurrentKeyBoardFocus();
        if(editbox) then
          editbox:Insert("[ForeverAuras: "..characterName.." - "..displayName.."]");
        end
      else
        local linkChannel = linkChannels[characterName .. " - " .. displayName]
        Trace("click key [" .. characterName .. " - " .. displayName .. "] remembered channel", tostring(linkChannel))
        characterName = characterName:gsub("%.", "")
        ShowTooltip({
          {2, "ForeverAuras", displayName, 0.5, 0, 1, 1, 1, 1},
          {1, L["Requesting display information from %s ..."]:format(characterName), 1, 0.82, 0}
        });
        tooltipLoading = true;
        receivedData = false;
        RequestDisplay(characterName, displayName, linkChannel);
        WeakAuras.timer:ScheduleTimer(function()
          if (tooltipLoading and not receivedData and ItemRefTooltip:IsVisible()) then
            ShowTooltip({
              {2, "ForeverAuras", displayName, 0.5, 0, 1, 1, 1, 1},
              {1, L["Error not receiving display information from %s"]:format(characterName), 1, 0, 0}
            })
            ShowFallbackUrl()
          end
        end, 5);
      end
    else
      ShowTooltip({
        {1, "ForeverAuras", 0.5, 0, 1},
        {1, L["Malformed ForeverAuras link"], 1, 0, 0}
      });
    end
  end
end);

local compressedTablesCache = {}

function TableToString(inTable, forChat)
  local serialized = LibSerialize:SerializeEx(configForLS, inTable)
  local compressed
  -- get from / add to cache
  if compressedTablesCache[serialized] then
    compressed = compressedTablesCache[serialized].compressed
    compressedTablesCache[serialized].lastAccess = time()
  else
    compressed = LibDeflate:CompressDeflate(serialized, configForDeflate)
    compressedTablesCache[serialized] = {
      compressed = compressed,
      lastAccess = time(),
    }
  end
  -- remove cache items after 5 minutes
  for k, v in pairs(compressedTablesCache) do
    if v.lastAccess < (time() - 300) then
      compressedTablesCache[k] = nil
    end
  end
  local encoded = "!WA:2!"
  if(forChat) then
    encoded = encoded .. LibDeflate:EncodeForPrint(compressed)
  else
    encoded = encoded .. LibDeflate:EncodeForWoWAddonChannel(compressed)
  end
  return encoded
end

function StringToTable(inString, fromChat)
  -- encoding format:
  -- version 0: simple b64 string, compressed with LC and serialized with AS
  -- version 1: b64 string prepended with "!", compressed with LD and serialized with AS
  -- version 2+: b64 string prepended with !FA:N! or !WA:N! (N is the encoding version)
  --   compressed with LD and serialized with LS
  if fromChat then inString = inString:match("^%s*(.-)%s*$") end
  local _, encodeVersion, encoded = inString:match("^!([FW]A):(%d+)!(.+)$")
  if encodeVersion then
    encodeVersion = tonumber(encodeVersion)
  else
    encoded, encodeVersion = inString:gsub("^%!", "")
  end

  local decoded
  if(fromChat) then
    if encodeVersion > 0 then
      decoded = LibDeflate:DecodeForPrint(encoded)
    else
      decoded = decodeB64(encoded)
    end
  else
    decoded = LibDeflate:DecodeForWoWAddonChannel(encoded)
  end

  if not decoded then
    return L["Error decoding."]
  end

  local decompressed
  if encodeVersion > 0 then
    decompressed = LibDeflate:DecompressDeflate(decoded)
    if not(decompressed) then
      return L["Error decompressing"]
    end
  else
    -- We ignore the error message, since it's more likely not a weakaura.
    decompressed = Compresser:Decompress(decoded)
    if not(decompressed) then
      return L["Error decompressing. This doesn't look like a ForeverAuras import."]
    end
  end

  local success, deserialized
  if encodeVersion < 2 then
    success, deserialized = Serializer:Deserialize(decompressed)
  else
    success, deserialized = LibSerialize:Deserialize(decompressed)
  end
  if not(success) then
    return L["Error deserializing"]
  end
  return deserialized
end
Private.StringToTable = StringToTable

-- excludedIds leaves those auras out, along with everything inside them.
function Private.DisplayToString(id, forChat, excludedIds)
  local data = WeakAuras.GetData(id);
  if(data) then
    excludedIds = excludedIds or {}
    local excluded = {}
    data.uid = data.uid or GenerateUniqueID()
    -- Check which transmission version we want to use
    local version = 1421
    for child in Private.TraverseSubGroups(data) do -- luacheck: ignore
      version = 2000
      break;
    end
    local transmitData = CompressDisplay(data, version);
    local transmit = {
      m = "d",
      d = transmitData,
      v = version,
      s = versionString
    };
    if(data.controlledChildren) then
      transmit.c = {};
      local uids = {}
      local index = 1
      for child in Private.TraverseAllChildren(data) do
        -- Children come after their group, so a group's exclusion reaches everything inside it.
        if excludedIds[child.id] or excluded[child.parent] then
          excluded[child.id] = true
        else
          if child.uid then
            if uids[child.uid] then
              child.uid = GenerateUniqueID()
            else
              uids[child.uid] = true
            end
          else
            child.uid = GenerateUniqueID()
          end
          transmit.c[index] = CompressDisplay(child, version);
          index = index + 1
        end
      end
    end
    if next(excluded) then
      local function dropExcluded(groupData)
        if not groupData.controlledChildren then return end
        local kept = {}
        for _, childId in ipairs(groupData.controlledChildren) do
          if not excluded[childId] then
            tinsert(kept, childId)
          end
        end
        groupData.controlledChildren = kept
      end
      dropExcluded(transmitData)
      for _, childData in ipairs(transmit.c or {}) do
        dropExcluded(childData)
      end
    end
    return TableToString(transmit, forChat);
  else
    return "";
  end
end

local orderedPairs
do
  local function __genOrderedIndex(t)
    local orderedIndex = {}
    for key in pairs(t) do
      if key ~= "__orderedIndex" then
        table.insert(orderedIndex, key)
      end
    end
    table.sort(orderedIndex, function(a, b)
      local typeA, typeB = type(a), type(b)
      if typeA ~= typeB then
        return typeA < typeB
      else
        return a < b
      end
    end)
    return orderedIndex
  end

  local function orderedNext(t, state)
    -- Equivalent of the next function, but returns the keys in the alphabetic
    -- order. We use a temporary ordered key table that is stored in the
    -- table being iterated.
    local key = nil
    if state == nil then
      -- the first time, generate the index
      t.__orderedIndex = __genOrderedIndex(t)
      key = t.__orderedIndex[1]
    else
      -- fetch the next value
      for i = 1, table.getn(t.__orderedIndex) do
        if t.__orderedIndex[i] == state then
          key = t.__orderedIndex[i+1]
        end
      end
    end

    if key then
      return key, t[key]
    end

    -- no more value to return, cleanup
    t.__orderedIndex = nil
  end

  function orderedPairs(t)
    return orderedNext, t, nil
  end
end

local function recurseStringify(data, level, lines, sorted)
  local pairsFn = sorted and orderedPairs or pairs
  for k, v in pairsFn(data) do
    local lineFormat = strrep("    ", level) .. "[%s] = %s"
    local form1, form2, value
    local kType, vType = type(k), type(v)
    if kType == "string" then
      form1 = "%q"
    elseif kType == "number" then
      form1 = "%d"
    else
      form1 = "%s"
    end
    if vType == "string" then
      form2 = "%q"
      v = v:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\"", "\\\"")
    elseif vType == "boolean" then
      v = tostring(v)
      form2 = "%s"
    else
      form2 = "%s"
    end
    lineFormat = lineFormat:format(form1, form2)
    if vType == "table" then
      tinsert(lines, lineFormat:format(k, "{"))
      recurseStringify(v, level + 1, lines, sorted)
      tinsert(lines, strrep("    ", level) .. "},")
    else
      tinsert(lines, lineFormat:format(k, v) .. ",")
    end
  end
end

function Private.DataToString(id, sorted)
  local data = WeakAuras.GetData(id)
  if data then
    return Private.SerializeTable(data, sorted):gsub("|", "||")
  end
end

function Private.SerializeTable(data, sorted)
  local lines = {"{"}
  recurseStringify(data, 1, lines, sorted)
  tinsert(lines, "}")
  return table.concat(lines, "\n")
end

function ShowTooltip(lines)
  ItemRefTooltip:Show();
  if not ItemRefTooltip:IsVisible() then
    ItemRefTooltip:SetOwner(UIParent, "ANCHOR_PRESERVE");
  end
  ItemRefTooltip:ClearLines();
  for i, line in ipairs(lines) do
    local sides, a1, a2, a3, a4, a5, a6, a7, a8 = unpack(line);
    if(sides == 1) then
      ItemRefTooltip:AddLine(a1, a2, a3, a4, a5);
    elseif(sides == 2) then
      ItemRefTooltip:AddDoubleLine(a1, a2, a3, a4, a5, a6, a7, a8);
    end
  end
  ItemRefTooltip:Show()
end

local delayedImport = CreateFrame("Frame")

local function ImportNow(data, children, target, linkedAuras, sender, callbackFunc)
  if InCombatLockdown() then
    WeakAuras.prettyPrint(L["Importing will start after combat ends."])

    delayedImport:RegisterEvent("PLAYER_REGEN_ENABLED")
    delayedImport:SetScript("OnEvent", function()
      delayedImport:UnregisterEvent("PLAYER_REGEN_ENABLED")
      ImportNow(data, children, target, linkedAuras, sender, callbackFunc)
    end)
    return
  end

  if Private.LoadOptions() then
    if not WeakAuras.IsOptionsOpen() then
      WeakAuras.OpenOptions()
    end
    Private.OpenUpdate(data, children, target, linkedAuras, sender, callbackFunc)
  end
end

function WeakAuras.Import(inData, target, callbackFunc, linkedAuras)
  local data, children, version
  if type(inData) == 'string' then
    -- encoded data
    local received = StringToTable(inData, true)
    if type(received) == 'string' then
      -- this is probably an error message from LibDeflate. Display it.
      ShowTooltip{
        {1, "ForeverAuras", 0.5333, 0, 1},
        {1, received, 1, 0, 0, 1}
      }
      return nil, received
    elseif received.m == "d" then
      data = received.d
      children = received.c
      version = received.v
    end
  elseif type(inData.d) == 'table' then
    data = inData.d
    children = inData.c
    version = inData.v
  end
  if type(data) ~= "table" then
    return nil, "Invalid import data."
  end

  local highestVersion = data.internalVersion or 0
  if children then
    for _, child in ipairs(children) do
      highestVersion = max(highestVersion, child.internalVersion or 0)
    end
  end
  if highestVersion > WeakAuras.InternalVersion() then
    -- Do not run PreAdd but still show Import Window
    tooltipLoading = nil;
    return ImportNow(data, children, target, linkedAuras, nil, callbackFunc)
  end

  if version < 2000 then
    if children then
      data.controlledChildren = {}
      for i, child in ipairs(children) do
        tinsert(data.controlledChildren, child.id)
        child.parent = data.id
      end
    end
  end

  if type(target) ~= 'nil' then
    local uid = type(target) == 'table' and target.uid or target
    local targetData = Private.GetDataByUID(uid)
    if not targetData then
      return false, "Invalid update target."
    else
      target = targetData
    end
    if data.uid and data.uid ~= target.uid then
      return false, "Invalid update target, uids don't match."
    end
  end
  WeakAuras.PreAdd(data)
  if children then
    for _, child in ipairs(children) do
      WeakAuras.PreAdd(child)
    end
  end

  tooltipLoading = nil;
  return ImportNow(data, children, target, linkedAuras, nil, callbackFunc)
end

-- ForeverAuras (1.4.3-dev.1, Dan's share-in-chat request): what the client says
-- about sending addon messages. A missing function reads as "not reported" (nil),
-- a hidden answer as blocked.
function Private.ChatTransferState()
  local state = {}
  local restricted = C_ChatInfo.AreOutgoingAddonChatMessagesRestricted
  if restricted then
    local value = restricted()
    state.restricted = issecretvalue(value) or value == true
    state.restrictedKnown = true
  end
  local lockdown = C_ChatInfo.InChatMessagingLockdown
  if lockdown then
    local value = lockdown()
    state.lockdown = issecretvalue(value) or value == true
    state.lockdownKnown = true
  end
  return state
end

function Private.PrintChatTransferDebug()
  local state = Private.ChatTransferState()
  local function describe(known, value)
    if not known then return "not available on this client" end
    return value and "|cffff4040yes|r" or "|cff40ff40no|r"
  end
  print("|cff9900ffForeverAuras|r chat sharing:")
  print("  addon messages restricted: " .. describe(state.restrictedKnown, state.restricted))
  print("  chat messaging lockdown: " .. describe(state.lockdownKnown, state.lockdown))
  print("  in combat: " .. (InCombatLockdown() and "yes" or "no") .. ", in instance: " .. (IsInInstance() and "yes" or "no"))
  local linked = 0
  if Private.linked then
    for _, time in pairs(Private.linked) do
      if time > GetTime() - 300 then linked = linked + 1 end
    end
  end
  print("  auras you linked in the last 5 minutes: " .. linked)
  Private.RunChatTransferTest()
end

-- ForeverAuras (1.4.3-dev.3, Dan's dev.2 report: the whisper was accepted but never
-- arrived): sends one addon message to this character over each channel it can use
-- and reports the client's result code and whether the message came back.
local transferTestFrame
function Private.RunChatTransferTest()
  local prefix = "FATransferTest"
  if not transferTestFrame then
    transferTestFrame = CreateFrame("Frame")
    transferTestFrame.waiting = {}
    transferTestFrame:RegisterEvent("CHAT_MSG_ADDON")
    transferTestFrame:SetScript("OnEvent", function(self, _, messagePrefix, message)
      if issecretvalue(messagePrefix) or issecretvalue(message) then
        if next(self.waiting) then print("  test: an addon message arrived but its content is hidden") end
        return
      end
      if messagePrefix ~= prefix then return end
      local channel = self.waiting[message]
      if channel then
        self.waiting[message] = nil
        print("  test " .. channel .. ": |cff40ff40came back|r")
      end
    end)
    if C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(prefix) end
  end
  local channels = {"WHISPER"}
  if IsInRaid() then tinsert(channels, "RAID") elseif IsInGroup() then tinsert(channels, "PARTY") end
  if IsInGuild() then tinsert(channels, "GUILD") end
  local name, realm = UnitFullName("player")
  for _, channel in ipairs(channels) do
    local token = channel .. math.random(100000, 999999)
    transferTestFrame.waiting[token] = channel
    local result = C_ChatInfo.SendAddonMessage(prefix, token, channel, channel == "WHISPER" and name or nil)
    local resultName
    if not issecretvalue(result) and Enum and Enum.SendAddonMessageResult then
      for enumName, value in pairs(Enum.SendAddonMessageResult) do
        if value == result then resultName = enumName end
      end
    end
    print("  test " .. channel .. ": send result " .. (issecretvalue(result) and "hidden" or tostring(result)) .. (resultName and (" (" .. resultName .. ")") or ""))
    C_Timer.After(3, function()
      if transferTestFrame.waiting[token] then
        transferTestFrame.waiting[token] = nil
        print("  test " .. channel .. ": |cffff4040nothing came back within 3 seconds|r")
      end
    end)
  end
  if #channels == 1 then print("  join a party and a guild, then run /fa comm again to test those channels too") end
end

local safeSenders = {}
-- ForeverAuras (1.4.3-dev.4): transfers over a group or guild channel reach everyone
-- on it, so every message starts with the name of the one player it is for.
-- ForeverAuras (1.4.3-dev.6, Dan's dev.5 trace): Forever names have two parts. A link
-- writes them "Fojji-Riya", the addon channel reports the sender as "Fojji Riya", and
-- UnitFullName gives "Fojji", "Riya". Names are compared with spaces and hyphens
-- removed, and that form (no spaces) is what addresses a message.
local function PlainName(name)
  return (name:gsub("[%s%-]", ""))
end
local function SameCharacter(a, b)
  local plainA, plainB = PlainName(a), PlainName(b)
  if plainA == plainB then return true end
  -- A same-realm sender on a client with realm names arrives without its realm.
  local firstA, firstB = a:match("^([^%-]+)%-"), b:match("^([^%-]+)%-")
  return (firstA ~= nil and PlainName(firstA) == plainB and not b:find("[%s%-]"))
      or (firstB ~= nil and PlainName(firstB) == plainA and not a:find("[%s%-]"))
end
local function IsThisPlayer(target)
  local name, realm = UnitFullName("player")
  if realm and realm ~= "" and target == PlainName(name .. realm) then return true end
  return target == PlainName(name)
end
local channelRequest

function RequestDisplay(characterName, displayName, linkChannel)
  local playerName, realm = Private.ExecEnv.UnitFullName("player")
  if characterName == playerName or (realm and characterName == playerName .. "-" .. realm:gsub("%s", "")) then
    tooltipLoading = nil
    local exported = Private.DisplayToString(displayName, true)
    if exported ~= "" then
      ItemRefTooltip:Hide()
      WeakAuras.Import(exported)
    else
      ShowTooltip({{1, "ForeverAuras", 0.5, 0, 1}, {1, L["Requested display does not exist"], 1, 0, 0}})
    end
    return
  end
  -- ForeverAuras (1.4.3-dev.1, Dan's share-in-chat request): both checks are read
  -- through Private.ChatTransferState, which tolerates a client without them, and
  -- /fa comm prints the same state.
  -- ForeverAuras (1.4.3-dev.2, Dan's dev.1 report): AreOutgoingAddonChatMessagesRestricted
  -- reads true on Forever in the open world, so it no longer stops the request. The
  -- request is sent and the 5 second timeout reports a transfer that got no answer.
  local transferState = Private.ChatTransferState()
  if transferState.lockdown then
    tooltipLoading = nil
    ShowTooltip({{1, "ForeverAuras", 0.5, 0, 1}, {1, "Aura sharing is unavailable while chat is restricted. Click the link again after restrictions end.", 1, 0.82, 0}})
    ShowFallbackUrl()
    return
  end
  local characterNameAmbiguate = Ambiguate(characterName, "none")
  safeSenders[characterName] = true
  safeSenders[characterNameAmbiguate] = true

  -- ForeverAuras (1.4.3-dev.4): a link seen in party, raid, instance or guild chat is
  -- requested over that channel. A link from anywhere else uses the group channel when
  -- the sender is grouped with this player, otherwise the whisper below.
  local channel = linkChannel
  if channel == "PARTY" and IsInRaid() then channel = "RAID" end
  if (channel == "PARTY" or channel == "RAID") and not IsInGroup() then channel = nil end
  if channel == "GUILD" and not IsInGuild() then channel = nil end
  if not channel then
    if UnitInRaid(characterNameAmbiguate) then channel = "RAID"
    elseif UnitInParty(characterNameAmbiguate) then channel = "PARTY" end
  end
  Trace("request to", characterName, "channel", tostring(channel), "in group", tostring(IsInGroup()), "in raid", tostring(IsInRaid()), "in guild", tostring(IsInGuild()))
  if channel then
    channelRequest = {from = characterName, display = displayName, time = GetTime()}
    local request = TableToString({m = "dR", d = displayName})
    Comm:SendCommMessage("ForeverAurasCh", PlainName(characterName) .. " " .. request, channel)
    return
  end

  local version = nil
  if characterNameAmbiguate:find("-", 1, true) then
    -- Cross realm transfer, use chomp
    version = 2
  end

  local transmit = {
    m = "dR",
    d = displayName,
    v = version
  };
  local transmitString = TableToString(transmit);
  Comm:SendCommMessage("ForeverAuras", transmitString, "WHISPER", characterName);
end

function TransmitError(errorMsg, characterName, channel)
  local transmit = {
    m = "dE",
    eM = errorMsg
  };
  if channel then
    Comm:SendCommMessage("ForeverAurasCh", PlainName(characterName) .. " " .. TableToString(transmit), channel)
    return
  end
  Comm:SendCommMessage("ForeverAuras", TableToString(transmit), "WHISPER", characterName);
end

function TransmitDisplay(id, characterName, version, channel)
  local encoded = Private.DisplayToString(id);
  if(encoded ~= "") then
    if channel then
      -- ForeverAuras (1.4.3-dev.4): the aura goes out on the channel the request came
      -- in on, addressed to the requester. Progress is sent at most once a second,
      -- since everyone on the channel receives it.
      local target = PlainName(characterName)
      local total = #encoded + #target + 1
      Trace("sending", id, "to", target, "on", channel, "bytes", total)
      local lastProgress = GetTime()
      Comm:SendCommMessage("ForeverAurasChP", target .. " 0 " .. total .. " " .. id, channel, nil, "ALERT")
      Comm:SendCommMessage("ForeverAurasCh", target .. " " .. encoded, channel, nil, "BULK", function(displayName, done, totalBytes)
        local now = GetTime()
        if done >= totalBytes or now - lastProgress >= 1 then
          lastProgress = now
          Comm:SendCommMessage("ForeverAurasChP", target .. " " .. done .. " " .. totalBytes .. " " .. displayName, channel, nil, "ALERT")
        end
      end, id)
    elseif version == 2  then
      -- Cross Realm communication
      local total = #encoded
      local messageOptions = {
        serialize = false,
        binaryBlob = true
      }

      Chomp.SmartAddonMessage("ForeverAuras2", encoded, "WHISPER", characterName, messageOptions)
      -- Chomp has no progress callback for SmartAddonMessage. Send a -1 as progress info
      local done = -1
      Comm:SendCommMessage("ForeverAurasProg", done.." "..total.." "..id, "WHISPER", characterName, "ALERT");
    else
      Comm:SendCommMessage("ForeverAuras", encoded, "WHISPER", characterName, "BULK", function(displayName, done, total)
        Comm:SendCommMessage("ForeverAurasProg", done.." "..total.." "..displayName, "WHISPER", characterName, "ALERT");
      end, id);
    end
  else
    Trace("cannot send", id, ": no such aura")
    TransmitError("dne", characterName, channel);
  end
end

local function HandleProgressComm(prefix, message, distribution, sender)
  if tooltipLoading and ItemRefTooltip:IsVisible() and safeSenders[sender] then
    receivedData = true;
    local done, total, displayName = strsplit(" ", message, 3)
    done = tonumber(done)
    total = tonumber(total)
    if done and total then
      if done == -1 then
        ShowTooltip({
          {2, "ForeverAuras", displayName, 0.5, 0, 1, 1, 1, 1},
          {1, L["Receiving display information"]:format(sender), 1, 0.82, 0},
          {2, L["No Progress Information available."]},
          {2, L["Receiving %s Bytes"]:format(total)}
        })
      elseif total >= done then
        local red = min(255, (1 - done / total) * 511)
        local green = min(255, (done / total) * 511)
        ShowTooltip({
          {2, "ForeverAuras", displayName, 0.5, 0, 1, 1, 1, 1},
          {1, L["Receiving display information"]:format(sender), 1, 0.82, 0},
          {2, " ", ("|cFF%2x%2x00"):format(red, green)..done.."|cFF00FF00/"..total}
        })
      end
    end
  end
end

local function HandleComm(prefix, message, distribution, sender, channel)
  if hasanysecretvalues(prefix, message, distribution, sender) then return end
  local linkValidityDuration = 60 * 5
  local safeSender = safeSenders[sender]
  local validLink = false
  if Private.linked then
    local expiredLinkTime = GetTime() - linkValidityDuration
    for id, time in pairs(Private.linked) do
      if time > expiredLinkTime then
        validLink = true
      end
    end
  end
  if not safeSender and not validLink then
    Trace("message from", sender, "ignored: not asked and nothing linked")
    return
  end

  local received = StringToTable(message);
  if(received and type(received) == "table" and received.m) then
    -- ForeverAuras (1.4.3-dev.4): on a shared channel an aura is only accepted from
    -- the character this player asked.
    if received.m == "d" and channel and not safeSender then return end
    if(received.m == "d") then
      tooltipLoading = nil;
      local data, children, version = received.d, received.c, received.v
      WeakAuras.PreAdd(data)
      if children then
        for _, child in ipairs(children) do
          WeakAuras.PreAdd(child)
        end
      end
      if version < 2000 then
        if children then
          data.controlledChildren = {}
          for i, child in ipairs(children) do
            tinsert(data.controlledChildren, child.id)
            child.parent = data.id
          end
        end
      end

      ItemRefTooltip:Hide()
      ImportNow(data, children, nil, nil, sender)
    elseif(received.m == "dR") then
      if(Private.linked and Private.linked[received.d] and Private.linked[received.d] > GetTime() - linkValidityDuration) then
        TransmitDisplay(received.d, sender, received.v, channel);
      else
        Trace("request for [" .. tostring(received.d) .. "] ignored: not linked by this character in the last 5 minutes")
      end
    elseif(received.m == "dE") then
      tooltipLoading = nil;
      if(received.eM == "dne") then
        ShowTooltip({
          {1, "ForeverAuras", 0.5333, 0, 1},
          {1, L["Requested display does not exist"], 1, 0, 0}
        });
      elseif(received.eM == "na") then
        ShowTooltip({
          {1, "ForeverAuras", 0.5333, 0, 1},
          {1, L["Requested display not authorized"], 1, 0, 0}
        });
      end
      ShowFallbackUrl()
    end
  elseif(ItemRefTooltip.WeakAuras_Tooltip_Thumbnail and ItemRefTooltip.WeakAuras_Tooltip_Thumbnail:IsVisible()) then
    ShowTooltip({
      {1, "ForeverAuras", 0.5333, 0, 1},
      {1, L["Transmission error"], 1, 0, 0}
    });
  end
end

-- ForeverAuras (1.4.3-dev.4): channel transfers. A message is "<short name> <body>";
-- only the named player handles it. The requester trusts the answer when it comes
-- from the character whose link was clicked, within five minutes of the click.
local function ForThisPlayer(message, sender)
  if hasanysecretvalues(message, sender) then
    Trace("channel message hidden: message", Shown(message) == "<hidden>" and "hidden" or "ok", "sender", Shown(sender))
    return
  end
  local target, body = message:match("^(%S+) (.*)$")
  if not target or not IsThisPlayer(target) then return end
  Trace("channel message from", sender, "for me, bytes", #message)
  if channelRequest and SameCharacter(channelRequest.from, sender) and GetTime() - channelRequest.time < 300 then
    safeSenders[sender] = true
  end
  return body
end

local function HandleChannelComm(prefix, message, distribution, sender)
  if hasanysecretvalues(prefix, distribution) then
    Trace("channel message hidden: prefix", Shown(prefix), "distribution", Shown(distribution))
    return
  end
  local body = ForThisPlayer(message, sender)
  if body then
    local received = StringToTable(body)
    Trace("handling on", distribution, "kind", type(received) == "table" and tostring(received.m) or tostring(received))
    HandleComm(prefix, body, distribution, sender, distribution)
  end
end

local function HandleChannelProgressComm(prefix, message, distribution, sender)
  if hasanysecretvalues(prefix, message, distribution, sender) then return end
  local body = ForThisPlayer(message, sender)
  if body then HandleProgressComm(prefix, body, distribution, sender) end
end

Comm:RegisterComm("ForeverAurasCh", HandleChannelComm)
Comm:RegisterComm("ForeverAurasChP", HandleChannelProgressComm)
Comm:RegisterComm("ForeverAurasProg", HandleProgressComm)
Comm:RegisterComm("ForeverAuras", HandleComm)
Chomp.RegisterAddonPrefix("ForeverAuras2", HandleComm)
