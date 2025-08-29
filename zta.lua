--[[
    ZTA - A lightweight auction house scanner for WoW Vanilla
    Features:
    - Moveable circular icon with $ symbols
    - Progress tracking with status window
    - Persistent data storage
    - Cancel functionality
    - Based on techniques from Auctioneer addon by Norganna's AddOns
]]

-- ============================================================================
-- GLOBAL FUNCTIONS (only those called by XML)
-- ============================================================================

-- CRITICAL: Initialize empty functions IMMEDIATELY to prevent XML errors
ZTA_Print           = ZTA_Print             or function() end
ZTA_OnLoad          = ZTA_OnLoad            or function() end
ZTA_OnClick         = ZTA_OnClick           or function() end
ZTA_ShowTooltip     = ZTA_ShowTooltip       or function() end
ZTA_SavePosition    = ZTA_SavePosition      or function() end
ZTA_OnDragStart     = ZTA_OnDragStart       or function() end
ZTA_OnDragStop      = ZTA_OnDragStop        or function() end

-- ============================================================================
-- SAVED VARIABLES (must be global)
-- ============================================================================

-- Saved variables (will be loaded from SavedVariables)
ZTA_DB = ZTA_DB or {
    iconPosition = { point = "TOPRIGHT", x = -50, y = -150 },
    scanHistory = {}
}

-- ============================================================================
-- LOCAL VARIABLES
-- ============================================================================

-- Icon states
local ICON_STATE_IDLE = "$"
local ICON_STATE_LOADING = "..."
local ICON_STATE_SCANNING = "X"

-- Local variables for scanning state
local scanInProgress = false
local scanStartTime = nil
local currentPage = 0
local totalPages = 0
local itemsScanned = 0
local totalItems = 0
local scanData = {}

-- Hook variables for original functions
local originalCanSendAuctionQuery = nil

-- ============================================================================
-- LOCAL HELPER FUNCTIONS
-- ============================================================================

local function secondsToTime(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    
    if hours > 0 then
        return string.format("%dh %dm %ds", hours, minutes, secs)
    elseif minutes > 0 then
        return string.format("%dm %ds", minutes, secs)
    else
        return string.format("%ds", secs)
    end
end

local function updateProgress()
    local progressFrame = getglobal("ZTAProgressFrame")
    if not progressFrame or not progressFrame:IsVisible() then
        return
    end
    
    -- Update item count
    local itemCountText = getglobal("ZTAProgressFrameProgressTextItemCount")
    if itemCountText then
        itemCountText:SetText("Items scanned: " .. itemsScanned)
    end
    
    -- Update progress percentage
    local progressPercent = 0
    if totalPages > 0 then
        progressPercent = math.floor((currentPage / totalPages) * 100)
    end
    local progressText = getglobal("ZTAProgressFrameProgressTextProgress")
    if progressText then
        progressText:SetText("Progress: " .. progressPercent .. "%")
    end
    
    -- Update ETA
    local eta = "Unknown"
    if scanStartTime and itemsScanned > 0 then
        local elapsed = GetTime() - scanStartTime
        local itemsPerSecond = itemsScanned / elapsed
        if itemsPerSecond > 0 and totalItems > itemsScanned then
            local remainingItems = totalItems - itemsScanned
            local remainingSeconds = remainingItems / itemsPerSecond
            eta = secondsToTime(remainingSeconds)
        elseif totalItems <= itemsScanned then
            eta = "Almost done..."
        end
    end
    local etaText = getglobal("ZTAProgressFrameProgressTextETA")
    if etaText then
        etaText:SetText("Time remaining: " .. eta)
    end
end

local function processCurrentPage()
    local numBatchAuctions, totalAuctions = GetNumAuctionItems("list")
    
    if numBatchAuctions > 0 then
        for i = 1, numBatchAuctions do
            local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)
            
            if name and owner then
                -- Store auction data
                local auctionData = {
                    name = name,
                    texture = texture,
                    count = count,
                    quality = quality,
                    level = level,
                    minBid = minBid,
                    buyoutPrice = buyoutPrice,
                    bidAmount = bidAmount,
                    owner = owner,
                    timeScanned = time()
                }
                
                table.insert(scanData, auctionData)
                itemsScanned = itemsScanned + 1
            end
        end
        
        totalItems = totalAuctions
        updateProgress()
    end
end

