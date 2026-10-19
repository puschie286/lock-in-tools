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

local function Location(player, now)
    if not player.region then return player.sharing == false and "Not sharing" or "No position" end
    local prefix = player.positionAvailable and player.online and "" or "Last: "
    return prefix .. player.region .. "\n" .. Age(player.positionStamp, now)
end

local function HideTooltip(button)
    if GameTooltip and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
end

local function ActionButton(menu, panel, label, action, y)
    local button = UI:Button(menu.menu, label)
    button:SetPoint("TOPLEFT", 8, -y)
    button:SetSize(154, 28)
    if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
    button:HookScript("OnEnter", function()
        if not GameTooltip then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
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
        panel.feedback:SetText(message or "")
        if success then panel.feedback:SetTextColor(0.4, 1, 0.4)
        else panel.feedback:SetTextColor(1, 0.35, 0.35) end
        addon:RefreshOverview()
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

local function CreateActionMenu(page, panel)
    local menu = CreateFrame("Button", "LockInToolsOverviewActions", page)
    menu.themeOwner = page.themeOwner
    menu:SetAllPoints(UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    menu:EnableMouseWheel(true)
    menu.menu = UI:Section(menu, 0, 0, 170, 80, "")
    menu.menu:SetFrameLevel(menu:GetFrameLevel() + 1)
    menu.menu:SetClampedToScreen(true)
    menu.menu:EnableMouse(true)
    menu.invite = ActionButton(menu, panel, "Invite", "invite", 8)
    menu.request = ActionButton(menu, panel, "Request to join", "request", 44)
    menu:SetScript("OnClick", function() menu:Hide() end)
    menu:SetScript("OnMouseWheel", function(_, delta) page:SetOffset(page.offset - delta) end)
    menu:SetScript("OnHide", function()
        menu.playerID, menu.anchor = nil, nil
        HideTooltip(menu.invite)
        HideTooltip(menu.request)
    end)
    menu:Hide()
    tinsert(UISpecialFrames, "LockInToolsOverviewActions")
    return menu
end

local function SortPlayers(page, players)
    local key = page.sortKey
    if not key then return end
    local function Value(player)
        if key == "name" then return player.name:lower() end
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
    for _, column in ipairs({ { "Name", "name", 16, 164 }, { "Lv", "level", 188, 36 },
        { "Region", "region", 232, 200 }, { "Last seen", "seen", 440, 88 } }) do
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
    page.actionMenu = CreateActionMenu(page, panel)
    for index = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, page)
        row.themeOwner = page.themeOwner
        row:SetPoint("TOPLEFT", 16, -48 - (index - 1) * ROW_HEIGHT)
        row:SetSize(626, ROW_HEIGHT)
        row.name = UI:Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 0, -7)
        row.name:SetSize(164, 30)
        row.level = UI:Label(row, "", 12)
        row.level:SetPoint("TOPLEFT", 172, -7)
        row.level:SetWidth(36)
        row.position = UI:Label(row, "", 11, "muted")
        row.position:SetPoint("TOPLEFT", 216, -3)
        row.position:SetSize(200, 36)
        row.seen = UI:Label(row, "", 11, "muted")
        row.seen:SetPoint("TOPLEFT", 424, -3)
        row.seen:SetSize(88, 36)
        row.actions = UI:Button(row, "Actions v")
        row.actions:SetPoint("TOPLEFT", 520, -5)
        row.actions:SetSize(106, 30)
        row.actions:SetScript("OnClick", function()
            local menu = page.actionMenu
            if menu:IsShown() and menu.playerID == row.playerID then menu:Hide(); return end
            menu:Hide()
            if not row.playerID then return end
            menu.playerID, menu.anchor = row.playerID, row
            menu.menu:ClearAllPoints()
            menu.menu:SetPoint("TOPRIGHT", row.actions, "BOTTOMRIGHT", 0, -2)
            RefreshActions(menu)
            menu:Show()
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
        addon:RequestRosterSnapshot()
        addon:RefreshOverview()
    end
    function page:Deactivate()
        self.active = false
        self:SetScript("OnUpdate", nil)
        self.actionMenu:Hide()
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
    if not self:HasGroup() then
        page.empty:SetText("Choose a group key in Settings > Group to see your friends.")
    elseif #players == 0 then
        page.empty:SetText("Waiting for players on this realm and faction.")
    end
    if #players == 0 then page.empty:Show() else page.empty:Hide() end
    local menu = page.actionMenu
    for index, row in ipairs(page.rows) do
        local player = players[page.offset + index]
        if menu:IsShown() and row.playerID ~= (player and player.id) then menu:Hide() end
        row.playerID = player and player.id or nil
        if player then
            row.name:SetText(player.name .. (player.isSelf and " (you)" or ""))
            row.level:SetText(player.level and tostring(player.level) or "—")
            row.position:SetText(Location(player, now))
            row.seen:SetText((player.online and "Active" or "Last seen") .. "\n" .. Age(player.seenAt, now))
            row:Show()
        else
            row:Hide()
        end
    end
    if menu:IsShown() then RefreshActions(menu) end
end

function addon:OpenOverview()
    self:OpenContent()
end
