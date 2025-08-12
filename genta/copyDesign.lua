
local delayPut = 300
local delayTp = 400

local os = require("os")
local BUILD_THREAD_LABEL = "DesignBuilderThread"
_G.isPaused = false

-- Load Dialog Builder Ihkaz
local ihkaz_loader_code, err = makeRequest("https://raw.githubusercontent.com/ihkaz/GT-Dialog-Builder-in-lua/refs/heads/main/DialogBuilder.lua", "GET")
if not ihkaz_loader_code or not ihkaz_loader_code.content or ihkaz_loader_code.content == "" then
    logToConsole("`4FATAL ERROR: `oCould not load Ihkaz Dialog Builder from GitHub!")
    return
end
local ihkaz, err = load(ihkaz_loader_code.content)
if not ihkaz then
    logToConsole("`4FATAL ERROR: `oFailed to execute Ihkaz Dialog Builder code: " .. tostring(err))
    return
end
ihkaz = ihkaz()
logToConsole("`2Ihkaz Dialog Builder loaded successfully.")
_G.deleteDialogState = { worldName = "", itemMap = {} }

function getDir(path)
  local Dir = io.open(path, "r")
  if Dir then Dir:close(); return true else return false end
end

function isThreadRunning(threadLabel)
    for _, id in ipairs(getThreadsID()) do
        if id == threadLabel then return true end
    end
    return false
end

function split(s, delimiter)
    local result = {}
    delimiter = delimiter:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    local pattern = "([^"..delimiter.."]*)"
    for match in s:gmatch(pattern) do
        table.insert(result, match)
    end
    return result
end

function getItemCount(targetItemID)
    for _, item in ipairs(getInventory()) do
        if item.id == targetItemID then return item.amount end
    end
    return 0
end

function getDesignList()
    local listFilePath = "/storage/emulated/0/android/media/GENTAHAX/design/list_design.txt"
    local file = io.open(listFilePath, "r")
    if not file then
        return logToConsole("`4Error: `oFile `2list_design.txt`o not found.")
    end
    
    local content = file:read("*all")
    file:close()
    
    local worlds = split(content, "\n")

    local dialog = ihkaz.new()
    dialog:setbody({
        bg = {25, 25, 25, 240},
        border = {150, 150, 150, 200},
        textcolor = "`o"
    })
    
    dialog:addlabel(true, {
        label = "`2Saved Designs",
        size = "big",
        id = 6016 -- Item ID untuk ikon (misal: GrowScan 9000)
    })
    dialog:addspacer("small")

    -- Memeriksa apakah ada desain yang tersimpan
    local hasDesigns = false
    local worldLabels = {}
    for _, name in ipairs(worlds) do
        if name ~= "" then
            table.insert(worldLabels, {label = "`2" .. name, id = 3802}) -- Item ID untuk ikon (misal: Globe)
            hasDesigns = true
        end
    end

    if hasDesigns then
        dialog:addlabel(true, worldLabels)
    else
        dialog:addlabel(false, {label = "`oNo designs saved yet."})
    end

    dialog:addspacer("small")
    dialog:addlabel(false, {
        label = "`oUse these names with: `6/check `oor `6/design`o."
    })
    dialog:setDialog({
        name = "design_list",
        closelabel = "Close"
    })
    
    dialog:showdialog()
end

function hasBuildAccess()
    local myUserID = getLocal().userId
    for _, tile in ipairs(getTile()) do
--        if tile.getFlags.locked then
            local extra = getExtraTile(tile.pos.x, tile.pos.y)
            if extra and extra.valid and extra.type == 3 then
                if extra.owner == myUserID then return true end
                for _, adminID in ipairs(extra.adminList) do
                    if adminID == myUserID then return true end
                end
                return false
            end
        end
--    end
    return true
end

function parse_paint(flags)
    local color_mapping = {[0]=nil,[1]=3478,[2]=3482,[3]=3480,[4]=3486,[5]=3488,[6]=3484,[7]=3490}
    return color_mapping[(flags >> 13) & 7] or nil
end

function calculateDistance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1)^2 + (y2 - y1)^2)
end

