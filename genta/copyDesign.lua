local delayPut = 300
local delayTp = 400

local os = require("os")
local BUILD_THREAD_LABEL = "DesignBuilderThread"
_G.isPaused = false

local ihkaz_loader_code, err =
    makeRequest(
    "https://raw.githubusercontent.com/ihkaz/GT-Dialog-Builder-in-lua/refs/heads/main/DialogBuilder.lua",
    "GET"
)
if not ihkaz_loader_code or not ihkaz_loader_code.content or ihkaz_loader_code.content == "" then
    return logToConsole("`4FATAL ERROR: `oCould not load Ihkaz Dialog Builder from GitHub!")
end
local ihkaz, err = load(ihkaz_loader_code.content)
if not ihkaz then
    return logToConsole("`4FATAL ERROR: `oFailed to execute Ihkaz Dialog Builder code: " .. tostring(err))
end
ihkaz = ihkaz()
logToConsole("`2Ihkaz Dialog Builder loaded successfully.")
_G.deleteDialogState = {worldName = "", itemMap = {}}
_G.displayShelfData = {}
_G.itemWantToAdd = {}

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

function split(s, delimiter)
    local result = {}
    delimiter = delimiter:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
    local pattern = "([^" .. delimiter .. "]*)"
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
        if #parts == 2 and parts[2]:lower() == searchName then
            file:close()
            return tonumber(parts[1])
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
    for _, tile in ipairs(getTile()) do
        if tile.getFlags.locked then
            local extra = getExtraTile(tile.pos.x, tile.pos.y)
            if extra and extra.valid then
                if extra.owner == myUserID then
                    return true
                end
                for _, adminID in ipairs(extra.adminList) do
                    if adminID == myUserID then
                        return true
                    end
                end
                return false
            end
        end
    end
    return true
end

function parse_paint(flags)
    local color_mapping = {
        [0] = nil,
        [1] = 3478,
        [2] = 3482,
        [3] = 3480,
        [4] = 3486,
        [5] = 3488,
        [6] = 3484,
        [7] = 3490
    }
    return color_mapping[(flags >> 13) & 7] or nil
end

function addItemToShelf(x, y, id, pos)
    local pkt = "action|dialog_return\ndialog_name|dispshelf\ntilex|%d|\ntiley|%d|\nreplace%d|%d\n"
    sendPacket(2, string.format(pkt, x, y, pos, id))
    return true
end

function calculateDistance(x1, y1, x2, y2)
    return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

function findPathToPlace(targetX, targetY)
    local p = getLocal()
    if not p then
        return false
    end
    local startX, startY = p.pos.x, p.pos.y
    local adjacentSpots = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {2, 0}, {-2, 0}, {0, 2}, {-2, 0}}
    local bestSpot, minDistance = nil, 9999
    for _, spot in ipairs(adjacentSpots) do
        local standX, standY = targetX + spot[1], targetY + spot[2]
        local tile = checkTile(standX, standY)
        if tile and tile.fg == 0 then
            local dist = calculateDistance(startX, startY, standX, standY)
            if dist < minDistance then
                minDistance = dist
                bestSpot = {x = standX, y = standY}
            end
        end
    end
    if not bestSpot then
        logToConsole("`4Path Error: `oNo empty spot found.")
        return false
    end
    if findPath(bestSpot.x, bestSpot.y) then
        return true
    else
        logToConsole("`4Path Error: `oPath is blocked.")
        return false
    end
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
    dialog:setbody(
        {
            bg = {25, 25, 25, 240},
            border = {150, 150, 150, 200},
            textcolor = "`o"
        }
    )

    dialog:addlabel(
        true,
        {
            label = "`2Saved Designs",
            size = "big",
            id = 6016
        }
    )
    dialog:addspacer("small")

    local hasDesigns = false
    local worldLabels = {}
    for _, name in ipairs(worlds) do
        if name ~= "" then
            table.insert(worldLabels, {label = "`2" .. name, id = 3802})
            hasDesigns = true
        end
    end

    if hasDesigns then
        dialog:addlabel(true, worldLabels)
    else
        dialog:addlabel(false, {label = "`oNo designs saved yet."})
    end

    dialog:addspacer("small")
    dialog:addlabel(
        false,
        {
            label = "`oUse these names with: `6/check `oor `6/design`o."
        }
    )
    dialog:setDialog(
        {
            name = "design_list",
            closelabel = "Close"
        }
    )

    dialog:showdialog()
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
        logToConsole("`6Build process paused.")
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

