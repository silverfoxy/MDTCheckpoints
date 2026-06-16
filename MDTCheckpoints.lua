-- MDTCheckpoints: boss % gate overlay for M+ runs
-- Reads route from MDT; live % from C_Scenario.

MDTCheckpointsDB = {}

local ADDON           = "MDTCheckpoints"
local W               = 230
local ROW_H           = 15
local PAD             = 6
local WARN_PCT        = 8    -- highlight next gate when this many % away
local MAX_CHECKPOINTS = 8

-- ── State ─────────────────────────────────────────────────────────────────────
local checkpoints = {}   -- { pct, label, isMini }[]
local currentPct  = 0
local dungeonName = "No dungeon"
local isActive    = false
local isCollapsed = false
local locked      = false
local frame, pctText, titleText, toggleBtnText, cpRows

-- ── Scenario % ────────────────────────────────────────────────────────────────
local function GetForcesPct()
    if not C_Scenario.IsInScenario() then return 0 end

    local _, _, numCriteria = C_Scenario.GetStepInfo()
    for i = 1, (numCriteria or 0) do
        local criteriaInfo = C_ScenarioInfo.GetCriteriaInfo(i)
        if criteriaInfo and criteriaInfo.isWeightedProgress then
            -- Enemy forces criteria found
            local cur_value = criteriaInfo.quantity
            local is_percent_value = criteriaInfo.isWeightedProgress

            -- Handle percentage string format (e.g., "45%")
            if criteriaInfo.isWeightedProgress and criteriaInfo.quantityString then
                cur_value = tonumber(string.sub(criteriaInfo.quantityString, 1, string.len(criteriaInfo.quantityString) - 1))
                is_percent_value = false
            end

            local quantity_percent = 0
            if is_percent_value then
                quantity_percent = cur_value
            else
                quantity_percent = (cur_value / criteriaInfo.totalQuantity) * 100
            end

            return quantity_percent
        end
    end
    return 0
end

-- ── MDT extraction ────────────────────────────────────────────────────────────
local function LoadCheckpoints()
    checkpoints = {}
    dungeonName = "No route"

    if not MDT then
        dungeonName = "MDT not loaded"
        return
    end

    local db = (MDT.GetDB and MDT:GetDB())
           or (MDT.db and (MDT.db.profile or MDT.db.global or MDT.db))
    if not db then return end

    local dIdx = db.currentDungeonIdx
    if not dIdx then return end

    local preset = MDT:GetCurrentPreset()
    if not preset then
        dungeonName = MDT:GetDungeonName(dIdx) or "Unknown"
        return
    end

    -- Handle both {value={pulls=...}} and direct {pulls=...} layouts
    local presetValue = preset.value or preset
    if not presetValue or not presetValue.pulls then
        dungeonName = MDT:GetDungeonName(dIdx) or "Unknown"
        return
    end

    local pulls   = presetValue.pulls
    local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dIdx]
    local totData = MDT.dungeonTotalCount and MDT.dungeonTotalCount[dIdx]
    local total   = totData and totData.normal or 0

    dungeonName = MDT:GetDungeonName(dIdx) or "Unknown"
    if not enemies or total == 0 then return end

    -- Count total clones per enemy across entire route (mini-boss detection)
    local routeClones = {}
    for pi = 1, #pulls do
        local p = pulls[pi]
        if p then
            for eIdx, clones in pairs(p) do
                if type(clones) == "table" then
                    routeClones[eIdx] = (routeClones[eIdx] or 0) + #clones
                end
            end
        end
    end

    local cumulative = 0
    local cps        = {}

    for pullIdx = 1, #pulls do
        local pull = pulls[pullIdx]
        if pull then
            local pullCnt = 0
            local gates   = {}
            local mini    = nil

            for eIdx, clones in pairs(pull) do
                if type(clones) == "table" then
                    local en = enemies[eIdx]
                    if en then
                        pullCnt = pullCnt + (en.count or 0) * #clones
                        if en.isBoss then
                            if (en.count or 0) == 0 then
                                table.insert(gates, en.name or "Boss")
                            elseif (routeClones[eIdx] or 0) == 1 and not mini then
                                mini = en.name
                            end
                        end
                    end
                end
            end

            local pctBefore = cumulative / total * 100
            cumulative = cumulative + pullCnt

            if #gates > 0 then
                table.insert(cps, {
                    pct    = pctBefore,
                    label  = table.concat(gates, " + "),
                    isMini = false,
                })
            elseif mini then
                table.insert(cps, {
                    pct    = pctBefore,
                    label  = mini,
                    isMini = true,
                })
            end
        end
    end

    checkpoints = cps
