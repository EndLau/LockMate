-------------------------------------------------------------------------------
--  LockMate  v1.1.0
--  Warlock Summon Queue Manager for WoW 3.3.5a
--
--  /lm              – toggle settings
--  /lm show         – pin queue window open even when empty
--  /lm hide         – hide queue window
--  /lm clear        – clear the queue
--  /lm shards       – run shard scan with full debug output
--  /lm help         – command list
-------------------------------------------------------------------------------

local ADDON_PREFIX = "LM10"
local SOUL_SHARD   = 6265
local SHARD_FAMILY = 8

LockMateDB = LockMateDB or {}

local DEFAULTS = {
    listenRaid        = true,
    listenParty       = true,
    listenWhisper     = true,
    summonMessage     = "Summoning %s. Click the portal!",
    msgChannelGroup   = true,
    msgChannelWhisper = false,
    maxShards         = 32,
    autoDeleteShards  = false,
    silentShardDelete = false,
    frameAlpha        = 85,
    locked            = false,
    frameX            = 0,
    frameY            = 0,
    frameW            = 230,
    frameH            = 300,
}

local queue       = {}
local inQueue     = {}
local summonDone  = {}
local initialized = false
local syncPending = false
local forceShow   = false

local MainFrame     = nil
local SettingsFrame = nil
local ScrollFrame   = nil
local ScrollChild   = nil
local Buttons       = {}

local function DB(key)
    local v = LockMateDB[key]
    return (v ~= nil) and v or DEFAULTS[key]
end
local function DBSet(key, val) LockMateDB[key] = val end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9966ffLockMate:|r " .. tostring(msg))
end

local function StripRealm(name)
    if not name then return "" end
    return name:match("^([^%-]+)") or name
end

local function FindUnit(name)
    if GetNumRaidMembers() > 0 then
        for i = 1, MAX_RAID_MEMBERS do
            local u = "raid"..i
            if UnitName(u) == name then return u end
        end
    else
        for i = 1, GetNumPartyMembers() do
            local u = "party"..i
            if UnitName(u) == name then return u end
        end
    end
    if UnitName("player") == name then return "player" end
end

local function IsNearby(name)
    local u = FindUnit(name); return u ~= nil and UnitIsVisible(u)
end
local function IsInCombat(name)
    local u = FindUnit(name); return u ~= nil and UnitAffectingCombat(u)
end

local function After(secs, fn)
    local f, e = CreateFrame("Frame"), 0
    f:SetScript("OnUpdate", function(self, dt)
        e = e + dt
        if e >= secs then self:SetScript("OnUpdate", nil); fn() end
    end)
end

local function Send(msg)
    if GetNumRaidMembers() > 0 then
        SendAddonMessage(ADDON_PREFIX, msg, "RAID")
    elseif GetNumPartyMembers() > 0 then
        SendAddonMessage(ADDON_PREFIX, msg, "PARTY")
    end
end

-- ── Soul shard deletion ───────────────────────────────────────
local shardBusy = false

local function IsSoulBag(bag)
    if bag == 0 then return false end
    local _, bagType = GetContainerNumFreeSlots(bag)
    if not bagType or bagType == 0 then return false end
    return (math.floor(bagType / SHARD_FAMILY) % 2) == 1
end

local function ItemIDFromLink(link)
    if not link then return nil end
    return tonumber(link:match("item:(%d+):"))
end

local function SlotHasShard(bag, slot)
    local id = GetContainerItemID(bag, slot)
    if id == SOUL_SHARD then return true end
    return ItemIDFromLink(GetContainerItemLink(bag, slot)) == SOUL_SHARD
end