local function canSendAuctionQuery()
    -- Custom query control during scanning
    if scanInProgress then
        local numBatchAuctions, totalAuctions = GetNumAuctionItems("list")
        
        -- Wait for all auction data to load completely
        if totalAuctions > 0 then
            local allDataLoaded = true
            for i = 1, numBatchAuctions do
                local name, texture, count, quality, canUse, level, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", i)
                if not owner then
                    allDataLoaded = false
                    break
                end
            end
            
            if allDataLoaded then
                processCurrentPage()
                
                -- Calculate total pages (NUM_AUCTION_ITEMS_PER_PAGE is usually 50 in Vanilla)
                local itemsPerPage = NUM_AUCTION_ITEMS_PER_PAGE or 50
                totalPages = math.ceil(totalAuctions / itemsPerPage)
                
                -- Move to next page if available
                if currentPage < totalPages - 1 then
                    currentPage = currentPage + 1
                    QueryAuctionItems("", "", "", nil, nil, nil, currentPage, nil, nil)
                    return false -- Don't allow other queries yet
                else
                    -- Scan complete
                    local scanRecord = {
                        timestamp = time(),
                        itemCount = itemsScanned,
                        scanTime = GetTime() - scanStartTime,
                        data = scanData
                    }
                    
                    table.insert(ZTA_DB.scanHistory, scanRecord)
                    
                    -- Keep only last 10 scans to manage memory
                    while getn(ZTA_DB.scanHistory) > 10 do
                        table.remove(ZTA_DB.scanHistory, 1)
                    end
                    
                    ZTA_Print("Scan completed! Found " .. itemsScanned .. " auction items. Data saved to database.")
                    
                    -- Stop scan
                    scanInProgress = false
                    scanStartTime = nil
                    currentPage = 0
                    totalPages = 0
                    
                    -- Restore original function
                    if originalCanSendAuctionQuery then
                        CanSendAuctionQuery = originalCanSendAuctionQuery
                        originalCanSendAuctionQuery = nil
                    end
                    
                    -- Reset icon and hide progress window
                    getglobal("ZTAIconText"):SetText(ICON_STATE_IDLE)
                    getglobal("ZTAProgressFrame"):Hide()
                    
                    return originalCanSendAuctionQuery()
                end
            end
        end
        
        return false -- Block other queries during scan
    end
    
    return originalCanSendAuctionQuery()
end

local function onEvent()
    if event == "ADDON_LOADED" and arg1 == "zta" then
        -- Addon has loaded, initialize saved variables
        if not ZTA_DB then
            ZTA_DB = {
                iconPosition = { point = "TOPRIGHT", x = -50, y = -150 },
                scanHistory = {}
            }
        end
        
        -- Restore icon position
        if ZTA_DB.iconPosition then
            local pos = ZTA_DB.iconPosition
            local icon = getglobal("ZTAIcon")
            if icon then
                icon:ClearAllPoints()
                icon:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
            end
        end
        
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- Player closed auction house, stop any active scan
        if scanInProgress then
            ZTA_Print("Auction scan cancelled.")
            scanInProgress = false
            scanStartTime = nil
            currentPage = 0
            totalPages = 0
            
            -- Restore original function
            if originalCanSendAuctionQuery then
                CanSendAuctionQuery = originalCanSendAuctionQuery
                originalCanSendAuctionQuery = nil
            end
            
            -- Reset icon and hide progress window
            getglobal("ZTAIconText"):SetText(ICON_STATE_IDLE)
            getglobal("ZTAProgressFrame"):Hide()
        end
        
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        -- New auction data received - processing handled in canSendAuctionQuery hook
    end
end

-- ============================================================================
-- GLOBAL XML-CALLED FUNCTIONS (redefining the stubs)
-- ============================================================================

function ZTA_Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ZTA]|r " .. msg)
    end
end

function ZTA_OnLoad()
    -- Get the icon frame directly
    local icon = getglobal("ZTAIcon")
    if not icon then
        ZTA_Print("ERROR: Could not find ZTAIcon frame")
        return
    end
    
    -- Initialize the addon  
    icon:RegisterForDrag("LeftButton")
    icon:SetMovable(true)
    icon:EnableMouse(true)
    
    -- Set initial icon state
    local iconText = getglobal("ZTAIconText")
    if iconText then
        iconText:SetText(ICON_STATE_IDLE)
    end
    
    ZTA_Print("ZTA loaded. Click the $ icon at an auctioneer to start scanning.")
end

