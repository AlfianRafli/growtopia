local delayPut = 300
local delayTp = 400

local os = require("os")
local BUILD_THREAD_LABEL = "DesignBuilderThread"
_G.isPaused = false -- Variabel global untuk status pause

function getDir(path)
  local Dir = io.open(path, "r")
  if Dir then
    Dir:close()
    return true
  else
    return false
  end
end

function isThreadRunning(threadLabel)
    for _, id in ipairs(getThreadsID()) do
        if id == threadLabel then
            return true
        end
    end
    return false
end

function parse_paint(flags)
    local color_mapping = {
        [0] = nil, -- Varnish
        [1] = 3478, -- Red
        [2] = 3482, -- Green
        [3] = 3480, -- Yellow
        [4] = 3486, -- Blue
        [5] = 3488, -- Purple
        [6] = 3484, -- Aqua
        [7] = 3490 -- Charcoal
    }
    local color_bits = (flags >> 13) & 7

    return color_mapping[color_bits] or nil
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

function findItemID(itemName)
    local itemsFilePath = "/storage/emulated/0/android/media/GENTAHAX/items.txt"
    local file = io.open(itemsFilePath, "r")
    if not file then
        logToConsole("`4Error: `oitems.txt not found!")
        return nil
    end

    local searchName = itemName:lower()
    for line in file:lines() do
        local parts = split(line, "|")
        if #parts == 2 then
            local id = tonumber(parts[1])
            local nameInFile = parts[2]:lower()
            if nameInFile == searchName then
                file:close()
                return id
            end
        end
    end

    file:close()
    return nil
end

function getItemCount(targetItemID)
    for _, item in ipairs(getInventory()) do
        if item.id == targetItemID then
            return item.amount
        end
    end
    return 0
end

function hasBuildAccess()
    local myUserID = getLocal().userId
    local worldIsLocked = false
    
    for _, tile in ipairs(getTile()) do
        if tile.getFlags.locked then
            worldIsLocked = true
            local extra = getExtraTile(tile.pos.x, tile.pos.y)
            if extra and extra.valid and extra.type == 3 then
                if extra.owner == myUserID then return true end
                for _, adminID in ipairs(extra.adminList) do
                    if adminID == myUserID then return true end
                end
            end
        end
    end
    if worldIsLocked then return false end
    return true
end