local function PurgeShards(verbose)
    if not DB("autoDeleteShards") then
        if verbose then Print("Auto-delete is OFF in settings.") end
        return
    end
    if shardBusy then
        if verbose then Print("Shard purge already running.") end
        return
    end

    local outside, inside = {}, {}
    for bag = 0, 4 do
        local slots  = GetContainerNumSlots(bag) or 0
        local isSoul = IsSoulBag(bag)
        local found, shardCount = 0, 0
        for slot = 1, slots do
            if SlotHasShard(bag, slot) then
                local _, stackSize = GetContainerItemInfo(bag, slot)
                stackSize = tonumber(stackSize) or 1
                table.insert(isSoul and inside or outside,
                    {bag=bag, slot=slot, count=stackSize})
                found      = found + 1
                shardCount = shardCount + stackSize
            end
        end
        if verbose then
            Print(string.format("  Bag %d: %d slots | %d stack(s) | %d shard(s)",
                bag, slots, found, shardCount))
        end
    end

    local total = 0
    for _, v in ipairs(outside) do total = total + v.count end
    for _, v in ipairs(inside)  do total = total + v.count end

    local maxS   = DB("maxShards")
    local excess = total - maxS

    if verbose then
        Print(string.format("Total shards: %d  |  Max: %d  |  Excess: %d",
            total, maxS, math.max(0, excess)))
    end

    if excess <= 0 then
        if verbose then Print("Nothing to delete.") end
        return
    end

    local toDelete = {}
    for _, v in ipairs(outside) do table.insert(toDelete, v) end
    for _, v in ipairs(inside)  do table.insert(toDelete, v) end

    if not DB("silentShardDelete") then
        Print("|cffff9900Deleting "..excess.." Soul Shard(s)...|r")
    end
    shardBusy = true
    local remaining = excess

    local function step(i)
        if i > #toDelete or remaining <= 0 then shardBusy = false; return end
        local v = toDelete[i]
        if CursorHasItem() then ClearCursor() end
        local del = math.min(v.count, remaining)
        if del == v.count then
            PickupContainerItem(v.bag, v.slot)
        else
            SplitContainerItem(v.bag, v.slot, del)
        end
        DeleteCursorItem()
        remaining = remaining - del
        After(0.5, function() step(i + 1) end)
    end
    step(1)
end

-- ── Queue ─────────────────────────────────────────────────────
local RefreshUI

local function QueueAdd(name, broadcast)
    if name == UnitName("player") then return end   -- never queue yourself
    if inQueue[name] then return end
    inQueue[name] = true
    table.insert(queue, {name=name, summoned=false})
    if broadcast then Send("ADD:"..name) end
    if RefreshUI then RefreshUI() end
end
local function QueueRemove(name, broadcast)
    if not inQueue[name] then return end
    inQueue[name] = nil
    for i, v in ipairs(queue) do
        if v.name == name then table.remove(queue, i); break end
    end
    if broadcast then Send("REMOVE:"..name) end
    if RefreshUI then RefreshUI() end
end
local function QueueMarkDone(name)
    summonDone[name] = true
    for _, v in ipairs(queue) do
        if v.name == name then v.summoned = true; break end
    end
    Send("DONE:"..name)
    if RefreshUI then RefreshUI() end
end

local function DoAnnounce(name)
    local msg = string.format(DB("summonMessage"), name)
    if DB("msgChannelGroup") then
        if GetNumRaidMembers() > 0 then SendChatMessage(msg, "RAID")
        elseif GetNumPartyMembers() > 0 then SendChatMessage(msg, "PARTY")
        else SendChatMessage(msg, "SAY") end
    end
    if DB("msgChannelWhisper") then SendChatMessage(msg, "WHISPER", nil, name) end
    QueueMarkDone(name)
    After(3, function() QueueRemove(name, true) end)
end

-- ── Chat ──────────────────────────────────────────────────────
local function IsInMyGroup(name)
    if GetNumRaidMembers() > 0 then
        for i = 1, MAX_RAID_MEMBERS do
            local u = "raid"..i
            if UnitName(u) == name then return true end
        end
    elseif GetNumPartyMembers() > 0 then
        for i = 1, GetNumPartyMembers() do
            local u = "party"..i
            if UnitName(u) == name then return true end
        end
    end
    return false
end

local function OnChat(event, message, author)
    local name = StripRealm(author)
    if name == UnitName("player") then return end
    if not message:find("123") then return end
    -- Only queue players who are actually in your current group/raid
    if not IsInMyGroup(name) then return end
    if (event=="CHAT_MSG_RAID" or event=="CHAT_MSG_RAID_LEADER") and DB("listenRaid") then
        QueueAdd(name, true)
    elseif (event=="CHAT_MSG_PARTY" or event=="CHAT_MSG_PARTY_LEADER") and DB("listenParty") then
        QueueAdd(name, true)
    elseif event=="CHAT_MSG_WHISPER" and DB("listenWhisper") then
        QueueAdd(name, true)
    end