end

-- ── Row renderer ─────────────────────────────────────────────────────────────
local function RenderRow(row, cp, done, isNext, warning)
    if done then
        row.icon:SetText("|cff55dd55ok|r")
    elseif isNext then
        row.icon:SetText(warning and "|cffff6633>>|r" or "|cffffd700>|r")
    elseif cp.isMini then
        row.icon:SetText("|cff888888*|r")
    else
        row.icon:SetText("|cff888888.|r")
    end

    local pctStr = string.format("%.1f%%", cp.pct)
    if done then
        row.pct:SetText("|cff55dd55" .. pctStr .. "|r")
    elseif isNext then
        local color = warning and "ffff6633" or "ffffd700"
        row.pct:SetText("|c" .. color .. pctStr .. "|r")
    else
        row.pct:SetText("|cff888888" .. pctStr .. "|r")
    end

    local nameStr = cp.isMini and (cp.label .. " *") or cp.label
    if done then
        row.label:SetText("|cff55dd55" .. nameStr .. "|r")
    elseif isNext then
        local color = warning and "ffff6633" or "ffffd700"
        row.label:SetText("|c" .. color .. nameStr .. "|r")
    else
        row.label:SetText("|cff888888" .. nameStr .. "|r")
    end
    row:Show()
end

-- ── Display update ────────────────────────────────────────────────────────────
local function UpdateDisplay()
    if not frame then return end

    if not isActive then
        frame:Hide()
        return
    end
    frame:Show()

    titleText:SetText(dungeonName)
    pctText:SetText(string.format("|cffaaddff%.1f%%|r", currentPct))
    if toggleBtnText then toggleBtnText:SetText(isCollapsed and "+" or "-") end

    -- Find next uncleared checkpoint
    local nextIdx = nil
    for i, cp in ipairs(checkpoints) do
        if currentPct < cp.pct - 0.05 then
            nextIdx = i
            break
        end
    end

    if isCollapsed then
        for i = 2, MAX_CHECKPOINTS do cpRows[i]:Hide() end
        if nextIdx then
            local cp  = checkpoints[nextIdx]
            local gap = cp.pct - currentPct
            RenderRow(cpRows[1], cp, false, true, gap <= WARN_PCT and gap > 0)
            frame:SetHeight(PAD + ROW_H + PAD/2 + ROW_H + PAD)
        else
            cpRows[1]:Hide()
            frame:SetHeight(PAD + ROW_H + PAD)
        end
    else
        -- Calculate height based on actual number of checkpoints
        local numCheckpoints = math.min(#checkpoints, MAX_CHECKPOINTS)
        if numCheckpoints == 0 then
            -- Minimum height when no checkpoints are loaded
            frame:SetHeight(PAD + ROW_H + PAD)
        else
            frame:SetHeight(PAD + ROW_H + PAD/2 + numCheckpoints * ROW_H + PAD)
        end
        for i, row in ipairs(cpRows) do
            local cp = checkpoints[i]
            if not cp then
                row:Hide()
            else
                local done    = currentPct >= cp.pct - 0.05
                local isNext  = (i == nextIdx)
                local gap     = cp.pct - currentPct
                local warning = isNext and gap <= WARN_PCT and gap > 0
                RenderRow(row, cp, done, isNext, warning)
            end
        end
    end
end

-- ── Frame builder ─────────────────────────────────────────────────────────────
local FONT   = "Fonts\\FRIZQT__.TTF"
local FONT_S = 12
local FONT_XS = 11

local function BuildFrame()
    local totalH = PAD + ROW_H + PAD/2 + MAX_CHECKPOINTS * ROW_H + PAD

    frame = CreateFrame("Frame", "MDTCheckpointsFrame", UIParent,
                        BackdropTemplateMixin and "BackdropTemplate" or nil)
    frame:SetSize(W, totalH)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left=3, right=3, top=3, bottom=3 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.85)
        frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    end

    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) if not locked then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        MDTCheckpointsDB.point = { self:GetPoint() }
    end)
    frame:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            isCollapsed = not isCollapsed
            MDTCheckpointsDB.collapsed = isCollapsed
            UpdateDisplay()
        end
    end)

    -- Collapse/expand toggle button (+/-)
    local toggleBtn = CreateFrame("Button", nil, frame)
    toggleBtn:SetSize(ROW_H + 4, ROW_H)
    toggleBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)

    toggleBtnText = toggleBtn:CreateFontString(nil, "OVERLAY")
    toggleBtnText:SetFont(FONT, FONT_S + 3, "OUTLINE")
    toggleBtnText:SetAllPoints()
    toggleBtnText:SetJustifyH("CENTER")
    toggleBtnText:SetJustifyV("MIDDLE")
    toggleBtnText:SetTextColor(0.65, 0.65, 0.65, 1)
    toggleBtnText:SetText("-")

    toggleBtn:SetScript("OnEnter", function()
        toggleBtnText:SetFont(FONT, FONT_S + 6, "OUTLINE")
        toggleBtnText:SetTextColor(1, 1, 1, 1)
    end)
    toggleBtn:SetScript("OnLeave", function()
        toggleBtnText:SetFont(FONT, FONT_S + 3, "OUTLINE")
        toggleBtnText:SetTextColor(0.65, 0.65, 0.65, 1)
    end)
    toggleBtn:SetScript("OnClick", function()
        isCollapsed = not isCollapsed
        MDTCheckpointsDB.collapsed = isCollapsed
        UpdateDisplay()
    end)

    -- Title
    titleText = frame:CreateFontString(nil, "OVERLAY")
    titleText:SetFont(FONT, FONT_S, "OUTLINE")
    titleText:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PAD + ROW_H + 2, -PAD)
    titleText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD)
    titleText:SetHeight(ROW_H)
    titleText:SetJustifyH("LEFT")
    titleText:SetTextColor(1, 0.82, 0, 1)

    -- % text on the same line as the title, right-aligned
    pctText = frame:CreateFontString(nil, "OVERLAY")
    pctText:SetFont(FONT, FONT_XS, "OUTLINE")
    pctText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD)
    pctText:SetSize(80, ROW_H)
    pctText:SetJustifyH("RIGHT")
    pctText:SetTextColor(0.7, 0.9, 1, 1)

    -- Checkpoint rows — font strings directly on the main frame (no child frames)
    cpRows = {}
    for i = 1, MAX_CHECKPOINTS do
        local row = {}
        local offsetY = -(PAD + ROW_H + PAD/2 + (i - 1) * ROW_H)

        row.icon = frame:CreateFontString(nil, "OVERLAY")
        row.icon:SetFont(FONT, FONT_XS, "")
        row.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, offsetY)
        row.icon:SetSize(14, ROW_H)
        row.icon:SetJustifyH("CENTER")
        row.icon:SetJustifyV("MIDDLE")

        row.pct = frame:CreateFontString(nil, "OVERLAY")
        row.pct:SetFont(FONT, FONT_XS, "")
        row.pct:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + 16, offsetY)
        row.pct:SetSize(40, ROW_H)
        row.pct:SetJustifyH("LEFT")
        row.pct:SetJustifyV("MIDDLE")

        row.label = frame:CreateFontString(nil, "OVERLAY")
        row.label:SetFont(FONT, FONT_XS, "")
        row.label:SetPoint("TOPLEFT",  frame, "TOPLEFT",  PAD + 58, offsetY)
        row.label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD,     offsetY)
        row.label:SetHeight(ROW_H)
        row.label:SetJustifyH("LEFT")
        row.label:SetJustifyV("MIDDLE")

        -- Hide/show helpers that work on the three font strings
        row.Hide = function()
            row.icon:Hide(); row.pct:Hide(); row.label:Hide()
        end
        row.Show = function()
            row.icon:Show(); row.pct:Show(); row.label:Show()
        end

        row:Hide()
        cpRows[i] = row
    end

    -- Anchor: top-right or saved position
    local saved = MDTCheckpointsDB.point
    if saved then
        frame:SetPoint(unpack(saved))
    else
        frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -200)
    end

    -- Resize grip (bottom-right corner)
    frame:SetResizable(true)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(12, 12)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp",   function()
        frame:StopMovingOrSizing()
        MDTCheckpointsDB.size = { frame:GetWidth(), frame:GetHeight() }
    end)
    -- Diagonal dot pattern (classic resize indicator)
    local dotPositions = {{2,2},{5,2},{2,5},{8,2},{5,5},{2,8}}
    for _, p in ipairs(dotPositions) do
        local dot = grip:CreateTexture(nil, "OVERLAY")
        dot:SetSize(2, 2)
        dot:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -p[1], p[2])
        dot:SetColorTexture(0.8, 0.8, 0.8, 0.8)
    end

    frame:Hide()