function ZTA_OnClick()
    if scanInProgress then
        -- Currently scanning, this acts as cancel
        ZTA_Print("Auction scan cancelled.")
        scanInProgress = false
        scanStartTime = nil
        currentPage = 0
        totalPages = 0
        
        -- Restore original function
        if originalCanSendAuctionQuery then
            CanSendAuctionQuery = originalCanSendAuctionQuery
            originalCanSendAuctionQuery = nil
        end
        
        -- Reset icon and hide progress window
        getglobal("ZTAIconText"):SetText(ICON_STATE_IDLE)
        getglobal("ZTAProgressFrame"):Hide()
    else
        -- Try to start a scan
        -- Check if we can start a scan
        if not AuctionFrame or not AuctionFrame:IsVisible() then
            ZTA_Print("You must be at an auctioneer to start scanning.")
            return
        end
        
        if not CanSendAuctionQuery or not CanSendAuctionQuery() then
            ZTA_Print("Cannot query auction house at this time. Please wait and try again.")
            return
        end
        
        -- Initialize scanning
        scanInProgress = true
        scanStartTime = GetTime()
        currentPage = 0
        totalPages = 0
        itemsScanned = 0
        totalItems = 0
        scanData = {}
        
        -- Update icon state
        getglobal("ZTAIconText"):SetText(ICON_STATE_LOADING)
        
        -- Show progress window
        getglobal("ZTAProgressFrame"):Show()
        updateProgress()
        
        -- Hook CanSendAuctionQuery to control scan timing
        if not originalCanSendAuctionQuery then
            originalCanSendAuctionQuery = CanSendAuctionQuery
            CanSendAuctionQuery = canSendAuctionQuery
        end
        
        ZTA_Print("Starting auction house scan...")
        
        -- Start the scan with a full query (getAll = true)
        QueryAuctionItems("", "", "", nil, nil, nil, 0, nil, nil)
        getglobal("ZTAIconText"):SetText(ICON_STATE_SCANNING)
    end
end

function ZTA_ShowTooltip()
    local icon = getglobal("ZTAIcon")
    if not icon then return end
    
    GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    
    if scanInProgress then
        GameTooltip:AddLine("ZTA Scanner", 1, 1, 1)
        GameTooltip:AddLine("Click to cancel scan", 0.8, 0.8, 0.8)
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine("Items scanned: " .. itemsScanned, 0.8, 0.8, 0.8)
        if totalItems > 0 then
            local percent = math.floor((itemsScanned / totalItems) * 100)
            GameTooltip:AddLine("Progress: " .. percent .. "%", 0.8, 0.8, 0.8)
        end
    else
        GameTooltip:AddLine("ZTA Scanner", 1, 1, 1)
        if AuctionFrame and AuctionFrame:IsVisible() then
            GameTooltip:AddLine("Click to start auction scan", 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine("Visit an auctioneer to scan", 0.8, 0.8, 0.8)
        end
        GameTooltip:AddLine("Drag to move", 0.6, 0.6, 0.6)
        
        -- Show scan history info
        local historyCount = 0
        if ZTA_DB and ZTA_DB.scanHistory then
            historyCount = getn(ZTA_DB.scanHistory)
        end
        if historyCount > 0 then
            GameTooltip:AddLine(" ", 1, 1, 1)
            GameTooltip:AddLine("Scans in database: " .. historyCount, 0.6, 0.6, 0.6)
        end
    end
    
    GameTooltip:Show()
end

function ZTA_SavePosition()
    local icon = getglobal("ZTAIcon")
    if icon and ZTA_DB then
        local point, _, _, x, y = icon:GetPoint()
        ZTA_DB.iconPosition = { point = point, x = x, y = y }
    end
end

function ZTA_OnDragStart()
    local icon = getglobal("ZTAIcon")
    if icon then
        icon:StartMoving()
    end
end

function ZTA_OnDragStop()
    local icon = getglobal("ZTAIcon")
    if icon then
        icon:StopMovingOrSizing()
        ZTA_SavePosition()
    end
end

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

SLASH_ZTA1 = "/zta"

function SlashCmdList.ZTA(msg)
    msg = string.lower(msg or "")
    
    if msg == "scan" then
        ZTA_OnClick() -- Reuse the click logic
    elseif msg == "cancel" or msg == "stop" then
        if scanInProgress then
            ZTA_OnClick() -- Reuse the click logic for cancel
        else
            ZTA_Print("No scan in progress.")
        end
    elseif msg == "clear" then
        ZTA_DB.scanHistory = {}
        ZTA_Print("Scan history cleared.")
    elseif msg == "stats" then
        local historyCount = getn(ZTA_DB.scanHistory)
        local totalScannedItems = 0
        for i = 1, historyCount do
            totalScannedItems = totalScannedItems + ZTA_DB.scanHistory[i].itemCount
        end
        ZTA_Print("Database contains " .. historyCount .. " scans with " .. totalScannedItems .. " total items.")
    else
        ZTA_Print("Commands:")
        ZTA_Print("  /zta scan - Start auction scan")
        ZTA_Print("  /zta cancel - Cancel current scan") 
        ZTA_Print("  /zta stats - Show database statistics")
        ZTA_Print("  /zta clear - Clear scan history")
    end
end

-- ============================================================================
-- EVENT REGISTRATION
-- ============================================================================

-- Register the main frame for events
local frame = CreateFrame("Frame", "ZTAFrame")
frame:SetScript("OnEvent", onEvent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