end

-- ── Addon messages ────────────────────────────────────────────
local function OnAddon(prefix, msg, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    if StripRealm(sender) == UnitName("player") then return end
    local cmd = msg:match("^([A-Z]+):")
    if not cmd then return end
    local data = msg:sub(#cmd+2)
    if cmd=="ADD" then QueueAdd(data, false)
    elseif cmd=="REMOVE" then QueueRemove(data, false)
    elseif cmd=="DONE" then
        summonDone[data]=true
        for _,v in ipairs(queue) do if v.name==data then v.summoned=true; break end end
        if RefreshUI then RefreshUI() end
    elseif cmd=="SYNC" then
        local parts={}
        for _,v in ipairs(queue) do
            table.insert(parts, v.name.."="..(v.summoned and "1" or "0"))
        end
        if #parts>0 then Send("FULL:"..table.concat(parts,",")) end
    elseif cmd=="FULL" then
        for entry in (data..","):gmatch("([^,]+),") do
            local n,s = entry:match("^(.+)=([01])$")
            if n then
                if not inQueue[n] then QueueAdd(n, false) end
                if s=="1" then
                    summonDone[n]=true
                    for _,v in ipairs(queue) do if v.name==n then v.summoned=true; break end end
                end
            end
        end
        if RefreshUI then RefreshUI() end
    end
end

-- ── Secure list buttons ───────────────────────────────────────
local scrollOffset = 0

local function GetOrCreateButton(i)
    if Buttons[i] then return Buttons[i] end
    local btn = CreateFrame("Button", nil, ScrollChild, "SecureActionButtonTemplate")
    btn:SetHeight(26)
    btn:RegisterForClicks("LeftButtonUp","RightButtonUp")
    btn:SetAttribute("type1","macro")
    btn:SetAttribute("macrotext1","")
    btn:SetAttribute("type2","")

    local bg = btn:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); btn.bg = bg
    local hl = btn:CreateTexture(nil,"HIGHLIGHT"); hl:SetAllPoints(); hl:SetTexture(1,1,1,0.07)
    local txt = btn:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    txt:SetPoint("LEFT",btn,"LEFT",6,0); txt:SetPoint("RIGHT",btn,"RIGHT",-6,0)
    txt:SetJustifyH("LEFT"); btn.txt = txt

    btn:SetScript("PreClick", function(self, button)
        if button ~= "LeftButton" then return end
        local e = queue[self.idx]
        if not e then self:SetAttribute("macrotext1",""); return end
        if IsInCombat(e.name) then
            SendChatMessage("Can't summon you while in combat!","WHISPER",nil,e.name)
            self:SetAttribute("macrotext1",""); return
        end
        if summonDone[e.name] and IsNearby(e.name) then
            Print(e.name.." is already summoned and nearby.")
            self:SetAttribute("macrotext1",""); return
        end
        self:SetAttribute("macrotext1","/target "..e.name.."\n/cast Ritual of Summoning")
        self._summonName = e.name
    end)

    btn:SetScript("PostClick", function(self, button)
        if button == "LeftButton" then
            local name = self._summonName; self._summonName = nil
            if name and self:GetAttribute("macrotext1") ~= "" then DoAnnounce(name) end
        elseif button == "RightButton" then
            local e = queue[self.idx]; if e then QueueRemove(e.name, true) end
        end
    end)

    btn:SetScript("OnEnter", function(self)
        local e = queue[self.idx]; if not e then return end
        GameTooltip:SetOwner(self,"ANCHOR_RIGHT"); GameTooltip:ClearLines()
        GameTooltip:AddLine(e.name,1,0.85,0)
        GameTooltip:AddLine("|cffffd700Left-click|r  — Summon",1,1,1)
        GameTooltip:AddLine("|cffffd700Right-click|r — Remove from queue",1,1,1)
        if e.summoned then GameTooltip:AddLine("|cff55ff55Already summoned|r",1,1,1) end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btn:Hide()
    Buttons[i] = btn
    return btn
end

-- ── RefreshUI ─────────────────────────────────────────────────
RefreshUI = function()
    if not MainFrame then return end
    if #queue == 0 then
        if forceShow then MainFrame:Show() else MainFrame:Hide() end
        for i=1,#Buttons do Buttons[i]:Hide() end
        return
    end
    MainFrame:Show()
    local w = math.max(ScrollFrame:GetWidth()-2, 60)
    ScrollChild:SetWidth(w); ScrollChild:SetHeight(math.max(#queue*26,1))
    local maxOff = math.max(0, ScrollChild:GetHeight()-ScrollFrame:GetHeight())
    if scrollOffset > maxOff then scrollOffset = maxOff end
    ScrollFrame:SetVerticalScroll(scrollOffset)
    for i, entry in ipairs(queue) do
        local btn = GetOrCreateButton(i)
        btn.idx = i; btn:ClearAllPoints(); btn:SetWidth(w)
        btn:SetPoint("TOPLEFT",ScrollChild,"TOPLEFT",0,-(i-1)*26)
        if entry.summoned then
            btn.bg:SetTexture(0.08,0.40,0.08,0.70)
            btn.txt:SetText("|cff55ff55"..entry.name.."  [Summoned]|r")
        else
            btn.bg:SetTexture(0.05,0.05,0.22,0.70)
            btn.txt:SetText("|cffccccff"..entry.name.."|r")
        end
        btn:Show()
    end
    for i=#queue+1,#Buttons do Buttons[i]:Hide() end
end

-- ── Build main (queue) frame ──────────────────────────────────
local function BuildMainFrame()
    local f = CreateFrame("Frame", nil, UIParent)
    MainFrame = f
    f:SetWidth(DB("frameW")); f:SetHeight(DB("frameH"))
    f:SetPoint("CENTER", UIParent, "CENTER", DB("frameX"), DB("frameY"))
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)

    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true,tileSize=16,edgeSize=14,
        insets={left=3,right=3,top=3,bottom=3},
    })
    f:SetBackdropColor(0.04,0.04,0.16, DB("frameAlpha")/100)
    f:SetBackdropBorderColor(0.55,0.30,0.85,0.90)

    local title = f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    title:SetPoint("TOPLEFT",f,"TOPLEFT",8,-7)
    title:SetText("|cff9966ffLockMate|r  Queue")

    -- Settings button: SetNormalTexture is safe; GetNormalTexture returns nil
    local gearBtn = CreateFrame("Button",nil,f)
    gearBtn:SetSize(22,22)
    gearBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-4,-3)
    gearBtn:EnableMouse(true)
    -- Colored background so button is visible even if texture path fails
    local gearBg = gearBtn:CreateTexture(nil,"BACKGROUND")
    gearBg:SetTexture(0.35,0.18,0.55,0.85)
    gearBg:SetAllPoints(gearBtn)
    gearBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    gearBtn:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
    gearBtn:SetScript("OnClick", function()
        if not SettingsFrame then return end
        if SettingsFrame:IsShown() then SettingsFrame:Hide() else SettingsFrame:Show() end
    end)
    gearBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("LockMate Settings  (/lm)"); GameTooltip:Show()
    end)
    gearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local sep = f:CreateTexture(nil,"ARTWORK"); sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",f,"TOPLEFT",4,-26)
    sep:SetPoint("TOPRIGHT",f,"TOPRIGHT",-4,-26)
    sep:SetTexture(0.55,0.30,0.85,0.55)

    -- Scroll frame (no scrollbar, mousewheel only)
    local sf = CreateFrame("ScrollFrame",nil,f)
    sf:SetPoint("TOPLEFT",f,"TOPLEFT",4,-29)
    sf:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-4,22)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        scrollOffset = scrollOffset - delta*26
        local h = ScrollChild and ScrollChild:GetHeight() or 0
        local maxOff = math.max(0, h-self:GetHeight())
        scrollOffset = math.max(0, math.min(maxOff, scrollOffset))
        self:SetVerticalScroll(scrollOffset)
    end)
    ScrollFrame = sf
    local sc = CreateFrame("Frame",nil,sf)
    sc:SetWidth(sf:GetWidth()); sc:SetHeight(1)
    sf:SetScrollChild(sc); ScrollChild = sc

    -- ── Drag ─────────────────────────────────────────────────────
    -- titleBar backup removed — it blocked the gear button.
    -- Direct RegisterForDrag on f is confirmed working.
    local function saveDragPos()
        local _,_,_,x,y = f:GetPoint(1)
        DBSet("frameX", math.floor(x or 0))
        DBSet("frameY", math.floor(y or 0))
    end

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if not DB("locked") then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveDragPos()
    end)

    -- ── Resize grip ───────────────────────────────────────────
    -- On mouse-down we switch the anchor to TOPLEFT so the
    -- top-left corner stays pinned while only the right/bottom
    -- edges extend as the cursor moves.
    -- On mouse-up we convert back to CENTER for consistency with
    -- how the drag position is saved.
    local resize = {on=false, cx=0, cy=0, w=0, h=0}

    local resizeUpdater = CreateFrame("Frame")
    resizeUpdater:SetScript("OnUpdate", function()
        if not resize.on then return end
        if DB("locked") then resize.on=false; return end
        local cx,cy = GetCursorPosition()
        local sc2   = UIParent:GetEffectiveScale()
        f:SetWidth( math.max(160, resize.w + (cx - resize.cx) / sc2))
        f:SetHeight(math.max( 80, resize.h - (cy - resize.cy) / sc2))
        sc:SetWidth(math.max(sf:GetWidth(), 60))
    end)

    local grip = CreateFrame("Frame",nil,f)
    grip:SetSize(16,16)
    grip:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-1,1)
    grip:SetFrameLevel(f:GetFrameLevel()+10)
    grip:EnableMouse(true)
    local gN=grip:CreateTexture(nil,"OVERLAY")
    gN:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up"); gN:SetAllPoints()
    local gH=grip:CreateTexture(nil,"HIGHLIGHT")
    gH:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlighted"); gH:SetAllPoints()

    grip:SetScript("OnMouseDown", function(self, btn)
        if btn~="LeftButton" or DB("locked") then return end
        -- Pin top-left corner before resize so only right/bottom move
        local tlx = f:GetLeft() or 0
        local tly = f:GetTop()  or 0
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", tlx, tly)
        resize.on = true
        resize.cx, resize.cy = GetCursorPosition()
        resize.w = f:GetWidth()
        resize.h = f:GetHeight()
    end)

    grip:SetScript("OnMouseUp", function(self, btn)
        if btn=="LeftButton" and resize.on then
            resize.on = false
            local newW = f:GetWidth()
            local newH = f:GetHeight()
            -- Convert TOPLEFT anchor back to CENTER offset
            local tlx = f:GetLeft() or 0
            local tly = f:GetTop()  or 0
            local uiW = UIParent:GetWidth()
            local uiH = UIParent:GetHeight()
            local cx  = (tlx + newW / 2) - uiW / 2
            local cy  = (tly - newH / 2) - uiH / 2
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
            DBSet("frameW", math.floor(newW))
            DBSet("frameH", math.floor(newH))
            DBSet("frameX", math.floor(cx))
            DBSet("frameY", math.floor(cy))
            sc:SetWidth(math.max(sf:GetWidth(), 60))
            RefreshUI()
        end
    end)

    f:Hide()
