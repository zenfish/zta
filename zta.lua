--[[
    ZTA - A lightweight auction house scanner for WoW Vanilla
    Features:
    - Moveable circular icon with $ symbols
    - Progress tracking with status window
    - Persistent data storage
    - Cancel functionality
    - Based on techniques from Auctioneer addon by Norganna's AddOns
]]

-- Addon namespace
ZTA = {}

-- Local variables for scanning state
local scanInProgress = false
local scanStartTime = nil
local currentPage = 0
local totalPages = 0
local itemsScanned = 0
local totalItems = 0
local scanData = {}

-- Saved variables (will be loaded from SavedVariables)
ZTA_DB = ZTA_DB or {
    iconPosition = { point = "CENTER", x = 0, y = 100 },
    scanHistory = {}
}

-- Icon states
local ICON_STATE_IDLE = "$"
local ICON_STATE_LOADING = "..."
local ICON_STATE_SCANNING = "X"

-- Hook variables for original functions
local originalCanSendAuctionQuery = nil

-- UI Functions (must be defined before XML calls them)
function ZTA_Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[ZTA]|r " .. msg)
    end
end

function ZTA_ShowTooltip()
    GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
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
        local historyCount = getn(ZTA_DB.scanHistory)
        if historyCount > 0 then
            GameTooltip:AddLine(" ", 1, 1, 1)
            GameTooltip:AddLine("Scans in database: " .. historyCount, 0.6, 0.6, 0.6)
        end
    end
    
    GameTooltip:Show()
end

function ZTA_SavePosition()
    local icon = getglobal("ZTAIcon")
    if icon then
        local point, _, _, x, y = icon:GetPoint()
        ZTA_DB.iconPosition = { point = point, x = x, y = y }
    end
end

function ZTA_OnClick()
    if scanInProgress then
        -- Currently scanning, this acts as cancel
        ZTA_CancelScan()
    else
        -- Try to start a scan
        ZTA_StartScan()
    end
end

function ZTA_CancelScan()
    ZTA_Print("Auction scan cancelled.")
    ZTA_StopScan()
end

function ZTA_OnLoad()
    -- Initialize the addon  
    this:RegisterForDrag("LeftButton")
    this:SetMovable(true)
    this:EnableMouse(true)
    
    -- Set initial icon state
    getglobal(this:GetName().."Text"):SetText(ICON_STATE_IDLE)
    
    -- Restore position if available
    ZTA_RestorePosition()
    
    ZTA_Print("ZTA loaded. Click the $ icon at an auctioneer to start scanning.")
end

function ZTA_OnEvent()
    if event == "ADDON_LOADED" and arg1 == "zta" then
        -- Addon has loaded, initialize saved variables
        if not ZTA_DB then
            ZTA_DB = {
                iconPosition = { point = "CENTER", x = 0, y = 100 },
                scanHistory = {}
            }
        end
        ZTA_RestorePosition()
        
    elseif event == "AUCTION_HOUSE_SHOW" then
        -- Player opened auction house
        
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- Player closed auction house, stop any active scan
        if scanInProgress then
            ZTA_StopScan()
        end
        
    elseif event == "AUCTION_ITEM_LIST_UPDATE" then
        -- New auction data received
        if scanInProgress then
            ZTA_ProcessAuctionData()
        end
    end
end

function ZTA_OnClick()
    if scanInProgress then
        -- Currently scanning, this acts as cancel
        ZTA_CancelScan()
    else
        -- Try to start a scan
        ZTA_StartScan()
    end
end

function ZTA_StartScan()
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
    ZTA_UpdateProgress()
    
    -- Hook CanSendAuctionQuery to control scan timing
    if not originalCanSendAuctionQuery then
        originalCanSendAuctionQuery = CanSendAuctionQuery
        CanSendAuctionQuery = ZTA_CanSendAuctionQuery
    end
    
    ZTA_Print("Starting auction house scan...")
    
    -- Start the scan with a full query (getAll = true)
    QueryAuctionItems("", "", "", nil, nil, nil, 0, nil, nil)
    getglobal("ZTAIconText"):SetText(ICON_STATE_SCANNING)
end

function ZTA_CanSendAuctionQuery()
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
                ZTA_ProcessCurrentPage()
                
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
                    ZTA_CompleteScan()
                    return originalCanSendAuctionQuery()
                end
            end
        end
        
        return false -- Block other queries during scan
    end
    
    return originalCanSendAuctionQuery()
end

function ZTA_ProcessCurrentPage()
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
        ZTA_UpdateProgress()
    end
end

function ZTA_ProcessAuctionData()
    -- This is called when AUCTION_ITEM_LIST_UPDATE fires
    -- The actual processing is handled in CanSendAuctionQuery hook
end

function ZTA_UpdateProgress()
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
            eta = ZTA_SecondsToTime(remainingSeconds)
        elseif totalItems <= itemsScanned then
            eta = "Almost done..."
        end
    end
    local etaText = getglobal("ZTAProgressFrameProgressTextETA")
    if etaText then
        etaText:SetText("Time remaining: " .. eta)
    end
end

function ZTA_SecondsToTime(seconds)
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

function ZTA_CompleteScan()
    -- Scan completed successfully
    ZTA_StopScan()
    
    -- Save scan data to database
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
end

function ZTA_CancelScan()
    ZTA_Print("Auction scan cancelled.")
    ZTA_StopScan()
end

function ZTA_StopScan()
    scanInProgress = false
    scanStartTime = nil
    currentPage = 0
    totalPages = 0
    
    -- Restore original function
    if originalCanSendAuctionQuery then
        CanSendAuctionQuery = originalCanSendAuctionQuery
        originalCanSendAuctionQuery = nil
    end
    
    -- Reset icon
    getglobal("ZTAIconText"):SetText(ICON_STATE_IDLE)
    
    -- Hide progress window
    getglobal("ZTAProgressFrame"):Hide()
end

function ZTA_RestorePosition()
    if ZTA_DB.iconPosition then
        local pos = ZTA_DB.iconPosition
        local icon = getglobal("ZTAIcon")
        if icon then
            icon:ClearAllPoints()
            icon:SetPoint(pos.point, UIParent, pos.point, pos.x, pos.y)
        end
    end
end

-- Slash command support
SLASH_ZTA1 = "/zta"

function SlashCmdList.ZTA(msg)
    msg = string.lower(msg or "")
    
    if msg == "scan" then
        ZTA_StartScan()
    elseif msg == "cancel" or msg == "stop" then
        ZTA_CancelScan()
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

-- Register the main frame for events
local frame = CreateFrame("Frame", "ZTAFrame")
frame:SetScript("OnEvent", ZTA_OnEvent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")