end

-- ── Settings panel ───────────────────────────────────────────────────────────
local settingsPanel   = nil
local previewActive   = false
local previewBtnTexts = {}

local function MakeSlider(parent, x, y, w, name, mn, mx, stp, init, fmt, cb)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, FONT_XS, "OUTLINE")
    lbl:SetTextColor(0.85, 0.85, 0.85, 1)
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    lbl:SetWidth(w); lbl:SetJustifyH("LEFT")

    local sl = CreateFrame("Slider", nil, parent)
    sl:SetOrientation("HORIZONTAL")
    sl:SetSize(w, 12)
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - 17)
    sl:SetMinMaxValues(mn, mx)
    sl:SetValueStep(stp)

    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0.18, 0.18, 0.18, 1)
    track:SetPoint("TOPLEFT",     sl, "TOPLEFT",     0, -3)
    track:SetPoint("BOTTOMRIGHT", sl, "BOTTOMRIGHT", 0,  3)

    local thumb = sl:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 20)
    thumb:SetColorTexture(0.78, 0.78, 0.78, 1)
    sl:SetThumbTexture(thumb)

    sl:SetScript("OnValueChanged", function(_, v)
        local s = math.floor(v / stp + 0.5) * stp
        lbl:SetText(name .. "  |cffffcc00" .. fmt(s) .. "|r")
        cb(s)
    end)
    sl:SetValue(init)
    return sl