end

-- ── Build settings frame ──────────────────────────────────────
local function BuildSettingsFrame()
    local f = CreateFrame("Frame",nil,UIParent)
    SettingsFrame = f
    f:SetSize(400,595)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)

    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true,tileSize=16,edgeSize=14,
        insets={left=3,right=3,top=3,bottom=3},
    })
    f:SetBackdropColor(0.04,0.04,0.16,0.96)
    f:SetBackdropBorderColor(0.55,0.30,0.85,0.90)

    -- Drag using RegisterForDrag+StartMoving — proven to work on this build
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)

    local titleFS = f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    titleFS:SetPoint("TOP",f,"TOP",0,-11)
    titleFS:SetText("|cff9966ffLockMate|r  Settings")

    -- ── Pending-settings system ───────────────────────────────
    -- All controls write to `pending` instead of DB.
    -- OnShow resets pending from the live DB so re-opening always
    -- shows current saved values.  Save commits pending to DB.
    local pending   = {}
    local refreshFn = {}  -- called on OnShow to reset widget displays

    f:SetScript("OnShow", function()
        for k in pairs(DEFAULTS) do pending[k] = DB(k) end
        for _, fn in ipairs(refreshFn) do fn() end
    end)

    -- Checkbox that writes to pending
    local function PCB(parent, label, key, x, y, onPreview)
        local cb = CreateFrame("CheckButton",nil,parent,"UICheckButtonTemplate")
        cb:SetSize(24,24)
        cb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
        cb:SetChecked(DB(key) and true or false)
        cb:SetScript("OnClick", function(self)
            local v = self:GetChecked() and true or false
            pending[key] = v
            if onPreview then onPreview(v) end
        end)
        table.insert(refreshFn, function()
            cb:SetChecked(pending[key] and true or false)
        end)
        local lbl = cb:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        lbl:SetPoint("LEFT",cb,"RIGHT",2,0); lbl:SetText(label)
        return cb
    end

    -- Slider that writes to pending (no immediate DB write or side effects)
    local function PSlider(parent, key, minV, maxV, x, y, fmtFn, onPreview)
        local lbl = parent:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y); lbl:SetText(fmtFn(DB(key)))
        local loL = parent:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        loL:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y-34); loL:SetText(tostring(minV))
        local hiL = parent:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        hiL:SetPoint("TOPLEFT",parent,"TOPLEFT",x+200,y-34); hiL:SetText(tostring(maxV))
        local sl = CreateFrame("Slider",nil,parent)
        sl:SetWidth(220); sl:SetHeight(16)
        sl:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y-16)
        sl:SetOrientation("HORIZONTAL")
        sl:SetMinMaxValues(minV,maxV); sl:SetValueStep(1)
        local track = sl:CreateTexture(nil,"BACKGROUND")
        track:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
        track:SetAllPoints(sl); track:SetTexCoord(0,1,0.25,0.75)
        sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        sl:SetValue(DB(key))
        sl:SetScript("OnValueChanged", function(self, val)
            local v = math.floor(val+0.5)
            pending[key] = v
            lbl:SetText(fmtFn(v))
            if onPreview then onPreview(v) end
        end)
        table.insert(refreshFn, function()
            sl:SetValue(pending[key] or DB(key))
        end)
        return sl, lbl
    end

    -- EditBox that writes to pending
    local function PEditBox(parent, key, x, y, w, h)
        local eb = CreateFrame("EditBox",nil,parent)
        eb:SetSize(w,h)
        eb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
        eb:SetFontObject(ChatFontNormal)
        eb:SetTextInsets(4,4,2,2)
        eb:SetAutoFocus(false)
        local ebBg = eb:CreateTexture(nil,"BACKGROUND")
        ebBg:SetTexture(0,0,0,0.5); ebBg:SetAllPoints(eb)
        eb:SetText(DB(key))
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEnterPressed",  function(self)
            pending[key] = self:GetText(); self:ClearFocus()
        end)
        eb:SetScript("OnEditFocusLost", function(self)
            pending[key] = self:GetText()
        end)
        table.insert(refreshFn, function()
            eb:SetText(pending[key] or DB(key))
        end)
        return eb
    end

    -- Separator helper
    local function Sep(yy)
        local s = f:CreateTexture(nil,"ARTWORK"); s:SetHeight(1)
        s:SetPoint("TOPLEFT",f,"TOPLEFT",10,yy)
        s:SetPoint("TOPRIGHT",f,"TOPRIGHT",-10,yy)
        s:SetTexture(0.3,0.3,0.3,0.5)
    end

    -- Close button (top-right X) – reverts previews, does NOT save
    local cBtn = CreateFrame("Button",nil,f,"UIPanelCloseButton")
    cBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-2,-2)
    cBtn:SetScript("OnClick", function()
        -- Revert any live visual previews
        if MainFrame then MainFrame:SetBackdropColor(0.04,0.04,0.16,DB("frameAlpha")/100) end
        f:Hide()
    end)

    local X,Y = 14,-40

    -- ── Listen channels ──
    f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"):SetPoint("TOPLEFT",f,"TOPLEFT",X,Y)
    do local fs=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
       fs:SetPoint("TOPLEFT",f,"TOPLEFT",X,Y); fs:SetText("|cffffff00Listen for '123' in:|r") end
    Y=Y-22
    PCB(f,"/Raid chat","listenRaid",X,Y)
    PCB(f,"/Party chat","listenParty",X+140,Y); Y=Y-28
    PCB(f,"/Whispers (to you)","listenWhisper",X,Y); Y=Y-32
    Sep(Y); Y=Y-10

    -- ── Summon message ──
    do local fs=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
       fs:SetPoint("TOPLEFT",f,"TOPLEFT",X,Y)
       fs:SetText("|cffffff00Summon Announcement|r  |cffaaaaaa(%s = player name)|r") end
    Y=Y-20
    PEditBox(f,"summonMessage",X+6,Y,362,22); Y=Y-32
    Sep(Y); Y=Y-10

    -- ── Announcement channel ──
    do local fs=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
       fs:SetPoint("TOPLEFT",f,"TOPLEFT",X,Y)
       fs:SetText("|cffffff00Send announcement via:|r") end
    Y=Y-22
    PCB(f,"/Say (or /Raid / /Party when grouped)","msgChannelGroup",X,Y); Y=Y-28
    PCB(f,"/Whisper to the player being summoned","msgChannelWhisper",X,Y); Y=Y-32
    Sep(Y); Y=Y-10

    -- ── Soul shards ──
    do local fs=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
       fs:SetPoint("TOPLEFT",f,"TOPLEFT",X,Y)
       fs:SetText("|cffffff00Soul Shard Management:|r") end
    Y=Y-22
    PCB(f,"Auto-delete Soul Shards above the limit","autoDeleteShards",X,Y); Y=Y-28
    PCB(f,"Silent deletion (no chat announcement)","silentShardDelete",X+16,Y); Y=Y-36
    -- Shard slider: only previews count label, no deletion until Save
    PSlider(f,"maxShards",0,84,X,Y,
        function(v) return "Max Soul Shards: "..v end,
        nil)  -- no onPreview — deletion happens only on Save
    Y=Y-56
    Sep(Y); Y=Y-10

    -- ── Window settings ──
    do local fs=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
       fs:SetPoint("TOPLEFT",f,"TOPLEFT",X,Y)
       fs:SetText("|cffffff00Window Settings:|r") end
    Y=Y-22
    PCB(f,"Lock window (prevent moving/resizing)","locked",X,Y); Y=Y-36
    -- Opacity slider: preview the backdrop color live, but DB only on Save
    PSlider(f,"frameAlpha",0,100,X,Y,
        function(v) return string.format("Background opacity: %d%%",v) end,
        function(v)
            if MainFrame then MainFrame:SetBackdropColor(0.04,0.04,0.16,v/100) end
        end)
    Y=Y-56
    Sep(Y); Y=Y-12

    -- ── Save / Cancel buttons ──────────────────────────────────
    local saveBtn = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    saveBtn:SetSize(90,24)
    saveBtn:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-12,12)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", function()
        -- Commit all pending values to DB
        for k,v in pairs(pending) do LockMateDB[k] = v end
        -- Apply side effects
        if MainFrame then
            MainFrame:SetBackdropColor(0.04,0.04,0.16, DB("frameAlpha")/100)
        end
        PurgeShards(false)   -- now that maxShards is saved, run the purge
        f:Hide()
        Print("Settings saved.")
    end)

    local cancelBtn = CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    cancelBtn:SetSize(90,24)
    cancelBtn:SetPoint("RIGHT",saveBtn,"LEFT",-6,0)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        -- Revert any live visual previews
        if MainFrame then MainFrame:SetBackdropColor(0.04,0.04,0.16,DB("frameAlpha")/100) end
        f:Hide()
    end)

    f:Hide()