function findPathToPlace(targetX, targetY)
    local p = getLocal()
    if not p then return false end
    local startX, startY = p.pos.x, p.pos.y
    local adjacentSpots = {{1,0},{-1,0},{0,1},{0,-1},{2,0},{-2,0},{0,2},{-2,0}}
    local bestSpot, minDistance = nil, 9999
    for _, spot in ipairs(adjacentSpots) do
        local standX, standY = targetX + spot[1], targetY + spot[2]
        local tile = checkTile(standX, standY)
        if tile and tile.fg == 0 then
            local dist = calculateDistance(startX, startY, standX, standY)
            if dist < minDistance then
                minDistance = dist; bestSpot = {x = standX, y = standY}
            end
        end
    end
    if not bestSpot then logToConsole("`4Path Error: `oNo empty spot found."); return false end
    if findPath(bestSpot.x, bestSpot.y) then return true else logToConsole("`4Path Error: `oPath is blocked."); return false end
end

function stopDesign()
    if isThreadRunning(BUILD_THREAD_LABEL) then
        killThread(BUILD_THREAD_LABEL); _G.isPaused = false
        logToConsole("`4Design construction forcibly stopped.")
        doToast(3, 3000, "Build process stopped!")
    else
        logToConsole("`oNo build process is currently running.")
    end
end

function pauseDesign()
    if isThreadRunning(BUILD_THREAD_LABEL) then
        _G.isPaused = true; logToConsole("`6Build process paused."); doToast(1, 2000, "Build Paused")
    else
        logToConsole("`4Error: `oNo build process is running to pause.")
    end
end

function resumeDesign()
    if _G.isPaused then
        _G.isPaused = false; logToConsole("`2Build process resumed."); doToast(1, 2000, "Build Resumed")
    else
        logToConsole("`4Error: `oBuild is not currently paused.")
    end
end

local function buildDesign(worldName)
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
    local file = io.open(filePath, "r"); if not file then return end
    local lines = split(file:read("*all"), "\n"); file:close()
    logToConsole("`2Starting construction for world: `o" .. worldName)
    for i, line in ipairs(lines) do
        local hasNotifiedPause = false
        while _G.isPaused do
            if not hasNotifiedPause then logToConsole("`6Build is paused..."); hasNotifiedPause = true end; sleep(1000)
        end
        if hasNotifiedPause then logToConsole("`2Resuming...") end
        if line ~= "" then
            local parts = split(line, "|")
            local itemID, x, y = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
            if itemID and x and y then
                local itemInfo = getItemByID(itemID); local existingTile = checkTile(x, y)
                local extraTi = getExtraTile(x, y)
                local isForegroundBlock = (itemInfo.collisionType > 0)
                if (isForegroundBlock and existingTile.fg == itemID) or (not isForegroundBlock and existingTile.bg == itemID) or (extraTi.valid and (extraTi.glue or extraTi.water or parse_paint(existingTile.flag))) then goto continue end
                local hasNotified = false
                while getItemCount(itemID) < 1 do
                    if not hasNotified then
                        logToConsole("`4Build paused. `oOut of material: `2"..itemInfo.name); doToast(2, 3000, "Out of Material: " .. itemInfo.name); hasNotified = true; _G.isPaused = true
                    end; sleep(2500)
                end
                if hasNotified then logToConsole("`2Material detected! `oResuming construction...") end
                if findPathToPlace(x, y) then
                    sleep(300); sleep(delayPut); requestTileChange(x, y, itemID)
                    local placement_confirmed = false; local timeSpent = 0; local timeout = 3000
                    while timeSpent < timeout do
                        local updatedTile = checkTile(x, y)
                        local extraT = getExtraTile(x, y)
                        if (isForegroundBlock and updatedTile.fg == itemID) or (not isForegroundBlock and updatedTile.bg == itemID) or (extraT.valid and (extraT.glue or extraT.water or parse_paint(updatedTile.flag))) then
                            placement_confirmed = true; break 
                        end
                        sleep(100); timeSpent = timeSpent + 100
                    end
                    if placement_confirmed then
                        sleep(delayTp)
                        local remainingContent = ""
                        for j = i + 1, #lines do if lines[j] ~= "" then remainingContent = remainingContent .. lines[j] .. "\n" end end
                        local fileToWrite = io.open(filePath, "w"); if fileToWrite then fileToWrite:write(remainingContent); fileToWrite:close() end
                    else
                        logToConsole("`4Warning: `oTile update timeout at ("..x..", "..y.."). Will retry.")
                    end
                else
                    logToConsole("`4Skipping: `oCould not find path to place block at ("..x..", "..y..")")
                end
            end
        end
        ::continue::
    end
    local fileCheck = io.open(filePath, "r")
    if fileCheck then
        local content = fileCheck:read("*a"); fileCheck:close()
        if content == "" then os.remove(filePath); logToConsole("`2Design finished! File removed."); doToast(1, 4000, "Construction Finished!")
        else logToConsole("`2Design stopped. Rerun to continue."); doToast(1, 4000, "Construction Stopped!") end
    else
        logToConsole("`2Design finished! File removed."); doToast(1, 4000, "Construction Finished!")
    end