end

local function MakeCheckbox(parent, x, y, name, init, cb)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(14, 14)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints()
    border:SetColorTexture(0.55, 0.55, 0.55, 1)

    local fill = btn:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT",     btn, "TOPLEFT",     1, -1)
    fill:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1,  1)

    local checked = init
    local function refresh()
        if checked then
            fill:SetColorTexture(0.2, 0.75, 0.2, 1)
        else
            fill:SetColorTexture(0.12, 0.12, 0.12, 1)
        end
    end
    refresh()

    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(FONT, FONT_XS, "OUTLINE")
    lbl:SetTextColor(0.85, 0.85, 0.85, 1)
    lbl:SetText(name)
    lbl:SetPoint("LEFT", btn, "RIGHT", 6, 0)

    btn:SetScript("OnClick", function()
        checked = not checked
        refresh()
        cb(checked)
    end)

    return btn, function(v) checked = v; refresh() end
end

local function MakeButton(parent, x, y, w, h, label, cb)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(w, h)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local border = btn:CreateTexture(nil, "BACKGROUND")
    border:SetAllPoints(); border:SetColorTexture(0.45, 0.45, 0.45, 1)
    local fill = btn:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT",     btn, "TOPLEFT",      1, -1)
    fill:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1,  1)
    fill:SetColorTexture(0.18, 0.18, 0.18, 1)
    local txt = btn:CreateFontString(nil, "OVERLAY")
    txt:SetFont(FONT, FONT_XS, "OUTLINE")
    txt:SetAllPoints(); txt:SetJustifyH("CENTER"); txt:SetJustifyV("MIDDLE")
    txt:SetText(label); txt:SetTextColor(0.85, 0.85, 0.85, 1)
    btn:SetScript("OnEnter", function() fill:SetColorTexture(0.3, 0.3, 0.3, 1); txt:SetTextColor(1, 1, 1, 1) end)
    btn:SetScript("OnLeave", function() fill:SetColorTexture(0.18, 0.18, 0.18, 1); txt:SetTextColor(0.85, 0.85, 0.85, 1) end)
    btn:SetScript("OnClick", cb)
    return btn, txt