end

-- ── Init ──────────────────────────────────────────────────────
local builtOnEnter = false

local function DoBuild()
    BuildMainFrame()
    BuildSettingsFrame()
    if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(ADDON_PREFIX) end
    initialized = true
    After(3, function() PurgeShards(false) end)
    Print("Ready! Players type |cffffd700123|r in raid/party/whisper to join the summon queue.")
end

-- ── Events ────────────────────────────────────────────────────
local EF = CreateFrame("Frame")
EF:RegisterEvent("PLAYER_ENTERING_WORLD")
EF:RegisterEvent("CHAT_MSG_PARTY")
EF:RegisterEvent("CHAT_MSG_PARTY_LEADER")
EF:RegisterEvent("CHAT_MSG_RAID")
EF:RegisterEvent("CHAT_MSG_RAID_LEADER")
EF:RegisterEvent("CHAT_MSG_WHISPER")
EF:RegisterEvent("CHAT_MSG_ADDON")
EF:RegisterEvent("BAG_UPDATE")
EF:RegisterEvent("PARTY_MEMBERS_CHANGED")
EF:RegisterEvent("RAID_ROSTER_UPDATE")

EF:SetScript("OnEvent", function(self, event, ...)
    if event=="PLAYER_ENTERING_WORLD" then
        if not builtOnEnter then
            builtOnEnter=true
            if type(LockMateDB)~="table" then LockMateDB={} end
            for k,v in pairs(DEFAULTS) do if LockMateDB[k]==nil then LockMateDB[k]=v end end
            DoBuild()
        end
        return
    end
    if not initialized then return end
    if event=="CHAT_MSG_PARTY" or event=="CHAT_MSG_PARTY_LEADER"
    or event=="CHAT_MSG_RAID" or event=="CHAT_MSG_RAID_LEADER"
    or event=="CHAT_MSG_WHISPER" then
        local msg,author=...; OnChat(event,msg,author)
    elseif event=="CHAT_MSG_ADDON" then
        local prefix,msg,channel,sender=...; OnAddon(prefix,msg,channel,sender)
    elseif event=="BAG_UPDATE" then
        PurgeShards(false)
    elseif event=="PARTY_MEMBERS_CHANGED" or event=="RAID_ROSTER_UPDATE" then
        -- Remove anyone from the queue who is no longer in the group
        local toRemove = {}
        for _, v in ipairs(queue) do
            if not IsInMyGroup(v.name) then
                table.insert(toRemove, v.name)
            end
        end
        for _, name in ipairs(toRemove) do
            QueueRemove(name, false)  -- local only; they already left
        end
        -- If we're no longer in any group at all, wipe everything
        if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then
            queue, inQueue, summonDone = {}, {}, {}
            RefreshUI()
        end
        if not syncPending then
            syncPending = true
            After(2, function() syncPending=false; Send("SYNC:") end)
        end
    end
end)