function getDesignList()
    local listFilePath = "/storage/emulated/0/android/media/GENTAHAX/design/list_design.txt"
    local file = io.open(listFilePath, "r")
    if not file then return logToConsole("`4Error: `oFile `2list_design.txt`o not found.") end
    
    local content = file:read("*all")
    file:close()
    
    local worldListText = ""
    local worlds = split(content, "\n")
    for _, name in ipairs(worlds) do
        if name ~= "" then
            worldListText = worldListText .. "add_textbox|`2"..name.."|left|\n"
        end
    end

    if worldListText == "" then
        worldListText = "add_textbox|`oNo designs saved yet.|left|"
    end
    
    local dialog = [[
set_default_color|`o
add_label_with_icon|big|`2Saved Designs|left|6016|
add_spacer|small|
%s
add_spacer|small|
add_label|small|`oUse these names with: `6/check `oor `6/design`o.|left|
end_dialog|design_list|Close|
]]
    sendVariant({ [0]= "OnDialogRequest", [1]= string.format(dialog, worldListText) }, -1, 0)
end

function stopDesign()
    if isThreadRunning(BUILD_THREAD_LABEL) then
        killThread(BUILD_THREAD_LABEL)
        _G.isPaused = false
        logToConsole("`4Design construction forcibly stopped.")
        doToast(3, 3000, "Build process stopped!")
    else
        logToConsole("`oNo build process is currently running.")
    end
end

function pauseDesign()
    if isThreadRunning(BUILD_THREAD_LABEL) then
        _G.isPaused = true
        logToConsole("`6Build process paused. Use /resume to continue.")
        doToast(1, 2000, "Build Paused")
    else
        logToConsole("`4Error: `oNo build process is running to pause.")
    end
end

function resumeDesign()
    if _G.isPaused then
        _G.isPaused = false
        logToConsole("`2Build process resumed.")
        doToast(1, 2000, "Build Resumed")
    else
        logToConsole("`4Error: `oBuild is not currently paused.")
    end
end

function findPathToPlace(targetX, targetY)
    local adjacentSpots = {
        {1, 0}, {-1, 0}, {0, 1}, {0, -1}, 
        {1, 1}, {-1, 1}, {1, -1}, {-1, -1},
        {2, 0}, {-2, 0}, {0, 2}, {0, -2},
        {2, 1}, {2, -1}, {-2, 1}, {-2, -1},
        {1, 2}, {1, -2}, {-1, 2}, {-1, -2},
        {2, 2}, {-2, 2}, {2, -2}, {-2, -2}
    }

    for _, spot in ipairs(adjacentSpots) do
        local standX = targetX + spot[1]
        local standY = targetY + spot[2]

        local tile = checkTile(standX, standY)
        if tile and tile.fg == 0 then
            if findPath(standX, standY) then
                return true
            end
        end
    end

    return false
end

local function buildDesign(worldName)
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
    local file = io.open(filePath, "r")
    if not file then return end
    local lines = split(file:read("*all"), "\n")
    file:close()
    
    logToConsole("`2Starting construction for world: `o" .. worldName)
    
    for i, line in ipairs(lines) do
        local hasNotifiedPause = false
        while _G.isPaused do
            if not hasNotifiedPause then
                logToConsole("`6Build is paused...")
                hasNotifiedPause = true
            end
            sleep(1000)
        end
        if hasNotifiedPause then logToConsole("`2Resuming...") end

        if line ~= "" then
            local parts = split(line, "|")
            local itemID, x, y = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])

            if itemID and x and y then
                local itemInfo = getItemByID(itemID)
                local existingTile = checkTile(x, y)
                local isForegroundBlock = (itemInfo.collisionType > 0)

                if (isForegroundBlock and existingTile.fg == itemID) or (not isForegroundBlock and existingTile.bg == itemID) then
                    goto continue
                end

                local hasNotified = false
                while getItemCount(itemID) < 1 do
                    if not hasNotified then
                        logToConsole("`4Build paused. `oOut of material: `2"..itemInfo.name)
                        doToast(2, 3000, "Out of Material: " .. itemInfo.name)
                        hasNotified = true
                        _G.isPaused = true
                    end
                    sleep(2500)
                end
                if hasNotified then logToConsole("`2Material detected! `oResuming construction...") end
                
                if findPathToPlace(x, y) then
                    sleep(300)
                    
                    sleep(delayPut)
                    requestTileChange(x, y, itemID)
                    
                    local placement_confirmed = false
                    local timeSpent = 0
                    local timeout = 3000
                    while timeSpent < timeout do
                        local updatedTile = checkTile(x, y)
                        if (isForegroundBlock and updatedTile.fg == itemID) or (not isForegroundBlock and updatedTile.bg == itemID) then
                            placement_confirmed = true
                            break 
                        end
                        sleep(100)
                        timeSpent = timeSpent + 100
                    end
                    
                    if placement_confirmed then
                        sleep(delayTp)
                        local remainingContent = ""
                        for j = i + 1, #lines do
                            if lines[j] ~= "" then
                                remainingContent = remainingContent .. lines[j] .. "\n"
                            end
                        end
                        
                        local fileToWrite = io.open(filePath, "w")
                        if fileToWrite then
                            fileToWrite:write(remainingContent)
                            fileToWrite:close()
                        end
                    else
                        logToConsole("`4Warning: `oTile update timeout at ("..x..", "..y.."). Will retry on next run.")
                    end
                else
                    doLog("`4Skipping: `oCould not find path to place block at ("..x..", "..y..")")
                end
            end
        end
        ::continue::
    end

    if #lines > 0 and (split(lines[#lines], "|")[1] or "") ~= "" then
      local finalFile = io.open(filePath, "r")
      if finalFile and finalFile:read("*a") == "" then
          finalFile:close()
          os.remove(filePath)
          logToConsole("`2Design construction finished! File has been removed.")
          doToast(1, 4000, "Construction Finished!")
      else
          if finalFile then finalFile:close() end
          logToConsole("`2Design construction stopped. Rerun to continue.")
          doToast(1, 4000, "Construction Stopped!")
      end
    end