function buildDesign(worldName)
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/" .. worldName:upper() .. ".txt"
    local file = io.open(filePath, "r")
    if not file then
        return
    end
    local lines = split(file:read("*all"), "\n")
    file:close()
    logToConsole("`2Starting smart construction for world: `o" .. worldName)
    for i, line in ipairs(lines) do
        while _G.isPaused do
            sleep(1000)
        end
        if line ~= "" then
            local parts = split(line, "|")
            local action = parts[1]
            local placement_confirmed = false
            if action == "place" then
                local itemID, x, y = tonumber(parts[2]), tonumber(parts[3]), tonumber(parts[4])
                local itemInfo = getItemByID(itemID)
                local existingTile = checkTile(x, y)
                local isForegroundBlock = (itemInfo.collisionType > 0)
                if
                    (isForegroundBlock and existingTile.fg == itemID) or
                        (not isForegroundBlock and existingTile.bg == itemID)
                 then
                    goto continue
                end
                while getItemCount(itemID) < 1 do
                    logToConsole("`4Paused: `oOut of `2" .. itemInfo.name)
                    doToast(2, 3000, "Out of Material!")
                    _G.isPaused = true
                    sleep(2500)
                end
                if findPathToPlace(x, y) then
                    sleep(300)
                    sleep(delayPut)
                    requestTileChange(x, y, itemID)
                    local timeSpent = 0
                    local timeout = 3000
                    while timeSpent < timeout do
                        local updatedTile = checkTile(x, y)
                        local flagsInfo = updatedTile.getFlags
                        local success = false
                        local isActionItem = (itemID == 1866 or itemID == 822 or (itemID >= 3478 and itemID <= 3490))
                        if isActionItem then
                            if itemID == 1866 and flagsInfo.glue then
                                success = true
                            elseif itemID == 822 and flagsInfo.water then
                                success = true
                            elseif parse_paint(updatedTile.flags) == itemID then
                                success = true
                            end
                        else
                            if isForegroundBlock and updatedTile.fg == itemID then
                                success = true
                            elseif not isForegroundBlock and updatedTile.bg == itemID then
                                success = true
                            end
                        end
                        if success then
                            placement_confirmed = true
                            break
                        end
                        sleep(100)
                        timeSpent = timeSpent + 100
                    end
                else
                    logToConsole("`4Skipping: `oCould not find path to place block at (" .. x .. ", " .. y .. ")")
                end
            elseif action == "add" then
                local shelfX, shelfY, itemID_to_add, slot =
                    tonumber(parts[2]),
                    tonumber(parts[3]),
                    tonumber(parts[4]),
                    tonumber(parts[5])
                logToConsole(
                    string.format(
                        "`oAdding `2%s`o to shelf at (`2%d`o, `2%d`o) slot `2%d",
                        getItemByID(itemID_to_add).name,
                        shelfX,
                        shelfY,
                        slot
                    )
                )
                while getItemCount(itemID_to_add) < 1 do
                    logToConsole("`4Paused: `oOut of `2" .. getItemByID(itemID_to_add).name .. "`o to put in shelf.")
                    _G.isPaused = true
                    sleep(2500)
                end
                _G.itemWantToAdd = {}
                for i, p in pairs(parts) do
                    table.insert(_G.itemWantToAdd, p)
                end

                requestTileChange(shelfX, shelfY, 32)
                sleep(600)
                local timeSpent = 0
                local timeout = 3000
                while timeSpent < timeout do
                    local extra = getExtraTile(shelfX, shelfY)
                    local success = false
                    if extra and extra.valid then
                        if slot == 1 and extra.owner == itemID_to_add then
                            success = true
                        elseif slot == 2 and extra.volume == itemID_to_add then
                            success = true
                        elseif slot == 3 and extra.lastUpdate == itemID_to_add then
                            success = true
                        elseif slot == 4 and extra.growth == itemID_to_add then
                            success = true
                        end
                    end
                    if success then
                        placement_confirmed = true
                        break
                    end
                    sleep(100)
                    timeSpent = timeSpent + 100
                end
            end
            if placement_confirmed then
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
                logToConsole("`4Warning: `oAction failed or timed out for line: " .. line)
            end
        end
        ::continue::
    end

    logToConsole("`2Build process finished or stopped.")
