script_name("ImGui Messenger")
local script_version = 1.0

local samp = require 'samp.events'
local imgui = require 'mimgui'
local encoding = require 'encoding'
local vkeys = require 'vkeys'
local dlstatus = require('moonloader').download_status

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local os = require 'os'
local io = require 'io'
local ffi = require 'ffi'

ffi.cdef[[
    void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
]]
local shell32 = ffi.load('shell32')

local dataFile = getWorkingDirectory() .. '\\config\\messenger_data.json'
local settingsFile = getWorkingDirectory() .. '\\config\\messenger_settings.json'
local updateFile = getWorkingDirectory() .. '\\config\\msg_update.json'
local changelogFile = getWorkingDirectory() .. '\\config\\msg_changelog.txt'
local phoneData = {}
local imageCache = {}
local activeTempFiles = {}

local globalSettings = {
    theme = 1,
    useScreenNotifications = false,
    logBank = false,
    hideSmsJunk = false,
    autoUpdate = true,
    lastNewsText = "",
    notifPos = 3
}

local newsUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/news.txt"
local updateUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/update.json"
local changelogUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/changelog.txt"

local windowState = imgui.new.bool(false)
local myNick = "Default"
local actualPlayerNick = "Default"
local lastSeenNick = "Default"
local activeContact = nil

local requestFocus = false
local scrollToBottom = false

local contactToDelete = nil
local requestDeletePopup = false

local linkToOpen = ""
local requestLinkModal = false

local activeNotification = nil

local isCollectingBank = false
local bankMessageBuffer = {}

local inputName = imgui.new.char[256]("")
local inputNumber = imgui.new.char[256]("")
local inputMessage = imgui.new.char[512]("")

local settingScreenNotif = imgui.new.bool(false)
local settingLogBank = imgui.new.bool(false)
local settingHideJunk = imgui.new.bool(false)
local settingAutoUpdate = imgui.new.bool(false)

local lastSmsPhone = nil
local lastSmsType = nil

local cachedSortedContacts = {}
local needSortContacts = true

local autoCleaning = false
local cleanStep = 0

local autoGeo = false
local geoStep = 0
local targetGeoNumber = ""
local waitingForGeoConfirm = false

local tempSysNotifText = nil
local tempSysNotifTimer = 0
local tempSysNotifType = 0

local function showSystemNotification(text, nType)
    tempSysNotifText = text
    tempSysNotifType = nType or 0
    tempSysNotifTimer = os.clock() + 3.0
end

local themes = {
    { name = "Классический синий", me = imgui.ImVec4(0.18, 0.35, 0.58, 1.0), them = imgui.ImVec4(0.25, 0.25, 0.25, 1.0) },
    { name = "Темная ночь",        me = imgui.ImVec4(0.35, 0.35, 0.35, 1.0), them = imgui.ImVec4(0.12, 0.12, 0.12, 1.0) },
    { name = "Telegram (Dark)",    me = imgui.ImVec4(0.17, 0.35, 0.53, 1.0), them = imgui.ImVec4(0.11, 0.14, 0.18, 1.0) },
    { name = "WhatsApp (Dark)",    me = imgui.ImVec4(0.02, 0.38, 0.33, 1.0), them = imgui.ImVec4(0.12, 0.17, 0.20, 1.0) },
    { name = "AMOLED Черный",      me = imgui.ImVec4(0.25, 0.25, 0.25, 1.0), them = imgui.ImVec4(0.05, 0.05, 0.05, 1.0) },
    { name = "Изумрудный",         me = imgui.ImVec4(0.15, 0.45, 0.25, 1.0), them = imgui.ImVec4(0.20, 0.25, 0.20, 1.0) },
    { name = "Малиновый закат",    me = imgui.ImVec4(0.50, 0.20, 0.35, 1.0), them = imgui.ImVec4(0.25, 0.15, 0.20, 1.0) },
    { name = "Осенний лес",        me = imgui.ImVec4(0.65, 0.33, 0.05, 1.0), them = imgui.ImVec4(0.25, 0.32, 0.22, 1.0) },
    { name = "Океанская бездна",   me = imgui.ImVec4(0.05, 0.30, 0.45, 1.0), them = imgui.ImVec4(0.05, 0.15, 0.25, 1.0) }
}

local notifPositions = {
    u8"Слева снизу",
    u8"Снизу (по центру)",
    u8"Справа снизу",
    u8"Сверху (по центру)"
}

local months = {
    "января", "февраля", "марта", "апреля", "мая", "июня",
    "июля", "августа", "сентября", "октября", "ноября", "декабря"
}

local function save_json(path, data)
    local file = io.open(path, "w")
    if file then
        local function serialize(tbl)
            local str = "{"
            for k, v in pairs(tbl) do
                local key = type(k) == "string" and string.format("%q", k) or k
                if type(v) == "table" then
                    str = str .. "[" .. key .. "]=" .. serialize(v) .. ","
                elseif type(v) == "string" then
                    str = str .. "[" .. key .. "]=" .. string.format("%q", v) .. ","
                else
                    str = str .. "[" .. key .. "]=" .. tostring(v) .. ","
                end
            end
            return str .. "}"
        end
        file:write("return " .. serialize(data))
        file:close()
    end
    needSortContacts = true
end

local function load_json(path)
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local func = load(content)
        if func then return func() end
    end
    return {}
end

local function decodeJsonSafe(str)
    local ok, res = pcall(function()
        local func = load("return " .. str)
        if func then return func() end
        return nil
    end)
    if ok then return res end
    return nil
end

local function get_day_string(ts)
    if not ts or ts == 0 then return "Неизвестная дата" end
    local d = tonumber(os.date("%d", ts))
    local m = tonumber(os.date("%m", ts))
    local y = tonumber(os.date("%Y", ts))
    local curr_y = tonumber(os.date("%Y"))
    
    local str = string.format("%d %s", d, months[m])
    if y ~= curr_y then 
        str = str .. " " .. y 
    end
    return str
end

local function clamp(val) 
    return math.max(0.0, math.min(1.0, val)) 
end

local function ApplyTheme(theme_idx, bg_alpha)
    bg_alpha = bg_alpha or 0.95
    local active_theme = themes[theme_idx] or themes[1]
    local acc = active_theme.me
    local bg = active_theme.them
    
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(clamp(bg.x*0.3), clamp(bg.y*0.3), clamp(bg.z*0.3), bg_alpha))
    imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(clamp(bg.x*0.25), clamp(bg.y*0.25), clamp(bg.z*0.25), 0.98))
    imgui.PushStyleColor(imgui.Col.Button, acc)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(clamp(acc.x+0.1), clamp(acc.y+0.1), clamp(acc.z+0.1), 1.0))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(clamp(acc.x-0.1), clamp(acc.y-0.1), clamp(acc.z-0.1), 1.0))
    imgui.PushStyleColor(imgui.Col.Header, acc)
    imgui.PushStyleColor(imgui.Col.HeaderHovered, imgui.ImVec4(clamp(acc.x+0.1), clamp(acc.y+0.1), clamp(acc.z+0.1), 0.8))
    imgui.PushStyleColor(imgui.Col.HeaderActive, imgui.ImVec4(clamp(acc.x-0.1), clamp(acc.y-0.1), clamp(acc.z-0.1), 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBg, bg)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(clamp(bg.x+0.1), clamp(bg.y+0.1), clamp(bg.z+0.1), 0.8))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, bg)
    imgui.PushStyleColor(imgui.Col.TitleBg, imgui.ImVec4(clamp(bg.x*0.4), clamp(bg.y*0.4), clamp(bg.z*0.4), 1.0))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, acc)
    imgui.PushStyleColor(imgui.Col.TextSelectedBg, imgui.ImVec4(acc.x, acc.y, acc.z, 0.5))
    imgui.PushStyleColor(imgui.Col.ModalWindowDimBg, imgui.ImVec4(0.0, 0.0, 0.0, 0.6))
