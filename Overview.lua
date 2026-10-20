local _, addon = ...
local UI = addon.Theme
local VISIBLE_ROWS, ROW_HEIGHT = 8, 40

local function Age(stamp, now)
    if type(stamp) ~= "number" then return "age unknown" end
    local seconds = math.max(0, math.floor(now - stamp))
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function Region(player)
    if not player.map then return nil end
    local zone = "Map " .. tostring(player.map)
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        local ok, info = pcall(C_Map.GetMapInfo, player.map)
        if ok and type(info) == "table" and type(info.name) == "string" then zone = info.name end
    end
    return zone
end

local function Location(player)
    if not player.region then return player.sharing == false and "Not sharing" or "No position" end
    return player.region
end

local function HideTooltip(button)
    if GameTooltip and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
end

local function KnownXP(player)
    return player.level and player.xpState == "known" and type(player.xp) == "number"
        and type(player.xpMax) == "number" and player.xpMax > 0
end

local function ProgressTooltip(cell)
    local player = cell.player
    if not player or not GameTooltip then return end
    GameTooltip_SetDefaultAnchor(GameTooltip, cell)
    GameTooltip:SetText(addon:GetPlayerDisplayName(player.name)
        .. (player.level and " — level " .. player.level or " — level unknown"))
    if KnownXP(player) then
        GameTooltip:AddLine("XP: " .. player.xp .. " / " .. player.xpMax)
        GameTooltip:AddLine("To next level: " .. math.max(0, player.xpMax - player.xp) .. " XP")
    elseif player.level and player.xpState == "max" then
        GameTooltip:AddLine("Maximum level")
    else
        GameTooltip:AddLine("Level progress unavailable")
    end
    GameTooltip:Show()
end

local function RefreshProgress(row, player)
    local cell = row.levelCell
    cell.player = player
    row.level:SetText(player.level and tostring(player.level) or "—")
    row.progress:SetText("")
    row.progress:SetAlpha(1)
    row.progressTrack:Hide()
    row.progressFill:Hide()
    if player.level then
        local stale = player.xpStale or player.online == false
        if KnownXP(player) then
            local fraction = math.max(0, math.min(1, player.xp / player.xpMax))
            row.progress:SetText(math.floor(fraction * 100) .. "%")
            row.progress:SetAlpha(stale and 0.55 or 1)
            local red, green, blue = UI:GetAccentColor()
            row.progressTrack:SetColorTexture(red * 0.25, green * 0.25, blue * 0.25, 0.8)
            row.progressFill:SetColorTexture(red, green, blue, stale and 0.35 or 1)
            row.progressTrack:Show()
            if fraction > 0 then
                row.progressFill:SetWidth(row.progressTrack:GetWidth() * fraction)
                row.progressFill:Show()
            end
        elseif player.xpState == "max" then
            row.progress:SetText("MAX")
            row.progress:SetAlpha(stale and 0.55 or 1)
        else
            row.progress:SetText("—")
        end
    end
    if GameTooltip and GameTooltip:IsOwned(cell) and GameTooltip:IsShown() then ProgressTooltip(cell) end
end

local function ActionButton(menu, onResult, label, action, y)
    local button = UI:Button(menu.menu, label)
    button:SetPoint("TOPLEFT", 8, -y)
    button:SetSize(154, 28)
    if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
    button:HookScript("OnEnter", function()
        if not GameTooltip then return end
        GameTooltip_SetDefaultAnchor(GameTooltip, button)
        GameTooltip:SetText(button.reason or label)
        GameTooltip:Show()
    end)
    button:HookScript("OnLeave", function() HideTooltip(button) end)
    button:SetScript("OnHide", function() HideTooltip(button) end)
    button:SetScript("OnClick", function()
        local playerID = menu.playerID
        menu:Hide()
        if not playerID then return end
        local success, message = addon:PerformOverviewAction(playerID, action)
        if onResult then onResult(success, message) end
        menu:Refresh()
    end)
    return button
end