end

function startDesign(worldName)
    if isThreadRunning(BUILD_THREAD_LABEL) then
        killThread(BUILD_THREAD_LABEL)
    end
    _G.isPaused = false
    if not hasBuildAccess() then
        doToast(3, 4000, "Access denied!")
        return
    end
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/" .. worldName:upper() .. ".txt"
    if not io.open(filePath, "r") then
        logToConsole("`4Error: `oDesign file not found.")
        return
    end
    runThread(
        function()
            buildDesign(worldName)
        end,
        BUILD_THREAD_LABEL
    )
    logToConsole("`2Access confirmed. `oBuild process starting...")
end

function doCopy()
    local name = getWorld().name
    local folderPath = "/storage/emulated/0/android/media/GENTAHAX/design/"
    if not getDir(folderPath) then
        os.execute("mkdir -p " .. folderPath)
    end
    local file = io.open(folderPath .. name:upper() .. ".txt", "w")
    if not file then
        return logToConsole("`4Failed to create file.")
    end
    local output = ""
    for _, tile in ipairs(getTile()) do
        if tile.fg ~= 0 and tile.fg ~= 8 and tile.fg ~= 6 and tile.fg ~= 242 and tile.fg ~= 3760 then
            output = output .. string.format("place|%d|%d|%d\n", tile.fg, tile.pos.x, tile.pos.y)
        end
        if tile.bg ~= 0 then
            output = output .. string.format("place|%d|%d|%d\n", tile.bg, tile.pos.x, tile.pos.y)
        end
        if tile.getFlags.water then
            output = output .. string.format("place|%d|%d|%d\n", 822, tile.pos.x, tile.pos.y)
        end
        if tile.getFlags.glue then
            output = output .. string.format("place|%d|%d|%d\n", 1866, tile.pos.x, tile.pos.y)
        end
        local paint = parse_paint(tile.flags)
        if paint then
            output = output .. string.format("place|%d|%d|%d\n", paint, tile.pos.x, tile.pos.y)
        end
        if tile.fg == 3794 then
            local extra = getExtraTile(tile.pos.x, tile.pos.y)
            if extra and extra.valid then
                if extra.owner ~= 0 then
                    output = output .. string.format("add|%d|%d|%d|1\n", tile.pos.x, tile.pos.y, extra.owner)
                end
                if extra.volume ~= 0 then
                    output = output .. string.format("add|%d|%d|%d|2\n", tile.pos.x, tile.pos.y, extra.volume)
                end
                if extra.lastUpdate ~= 0 then
                    output = output .. string.format("add|%d|%d|%d|3\n", tile.pos.x, tile.pos.y, extra.lastUpdate)
                end
                if extra.growth ~= 0 then
                    output = output .. string.format("add|%d|%d|%d|4\n", tile.pos.x, tile.pos.y, extra.growth)
                end
            end
        end
    end
    file:write(output)
    file:close()
    local listFile = io.open(folderPath .. "list_design.txt", "r")
    local content = ""
    if listFile then
        content = listFile:read("*a")
        listFile:close()
    end
    if not content:find(name:upper(), 1, true) then
        listFile = io.open(folderPath .. "list_design.txt", "a")
        if listFile then
            listFile:write(name .. "\n")
            listFile:close()
        end
    end
    logToConsole("`2Success! `oWorld design `2" .. name .. "`o copied.")
    doToast(1, 3000, "World design copied!")
end