end

local function TogglePreview()
    previewActive = not previewActive
    for _, t in ipairs(previewBtnTexts) do
        t:SetText(previewActive and "Stop Preview" or "Preview")
    end
    if previewActive then
        isActive    = true
        dungeonName = "Preview Mode"
        currentPct  = 25.0
        checkpoints = {
            { pct =  18.0, label = "First Boss",  isMini = false },
            { pct =  35.5, label = "Mini-Boss",   isMini = true  },
            { pct =  58.0, label = "Second Boss", isMini = false },
            { pct =  80.0, label = "Third Boss",  isMini = false },
            { pct = 100.0, label = "Final Boss",  isMini = false },
        }
    else
        isActive    = false
        dungeonName = "No dungeon"
        checkpoints = {}
        currentPct  = 0
        LoadCheckpoints()
        if C_Scenario.IsInScenario() then
            isActive   = true
            currentPct = GetForcesPct()
        end
    end
    UpdateDisplay()
end

local function BuildSettingsPanel()
    local SW, SP = 300, 12
    local IW = SW - SP * 2

    local panel = CreateFrame("Frame", "MDTCheckpointsSettingsPanel", UIParent,
                              BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(SW, 290)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop",  panel.StopMovingOrSizing)
    panel:SetPoint("CENTER")

    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = {left=3, right=3, top=3, bottom=3},
        })
        panel:SetBackdropColor(0.08, 0.08, 0.10, 0.97)
        panel:SetBackdropBorderColor(0.6, 0.5, 0.2, 1)
    end

    local titleStr = panel:CreateFontString(nil, "OVERLAY")
    titleStr:SetFont(FONT, FONT_S, "OUTLINE")
    titleStr:SetText("|cffffcc00MDT Checkpoints|r  Settings")
    titleStr:SetPoint("TOPLEFT", panel, "TOPLEFT", SP, -SP)
    titleStr:SetHeight(ROW_H)

    local xBtn = CreateFrame("Button", nil, panel)
    xBtn:SetSize(ROW_H, ROW_H)
    xBtn:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SP/2, -SP/2)
    local xTxt = xBtn:CreateFontString(nil, "OVERLAY")
    xTxt:SetFont(FONT, FONT_S + 2, "OUTLINE")
    xTxt:SetAllPoints(); xTxt:SetJustifyH("CENTER"); xTxt:SetJustifyV("MIDDLE")
    xTxt:SetText("X"); xTxt:SetTextColor(0.65, 0.65, 0.65, 1)
    xBtn:SetScript("OnClick", function() panel:Hide() end)
    xBtn:SetScript("OnEnter", function() xTxt:SetTextColor(1, 0.3, 0.3, 1) end)
    xBtn:SetScript("OnLeave", function() xTxt:SetTextColor(0.65, 0.65, 0.65, 1) end)

    local function Divider(label, y)
        local line = panel:CreateTexture(nil, "BACKGROUND")
        line:SetColorTexture(0.5, 0.42, 0.12, 0.7)
        line:SetPoint("TOPLEFT",  panel, "TOPLEFT",  SP, y)
        line:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -SP, y)
        line:SetHeight(1)
        local dlbl = panel:CreateFontString(nil, "OVERLAY")
        dlbl:SetFont(FONT, FONT_XS - 1, "OUTLINE")
        dlbl:SetText(label)
        dlbl:SetTextColor(0.85, 0.7, 0.2, 1)
        dlbl:SetPoint("BOTTOMLEFT", line, "TOPLEFT", 0, 1)
    end

    local y = -(SP + ROW_H + SP)

    Divider("Window", y); y = y - 20
    local scaleSlider = MakeSlider(panel, SP, y, IW, "Scale",
        0.5, 2.0, 0.05, MDTCheckpointsDB.scale or 1.0,
        function(v) return string.format("x%.2f", v) end,
        function(v) frame:SetScale(v); MDTCheckpointsDB.scale = v end)
    y = y - 40

    Divider("Behavior", y); y = y - 20
    local warnSlider = MakeSlider(panel, SP, y, IW, "Warn when gate is within",
        0, 20, 1, MDTCheckpointsDB.warnPct or WARN_PCT,
        function(v) return string.format("%d%%", v) end,
        function(v) WARN_PCT = v; MDTCheckpointsDB.warnPct = v end)
    y = y - 40

    local _, setLock = MakeCheckbox(panel, SP, y, "Lock position (disable drag)",
        MDTCheckpointsDB.locked or false,
        function(v) locked = v; MDTCheckpointsDB.locked = v end)
    y = y - 26

    local _, setStartCollapsed = MakeCheckbox(panel, SP, y, "Start collapsed",
        MDTCheckpointsDB.collapsed or false,
        function(v) isCollapsed = v; MDTCheckpointsDB.collapsed = v; UpdateDisplay() end)
    y = y - 34

    -- Preview button
    local hw = (IW - 4) / 2
    local _, previewTxt = MakeButton(panel, SP, y, hw, 22, "Preview", TogglePreview)
    table.insert(previewBtnTexts, previewTxt)
    y = y - 28

    -- Reset Defaults button
    local resetBtn = CreateFrame("Button", nil, panel)
    resetBtn:SetSize(IW, 22)
    resetBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", SP, y)

    local rBorder = resetBtn:CreateTexture(nil, "BACKGROUND")
    rBorder:SetAllPoints(); rBorder:SetColorTexture(0.45, 0.45, 0.45, 1)
    local rFill = resetBtn:CreateTexture(nil, "ARTWORK")
    rFill:SetPoint("TOPLEFT",     resetBtn, "TOPLEFT",     1, -1)
    rFill:SetPoint("BOTTOMRIGHT", resetBtn, "BOTTOMRIGHT", -1,  1)
    rFill:SetColorTexture(0.18, 0.18, 0.18, 1)
    local rTxt = resetBtn:CreateFontString(nil, "OVERLAY")
    rTxt:SetFont(FONT, FONT_XS, "OUTLINE")
    rTxt:SetAllPoints(); rTxt:SetJustifyH("CENTER"); rTxt:SetJustifyV("MIDDLE")
    rTxt:SetText("Reset Defaults"); rTxt:SetTextColor(0.85, 0.85, 0.85, 1)

    resetBtn:SetScript("OnEnter", function()
        rFill:SetColorTexture(0.28, 0.28, 0.28, 1); rTxt:SetTextColor(1, 1, 1, 1)
    end)
    resetBtn:SetScript("OnLeave", function()
        rFill:SetColorTexture(0.18, 0.18, 0.18, 1); rTxt:SetTextColor(0.85, 0.85, 0.85, 1)
    end)
    resetBtn:SetScript("OnClick", function()
        frame:SetScale(1.0);    MDTCheckpointsDB.scale    = nil; scaleSlider:SetValue(1.0)
        WARN_PCT = 8;           MDTCheckpointsDB.warnPct  = nil; warnSlider:SetValue(8)
        locked = false;         MDTCheckpointsDB.locked   = nil; setLock(false)
        isCollapsed = false;    MDTCheckpointsDB.collapsed= nil; setStartCollapsed(false)
        UpdateDisplay()
    end)

    panel:Hide()
    return panel