local function RefreshActions(menu)
    local state = addon:GetOverviewActionState(menu.playerID)
    menu.invite.reason, menu.request.reason = state.inviteReason, state.requestReason
    menu.invite:SetEnabled(state.invite == true)
    menu.request:SetEnabled(state.request == true)
    for _, button in ipairs({ menu.invite, menu.request }) do
        if GameTooltip and GameTooltip:IsOwned(button) then
            GameTooltip:SetText(button.reason or button:GetText())
        end
    end
end

function addon:CreatePlayerActionMenu(parent, name, onResult, onScroll)
    local menu = CreateFrame("Button", name, parent)
    menu:SetAllPoints(UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    menu:EnableMouseWheel(true)
    menu.menu = UI:Section(menu, 0, 0, 170, 80, "")
    menu.menu:SetFrameLevel(menu:GetFrameLevel() + 1)
    menu.menu:SetClampedToScreen(true)
    menu.menu:EnableMouse(true)
    menu.invite = ActionButton(menu, onResult, "Invite", "invite", 8)
    menu.request = ActionButton(menu, onResult, "Request to join", "request", 44)
    menu:SetScript("OnClick", function() menu:Hide() end)
    menu:SetScript("OnMouseWheel", function(_, delta)
        menu:Hide()
        if onScroll then onScroll(delta) end
    end)
    menu:SetScript("OnHide", function()
        menu.playerID, menu.anchor = nil, nil
        if addon.activePlayerActionMenu == menu then addon.activePlayerActionMenu = nil end
        HideTooltip(menu.invite)
        HideTooltip(menu.request)
    end)
    parent:HookScript("OnHide", function() menu:Hide() end)
    function menu:Refresh()
        if self.playerID then RefreshActions(self) end
    end
    function menu:Open(playerID, anchor, anchorTarget)
        local wasOpen = self:IsShown() and self.playerID == playerID
        self:Hide()
        if wasOpen or not playerID or not anchor or addon:IsDataSelf(playerID) then return end
        -- Roster and ranking share native action guards, and only one menu may
        -- own the screen at a time even when both player lists are visible.
        if addon.activePlayerActionMenu then addon.activePlayerActionMenu:Hide() end
        self.playerID, self.anchor = playerID, anchor
        self.menu:ClearAllPoints()
        self.menu:SetPoint("TOPRIGHT", anchorTarget or anchor, "BOTTOMRIGHT", 0, -2)
        self:Refresh()
        self:Show()
        addon.activePlayerActionMenu = self
    end
    menu:Hide()
    tinsert(UISpecialFrames, name)
    return menu
end

local function SortPlayers(page, players)
    local key = page.sortKey
    if not key then return end
    local function Value(player)
        if key == "name" then return addon:GetPlayerDisplayName(player.name):lower() end
        if key == "region" then return player.region and player.region:lower() end
        if key == "seen" then return player.seenAt end
        return player.level
    end
    table.sort(players, function(left, right)
        local a, b = Value(left), Value(right)
        if a == nil or b == nil then
            if a ~= b then return a ~= nil end
        elseif a ~= b then
            if page.sortDescending then return a > b end
            return a < b
        end
        return left.id < right.id
    end)
end

function addon:CreateOverviewPage(panel)
    local page = UI:Section(panel, 20, 116, 680, 414, "")
    panel.pages.overview, panel.overviewPage = page, page
    panel.feedback = UI:Label(page, "", 13)
    panel.feedback:SetPoint("TOPLEFT", 16, -378)
    panel.feedback:SetSize(648, 26)
    page.offset, page.rows, page.headers = 0, {}, {}
    page.empty = UI:Label(page, "", 13, "muted")
    page.empty:SetPoint("TOPLEFT", 16, -56)
    page.empty:SetSize(626, 50)
    for _, column in ipairs({ { "Name", "name", 16, 124 }, { "Level", "level", 148, 80 },
        { "Region", "region", 236, 196 }, { "Last seen", "seen", 440, 88 } }) do
        local title, key = column[1], column[2]
        local header = UI:Button(page, title)
        header:SetPoint("TOPLEFT", column[3], -12)
        header:SetSize(column[4], 28)
        header:GetFontString():ClearAllPoints()
        header:GetFontString():SetPoint("LEFT", 4, 0)
        header:SetScript("OnClick", function()
            if page.sortKey == key then page.sortDescending = not page.sortDescending
            else page.sortKey, page.sortDescending = key, key == "seen" end
            page:SetOffset(0)
        end)
        header.title = title
        page.headers[key] = header
    end
    local actions = UI:Label(page, "Actions", 12, "muted")
    actions:SetPoint("TOPLEFT", 536, -20)
    actions:SetWidth(106)
    page.actionMenu = self:CreatePlayerActionMenu(page, "LockInToolsOverviewActions", function(success, message)
        panel.feedback:SetText(message or "")
        if success then panel.feedback:SetTextColor(0.4, 1, 0.4)
        else panel.feedback:SetTextColor(1, 0.35, 0.35) end
        addon:RefreshOverview()
    end, function(delta) page:SetOffset(page.offset - delta) end)
    for index = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, page)
        row:SetPoint("TOPLEFT", 16, -48 - (index - 1) * ROW_HEIGHT)
        row:SetSize(626, ROW_HEIGHT)
        row.name = UI:Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 0, -7)
        row.name:SetSize(124, 30)
        row.levelCell = CreateFrame("Frame", nil, row)
        row.levelCell:SetPoint("TOPLEFT", 132, -2)
        row.levelCell:SetSize(80, 36)
        row.levelCell:EnableMouse(true)
        row.levelCell:SetScript("OnEnter", ProgressTooltip)
        row.levelCell:SetScript("OnLeave", HideTooltip)
        row.levelCell:SetScript("OnHide", HideTooltip)
        row:SetScript("OnHide", function() HideTooltip(row.levelCell) end)
        row.level = UI:Label(row.levelCell, "", 12)
        row.level:SetPoint("TOPLEFT", 0, -5)
        row.level:SetWidth(24)
        row.progress = UI:Label(row.levelCell, "", 11)
        row.progressTrack = row.levelCell:CreateTexture(nil, "BACKGROUND")
        row.progressTrack:SetPoint("TOPLEFT", 0, -24)
        row.progressTrack:SetSize(36, 3)
        row.progress:SetPoint("LEFT", row.level, "RIGHT", 6, 0)
        row.progress:SetSize(38, 12)
        row.progress:SetJustifyH("RIGHT")
        row.progressFill = row.levelCell:CreateTexture(nil, "ARTWORK")
        row.progressFill:SetPoint("TOPLEFT", row.progressTrack, "TOPLEFT")
        row.progressFill:SetHeight(3)
        row.position = UI:Label(row, "", 11, "muted")
        row.position:SetPoint("TOPLEFT", 220, -3)
        row.position:SetSize(196, 36)
        row.seen = UI:Label(row, "", 11, "muted")
        row.seen:SetPoint("TOPLEFT", 424, -3)
        row.seen:SetSize(88, 36)
        row.actions = UI:Button(row, "Actions v")
        row.actions:SetPoint("TOPLEFT", 520, -5)
        row.actions:SetSize(106, 30)
        row.actions:SetScript("OnClick", function()
            if not row.playerID or addon:IsDataSelf(row.playerID) then return end
            page.actionMenu:Open(row.playerID, row, row.actions)
        end)
        page.rows[index] = row
    end
    local scrollbar = CreateFrame("Slider", nil, page)
    page.scrollbar = scrollbar
    scrollbar:SetPoint("TOPLEFT", 650, -48)
    scrollbar:SetSize(14, VISIBLE_ROWS * ROW_HEIGHT)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetValueStep(1)
    local track = scrollbar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(scrollbar)
    track:SetColorTexture(0.025, 0.035, 0.05, 1)
    scrollbar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    scrollbar:GetThumbTexture():SetSize(20, 28)
    scrollbar:SetScript("OnValueChanged", function(_, value)
        if not page.refreshing then page:SetOffset(value) end
    end)
    function page:SetOffset(value)
        self.actionMenu:Hide()
        for _, row in ipairs(self.rows) do HideTooltip(row.levelCell) end
        self.offset = math.max(0, math.min(math.floor(value + 0.5), self.maxOffset or 0))
        addon:RefreshOverview()
    end
    page:EnableMouseWheel(true)
    scrollbar:EnableMouseWheel(true)
    local function Scroll(_, delta) page:SetOffset(page.offset - delta) end
    page:SetScript("OnMouseWheel", Scroll)
    scrollbar:SetScript("OnMouseWheel", Scroll)
    function page:Activate()
        if self.active or not self:IsVisible() then return end
        self.active, self.elapsed = true, 0
        self:SetScript("OnUpdate", function(_, elapsed)
            self.elapsed = self.elapsed + elapsed
            if self.elapsed >= 1 then
                self.elapsed = self.elapsed % 1
                addon:RefreshOverview()
            end
        end)
        addon:RefreshOverview()
    end
    function page:Deactivate()
        self.active = false
        self:SetScript("OnUpdate", nil)
        self.actionMenu:Hide()
        for _, row in ipairs(self.rows) do HideTooltip(row.levelCell) end
    end
    page:SetScript("OnShow", function() page:Activate() end)
    page:SetScript("OnHide", function() page:Deactivate() end)
    return page