function copy()
    local dialog = ihkaz.new()
    dialog:setbody({bg = {25, 25, 25, 240}, border = {150, 150, 150, 200}, textcolor = "`o"})
    dialog:addlabel(true, {label = "`4Confirm Copy", size = "big", id = 2412})
    dialog:addspacer("small"):addlabel(false, {label = "`oStart copying the design of this world?"})
    dialog:setDialog({name = "copy_confirm", closelabel = "No", applylabel = "Yes"})
    dialog:showdialog()
end

function showShelfDataDialog()
    local dialog = ihkaz.new()
    dialog:setbody({bg = {25, 25, 25, 240}, border = {150, 150, 150, 200}, textcolor = "`o"})
    dialog:addlabel(true, {label = "`2Display Shelf Contents", size = "big", id = 3794})
    dialog:addspacer("small")
    if #_G.displayShelfData > 0 then
        local shelfLabels, amount = {}, {}
        for _, dataString in ipairs(_G.displayShelfData) do
            local parts = split(dataString, "|")
            if parts[4] then
                amount[parts[4]] = (amount[parts[4]] or 0) + 1
            end
        end
        for i, count in pairs(amount) do
            table.insert(shelfLabels, {label = string.format("`o%dx `2%s", count, getItemByID(i).name), id = i})
        end
        dialog:addlabel(true, shelfLabels)
    else
        dialog:addlabel(false, {label = "`oNo display data found."})
    end
    dialog:setDialog({name = "shelf_data_dialog", closelabel = "Close"})
    dialog:showdialog()
end

function check(worldName)
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/" .. worldName:upper() .. ".txt"
    local file = io.open(filePath, "r")
    if not file then
        return logToConsole("`4Error: `oDesign file not found.")
    end
    local content = file:read("*all")
    file:close()
    local amount, labels, shelfData = {}, {}, {}
    for part in content:gmatch("([^\n]+)") do
        local parts = split(part, "|")
        local action = parts[1]
        local itemID = (action == "place" and tonumber(parts[2]))
        if itemID then
            amount[itemID] = (amount[itemID] or 0) + 1
        end
        if action == "add" then
            table.insert(shelfData, part)
        end
    end
    for itemID, count in pairs(amount) do
        table.insert(labels, {label = string.format("`o%dx `2%s", count, getItemByID(itemID).name), id = itemID})
    end
    _G.displayShelfData = shelfData
    local dialog = ihkaz.new()
    dialog:setbody({bg = {25, 25, 25, 240}, border = {150, 150, 150, 200}, textcolor = "`o", quickexit = true})
    dialog:addlabel(true, {label = "`2Materials for `o" .. worldName:upper(), size = "big", id = 6016})
    dialog:addspacer("small"):addlabel(true, labels)
    if #shelfData > 0 then
        dialog:addspacer("small"):addbutton(false, {value = "show_shelf_data", label = "Show Item in Display"})
    end
    dialog:setDialog({name = "check_dialog", closelabel = "Close"})
    dialog:showdialog()
end