-- ── Slash commands ────────────────────────────────────────────
SLASH_LOCKMATE1="/lockmate"
SLASH_LOCKMATE2="/lm"
SlashCmdList["LOCKMATE"] = function(msg)
    if not initialized or not SettingsFrame then Print("Not ready yet."); return end
    msg = strtrim(strlower(msg or ""))
    if msg=="" or msg=="config" or msg=="settings" or msg=="options" then
        if SettingsFrame:IsShown() then SettingsFrame:Hide() else SettingsFrame:Show() end
    elseif msg=="show" then
        forceShow=true; if MainFrame then MainFrame:Show() end
        Print("Queue window pinned. |cffffd700/lm hide|r to unpin.")
    elseif msg=="hide" then
        forceShow=false; if MainFrame then MainFrame:Hide() end
        Print("Queue window hidden.")
    elseif msg=="clear" then
        queue,inQueue={},{}; RefreshUI(); Print("Queue cleared.")
    elseif msg=="shards" then
        PurgeShards(true)
    elseif msg=="help" then
        Print("/lm          — toggle settings")
        Print("/lm show     — pin queue window visible")
        Print("/lm hide     — hide queue window")
        Print("/lm clear    — clear summon queue")
        Print("/lm help     — this help")
    else
        Print("Unknown command. |cffffd700/lm help|r for options.")
    end
end