end

function startDesign(worldName)
    if isThreadRunning(BUILD_THREAD_LABEL) then
        killThread(BUILD_THREAD_LABEL)
    end
    _G.isPaused = false

    if not hasBuildAccess() then
        logToConsole("`4Access Denied: `oYou are not an admin/owner in this world.")
        doToast(3, 4000, "Access denied!")
        return
    end

    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
    if not io.open(filePath, "r") then
        logToConsole("`4Error: `oDesign file '"..worldName..".txt' not found. Use `/copy` first.")
        return
    end
  
    runThread(function() buildDesign(worldName) end, BUILD_THREAD_LABEL)
    logToConsole("`2Access confirmed. `oBuild process starting...")
end

function copy()
  local name = getWorld().name
  local folderPath = "/storage/emulated/0/android/media/GENTAHAX/design/"
  if not getDir(folderPath) then
    os.execute("mkdir -p "..folderPath)
    doToast(1, 2000, "Folder 'design' created")
  end

  local file = io.open(folderPath..name:upper()..".txt", "w")
  if not file then return logToConsole("`4Failed to create file.") end
  local designList = io.open(folderPath.."list_design.txt", "a")
  if not designList then return logToConsole("`4Failed to create list.") end
  
  local output = ""
  for _, tile in ipairs(getTile()) do
    if tile.fg ~= 0 and tile.fg ~= 8 and tile.fg ~= 6 and tile.fg ~= 242 and tile.fg ~= 3760 then
      output = output .. string.format("%d|%d|%d", tile.fg, tile.pos.x, tile.pos.y) .. "\n"
      if tile.getFlags.glue then
        output = output .. string.format("%d|%d|%d", 1866, tile.pos.x, tile.pos.y) .. "\n"
      end
      if tile.getFlags.water then
        output = output .. string.format("%d|%d|%d", 822, tile.pos.x, tile.pos.y) .. "\n"
      end
      local paint = parse_paint(tile.flags)
      if paint then
        output = output .. string.format("%d|%d|%d", paint, tile.pos.x, tile.pos.y) .. "\n"
      end
    end
    if tile.bg ~= 0 then
      output = output .. string.format("%d|%d|%d", tile.bg, tile.pos.x, tile.pos.y) .. "\n"
    end
  end
  
  file:write(output)
  file:close()
  
  local readDesignList = io.open(folderPath.."list_design.txt", "r")
  local listD = nil
  if readDesignList then
    listD = split(readDesignList:read("*all"), "\n")
    readDesignList:close()
  end
  local avaList = false
 
  if listD then
    for _, i in ipairs(listD) do
      if i:upper() == name:upper() then
        avaList = true
        break
      end
    end
  end

  if not avaList then
    designList:write(name.."\n")
    designList:close()
  end
  
  logToConsole("`2Success! `oWorld design `2"..name.."`o copied.")
end

function check(worldName)
  local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
  local file = io.open(filePath, "r")
  if not file then
    return logToConsole("`4Error: `oDesign file for `2"..worldName.."`o not found.")
  end
  
  local amount, itemListStr = {}, ""
  local dialog = "set_default_color|`o\nadd_label_with_icon|big|`2Materials for `o%s|left|6016|\nadd_spacer|small|\n%sadd_quick_exit|\nend_dialog|material_dialog|Close|"
  
  local content = file:read("*all")
  file:close()
  
  for part in content:gmatch("([^\n]+)") do
    local itemID = tonumber(part:match("([^|]+)"))
    if itemID then
      amount[itemID] = (amount[itemID] or 0) + 1
    end
  end
  
  for itemID, count in pairs(amount) do
    itemListStr = itemListStr .. string.format("add_label_with_icon|small|`o%dx `2%s|left|%d|\n", count, getItemByID(itemID).name, itemID)
  end
  
  sendVariant({ [0]= "OnDialogRequest", [1]= string.format(dialog, worldName:upper(), itemListStr) }, -1, 0)