function deleteDialog(worldName)
    local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/" .. worldName:upper() .. ".txt"
    local file = io.open(filePath, "r")
    if not file then
        return logToConsole("`4Error: `oDesign file not found.")
    end
    local content = file:read("*all")
    file:close()

    local placeItems, addItems = {}, {}
    local placeCounts, addCounts = {}, {}

    for part in content:gmatch("([^\n]+)") do
        local parts = split(part, "|")
        local action = parts[1]
        if action == "place" then
            local itemID = tonumber(parts[2])
            if itemID then
                if not placeItems[itemID] then
                    placeItems[itemID] = getItemByID(itemID).name
                end
                placeCounts[itemID] = (placeCounts[itemID] or 0) + 1
            end
        elseif action == "add" then
            local itemID = tonumber(parts[4])
            if itemID then
                if not addItems[itemID] then
                    addItems[itemID] = getItemByID(itemID).name
                end
                addCounts[itemID] = (addCounts[itemID] or 0) + 1
            end
        end
    end

    _G.deleteDialogState.worldName = worldName
    local dialog = ihkaz.new()
    dialog:setbody({bg = {25, 25, 25, 240}, border = {150, 150, 150, 200}, textcolor = "`o", quickexit = true})
    dialog:addlabel(true, {label = "`4Delete Items from `5" .. worldName:upper(), size = "big", id = 1866})

    dialog:addspacer("small"):addlabel(false, {label = "`oBlocks to Place:", size = "small"})
    for id, name in pairs(placeItems) do
        dialog:_append(string.format("add_checkbox|delete_place_%d|`o%d`4x `o%s|0|", id, placeCounts[id], name))
    end

    dialog:addspacer("small"):addlabel(false, {label = "`oItems in Shelves:", size = "small"})
    for id, name in pairs(addItems) do
        dialog:_append(string.format("add_checkbox|delete_add_%d|`o%d`4x `o%s|0|", id, addCounts[id], name))
    end

    dialog:addspacer("big"):addbutton(false, {value = "delete_entire_file", label = "Delete Entire Design File"})
    dialog:setDialog({name = "delete_items_dialog", closelabel = "Cancel", applylabel = "Ok"})
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
        logToConsole("`2File `o" .. worldName:upper() .. ".txt `2deleted.")
    else
        logToConsole("`6Info: `oFile `4" .. worldName:upper() .. ".txt `onot found.")
    end
    local listFile = io.open(listFilePath, "r")
    if not listFile then
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
            logToConsole("`2World `o" .. worldName:upper() .. "`2 removed from list.")
        end
    else
        logToConsole("`4Error: `oFailed to rewrite list.")
    end
    doToast(1, 3000, "Design " .. worldName .. " deleted.")
end

function help()
    local dialog = ihkaz.new()
    dialog:setbody({bg = {25, 25, 25, 240}, border = {150, 150, 150, 200}, textcolor = "`o", quickexit = true})
    dialog:addlabel(true, {label = "`4Copy & Design Help", size = "big", id = 3802})
    dialog:addspacer("small"):addlabel(true, {label = "`4Author: `3Raaffly", size = "small", id = 1752})
    dialog:addspacer("big"):addlabel(true, {label = "`9Commands:", size = "small", id = 32})
    dialog:addspacer("small")
    local commands = {
        {"/copy", "Copies design (incl. shelves)."},
        {"/check <world>", "Checks materials."},
        {"/design <world>", "Starts building a design."},
        {"/list", "Shows all saved designs."},
        {"/stop", "Stops the build process."},
        {"/pause", "Pauses the current build."},
        {"/resume", "Resumes a paused build."},
        {"/delete <world>", "Opens dialog to delete items from file."},
        {"/deletedesign <world>", "Deletes a design file."},
        {"/help", "Shows this help dialog."},
        {"/delayput <ms>", "Sets placement delay."},
        {"/delaytp <ms>", "Sets post-action delay."}
    }
    for _, cmd in ipairs(commands) do
        dialog:addlabel(true, {label = string.format("`6%s `o- %s", cmd[1], cmd[2]), id = 2412})
    end
    dialog:setDialog({name = "help_dialog", closelabel = "Close"})
    dialog:showdialog()
end