end

function startDesign(worldName)
    if isThreadRunning(BUILD_THREAD_LABEL) then killThread(BUILD_THREAD_LABEL) end; _G.isPaused = false
    if not hasBuildAccess() then doToast(3, 4000, "Access denied!"); return end
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
    if not io.open(filePath, "r") then logToConsole("`4Error: `oDesign file not found."); return end
    runThread(function() buildDesign(worldName) end, BUILD_THREAD_LABEL)
    logToConsole("`2Access confirmed. `oBuild process starting...")
end

function copy()
  local name = getWorld().name
  local folderPath = "/storage/emulated/0/android/media/GENTAHAX/design/"
  if not getDir(folderPath) then os.execute("mkdir -p "..folderPath) end
  local file = io.open(folderPath..name:upper()..".txt", "w")
  if not file then return logToConsole("`4Failed to create file.") end
  
  local output = ""
  for _, tile in ipairs(getTile()) do
    if tile.fg ~= 0 and tile.fg ~= 8 and tile.fg ~= 6 and tile.fg ~= 242 and tile.fg ~= 3760 then
      output = output .. string.format("%d|%d|%d", tile.fg, tile.pos.x, tile.pos.y) .. "\n"
    end
    if tile.bg ~= 0 then output = output .. string.format("%d|%d|%d", tile.bg, tile.pos.x, tile.pos.y) .. "\n" end
    if tile.getFlags.water then output = output .. string.format("%d|%d|%d", 822, tile.pos.x, tile.pos.y) .. "\n" end
    if tile.getFlags.glue then output = output .. string.format("%d|%d|%d", 1866, tile.pos.x, tile.pos.y) .. "\n" end
    local paint = parse_paint(tile.flags)
    if paint then output = output .. string.format("%d|%d|%d", paint, tile.pos.x, tile.pos.y) .. "\n" end
  end
  file:write(output); file:close()

  local listFile = io.open(folderPath.."list_design.txt", "r")
  local content = ""; if listFile then content = listFile:read("*a"); listFile:close() end
  if not content:find(name:upper(), 1, true) then
    listFile = io.open(folderPath.."list_design.txt", "a")
    if listFile then listFile:write(name.."\n"); listFile:close() end
  end
  logToConsole("`2Success! `oWorld design `2"..name.."`o copied.")
end

function check(worldName)
  local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
  local file = io.open(filePath, "r")
  if not file then return logToConsole("`4Error: `oDesign file not found.") end
  local content = file:read("*all"); file:close()
  local amount, labels = {}, {}
  for part in content:gmatch("([^\n]+)") do
    local itemID = tonumber(part:match("([^|]+)"))
    if itemID then amount[itemID] = (amount[itemID] or 0) + 1 end
  end
  for itemID, count in pairs(amount) do
    table.insert(labels, {label=string.format("`o%dx `2%s", count, getItemByID(itemID).name), id=itemID})
  end
  local dialog = ihkaz.new()
  dialog:setbody({bg={25,25,25,240}, border={150,150,150,200}, textcolor="`o", quickexit=true})
  dialog:addlabel(true, {label="`2Materials for `o"..worldName:upper(), size="big", id=6016})
  dialog:addspacer("small"):addlabel(true, labels)
  dialog:setDialog({name="check_dialog", closelabel="Close"})
  dialog:showdialog()