end

local function addSmsToHistory(profile, number, sender, text, ts)
    if not profile.contacts[number] then profile.contacts[number] = "" end
    if not profile.history[number] then profile.history[number] = {} end
    table.insert(profile.history[number], {sender = sender, msg = text, timestamp = ts})
    save_json(dataFile, phoneData)
end

function checkUpdates()
    if not globalSettings.autoUpdate then return end
    
    downloadUrlToFile(updateUrl, updateFile, function(id, status)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            local f = io.open(updateFile, "r")
            if f then
                local content = f:read("*a")
                f:close()
                os.remove(updateFile)
                if content then
                    local data = nil
                    local ok, res = pcall(decodeJson, content)
                    if ok and type(res) == "table" then
                        data = res
                    else
                        pcall(function()
                            local func = load("return " .. content)
                            if func then data = func() end
                        end)
                    end
                    
                    if data and data.version and data.url then
                        if tonumber(data.version) > script_version then
                            showSystemNotification(u8"Найдено обновление! Загрузка...", 3)
                            
                            downloadUrlToFile(changelogUrl, changelogFile, function(id_cl, status_cl)
                                if status_cl == dlstatus.STATUS_ENDDOWNLOADDATA then
                                    local fc = io.open(changelogFile, "r")
                                    local changelogText = ""
                                    if fc then
                                        changelogText = fc:read("*a")
                                        fc:close()
                                        os.remove(changelogFile)
                                    end
                                    
                                    local targetNick = actualPlayerNick
                                    if targetNick == "Default" then targetNick = myNick end
                                    local profile = phoneData[targetNick]
                                    
                                    if profile and changelogText ~= "" then
                                        local sys_num = "System_News"
                                        if not profile.contacts[sys_num] then profile.contacts[sys_num] = "Уведомления" end
                                        
                                        local header = "Скрипт обновлен до версии " .. tostring(data.version) .. "!\n\nЧто нового:\n"
                                        local full_text = header .. changelogText
                                        local text_cp1251 = u8:decode(full_text)
                                        
                                        addSmsToHistory(profile, sys_num, "them", text_cp1251, os.time())
                                        profile.unread[sys_num] = true
                                        save_json(dataFile, phoneData)
                                    end

                                    local scriptPath = thisScript().path
                                    downloadUrlToFile(data.url, scriptPath, function(id2, status2)
                                        if status2 == dlstatus.STATUS_ENDDOWNLOADDATA then
                                            showSystemNotification(u8"Успешно обновлено! Перезапуск...", 1)
                                            lua_thread.create(function()
                                                wait(1500)
                                                thisScript():reload()
                                            end)
                                        end
                                    end)
                                end
                            end)
                        end
                    end
                end
            end
        end
    end)
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    
    local loadedSettings = load_json(settingsFile)
    if loadedSettings.theme ~= nil then globalSettings.theme = loadedSettings.theme end
    if loadedSettings.notifPos ~= nil then globalSettings.notifPos = loadedSettings.notifPos end
    if loadedSettings.useScreenNotifications ~= nil then globalSettings.useScreenNotifications = loadedSettings.useScreenNotifications end
    if loadedSettings.hideSmsJunk ~= nil then globalSettings.hideSmsJunk = loadedSettings.hideSmsJunk end
    if loadedSettings.logBank ~= nil then globalSettings.logBank = loadedSettings.logBank end
    if loadedSettings.autoUpdate ~= nil then globalSettings.autoUpdate = loadedSettings.autoUpdate end
    if loadedSettings.lastNewsText ~= nil then globalSettings.lastNewsText = loadedSettings.lastNewsText end
    
    local result, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result then
        local tempNick = sampGetPlayerNickname(myId)
        lastSeenNick = tempNick
        if tempNick:find("_") then
            myNick = tempNick
            actualPlayerNick = tempNick
        end
    end
    
    phoneData = load_json(dataFile)
    
    for pName, pData in pairs(phoneData) do
        if not pData.unread then pData.unread = {} end
        if not pData.contacts then pData.contacts = {} end
        if not pData.history then pData.history = {} end
        pData.settings = nil
        
        for cNum, cHist in pairs(pData.history) do
            for _, msg in ipairs(cHist) do
                msg.bubbleSize = nil 
                msg.loadedStr = nil
                if not msg.timestamp then msg.timestamp = 0 end
            end
        end
    end
    
    if myNick ~= "Default" and myNick:find("_") and not phoneData[myNick] then
        phoneData[myNick] = { contacts = {}, history = {}, unread = {} }
        save_json(dataFile, phoneData)
    end

    checkUpdates()

    local temp_news_file = getWorkingDirectory() .. '\\config\\temp_news.txt'
    downloadUrlToFile(newsUrl, temp_news_file, function(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            local f = io.open(temp_news_file, "r")
            if f then
                local text_utf8 = f:read("*a")
                f:close()
                os.remove(temp_news_file)

                if text_utf8 then
                    text_utf8 = text_utf8:gsub("\r", "")
                    text_utf8 = text_utf8:match("^%s*(.-)%s*$")
                    
                    if text_utf8 and text_utf8 ~= "" and text_utf8:lower() ~= "none" and text_utf8:lower() ~= "clear" then
                        local profile = phoneData[myNick]
                        if profile then
                            local text_cp1251 = u8:decode(text_utf8)
                            
                            if globalSettings.lastNewsText ~= text_cp1251 then
                                globalSettings.lastNewsText = text_cp1251
                                save_json(settingsFile, globalSettings)
                                
                                local sys_num = "System_News"
                                if not profile.contacts[sys_num] then profile.contacts[sys_num] = "Уведомления" end
                                addSmsToHistory(profile, sys_num, "them", text_cp1251, os.time())

                                if activeContact ~= sys_num or not windowState[0] then
                                    profile.unread[sys_num] = true
                                    if globalSettings.useScreenNotifications then
                                        activeNotification = {
                                            number = sys_num,
                                            name = "Уведомления",
                                            text = text_cp1251,
                                            time = os.clock()
                                        }
                                    end
                                end
                                save_json(dataFile, phoneData)
                                if activeContact == sys_num then scrollToBottom = true end
                                needSortContacts = true
                            end
                        end
                    end
                end
            end
        end
    end)

    sampRegisterChatCommand("p", function()
        windowState[0] = not windowState[0]
        if windowState[0] then
            requestFocus = true
            scrollToBottom = true
        end
    end)

    local lastNickCheck = 0

    while true do
        wait(0)
        
        if os.clock() - lastNickCheck > 1.0 then
            lastNickCheck = os.clock()
            if sampIsLocalPlayerSpawned() then
                local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if r then
                    local currentInGameNick = sampGetPlayerNickname(id)
                    if currentInGameNick ~= lastSeenNick then
                        lastSeenNick = currentInGameNick
                        
                        if currentInGameNick:find("_") then
                            actualPlayerNick = currentInGameNick
                            myNick = currentInGameNick
                            activeContact = nil
                            needSortContacts = true
                            
                            if not phoneData[myNick] then
                                phoneData[myNick] = { contacts = {}, history = {}, unread = {} }
                                save_json(dataFile, phoneData)
                            end
                        end
                    end
                end
            end
        end

        if activeNotification and (os.clock() - activeNotification.time < 5.0) and not windowState[0] then
            if isKeyJustPressed(vkeys.VK_P) and not sampIsChatInputActive() and not sampIsDialogActive() and not sampIsCursorActive() then
                windowState[0] = true
                activeContact = activeNotification.number
                scrollToBottom = true
                requestFocus = true
                activeNotification = nil 
            end
        end
    end
end

function onScriptTerminate(scr, quitGame)
    if scr == thisScript() then
        for path, _ in pairs(activeTempFiles) do
            pcall(os.remove, path)
        end
    end
end

function samp.onShowDialog(id, st, title, b1, b2, text)
    if autoCleaning and id == 32700 then
        local tStr = tostring(title)
        local txtStr = tostring(text)
        
        if cleanStep == 2 and tStr:find("Сообщения") and not tStr:find("Последние") then
            local idx = 4
            local i = 0
            for line in txtStr:gmatch("[^\n]+") do
                if line:find("Входящие сообщения") and not line:find("Удалить") then
                    idx = i
                    break
                end
                i = i + 1
            end
            
            cleanStep = 3
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
            
        elseif cleanStep == 3 and (tStr:find("Последние сообщения") or txtStr:find("Отправитель")) then
            cleanStep = 4
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 0, 0, "")
            end)
            return false
            
        elseif cleanStep == 4 and tStr:find("Сообщения") and not tStr:find("Последние") then
            local idx = 0
            local i = 0
            for line in txtStr:gmatch("[^\n]+") do
                if line:find("Удалить все входящие сообщения") then
                    idx = i
                    break
                end
                i = i + 1
            end
            
            cleanStep = 5
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
            
        elseif cleanStep == 5 and txtStr:find("действительно хотите удалить") then
            autoCleaning = false
            cleanStep = 0
            
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, 65535, "")
                
                wait(400)
                sampSendClickTextdraw(65535) 
                sampSendChat("/untd 2")      
                
                showSystemNotification(u8"Серверный лимит SMS успешно очищен!", 1)
                windowState[0] = true
            end)
            return false
        end
    end

    if autoGeo and id == 32700 then
        local tStr = tostring(title)
        local txtStr = tostring(text)
        local cleanTitle = tStr:gsub("{.-}", "")
        local cleanText = txtStr:gsub("{.-}", "")
        
        if geoStep == 2 and cleanTitle:find("Сообщения") and not cleanTitle:find("Последние") then
            local idx = 3
            local i = 0
            for line in cleanText:gmatch("[^\n]+") do
                if line:find("Отправить геопозицию") then
                    idx = i
                    break
                end
                i = i + 1
            end
            
            geoStep = 3
            lua_thread.create(function()
                wait(500)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
            
        elseif geoStep == 3 and (cleanTitle:find("Новое сообщение") or cleanText:find("Введите номер")) then
            autoGeo = false
            geoStep = 0
            
            lua_thread.create(function()
                wait(500)
                sampSendDialogResponse(id, 1, 65535, tostring(targetGeoNumber))
                
                waitingForGeoConfirm = true
                wait(5000)
                if waitingForGeoConfirm then
                    waitingForGeoConfirm = false
                    if sampIsDialogActive() then
                        sampCloseCurrentDialogWithButton(0)
                    end
                    sampSendClickTextdraw(65535) 
                    sampSendChat("/untd 2")      
                    windowState[0] = true
                end
            end)
            return false
        end
    end
end

function samp.onServerMessage(color, text)
    if actualPlayerNick == "Default" or not phoneData[actualPlayerNick] then return end
    local profile = phoneData[actualPlayerNick]
    local ts = os.time()
    
    local plain_text = text:gsub("{%x%x%x%x%x%x}", "")
    
    if autoCleaning and plain_text:find("У Вас нет входящих сообщений") then
        autoCleaning = false
        cleanStep = 0
        
        lua_thread.create(function()
            wait(100)
            if sampIsDialogActive() then
                sampCloseCurrentDialogWithButton(0)
            end
            wait(100)
            sampSendClickTextdraw(65535) 
            sampSendChat("/untd 2")      
            showSystemNotification(u8"Память и так пуста!", 3)
            windowState[0] = true
        end)
    end
    
    local geo_num = plain_text:match("^%| Геопозиция на номер (%d+) отправлена%.")
    if geo_num then
        addSmsToHistory(profile, geo_num, "me", "[Геопозиция]", ts)
        if myNick == actualPlayerNick and activeContact == geo_num then scrollToBottom = true end
        
        if waitingForGeoConfirm then
            waitingForGeoConfirm = false
            lua_thread.create(function()
                wait(50)
                if sampIsDialogActive() then
                    sampCloseCurrentDialogWithButton(0)
                end
                wait(50)
                sampSendClickTextdraw(65535) 
                sampSendChat("/untd 2")      
                showSystemNotification(u8"Геопозиция успешно отправлена!", 1)
                windowState[0] = true
            end)
        end
    end
    
    if plain_text:find("Осталось сообщений до лимита: %d+ шт%.") then
        if globalSettings.useScreenNotifications or globalSettings.hideSmsJunk then
            return false
        end
    end
    
    if plain_text:find("^%| С вашего банковского счета списано %$%d+ за отправку SMS") then
        if globalSettings.useScreenNotifications or globalSettings.hideSmsJunk then
            return false
        end
    end

    if plain_text:find("Чтобы убрать телефон, нажмите кнопку \"ESC\"") then
        if globalSettings.useScreenNotifications or globalSettings.hideSmsJunk then
            return false
        end
    end
    
    if globalSettings.logBank then
        if plain_text:match("^%s*%|%s*Вы отыграли час") then
            isCollectingBank = true
            bankMessageBuffer = { plain_text }
            
            lua_thread.create(function()
                wait(300)
                isCollectingBank = false
                if #bankMessageBuffer > 0 then
                    local full_text = table.concat(bankMessageBuffer, "\n")
                    if not profile.contacts["Bank_System"] then profile.contacts["Bank_System"] = "Банк" end
                    
                    addSmsToHistory(profile, "Bank_System", "them", full_text, os.time())
                    
                    if myNick == actualPlayerNick and activeContact ~= "Bank_System" or not windowState[0] then
                        profile.unread["Bank_System"] = true
                        if globalSettings.useScreenNotifications then
                            activeNotification = {
                                number = "Bank_System",
                                name = "Банк",
                                text = "Получена новая выписка с банковского счета.",
                                time = os.clock()
                            }
                        end
                    end
                    save_json(dataFile, phoneData)
                    if myNick == actualPlayerNick and activeContact == "Bank_System" then scrollToBottom = true end
                end
            end)
            return false
        elseif isCollectingBank then
            if plain_text:match("^%s*[%|%-]") then
                table.insert(bankMessageBuffer, plain_text)
                return false 
            end
        end
    end

    local sender_str, inc_num, inc_text = text:match("SMS от (.-) %(тел%. (%d+)%): (.*)")
    if inc_num and inc_text then
        lastSmsPhone = inc_num
        lastSmsType = "in"
        addSmsToHistory(profile, inc_num, "them", inc_text, ts)
        
        if myNick ~= actualPlayerNick or activeContact ~= inc_num or not windowState[0] then
            profile.unread[inc_num] = true
            if globalSettings.useScreenNotifications then
                local cName = profile.contacts[inc_num]
                activeNotification = {
                    number = inc_num,
                    name = (cName == "" and inc_num or cName),
                    text = inc_text,
                    time = os.clock()
                }
            end
        end
        save_json(dataFile, phoneData)
        if myNick == actualPlayerNick and activeContact == inc_num then scrollToBottom = true end
        
        if globalSettings.useScreenNotifications then
            return false
        else
            if profile.contacts[inc_num] and profile.contacts[inc_num] ~= "" then
                local safe_sender = sender_str:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
                local new_text = text:gsub("SMS от " .. safe_sender, "SMS от " .. profile.contacts[inc_num])
                return {color, new_text}
            end
            return 
        end
    end

    local out_str, out_num, out_text = text:match("SMS к (.-) %(тел%. (%d+)%): (.*)")
    if out_num and out_text then
        lastSmsPhone = out_num
        lastSmsType = "out"
        addSmsToHistory(profile, out_num, "me", out_text, ts)
        if myNick == actualPlayerNick and activeContact == out_num then scrollToBottom = true end
        
        if globalSettings.useScreenNotifications then
            return false
        else
            if profile.contacts[out_num] and profile.contacts[out_num] ~= "" then
                local safe_receiver = out_str:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
                local new_text = text:gsub("SMS к " .. safe_receiver, "SMS к " .. profile.contacts[out_num])
                return {color, new_text}
            end
            return 
        end
    end

    local continued_text = text:match("^%.%.%.?%s*(.*)")
    if continued_text and lastSmsPhone then
        local hist = profile.history[lastSmsPhone]
        if hist and #hist > 0 then
            local prev_msg = hist[#hist].msg
            prev_msg = prev_msg:gsub("%s*%.%.%.?%s*$", "")
            hist[#hist].msg = prev_msg .. " " .. continued_text
            hist[#hist].bubbleSize = nil 
            save_json(dataFile, phoneData)
            if myNick == actualPlayerNick and activeContact == lastSmsPhone then scrollToBottom = true end
        end
        if globalSettings.useScreenNotifications then
            return false
        end
        return
    else
        lastSmsPhone = nil
    end
end

local notifyFrame = imgui.OnFrame(
    function() 
        return activeNotification ~= nil and (os.clock() - activeNotification.time < 5.0) and not windowState[0] 
    end,
    function(player)
        if not activeNotification then return end

        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY * 0.15), imgui.Cond.Always, imgui.ImVec2(0.5, 0.0))
        
        local profile = phoneData[actualPlayerNick]
        if not profile then return end
        local current_theme_idx = globalSettings.theme
        local active_theme = themes[current_theme_idx] or themes[1]
        local acc = active_theme.me
        
        ApplyTheme(current_theme_idx, 0.90)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8.0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(15, 12))
        
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoInputs
        if imgui.Begin("##NotifyWindow", nil, flags) then
            if activeNotification then
                imgui.TextColored(imgui.ImVec4(acc.x, acc.y, acc.z, 1.0), u8"Новое сообщение: " .. u8(activeNotification.name))
                
                imgui.PushTextWrapPos(350)
                imgui.Text(u8(activeNotification.text))
                imgui.PopTextWrapPos()
                
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                local hintText = u8"Нажмите 'P', чтобы прочитать"
                local hintWidth = imgui.CalcTextSize(hintText).x
                local windowWidth = imgui.GetWindowWidth()
                imgui.SetCursorPosX((windowWidth - hintWidth) / 2)
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1.0), hintText)
            end
            imgui.End()
        end
        imgui.PopStyleVar(2)
        imgui.PopStyleColor(15)
    end
)
notifyFrame.HideCursor = true 