local function commandHook(type, pkt)
    if pkt:find("action|dialog_return") then
        local lines = split(pkt, "\n")
        local dialogData = {}
        for _, line in ipairs(lines) do
            local parts = split(line, "|")
            if parts[1] and parts[2] then
                dialogData[parts[1]] = parts[2]
            end
        end
        if dialogData["dialog_name"] == "delete_items_dialog" then
            if dialogData["button_name"] == "delete_entire_file" then
                deleteDesign(_G.deleteDialogState.worldName)
                return true
            end
            local placeIDsToDelete, addIDsToDelete = {}, {}
            for key, value in pairs(dialogData) do
                if value == "1" then
                    local placeID, addID = key:gsub("delete_place_", ""), key:gsub("delete_add_", "")
                    if key:find("delete_place_") then
                        table.insert(placeIDsToDelete, tonumber(placeID))
                    elseif key:find("delete_add_") then
                        table.insert(addIDsToDelete, tonumber(addID))
                    end
                end
            end
            if #placeIDsToDelete > 0 or #addIDsToDelete > 0 then
                local worldName = _G.deleteDialogState.worldName
                local filePath = "/storage/emulated/0/android/media/GENTAHAX/design/" .. worldName:upper() .. ".txt"
                local file = io.open(filePath, "r")
                if not file then
                    return true
                end
                local fileLines = split(file:read("*all"), "\n")
                file:close()
                local newContent = ""
                local itemsDeletedCount = 0
                for _, line in ipairs(fileLines) do
                    if line ~= "" then
                        local parts = split(line, "|")
                        local action = parts[1]
                        local itemID = -1
                        local shouldKeep = true
                        if action == "place" then
                            itemID = tonumber(parts[2])
                            for _, idToDelete in ipairs(placeIDsToDelete) do
                                if itemID == idToDelete then
                                    shouldKeep = false
                                    break
                                end
                            end
                        elseif action == "add" then
                            itemID = tonumber(parts[4])
                            for _, idToDelete in ipairs(addIDsToDelete) do
                                if itemID == idToDelete then
                                    shouldKeep = false
                                    break
                                end
                            end
                        end
                        if shouldKeep then
                            newContent = newContent .. line .. "\n"
                        else
                            itemsDeletedCount = itemsDeletedCount + 1
                        end
                    end
                end
                local fileToWrite = io.open(filePath, "w")
                if not fileToWrite then
                    return true
                end
                fileToWrite:write(newContent)
                fileToWrite:close()
                logToConsole("`2Success! `oDeleted `4" .. itemsDeletedCount .. "`o items from `4" .. worldName .. "`o.")
                doToast(1, 3000, "Items deleted from " .. worldName)
            else
                logToConsole("`oNo items selected.")
            end
            return true
        elseif dialogData["dialog_name"] == "check_dialog" and dialogData["buttonClicked"] == "show_shelf_data" then
            showShelfDataDialog()
            return true
        elseif dialogData["dialog_name"] == "copy_confirm" then
            doCopy()
            return true
        end
    end
    if pkt:find("action|input\n|text|/") then
        local text = pkt:gsub("action|input\n|text|", "")
        local parts = split(text, " ")
        local command = parts[1]
        local worldName = parts[2]
        local val = parts[3]
        if command == "/copy" then
            copy()
            return true
        elseif command == "/check" then
            if not worldName then
                logToConsole("`4Usage: `o/check <world_name>")
                return true
            end
            check(worldName)
            return true
        elseif command == "/design" then
            if not worldName then
                logToConsole("`4Usage: `o/design <world_name>")
                return true
            end
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
            if not worldName then
                logToConsole("`4Usage: `o/delete <world_name>")
                return true
            end
            deleteDialog(worldName)
            return true
        elseif command == "/deletedesign" then
            if not worldName then
                logToConsole("`4Usage: `o/deletedesign <world_name>")
                return true
            end
            deleteDesign(worldName)
            return true
        elseif command == "/help" then
            help()
            return true
        elseif command == "/delayput" then
            if not val then
                logToConsole("`4Usage: `o/delayput <ms>")
                return true
            end
            delayPut = tonumber(val)
            logToConsole("delayPut set to: " .. delayPut .. "ms.")
            return true
        elseif command == "/delaytp" then
            if not val then
                logToConsole("`4Usage: `o/delaytp <ms>")
                return true
            end
            delayTp = tonumber(val)
            logToConsole("delayTp set to: " .. delayTp .. "ms.")
            return true
        end
    end
end

local function varlist(v)
    if v[0] == "OnDialogRequest" then
        if v[1]:find("`wDisplay Shelf``") then
            doLog("start adding item to shelf...")
            if not _G.itemWantToAdd then
                return false
            end
            local item = _G.itemWantToAdd
            addItemToShelf(item[2], item[3], item[4], item[5])
            return true
        end
    end
end

AddHook("OnVarlist", "v", varlist)
AddHook("OnTextPacket", "y", commandHook)
