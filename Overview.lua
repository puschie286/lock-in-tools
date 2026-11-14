local _, addon = ...
local UI = addon.Theme
local VISIBLE_ROWS, ROW_HEIGHT = 8, 40
local SHOWN_COLUMN_X, SHOWN_COLUMN_WIDTH = 562, 80
local PARTY_ACTION_LABELS = { invite = "Invite", suggest = "Suggest Invite", request = "Request to join" }

local function Age(stamp, now)
    if type(stamp) ~= "number" then return "age unknown" end
    local seconds = math.max(0, math.floor(now - stamp))
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function HideTooltip(button)
    if GameTooltip and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
end

local function OverviewName(player)
    return player.displayName or addon:GetPlayerDisplayName(player.name)
end

local function KnownXP(player)
    return player.level and player.xpState == "known" and type(player.xp) == "number"
        and type(player.xpMax) == "number" and player.xpMax > 0
end

local function ProgressTooltip(cell)
    local player = cell.player
    if not player or not GameTooltip then return end
    GameTooltip_SetDefaultAnchor(GameTooltip, cell)
    GameTooltip:SetText(OverviewName(player)
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

local function RefreshActions(menu, playerID)
    local state = addon:GetOverviewActionState(playerID)
    local action = state.invite and "invite" or state.suggest and "suggest" or state.request and "request" or nil
    local partyText = action and PARTY_ACTION_LABELS[action] or state.partyInfo
    if not partyText then return false end
    menu.party.action = action
    menu.party:SetText(partyText)
    menu.party:SetEnabled(action ~= nil)
    return true
end

function addon:CreatePlayerActionMenu(parent, name, onResult, onScroll)
    local menu = CreateFrame("Button", name, parent)
    menu:SetAllPoints(UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    -- Buttons default to left clicks; either button should dismiss the backdrop.
    menu:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    menu:EnableMouseWheel(true)
    menu.menu = UI:Section(menu, 0, 0, 170, 44, "")
    menu.menu:SetFrameLevel(menu:GetFrameLevel() + 1)
    menu.menu:SetClampedToScreen(true)
    menu.menu:EnableMouse(true)
    menu.party = UI:Button(menu.menu, "")
    menu.party:SetPoint("TOPLEFT", 8, -8)
    menu.party:SetSize(154, 28)
    menu.party:SetScript("OnClick", function(button, mouseButton)
        if mouseButton ~= "LeftButton" then return end
        local playerID, action = menu.playerID, button.action
        menu:Hide()
        if not playerID or not action then return end
        local success, message = addon:PerformOverviewAction(playerID, action)
        if onResult then onResult(success, message) end
    end)
    menu:SetScript("OnClick", function() menu:Hide() end)
    menu:SetScript("OnMouseWheel", function(_, delta)
        menu:Hide()
        if onScroll then onScroll(delta) end
    end)
    menu:SetScript("OnHide", function()
        menu.playerID, menu.anchor = nil, nil
        if addon.activePlayerActionMenu == menu then addon.activePlayerActionMenu = nil end
    end)
    parent:HookScript("OnHide", function() menu:Hide() end)
    function menu:Refresh()
        if self.playerID and not RefreshActions(self, self.playerID) then self:Hide() end
    end
    function menu:Open(playerID, anchor)
        self:Hide()
        if not playerID or not anchor or addon:IsDataSelf(playerID) then return end
        if not RefreshActions(self, playerID) then return end
        -- Roster and ranking share native action guards, and only one menu may
        -- own the screen at a time even when both player lists are visible.
        if addon.activePlayerActionMenu then addon.activePlayerActionMenu:Hide() end
        self.playerID, self.anchor = playerID, anchor
        local x, y = GetCursorPosition()
        -- Cursor pixels must be converted to the menu's inherited UI scale.
        local scale = self.menu:GetEffectiveScale()
        self.menu:ClearAllPoints()
        self.menu:SetPoint("TOPLEFT", self, "BOTTOMLEFT", x / scale, y / scale)
        self:Show()
        addon.activePlayerActionMenu = self
    end
    menu:Hide()
    tinsert(UISpecialFrames, name)
    return menu
end

addon:RegisterGameEvents({ "GLOBAL_MOUSE_UP" }, function(self, _, button)
    local menu = self.activePlayerActionMenu
    -- Global input also reaches disabled entries, whose click scripts do not run.
    if button == "RightButton" and menu and menu.menu:IsMouseOver() then
        menu:Open(menu.playerID, menu.anchor)
    end
end)

local function SortPlayers(page, players, displayName)
    local key = page.sortKey
    if not key then return end
    local function Value(player)
        if key == "name" then return displayName(player):lower() end
        if key == "seen" then return player.seenAt end
        if key == "zone" then return player.zone and player.zone:lower() end
        if key == "status" then
            if player.online ~= nil then return player.online and 1 or 0 end
            return nil
        end
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

local function CreatePlayerTable(panel, columns, refresh)
    local page = UI:Section(panel, 20, 116, 680, 414, "")
    page.feedback = UI:Label(page, "", 13)
    page.feedback:SetPoint("TOPLEFT", 16, -378)
    page.feedback:SetSize(648, 26)
    page.offset, page.rows, page.headers = 0, {}, {}
    page.empty = UI:Label(page, "", 13, "muted")
    page.empty:SetPoint("TOPLEFT", 16, -56)
    page.empty:SetSize(626, 50)
    for _, column in ipairs(columns) do
        local title, key = column[1], column[2]
        local header = UI:Button(page, title)
        header:SetPoint("TOPLEFT", column[3], -12)
        header:SetSize(column[4], 28)
        header:GetFontString():ClearAllPoints()
        header:GetFontString():SetPoint("LEFT", 4, 0)
        header:SetScript("OnClick", function()
            if page.sortKey == key then page.sortDescending = not page.sortDescending
            else page.sortKey, page.sortDescending = key, key == "seen" or key == "status" end
            page:SetOffset(0)
        end)
        header.title = title
        page.headers[key] = header
    end
    local shownHeader = UI:Label(page, "Shown", 13, "heading")
    shownHeader:SetPoint("TOPLEFT", SHOWN_COLUMN_X, -12)
    shownHeader:SetSize(SHOWN_COLUMN_WIDTH, 28)
    shownHeader:SetJustifyH("CENTER")
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
        if self.ClearInteractions then self:ClearInteractions() end
        self.offset = math.max(0, math.min(math.floor(value + 0.5), self.maxOffset or 0))
        refresh(addon)
    end
    page:EnableMouseWheel(true)
    scrollbar:EnableMouseWheel(true)
    local function Scroll(_, delta) page:SetOffset(page.offset - delta) end
    page:SetScript("OnMouseWheel", Scroll)
    scrollbar:SetScript("OnMouseWheel", Scroll)
    return page
end

local function CreateShownCheckbox(page, row)
    local ranking = UI:Checkbox(row)
    row.ranking = ranking
    ranking:SetPoint("LEFT", SHOWN_COLUMN_X - 16 + (SHOWN_COLUMN_WIDTH - 28) / 2, 0)
    ranking:SetSize(28, 28)
    ranking:SetScript("OnClick", function(button)
        local id = row.playerID
        if not id or not row:IsVisible() or row.rankingAvailable == false then return end
        local success, message = addon:SetRankingPlayerShown(id, button:GetChecked() and true or false)
        if not success then button:SetChecked(addon:IsRankingPlayerShown(id, row.defaultShown)) end
        page.feedback:SetText(success and "" or (message or "Unable to change ranking visibility."))
        if not success then page.feedback:SetTextColor(1, 0.35, 0.35) end
    end)
    ranking:SetScript("OnEnter", function(button)
        if not row.playerID or not GameTooltip then return end
        GameTooltip_SetDefaultAnchor(GameTooltip, button)
        GameTooltip:SetText("Show in ranking overlay")
        GameTooltip:AddLine("Include this character when ranking data is available.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ranking:SetScript("OnLeave", HideTooltip)
    ranking:SetScript("OnHide", HideTooltip)
    return ranking
end

local function RefreshShown(row, defaultShown, available)
    row.defaultShown, row.rankingAvailable = defaultShown, available
    row.ranking:SetChecked(available and addon:IsRankingPlayerShown(row.playerID, defaultShown))
    row.ranking:SetEnabled(available and not addon.savedDataReadOnly)
end

function addon:CreateOverviewPage(panel, tab, menuName)
    local page = CreatePlayerTable(panel, { { "Name", "name", 16, 310 }, { "Level", "level", 334, 124 },
        { "Last seen", "seen", 466, 88 } }, function(self)
        self:RefreshOverview()
    end)
    panel.pages[tab] = page
    page.actionMenu = self:CreatePlayerActionMenu(page, menuName, function(success, message)
        page.feedback:SetText(message or "")
        if success then page.feedback:SetTextColor(0.4, 1, 0.4)
        else page.feedback:SetTextColor(1, 0.35, 0.35) end
        addon:RefreshOverview()
    end, function(delta) page:SetOffset(page.offset - delta) end)
    for index = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, page)
        row:SetPoint("TOPLEFT", 16, -48 - (index - 1) * ROW_HEIGHT)
        row:SetSize(626, ROW_HEIGHT)
        row:EnableMouse(true)
        row:RegisterForClicks("RightButtonUp")
        local function OpenActions(_, button)
            if button ~= "RightButton" then return end
            HideTooltip(row.levelCell)
            HideTooltip(row.ranking)
            page.actionMenu:Open(row.playerID, row)
        end
        row:SetScript("OnClick", OpenActions)
        CreateShownCheckbox(page, row):SetScript("OnMouseUp", OpenActions)
        row.name = UI:Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 0, -7)
        row.name:SetSize(310, 30)
        row.levelCell = CreateFrame("Frame", nil, row)
        row.levelCell:SetPoint("TOPLEFT", 318, -2)
        row.levelCell:SetSize(124, 36)
        row.levelCell:EnableMouse(true)
        row.levelCell:SetScript("OnEnter", ProgressTooltip)
        row.levelCell:SetScript("OnLeave", HideTooltip)
        row.levelCell:SetScript("OnHide", HideTooltip)
        -- The XP tooltip's mouse-enabled cell captures clicks before the row.
        row.levelCell:SetScript("OnMouseUp", OpenActions)
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
        row.seen = UI:Label(row, "", 11, "muted")
        row.seen:SetPoint("TOPLEFT", 450, -3)
        row.seen:SetSize(88, 36)
        page.rows[index] = row
    end
    function page:ClearInteractions()
        self.actionMenu:Hide()
        for _, row in ipairs(self.rows) do
            HideTooltip(row.levelCell)
            HideTooltip(row.ranking)
        end
    end
    function page:Activate()
        if self.active or not self:IsVisible() then return end
        self.active, self.elapsed = true, 0
        addon:RequestGuildRoster()
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
        self:ClearInteractions()
    end
    page:SetScript("OnShow", function() page:Activate() end)
    page:SetScript("OnHide", function() page:Deactivate() end)
    return page
end

local function RefreshPlayerTable(page, players, displayName)
    SortPlayers(page, players, displayName)
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
    if #players == 0 then page.empty:Show() else page.empty:Hide() end
end

function addon:GetContentRankingPlayers(guildOnly)
    local hasGuild = self:HasGuild()
    if guildOnly and not hasGuild then return {} end
    local guild, friends = self:GetGuildPlayers(), self:GetFriendsPlayers()
    if not hasGuild and #friends == 0 then return {} end
    local own, shared, friendByKey = nil, {}, {}
    for _, player in ipairs(self:GetOverviewPlayers(true)) do
        if player.isSelf then own = player
        else shared[self:GetRankingPlayerKey(player.id)] = player end
    end
    for _, friend in ipairs(friends) do
        friendByKey[friend.id] = friend
        if friend.aliasID then friendByKey[self:GetRankingPlayerKey(friend.aliasID)] = friend end
    end

    local players, added = {}, {}
    if own then
        players[1] = own
        added[self:GetRankingPlayerKey(own.id)] = true
    end
    local function Add(native, friend)
        local nativeKey = self:GetRankingPlayerKey(native.id)
        local key = friend and friend.id or nativeKey
        if native.isSelf or added[key] then return end
        added[key] = true
        -- Keep the reporting identity for party actions and use native rows
        -- as the source of membership, including after a guild or friend removal.
        local player = shared[nativeKey] or shared[key]
            or (friend and shared[self:GetRankingPlayerKey(friend.aliasID)])
        if player then
            player.displayName = (friend and friend.displayName) or player.displayName or native.displayName
            player.level = player.level or native.level or (friend and friend.level)
        else
            player = { id = friend and friend.id or native.id, name = native.name,
                displayName = (friend and friend.displayName) or native.displayName,
                level = native.level, seenAt = native.seenAt, online = native.online, xpState = "unavailable",
                nativeOnly = true, rankingAvailable = friend ~= nil }
        end
        players[#players + 1] = player
    end
    for _, member in ipairs(guild) do Add(member, friendByKey[self:GetRankingPlayerKey(member.id)]) end
    if not guildOnly then
        for _, friend in ipairs(friends) do Add(friend, friend) end
    end
    table.sort(players, function(left, right)
        local leftSelf, rightSelf = left.isSelf == true, right.isSelf == true
        if leftSelf ~= rightSelf then return leftSelf end
        local leftOnline, rightOnline = left.online == true, right.online == true
        if leftOnline ~= rightOnline then return leftOnline end
        return left.id < right.id
    end)
    return players
end

function addon:RefreshOverview()
    local panel = self.contentPanel
    local tab = panel and panel.selectedTab
    if tab ~= "overview" and tab ~= "guild" then return end
    local page = panel.pages[tab]
    if not page:IsVisible() then return end
    local players, now = self:GetContentRankingPlayers(tab == "guild"), GetServerTime()
    RefreshPlayerTable(page, players, OverviewName)
    if #players == 0 then
        local message = "Your guild members and available WoW friends appear here."
        if tab == "guild" then
            message = self:HasGuild() and "Waiting for your guild roster." or "Join a guild to see its members here."
        end
        page.empty:SetText(message)
    end
    local menu = page.actionMenu
    for index, row in ipairs(page.rows) do
        local player = players[page.offset + index]
        local id = player and player.id or nil
        if row.playerID ~= id then
            if menu:IsShown() then menu:Hide() end
            HideTooltip(row.levelCell)
            HideTooltip(row.ranking)
        end
        row.playerID = id
        if player then
            row.name:SetText(OverviewName(player))
            RefreshProgress(row, player)
            local seen = Age(player.seenAt, now)
            if player.online then seen = player.nativeOnly and "Online" or "Active"
            elseif player.nativeOnly and player.online == false and not player.seenAt then seen = "Offline" end
            row.seen:SetText(seen)
            RefreshShown(row, not player.nativeOnly, player.rankingAvailable ~= false)
            row:Show()
        else
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

local FRIEND_COLUMNS = { { "Name", "name", 16, 204 }, { "Level", "level", 228, 64 },
    { "Zone", "zone", 300, 162 }, { "Status", "status", 470, 84 } }

function addon:CreateFriendsPage(panel)
    local page = CreatePlayerTable(panel, FRIEND_COLUMNS, function(self) self:RefreshFriends() end)
    panel.pages.friends = page
    for index = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, page)
        row:SetPoint("TOPLEFT", 16, -48 - (index - 1) * ROW_HEIGHT)
        row:SetSize(626, ROW_HEIGHT)
        for _, column in ipairs(FRIEND_COLUMNS) do
            local key = column[2]
            local primary = key == "name" or key == "level"
            local label = UI:Label(row, "", primary and 12 or 11, primary and "text" or "muted")
            label:SetPoint("TOPLEFT", column[3] - 16, -3)
            label:SetSize(column[4], 36)
            row[key] = label
        end
        CreateShownCheckbox(page, row)
        page.rows[index] = row
    end
    page:SetScript("OnShow", function() addon:RefreshFriends() end)
    return page
end

local function FriendName(player)
    return player.displayName or player.name
end

function addon:RefreshFriends()
    local panel = self.contentPanel
    local page = panel and panel.pages.friends
    if not page or not page:IsVisible() or panel.selectedTab ~= "friends" then return end
    local friends, players = self:GetFriendsPlayers(), {}
    if #friends > 0 then
        local inRankings = {}
        for _, player in ipairs(self:GetOverviewPlayers()) do
            inRankings[player.id] = true
            local key = self:GetRankingPlayerKey(player.id)
            if key then inRankings[key] = true end
        end
        -- Keep the native snapshot intact for the overlay. Friends shows
        -- native entries that have no shared row.
        for _, friend in ipairs(friends) do
            if not inRankings[friend.id] and not inRankings[friend.aliasID] then
                players[#players + 1] = friend
            end
        end
    end
    page.empty:SetText(#friends > 0 and "Your available friends are already listed in Rankings."
        or "Your WoW friends appear here when their character information is available.")
    RefreshPlayerTable(page, players, FriendName)
    for index, row in ipairs(page.rows) do
        local player = players[page.offset + index]
        local id = player and player.id or nil
        if row.playerID ~= id then HideTooltip(row.ranking) end
        row.playerID = id
        if player then
            row.name:SetText(FriendName(player))
            row.level:SetText(player.level and tostring(player.level) or "—")
            row.zone:SetText(player.zone or "—")
            row.status:SetText(player.online and "Online" or (player.online == false and "Offline" or "Unknown"))
            RefreshShown(row, false, true)
            row:Show()
        else row:Hide() end
    end
end

function addon:OpenOverview()
    self:OpenContent("overview")
end

addon:RegisterNotification("GUILD_CHANGED", function() addon:RefreshOverview() end)
for _, notification in ipairs({ "DATA_CHANGED", "ROSTER_CHANGED", "FRIENDS_CHANGED", "RANKING_CHANGED" }) do
    addon:RegisterNotification(notification, function()
        addon:RefreshOverview()
        addon:RefreshFriends()
    end)
end