local unreadIndicatorFrame = imgui.OnFrame(
    function() 
        if tempSysNotifText and os.clock() < tempSysNotifTimer then return true end
        if not phoneData[actualPlayerNick] then return false end
        for _, is_unread in pairs(phoneData[actualPlayerNick].unread) do
            if is_unread then return true end
        end
        return false
    end,
    function(player)
        local profile = phoneData[actualPlayerNick]
        if not profile then return end
        local notifPos = globalSettings.notifPos
        
        local resX, resY = getScreenResolution()
        local posX, posY = resX - 20, resY - 20
        local pivotX, pivotY = 1.0, 1.0
        
        if notifPos == 1 then 
            posX, posY = 20, resY - 20
            pivotX, pivotY = 0.0, 1.0
        elseif notifPos == 2 then 
            posX, posY = resX / 2, resY - 20
            pivotX, pivotY = 0.5, 1.0
        elseif notifPos == 3 then 
            posX, posY = resX - 20, resY - 20
            pivotX, pivotY = 1.0, 1.0
        elseif notifPos == 4 then 
            posX, posY = resX / 2, resY * 0.08
            pivotX, pivotY = 0.5, 0.0
        end

        local borderColor = imgui.ImVec4(0.0, 0.0, 0.0, 0.0)
        local textToShow = ""

        if tempSysNotifText and os.clock() < tempSysNotifTimer then
            textToShow = tempSysNotifText
            if tempSysNotifType == 1 then
                borderColor = imgui.ImVec4(0.20, 0.80, 0.20, 0.80)
            elseif tempSysNotifType == 2 then
                borderColor = imgui.ImVec4(0.80, 0.20, 0.20, 0.80)
            elseif tempSysNotifType == 3 then
                borderColor = imgui.ImVec4(0.20, 0.50, 0.80, 0.80)
            else
                borderColor = imgui.ImVec4(0.50, 0.50, 0.50, 0.80)
            end
        else
            textToShow = u8"У вас есть непрочитанные сообщения (открыть: /p)"
            local current_theme_idx = globalSettings.theme
            local acc = themes[current_theme_idx] and themes[current_theme_idx].me or imgui.ImVec4(0.18, 0.35, 0.58, 1.0)
            borderColor = imgui.ImVec4(acc.x, acc.y, acc.z, 0.80)
        end

        imgui.SetNextWindowPos(imgui.ImVec2(posX, posY), imgui.Cond.Always, imgui.ImVec2(pivotX, pivotY))
        
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.10, 0.10, 0.11, 0.95))
        imgui.PushStyleColor(imgui.Col.Border, borderColor)
        
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 6.0)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(15, 10))
        
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoInputs
        if imgui.Begin("##SysIndicator", nil, flags) then
            imgui.TextColored(imgui.ImVec4(0.9, 0.9, 0.9, 1.0), textToShow)
            imgui.End()
        end
        imgui.PopStyleVar(3)
        imgui.PopStyleColor(2)
    end
)
unreadIndicatorFrame.HideCursor = true

