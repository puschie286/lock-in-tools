local _, addon = ...
local UI = addon.Theme
local ROWS_PER_PAGE = 6

local function Age(stamp, now)
    if type(stamp) ~= "number" then return "age unknown" end
    local seconds = math.max(0, math.floor(now - stamp))
    if seconds < 60 then return seconds .. "s ago" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function Location(player, now)
    if not player.map or not player.x or not player.y then
        return player.sharing == false and "Not sharing" or "No position"
    end
    local zone = "Map " .. tostring(player.map)
    if C_Map and type(C_Map.GetMapInfo) == "function" then
        local ok, info = pcall(C_Map.GetMapInfo, player.map)
        if ok and type(info) == "table" and type(info.name) == "string" then zone = info.name end
    end
    local prefix = player.positionAvailable and player.online and "" or "Last: "
    return prefix .. zone .. "\n" .. string.format("%.1f, %.1f", player.x * 100, player.y * 100)
        .. " · " .. Age(player.positionStamp, now)
end

local function HideTooltip(button)
    if GameTooltip and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
end

local function ActionButton(row, panel, label, action, x, width)
    local button = UI:Button(row, label)
    button:SetPoint("TOPLEFT", x, -5)
    button:SetSize(width, 30)
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
        if not row.playerID then return end
        local success, message = addon:PerformOverviewAction(row.playerID, action)
        panel.feedback:SetText(message or "")
        if success then panel.feedback:SetTextColor(0.4, 1, 0.4)
        else panel.feedback:SetTextColor(1, 0.35, 0.35) end
        addon:RefreshOverview()
    end)
    return button
end

function addon:CreateOverviewPage(panel)
    local page = UI:Section(panel, 20, 116, 680, 414, "Players")
    panel.pages.overview, panel.overviewPage = page, page
    panel.feedback = UI:Label(page, "", 13)
    panel.feedback:SetPoint("TOPLEFT", 16, -345)
    panel.feedback:SetSize(648, 26)
    page.pageNumber, page.rows = 1, {}
    page.summary = UI:Label(page, "", 12, "muted")
    page.summary:SetPoint("TOPLEFT", 16, -45)
    page.summary:SetWidth(648)
    for _, column in ipairs({ { "Name", 16, 142 }, { "Lv", 162, 32 },
        { "Last position", 202, 210 }, { "Last seen", 420, 66 }, { "Actions", 494, 166 } }) do
        local label = UI:Label(page, column[1], 12, "muted")
        label:SetPoint("TOPLEFT", column[2], -69)
        label:SetWidth(column[3])
    end
    for index = 1, ROWS_PER_PAGE do
        local row = CreateFrame("Frame", nil, page)
        row.themeOwner = page.themeOwner
        row:SetPoint("TOPLEFT", 16, -89 - (index - 1) * 42)
        row:SetSize(648, 40)
        row.name = UI:Label(row, "", 12)
        row.name:SetPoint("TOPLEFT", 0, -7)
        row.name:SetSize(142, 30)
        row.level = UI:Label(row, "", 12)
        row.level:SetPoint("TOPLEFT", 146, -7)
        row.level:SetWidth(32)
        row.position = UI:Label(row, "", 11, "muted")
        row.position:SetPoint("TOPLEFT", 186, -3)
        row.position:SetSize(210, 36)
        row.seen = UI:Label(row, "", 11, "muted")
        row.seen:SetPoint("TOPLEFT", 404, -3)
        row.seen:SetSize(66, 36)
        row.invite = ActionButton(row, panel, "Invite", "invite", 478, 54)
        row.request = ActionButton(row, panel, "Request to join", "request", 538, 106)
        page.rows[index] = row
    end
    page.previous = UI:Button(page, "Previous")
    page.previous:SetPoint("BOTTOMLEFT", 16, 12)
    page.previous:SetSize(82, 26)
    page.next = UI:Button(page, "Next")
    page.next:SetPoint("BOTTOMRIGHT", -16, 12)
    page.next:SetSize(82, 26)
    page.pagination = UI:Label(page, "", 12, "muted")
    page.pagination:SetPoint("CENTER", page, "BOTTOM", 0, 25)
    page.previous:SetScript("OnClick", function()
        page.pageNumber = page.pageNumber - 1
        addon:RefreshOverview()
    end)
    page.next:SetScript("OnClick", function()
        page.pageNumber = page.pageNumber + 1
        addon:RefreshOverview()
    end)
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
        for _, row in ipairs(self.rows) do
            HideTooltip(row.invite)
            HideTooltip(row.request)
        end
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
    local online = 0
    for _, player in ipairs(players) do if player.online then online = online + 1 end end
    local pages = math.max(1, math.ceil(#players / ROWS_PER_PAGE))
    page.pageNumber = math.max(1, math.min(page.pageNumber, pages))
    if not self:HasGroup() then
        page.summary:SetText("Choose a group key in Settings > Group to see your friends.")
    elseif #players == 0 then
        page.summary:SetText("Waiting for players on this realm and faction.")
    else
        page.summary:SetText(online .. " active · " .. #players .. " known · Same realm and faction")
    end
    for index, row in ipairs(page.rows) do
        local player = players[(page.pageNumber - 1) * ROWS_PER_PAGE + index]
        row.playerID = player and player.id or nil
        if player then
            row.name:SetText(player.name .. (player.isSelf and " (you)" or ""))
            row.level:SetText(player.level and tostring(player.level) or "—")
            row.position:SetText(Location(player, now))
            row.seen:SetText((player.online and "Active" or "Last seen") .. "\n" .. Age(player.seenAt, now))
            local state = self:GetOverviewActionState(player.id)
            row.invite.reason, row.request.reason = state.inviteReason, state.requestReason
            row.invite:SetEnabled(state.invite == true)
            row.request:SetEnabled(state.request == true)
            row:Show()
        else
            row:Hide()
        end
    end
    page.pagination:SetText("Page " .. page.pageNumber .. " / " .. pages)
    page.previous:SetEnabled(page.pageNumber > 1)
    page.next:SetEnabled(page.pageNumber < pages)
end

function addon:OpenOverview()
    self:OpenContent()
end