end

function help()
    local dialog = ihkaz.new()
    dialog:setbody({bg={25,25,25,240}, border={150,150,150,200}, textcolor="`o", quickexit=true})
    dialog:addlabel(true, {label="`4Copy & Design Help", size="big", id=3802})
    dialog:addspacer("small"):addlabel(true, {label="`4Author: `3Raaffly", size="small", id=1752})
    dialog:addspacer("big"):addlabel(true, {label="`9Commands:", size="small", id=32})
    dialog:addspacer("small")
    local commands = {
        {"/copy", "Copies the current world design."}, {"/check <world>", "Checks materials."},
        {"/design <world>", "Starts building a design."}, {"/list", "Shows all saved designs."},
        {"/stop", "Stops the build process."}, {"/pause", "Pauses the current build."},
        {"/resume", "Resumes a paused build."}, {"/delete <world>", "Opens a dialog to delete items."}, {"/deletedesign", "Delete the copied world"},
        {"/help", "Shows this help dialog."}
    }
    for _, cmd in ipairs(commands) do
        dialog:addlabel(true, {label=string.format("`6%s `o- %s", cmd[1], cmd[2]), id=2412})
    end
    dialog:setDialog({name="help_dialog", closelabel="Close"})
    dialog:showdialog()
end

function deleteDialog(worldName)
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
    local file = io.open(filePath, "r")
    if not file then return logToConsole("`4Error: `oDesign file not found.") end
    local content = file:read("*all"); file:close()
    local uniqueItems, itemCounts = {}, {}
    for part in content:gmatch("([^\n]+)") do
        local itemID = tonumber(part:match("([^|]+)"))
        if itemID then
            if not uniqueItems[itemID] then uniqueItems[itemID] = getItemByID(itemID).name end
            itemCounts[itemID] = (itemCounts[itemID] or 0) + 1
        end
    end
    _G.deleteDialogState = {worldName = worldName, itemMap = {}}
    local dialog = ihkaz.new()
    dialog:setbody({bg = {25, 25, 25, 240}, border = {150, 150, 150, 200}, textcolor = "`o"})
    dialog:addlabel(true, {label = "`4Delete Items from `5"..worldName:upper(), size = "big", id = 1866})
    dialog:addspacer("small"):addlabel(false, {label = "`oSelect items to delete:", size = "small"})
    local itemCount = 0
    for id, name in pairs(uniqueItems) do
        local checkboxName = "delete_item_" .. id
        dialog:_append(string.format("add_checkbox|%s|`o%d`4x `o%s|0|", checkboxName, itemCounts[id], name))
        _G.deleteDialogState.itemMap[checkboxName] = id
        itemCount = itemCount + 1
    end
    if itemCount == 0 then dialog:addlabel(false, {label = "`oThis design file is empty."}) end
    dialog:addspacer("small"):setDialog({name = "delete_items_dialog", closelabel = "Cancel", applylabel = "Delete Selected"})
    dialog:showdialog()
end