local newFrame = imgui.OnFrame(
    function() return windowState[0] end,
    function(player)
        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(750, 500), imgui.Cond.FirstUseEver)
        
        local profile = phoneData[myNick]
        if not profile then return end
        local current_theme_idx = globalSettings.theme
        local active_theme = themes[current_theme_idx] or themes[1]
        
        ApplyTheme(current_theme_idx, 0.95)
        
        if imgui.Begin(u8"Мессенджер", windowState, imgui.WindowFlags.NoCollapse) then

            if requestLinkModal then
                imgui.OpenPopup("LinkConfirmModal")
                requestLinkModal = false
            end
            
            if imgui.BeginPopupModal("LinkConfirmModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
                imgui.Text(u8"Переход по ссылке")
                imgui.Spacing()
                imgui.Text(u8"Вы собираетесь открыть внешнюю ссылку в браузере:")
                imgui.PushTextWrapPos(350)
                imgui.TextColored(imgui.ImVec4(0.3, 0.6, 1.0, 1.0), linkToOpen)
                imgui.PopTextWrapPos()
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                local availWidth = imgui.GetContentRegionAvail().x
                local btnWidth = (availWidth - imgui.GetStyle().ItemSpacing.x) / 2
                
                if imgui.Button(u8"Перейти", imgui.ImVec2(btnWidth, 0)) then
                    local safeUrl = linkToOpen
                    if not safeUrl:match("^https?://") then
                        safeUrl = "http://" .. safeUrl
                    end
                    lua_thread.create(function()
                        wait(150)
                        shell32.ShellExecuteA(nil, "open", safeUrl, nil, nil, 1)
                    end)
                    imgui.CloseCurrentPopup()
                end
                imgui.SameLine()
                if imgui.Button(u8"Отмена", imgui.ImVec2(btnWidth, 0)) then
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end

            if requestDeletePopup then
                imgui.OpenPopup("DeleteContactConfirm")
                requestDeletePopup = false
            end

            if imgui.BeginPopupModal("DeleteContactConfirm", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
                imgui.Text(u8"Подтверждение")
                if contactToDelete then
                    local rawName = profile.contacts[contactToDelete] or ""
                    local cName = ""
                    if contactToDelete == "Bank_System" then
                        cName = u8"Банк"
                    elseif contactToDelete == "System_News" then
                        cName = u8"Уведомления"
                    else
                        cName = (rawName == "" and "#" .. contactToDelete or u8(rawName) .. " (" .. contactToDelete .. ")")
                    end
                    imgui.Text(u8"Вы действительно хотите удалить контакт " .. cName .. u8"?\nВся история сообщений будет стерта.")
                end
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                local availWidth = imgui.GetContentRegionAvail().x
                local btnWidth = (availWidth - imgui.GetStyle().ItemSpacing.x) / 2
                
                if imgui.Button(u8"Удалить", imgui.ImVec2(btnWidth, 0)) then
                    if contactToDelete then
                        profile.contacts[contactToDelete] = nil
                        profile.history[contactToDelete] = nil
                        profile.unread[contactToDelete] = nil
                        if activeContact == contactToDelete then activeContact = nil end
                        save_json(dataFile, phoneData)
                    end
                    contactToDelete = nil
                    imgui.CloseCurrentPopup()
                end
                imgui.SameLine()
                if imgui.Button(u8"Отмена", imgui.ImVec2(btnWidth, 0)) then
                    contactToDelete = nil
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end

            if imgui.BeginPopupModal("SettingsModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
                imgui.Text(u8"Настройки мессенджера")
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "v" .. tostring(script_version))
                imgui.Spacing()
                
                imgui.Text(u8"Ваш профиль:")
                imgui.PushItemWidth(170)
                if imgui.BeginCombo("##SetProfileCombo", u8(myNick)) then
                    for nick, _ in pairs(phoneData) do
                        local is_selected = (myNick == nick)
                        if imgui.Selectable(u8(nick), is_selected) then
                            myNick = nick
                            profile = phoneData[myNick]
                            activeContact = nil 
                            needSortContacts = true
                        end
                    end
                    imgui.EndCombo()
                end
                imgui.PopItemWidth()
                
                imgui.SameLine()
                if imgui.Button(u8"Удалить", imgui.ImVec2(0, 0)) then
                    local actualNick = "Default"
                    local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                    if r then actualNick = sampGetPlayerNickname(id) end
                    
                    phoneData[myNick] = nil
                    
                    if myNick == actualNick and actualNick:find("_") then
                        phoneData[actualNick] = { contacts = {}, history = {}, unread = {} }
                    else
                        if actualNick:find("_") then
                            myNick = actualNick
                            if not phoneData[myNick] then
                                phoneData[myNick] = { contacts = {}, history = {}, unread = {} }
                            end
                        else
                            local any = next(phoneData)
                            if any then myNick = any else myNick = "Default" end
                        end
                    end
                    
                    profile = phoneData[myNick]
                    activeContact = nil
                    needSortContacts = true
                    save_json(dataFile, phoneData)
                end
                
                imgui.Spacing()
                imgui.Text(u8"Внешний вид:")
                local active_theme_name = themes[current_theme_idx] and themes[current_theme_idx].name or themes[1].name
                imgui.PushItemWidth(250)
                if imgui.BeginCombo("##SetThemeCombo", u8(active_theme_name)) then
                    for i, theme in ipairs(themes) do
                        if imgui.Selectable(u8(theme.name), current_theme_idx == i) then
                            globalSettings.theme = i
                            save_json(settingsFile, globalSettings)
                        end
                    end
                    imgui.EndCombo()
                end
                
                imgui.Spacing()
                imgui.Text(u8"Положение системных уведомлений:")
                local current_pos_idx = globalSettings.notifPos
                if imgui.BeginCombo("##NotifPosCombo", notifPositions[current_pos_idx]) then
                    for i, posName in ipairs(notifPositions) do
                        if imgui.Selectable(posName, current_pos_idx == i) then
                            globalSettings.notifPos = i
                            save_json(settingsFile, globalSettings)
                        end
                    end
                    imgui.EndCombo()
                end
                imgui.PopItemWidth()
                
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                settingScreenNotif[0] = globalSettings.useScreenNotifications
                if imgui.Checkbox(u8"Всплывающие уведомления (и скрытие SMS из чата)", settingScreenNotif) then
                    globalSettings.useScreenNotifications = settingScreenNotif[0]
                    save_json(settingsFile, globalSettings)
                end
                
                settingHideJunk[0] = globalSettings.hideSmsJunk
                if imgui.Checkbox(u8"Отключение серверного шлака телефона", settingHideJunk) then
                    globalSettings.hideSmsJunk = settingHideJunk[0]
                    save_json(settingsFile, globalSettings)
                end
                
                settingLogBank[0] = globalSettings.logBank
                if imgui.Checkbox(u8"Сохранять выписки из банка (PayDay) в отдельный диалог", settingLogBank) then
                    globalSettings.logBank = settingLogBank[0]
                    save_json(settingsFile, globalSettings)
                end

                settingAutoUpdate[0] = globalSettings.autoUpdate
                if imgui.Checkbox(u8"Автообновление скрипта", settingAutoUpdate) then
                    globalSettings.autoUpdate = settingAutoUpdate[0]
                    save_json(settingsFile, globalSettings)
                end
                
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                imgui.SetCursorPosX(imgui.GetWindowWidth() - 110)
                if imgui.Button(u8"Закрыть", imgui.ImVec2(100, 0)) then
                    imgui.CloseCurrentPopup()
                end
                
                imgui.EndPopup()
            end

            imgui.Columns(2, "PhoneColumns", false)
            imgui.SetColumnWidth(0, 280) 

            local topHeadY = imgui.GetCursorPosY()
            imgui.Text(u8"Контакты:")
            
            local cleanBtnText = u8"Сброс лимита"
            local cleanBtnWidth = imgui.CalcTextSize(cleanBtnText).x + 16
            local settingsBtnText = u8"Настройки"
            local settingsBtnWidth = imgui.CalcTextSize(settingsBtnText).x + 16
            
            imgui.SetCursorPos(imgui.ImVec2(imgui.GetColumnWidth() - cleanBtnWidth - settingsBtnWidth - 12, topHeadY - 2))
            
            if imgui.Button(cleanBtnText) then
                windowState[0] = false 
                autoCleaning = true
                cleanStep = 1
                showSystemNotification(u8"Запуск очистки памяти...", 0)
                sampSendChat("/phone")
                
                lua_thread.create(function()
                    local swiped = false
                    for i = 1, 50 do
                        wait(100)
                        for td = 0, 2304 do
                            if sampTextdrawIsExists(td) then
                                local txt = sampTextdrawGetString(td)
                                if type(txt) == "string" then
                                    local cleanText = txt:gsub("~.-~", ""):upper()
                                    if cleanText:find("SWIPE UP TO UNLOCK") and not swiped then
                                        sampSendClickTextdraw(td)
                                        swiped = true
                                        break
                                    end
                                end
                            end
                        end
                        if swiped then break end
                    end
                    
                    if not swiped then
                        showSystemNotification(u8"Ошибка: не найден экран блокировки телефона.", 2)
                        autoCleaning = false
                        windowState[0] = true
                        return
                    end
                    
                    wait(800) 
                    
                    if sampTextdrawIsExists(327) then
                        sampSendClickTextdraw(327)
                    end
                    
                    for td = 0, 2304 do
                        if sampTextdrawIsExists(td) then
                            local txt = sampTextdrawGetString(td)
                            if type(txt) == "string" then
                                local clean = txt:upper()
                                if clean:find("MESSAGE") or clean:find("СООБЩЕНИЯ") then
                                    sampSendClickTextdraw(td)
                                end
                            end
                        end
                    end
                    
                    cleanStep = 2
                    
                    wait(10000)
                    if autoCleaning then
                        autoCleaning = false
                        cleanStep = 0
                        showSystemNotification(u8"Ошибка: Таймаут. Сервер не ответил на диалоги.", 2)
                        sampSendClickTextdraw(65535)
                        sampSendChat("/untd 2")
                        windowState[0] = true 
                    end
                end)
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Автоматически очистить серверный лимит сообщений") end
            
            imgui.SameLine(imgui.GetColumnWidth() - settingsBtnWidth - 4)
            if imgui.Button(settingsBtnText) then
                imgui.OpenPopup("SettingsModal")
            end

            imgui.Spacing()
            
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8.0)
            local leftColWidth = imgui.GetColumnWidth()
            local inputWidth = (leftColWidth - 50) / 2 
            
            imgui.PushItemWidth(inputWidth)
            local enter1 = imgui.InputTextWithHint("##NameInput", u8"Имя", inputName, 256, imgui.InputTextFlags.EnterReturnsTrue)
            imgui.SameLine(0, 4)
            local enter2 = imgui.InputTextWithHint("##NumberInput", u8"Номер", inputNumber, 256, imgui.InputTextFlags.EnterReturnsTrue)
            imgui.PopItemWidth()
            
            imgui.SameLine(0, 4)
            if imgui.Button("+", imgui.ImVec2(30, 0)) or enter1 or enter2 then
                local name = u8:decode(ffi.string(inputName))
                local number = ffi.string(inputNumber)
                if number:match("^[%d%_a-zA-Z]+$") then
                    profile.contacts[number] = name
                    save_json(dataFile, phoneData)
                    inputName[0] = 0
                    inputNumber[0] = 0
                end
            end
            imgui.PopStyleVar() 
            
            imgui.Spacing()
            imgui.Separator()

            if needSortContacts then
                cachedSortedContacts = {}
                for num, name in pairs(profile.contacts) do
                    local last_ts = 0
                    if profile.history[num] and #profile.history[num] > 0 then
                        last_ts = profile.history[num][#profile.history[num]].timestamp or 0
                    end
                    table.insert(cachedSortedContacts, {num = num, name = name, last_ts = last_ts})
                end
                table.sort(cachedSortedContacts, function(a, b) return a.last_ts > b.last_ts end)
                needSortContacts = false
            end

            imgui.BeginChild("ContactsList", imgui.ImVec2(0, 0), true)
            for _, c in ipairs(cachedSortedContacts) do
                local num = c.num
                local name = c.name
                
                imgui.PushIDStr("contact_" .. num)
                
                local is_selected = (activeContact == num)
                local is_unread = profile.unread[num]
                
                local displayName = ""
                if num == "Bank_System" then
                    displayName = u8"Банк"
                elseif num == "System_News" then
                    displayName = u8"Уведомления"
                else
                    displayName = (name == "" and "#" .. num or u8(name) .. " (" .. num .. ")")
                end
                
                if is_unread then
                    displayName = "   " .. displayName
                end
                
                local cursorPos = imgui.GetCursorScreenPos()
                
                if is_unread and not is_selected then
                    local drawList = imgui.GetWindowDrawList()
                    local width = imgui.GetContentRegionAvail().x
                    local height = imgui.GetTextLineHeight() + 4 
                    
                    drawList:AddRectFilled(
                        cursorPos, 
                        imgui.ImVec2(cursorPos.x + width, cursorPos.y + height), 
                        imgui.GetColorU32Vec4(imgui.ImVec4(0.85, 0.30, 0.30, 0.25))
                    )
                    drawList:AddRectFilled(
                        cursorPos, 
                        imgui.ImVec2(cursorPos.x + 3, cursorPos.y + height), 
                        imgui.GetColorU32Vec4(imgui.ImVec4(0.90, 0.20, 0.20, 1.0))
                    )
                end
                
                if imgui.Selectable(displayName .. "##sel_" .. num, is_selected) then
                    activeContact = num
                    scrollToBottom = true
                    requestFocus = true
                    if is_unread then
                        profile.unread[num] = nil
                        save_json(dataFile, phoneData)
                    end
                end
                
                if imgui.BeginPopupContextItem("ContactPopup_" .. num) then
                    if num == "Bank_System" or num == "System_News" then
                        if imgui.Selectable(u8"Очистить историю") then
                            profile.history[num] = nil
                            profile.contacts[num] = nil
                            profile.unread[num] = nil
                            if activeContact == num then
                                activeContact = nil
                            end
                            save_json(dataFile, phoneData)
                        end
                    else
                        if imgui.Selectable(u8"Изменить") then
                            ffi.copy(inputNumber, num)
                            ffi.copy(inputName, u8(name))
                        end
                        if imgui.Selectable(u8"Позвонить") then
                            sampSendChat("/call " .. num)
                        end
                        imgui.Separator()
                        if imgui.Selectable(u8"Удалить контакт") then
                            contactToDelete = num
                            requestDeletePopup = true
                        end
                    end
                    imgui.EndPopup()
                end
                
                imgui.PopID()
            end
            imgui.EndChild()

            imgui.NextColumn()

            if activeContact then
                
                if profile.unread[activeContact] then
                    profile.unread[activeContact] = nil
                    save_json(dataFile, phoneData)
                end

                local contactName = ""
                if activeContact == "Bank_System" then
                    contactName = u8"Банк"
                elseif activeContact == "System_News" then
                    contactName = u8"Уведомления"
                else
                    local rawName = profile.contacts[activeContact]
                    contactName = (rawName == "" and "#" .. activeContact or u8(rawName))
                end
                
                local isSystemChat = (activeContact == "Bank_System" or activeContact == "System_News")
                
                imgui.AlignTextToFramePadding()
                imgui.Text(u8"Диалог: " .. contactName)
                
                if not isSystemChat then
                    local geoBtnText = u8"Геопозиция"
                    local geoBtnWidth = imgui.CalcTextSize(geoBtnText).x + 16
                    imgui.SameLine(imgui.GetColumnWidth() - geoBtnWidth - 10)
                    if imgui.Button(geoBtnText) then
                        targetGeoNumber = tostring(activeContact):match("%d+")
                        if targetGeoNumber then
                            windowState[0] = false 
                            autoGeo = true
                            geoStep = 1
                            showSystemNotification(u8"Запуск отправки геопозиции...", 0)
                            sampSendChat("/phone")
                            
                            lua_thread.create(function()
                                local swiped = false
                                for i = 1, 50 do
                                    wait(100)
                                    for td = 0, 2304 do
                                        if sampTextdrawIsExists(td) then
                                            local txt = sampTextdrawGetString(td)
                                            if type(txt) == "string" then
                                                local cleanText = txt:gsub("~.-~", ""):upper()
                                                if cleanText:find("SWIPE UP TO UNLOCK") and not swiped then
                                                    sampSendClickTextdraw(td)
                                                    swiped = true
                                                    break
                                                end
                                            end
                                        end
                                    end
                                    if swiped then break end
                                end
                                
                                if not swiped then
                                    showSystemNotification(u8"Ошибка: не найден экран блокировки телефона.", 2)
                                    autoGeo = false
                                    windowState[0] = true
                                    return
                                end
                                
                                wait(800) 
                                
                                if sampTextdrawIsExists(327) then
                                    sampSendClickTextdraw(327)
                                end
                                
                                for td = 0, 2304 do
                                    if sampTextdrawIsExists(td) then
                                        local txt = sampTextdrawGetString(td)
                                        if type(txt) == "string" then
                                            local clean = txt:upper()
                                            if clean:find("MESSAGE") or clean:find("СООБЩЕНИЯ") then
                                                sampSendClickTextdraw(td)
                                            end
                                        end
                                    end
                                end
                                
                                geoStep = 2
                                
                                wait(10000)
                                if autoGeo then
                                    autoGeo = false
                                    geoStep = 0
                                    showSystemNotification(u8"Ошибка: Таймаут. Сервер не ответил на диалоги.", 2)
                                    sampSendClickTextdraw(65535)
                                    sampSendChat("/untd 2")
                                    windowState[0] = true 
                                end
                            end)
                        else
                            showSystemNotification(u8"Ошибка: неверный номер телефона.", 2)
                        end
                    end
                end
                
                local p = imgui.GetCursorScreenPos()
                local w = imgui.GetColumnWidth()
                imgui.GetWindowDrawList():AddLine(
                    imgui.ImVec2(p.x, p.y + 2), 
                    imgui.ImVec2(p.x + w - 15, p.y + 2), 
                    imgui.GetColorU32Vec4(imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
                )
                imgui.Spacing()

                imgui.BeginChild("ChatHistory", imgui.ImVec2(0, -40), true)
                
                if profile.history[activeContact] then
                    local last_date_str = ""
                    local active_theme = themes[current_theme_idx] or themes[1]
                    
                    local scrollY = imgui.GetScrollY()
                    local windowH = imgui.GetWindowHeight()
                    local culling_buffer = 3000
                    
                    for index, msgData in ipairs(profile.history[activeContact]) do
                        local text = u8(msgData.msg)
                        
                        local urls = {}
                        local foundUrls = {}
                        local textToDisplay = text
                        
                        for word in text:gmatch("%S+") do
                            local isUrl = false
                            if word:match("^https?://[a-zA-Z0-9_%-%.%?%.:/%+=&]+") then
                                isUrl = true
                            elseif word:match("^[a-zA-Z0-9%-]+%.[a-zA-Z0-9%-%.]*[a-zA-Z][a-zA-Z]+[a-zA-Z0-9_%-%.%?%.:/%+=&]*$") then
                                isUrl = true
                            elseif word:match("^%d+%.%d+%.%d+%.%d+[:%d]*$") then
                                isUrl = true
                            end
                            
                            if isUrl then
                                if not foundUrls[word] then
                                    foundUrls[word] = true
                                    table.insert(urls, word)
                                    local safeWord = word:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
                                    textToDisplay = textToDisplay:gsub(safeWord, "")
                                end
                            end
                        end
                        textToDisplay = textToDisplay:gsub(" +", " "):match("^%s*(.-)%s*$") or ""
                        
                        local wrap_width = 300 
                        local current_date_str = get_day_string(msgData.timestamp)
                        local has_date = (current_date_str ~= last_date_str)
                        local date_h = has_date and (10 + imgui.GetTextLineHeight()) or 0
                        
                        local timeText = "00:00"
                        if msgData.timestamp and msgData.timestamp > 0 then
                            timeText = os.date("%H:%M", msgData.timestamp)
                        end
                        
                        local urlsStr = table.concat(urls, "|")
                        local loadedStr = ""
                        for _, url in ipairs(urls) do
                            if imageCache[url] and imageCache[url].status == 2 then
                                loadedStr = loadedStr .. url .. imageCache[url].w .. "x" .. imageCache[url].h
                            elseif imageCache[url] and imageCache[url].status == 3 then
                                loadedStr = loadedStr .. url .. "err"
                            end
                        end

                        if not msgData.bubbleSize or msgData.urlsStr ~= urlsStr or msgData.loadedStr ~= loadedStr then
                            local msgTextSize = imgui.ImVec2(0, 0)
                            if textToDisplay ~= "" then
                                msgTextSize = imgui.CalcTextSize(textToDisplay, nil, false, wrap_width)
                            end
                            local timeSize = imgui.CalcTextSize(timeText)
                            local padding = imgui.ImVec2(12, 8)
                            
                            local b_width = 0
                            if textToDisplay ~= "" then
                                b_width = msgTextSize.x
                            end
                            
                            local b_height = padding.y * 1.5 + timeSize.y
                            if textToDisplay ~= "" then
                                b_height = b_height + msgTextSize.y + 5
                            end
                            
                            for _, url in ipairs(urls) do
                                local isImg = url:lower():match("%.png") or url:lower():match("%.jpe?g") or url:lower():match("%.gif")
                                if isImg then
                                    if imageCache[url] and imageCache[url].status == 2 then
                                        b_width = math.max(b_width, imageCache[url].w)
                                        b_height = b_height + imageCache[url].h + 5
                                    else
                                        local load_size = imgui.CalcTextSize(u8"Загрузка...")
                                        b_width = math.max(b_width, load_size.x)
                                        b_height = b_height + load_size.y + 5
                                    end
                                else
                                    local linkSize = imgui.CalcTextSize(url, nil, false, wrap_width)
                                    b_width = math.max(b_width, linkSize.x)
                                    b_height = b_height + linkSize.y + 5
                                end
                            end
                            
                            b_width = math.max(b_width, timeSize.x + 10)
                            
                            msgData.bubbleSize = {x = b_width + padding.x * 2, y = b_height}
                            msgData.timeSize = {x = timeSize.x, y = timeSize.y}
                            msgData.urls = urls
                            msgData.urlsStr = urlsStr
                            msgData.loadedStr = loadedStr
                            msgData.textToDisplay = textToDisplay
                        end
                        
                        local bubbleSize = imgui.ImVec2(msgData.bubbleSize.x, msgData.bubbleSize.y)
                        local timeSize = imgui.ImVec2(msgData.timeSize.x, msgData.timeSize.y)
                        local padding = imgui.ImVec2(12, 8)
                        
                        local startY = imgui.GetCursorPosY()
                        local item_total_h = date_h + bubbleSize.y + 6
                        
                        if startY + item_total_h < scrollY - culling_buffer or startY > scrollY + windowH + culling_buffer then
                            imgui.SetCursorPosY(startY + item_total_h)
                            if has_date then last_date_str = current_date_str end
                        else
                            if has_date then
                                imgui.Spacing()
                                local tSize = imgui.CalcTextSize(u8(current_date_str)).x
                                imgui.SetCursorPosX((imgui.GetWindowWidth() - tSize) / 2)
                                imgui.TextDisabled(u8(current_date_str))
                                imgui.Spacing()
                                last_date_str = current_date_str
                            end
                            
                            local bubble_start_y = imgui.GetCursorPosY()
                            local windowWidth = imgui.GetWindowWidth()
                            local cursorX = imgui.GetCursorPosX()

                            if msgData.sender == "me" then
                                cursorX = windowWidth - bubbleSize.x - 20
                            end
                            
                            imgui.SetCursorPos(imgui.ImVec2(cursorX, bubble_start_y))
                            local screenPos = imgui.GetCursorScreenPos()

                            local color = msgData.sender == "me" and active_theme.me or active_theme.them
                            imgui.GetWindowDrawList():AddRectFilled(
                                screenPos,
                                imgui.ImVec2(screenPos.x + bubbleSize.x, screenPos.y + bubbleSize.y),
                                imgui.GetColorU32Vec4(color), 
                                10.0 
                            )

                            imgui.SetCursorPos(imgui.ImVec2(cursorX, bubble_start_y))
                            imgui.InvisibleButton("msgbtn_" .. index, bubbleSize)
                            imgui.SetItemAllowOverlap() 

                            if imgui.IsItemHovered() then
                                imgui.SetTooltip(u8"Правый клик — скопировать")
                                if imgui.IsMouseClicked(1) then
                                    imgui.SetClipboardText(text)
                                end
                            end

                            local currentOffset = bubble_start_y + padding.y

                            if msgData.textToDisplay ~= "" then
                                imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                local isGeo = (msgData.textToDisplay == "[Геопозиция]" or msgData.textToDisplay == u8"[Геопозиция]")
                                if isGeo then
                                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.7, 1.0, 1.0))
                                else
                                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 1.0, 1.0, 1.0)) 
                                end
                                imgui.PushTextWrapPos(imgui.GetCursorPosX() + wrap_width)
                                imgui.Text(msgData.textToDisplay)
                                imgui.PopTextWrapPos()
                                imgui.PopStyleColor()
                                currentOffset = currentOffset + imgui.CalcTextSize(msgData.textToDisplay, nil, false, wrap_width).y + 5
                            end

                            for u_idx, url in ipairs(msgData.urls) do
                                local isImg = url:lower():match("%.png") or url:lower():match("%.jpe?g") or url:lower():match("%.gif")
                                if isImg then
                                    imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                    
                                    if not imageCache[url] then
                                        imageCache[url] = { status = 1 }
                                        local cleanUrl = url:match("([^%?]+)") or url
                                        local ext = cleanUrl:match("%.([^%.]+)$") or "png"
                                        local tempPath = getWorkingDirectory() .. "\\config\\img_" .. tostring(math.random(100000,999999)) .. "." .. ext
                                        activeTempFiles[tempPath] = true
                                        downloadUrlToFile(url, tempPath, function(id, status)
                                            if status == dlstatus.STATUS_ENDDOWNLOADDATA then
                                                local rtex = renderLoadTextureFromFile(tempPath)
                                                if rtex then
                                                    local tex_w, tex_h = renderGetTextureSize(rtex)
                                                    renderReleaseTexture(rtex)
                                                    
                                                    local tex = imgui.CreateTextureFromFile(tempPath)
                                                    if tex then
                                                        local max_dim = 300.0
                                                        local draw_w, draw_h = tex_w, tex_h
                                                        if tex_w > max_dim or tex_h > max_dim then
                                                            local ratio = tex_w / tex_h
                                                            if tex_w > tex_h then
                                                                draw_w = max_dim
                                                                draw_h = max_dim / ratio
                                                            else
                                                                draw_h = max_dim
                                                                draw_w = max_dim * ratio
                                                            end
                                                        end
                                                        imageCache[url] = { status = 2, tex = tex, w = draw_w, h = draw_h }
                                                    else
                                                        imageCache[url] = { status = 3 }
                                                    end
                                                else
                                                    imageCache[url] = { status = 3 }
                                                end
                                                os.remove(tempPath)
                                                activeTempFiles[tempPath] = nil
                                            elseif status == dlstatus.STATUS_EX_ERROR then
                                                os.remove(tempPath)
                                                activeTempFiles[tempPath] = nil
                                            end
                                        end)
                                    end
                                    
                                    if imageCache[url].status == 1 then
                                        imgui.TextDisabled(u8"Загрузка...")
                                        currentOffset = currentOffset + imgui.CalcTextSize(u8"Загрузка...").y + 5
                                    elseif imageCache[url].status == 2 then
                                        imgui.Image(imageCache[url].tex, imgui.ImVec2(imageCache[url].w, imageCache[url].h))
                                        
                                        imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                        imgui.InvisibleButton("imgbtn_"..index.."_"..u_idx, imgui.ImVec2(imageCache[url].w, imageCache[url].h))
                                        imgui.SetItemAllowOverlap()
                                        if imgui.IsItemHovered() then
                                            imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                                            if imgui.IsMouseClicked(0) then
                                                linkToOpen = url
                                                requestLinkModal = true
                                            end
                                        end
                                        currentOffset = currentOffset + imageCache[url].h + 5
                                    elseif imageCache[url].status == 3 then
                                        imgui.TextDisabled(u8"Ошибка загрузки")
                                        currentOffset = currentOffset + imgui.CalcTextSize(u8"Ошибка загрузки").y + 5
                                    end
                                else
                                    imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                    local minPos = imgui.GetCursorScreenPos()
                                    
                                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.7, 1.0, 1.0))
                                    imgui.PushTextWrapPos(imgui.GetCursorPosX() + wrap_width)
                                    imgui.Text(url)
                                    imgui.PopTextWrapPos()
                                    imgui.PopStyleColor()
                                    
                                    local endPos = imgui.GetItemRectMax()
                                    imgui.GetWindowDrawList():AddLine(imgui.ImVec2(minPos.x, endPos.y), imgui.ImVec2(endPos.x, endPos.y), imgui.GetColorU32Vec4(imgui.ImVec4(0.4, 0.7, 1.0, 1.0)))
                                    
                                    local linkSize = imgui.ImVec2(endPos.x - minPos.x, endPos.y - minPos.y)
                                    imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                    imgui.InvisibleButton("txtbtn_"..index.."_"..u_idx, linkSize)
                                    imgui.SetItemAllowOverlap()
                                    
                                    if imgui.IsItemHovered() then
                                        imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                                        if imgui.IsMouseClicked(0) then
                                            linkToOpen = url
                                            requestLinkModal = true
                                        end
                                    end
                                    
                                    currentOffset = currentOffset + linkSize.y + 5
                                end
                            end

                            local time_x = cursorX + bubbleSize.x - timeSize.x - padding.x + 4
                            local time_y = bubble_start_y + bubbleSize.y - timeSize.y - padding.y / 2
                            imgui.SetCursorPos(imgui.ImVec2(time_x, time_y))
                            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 0.8), timeText)

                            imgui.SetCursorPosY(bubble_start_y + bubbleSize.y + 6)
                        end
                    end
                end
                
                imgui.Spacing()
                
                if scrollToBottom then
                    imgui.SetScrollHereY(1.0)
                    scrollToBottom = false
                end
                
                imgui.EndChild()
                
                if activeContact == "Bank_System" or activeContact == "System_News" then
                    local bText = u8"Это системный чат. Ответить на эти сообщения нельзя."
                    local text_h = imgui.GetTextLineHeight()
                    local offset_y = (40 - text_h) / 2
                    
                    imgui.SetCursorPosY(imgui.GetCursorPosY() + offset_y)
                    imgui.SetCursorPosX((imgui.GetWindowWidth() - imgui.CalcTextSize(bText).x) / 2)
                    imgui.TextDisabled(bText)
                else
                    imgui.Spacing()
                    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8.0)
                    local currentPaddingY = imgui.GetStyle().FramePadding.y
                    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(10.0, currentPaddingY)) 
                    imgui.PushItemWidth(-80) 
                    
                    if requestFocus then
                        imgui.SetKeyboardFocusHere()
                        requestFocus = false
                    end
                    
                    if imgui.InputTextWithHint("##MessageInput", u8"Напишите сообщение...", inputMessage, 512, imgui.InputTextFlags.EnterReturnsTrue) then
                        sendMessage(activeContact)
                    end
                    
                    imgui.PopItemWidth()
                    imgui.PopStyleVar(2) 
                    
                    imgui.SameLine()
                    if imgui.Button(u8"Отправить", imgui.ImVec2(0, 0)) then
                        sendMessage(activeContact)
                    end
                end
            else
                imgui.Text(u8"Выберите контакт для начала переписки.")
            end

            imgui.Columns(1)
            imgui.End()
        end
        
        imgui.PopStyleColor(15) 
    end
)

function sendMessage(number)
    local text = u8:decode(ffi.string(inputMessage))
    if text ~= "" then
        sampSendChat("/sms " .. number .. " " .. text)
        inputMessage[0] = 0
        requestFocus = true
        scrollToBottom = true
    end
end