end

function addon:RefreshOverview()
    local panel = self.contentPanel
    local page = panel and panel.overviewPage
    if not page or not page:IsVisible() or panel.selectedTab ~= "overview" then return end
    local players, now = self:GetOverviewPlayers(), GetServerTime()
    for _, player in ipairs(players) do player.region = Region(player) end
    SortPlayers(page, players)
    page.maxOffset = math.max(0, #players - VISIBLE_ROWS)
    page.offset = math.max(0, math.min(page.offset, page.maxOffset))
    page.refreshing = true
    page.scrollbar:SetMinMaxValues(0, math.max(1, page.maxOffset))
    page.scrollbar:SetValue(page.offset)
    page.refreshing = false
    if page.maxOffset > 0 then page.scrollbar:Show() else page.scrollbar:Hide() end
    for key, header in pairs(page.headers) do
        header:SetText(header.title .. (key == page.sortKey and (page.sortDescending and " v" or " ^") or ""))
    end
    if self:IsGroupSwitching() then
        page.empty:SetText("Leaving previous group...")
    elseif not self:HasGroup() then
        page.empty:SetText("Choose a group key in Settings > Group to see your friends.")
    elseif #players == 0 then
        page.empty:SetText("Waiting for players on this realm and faction.")
    end
    if #players == 0 then page.empty:Show() else page.empty:Hide() end
    local menu = page.actionMenu
    for index, row in ipairs(page.rows) do
        local player = players[page.offset + index]
        if menu:IsShown() and row.playerID ~= (player and player.id) then menu:Hide() end
        if row.playerID ~= (player and player.id) then HideTooltip(row.levelCell) end
        row.playerID = player and player.id or nil
        if player then
            row.name:SetText(self:GetPlayerDisplayName(player.name))
            row.actions:SetEnabled(not player.isSelf)
            RefreshProgress(row, player)
            row.position:SetText(Location(player))
            row.seen:SetText(player.online and "Active" or Age(player.seenAt, now))
            row:Show()
        else
            row.actions:SetEnabled(false)
            row.levelCell.player = nil
            row.level:SetText("")
            row.progress:SetText("")
            row.progressTrack:Hide()
            row.progressFill:Hide()
            row:Hide()
        end
    end
    if menu:IsShown() then menu:Refresh() end
end

function addon:OpenOverview()
    self:OpenContent()
end

for _, notification in ipairs({ "GROUP_CHANGED", "POSITIONS_CHANGED", "POSITION_CONTACT_CHANGED", "ROSTER_CHANGED" }) do
    addon:RegisterNotification(notification, function() addon:RefreshOverview() end)
end