end

local function RegisterWithSettings()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local canvas = CreateFrame("Frame")
    local x, y, IW = 20, -24, 380

    local hdr = canvas:CreateFontString(nil, "OVERLAY")
    hdr:SetFont(FONT, FONT_S + 1, "OUTLINE")
    hdr:SetText("|cffffcc00MDT Checkpoints|r  Settings")
    hdr:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, y)
    y = y - 36

    local scaleSlider2 = MakeSlider(canvas, x, y, IW, "Scale",
        0.5, 2.0, 0.05, MDTCheckpointsDB.scale or 1.0,
        function(v) return string.format("x%.2f", v) end,
        function(v) frame:SetScale(v); MDTCheckpointsDB.scale = v end)
    y = y - 48

    local warnSlider2 = MakeSlider(canvas, x, y, IW, "Warn when gate is within",
        0, 20, 1, MDTCheckpointsDB.warnPct or WARN_PCT,
        function(v) return string.format("%d%%", v) end,
        function(v) WARN_PCT = v; MDTCheckpointsDB.warnPct = v end)
    y = y - 48

    local _, setLock2 = MakeCheckbox(canvas, x, y, "Lock position (disable drag)",
        MDTCheckpointsDB.locked or false,
        function(v) locked = v; MDTCheckpointsDB.locked = v end)
    y = y - 30

    local _, setCollapsed2 = MakeCheckbox(canvas, x, y, "Start collapsed",
        MDTCheckpointsDB.collapsed or false,
        function(v) isCollapsed = v; MDTCheckpointsDB.collapsed = v; UpdateDisplay() end)
    y = y - 36

    local _, previewTxt2 = MakeButton(canvas, x, y, 160, 22, "Preview", TogglePreview)
    table.insert(previewBtnTexts, previewTxt2)

    -- Sync widgets from DB each time the panel is opened
    canvas:SetScript("OnShow", function()
        scaleSlider2:SetValue(MDTCheckpointsDB.scale or 1.0)
        warnSlider2:SetValue(MDTCheckpointsDB.warnPct or WARN_PCT)
        setLock2(MDTCheckpointsDB.locked or false)
        setCollapsed2(MDTCheckpointsDB.collapsed or false)
    end)

    local category = Settings.RegisterCanvasLayoutCategory(canvas, "MDT Checkpoints")
    Settings.RegisterAddOnCategory(category)