end

function deleteItemFromDesign(worldName, itemName)
    local itemIDToDelete = findItemID(itemName)
    if not itemIDToDelete then
        return logToConsole("`4Error: `oItem `2"..itemName.."`o not found in items.txt.")
    end

    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/"..worldName:upper()..".txt"
    local file = io.open(filePath, "r")
    if not file then
        return logToConsole("`4Error: `oDesign file for `2"..worldName.."`o not found.")
    end

    local lines = split(file:read("*all"), "\n")
    file:close()

    local newContent = ""
    local itemsDeleted = 0
    for _, line in ipairs(lines) do
        if line ~= "" then
            local itemIDInLine = tonumber(line:match("([^|]+)"))
            if itemIDInLine ~= itemIDToDelete then
                newContent = newContent .. line .. "\n"
            else
                itemsDeleted = itemsDeleted + 1
            end
        end
    end

    local fileToWrite = io.open(filePath, "w")
    if not fileToWrite then
        return logToConsole("`4Error: `oCould not write to design file.")
    end
    fileToWrite:write(newContent)
    fileToWrite:close()

    logToConsole("`2Success! `oDeleted `4"..itemsDeleted.."`o `2"..itemName.."`o from design `4"..worldName.."`o.")
end

function help()
    local dialog = [[
set_default_color|`o
add_label_with_icon|big|`4Copy & Design Help|left|3802|
add_spacer|small|
add_label_with_icon|small|`4Author: `3Raaffly|left|1752|
add_spacer|big|
add_label_with_icon|small|`9Commands:|left|32|
add_spacer|small|
add_label_with_icon|small|`6/copy `o- Copies the current world design.|left|2412|
add_label_with_icon|small|`6/check <world> `o- Checks materials for a design.|left|2412|
add_label_with_icon|small|`6/design <world> `o- Starts building a design.|left|2412|
add_label_with_icon|small|`6/list `o- Shows all saved design files.|left|2412|
add_label_with_icon|small|`6/stop `o- Forcibly stops the build process.|left|2412|
add_label_with_icon|small|`6/pause `o- Pauses the current build process.|left|2412|
add_label_with_icon|small|`6/resume `o- Resumes a paused build process.|left|2412|
add_label_with_icon|small|`6/delete <world> <item> `o- Deletes an item from a file.|left|2412|
add_label_with_icon|small|`6/help `o- Shows this help dialog.|left|2412|
add_spacer|small|
end_dialog|lusi|Close|
]]
    sendVariant({ [0]= "OnDialogRequest", [1]= dialog }, -1, 0)
end

local function commandHook(_, pkt)
  if pkt:find("action|input\n|text|/") then
    local text = pkt:gsub("action|input\n|text|", "")
    local parts = split(text, " ")
    local command = parts[1]
    local worldName = parts[2]
    local itemName = ""
    if #parts > 2 then
        itemName = table.concat(parts, " ", 3)
    end
    
    if command == "/copy" then
      copy()
      return true
    elseif command == "/check" then
      if not worldName then logToConsole("`4Usage: `o/check <world_name>") return true end
      check(worldName)
      return true
    elseif command == "/design" then
      if not worldName then logToConsole("`4Usage: `o/design <world_name>") return true end
      startDesign(worldName)
      return true
    elseif command == "/list" then
      getDesignList()
      return true
    elseif command == "/stop" then
      stopDesign()
      return true
    elseif command == "/pause" then
        pauseDesign()
        return true
    elseif command == "/resume" then
        resumeDesign()
        return true
    elseif command == "/delete" then
        if not worldName or itemName == "" then
            logToConsole("`4Usage: `o/delete <world_name> <item_name>")
            return true
        end
        deleteItemFromDesign(worldName, itemName)
        return true
    elseif command == "/help" then
        help()
        return true
    end
  end
end

AddHook("OnTextPacket", "CommandHook", commandHook)