function deleteDesign(worldName)
    local folderPath = "/storage/emulated/0/android/media/GENTAHAX/design/"
    local designFilePath = folderPath .. worldName:upper() .. ".txt"
    local listFilePath = folderPath .. "list_design.txt"

    local designFile = io.open(designFilePath, "r")
    if designFile then
        designFile:close()
        os.remove(designFilePath)
        logToConsole("`2File desain `o" .. worldName:upper() .. ".txt `2berhasil dihapus.")
    else
        logToConsole("`6Info: `oFile desain `4" .. worldName:upper() .. ".txt `otidak ditemukan.")
    end

    local listFile = io.open(listFilePath, "r")
    if not listFile then
        logToConsole("`6Info: `oFile `4list_design.txt`o tidak ditemukan, tidak ada yang perlu diubah.")
        doToast(1, 3000, "Design " .. worldName .. " deleted.")
        return
    end

    local lines = split(listFile:read("*all"), "\n")
    listFile:close()

    local newLines = {}
    local nameRemoved = false
    for _, name in ipairs(lines) do
        if name:upper() ~= worldName:upper() and name ~= "" then
            table.insert(newLines, name)
        else
            if name:upper() == worldName:upper() then
                nameRemoved = true
            end
        end
    end
    
    local fileToWrite = io.open(listFilePath, "w")
    if fileToWrite then
        fileToWrite:write(table.concat(newLines, "\n") .. "\n")
        fileToWrite:close()
        if nameRemoved then
            logToConsole("`2Nama dunia `o" .. worldName:upper() .. "`2 berhasil dihapus dari daftar.")
        end
    else
        logToConsole("`4Error: `oGagal menulis ulang `2list_design.txt`o.")
    end

    doToast(1, 3000, "Design " .. worldName .. " deleted.")
end

local function commandHook(type, pkt)
  if pkt:find("action|dialog_return") then
      local lines = split(pkt, "\n"); local dialogData = {}
      for _, line in ipairs(lines) do
          local parts = split(line, "|"); if parts[1] and parts[2] then dialogData[parts[1]] = parts[2] end
      end
      if dialogData["dialog_name"] == "delete_items_dialog" then
          local worldName = _G.deleteDialogState.worldName; local itemsToDelete = {}
          for key, value in pairs(dialogData) do
              if key:find("delete_item_") and value == "1" then
                  doLog(key..": "..value)
                  local itemID = key:gsub("delete_item_", ""); if itemID then table.insert(itemsToDelete, tonumber(itemID)) end
              end
          end
          if #itemsToDelete > 0 then
              local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
              local file = io.open(filePath, "r"); if not file then return true end
              local fileLines = split(file:read("*all"), "\n"); file:close()
              local newContent = ""; local itemsDeletedCount = 0
              for _, line in ipairs(fileLines) do
                  if line ~= "" then
                      local itemIDInLine = tonumber(line:match("([^|]+)")); local shouldKeep = true
                      for _, idToDelete in ipairs(itemsToDelete) do
                          if itemIDInLine == idToDelete then shouldKeep = false; itemsDeletedCount = itemsDeletedCount + 1; break end
                      end
                      if shouldKeep then newContent = newContent .. line .. "\n" end
                  end
              end
              local fileToWrite = io.open(filePath, "w"); if not fileToWrite then return true end
              fileToWrite:write(newContent); fileToWrite:close()
              logToConsole("`2Success! `oDeleted `4"..itemsDeletedCount.."`o blocks from `4"..worldName.."`o.")
              doToast(1, 3000, "Items deleted from " .. worldName)
          else
              logToConsole("`oNo items selected for deletion.")
          end
          return true
      end
  end
  if pkt:find("action|input\n|text|/") then
    local text = pkt:gsub("action|input\n|text|", ""); local parts = split(text, " ")
    local command = parts[1]; local worldName = parts[2]
    local itemName = ""; if #parts > 2 then itemName = table.concat(parts, " ", 3) end
    if command == "/copy" then copy(); return true
    elseif command == "/check" then
      if not worldName then logToConsole("`4Usage: `o/check <world_name>"); return true end; check(worldName); return true
    elseif command == "/design" then
      if not worldName then logToConsole("`4Usage: `o/design <world_name>"); return true end; startDesign(worldName); return true
    elseif command == "/list" then getDesignList(); return true
    elseif command == "/stop" then stopDesign(); return true
    elseif command == "/pause" then pauseDesign(); return true
    elseif command == "/resume" then resumeDesign(); return true
    elseif command == "/delete" then
        if not worldName then logToConsole("`4Usage: `o/delete <world_name>"); return true end
        deleteDialog(worldName); return true
    elseif command == "/deletedesign" then if not worldName then logToConsole("`4 Usage: `o/delete <world_name>") return true end
    deleteDesign(worldName); return true
    elseif command == "/help" then help(); return true
    end
  end
end

AddHook("OnTextPacket", "kntlkuda", commandHook)

