end

-- ── Throttled updater ─────────────────────────────────────────────────────────
local elapsed = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, dt)
    if not isActive then return end
    elapsed = elapsed + dt
    if elapsed < 0.5 then return end
    elapsed = 0
    currentPct = GetForcesPct()
    local ok, err = pcall(UpdateDisplay)
    if not ok then
        isActive = false
        print("|cffff3333[MDTCheckpoints]|r display error (auto-stopped): " .. tostring(err))
    end
end)

-- ── Events ────────────────────────────────────────────────────────────────────
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("CHALLENGE_MODE_START")
events:RegisterEvent("CHALLENGE_MODE_RESET")
events:RegisterEvent("CHALLENGE_MODE_COMPLETED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("SCENARIO_CRITERIA_UPDATE")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        if not MDTCheckpointsDB then MDTCheckpointsDB = {} end
        BuildFrame()
        isCollapsed = MDTCheckpointsDB.collapsed or false
        locked      = MDTCheckpointsDB.locked    or false
        WARN_PCT    = MDTCheckpointsDB.warnPct   or WARN_PCT
        if MDTCheckpointsDB.scale then frame:SetScale(MDTCheckpointsDB.scale) end
        if MDTCheckpointsDB.size  then frame:SetSize(unpack(MDTCheckpointsDB.size)) end
        settingsPanel = BuildSettingsPanel()
        RegisterWithSettings()

    elseif event == "CHALLENGE_MODE_START" then
        isActive = true
        currentPct = 0
        -- Short delay so MDT can sync its dungeon state
        C_Timer.After(1.5, function()
            LoadCheckpoints()
            UpdateDisplay()
        end)

    elseif event == "CHALLENGE_MODE_RESET" or event == "CHALLENGE_MODE_COMPLETED" then
        isActive = false
        UpdateDisplay()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Resume display if already inside a scenario/M+ (e.g., after /reload or login mid-run)
        C_Timer.After(2, function()
            if C_Scenario.IsInScenario() then
                isActive = true
                LoadCheckpoints()
                currentPct = GetForcesPct()
                UpdateDisplay()
            end
        end)

    elseif event == "SCENARIO_CRITERIA_UPDATE" then
        -- Update percentage when enemy forces change in M+
        if isActive then
            currentPct = GetForcesPct()
            UpdateDisplay()
        end
    end
end)

-- ── Slash command ─────────────────────────────────────────────────────────────
SLASH_MDTCP1 = "/mdtcp"
SlashCmdList["MDTCP"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "reload" then
        LoadCheckpoints()
        UpdateDisplay()
        print("|cff00cc44[MDTCheckpoints]|r Reloaded route from MDT.")
    elseif msg == "config" then
        if settingsPanel then
            if settingsPanel:IsShown() then
                settingsPanel:Hide()
            else
                settingsPanel:SetPoint("CENTER")
                settingsPanel:Show()
            end
        end
    else
        print("|cff00cc44[MDTCheckpoints]|r Commands:")
        print("  /mdtcp config — open settings panel")
        print("  /mdtcp reload — re-read route from MDT")
    end
end
