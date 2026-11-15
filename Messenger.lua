script_name("ImGui Messenger")
local script_version = 2.5

local samp = require 'samp.events'
local imgui = require 'mimgui'
local encoding = require 'encoding'
local vkeys = require 'vkeys'
local dlstatus = require('moonloader').download_status
local lfs = require 'lfs'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local os = require 'os'
local io = require 'io'
local ffi = require 'ffi'

math.randomseed(os.time() + math.floor(os.clock() * 1000))

ffi.cdef[[
    void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
    
    typedef struct IDirect3DTexture9 IDirect3DTexture9;
    struct IDirect3DTexture9 {
        struct {
            void* QueryInterface;
            uint32_t (__stdcall *AddRef)(IDirect3DTexture9*);
            uint32_t (__stdcall *Release)(IDirect3DTexture9*);
        }* lpVtbl;
    };
]]
local shell32 = ffi.load('shell32')

local function toHex(str)
    return (str:gsub('.', function(c)
        return string.format('%02X', string.byte(c))
    end))
end

local function fromHex(str)
    return (str:gsub('..', function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

local function isValidRpNick(nick)
    if type(nick) ~= "string" or nick == "Default" then return false end
    if not nick:match("^[A-Z][a-zA-Z]+_[a-zA-Z_]+$") then return false end
    if nick:find("__") or not nick:match("_[A-Z][a-zA-Z]+$") then return false end
    return true
end

local function removeProfileFolder(nick)
    if not nick or nick == "" or nick == "." or nick == ".." then return end
    local pDir = getWorkingDirectory() .. '\\config\\Messenger\\' .. nick
    if lfs.attributes(pDir, "mode") ~= "directory" then return end
    local cDir = pDir .. '\\chats'
    if lfs.attributes(cDir, "mode") == "directory" then
        for file in lfs.dir(cDir) do
            if file ~= "." and file ~= ".." then
                pcall(os.remove, cDir .. '\\' .. file)
            end
        end
        pcall(lfs.rmdir, cDir)
    end
    for file in lfs.dir(pDir) do
        if file ~= "." and file ~= ".." then
            pcall(os.remove, pDir .. '\\' .. file)
        end
    end
    pcall(lfs.rmdir, pDir)
end

local oldMasterFile = getWorkingDirectory() .. '\\config\\Messenger.json'
local settingsFile = getWorkingDirectory() .. '\\config\\Messenger\\settings.json'

local phoneData = {}
local activeChatHistory = nil
local activeChatId = nil
local smsOutQueue = {}
local lastSmsOutTime = 0
local smsSendDelay = 1.0
local lastSentSmsTask = nil

local mainFolder = getWorkingDirectory() .. '\\config\\Messenger\\'
pcall(lfs.mkdir, mainFolder)
local cacheFolder = mainFolder .. 'cache\\'
pcall(lfs.mkdir, cacheFolder)
local imagesFolder = mainFolder .. 'images\\'
pcall(lfs.mkdir, imagesFolder)

local downloadQueue = {}
local activeDownloads = 0

local function isImageSafe(path)
    local size = lfs.attributes(path, "size")
    if not size or size < 64 then return false end
    local f = io.open(path, "rb")
    if not f then return false end
    local bytes = f:read(4)
    f:close()
    if not bytes or #bytes < 4 then return false end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    if b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then return true end
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then return true end
    if b1 == 0x47 and b2 == 0x49 and b3 == 0x46 then return true end
    return false
end
local imageCache = {}
local imageCacheKeys = {}
local activeTempFiles = {}
local onlinePlayers = {}
local onlinePlayersById = {}

local globalSettings = {
    theme = 1,
    font = 1,
    useScreenNotifications = false,
    logBank = false,
    hideSmsJunk = false,
    autoUpdate = true,
    lastNewsText = "",
    notifPos = 3,
    dndMode = false,
    autoDownloadMedia = true,
    openCommand = "p",
    openKey = vkeys.VK_P,
    openMod = vkeys.VK_MENU,
    customThemes = {},
    contactSortMode = 1,
    uiScale = 1.0,
    hideUnreadOnLogin = false,
    gallery = {},
    closeChatOnEsc = false,
    saveImagesPersistently = false,
    fontSize = 14.0,
    hideContactNumber = false,
    lastStatDate = "",
    lastChangelogText = "",
    clientId = "",
    iosPhoneMode = false,
    iosTheme = 1
}

local loadedFontSize = 14.0

local newsUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/news.txt"
local updateUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/update.json"
local changelogUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/changelog.txt"
local verifyUrl = "https://raw.githubusercontent.com/kaip0v/Messenger/main/resource/verify.json"

local globalVerified = {}

local myNick = "Default"
local actualPlayerNick = "Default"
local lastSeenNick = "Default"
local activeContact = nil

local lastSmsPhone = nil
local lastSmsIsUnread = false
local lastSmsIsDup = false
local lastSmsSysTime = 0
local lastSmsWasSkipped = false
local pendingLocalSms = {}
local pending_new_format_sms = nil
local pending_new_format_time = 0

local cachedSortedContacts = {}
local needSortContacts = true

local UI = {
    windowState = imgui.new.bool(false),
    requestFocus = false,
    scrollToBottom = false,
    requestFocusSearch = false,
    contactToDelete = nil,
    requestDeletePopup = false,
    linkToOpen = "",
    requestLinkModal = false,
    requestContactModal = false,
    inputContactName = imgui.new.char[256](""),
    inputContactNumber = imgui.new.char[256](""),
    inputContactNick = imgui.new.char[256](""),
    inputMessage = imgui.new.char[2048](""),
    inputSearchContact = imgui.new.char[256](""),
    inputSearchMessage = imgui.new.char[256](""),
    inputOpenCommand = imgui.new.char[64](""),
    showMessageSearch = false,
    showCallHistory = false,
    callOpenedFromChat = false,
    showGallery = imgui.new.bool(false),
    viewingCallIndex = 0,
	viewingImage = nil,
    settingScreenNotif = imgui.new.bool(false),
    settingLogBank = imgui.new.bool(false),
    settingHideJunk = imgui.new.bool(false),
    settingAutoUpdate = imgui.new.bool(false),
    settingDND = imgui.new.bool(false),
    settingAutoDownload = imgui.new.bool(true),
    settingHideUnread = imgui.new.bool(false),
    settingCloseChatOnEsc = imgui.new.bool(false),
    settingSaveImages = imgui.new.bool(false),
    settingHideContactNumber = imgui.new.bool(false),
    settingIosPhoneMode = imgui.new.bool(false),
    showContactProfile = false,
    showThemeEditor = imgui.new.bool(false),
    forceResize = false,
    anyModalOpen = false,
    requestCloseModal = false,
    confirmDeleteProfileTimer = 0
}

local Sys = {
    activeNotification = nil,
    tempSysNotifText = nil,
    tempSysNotifTimer = 0,
    tempSysNotifType = 0,
    wasTypingEscape = false
}

local Bank = {
    isCollecting = false,
    buffer = {}
}

local Macro = {
    autoCleaning = false,
    cleanStep = 0,
    autoGeo = false,
    geoStep = 0,
    targetGeoNumber = "",
    waitingForGeoConfirm = false,
    autoBlock = false
}

local CallState = {
    active = false,
    number = nil,
    startTime = 0,
    saved = false,
    callIndex = nil,
    messages = {},
    lastMsgSysTime = 0
}

local ThemeEditor = {
    temp = {
        me = imgui.new.float[4](0,0,0,1),
        them = imgui.new.float[4](0,0,0,1),
        warn = imgui.new.float[4](0,0,0,1),
        notif_bg = imgui.new.float[4](0,0,0,1),
        notif_text = imgui.new.float[4](0,0,0,1),
        sys_ok = imgui.new.float[4](0,0,0,1),
        sys_err = imgui.new.float[4](0,0,0,1),
        sys_info = imgui.new.float[4](0,0,0,1),
        online = imgui.new.float[4](0.2, 0.8, 0.2, 1.0),
        muted = imgui.new.float[4](0.6, 0.6, 0.6, 1.0),
        draft = imgui.new.float[4](0.8, 0.4, 0.4, 1.0),
        call_me = imgui.new.float[4](0.4, 0.7, 1.0, 1.0),
        call_them = imgui.new.float[4](1.0, 1.0, 1.0, 1.0),
        call_time = imgui.new.float[4](0.5, 0.5, 0.5, 1.0),
        checkmark = imgui.new.float[4](0.18, 0.35, 0.58, 1.0),
        badge_text = imgui.new.float[4](1.0, 1.0, 1.0, 1.0),
        bubble_muted = imgui.new.float[4](0.5, 0.5, 0.5, 1.0)
    },
    colorNames = {
        {"me", u8"Акцент (Мои SMS, Кнопки)"},
        {"them", u8"Фон (Чужие SMS, Окна)"},
        {"warn", u8"Внимание (Непрочитанные)"},
        {"notif_bg", u8"Фон уведомлений"},
        {"notif_text", u8"Текст уведомлений"},
        {"sys_ok", u8"Системные: Успех"},
        {"sys_err", u8"Системные: Ошибка"},
        {"sys_info", u8"Системные: Инфо"},
        {"online", u8"Индикатор онлайна"},
        {"muted", u8"Текст [Мут]"},
        {"draft", u8"Текст [Черновик]"},
        {"call_me", u8"Звонок: Мой текст"},
        {"call_them", u8"Звонок: Собеседник"},
        {"call_time", u8"Звонок: Время"},
        {"checkmark", u8"Цвет галочек (Настройки)"},
        {"badge_text", u8"Текст в бейджах (Новые SMS)"},
        {"bubble_muted", u8"Фон SMS в муте (Серый)"}
    },
    selectedIdx = 1
}

local availableKeys = {}
for i = 65, 90 do
    table.insert(availableKeys, {name = string.char(i), val = i})
end

local availableMods = {
    {name = u8"Нет", val = 0},
    {name = "ALT", val = vkeys.VK_MENU},
    {name = "CTRL", val = vkeys.VK_CONTROL},
    {name = "SHIFT", val = vkeys.VK_SHIFT}
}

local sortModes = {
    u8"По последнему сообщению",
    u8"Сначала сохраненные контакты",
    u8"Сначала онлайн"
}

local function showSystemNotification(text, nType)
    Sys.tempSysNotifText = text
    Sys.tempSysNotifType = nType or 0
    Sys.tempSysNotifTimer = os.clock() + 3.0
end

local function SaveCurrentDraft()
    if not activeContact or not phoneData[myNick] then return end
    local profile = phoneData[myNick]
    if not profile.drafts then profile.drafts = {} end
    local currentText = ffi.string(UI.inputMessage)
    if currentText ~= "" then
        profile.drafts[activeContact] = u8:decode(currentText)
    else
        profile.drafts[activeContact] = nil
    end
end

local function LoadDraft(number)
    if not phoneData[myNick] then return end
    local profile = phoneData[myNick]
    local draftText = (profile.drafts and profile.drafts[number]) and profile.drafts[number] or ""
    ffi.copy(UI.inputMessage, u8(draftText))
end

local function ClearDraft(number)
    if not phoneData[myNick] then return end
    local profile = phoneData[myNick]
    if profile.drafts then profile.drafts[number] = nil end
    UI.inputMessage[0] = 0
end

local themes = {
    { name = "Классический синий", me = imgui.ImVec4(0.18, 0.35, 0.58, 1.0), them = imgui.ImVec4(0.25, 0.25, 0.25, 1.0), warn = imgui.ImVec4(0.20, 0.60, 0.90, 1.0), notif_bg = imgui.ImVec4(0.12, 0.12, 0.12, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.20, 0.60, 0.90, 0.80) },
    { name = "Темная ночь", me = imgui.ImVec4(0.35, 0.35, 0.35, 1.0), them = imgui.ImVec4(0.12, 0.12, 0.12, 1.0), warn = imgui.ImVec4(0.70, 0.70, 0.70, 1.0), notif_bg = imgui.ImVec4(0.08, 0.08, 0.08, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.50, 0.50, 0.50, 0.80) },
    { name = "Telegram (Dark)", me = imgui.ImVec4(0.17, 0.35, 0.53, 1.0), them = imgui.ImVec4(0.11, 0.14, 0.18, 1.0), warn = imgui.ImVec4(0.25, 0.55, 0.85, 1.0), notif_bg = imgui.ImVec4(0.09, 0.11, 0.14, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.25, 0.55, 0.85, 0.80) },
    { name = "WhatsApp (Dark)", me = imgui.ImVec4(0.02, 0.38, 0.33, 1.0), them = imgui.ImVec4(0.12, 0.17, 0.20, 1.0), warn = imgui.ImVec4(0.10, 0.70, 0.40, 1.0), notif_bg = imgui.ImVec4(0.07, 0.12, 0.13, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.10, 0.70, 0.40, 0.80) },
    { name = "AMOLED Черный", me = imgui.ImVec4(0.25, 0.25, 0.25, 1.0), them = imgui.ImVec4(0.05, 0.05, 0.05, 1.0), warn = imgui.ImVec4(0.80, 0.80, 0.80, 1.0), notif_bg = imgui.ImVec4(0.0, 0.0, 0.0, 0.95), notif_text = imgui.ImVec4(0.95, 0.95, 0.95, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.60, 0.60, 0.60, 0.80) },
    { name = "Изумрудный", me = imgui.ImVec4(0.15, 0.45, 0.25, 1.0), them = imgui.ImVec4(0.20, 0.25, 0.20, 1.0), warn = imgui.ImVec4(0.20, 0.70, 0.30, 1.0), notif_bg = imgui.ImVec4(0.08, 0.15, 0.10, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.20, 0.70, 0.30, 0.80) },
    { name = "Малиновый закат", me = imgui.ImVec4(0.50, 0.20, 0.35, 1.0), them = imgui.ImVec4(0.25, 0.15, 0.20, 1.0), warn = imgui.ImVec4(0.80, 0.30, 0.50, 1.0), notif_bg = imgui.ImVec4(0.15, 0.08, 0.12, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.80, 0.30, 0.50, 0.80) },
    { name = "Осенний лес", me = imgui.ImVec4(0.65, 0.33, 0.05, 1.0), them = imgui.ImVec4(0.25, 0.32, 0.22, 1.0), warn = imgui.ImVec4(0.90, 0.50, 0.10, 1.0), notif_bg = imgui.ImVec4(0.15, 0.12, 0.08, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.90, 0.50, 0.10, 0.80) },
    { name = "Океанская бездна", me = imgui.ImVec4(0.05, 0.30, 0.45, 1.0), them = imgui.ImVec4(0.05, 0.15, 0.25, 1.0), warn = imgui.ImVec4(0.10, 0.60, 0.80, 1.0), notif_bg = imgui.ImVec4(0.04, 0.08, 0.15, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.10, 0.60, 0.80, 0.80) }
}

for _, t in ipairs(themes) do
    t.online = t.online or imgui.ImVec4(0.2, 0.8, 0.2, 1.0)
    t.muted = t.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
    t.draft = t.draft or imgui.ImVec4(0.8, 0.4, 0.4, 1.0)
    t.call_me = t.call_me or imgui.ImVec4(0.4, 0.7, 1.0, 1.0)
    t.call_them = t.call_them or imgui.ImVec4(1.0, 1.0, 1.0, 1.0)
    t.call_time = t.call_time or imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
    t.checkmark = t.checkmark or t.me
    t.badge_text = t.badge_text or imgui.ImVec4(1.0, 1.0, 1.0, 1.0)
    
    local is_light = (t.them.x + t.them.y + t.them.z) > 1.5
    if is_light then
        t.bubble_muted = t.bubble_muted or imgui.ImVec4(math.max(0, t.them.x - 0.15), math.max(0, t.them.y - 0.15), math.max(0, t.them.z - 0.15), 1.0)
    else
        t.bubble_muted = t.bubble_muted or imgui.ImVec4(math.min(1, t.them.x + 0.15), math.min(1, t.them.y + 0.15), math.min(1, t.them.z + 0.15), 1.0)
    end
end

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

local function cp1251_lower(str)
    local res = {}
    for i = 1, #str do
        local b = str:byte(i)
        if b >= 192 and b <= 223 then
            res[i] = string.char(b + 32)
        elseif b == 168 then
            res[i] = string.char(184)
        elseif b >= 65 and b <= 90 then
            res[i] = string.char(b + 32)
        else
            res[i] = string.char(b)
        end
    end
    return table.concat(res)
end

local function truncateToLastWord(text, maxWidth)
    if imgui.CalcTextSize(text).x <= maxWidth then return text end
    local current_str = ""
    local ellipsis = "..."
    for word in text:gmatch("%S+") do
        local test_str = current_str == "" and word or (current_str .. " " .. word)
        if imgui.CalcTextSize(test_str .. ellipsis).x > maxWidth then
            if current_str == "" then return ellipsis end
            return current_str .. ellipsis
        end
        current_str = test_str
    end
    return current_str .. ellipsis
end

local function truncateText(text, maxWidth)
    if imgui.CalcTextSize(text).x <= maxWidth then return text end
    local cp_text = u8:decode(text) or text
    local ellipsis = "..."
    for i = #cp_text, 1, -1 do
        if imgui.CalcTextSize(u8(cp_text:sub(1, i)) .. ellipsis).x <= maxWidth then
            return u8(cp_text:sub(1, i)) .. ellipsis
        end
    end
    return ellipsis
end

local function cleanupGhostFiles()
    pcall(lfs.mkdir, cacheFolder)
    pcall(function()
        local now = os.time()
        for file in lfs.dir(cacheFolder) do
            if file ~= "." and file ~= ".." then
                local path = cacheFolder .. file
                local mod = lfs.attributes(path, "modification") or 0
                if now - mod > 86400 then
                    pcall(os.remove, path)
                end
            end
        end
    end)
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

local availableFonts = {
    { name = u8"Стандартный (Trebuchet MS)", path = nil },
    { name = "Arial", path = "C:\\Windows\\Fonts\\arial.ttf" },
    { name = "Arial Bold", path = "C:\\Windows\\Fonts\\arialbd.ttf" },
    { name = "Comic Sans MS", path = "C:\\Windows\\Fonts\\comic.ttf" },
    { name = "Tahoma", path = "C:\\Windows\\Fonts\\tahoma.ttf" }
}

pcall(function()
    for file in lfs.dir(mainFolder) do
        if type(file) == "string" then
            local ext = file:match("^.+(%.%w+)$")
            if ext and (ext:lower() == ".ttf" or ext:lower() == ".otf") then
                local fontName = file:match("^(.+)%.%w+$")
                table.insert(availableFonts, { name = u8(fontName), path = mainFolder .. file })
            end
        end
    end
end)

local fontNames = {}
for _, f in ipairs(availableFonts) do
    table.insert(fontNames, f.name)
end

local customFonts = {}

imgui.OnInitialize(function()
    local glyphRanges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    
    local currentFont = 1
        local currentSize = 14.0
        local file = io.open(settingsFile, "rb")
        if not file then file = io.open(oldMasterFile, "rb") end
        if file then
        local content = file:read("*a")
        file:close()
        local fontMatch = content:match('%["font"%]%s*=%s*(%d+)') or content:match('["\']font["\']%s*:%s*(%d+)')
        if fontMatch then currentFont = tonumber(fontMatch) end
        local sizeMatch = content:match('%["fontSize"%]%s*=%s*([%d%.]+)') or content:match('["\']fontSize["\']%s*:%s*([%d%.]+)')
        if sizeMatch then currentSize = tonumber(sizeMatch) end
    end
    
    loadedFontSize = currentSize
    
    if currentFont > #availableFonts then currentFont = 1 end
    
    local selectedFont = availableFonts[currentFont]
    if selectedFont and selectedFont.path and file_exists(selectedFont.path) then
        customFonts[currentFont] = imgui.GetIO().Fonts:AddFontFromFileTTF(selectedFont.path, currentSize, nil, glyphRanges)
    end
end)

local function save_json(path, data)
    local file = io.open(path, "wb")
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
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    
    if content == nil or content:gsub("%s", "") == "" then return {} end
    
    local ok, res = pcall(decodeJson, content)
    if ok and type(res) == "table" then return res end
    
    local func = load(content)
    if func then
        local ok2, res2 = pcall(func)
        if ok2 and type(res2) == "table" then return res2 end
    end
    
    return false
end

local function save_global_settings()
    save_json(settingsFile, globalSettings)
end

local function save_profile_data(nick)
    if not phoneData[nick] then return end
    local pDir = getWorkingDirectory() .. '\\config\\Messenger\\' .. nick
    pcall(lfs.mkdir, pDir)
    pcall(lfs.mkdir, pDir .. '\\chats')
    local pData = {}
    for k, v in pairs(phoneData[nick]) do
        if k ~= "history" then pData[k] = v end
    end
    save_json(pDir .. '\\profile.json', pData)
end

local function save_chat_data(nick, chatId, historyData)
    local path = getWorkingDirectory() .. '\\config\\Messenger\\' .. nick .. '\\chats\\' .. chatId .. '.json'
    local cleanHistory = {}
    if type(historyData) == "table" then
        for i, msg in ipairs(historyData) do
            cleanHistory[i] = {
                sender = msg.sender,
                msg = msg.msg,
                timestamp = msg.timestamp
            }
        end
    end
    save_json(path, cleanHistory)
end

local function save_all_data()
    save_global_settings()
    for nick, _ in pairs(phoneData) do
        save_profile_data(nick)
    end
    if myNick and activeChatId and activeChatHistory then
        save_chat_data(myNick, activeChatId, activeChatHistory)
    end
end

local function load_chat_history(nick, chatId)
    if not nick or not chatId then return {} end
    local path = getWorkingDirectory() .. '\\config\\Messenger\\' .. nick .. '\\chats\\' .. chatId .. '.json'
    if file_exists(path) then
        local data = load_json(path)
        return type(data) == "table" and data or {}
    end
    return {}
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

local function formatMessageTime(ts)
    if not ts or ts == 0 then return "00:00" end
    local now = os.time()
    local t_now = os.date("*t", now)
    local t_msg = os.date("*t", ts)
    local today_start = os.time({year = t_now.year, month = t_now.month, day = t_now.day})
    local msg_start = os.time({year = t_msg.year, month = t_msg.month, day = t_msg.day})
    local diff_days = math.floor(os.difftime(today_start, msg_start) / 86400 + 0.5)
    
    if diff_days == 0 then
        return os.date("%H:%M", ts)
    elseif diff_days >= 1 and diff_days <= 6 then
        local dmap = { [1] = "Вс", [2] = "Пн", [3] = "Вт", [4] = "Ср", [5] = "Чт", [6] = "Пт", [7] = "Сб" }
        return u8(dmap[t_msg.wday])
    else
        return os.date("%d.%m.%Y", ts)
    end
end

local function clamp(val) 
    return math.max(0.0, math.min(1.0, val)) 
end

local function DrawVerificationBadge(dl, center, radius, scale)
    local bg_col = imgui.GetColorU32Vec4(imgui.ImVec4(0.11, 0.63, 0.95, 1.0))
    local fg_col = imgui.GetColorU32Vec4(imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
    
    local petals = 10
    for i = 0, petals - 1 do
        local angle = (i / petals) * math.pi * 2
        local px = center.x + math.cos(angle) * (radius * 0.7)
        local py = center.y + math.sin(angle) * (radius * 0.7)
        dl:AddCircleFilled(imgui.ImVec2(px, py), radius * 0.45, bg_col, 12)
    end
    dl:AddCircleFilled(center, radius * 0.85, bg_col, 24)
    
    local thick = 2.0 * scale
    local p1 = imgui.ImVec2(center.x - radius * 0.45, center.y + radius * 0.05)
    local p2 = imgui.ImVec2(center.x - radius * 0.20, center.y + radius * 0.35)
    local p3 = imgui.ImVec2(center.x + radius * 0.35, center.y - radius * 0.30)
    
    dl:AddLine(p1, p2, fg_col, thick)
    dl:AddLine(p2, p3, fg_col, thick)
end

local function DrawPinBadge(dl, center, radius, scale)
    local r = radius * 1.15
    local pin_col = imgui.GetColorU32Vec4(imgui.ImVec4(1.0, 0.78, 0.20, 1.0))
    local needle_col = imgui.GetColorU32Vec4(imgui.ImVec4(0.90, 0.92, 0.95, 1.0))
    
    dl:AddLine(
        imgui.ImVec2(center.x - r * 0.15, center.y + r * 0.15),
        imgui.ImVec2(center.x - r * 0.95, center.y + r * 0.95),
        needle_col, 2.0 * scale
    )
    dl:AddLine(
        imgui.ImVec2(center.x - r * 0.20, center.y + r * 0.20),
        imgui.ImVec2(center.x + r * 0.50, center.y - r * 0.50),
        pin_col, 3.6 * scale
    )
    dl:AddLine(
        imgui.ImVec2(center.x - r * 0.60, center.y - r * 0.10),
        imgui.ImVec2(center.x + r * 0.10, center.y + r * 0.60),
        pin_col, 2.4 * scale
    )
    dl:AddLine(
        imgui.ImVec2(center.x + r * 0.20, center.y - r * 0.80),
        imgui.ImVec2(center.x + r * 0.80, center.y - r * 0.20),
        pin_col, 2.4 * scale
    )
end

local function DrawMuteBadge(dl, center, radius, scale, colorVec4)
    local r = radius * 1.15
    local col = imgui.GetColorU32Vec4(colorVec4 or imgui.ImVec4(0.65, 0.65, 0.65, 1.0))
    local strike_col = imgui.GetColorU32Vec4(imgui.ImVec4(0.95, 0.35, 0.35, 1.0))
    
    dl:AddRectFilled(
        imgui.ImVec2(center.x - r * 0.85, center.y - r * 0.35),
        imgui.ImVec2(center.x - r * 0.35, center.y + r * 0.35),
        col, 1.5 * scale
    )
    dl:AddTriangleFilled(
        imgui.ImVec2(center.x - r * 0.45, center.y),
        imgui.ImVec2(center.x + r * 0.20, center.y - r * 0.80),
        imgui.ImVec2(center.x + r * 0.20, center.y + r * 0.80),
        col
    )
    dl:AddLine(
        imgui.ImVec2(center.x - r * 0.75, center.y - r * 0.75),
        imgui.ImVec2(center.x + r * 0.75, center.y + r * 0.75),
        strike_col, 2.2 * scale
    )
end

local function DrawBlockBadge(dl, center, radius, scale)
    local r = radius * 1.05
    local col = imgui.GetColorU32Vec4(imgui.ImVec4(0.90, 0.25, 0.25, 1.0))
    dl:AddCircle(center, r, col, 20, 2.2 * scale)
    dl:AddLine(
        imgui.ImVec2(center.x - r * 0.68, center.y - r * 0.68),
        imgui.ImVec2(center.x + r * 0.68, center.y + r * 0.68),
        col, 2.2 * scale
    )
end

local function formatCallDuration(calc_duration)
    if not calc_duration or calc_duration <= 0 then return "0 сек." end
    local h = math.floor(calc_duration / 3600)
    local m = math.floor((calc_duration % 3600) / 60)
    local s = calc_duration % 60
    if h > 0 then
        return string.format("%d ч. %d мин. %d сек.", h, m, s)
    elseif m > 0 then
        return string.format("%d мин. %d сек.", m, s)
    else
        return string.format("%d сек.", s)
    end
end

local function GetActiveTheme()
    if UI.showThemeEditor[0] then
        return {
            me = imgui.ImVec4(ThemeEditor.temp.me[0], ThemeEditor.temp.me[1], ThemeEditor.temp.me[2], ThemeEditor.temp.me[3]),
            them = imgui.ImVec4(ThemeEditor.temp.them[0], ThemeEditor.temp.them[1], ThemeEditor.temp.them[2], ThemeEditor.temp.them[3]),
            warn = imgui.ImVec4(ThemeEditor.temp.warn[0], ThemeEditor.temp.warn[1], ThemeEditor.temp.warn[2], ThemeEditor.temp.warn[3]),
            notif_bg = imgui.ImVec4(ThemeEditor.temp.notif_bg[0], ThemeEditor.temp.notif_bg[1], ThemeEditor.temp.notif_bg[2], ThemeEditor.temp.notif_bg[3]),
            notif_text = imgui.ImVec4(ThemeEditor.temp.notif_text[0], ThemeEditor.temp.notif_text[1], ThemeEditor.temp.notif_text[2], ThemeEditor.temp.notif_text[3]),
            sys_ok = imgui.ImVec4(ThemeEditor.temp.sys_ok[0], ThemeEditor.temp.sys_ok[1], ThemeEditor.temp.sys_ok[2], ThemeEditor.temp.sys_ok[3]),
            sys_err = imgui.ImVec4(ThemeEditor.temp.sys_err[0], ThemeEditor.temp.sys_err[1], ThemeEditor.temp.sys_err[2], ThemeEditor.temp.sys_err[3]),
            sys_info = imgui.ImVec4(ThemeEditor.temp.sys_info[0], ThemeEditor.temp.sys_info[1], ThemeEditor.temp.sys_info[2], ThemeEditor.temp.sys_info[3]),
            online = imgui.ImVec4(ThemeEditor.temp.online[0], ThemeEditor.temp.online[1], ThemeEditor.temp.online[2], ThemeEditor.temp.online[3]),
            muted = imgui.ImVec4(ThemeEditor.temp.muted[0], ThemeEditor.temp.muted[1], ThemeEditor.temp.muted[2], ThemeEditor.temp.muted[3]),
            draft = imgui.ImVec4(ThemeEditor.temp.draft[0], ThemeEditor.temp.draft[1], ThemeEditor.temp.draft[2], ThemeEditor.temp.draft[3]),
            call_me = imgui.ImVec4(ThemeEditor.temp.call_me[0], ThemeEditor.temp.call_me[1], ThemeEditor.temp.call_me[2], ThemeEditor.temp.call_me[3]),
            call_them = imgui.ImVec4(ThemeEditor.temp.call_them[0], ThemeEditor.temp.call_them[1], ThemeEditor.temp.call_them[2], ThemeEditor.temp.call_them[3]),
            call_time = imgui.ImVec4(ThemeEditor.temp.call_time[0], ThemeEditor.temp.call_time[1], ThemeEditor.temp.call_time[2], ThemeEditor.temp.call_time[3]),
            checkmark = imgui.ImVec4(ThemeEditor.temp.checkmark[0], ThemeEditor.temp.checkmark[1], ThemeEditor.temp.checkmark[2], ThemeEditor.temp.checkmark[3]),
            badge_text = imgui.ImVec4(ThemeEditor.temp.badge_text[0], ThemeEditor.temp.badge_text[1], ThemeEditor.temp.badge_text[2], ThemeEditor.temp.badge_text[3]),
            bubble_muted = imgui.ImVec4(ThemeEditor.temp.bubble_muted[0], ThemeEditor.temp.bubble_muted[1], ThemeEditor.temp.bubble_muted[2], ThemeEditor.temp.bubble_muted[3]),
            name = "Live Preview"
        }
    else
        if globalSettings.theme > #themes and globalSettings.customThemes and globalSettings.customThemes[globalSettings.theme - #themes] then
            local ct = globalSettings.customThemes[globalSettings.theme - #themes]
            local function sv(a, d) return (a and type(a) == "table" and #a>=4) and imgui.ImVec4(a[1],a[2],a[3],a[4]) or d end
            return {
                me = sv(ct.me, imgui.ImVec4(0.18, 0.35, 0.58, 1.0)),
                them = sv(ct.them, imgui.ImVec4(0.25, 0.25, 0.25, 1.0)),
                warn = sv(ct.warn, imgui.ImVec4(0.20, 0.60, 0.90, 1.0)),
                notif_bg = sv(ct.notif_bg, imgui.ImVec4(0.12, 0.12, 0.12, 0.95)),
                notif_text = sv(ct.notif_text, imgui.ImVec4(0.9, 0.9, 0.9, 1.0)),
                sys_ok = sv(ct.sys_ok, imgui.ImVec4(0.20, 0.80, 0.20, 0.80)),
                sys_err = sv(ct.sys_err, imgui.ImVec4(0.80, 0.20, 0.20, 0.80)),
                sys_info = sv(ct.sys_info, imgui.ImVec4(0.20, 0.60, 0.90, 0.80)),
                online = sv(ct.online, imgui.ImVec4(0.2, 0.8, 0.2, 1.0)),
                muted = sv(ct.muted, imgui.ImVec4(0.6, 0.6, 0.6, 1.0)),
                draft = sv(ct.draft, imgui.ImVec4(0.8, 0.4, 0.4, 1.0)),
                call_me = sv(ct.call_me, imgui.ImVec4(0.4, 0.7, 1.0, 1.0)),
                call_them = sv(ct.call_them, imgui.ImVec4(1.0, 1.0, 1.0, 1.0)),
                call_time = sv(ct.call_time, imgui.ImVec4(0.5, 0.5, 0.5, 1.0)),
                checkmark = sv(ct.checkmark, ct.me and imgui.ImVec4(ct.me[1],ct.me[2],ct.me[3],ct.me[4]) or imgui.ImVec4(0.18, 0.35, 0.58, 1.0)),
                badge_text = sv(ct.badge_text, imgui.ImVec4(1.0, 1.0, 1.0, 1.0)),
                bubble_muted = sv(ct.bubble_muted, imgui.ImVec4(0.5, 0.5, 0.5, 1.0)),
                name = "Пользовательская тема #" .. (globalSettings.theme - #themes)
            }
        else
            local t = themes[globalSettings.theme] or themes[1]
            t.online = t.online or imgui.ImVec4(0.2, 0.8, 0.2, 1.0)
            t.muted = t.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
            t.draft = t.draft or imgui.ImVec4(0.8, 0.4, 0.4, 1.0)
            t.call_me = t.call_me or imgui.ImVec4(0.4, 0.7, 1.0, 1.0)
            t.call_them = t.call_them or imgui.ImVec4(1.0, 1.0, 1.0, 1.0)
            t.call_time = t.call_time or imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
            t.checkmark = t.checkmark or t.me
            t.badge_text = t.badge_text or imgui.ImVec4(1.0, 1.0, 1.0, 1.0)
            t.bubble_muted = t.bubble_muted or imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
            return t
        end
    end
end

local function ApplyTheme(active_theme, bg_alpha)
    bg_alpha = bg_alpha or 0.95
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
    
    local grab = acc
    local grab_hovered = imgui.ImVec4(clamp(grab.x+0.1), clamp(grab.y+0.1), clamp(grab.z+0.1), 1.0)
    local grab_active = imgui.ImVec4(clamp(grab.x-0.1), clamp(grab.y-0.1), clamp(grab.z-0.1), 1.0)
    local scroll_bg = imgui.ImVec4(bg.x, bg.y, bg.z, 0.3)

    imgui.PushStyleColor(imgui.Col.ScrollbarBg, scroll_bg)
    imgui.PushStyleColor(imgui.Col.ScrollbarGrab, grab)
    imgui.PushStyleColor(imgui.Col.ScrollbarGrabHovered, grab_hovered)
    imgui.PushStyleColor(imgui.Col.ScrollbarGrabActive, grab_active)
    imgui.PushStyleColor(imgui.Col.CheckMark, active_theme.checkmark or acc)
end

local function addSmsToHistory(profile, number, sender, text, ts)
    if not profile.contacts[number] then profile.contacts[number] = "" end
    if not profile.metadata then profile.metadata = {} end
    profile.metadata[number] = { sender = sender, text = text, timestamp = ts }
    
    local targetNick = nil
    for nick, p in pairs(phoneData) do
        if p == profile then targetNick = nick break end
    end
    
    if targetNick then
        local hist = {}
        if targetNick == myNick and activeChatId == number and activeChatHistory then
            hist = activeChatHistory
        else
            hist = load_chat_history(targetNick, number)
        end
        table.insert(hist, {sender = sender, msg = text, timestamp = ts})
        if targetNick == myNick and activeChatId == number then
            activeChatHistory = hist
        end
        save_chat_data(targetNick, number, hist)
        save_profile_data(targetNick)
    else
        save_all_data()
    end
end

local function syncGlobalVerified(number)
    local profile = phoneData[actualPlayerNick]
    if not profile then return end
    
    local data = globalVerified[number]
    local changed = false
    
    if not data then
        if profile.verified and profile.verified[number] then
            profile.verified[number] = nil
            changed = true
        end
        if profile.tagger and profile.tagger[number] then
            profile.tagger[number] = nil
            changed = true
        end
        if changed then
            save_all_data()
            needSortContacts = true
        end
        return
    end
    
    if data.verified then
        if not profile.verified then profile.verified = {} end
        if not profile.verified[number] then
            profile.verified[number] = true
            changed = true
        end
    end
    
    if data.name and data.name ~= "" and data.name ~= "-" then
        local decName = u8:decode(data.name) or data.name
        if not profile.contacts[number] or profile.contacts[number] == "" or profile.contacts[number] ~= decName then
            profile.contacts[number] = decName
            changed = true
        end
    end
    
    if data.nick and data.nick ~= "" and data.nick ~= "-" then
        if not profile.nicknames then profile.nicknames = {} end
        if profile.nicknames[number] ~= data.nick then
            profile.nicknames[number] = data.nick
            changed = true
        end
    end
    
    if data.tagger and data.tagger ~= "" and data.tagger ~= "-" then
        if not profile.tagger then profile.tagger = {} end
        if profile.tagger[number] ~= data.tagger then
            profile.tagger[number] = data.tagger
            changed = true
        end
    end
    
    if changed then
        save_all_data()
        needSortContacts = true
    end
end

local function downloadImageToCache(url)
    if imageCache[url] and imageCache[url].status == 1 then return end
    imageCache[url] = { status = 1 }
    table.insert(downloadQueue, url)
end

local function processDownloadQueue()
    if #downloadQueue > 0 then
        local i = 1
        while i <= #downloadQueue do
            local url = downloadQueue[i]
            if not imageCache[url] or imageCache[url].status ~= 1 then
                table.remove(downloadQueue, i)
            else
                local cleanUrl = url:match("([^%?]+)") or url
                local ext = cleanUrl:match("%.([^%.]+)$") or "png"
                if #ext > 4 then ext = "png" end
                local safeName = toHex(url)
                if #safeName > 50 then safeName = safeName:sub(#safeName - 50) end
                local fileName = safeName .. "." .. ext
                local persistentPath = imagesFolder .. fileName

                if globalSettings.saveImagesPersistently and doesFileExist(persistentPath) then
                    if not isImageSafe(persistentPath) then
                        pcall(os.remove, persistentPath)
                    end
                end
                if globalSettings.saveImagesPersistently and doesFileExist(persistentPath) then
                    table.remove(downloadQueue, i)
                    lua_thread.create(function()
                        wait(0)
                        local rtex = renderLoadTextureFromFile(persistentPath)
                        if rtex then
                            local tex_w, tex_h = renderGetTextureSize(rtex)
                            renderReleaseTexture(rtex)
                            local tex = imgui.CreateTextureFromFile(persistentPath)
                            if tex then
                                table.insert(imageCacheKeys, url)
                                if #imageCacheKeys > 15 then
                                    local oldUrl = table.remove(imageCacheKeys, 1)
                                    if imageCache[oldUrl] and imageCache[oldUrl].tex then
                                        local pTex = ffi.cast("IDirect3DTexture9*", imageCache[oldUrl].tex)
                                        pTex.lpVtbl.Release(pTex)
                                        imageCache[oldUrl] = nil
                                    end
                                end
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
                                imageCache[url] = { status = 2, tex = tex, w = draw_w, h = draw_h, orig_w = tex_w, orig_h = tex_h }
                                UI.scrollToBottom = true
                            else
                                imageCache[url] = { status = 3 }
                                UI.scrollToBottom = true
                            end
                        else
                            imageCache[url] = { status = 3 }
                            UI.scrollToBottom = true
                        end
                    end)
                else
                    if activeDownloads < 2 then
                        table.remove(downloadQueue, i)
                        activeDownloads = activeDownloads + 1
                        local tempPath = cacheFolder .. "img_" .. tostring(math.random(1000000,9999999)) .. "." .. ext
                        activeTempFiles[tempPath] = true
                        local dlstatus = require('moonloader').download_status
                        downloadUrlToFile(url, tempPath, function(id, status)
                            if status == dlstatus.STATUS_ENDDOWNLOADDATA then
                                lua_thread.create(function()
                                    wait(50)
                                    activeDownloads = activeDownloads - 1
                                    if doesFileExist(tempPath) then
                                        if not isImageSafe(tempPath) then
                                            pcall(os.remove, tempPath)
                                            activeTempFiles[tempPath] = nil
                                            imageCache[url] = { status = 3 }
                                            UI.scrollToBottom = true
                                            return
                                        end
                                        
                                        local finalPath = tempPath
                                        if globalSettings.saveImagesPersistently then
                                            os.rename(tempPath, persistentPath)
                                            finalPath = persistentPath
                                            activeTempFiles[tempPath] = nil
                                        end
                                        
                                        local rtex = renderLoadTextureFromFile(finalPath)
                                        if rtex then
                                            local tex_w, tex_h = renderGetTextureSize(rtex)
                                            renderReleaseTexture(rtex)
                                            local tex = imgui.CreateTextureFromFile(finalPath)
                                            if tex then
                                                table.insert(imageCacheKeys, url)
                                                if #imageCacheKeys > 15 then
                                                    local oldUrl = table.remove(imageCacheKeys, 1)
                                                    if imageCache[oldUrl] and imageCache[oldUrl].tex then
                                                        local pTex = ffi.cast("IDirect3DTexture9*", imageCache[oldUrl].tex)
                                                        pTex.lpVtbl.Release(pTex)
                                                        imageCache[oldUrl] = nil
                                                    end
                                                end
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
                                                imageCache[url] = { status = 2, tex = tex, w = draw_w, h = draw_h, orig_w = tex_w, orig_h = tex_h }
                                                UI.scrollToBottom = true
                                            else
                                                imageCache[url] = { status = 3 }
                                                UI.scrollToBottom = true
                                            end
                                        else
                                            imageCache[url] = { status = 3 }
                                            UI.scrollToBottom = true
                                        end
                                        if not globalSettings.saveImagesPersistently then
                                            pcall(os.remove, tempPath)
                                            activeTempFiles[tempPath] = nil
                                        end
                                    else
                                        imageCache[url] = { status = 3 }
                                        UI.scrollToBottom = true
                                        activeTempFiles[tempPath] = nil
                                    end
                                end)
                            elseif status == dlstatus.STATUS_EX_ERROR then
                                activeDownloads = activeDownloads - 1
                                pcall(os.remove, tempPath)
                                activeTempFiles[tempPath] = nil
                                imageCache[url] = { status = 3 }
                                UI.scrollToBottom = true
                            end
                        end)
                    else
                        i = i + 1
                    end
                end
            end
        end
    end
end

function checkUpdates(is_manual)
    if not globalSettings.autoUpdate and not is_manual then return end
    
    local updateFile_tmp = cacheFolder .. 'msg_update_' .. tostring(math.random(100000, 999999)) .. '.json'
    activeTempFiles[updateFile_tmp] = true
    
    if is_manual then showSystemNotification(u8"Проверка обновлений...", 3) end
    
    local dlstatus = require('moonloader').download_status
    local url_no_cache = updateUrl .. "?t=" .. tostring(os.time())
    downloadUrlToFile(url_no_cache, updateFile_tmp, function(id, status)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            local f = io.open(updateFile_tmp, "rb")
            local content = nil
            if f then
                content = f:read("*a")
                f:close()
            end
            pcall(os.remove, updateFile_tmp)
            activeTempFiles[updateFile_tmp] = nil
            
            if content and content ~= "" then
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
                    if tonumber(data.version) > tonumber(script_version) then
                        local is_silent = (data.silent == true) and not is_manual
                        
                        if not is_silent then
                            showSystemNotification(u8"Найдено обновление! Загрузка...", 3)
                        end
                        
                        lua_thread.create(function()
                            wait(100)
                            local function downloadAndInstallScript()
                                local scriptPath = thisScript().path
                                local tempPath = scriptPath .. tostring(math.random(10000, 99999)) .. ".tmp"
                                activeTempFiles[tempPath] = true
                                
                                local dl_url_no_cache = data.url .. "?t=" .. tostring(os.time())
                                downloadUrlToFile(dl_url_no_cache, tempPath, function(id2, status2)
                                    if status2 == dlstatus.STATUS_ENDDOWNLOADDATA then
                                        local fTmp = io.open(tempPath, "rb")
                                        if fTmp then
                                            local newCode = fTmp:read("*a")
                                            fTmp:close()
                                            pcall(os.remove, tempPath)
                                            activeTempFiles[tempPath] = nil
                                            
                                            if newCode:find("\208[\128-\191]") or newCode:find("\209[\128-\191]") then
                                                local decoded = u8:decode(newCode)
                                                if decoded then newCode = decoded end
                                            end
                                            
                                            local fOut = io.open(scriptPath, "wb")
                                            if fOut then
                                                fOut:write(newCode)
                                                fOut:close()
                                                if not is_silent then showSystemNotification(u8"Успешно обновлено! Перезапуск...", 1) end
                                                lua_thread.create(function() wait(1500) thisScript():reload() end)
                                            elseif not is_silent then
                                                showSystemNotification(u8"Ошибка: Файл скрипта занят!", 2)
                                            end
                                        end
                                    elseif status2 == dlstatus.STATUS_EX_ERROR then
                                        pcall(os.remove, tempPath)
                                        activeTempFiles[tempPath] = nil
                                        if not is_silent then showSystemNotification(u8"Ошибка при скачивании обновления!", 2) end
                                    end
                                end)
                            end

                            local changelogFile_tmp = cacheFolder .. 'msg_changelog_' .. tostring(math.random(100000, 999999)) .. '.txt'
                            activeTempFiles[changelogFile_tmp] = true
                            local cl_no_cache = changelogUrl .. "?t=" .. tostring(os.time())
                            downloadUrlToFile(cl_no_cache, changelogFile_tmp, function(id_cl, status_cl)
                                if status_cl == dlstatus.STATUS_ENDDOWNLOADDATA then
                                    local fc = io.open(changelogFile_tmp, "rb")
                                    local changelogText = ""
                                    if fc then
                                        changelogText = fc:read("*a")
                                        fc:close()
                                    end
                                    pcall(os.remove, changelogFile_tmp)
                                    activeTempFiles[changelogFile_tmp] = nil
                                    
                                    changelogText = changelogText:gsub("\r", ""):match("^%s*(.-)%s*$") or ""
                                    if changelogText ~= "" and changelogText:lower() ~= "none" and changelogText:lower() ~= "clear" then
                                        local text_to_save = changelogText
                                        if changelogText:find("[\208\209][\128-\191]") then
                                            local decoded = u8:decode(changelogText)
                                            if decoded then text_to_save = decoded end
                                        end
                                        
                                        if globalSettings.lastChangelogText ~= text_to_save then
                                            globalSettings.lastChangelogText = text_to_save
                                            local sys_num = "system"
                                            local base_profile = phoneData[myNick]
                                            if not base_profile then
                                                for _, p in pairs(phoneData) do base_profile = p break end
                                            end
                                            if base_profile then
                                                if not base_profile.contacts[sys_num] then base_profile.contacts[sys_num] = "Уведомления" end
                                                addSmsToHistory(base_profile, sys_num, "them", text_to_save, os.time())
                                            end
                                            for _, p in pairs(phoneData) do p.unread[sys_num] = true end
                                            save_all_data()
                                        end
                                    end
                                    lua_thread.create(function() wait(100) downloadAndInstallScript() end)
                                elseif status_cl == dlstatus.STATUS_EX_ERROR then
                                    pcall(os.remove, changelogFile_tmp)
                                    activeTempFiles[changelogFile_tmp] = nil
                                    downloadAndInstallScript()
                                end
                            end)
                        end)
                    else
                        if is_manual then showSystemNotification(u8"У вас установлена последняя версия!", 1) end
                    end
                else
                    if is_manual then showSystemNotification(u8"Ошибка: Неверный формат ответа от сервера!", 2) end
                end
            else
                if is_manual then showSystemNotification(u8"Ошибка: Пустой ответ от сервера GitHub!", 2) end
            end
        elseif status == dlstatus.STATUS_EX_ERROR then
            pcall(os.remove, updateFile_tmp)
            activeTempFiles[updateFile_tmp] = nil
            if is_manual then showSystemNotification(u8"Ошибка соединения с GitHub!", 2) end
        end
    end)
end

function samp.onShowTextDraw(id, data)
    if CallState.active and not CallState.number then
        if type(data.text) == "string" then
            local tnum = data.text:match("^[%d%-]+$")
            if tnum then
                CallState.number = tnum
                if actualPlayerNick ~= "Default" and phoneData[actualPlayerNick] then
                    local profile = phoneData[actualPlayerNick]
                    if not profile.calls then profile.calls = {} end
                    if not profile.calls[CallState.number] then profile.calls[CallState.number] = {} end
                    table.insert(profile.calls[CallState.number], {
                        timestamp = CallState.startTime,
                        duration = 0,
                        messages = {}
                    })
                    CallState.callIndex = #profile.calls[CallState.number]
                    CallState.saved = true
                    if not profile.contacts[CallState.number] then profile.contacts[CallState.number] = "" end
                    save_all_data()
                    needSortContacts = true
                end
            end
        end
    end
end

addEventHandler('onWindowMessage', function(msg, wparam, lparam)
    if msg == 0x0100 or msg == 0x0101 then 
        if wparam == vkeys.VK_ESCAPE and (UI.windowState[0] or UI.viewingImage or UI.showGallery[0]) then
            consumeWindowMessage(true, false)
            if msg == 0x0100 then
                local intercepted = false
                
                if UI.viewingImage then
                    UI.viewingImage = nil
                    intercepted = true
                elseif UI.anyModalOpen then
                    UI.requestCloseModal = true
                    intercepted = true
                elseif UI.showThemeEditor[0] then
                    UI.showThemeEditor[0] = false
                    intercepted = true
                elseif UI.showGallery[0] then
                    UI.showGallery[0] = false
                    intercepted = true
                elseif UI.showMessageSearch then
                    UI.showMessageSearch = false
                    intercepted = true
                elseif UI.showCallHistory then
                    if UI.viewingCallIndex > 0 and not UI.callOpenedFromChat then
                        UI.viewingCallIndex = 0
                    else
                        UI.showCallHistory = false
                        UI.viewingCallIndex = 0
                        UI.callOpenedFromChat = false
                    end
                    intercepted = true
                elseif UI.showContactProfile then
                    UI.showContactProfile = false
                    intercepted = true
                elseif imgui.GetIO().WantCaptureKeyboard then
                    intercepted = true
                end
                
                Sys.wasTypingEscape = intercepted
            elseif msg == 0x0101 then
                if not Sys.wasTypingEscape then
                    if (globalSettings.closeChatOnEsc or globalSettings.iosPhoneMode) and activeContact then
                        SaveCurrentDraft()
                        activeContact = nil
                        activeChatId = nil
                        activeChatHistory = nil
                        UI.showContactProfile = false
                        UI.showCallHistory = false
                        UI.viewingCallIndex = 0
                        UI.callOpenedFromChat = false
                        UI.showMessageSearch = false
                        UI.inputSearchMessage[0] = 0
                        UI.inputMessage[0] = 0
                    else
                        UI.windowState[0] = false
                        SaveCurrentDraft()
                    end
                end
                Sys.wasTypingEscape = false
            end
        end
    end
end)

function samp.onPlayerJoin(id, color, is_npc, nickname)
    onlinePlayersById[id] = nickname
    onlinePlayers[nickname] = true
    if globalSettings.contactSortMode == 3 then needSortContacts = true end
end

function samp.onPlayerQuit(id, reason)
    local nick = onlinePlayersById[id]
    if nick then
        onlinePlayers[nick] = nil
    end
    onlinePlayersById[id] = nil
    if globalSettings.contactSortMode == 3 then needSortContacts = true end
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    
    cleanupGhostFiles()
    
    if file_exists(oldMasterFile) then
        local masterData = load_json(oldMasterFile)
        if type(masterData) == "table" then
            if masterData.global_settings then
                for k, v in pairs(masterData.global_settings) do globalSettings[k] = v end
                if globalSettings.customTheme then
                    globalSettings.customThemes = { globalSettings.customTheme }
                    globalSettings.customTheme = nil
                    if globalSettings.theme == 0 then globalSettings.theme = #themes + 1 end
                end
            end
            if masterData.profiles then
                phoneData = masterData.profiles
                for pNick, pData in pairs(phoneData) do
                    local oldBank = "Bank" .. "_System"
                    local oldNews = "System" .. "_News"
                    local function migrateKey(tbl, oldK, newK)
                        if tbl and tbl[oldK] ~= nil then
                            tbl[newK] = tbl[oldK]
                            tbl[oldK] = nil
                        end
                    end
                    
                    migrateKey(pData.contacts, oldNews, "system")
                    migrateKey(pData.contacts, oldBank, "banking")
                    migrateKey(pData.history, oldNews, "system")
                    migrateKey(pData.history, oldBank, "banking")
                    migrateKey(pData.unread, oldNews, "system")
                    migrateKey(pData.unread, oldBank, "banking")
                    migrateKey(pData.muted, oldNews, "system")
                    migrateKey(pData.muted, oldBank, "banking")
                    migrateKey(pData.drafts, oldNews, "system")
                    migrateKey(pData.drafts, oldBank, "banking")
                    
                    if not pData.metadata then pData.metadata = {} end
                    if pData.history then
                        for cNum, cHist in pairs(pData.history) do
                            if #cHist > 0 then
                                local lastMsg = cHist[#cHist]
                                pData.metadata[cNum] = { sender = lastMsg.sender, text = lastMsg.msg, timestamp = lastMsg.timestamp }
                                local pDir = getWorkingDirectory() .. '\\config\\Messenger\\' .. pNick
                                pcall(lfs.mkdir, pDir)
                                pcall(lfs.mkdir, pDir .. '\\chats')
                                save_chat_data(pNick, cNum, cHist)
                            end
                        end
                        pData.history = nil
                    end
                end
            end
            os.rename(oldMasterFile, getWorkingDirectory() .. '\\config\\Messenger_backup_' .. tostring(os.time()) .. '.json')
            save_all_data()
        end
    else
        if file_exists(settingsFile) then
            local sData = load_json(settingsFile)
            if type(sData) == "table" then
                for k, v in pairs(sData) do globalSettings[k] = v end
            end
        end
        for dir in lfs.dir(getWorkingDirectory() .. '\\config\\Messenger\\') do
            if dir ~= "." and dir ~= ".." and dir ~= "settings.json" and dir ~= "cache" and dir ~= "images" then
                if isValidRpNick(dir) then
                    local pPath = getWorkingDirectory() .. '\\config\\Messenger\\' .. dir .. '\\profile.json'
                    if file_exists(pPath) then
                        local pData = load_json(pPath)
                        if type(pData) == "table" then
                            if not pData.metadata then pData.metadata = {} end
                            phoneData[dir] = pData
                        end
                    end
                else
                    removeProfileFolder(dir)
                end
            end
        end
    end
    
    globalSettings.chatBackgroundUrl = nil
    ffi.copy(UI.inputOpenCommand, globalSettings.openCommand or "p")
    
    if globalSettings.contactSortMode and globalSettings.contactSortMode > #sortModes then
        globalSettings.contactSortMode = 1
    end
    
    sampRegisterChatCommand(globalSettings.openCommand or "p", function()
        UI.windowState[0] = not UI.windowState[0]
        if UI.windowState[0] then
            UI.requestFocus = true
            UI.scrollToBottom = true
        else
            SaveCurrentDraft()
        end
    end)

    local result, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result then
        local tempNick = sampGetPlayerNickname(myId)
        lastSeenNick = tempNick
        if isValidRpNick(tempNick) then
            myNick = tempNick
            actualPlayerNick = tempNick
        end
    end
    if myNick == "Default" then
        local anyProfile = next(phoneData)
        if anyProfile then myNick = anyProfile end
    end
    
    local master_news_hist = {}
    for nick, _ in pairs(phoneData) do
        local sysHist = load_chat_history(nick, "system")
        if sysHist and #sysHist > #master_news_hist then
            master_news_hist = sysHist
        end
    end
    
    for pName, pData in pairs(phoneData) do
        if not pData.unread then pData.unread = {} end
        if not pData.contacts then pData.contacts = {} end
        if not pData.metadata then pData.metadata = {} end
        if not pData.nicknames then pData.nicknames = {} end
        if not pData.muted then pData.muted = {} end
        if not pData.drafts then pData.drafts = {} end
        if not pData.calls then pData.calls = {} end
        if not pData.pinned then pData.pinned = {} end
        if not pData.blocked then pData.blocked = {} end
        pData.groups = nil
        
        if #master_news_hist > 0 then
            save_chat_data(pName, "system", master_news_hist)
            local lMsg = master_news_hist[#master_news_hist]
            pData.metadata["system"] = { sender = lMsg.sender, text = lMsg.msg, timestamp = lMsg.timestamp }
        end
        pData.contacts["system"] = "Уведомления"
        
        pData.numbers = nil
        pData.activeNumber = nil
        pData.settings = nil
    end
    
    if isValidRpNick(myNick) and not phoneData[myNick] then
        phoneData[myNick] = { contacts = {}, metadata = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, pinned = {}, blocked = {} }
        if #master_news_hist > 0 then
            save_chat_data(myNick, "system", master_news_hist)
            local lMsg = master_news_hist[#master_news_hist]
            phoneData[myNick].metadata["system"] = { sender = lMsg.sender, text = lMsg.msg, timestamp = lMsg.timestamp }
        end
        phoneData[myNick].contacts["system"] = "Уведомления"
        save_all_data()
    end
    
    checkUpdates()

    local verifyFile_tmp = cacheFolder .. 'verify_' .. tostring(math.random(100000, 999999)) .. '.json'
    activeTempFiles[verifyFile_tmp] = true
    downloadUrlToFile(verifyUrl .. "?t=" .. tostring(os.time()), verifyFile_tmp, function(id, status)
        local dlstatus = require('moonloader').download_status
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            local f = io.open(verifyFile_tmp, "rb")
            if f then
                local content = f:read("*a")
                f:close()
                local ok, res = pcall(decodeJson, content)
                if ok and type(res) == "table" then 
                    globalVerified = res 
                    
                    for nick, profile in pairs(phoneData) do
                        local changed = false
                        if not profile.verified then profile.verified = {} end
                        if not profile.tagger then profile.tagger = {} end
                        if not profile.nicknames then profile.nicknames = {} end

                        for num, _ in pairs(profile.verified) do
                            if not globalVerified[num] or not globalVerified[num].verified then
                                profile.verified[num] = nil
                                changed = true
                            end
                        end
                        for num, _ in pairs(profile.tagger) do
                            if not globalVerified[num] or not globalVerified[num].tagger then
                                profile.tagger[num] = nil
                                changed = true
                            end
                        end

                        for num, _ in pairs(profile.metadata or {}) do
                            if globalVerified[num] then
                                local data = globalVerified[num]
                                if data.verified and not profile.verified[num] then
                                    profile.verified[num] = true
                                    changed = true
                                end
                                if data.name and data.name ~= "" and data.name ~= "-" then
                                    local decName = u8:decode(data.name) or data.name
                                    if not profile.contacts[num] or profile.contacts[num] == "" or profile.contacts[num] ~= decName then
                                        profile.contacts[num] = decName
                                        changed = true
                                    end
                                end
                                if data.nick and data.nick ~= "" and data.nick ~= "-" then
                                    if profile.nicknames[num] ~= data.nick then
                                        profile.nicknames[num] = data.nick
                                        changed = true
                                    end
                                end
                                if data.tagger and data.tagger ~= "" and data.tagger ~= "-" then
                                    if profile.tagger[num] ~= data.tagger then
                                        profile.tagger[num] = data.tagger
                                        changed = true
                                    end
                                end
                            end
                        end
                        if changed then needSortContacts = true end
                    end
                    save_all_data()
                end
                pcall(os.remove, verifyFile_tmp)
                activeTempFiles[verifyFile_tmp] = nil
            end
        elseif status == dlstatus.STATUS_EX_ERROR then
            pcall(os.remove, verifyFile_tmp)
            activeTempFiles[verifyFile_tmp] = nil
        end
    end)

    local temp_news_file = cacheFolder .. 'temp_news_' .. tostring(math.random(100000, 999999)) .. '.txt'
    activeTempFiles[temp_news_file] = true
    
    local dlstatus = require('moonloader').download_status
    local news_url_no_cache = newsUrl .. "?t=" .. tostring(os.time())
    downloadUrlToFile(news_url_no_cache, temp_news_file, function(id, status, p1, p2)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            local f = io.open(temp_news_file, "rb")
            if f then
                local text_utf8 = f:read("*a")
                f:close()
                pcall(os.remove, temp_news_file)
                activeTempFiles[temp_news_file] = nil

                if text_utf8 then
                    text_utf8 = text_utf8:gsub("\r", "")
                    text_utf8 = text_utf8:match("^%s*(.-)%s*$")
                    
                    if text_utf8 and text_utf8 ~= "" and text_utf8:lower() ~= "none" and text_utf8:lower() ~= "clear" then
                        local text_cp1251 = u8:decode(text_utf8)
                        if next(phoneData) ~= nil and globalSettings.lastNewsText ~= text_cp1251 then
                            globalSettings.lastNewsText = text_cp1251
                            local sys_num = "system"
                            local now_ts = os.time()
                            for _, p in pairs(phoneData) do
                                if not p.contacts[sys_num] then p.contacts[sys_num] = "Уведомления" end
                                addSmsToHistory(p, sys_num, "them", text_cp1251, now_ts)
                                if activeContact ~= sys_num or not UI.windowState[0] then
                                    p.unread[sys_num] = true
                                end
                            end
                            if (activeContact ~= sys_num or not UI.windowState[0]) and globalSettings.useScreenNotifications and not globalSettings.dndMode then
                                Sys.activeNotification = {
                                    number = sys_num,
                                    name = "Уведомления",
                                    text = text_cp1251,
                                    time = os.clock()
                                }
                            end
                            save_all_data()
                            if activeContact == sys_num then UI.scrollToBottom = true end
                            needSortContacts = true
                        end
                    end
                end
            end
        elseif status == dlstatus.STATUS_EX_ERROR then
            pcall(os.remove, temp_news_file)
            activeTempFiles[temp_news_file] = nil
        end
    end)

    local max_id = sampGetMaxPlayerId(false)
    for i = 0, max_id do
        if sampIsPlayerConnected(i) then
            local nick = sampGetPlayerNickname(i)
            if nick then
                onlinePlayersById[i] = nick
                onlinePlayers[nick] = true
            end
        end
    end

    local lastNickCheck = 0
    local lastOnlineSync = 0

    while true do
        wait(0)
        processDownloadQueue()
        
        if #smsOutQueue > 0 and (os.clock() - lastSmsOutTime > smsSendDelay) then
            lastSentSmsTask = table.remove(smsOutQueue, 1)
            sampSendChat("/sms " .. lastSentSmsTask.num .. " " .. lastSentSmsTask.text)
            lastSmsOutTime = os.clock()
            smsSendDelay = 1.0
        end
		
        if os.clock() - lastNickCheck > 1.0 then
            lastNickCheck = os.clock()
            
            if os.clock() - lastOnlineSync > 10.0 then
                lastOnlineSync = os.clock()
                local currentOnline = {}
                local currentOnlineById = {}
                local onlineChanged = false
                for i = 0, sampGetMaxPlayerId(false) do
                    if sampIsPlayerConnected(i) then
                        local n = sampGetPlayerNickname(i)
                        if n then
                            currentOnline[n] = true
                            currentOnlineById[i] = n
                            if not onlinePlayers[n] then onlineChanged = true end
                        end
                    end
                end
                if not onlineChanged then
                    for n, _ in pairs(onlinePlayers) do
                        if not currentOnline[n] then onlineChanged = true break end
                    end
                end
                onlinePlayers = currentOnline
                onlinePlayersById = currentOnlineById
                if onlineChanged and globalSettings.contactSortMode == 3 then
                    needSortContacts = true
                end
            end

            if sampIsLocalPlayerSpawned() then
                local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if r then
                    local currentInGameNick = sampGetPlayerNickname(id)
                    if currentInGameNick ~= lastSeenNick then
                        lastSeenNick = currentInGameNick
                        
                        if isValidRpNick(currentInGameNick) then
                            actualPlayerNick = currentInGameNick
                            myNick = currentInGameNick
                            activeContact = nil
                            activeChatId = nil
                            activeChatHistory = nil
                            needSortContacts = true
                            
                            if not phoneData[myNick] then
                                phoneData[myNick] = { contacts = {}, metadata = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, pinned = {}, blocked = {} }
                                local m_hist = {}
                                for nick, _ in pairs(phoneData) do
                                    local sHist = load_chat_history(nick, "system")
                                    if sHist and #sHist > #m_hist then m_hist = sHist end
                                end
                                if #m_hist > 0 then
                                    save_chat_data(myNick, "system", m_hist)
                                    local lMsg = m_hist[#m_hist]
                                    phoneData[myNick].metadata["system"] = { sender = lMsg.sender, text = lMsg.msg, timestamp = lMsg.timestamp }
                                end
                                phoneData[myNick].contacts["system"] = "Уведомления"
                                save_all_data()
                            end
                        end
                    end
                end
            end
        end

        if Sys.activeNotification and (os.clock() - Sys.activeNotification.time < 5.0) and not UI.windowState[0] then
            if isKeyJustPressed(globalSettings.openKey or vkeys.VK_P) and not sampIsChatInputActive() and not sampIsDialogActive() and not sampIsCursorActive() then
                UI.windowState[0] = true
                activeContact = Sys.activeNotification.number
                activeChatId = activeContact
                activeChatHistory = load_chat_history(myNick, activeContact)
                LoadDraft(activeContact)
                UI.scrollToBottom = true
                UI.requestFocus = true
                Sys.activeNotification = nil 
            end
        end

        if not sampIsChatInputActive() and not sampIsDialogActive() then
            local modPressed = false
            if globalSettings.openMod == 0 then
                modPressed = true
            else
                modPressed = isKeyDown(globalSettings.openMod)
            end

            if modPressed and isKeyJustPressed(globalSettings.openKey) then
                if not UI.windowState[0] or not imgui.GetIO().WantCaptureKeyboard then
                    UI.windowState[0] = not UI.windowState[0]
                    if UI.windowState[0] then
                        UI.scrollToBottom = true
                        UI.requestFocus = true
                    else
                        if activeContact and phoneData[myNick] and phoneData[myNick].drafts then
                            local currentText = ffi.string(UI.inputMessage)
                            if currentText ~= "" then
                                phoneData[myNick].drafts[activeContact] = u8:decode(currentText)
                            else
                                phoneData[myNick].drafts[activeContact] = nil
                            end
                        end
                    end
                end
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
    if Macro.autoCleaning then
        local tStr = tostring(title)
        local txtStr = tostring(text)
        
        -- Шаг 2: В главном меню (ID 538) ищем пункт "Входящие сообщения"
        if Macro.cleanStep == 2 and id == 538 and tStr:find("Сообщения") then
            local idx = 4
            local i = 0
            for line in txtStr:gmatch("[^\n]+") do
                if line:find("Входящие сообщения") and not line:find("Удалить") then
                    idx = i
                    break
                end
                i = i + 1
            end
            
            Macro.cleanStep = 3
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
            
        -- Шаг 3: В списке входящих (ID 543) нажимаем "Назад"
        elseif Macro.cleanStep == 3 and id == 543 and (tStr:find("Последние сообщения") or txtStr:find("Отправитель")) then
            Macro.cleanStep = 4
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 0, 0, "")
            end)
            return false
            
        -- Шаг 4: Снова в главном меню (ID 538) ищем пункт "Удалить все входящие сообщения"
        elseif Macro.cleanStep == 4 and id == 538 and tStr:find("Сообщения") then
            local idx = 0
            local i = 0
            for line in txtStr:gmatch("[^\n]+") do
                if line:find("Удалить все входящие сообщения") then
                    idx = i
                    break
                end
                i = i + 1
            end
            
            Macro.cleanStep = 5
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
            
        -- Шаг 5: В диалоге подтверждения (ID 550) нажимаем "Далее"
        elseif Macro.cleanStep == 5 and id == 550 and txtStr:find("действительно хотите удалить") then
            Macro.autoCleaning = false
            Macro.cleanStep = 0
            
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 1, 65535, "")
                
                wait(400)
                sampSendClickTextdraw(65535) 
                sampSendChat("/untd 2")      
                
                showSystemNotification(u8"Серверный лимит SMS успешно очищен!", 1)
                UI.windowState[0] = true
            end)
            return false
        end
    end

    if Macro.autoGeo then
        local tStr = tostring(title)
        local txtStr = tostring(text)
        local cleanTitle = tStr:gsub("{.-}", "")
        local cleanText = txtStr:gsub("{.-}", "")
        
        -- Шаг 2: В главном меню (ID 538) ищем пункт "Отправить геопозицию"
        if Macro.geoStep == 2 and id == 538 and cleanTitle:find("Сообщения") then
            local idx = 3
            local i = 0
            for line in cleanText:gmatch("[^\n]+") do
                if line:find("Отправить геопозицию") then
                    idx = i
                    break
                end
                i = i + 1
            end
            
            Macro.geoStep = 3
            lua_thread.create(function()
                wait(500)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
            
        -- Шаг 3: В диалоге ввода номера (ID 554) вводим номер и жмем "Далее"
        elseif Macro.geoStep == 3 and id == 554 and cleanText:find("Введите номер") then
            Macro.autoGeo = false
            Macro.geoStep = 0
            
            lua_thread.create(function()
                wait(500)
                sampSendDialogResponse(id, 1, 65535, tostring(Macro.targetGeoNumber))
                
                Macro.waitingForGeoConfirm = true
                wait(5000)
                if Macro.waitingForGeoConfirm then
                    Macro.waitingForGeoConfirm = false
                    if sampIsDialogActive() then
                        sampCloseCurrentDialogWithButton(0)
                    end
                    sampSendClickTextdraw(65535) 
                    sampSendChat("/untd 2")      
                    UI.windowState[0] = true
                end
            end)
            return false
        end
    end
	
    if Macro.autoBlock and id == 32500 then
        local txtStr = tostring(text)
        local cleanText = txtStr:gsub("{.-}", "")
        
        local search1 = u8:decode("хотите заблокировать номер")
        local search2 = u8:decode("Желаете разблокировать его")
        
        if cleanText:find(search1) or cleanText:find(search2) then
            Macro.autoBlock = false
            
            lua_thread.create(function()
                wait(10)
                if sampIsDialogActive() then
                    sampCloseCurrentDialogWithButton(1) 
                else
                    -- Заменили 0 на 65535, так как это Style 0 (MSGBOX)
                    sampSendDialogResponse(id, 1, 65535, "")
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
	
    if plain_text:match("^%s*SMS: ") or (pending_new_format_sms and plain_text:match("^%.%.%.")) then
        if plain_text:match("^%s*SMS: ") then
            pending_new_format_sms = plain_text
        else
            pending_new_format_sms = pending_new_format_sms:gsub("%.%.%.?%s*$", "") .. " " .. plain_text:gsub("^%.%.%.?%s*", "")
        end
        pending_new_format_time = os.clock()

        if not pending_new_format_sms:find("Тел: [%d%-]+") then
            if globalSettings.useScreenNotifications then return false end
            return
        end

        plain_text = pending_new_format_sms
        text = pending_new_format_sms
        pending_new_format_sms = nil
    end

    if plain_text:find("|", 1, true) and plain_text:find("SMS", 1, true) then
        local num = plain_text:match("Номер.-([%d%-]+)") or plain_text:match("\xcd\xee\xec\xe5\xf0.-([%d%-]+)")
        
        if num then
            local is_unblock = plain_text:find("\xf3\xe4\xe0\xeb") or plain_text:find("\xf0\xe0\xe7\xf0\xe5\xf8\xe5\xed")
            is_unblock = is_unblock or plain_text:find("удал") or plain_text:find("разрешен")
            
            local is_block = plain_text:find("\xe2\xed\xe5\xf1")
            is_block = is_block or plain_text:find("внес")
            
            if is_unblock then
                if profile.blocked then
                    profile.blocked[tostring(num)] = nil
                    profile.blocked[tonumber(num)] = nil
                end
                
                save_all_data()
                needSortContacts = true
                
                if globalSettings.useScreenNotifications then
                    showSystemNotification(u8"Номер " .. num .. u8" разблокирован.", 1)
                    return false
                end
                return
                
            elseif is_block then
                if not profile.blocked then profile.blocked = {} end
                profile.blocked[tostring(num)] = true
                profile.blocked[tonumber(num)] = true 
                
                save_all_data()
                needSortContacts = true
                
                if globalSettings.useScreenNotifications then
                    showSystemNotification(u8"Номер " .. num .. u8" заблокирован.", 1)
                    return false
                end
                return
            end
        end
    end
    
    local is_incoming = plain_text:match("^%s*%[Телефон%] Входящий вызов%.%.%.")
    local out_match = plain_text:match("^%s*%[Телефон%] Исходящий вызов ([%d%-]+)%.%.%.")

    if is_incoming or out_match then
        CallState.active = true
        CallState.number = out_match
        CallState.startTime = ts
        CallState.saved = false
        CallState.callIndex = nil
        CallState.messages = {}
        
        if out_match then
            if actualPlayerNick ~= "Default" and phoneData[actualPlayerNick] then
                if not profile.calls then profile.calls = {} end
                if not profile.calls[out_match] then profile.calls[out_match] = {} end
                table.insert(profile.calls[out_match], {
                    timestamp = ts,
                    duration = 0,
                    messages = {}
                })
                CallState.callIndex = #profile.calls[out_match]
                CallState.saved = true
                if not profile.contacts[out_match] then profile.contacts[out_match] = "" end
                syncGlobalVerified(out_match)
                save_all_data()
                needSortContacts = true
                if myNick == actualPlayerNick and activeContact == out_match then UI.scrollToBottom = true end
            end
        end
    end

    if CallState.active then
        if plain_text:match("^%s*%| Вы завершили вызов%.") or plain_text:match("^%s*%| Абонент завершил вызов%.") then
            if CallState.saved and CallState.number and CallState.callIndex then
                if profile.calls[CallState.number] and profile.calls[CallState.number][CallState.callIndex] then
                    profile.calls[CallState.number][CallState.callIndex].duration = ts - CallState.startTime
                    save_all_data()
                end
            end
            CallState.active = false
            CallState.number = nil
            CallState.saved = false
            CallState.callIndex = nil
        else
            local is_call_msg = false
            local sender = "them"
            local msg_text = ""
            local myNameSpace = actualPlayerNick:gsub("_", " ")

            if plain_text:match("^%s*%[Телефон%] ") or plain_text:match("^%s*%[Громкая связь%] ") then
                local prefix = plain_text:match("^%s*%[Телефон%] ") and "^%s*%[Телефон%] " or "^%s*%[Громкая связь%] "
                local clean = plain_text:gsub(prefix, "")
                
                if not clean:match("Входящий вызов") and not clean:match("Исходящий вызов") then
                    is_call_msg = true
                    local c_name, c_text = clean:match("^(.-) говорит: (.*)")
                    if c_name then
                        if c_name == actualPlayerNick or c_name == myNameSpace then
                            sender = "me"
                            msg_text = c_text
                        else
                            is_call_msg = false 
                        end
                    else
                        if clean:sub(1, #actualPlayerNick) == actualPlayerNick then
                            sender = "me"
                            msg_text = "*" .. clean:sub(#actualPlayerNick + 2)
                        elseif clean:sub(1, #myNameSpace) == myNameSpace then
                            sender = "me"
                            msg_text = "*" .. clean:sub(#myNameSpace + 2)
                        else
                            sender = "them"
                            msg_text = clean
                        end
                    end
                end
            elseif plain_text:match("^%s*%[Транспорт%] ") then
                local c_name, c_text = plain_text:match("^%s*%[Транспорт%] (.-) говорит по телефону: (.*)")
                if c_name then
                    if c_name == actualPlayerNick or c_name == myNameSpace then
                        is_call_msg = true
                        sender = "me"
                        msg_text = c_text
                    else
                        is_call_msg = false
                    end
                end
            end

            if is_call_msg and msg_text ~= "" then
                if CallState.saved and CallState.number and CallState.callIndex then
                    local callEntry = profile.calls[CallState.number] and profile.calls[CallState.number][CallState.callIndex]
                    if callEntry then
                        table.insert(callEntry.messages, {sender = sender, msg = msg_text, timestamp = ts})
                        CallState.lastMsgSysTime = os.clock()
                        save_all_data()
                        if myNick == actualPlayerNick and activeContact == CallState.number then UI.scrollToBottom = true end
                    end
                end
            end
        end
    end
    
    if Macro.autoCleaning and plain_text:find("У Вас нет входящих сообщений") then
        Macro.autoCleaning = false
        Macro.cleanStep = 0
        lua_thread.create(function()
            wait(100)
            if sampIsDialogActive() then sampCloseCurrentDialogWithButton(0) end
            wait(100)
            sampSendClickTextdraw(65535) 
            sampSendChat("/untd 2")      
            showSystemNotification(u8"Память и так пуста!", 3)
            UI.windowState[0] = true
        end)
    end
    
    local geo_num = plain_text:match("^%| Геопозиция на номер ([%d%-]+) отправлена%.")
    if geo_num then
        addSmsToHistory(profile, geo_num, "me", "[Геопозиция]", ts)
        needSortContacts = true
        if myNick == actualPlayerNick and activeContact == geo_num then UI.scrollToBottom = true end
        if Macro.waitingForGeoConfirm then
            Macro.waitingForGeoConfirm = false
            lua_thread.create(function()
                wait(50)
                if sampIsDialogActive() then sampCloseCurrentDialogWithButton(0) end
                wait(50)
                sampSendClickTextdraw(65535) 
                sampSendChat("/untd 2")      
                showSystemNotification(u8"Геопозиция успешно отправлена!", 1)
                UI.windowState[0] = true
            end)
        end
    end
    
    local wait_sec = plain_text:match("Перед отправкой следующего сообщения в чат следует подождать (%d+) сек%.")
    if wait_sec then
        if lastSentSmsTask then
            -- Если сообщение не отправилось, возвращаем его в начало очереди
            table.insert(smsOutQueue, 1, lastSentSmsTask)
            lastSentSmsTask = nil
        end
        smsSendDelay = tonumber(wait_sec) + 0.5 -- Устанавливаем требуемый кулдаун + 0.5 сек
        lastSmsOutTime = os.clock()
        
        if globalSettings.useScreenNotifications or globalSettings.hideSmsJunk then return false end
    end

    if plain_text:find("Осталось сообщений до лимита: %d+ шт%.") or plain_text:find("^%| С вашего банковского счета списано %$%d+ за отправку SMS") or plain_text:find("Чтобы убрать телефон, нажмите кнопку \"ESC\"") then
        if globalSettings.useScreenNotifications or globalSettings.hideSmsJunk then return false end
    end
    
    if globalSettings.logBank then
        if plain_text:match("^%s*%|%s*Вы отыграли час") then
            Bank.isCollecting = true
            Bank.buffer = { plain_text }
            lua_thread.create(function()
                wait(300)
                Bank.isCollecting = false
                if #Bank.buffer > 0 then
                    local full_text = table.concat(Bank.buffer, "\n")
                    if not profile.contacts["banking"] then profile.contacts["banking"] = "Банк" end
                    addSmsToHistory(profile, "banking", "them", full_text, os.time())
                    needSortContacts = true
                    if myNick == actualPlayerNick and activeContact ~= "banking" or not UI.windowState[0] then
                        profile.unread["banking"] = (type(profile.unread["banking"]) == "number" and profile.unread["banking"] or 0) + 1
                        if not profile.muted["banking"] then
                            if globalSettings.useScreenNotifications and not globalSettings.dndMode then
                                Sys.activeNotification = { number = "banking", name = "Банк", text = "Получена новая выписка с банковского счета.", time = os.clock() }
                            end
                        end
                    end
                    save_all_data()
                    if myNick == actualPlayerNick and activeContact == "banking" then UI.scrollToBottom = true end
                end
            end)
            return false
        elseif Bank.isCollecting then
            if plain_text:match("^%s*[%|%-]") then
                table.insert(Bank.buffer, plain_text)
                return false 
            end
        end
    end

    local clean_sms_text = plain_text
    local is_unread = false
    
    if clean_sms_text:match("^%s*UNREAD%s*SMS%s+") then
        is_unread = true
        clean_sms_text = clean_sms_text:gsub("^%s*UNREAD%s*", "")
    end
    
    local inc_str, inc_num, inc_text = clean_sms_text:match("^%s*SMS от (.-) %(тел%. ([%d%-]+)%): (.*)")
    if not inc_num then
        inc_num, inc_text = clean_sms_text:match("^%s*SMS от #?([%d%-]+): (.*)")
        inc_str = ""
    end
    
    if not inc_num then
        local n_text, n_str, n_num = clean_sms_text:match("^%s*SMS:%s*(.*) От: (.-) Тел: ([%d%-]+)")
        if n_num then
            inc_num = n_num
            inc_str = n_str
            inc_text = n_text
        end
    end

    if inc_num and inc_text then
        if inc_str and inc_str ~= "" then
            local c_name = inc_str:gsub("_", " ")
            local rp_nick = inc_str:gsub(" ", "_")
            
            if not profile.contacts[inc_num] or profile.contacts[inc_num] == "" then
                profile.contacts[inc_num] = c_name
            end
            if not profile.nicknames then profile.nicknames = {} end
            if not profile.nicknames[inc_num] or profile.nicknames[inc_num] == "" then
                profile.nicknames[inc_num] = rp_nick
            end
        end

        local is_dup = false
        local plus_cont = inc_text:match("^%s*%+%s*(.+)")

        if is_unread then
            local targetHist = nil
            local search_text = (plus_cont or inc_text):gsub("%s*%.%.%.?%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            if profile.metadata and profile.metadata[inc_num] then
                targetHist = (myNick == actualPlayerNick and activeChatId == inc_num) and activeChatHistory or load_chat_history(actualPlayerNick, inc_num)
            end
            if targetHist then
                for i = #targetHist, math.max(1, #targetHist - 100), -1 do
                    local h_text = targetHist[i].msg:gsub("^%s+", ""):gsub("%s+$", "")
                    if h_text:find(search_text, 1, true) then
                        is_dup = true
                        break
                    end
                end
            end
        end

        lastSmsPhone = inc_num
        lastSmsIsUnread = is_unread
        lastSmsIsDup = is_dup
        lastSmsSysTime = os.clock()
        
        if not is_dup then
            local stitched = false
            if plus_cont then
                local targetHist = (myNick == actualPlayerNick and activeChatId == inc_num and activeChatHistory) and activeChatHistory or load_chat_history(actualPlayerNick, inc_num)
                if targetHist and #targetHist > 0 then
                    local lastMsg = targetHist[#targetHist]
                    if lastMsg.sender == "them" and (lastMsg.msg:match("%+%s*$") or (ts - (lastMsg.timestamp or 0) <= 10)) then
                        local baseMsg = lastMsg.msg:gsub("%s*%.%.%.?%s*$", ""):gsub("%s*%+%s*$", "")
                        lastMsg.msg = baseMsg .. " " .. plus_cont
                        lastMsg.bubbleSize = nil
                        if myNick == actualPlayerNick and activeChatId == inc_num then activeChatHistory = targetHist end
                        save_chat_data(actualPlayerNick, inc_num, targetHist)
                        if not profile.metadata then profile.metadata = {} end
                        profile.metadata[inc_num] = { sender = "them", text = lastMsg.msg, timestamp = lastMsg.timestamp }
                        if Sys.activeNotification and Sys.activeNotification.number == inc_num then
                            Sys.activeNotification.text = lastMsg.msg
                        end
                        save_all_data()
                        needSortContacts = true
                        if myNick == actualPlayerNick and activeContact == inc_num then UI.scrollToBottom = true end
                        stitched = true
                    end
                end
            end
            if not stitched then
                addSmsToHistory(profile, inc_num, "them", inc_text, ts)
                syncGlobalVerified(inc_num)
                needSortContacts = true
                if myNick ~= actualPlayerNick or activeContact ~= inc_num or not UI.windowState[0] then
                    profile.unread[inc_num] = (type(profile.unread[inc_num]) == "number" and profile.unread[inc_num] or 0) + 1
                    if not profile.muted[inc_num] then
                        if globalSettings.useScreenNotifications and not globalSettings.dndMode then
                            local cName = profile.contacts[inc_num] or ""
                            Sys.activeNotification = { number = inc_num, name = (cName == "" and inc_num or cName), text = inc_text:gsub("%+$", ""), time = os.clock() }
                        end
                    end
                end
                save_all_data()
                if myNick == actualPlayerNick and activeContact == inc_num then UI.scrollToBottom = true end
            end
        end
        
        if is_unread and globalSettings.hideUnreadOnLogin then return false
        elseif globalSettings.useScreenNotifications then return false
        else
            return 
        end
    end

    local out_str, out_num, out_text = clean_sms_text:match("^%s*SMS к (.-) %(тел%. ([%d%-]+)%): (.*)")
    if not out_num then
        out_num, out_text = clean_sms_text:match("^%s*SMS к #?([%d%-]+): (.*)")
        out_str = ""
    end
    
    if not out_num then
        local n_text, n_str, n_num = clean_sms_text:match("^%s*SMS:%s*(.*) Для: (.-) Тел: ([%d%-]+)")
        if n_num then
            out_num = n_num
            out_str = n_str
            out_text = n_text
        end
    end

    if out_num and out_text then
        if out_str and out_str ~= "" then
            local c_name = out_str:gsub("_", " ")
            local rp_nick = out_str:gsub(" ", "_")
            
            if not profile.contacts[out_num] or profile.contacts[out_num] == "" then
                profile.contacts[out_num] = c_name
            end
            if not profile.nicknames then profile.nicknames = {} end
            if not profile.nicknames[out_num] or profile.nicknames[out_num] == "" then
                profile.nicknames[out_num] = rp_nick
            end
        end

        lastSmsPhone = out_num
        lastSmsIsUnread = false
        lastSmsIsDup = false
        lastSmsSysTime = os.clock()
        
        if pendingLocalSms[out_num] and pendingLocalSms[out_num].count > 0 and (os.clock() - pendingLocalSms[out_num].time < 15.0) then
            pendingLocalSms[out_num].count = pendingLocalSms[out_num].count - 1
            lastSmsWasSkipped = true
        else
            lastSmsWasSkipped = false
            local plus_cont = out_text:match("^%s*%+%s*(.+)")
            local stitched = false
            if plus_cont then
                local targetHist = (myNick == actualPlayerNick and activeChatId == out_num and activeChatHistory) and activeChatHistory or load_chat_history(actualPlayerNick, out_num)
                if targetHist and #targetHist > 0 then
                    local lastMsg = targetHist[#targetHist]
                    if lastMsg.sender == "me" and (lastMsg.msg:match("%+%s*$") or (ts - (lastMsg.timestamp or 0) <= 10)) then
                        local baseMsg = lastMsg.msg:gsub("%s*%.%.%.?%s*$", ""):gsub("%s*%+%s*$", "")
                        lastMsg.msg = baseMsg .. " " .. plus_cont
                        lastMsg.bubbleSize = nil
                        if myNick == actualPlayerNick and activeChatId == out_num then activeChatHistory = targetHist end
                        save_chat_data(actualPlayerNick, out_num, targetHist)
                        if not profile.metadata then profile.metadata = {} end
                        profile.metadata[out_num] = { sender = "me", text = lastMsg.msg, timestamp = lastMsg.timestamp }
                        save_all_data()
                        needSortContacts = true
                        if myNick == actualPlayerNick and activeContact == out_num then UI.scrollToBottom = true end
                        stitched = true
                    end
                end
            end
            
            if not stitched then
                addSmsToHistory(profile, out_num, "me", out_text, ts)
                syncGlobalVerified(out_num)
                needSortContacts = true
                if myNick == actualPlayerNick and activeContact == out_num then UI.scrollToBottom = true end
            end
        end
        
        if globalSettings.useScreenNotifications then return false
        else
            return 
        end
    end

    local continued_text = plain_text:match("^%.%.%.?%s*(.*)")
    if continued_text then
        if lastSmsPhone and (os.clock() - lastSmsSysTime <= 0.5) then
            if not lastSmsIsDup and not lastSmsWasSkipped then
                local targetHist = (myNick == actualPlayerNick and activeChatId == lastSmsPhone) and activeChatHistory or load_chat_history(actualPlayerNick, lastSmsPhone)
                if targetHist and #targetHist > 0 then
                    local prev_msg = targetHist[#targetHist].msg
                    prev_msg = prev_msg:gsub("%s*%.%.%.?%s*$", "")
                    targetHist[#targetHist].msg = prev_msg .. " " .. continued_text
                    targetHist[#targetHist].bubbleSize = nil 
                    save_chat_data(actualPlayerNick, lastSmsPhone, targetHist)
                    if profile.metadata and profile.metadata[lastSmsPhone] then
                        profile.metadata[lastSmsPhone].text = targetHist[#targetHist].msg
                    end
                    save_all_data()
                    if myNick == actualPlayerNick and activeContact == lastSmsPhone then UI.scrollToBottom = true end
                end
            end
            if lastSmsIsUnread and globalSettings.hideUnreadOnLogin then return false
            elseif globalSettings.useScreenNotifications then return false end
            return
        elseif CallState.active and CallState.saved and CallState.number and CallState.callIndex and (os.clock() - CallState.lastMsgSysTime <= 0.5) then
            local callEntry = profile.calls[CallState.number] and profile.calls[CallState.number][CallState.callIndex]
            if callEntry and callEntry.messages and #callEntry.messages > 0 then
                local prev_msg = callEntry.messages[#callEntry.messages].msg
                prev_msg = prev_msg:gsub("%s*%.%.%.?%s*$", "")
                callEntry.messages[#callEntry.messages].msg = prev_msg .. " " .. continued_text
                save_all_data()
                if myNick == actualPlayerNick and activeContact == CallState.number then UI.scrollToBottom = true end
            end
        end
    elseif not plain_text:match("^%s*[%|%-]") then
        lastSmsPhone = nil
        lastSmsIsUnread = false
        lastSmsIsDup = false
    end
end

local notifyFrame = imgui.OnFrame(
    function() 
        return Sys.activeNotification ~= nil and (os.clock() - Sys.activeNotification.time < 5.0) and not UI.windowState[0] 
    end,
    function(player)
        local profile = phoneData[actualPlayerNick]
        if not Sys.activeNotification or not profile then return end

        if globalSettings.font and globalSettings.font > 1 and customFonts[globalSettings.font] then
            imgui.PushFont(customFonts[globalSettings.font])
        end
        
        local baseScale = globalSettings.uiScale or 1.0
        local fontScale = (globalSettings.fontSize or 14.0) / 14.0
        local scale = baseScale * fontScale
        local fontPreview = (globalSettings.fontSize or 14.0) / loadedFontSize
        imgui.GetIO().FontGlobalScale = baseScale * fontPreview

        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY * 0.15), imgui.Cond.Always, imgui.ImVec2(0.5, 0.0))
        
        local active_theme = GetActiveTheme()
        local acc = active_theme.me
        
        ApplyTheme(active_theme, 0.90)
        
        imgui.PushStyleColor(imgui.Col.WindowBg, active_theme.notif_bg)
        imgui.PushStyleColor(imgui.Col.Border, acc)
        imgui.PushStyleColor(imgui.Col.Text, active_theme.notif_text)
        
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(15 * scale, 12 * scale))
        
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoInputs
        if imgui.Begin("##NotifyWindow", nil, flags) then
            if Sys.activeNotification then
                imgui.TextColored(acc, u8"Новое сообщение: " .. u8(Sys.activeNotification.name))
                
                imgui.PushTextWrapPos(350 * scale)
                imgui.Text(u8(Sys.activeNotification.text))
                imgui.PopTextWrapPos()
                
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                local hintText = u8"Нажмите '" .. (globalSettings.openCommand or "P") .. "', чтобы прочитать"
                local hintWidth = imgui.CalcTextSize(hintText).x
                local windowWidth = imgui.GetWindowWidth()
                imgui.SetCursorPosX((windowWidth - hintWidth) / 2)
                imgui.TextColored(imgui.ImVec4(active_theme.notif_text.x * 0.7, active_theme.notif_text.y * 0.7, active_theme.notif_text.z * 0.7, 1.0), hintText)
            end
            imgui.End()
        end
        imgui.PopStyleVar(3)
        imgui.PopStyleColor(23)
        
        if globalSettings.font and globalSettings.font > 1 and customFonts[globalSettings.font] then
            imgui.PopFont()
        end
    end
)
notifyFrame.HideCursor = true 

local unreadIndicatorFrame = imgui.OnFrame(
    function() 
        if Sys.tempSysNotifText and os.clock() < Sys.tempSysNotifTimer then return true end
        local profile = phoneData[actualPlayerNick]
        if not profile then return false end
        for num, val in pairs(profile.unread) do
            local is_u = (type(val) == "number" and val > 0) or (type(val) == "boolean" and val)
            if is_u and not (profile.muted and profile.muted[num]) then return true end
        end
        return false
    end,
    function(player)
        local profile = phoneData[actualPlayerNick]
        if not profile and not (Sys.tempSysNotifText and os.clock() < Sys.tempSysNotifTimer) then return end

        if globalSettings.font and globalSettings.font > 1 and customFonts[globalSettings.font] then
            imgui.PushFont(customFonts[globalSettings.font])
        end
        
        local baseScale = globalSettings.uiScale or 1.0
        local fontScale = (globalSettings.fontSize or 14.0) / 14.0
        local scale = baseScale * fontScale
        local fontPreview = (globalSettings.fontSize or 14.0) / loadedFontSize
        imgui.GetIO().FontGlobalScale = baseScale * fontPreview
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
        local active_theme = GetActiveTheme()

        if Sys.tempSysNotifText and os.clock() < Sys.tempSysNotifTimer then
            textToShow = Sys.tempSysNotifText
            if Sys.tempSysNotifType == 1 then
                borderColor = active_theme.sys_ok
            elseif Sys.tempSysNotifType == 2 then
                borderColor = active_theme.sys_err
            elseif Sys.tempSysNotifType == 3 then
                borderColor = active_theme.sys_info
            else
                borderColor = active_theme.them
            end
        else
            textToShow = u8"У вас есть непрочитанные сообщения (открыть: /" .. (globalSettings.openCommand or "p") .. ")"
            borderColor = active_theme.warn
        end

        imgui.SetNextWindowPos(imgui.ImVec2(posX, posY), imgui.Cond.Always, imgui.ImVec2(pivotX, pivotY))
        
        imgui.PushStyleColor(imgui.Col.WindowBg, active_theme.notif_bg)
        imgui.PushStyleColor(imgui.Col.Border, borderColor)
        imgui.PushStyleColor(imgui.Col.Text, active_theme.notif_text)
        
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 6.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(15 * scale, 10 * scale))
        
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoInputs
        if imgui.Begin("##SysIndicator", nil, flags) then
            imgui.Text(textToShow)
            imgui.End()
        end
        imgui.PopStyleVar(3)
        imgui.PopStyleColor(3)
        
        if globalSettings.font and globalSettings.font > 1 and customFonts[globalSettings.font] then
            imgui.PopFont()
        end
    end
)
unreadIndicatorFrame.HideCursor = true

local function DrawThemeEditor(scale, sizeCond)
    if not UI.showThemeEditor[0] then return end
    imgui.SetNextWindowSize(imgui.ImVec2(600 * scale, 450 * scale), sizeCond)
    if imgui.Begin(u8"Редактор кастомной темы", UI.showThemeEditor) then
        imgui.Columns(2, "ThemeCols", false)
        imgui.SetColumnWidth(0, 240 * scale)
        for i, v in ipairs(ThemeEditor.colorNames) do
            if imgui.Selectable(v[2], ThemeEditor.selectedIdx == i) then
                ThemeEditor.selectedIdx = i
            end
        end
        imgui.NextColumn()
        local curKey = ThemeEditor.colorNames[ThemeEditor.selectedIdx][1]
        local curName = ThemeEditor.colorNames[ThemeEditor.selectedIdx][2]
        imgui.Text(curName)
        imgui.ColorPicker4("##Picker_"..curKey, ThemeEditor.temp[curKey], imgui.ColorEditFlags.AlphaBar + imgui.ColorEditFlags.DisplayHex + imgui.ColorEditFlags.DisplayRGB + imgui.ColorEditFlags.AlphaPreview)
        imgui.Spacing()
        imgui.Spacing()
        local availWidth = imgui.GetContentRegionAvail().x
        local btnW = (availWidth - imgui.GetStyle().ItemSpacing.x) / 2
        local function sa(dest, src, dx, dy, dz, dw)
            if src and #src == 4 then
                dest[0], dest[1], dest[2], dest[3] = src[1], src[2], src[3], src[4]
            else
                dest[0], dest[1], dest[2], dest[3] = dx, dy, dz, dw
            end
        end
        if imgui.Button(u8"Сброс", imgui.ImVec2(btnW, 0)) then
            local cur = themes[1]
            for _, v in ipairs(ThemeEditor.colorNames) do
                local k = v[1]
                local cv = cur[k]
                if cv then
                    ThemeEditor.temp[k][0], ThemeEditor.temp[k][1], ThemeEditor.temp[k][2], ThemeEditor.temp[k][3] = cv.x, cv.y, cv.z, cv.w
                else
                    ThemeEditor.temp[k][0], ThemeEditor.temp[k][1], ThemeEditor.temp[k][2], ThemeEditor.temp[k][3] = cur.me.x, cur.me.y, cur.me.z, cur.me.w
                end
            end
            ThemeEditor.temp.online[0], ThemeEditor.temp.online[1], ThemeEditor.temp.online[2], ThemeEditor.temp.online[3] = 0.2, 0.8, 0.2, 1.0
            ThemeEditor.temp.muted[0], ThemeEditor.temp.muted[1], ThemeEditor.temp.muted[2], ThemeEditor.temp.muted[3] = 0.6, 0.6, 0.6, 1.0
            ThemeEditor.temp.draft[0], ThemeEditor.temp.draft[1], ThemeEditor.temp.draft[2], ThemeEditor.temp.draft[3] = 0.8, 0.4, 0.4, 1.0
            ThemeEditor.temp.call_me[0], ThemeEditor.temp.call_me[1], ThemeEditor.temp.call_me[2], ThemeEditor.temp.call_me[3] = 0.4, 0.7, 1.0, 1.0
            ThemeEditor.temp.call_them[0], ThemeEditor.temp.call_them[1], ThemeEditor.temp.call_them[2], ThemeEditor.temp.call_them[3] = 1.0, 1.0, 1.0, 1.0
            ThemeEditor.temp.call_time[0], ThemeEditor.temp.call_time[1], ThemeEditor.temp.call_time[2], ThemeEditor.temp.call_time[3] = 0.5, 0.5, 0.5, 1.0
        end
        imgui.SameLine()
        if imgui.Button(u8"Сохранить", imgui.ImVec2(btnW, 0)) then
            local newT = {}
            for _, v in ipairs(ThemeEditor.colorNames) do
                local k = v[1]
                newT[k] = {ThemeEditor.temp[k][0], ThemeEditor.temp[k][1], ThemeEditor.temp[k][2], ThemeEditor.temp[k][3]}
            end
            globalSettings.customThemes = globalSettings.customThemes or {}
            if globalSettings.theme > #themes then
                globalSettings.customThemes[globalSettings.theme - #themes] = newT
                showSystemNotification(u8"Тема обновлена!", 1)
            else
                table.insert(globalSettings.customThemes, newT)
                globalSettings.theme = #themes + #globalSettings.customThemes
                showSystemNotification(u8"Пользовательская тема сохранена!", 1)
            end
            save_all_data()
        end
        if imgui.Button(u8"Экспорт", imgui.ImVec2(btnW, 0)) then
            local exp = {}
            for k, v in pairs(ThemeEditor.temp) do
                exp[k] = {v[0], v[1], v[2], v[3]}
            end
            local ok, jStr = pcall(encodeJson, exp)
            if ok then
                imgui.SetClipboardText("MSGTHEME:" .. toHex(jStr))
                showSystemNotification(u8"Тема скопирована в буфер обмена!", 1)
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"Импорт", imgui.ImVec2(btnW, 0)) then
            local cb_ptr = imgui.GetClipboardText()
            if cb_ptr ~= nil then
                local cb = ffi.string(cb_ptr)
                if cb:match("^MSGTHEME:") then
                    local hStr = cb:sub(10)
                    local jStr = fromHex(hStr)
                    local ok, dec = pcall(decodeJson, jStr)
                    if ok and type(dec) == "table" and dec.me then
                        globalSettings.customThemes = globalSettings.customThemes or {}
                        table.insert(globalSettings.customThemes, dec)
                        globalSettings.theme = #themes + #globalSettings.customThemes
                        save_all_data()
                        showSystemNotification(u8"Тема импортирована и применена!", 1)
                    else
                        showSystemNotification(u8"Ошибка: поврежденный код темы!", 2)
                    end
                else
                    showSystemNotification(u8"В буфере обмена нет кода темы!", 2)
                end
            else
                showSystemNotification(u8"Буфер обмена пуст!", 2)
            end
        end
        imgui.Columns(1)
        imgui.End()
    end
end

local function DrawGalleryWindow(scale)
    if not UI.showGallery[0] then return end
    imgui.SetNextWindowSize(imgui.ImVec2(350 * scale, 450 * scale), imgui.Cond.FirstUseEver)
    if imgui.Begin(u8"Галерея сохраненных медиа", UI.showGallery) then
        if not globalSettings.gallery or #globalSettings.gallery == 0 then
            imgui.TextDisabled(u8"Галерея пуста.\nНажмите ПКМ по картинке в чате -> 'В галерею'")
        else
            local thumb_size = 110 * scale
            local avail_w = imgui.GetWindowWidth()
            local cols = math.max(1, math.floor(avail_w / thumb_size))
            imgui.Columns(cols, "GalleryCols", false)
            local deleteGalleryIndex = nil
            for i, url in ipairs(globalSettings.gallery) do
                if not imageCache[url] then
                    if globalSettings.autoDownloadMedia then downloadImageToCache(url) else imageCache[url] = { status = 4 } end
                end
                local c = imageCache[url]
                imgui.PushIDStr("gal_"..i)
                if c.status == 2 then
                    local ratio = c.orig_w / c.orig_h
                    local draw_w, draw_h = thumb_size - (10 * scale), thumb_size - (10 * scale)
                    if ratio > 1 then draw_h = draw_w / ratio else draw_w = draw_h * ratio end
                    local curX = imgui.GetCursorPosX()
                    local curY = imgui.GetCursorPosY()
                    imgui.SetCursorPos(imgui.ImVec2(curX + ((thumb_size - (10 * scale)) - draw_w) / 2, curY + ((thumb_size - (10 * scale)) - draw_h) / 2))
                    imgui.Image(c.tex, imgui.ImVec2(draw_w, draw_h))
                    imgui.SetCursorPos(imgui.ImVec2(curX, curY))
                    imgui.InvisibleButton("galbtn_"..i, imgui.ImVec2(thumb_size - (10 * scale), thumb_size - (10 * scale)))
                    imgui.SetItemAllowOverlap()
                    if imgui.IsItemHovered() then
                        imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                        if imgui.IsMouseClicked(0) then
                            local current = ffi.string(UI.inputMessage)
                            local new_str = current .. (current == "" and "" or " ") .. url
                            ffi.copy(UI.inputMessage, new_str)
                            UI.showGallery[0] = false
                            UI.requestFocus = true
                        end
                    end
                elseif c.status == 1 then
                    imgui.Button(u8"Загрузка...", imgui.ImVec2(thumb_size - (10 * scale), thumb_size - (10 * scale)))
                elseif c.status == 3 then
                    imgui.Button(u8"Ошибка", imgui.ImVec2(thumb_size - (10 * scale), thumb_size - (10 * scale)))
                elseif c.status == 4 then
                    if imgui.Button(u8"Загрузить", imgui.ImVec2(thumb_size - (10 * scale), thumb_size - (10 * scale))) then downloadImageToCache(url) end
                end
                if imgui.BeginPopupContextItem("GalCtx_" .. i) then
                    if imgui.Selectable(u8"Удалить") then deleteGalleryIndex = i end
                    imgui.EndPopup()
                end
                imgui.PopID()
                imgui.NextColumn()
            end
            imgui.Columns(1)
            if deleteGalleryIndex then
                table.remove(globalSettings.gallery, deleteGalleryIndex)
                save_all_data()
            end
        end
    end
    imgui.End()
end

local function DrawModals(scale)
    UI.anyModalOpen = false
    local profile = phoneData[myNick]
    if not profile then return end

    if UI.requestLinkModal then
        imgui.OpenPopup("LinkConfirmModal")
        UI.requestLinkModal = false
    end
    
    if imgui.BeginPopupModal("LinkConfirmModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
        UI.anyModalOpen = true
        if UI.requestCloseModal then imgui.CloseCurrentPopup() UI.requestCloseModal = false end
        
        imgui.Text(u8"Переход по ссылке")
        imgui.Spacing()
        imgui.Text(u8"Вы собираетесь открыть внешнюю ссылку в браузере:")
        imgui.PushTextWrapPos(350 * scale)
        imgui.TextColored(imgui.ImVec4(0.3, 0.6, 1.0, 1.0), UI.linkToOpen)
        imgui.PopTextWrapPos()
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        local availWidth = imgui.GetContentRegionAvail().x
        local btnWidth = (availWidth - imgui.GetStyle().ItemSpacing.x) / 2
        
        if imgui.Button(u8"Перейти", imgui.ImVec2(btnWidth, 0)) then
            local safeUrl = UI.linkToOpen
            if not safeUrl:match("^https?://") then safeUrl = "http://" .. safeUrl end
            lua_thread.create(function() wait(150) shell32.ShellExecuteA(nil, "open", safeUrl, nil, nil, 1) end)
            imgui.CloseCurrentPopup()
        end
        imgui.SameLine()
        if imgui.Button(u8"Отмена", imgui.ImVec2(btnWidth, 0)) then imgui.CloseCurrentPopup() end
        imgui.EndPopup()
    end

    if UI.requestDeletePopup then
        imgui.OpenPopup("DeleteContactConfirm")
        UI.requestDeletePopup = false
    end

    if imgui.BeginPopupModal("DeleteContactConfirm", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
        UI.anyModalOpen = true
        if UI.requestCloseModal then imgui.CloseCurrentPopup() UI.requestCloseModal = false end
        
        imgui.Text(u8"Подтверждение")
        if UI.contactToDelete then
            local rawName = profile.contacts[UI.contactToDelete] or ""
            local cName = ""
            if UI.contactToDelete == "banking" then cName = u8"Банк"
            elseif UI.contactToDelete == "system" then cName = u8"Уведомления"
            else cName = (rawName == "" and "#" .. UI.contactToDelete or u8(rawName) .. " (" .. UI.contactToDelete .. ")") end
            imgui.Text(u8"Вы действительно хотите удалить контакт " .. cName .. u8"?\nВся история сообщений будет стерта.")
        end
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        local availWidth = imgui.GetContentRegionAvail().x
        local btnWidth = (availWidth - imgui.GetStyle().ItemSpacing.x) / 2
        
        if imgui.Button(u8"Удалить", imgui.ImVec2(btnWidth, 0)) then
            if UI.contactToDelete then
                profile.contacts[UI.contactToDelete] = nil
                save_chat_data(myNick, UI.contactToDelete, {})
                profile.metadata[UI.contactToDelete] = nil
                profile.calls[UI.contactToDelete] = nil
                profile.unread[UI.contactToDelete] = nil
                if profile.pinned then profile.pinned[UI.contactToDelete] = nil end
                if profile.muted then profile.muted[UI.contactToDelete] = nil end
                if profile.drafts then profile.drafts[UI.contactToDelete] = nil end
                if activeContact == UI.contactToDelete then activeContact = nil activeChatId = nil activeChatHistory = nil end
                save_all_data()
                needSortContacts = true
            end
            UI.contactToDelete = nil
            imgui.CloseCurrentPopup()
        end
        imgui.SameLine()
        if imgui.Button(u8"Отмена", imgui.ImVec2(btnWidth, 0)) then UI.contactToDelete = nil imgui.CloseCurrentPopup() end
        imgui.EndPopup()
    end
    
    if UI.requestContactModal then
        imgui.OpenPopup("ContactModal")
        UI.requestContactModal = false
    end
    
    if imgui.BeginPopupModal("ContactModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
        UI.anyModalOpen = true
        if UI.requestCloseModal then imgui.CloseCurrentPopup() UI.requestCloseModal = false end
        
        imgui.Text(u8"Управление контактом")
        imgui.Spacing()
        imgui.InputTextWithHint("##CName", u8"Имя контакта", UI.inputContactName, 256)
        imgui.InputTextWithHint("##CNum", u8"Номер", UI.inputContactNumber, 256)
        imgui.InputTextWithHint("##CNick", u8"Ник-нейм игрока для проверки онлайна", UI.inputContactNick, 256)
        
        local current_nick_input = ffi.string(UI.inputContactNick)
        if current_nick_input ~= "" then
            local suggestions = {}
            local lower_input = current_nick_input:lower()
            for nick, _ in pairs(onlinePlayers) do
                if nick:lower():find(lower_input, 1, true) and nick ~= current_nick_input then table.insert(suggestions, nick) end
            end
            if #suggestions > 0 then
                table.sort(suggestions)
                local item_height = imgui.GetTextLineHeightWithSpacing()
                local padding_y = imgui.GetStyle().WindowPadding.y
                local visible_items = math.min(#suggestions, 5)
                local list_height = visible_items * item_height + padding_y * 2
                imgui.BeginChild("SuggestList", imgui.ImVec2(0, list_height), true)
                for _, s_nick in ipairs(suggestions) do
                    if imgui.Selectable(s_nick) then ffi.copy(UI.inputContactNick, s_nick) end
                end
                imgui.EndChild()
            end
        end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        local availWidth = imgui.GetContentRegionAvail().x
        local btnW = (availWidth - imgui.GetStyle().ItemSpacing.x) / 2
        
        if imgui.Button(u8"Сохранить", imgui.ImVec2(btnW, 0)) then
            local name = u8:decode(ffi.string(UI.inputContactName))
            local number = ffi.string(UI.inputContactNumber)
            local nick = ffi.string(UI.inputContactNick)
            if number:match("^[%d%_a%-zA%-Z]+$") then
                profile.contacts[number] = name
                if not profile.nicknames then profile.nicknames = {} end
                if nick ~= "" then profile.nicknames[number] = nick else profile.nicknames[number] = nil end
                save_all_data()
                needSortContacts = true
                imgui.CloseCurrentPopup()
            end
        end
        imgui.SameLine()
        if imgui.Button(u8"Отмена", imgui.ImVec2(btnW, 0)) then imgui.CloseCurrentPopup() end
        imgui.EndPopup()
    end

    if imgui.BeginPopupModal("SettingsModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
        UI.anyModalOpen = true
        if UI.requestCloseModal then imgui.CloseCurrentPopup() UI.requestCloseModal = false end
        
        imgui.Text(u8"Настройки мессенджера")
        imgui.SameLine()
        local ver_str = tostring(script_version)
        if not ver_str:find("%.") then ver_str = ver_str .. ".0" end
        imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "v" .. ver_str)
        imgui.Spacing()
        
        local comboWidth = 250 * scale
        local btnOffset = comboWidth + imgui.GetStyle().ItemSpacing.x + 10
        
        imgui.Text(u8"Ваш профиль (Персонаж):")
        imgui.PushItemWidth(comboWidth)
        if imgui.BeginCombo("##SetProfileCombo", u8(myNick)) then
            for nick, _ in pairs(phoneData) do
                local is_selected = (myNick == nick)
                if imgui.Selectable(u8(nick), is_selected) then
                    myNick = nick
                    profile = phoneData[myNick]
                    activeContact = nil 
                    activeChatId = nil
                    activeChatHistory = nil
                    needSortContacts = true
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Выберите профиль персонажа для загрузки его истории SMS и контактов.") end
        
        imgui.SameLine(btnOffset)
        local isConfirmingProfileDel = (os.clock() < UI.confirmDeleteProfileTimer)
        local delProfLabel = isConfirmingProfileDel and u8"Точно удалить?##char" or u8"Удалить профиль##char"
        if isConfirmingProfileDel then
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.80, 0.20, 0.20, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.90, 0.30, 0.30, 1.0))
        end
        if imgui.Button(delProfLabel, imgui.ImVec2(130 * scale, 0)) then
            if not isConfirmingProfileDel then
                UI.confirmDeleteProfileTimer = os.clock() + 3.0
            else
                UI.confirmDeleteProfileTimer = 0
                removeProfileFolder(myNick)

                local actualNick = "Default"
                local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if r then actualNick = sampGetPlayerNickname(id) end
                
                phoneData[myNick] = nil
                
                if myNick == actualNick and isValidRpNick(actualNick) then
                    phoneData[actualNick] = { contacts = {}, metadata = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, pinned = {}, blocked = {} }
                    phoneData[actualNick].contacts["system"] = "Уведомления"
                else
                    if isValidRpNick(actualNick) then
                        myNick = actualNick
                        if not phoneData[myNick] then
                            phoneData[myNick] = { contacts = {}, metadata = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, pinned = {}, blocked = {} }
                            phoneData[myNick].contacts["system"] = "Уведомления"
                        end
                    else
                        local local_any = next(phoneData)
                        if local_any then myNick = local_any else myNick = "Default" end
                    end
                end
                
                profile = phoneData[myNick]
                activeContact = nil
                activeChatId = nil
                activeChatHistory = nil
                needSortContacts = true
                save_all_data()
            end
        end
        if isConfirmingProfileDel then
            imgui.PopStyleColor(2)
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Безвозвратно удаляет историю и контакты выбранного профиля.") end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        imgui.Text(u8"Внешний вид:")
        
        if globalSettings.iosPhoneMode then
            if globalSettings.iosTheme ~= 1 and globalSettings.iosTheme ~= 2 then
                globalSettings.iosTheme = 1
            end
            local iosThemeNames = { u8"Белая (iOS Светлая)", u8"Чёрная (iOS Тёмная)" }
            imgui.PushItemWidth(comboWidth)
            if imgui.BeginCombo("##SetIosThemeCombo", iosThemeNames[globalSettings.iosTheme]) then
                for i = 1, 2 do
                    if imgui.Selectable(iosThemeNames[i], globalSettings.iosTheme == i) then
                        globalSettings.iosTheme = i
                        save_all_data()
                    end
                end
                imgui.EndCombo()
            end
            imgui.PopItemWidth()
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"В режиме смартфона iOS 26 доступны две системные темы: Белая и Чёрная.") end
        else
            local total_themes = #themes + (globalSettings.customThemes and #globalSettings.customThemes or 0)
            if globalSettings.theme > total_themes then globalSettings.theme = 1 end
            
            local active_theme_name = ""
            if globalSettings.theme <= #themes then
                active_theme_name = u8(themes[globalSettings.theme].name)
            else
                active_theme_name = u8"Пользовательская тема #" .. (globalSettings.theme - #themes)
            end
            
            imgui.PushItemWidth(comboWidth)
            if imgui.BeginCombo("##SetThemeCombo", active_theme_name) then
                for i = 1, total_themes do
                    local tName = (i <= #themes) and themes[i].name or ("Пользовательская тема #" .. (i - #themes))
                    if imgui.Selectable(u8(tName), globalSettings.theme == i) then
                        globalSettings.theme = i
                        save_all_data()
                    end
                end
                imgui.EndCombo()
            end
            imgui.PopItemWidth()
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Выберите цветовую схему мессенджера.") end
            
            imgui.SameLine()
            if imgui.Button(u8"Редактор тем") then
                local function sa(dest, src, dx, dy, dz, dw)
                    if src and #src == 4 then
                        dest[0], dest[1], dest[2], dest[3] = src[1], src[2], src[3], src[4]
                    else
                        dest[0], dest[1], dest[2], dest[3] = dx, dy, dz, dw
                    end
                end
                
                if globalSettings.theme > #themes and globalSettings.customThemes and globalSettings.customThemes[globalSettings.theme - #themes] then
                    local ct = globalSettings.customThemes[globalSettings.theme - #themes]
                    sa(ThemeEditor.temp.me, ct.me, 0.18, 0.35, 0.58, 1.0)
                    sa(ThemeEditor.temp.them, ct.them, 0.25, 0.25, 0.25, 1.0)
                    sa(ThemeEditor.temp.warn, ct.warn, 0.20, 0.60, 0.90, 1.0)
                    sa(ThemeEditor.temp.notif_bg, ct.notif_bg, 0.12, 0.12, 0.12, 0.95)
                    sa(ThemeEditor.temp.notif_text, ct.notif_text, 0.9, 0.9, 0.9, 1.0)
                    sa(ThemeEditor.temp.sys_ok, ct.sys_ok, 0.20, 0.80, 0.20, 0.80)
                    sa(ThemeEditor.temp.sys_err, ct.sys_err, 0.80, 0.20, 0.20, 0.80)
                    sa(ThemeEditor.temp.sys_info, ct.sys_info, 0.20, 0.60, 0.90, 0.80)
                    sa(ThemeEditor.temp.online, ct.online, 0.2, 0.8, 0.2, 1.0)
                    sa(ThemeEditor.temp.muted, ct.muted, 0.6, 0.6, 0.6, 1.0)
                    sa(ThemeEditor.temp.draft, ct.draft, 0.8, 0.4, 0.4, 1.0)
                    sa(ThemeEditor.temp.call_me, ct.call_me, 0.4, 0.7, 1.0, 1.0)
                    sa(ThemeEditor.temp.call_them, ct.call_them, 1.0, 1.0, 1.0, 1.0)
                    sa(ThemeEditor.temp.call_time, ct.call_time, 0.5, 0.5, 0.5, 1.0)
                    sa(ThemeEditor.temp.checkmark, ct.checkmark, 0.18, 0.35, 0.58, 1.0)
                    sa(ThemeEditor.temp.badge_text, ct.badge_text, 1.0, 1.0, 1.0, 1.0)
                    sa(ThemeEditor.temp.bubble_muted, ct.bubble_muted, 0.5, 0.5, 0.5, 1.0)
                else
                    local cur = themes[globalSettings.theme] or themes[1]
                    sa(ThemeEditor.temp.me, {cur.me.x, cur.me.y, cur.me.z, cur.me.w}, 0.18, 0.35, 0.58, 1.0)
                    sa(ThemeEditor.temp.them, {cur.them.x, cur.them.y, cur.them.z, cur.them.w}, 0.25, 0.25, 0.25, 1.0)
                    sa(ThemeEditor.temp.warn, {cur.warn.x, cur.warn.y, cur.warn.z, cur.warn.w}, 0.20, 0.60, 0.90, 1.0)
                    sa(ThemeEditor.temp.notif_bg, {cur.notif_bg.x, cur.notif_bg.y, cur.notif_bg.z, cur.notif_bg.w}, 0.12, 0.12, 0.12, 0.95)
                    sa(ThemeEditor.temp.notif_text, {cur.notif_text.x, cur.notif_text.y, cur.notif_text.z, cur.notif_text.w}, 0.9, 0.9, 0.9, 1.0)
                    sa(ThemeEditor.temp.sys_ok, {cur.sys_ok.x, cur.sys_ok.y, cur.sys_ok.z, cur.sys_ok.w}, 0.20, 0.80, 0.20, 0.80)
                    sa(ThemeEditor.temp.sys_err, {cur.sys_err.x, cur.sys_err.y, cur.sys_err.z, cur.sys_err.w}, 0.80, 0.20, 0.20, 0.80)
                    sa(ThemeEditor.temp.sys_info, {cur.sys_info.x, cur.sys_info.y, cur.sys_info.z, cur.sys_info.w}, 0.20, 0.60, 0.90, 0.80)
                    
                    sa(ThemeEditor.temp.online, cur.online and {cur.online.x, cur.online.y, cur.online.z, cur.online.w} or nil, 0.2, 0.8, 0.2, 1.0)
                    sa(ThemeEditor.temp.muted, cur.muted and {cur.muted.x, cur.muted.y, cur.muted.z, cur.muted.w} or nil, 0.6, 0.6, 0.6, 1.0)
                    sa(ThemeEditor.temp.draft, cur.draft and {cur.draft.x, cur.draft.y, cur.draft.z, cur.draft.w} or nil, 0.8, 0.4, 0.4, 1.0)
                    sa(ThemeEditor.temp.call_me, cur.call_me and {cur.call_me.x, cur.call_me.y, cur.call_me.z, cur.call_me.w} or nil, 0.4, 0.7, 1.0, 1.0)
                    sa(ThemeEditor.temp.call_them, cur.call_them and {cur.call_them.x, cur.call_them.y, cur.call_them.z, cur.call_them.w} or nil, 1.0, 1.0, 1.0, 1.0)
                    sa(ThemeEditor.temp.call_time, cur.call_time and {cur.call_time.x, cur.call_time.y, cur.call_time.z, cur.call_time.w} or nil, 0.5, 0.5, 0.5, 1.0)
                    sa(ThemeEditor.temp.checkmark, cur.checkmark and {cur.checkmark.x, cur.checkmark.y, cur.checkmark.z, cur.checkmark.w} or nil, cur.me.x, cur.me.y, cur.me.z, cur.me.w)
                    sa(ThemeEditor.temp.badge_text, cur.badge_text and {cur.badge_text.x, cur.badge_text.y, cur.badge_text.z, cur.badge_text.w} or nil, 1.0, 1.0, 1.0, 1.0)
                    sa(ThemeEditor.temp.bubble_muted, cur.bubble_muted and {cur.bubble_muted.x, cur.bubble_muted.y, cur.bubble_muted.z, cur.bubble_muted.w} or nil, 0.5, 0.5, 0.5, 1.0)
                end
                UI.showThemeEditor[0] = not UI.showThemeEditor[0]
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Открыть редактор для создания или изменения своей собственной темы.") end
            
            if globalSettings.theme > #themes then
                imgui.SameLine()
                if imgui.Button(u8"Удалить тему") then
                    table.remove(globalSettings.customThemes, globalSettings.theme - #themes)
                    globalSettings.theme = 1
                    save_all_data()
                end
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Удалить текущую кастомную тему.") end
            end
        end
        
        imgui.Spacing()
        imgui.Text(u8"Шрифт и размер текста:")
        local current_font_idx = globalSettings.font or 1
        if current_font_idx > #fontNames then current_font_idx = 1 end
        imgui.PushItemWidth(comboWidth)
        if imgui.BeginCombo("##SetFontCombo", fontNames[current_font_idx]) then
            for i, fName in ipairs(fontNames) do
                if imgui.Selectable(fName, current_font_idx == i) then
                    globalSettings.font = i
                    save_all_data()
                    lua_thread.create(function() wait(50) thisScript():reload() end)
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Изменить шрифт текста.\nВнимание: Скрипт будет перезагружен!") end
        
        local fSizeArr = imgui.new.float[1](globalSettings.fontSize or 14.0)
        imgui.PushItemWidth(100 * scale)
        if imgui.SliderFloat("##FontSize", fSizeArr, 10.0, 24.0, "%.1f") then
            globalSettings.fontSize = fSizeArr[0]
            UI.forceResize = true
            save_all_data()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Настроить размер шрифта.\nИзменения отображаются сразу в предпросмотре.") end
        
        imgui.SameLine()
        if imgui.Button(u8"Сбросить") then
            globalSettings.fontSize = 14.0
            UI.forceResize = true
            save_all_data()
            lua_thread.create(function() wait(50) thisScript():reload() end)
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Вернуть стандартный размер шрифта (14.0).") end
        
        imgui.SameLine()
        if imgui.Button(u8"Применить и перезагрузить##Font") then
            save_all_data()
            lua_thread.create(function() wait(50) thisScript():reload() end)
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Запечь шрифт в новом размере для высокого качества.\nВнимание: Скрипт будет перезагружен!") end
        imgui.Spacing()
        imgui.Text(u8"Масштаб интерфейса:")
        local uiScaleArr = imgui.new.float[1](globalSettings.uiScale or 1.0)
        imgui.PushItemWidth(150 * scale)
        if imgui.SliderFloat("##UIScale", uiScaleArr, 0.5, 2.0, "%.2f") then
            globalSettings.uiScale = uiScaleArr[0]
            UI.forceResize = true
            save_all_data()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Изменить масштаб (размер) всех элементов мессенджера.") end
        
        imgui.SameLine()
        if imgui.Button(u8"Сбросить размер") then
            globalSettings.uiScale = 1.0
            UI.forceResize = true
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Вернуть масштаб к стандартному (1.0).") end
        
        imgui.Spacing()
        imgui.Text(u8"Положение системных уведомлений:")
        local current_pos_idx = globalSettings.notifPos
        imgui.PushItemWidth(comboWidth)
        if imgui.BeginCombo("##NotifPosCombo", notifPositions[current_pos_idx]) then
            for i, posName in ipairs(notifPositions) do
                if imgui.Selectable(posName, current_pos_idx == i) then
                    globalSettings.notifPos = i
                    save_all_data()
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Выберите угол экрана, где будут появляться всплывающие мини-уведомления (плашки).") end
        
        imgui.Spacing()
        local current_sort_idx = globalSettings.contactSortMode or 1
        imgui.Text(u8"Сортировка контактов:")
        imgui.PushItemWidth(comboWidth)
        if imgui.BeginCombo("##SortModeCombo", sortModes[current_sort_idx]) then
            for i, modeName in ipairs(sortModes) do
                if imgui.Selectable(modeName, current_sort_idx == i) then
                    globalSettings.contactSortMode = i
                    save_all_data()
                    needSortContacts = true
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Выберите, как сортировать список диалогов в левой панели.") end
        
        imgui.Spacing()
        
        local currentModIdx = 1
        for i, v in ipairs(availableMods) do if v.val == globalSettings.openMod then currentModIdx = i break end end
        local currentKeyIdx = 16
        for i, v in ipairs(availableKeys) do if v.val == globalSettings.openKey then currentKeyIdx = i break end end
        
        imgui.Text(u8"Бинд открытия мессенджера:")
        imgui.PushItemWidth(100 * scale)
        if imgui.BeginCombo("##ModCombo", availableMods[currentModIdx].name) then
            for i, v in ipairs(availableMods) do
                if imgui.Selectable(v.name, currentModIdx == i) then
                    globalSettings.openMod = v.val
                    save_all_data()
                end
            end
            imgui.EndCombo()
        end
        imgui.SameLine()
        imgui.Text("+")
        imgui.SameLine()
        if imgui.BeginCombo("##KeyCombo", availableKeys[currentKeyIdx].name) then
            for i, v in ipairs(availableKeys) do
                if imgui.Selectable(v.name, currentKeyIdx == i) then
                    globalSettings.openKey = v.val
                    save_all_data()
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Клавиши для быстрого открытия/закрытия мессенджера.") end
        
        imgui.PushItemWidth(150 * scale)
        imgui.InputTextWithHint("##CmdInput", u8"Команда", UI.inputOpenCommand, 64)
        if imgui.Button(u8"Сохранить команду и перезагрузить") then
            globalSettings.openCommand = ffi.string(UI.inputOpenCommand)
            save_all_data()
            lua_thread.create(function() wait(50) thisScript():reload() end)
        end
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Изменить команду для открытия (например: /phone).\nВнимание: Скрипт будет перезагружен!") end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        imgui.Text(u8"Дополнительные функции:")
        imgui.Spacing()

        UI.settingIosPhoneMode[0] = globalSettings.iosPhoneMode or false
        if imgui.Checkbox(u8"Режим смартфона iOS 26 (компактный телефон в углу экрана)", UI.settingIosPhoneMode) then
            globalSettings.iosPhoneMode = UI.settingIosPhoneMode[0]
            if globalSettings.iosPhoneMode then
                if globalSettings.theme ~= 2 then
                    globalSettings.iosTheme = 1
                else
                    globalSettings.iosTheme = 2
                end
                UI.showThemeEditor[0] = false
            end
            UI.showContactProfile = false
            UI.forceResize = true
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Переключает интерфейс мессенджера в формат современного смартфона iOS 26 в правом нижнем углу экрана.") end
        
        UI.settingCloseChatOnEsc[0] = globalSettings.closeChatOnEsc or false
        if imgui.Checkbox(u8"Закрывать диалог по нажатию ESC", UI.settingCloseChatOnEsc) then
            globalSettings.closeChatOnEsc = UI.settingCloseChatOnEsc[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Если включено, ESC сначала закроет открытый диалог (вернет к списку), а повторное нажатие закроет мессенджер.") end

        UI.settingSaveImages[0] = globalSettings.saveImagesPersistently or false
        if imgui.Checkbox(u8"Сохранять картинки на диске (Кэширование)", UI.settingSaveImages) then
            globalSettings.saveImagesPersistently = UI.settingSaveImages[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Картинки сохраняются в папку images и не скачиваются повторно, ускоряя загрузку и экономя трафик.") end
        
        UI.settingHideUnread[0] = globalSettings.hideUnreadOnLogin or false
        if imgui.Checkbox(u8"Скрывать непрочитанные при входе", UI.settingHideUnread) then
            globalSettings.hideUnreadOnLogin = UI.settingHideUnread[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Скрывать из чата оффлайн-сообщения (UNREAD SMS), которые приходят при авторизации. Они всё равно будут сохранены в историю.") end

        UI.settingHideContactNumber[0] = globalSettings.hideContactNumber or false
        if imgui.Checkbox(u8"Скрывать номер у сохраненных контактов", UI.settingHideContactNumber) then
            globalSettings.hideContactNumber = UI.settingHideContactNumber[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Если у контакта задано имя, его номер не будет отображаться в списке контактов (в чате он останется).") end

        UI.settingScreenNotif[0] = globalSettings.useScreenNotifications
        if imgui.Checkbox(u8"Всплывающие уведомления (и скрытие SMS из чата)", UI.settingScreenNotif) then
            globalSettings.useScreenNotifications = UI.settingScreenNotif[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Показывать системные уведомления в углу экрана и полностью скрывать SMS из чата.") end
        
        UI.settingDND[0] = globalSettings.dndMode
        if imgui.Checkbox(u8"Режим 'Не беспокоить' (откл. всплывающие окна)", UI.settingDND) then
            globalSettings.dndMode = UI.settingDND[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Отключает появление всплывающих окон при получении SMS, но сообщения всё равно сохраняются в историю.") end
        
        UI.settingAutoDownload[0] = globalSettings.autoDownloadMedia
        if imgui.Checkbox(u8"Автоматически загружать медиа (картинки по ссылкам)", UI.settingAutoDownload) then
            globalSettings.autoDownloadMedia = UI.settingAutoDownload[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Скрипт будет сам загружать и отрисовывать картинки, если в сообщении прислана ссылка на изображение.") end

        UI.settingHideJunk[0] = globalSettings.hideSmsJunk
        if imgui.Checkbox(u8"Отключение серверного шлака телефона", UI.settingHideJunk) then
            globalSettings.hideSmsJunk = UI.settingHideJunk[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Скрывать надоедливые сообщения сервера типа 'Осталось сообщений до лимита', 'С вашего счета списано' и т.д.") end
        
        UI.settingLogBank[0] = globalSettings.logBank
        if imgui.Checkbox(u8"Сохранять выписки из банка (PayDay) в отдельный диалог", UI.settingLogBank) then
            globalSettings.logBank = UI.settingLogBank[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Логирует всю серверную выписку (зарплата, налоги) в отдельный чат 'Банк'.") end

        UI.settingAutoUpdate[0] = globalSettings.autoUpdate
        if imgui.Checkbox(u8"Автообновление скрипта", UI.settingAutoUpdate) then
            globalSettings.autoUpdate = UI.settingAutoUpdate[0]
            save_all_data()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Автоматически проверять наличие новых версий скрипта при запуске игры.") end
        
        imgui.SameLine()
        if imgui.Button(u8"Проверить обновление") then checkUpdates(true) end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Принудительно проверить новые версии прямо сейчас.") end
        
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()
        
        local dbSize = 0
        local pDir = getWorkingDirectory() .. '\\config\\Messenger\\' .. myNick
        if lfs.attributes(pDir, "mode") == "directory" then
            local pFile = pDir .. '\\profile.json'
            if file_exists(pFile) then dbSize = dbSize + (lfs.attributes(pFile, "size") or 0) end
            local cDir = pDir .. '\\chats'
            if lfs.attributes(cDir, "mode") == "directory" then
                for file in lfs.dir(cDir) do
                    if file ~= "." and file ~= ".." then
                        local cPath = cDir .. '\\' .. file
                        if lfs.attributes(cPath, "mode") == "file" then
                            dbSize = dbSize + (lfs.attributes(cPath, "size") or 0)
                        end
                    end
                end
            end
        end
        
        local sizeText = ""
        if dbSize < 1024 then sizeText = string.format("%d B", dbSize)
        elseif dbSize < 1048576 then sizeText = string.format("%.2f KB", dbSize / 1024.0)
        else sizeText = string.format("%.2f MB", dbSize / 1048576.0) end
        
        local btnWidth = 100 * scale
        local currentY = imgui.GetCursorPosY()
        
        imgui.AlignTextToFramePadding()
        imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1.0), u8"Размер базы данных: " .. sizeText)
        
        imgui.SameLine()
        local availRight = imgui.GetContentRegionAvail().x
        if availRight > btnWidth then imgui.SetCursorPosX(imgui.GetCursorPosX() + availRight - btnWidth) end
        
        imgui.SetCursorPosY(currentY)
        if imgui.Button(u8"Закрыть", imgui.ImVec2(btnWidth, 0)) then imgui.CloseCurrentPopup() end
        
        imgui.EndPopup()
    end
end

local function DrawImageViewer(scale, resX, resY)
    if not UI.viewingImage then return end
    imgui.SetNextWindowPos(imgui.ImVec2(0, 0), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(resX, resY), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0, 0, 0, 0.85))
    if imgui.Begin("FullscreenImage", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings) then
        local c = imageCache[UI.viewingImage]
        if c and c.status == 2 then
            local img_w, img_h = c.orig_w, c.orig_h
            local max_w, max_h = resX * 0.95, resY * 0.95
            if img_w > max_w or img_h > max_h then
                local ratio = math.min(max_w / img_w, max_h / img_h)
                img_w = img_w * ratio
                img_h = img_h * ratio
            end
            imgui.SetCursorPos(imgui.ImVec2((resX - img_w) / 2, (resY - img_h) / 2))
            imgui.Image(c.tex, imgui.ImVec2(img_w, img_h))
        else
            local txt = c and c.status == 1 and u8"Загрузка..." or u8"Ошибка загрузки"
            local tw = imgui.CalcTextSize(txt).x
            imgui.SetCursorPos(imgui.ImVec2((resX - tw) / 2, resY / 2))
            imgui.Text(txt)
        end
        local hintText = u8"Кликните в любом месте или нажмите ESC, чтобы закрыть"
        local hW = imgui.CalcTextSize(hintText).x
        imgui.SetCursorPos(imgui.ImVec2((resX - hW) / 2, resY - 30 * scale))
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 0.5), hintText)
        if imgui.IsWindowHovered() and imgui.IsMouseClicked(0) then
            UI.viewingImage = nil
        end
    end
    imgui.End()
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)
end

local function DrawContactsList(scale, profile, leftAvailW)
    imgui.AlignTextToFramePadding()
    imgui.Text(u8"Контакты:")
    local framePadX = imgui.GetStyle().FramePadding.x
    local cleanBtnText = u8"Сброс лимита"
    local settingsBtnText = u8"Настройки"
    local cleanBtnWidth = imgui.CalcTextSize(cleanBtnText).x + (framePadX * 2.0)
    local settingsBtnWidth = imgui.CalcTextSize(settingsBtnText).x + (framePadX * 2.0)
    local spaceX = imgui.GetStyle().ItemSpacing.x
    local totalLeftBtnsWidth = cleanBtnWidth + settingsBtnWidth + spaceX
    imgui.SameLine()
    local availLeft = imgui.GetContentRegionAvail().x
    if availLeft > totalLeftBtnsWidth then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + availLeft - totalLeftBtnsWidth)
    end
    if imgui.Button(cleanBtnText) then
        UI.windowState[0] = false 
        Macro.autoCleaning = true
        Macro.cleanStep = 1
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
                Macro.autoCleaning = false
                UI.windowState[0] = true
                return
            end
            local appFound = false
            for i = 1, 50 do
                wait(50)
                for td = 2304, 0, -1 do
                    if sampTextdrawIsExists(td) then
                        local posX, posY = sampTextdrawGetPos(td)
                        if posX >= 529.0 and posX <= 533.0 and posY >= 407.0 and posY <= 411.0 then
                            sampSendClickTextdraw(td)
                            appFound = true
                            break
                        end
                    end
                end
                if appFound then break end
            end
            if not appFound then
                showSystemNotification(u8"Ошибка: иконка сообщений не появилась.", 2)
                Macro.autoCleaning = false
                UI.windowState[0] = true
                return
            end
            Macro.cleanStep = 2
            wait(10000)
            if Macro.autoCleaning then
                Macro.autoCleaning = false
                Macro.cleanStep = 0
                showSystemNotification(u8"Ошибка: Таймаут. Сервер не ответил на диалоги.", 2)
                sampSendClickTextdraw(65535)
                sampSendChat("/untd 2")
                UI.windowState[0] = true 
            end
        end)
    end
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Автоматически очистить серверный лимит сообщений") end
    imgui.SameLine(0, spaceX)
    if imgui.Button(settingsBtnText) then
        imgui.OpenPopup("SettingsModal")
    end
	if imgui.IsItemHovered() then imgui.SetTooltip(u8"Открыть настройки мессенджера") end
    imgui.Spacing()
    local btnPlusW = 30 * scale
    local searchW = leftAvailW - btnPlusW - spaceX
    imgui.PushItemWidth(searchW)
    imgui.InputTextWithHint("##SearchContactList", u8"Поиск контактов...", UI.inputSearchContact, 256)
    imgui.PopItemWidth()
    imgui.SameLine(0, spaceX)
    if imgui.Button("+", imgui.ImVec2(btnPlusW, 0)) then
        UI.inputContactName[0] = 0
        UI.inputContactNumber[0] = 0
        UI.inputContactNick[0] = 0
        UI.requestContactModal = true
    end
	if imgui.IsItemHovered() then imgui.SetTooltip(u8"Добавить новый контакт") end
    imgui.Spacing()
    if needSortContacts then
        cachedSortedContacts = {}
        local uniqueNumbers = {}
        for num, _ in pairs(profile.contacts) do uniqueNumbers[num] = true end
        if profile.metadata then
            for num, _ in pairs(profile.metadata) do uniqueNumbers[num] = true end
        end
        if profile.calls then
            for num, _ in pairs(profile.calls) do uniqueNumbers[num] = true end
        end
        if profile.metadata and profile.metadata["banking"] then uniqueNumbers["banking"] = true end
        if profile.metadata and profile.metadata["system"] then uniqueNumbers["system"] = true end
        for num, _ in pairs(uniqueNumbers) do
            local name = profile.contacts[num] or ""
            local hasName = (name ~= "")
            local meta = profile.metadata and profile.metadata[num]
            local hasHistory = (meta ~= nil)
            local calls = profile.calls and profile.calls[num]
            local hasCalls = (calls and #calls > 0)
            local isSystem = (num == "banking" or num == "system")
            if hasName or hasHistory or hasCalls or isSystem then
                local last_ts = 0
                if hasHistory then
                    last_ts = meta.timestamp or 0
                end
                if hasCalls then
                    local last_call_ts = calls[#calls].timestamp or 0
                    if last_call_ts > last_ts then
                        last_ts = last_call_ts
                    end
                end
                table.insert(cachedSortedContacts, {num = num, name = name, last_ts = last_ts})
            end
        end
        table.sort(cachedSortedContacts, function(a, b)
            local a_pin = profile.pinned and profile.pinned[a.num] or false
            local b_pin = profile.pinned and profile.pinned[b.num] or false
            if a_pin ~= b_pin then
                return a_pin
            end
            local mode = globalSettings.contactSortMode or 1
            if mode == 2 then
                local a_saved = (a.name ~= "")
                local b_saved = (b.name ~= "")
                if a_saved ~= b_saved then
                    return a_saved
                end
            elseif mode == 3 then
                local a_nick = profile.nicknames and profile.nicknames[a.num]
                local b_nick = profile.nicknames and profile.nicknames[b.num]
                local a_online = a_nick and onlinePlayers[a_nick] or false
                local b_online = b_nick and onlinePlayers[b_nick] or false
                if a_online ~= b_online then
                    return a_online and not b_online
                end
            end
            return a.last_ts > b.last_ts
        end)
        needSortContacts = false
    end
    imgui.BeginChild("ContactsList", imgui.ImVec2(0, 0), true)
    local sContactText = cp1251_lower(u8:decode(ffi.string(UI.inputSearchContact)))
    for _, c in ipairs(cachedSortedContacts) do
        local num = c.num
        local name = c.name
        local skipContact = false
        if sContactText ~= "" then
            local lowerName = cp1251_lower(name)
            local lowerNum = cp1251_lower(num)
            local localDisplay = ""
            if num == "banking" then 
                localDisplay = cp1251_lower(u8:decode(u8"Банк"))
            elseif num == "system" then 
                localDisplay = cp1251_lower(u8:decode(u8"Уведомления"))
            else 
                localDisplay = lowerName == "" and ("#" .. lowerNum) or (lowerName .. " (" .. lowerNum .. ")")
            end
            if not localDisplay:find(sContactText, 1, true) then
                skipContact = true
            end
        end
        if not skipContact then
            imgui.PushIDStr("contact_" .. num)
            local is_selected = (activeContact == num)
            local is_unread = profile.unread and profile.unread[num]
            if is_selected and is_unread and UI.windowState[0] then
                profile.unread[num] = nil
                save_profile_data(myNick)
                is_unread = false
            end
            local displayName = ""
            if num == "banking" then
                displayName = u8"Банк"
            elseif num == "system" then
                displayName = u8"Уведомления"
            else
                if name == "" then
                    displayName = "#" .. num
                else
                    if globalSettings.hideContactNumber then
                        displayName = u8(name)
                    else
                        displayName = u8(name) .. " (" .. num .. ")"
                    end
                end
            end
            local cursorPos = imgui.GetCursorScreenPos()
            local avail_w = imgui.GetContentRegionAvail().x
            local item_h = imgui.GetTextLineHeight() * 2 + 14
            local p_min = cursorPos
            local p_max = imgui.ImVec2(cursorPos.x + avail_w, cursorPos.y + item_h)
            local is_clicked = imgui.InvisibleButton("btn_" .. num, imgui.ImVec2(avail_w, item_h))
            local is_hovered = imgui.IsItemHovered()
            if is_clicked then
                if activeContact ~= num then
                    SaveCurrentDraft()
                    activeContact = num
                    activeChatId = num
                    activeChatHistory = load_chat_history(myNick, num)
                    UI.showCallHistory = false
                    UI.viewingCallIndex = 0
                    LoadDraft(num)
                    UI.showMessageSearch = false
                    UI.inputSearchMessage[0] = 0
                end
                UI.scrollToBottom = true
                UI.requestFocus = true
            end
            if imgui.BeginPopupContextItem("ContactPopup_" .. num) then
                local isPinned = profile.pinned and profile.pinned[num]
                if imgui.Selectable(isPinned and u8"Открепить диалог" or u8"Закрепить диалог") then
                    if not profile.pinned then profile.pinned = {} end
                    if isPinned then profile.pinned[num] = nil else profile.pinned[num] = true end
                    save_all_data()
                    needSortContacts = true
                end
                imgui.Separator()
                if profile.tagger and profile.tagger[num] then
                    if imgui.Selectable(u8"Открыть Nova (Social)") then
                        local url = "https://nova.gambit-rp.com/" .. profile.tagger[num]
                        shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
                    end
                    imgui.Separator()
                end
                if num == "system" then
                    if imgui.Selectable(u8"Очистить историю") then
                        save_chat_data(myNick, num, {})
                        if activeContact == num then activeChatHistory = {} end
                        profile.metadata[num] = nil
                        for _, p in pairs(phoneData) do
                            if p.unread then p.unread[num] = nil end
                            if p.muted then p.muted[num] = nil end
                            if p.drafts then p.drafts[num] = nil end
                        end
                        if activeContact == num then activeContact = nil activeChatId = nil activeChatHistory = nil end
                        save_all_data()
                        needSortContacts = true
                    end
                elseif num == "banking" then
                    local muteText = profile.muted and profile.muted[num] and u8"Включить уведомления" or u8"Отключить уведомления"
                    if imgui.Selectable(muteText) then
                        if not profile.muted then profile.muted = {} end
                        profile.muted[num] = not profile.muted[num]
                        if profile.muted[num] then
                            if Sys.activeNotification and Sys.activeNotification.number == num then Sys.activeNotification = nil end
                        end
                        save_all_data()
                    end
                    imgui.Separator()
                    if imgui.Selectable(u8"Очистить историю") then
                        save_chat_data(myNick, num, {})
                        if activeContact == num then activeChatHistory = {} end
                        profile.metadata[num] = nil
                        profile.unread[num] = nil
                        if profile.muted then profile.muted[num] = nil end
                        if profile.drafts then profile.drafts[num] = nil end
                        if activeContact == num then activeContact = nil activeChatId = nil activeChatHistory = nil end
                        save_all_data()
                        needSortContacts = true
                    end
                else
                    if imgui.Selectable(u8"Изменить") then
                        ffi.copy(UI.inputContactNumber, num)
                        ffi.copy(UI.inputContactName, u8(name))
                        local nick = (profile.nicknames and profile.nicknames[num]) and profile.nicknames[num] or ""
                        ffi.copy(UI.inputContactNick, nick)
                        UI.requestContactModal = true
                    end
                    if imgui.Selectable(u8"Позвонить") then
                        sampSendChat("/call " .. num)
                        UI.windowState[0] = false 
                    end
                    local muteText = profile.muted and profile.muted[num] and u8"Включить уведомления" or u8"Отключить уведомления"
                    if imgui.Selectable(muteText) then
                        if not profile.muted then profile.muted = {} end
                        profile.muted[num] = not profile.muted[num]
                        if profile.muted[num] then
                            if Sys.activeNotification and Sys.activeNotification.number == num then Sys.activeNotification = nil end
                        end
                        save_all_data()
                    end
                    imgui.Separator()
                    if imgui.Selectable(u8"Очистить историю") then
                        save_chat_data(myNick, num, {})
                        if activeContact == num then activeChatHistory = {} end
                        profile.metadata[num] = nil
                        profile.calls[num] = nil
                        profile.unread[num] = nil
                        save_all_data()
                        needSortContacts = true
                    end
                    local isBlocked = profile.blocked and profile.blocked[num]
                    local blockText = isBlocked and u8"Разблокировать" or u8"Заблокировать"
                    if imgui.Selectable(blockText) then
                        Macro.autoBlock = true
                        sampSendChat("/blocknum " .. num)
                    end
                    imgui.Separator()
                    if imgui.Selectable(u8"Удалить контакт") then
                        UI.contactToDelete = num
                        UI.requestDeletePopup = true
                    end
                end
                imgui.EndPopup()
            end
            local active_theme_render = GetActiveTheme()
            local dl = imgui.GetWindowDrawList()
            local bg_color = imgui.ImVec4(0, 0, 0, 0)
            local is_muted = profile.muted and profile.muted[num]
            if is_selected then bg_color = active_theme_render.me
            elseif is_hovered then bg_color = imgui.ImVec4(active_theme_render.me.x, active_theme_render.me.y, active_theme_render.me.z, 0.6)
            elseif is_unread then
                if is_muted then
                    local m_col = active_theme_render.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
                    bg_color = imgui.ImVec4(m_col.x, m_col.y, m_col.z, 0.25)
                else
                    bg_color = imgui.ImVec4(active_theme_render.warn.x, active_theme_render.warn.y, active_theme_render.warn.z, 0.25)
                end
            else
                bg_color = imgui.ImVec4(active_theme_render.them.x, active_theme_render.them.y, active_theme_render.them.z, 0.4)
            end
            dl:AddRectFilled(p_min, p_max, imgui.GetColorU32Vec4(bg_color), 8.0)
            local time_str = ""
            local snippet = ""
            local meta = profile.metadata and profile.metadata[num]
            local calls = profile.calls and profile.calls[num]
            local last_sms_ts = meta and meta.timestamp or 0
            local last_call_ts = (calls and #calls > 0) and calls[#calls].timestamp or 0
            if last_sms_ts > 0 or last_call_ts > 0 then
                if last_sms_ts >= last_call_ts then
                    time_str = formatMessageTime(last_sms_ts)
                    if num == "banking" then snippet = u8"Вам пришла выписка из банка"
                    elseif num == "system" then
                        local prefix = (meta.sender == "me") and u8"Вы: " or ""
                        snippet = prefix .. u8(meta.text):gsub("\n", " ")
                    else
                        local prefix = (meta.sender == "me") and u8"Вы: " or ""
                        snippet = prefix .. u8(meta.text):gsub("\n", " ")
                    end
                else
                    time_str = formatMessageTime(last_call_ts)
                    snippet = u8"[Звонок]"
                end
            else
                snippet = u8"Нет сообщений"
            end
            local time_w = imgui.CalcTextSize(time_str).x
            local badges_w = 0
            local isPinned = profile.pinned and profile.pinned[num]
            local isVerified = (num == "banking" or num == "system" or (profile.verified and profile.verified[num]))
            if isPinned then badges_w = badges_w + (20 * scale) end
            if isVerified then badges_w = badges_w + (22 * scale) end
            if profile.muted and profile.muted[num] then badges_w = badges_w + (20 * scale) end
            if profile.blocked and profile.blocked[num] then badges_w = badges_w + (20 * scale) end
            if profile.nicknames and profile.nicknames[num] and onlinePlayers[profile.nicknames[num]] then badges_w = badges_w + (14 * scale) end
            
            local max_name_w = avail_w - time_w - badges_w - (30 * scale)
            local truncDisplayName = truncateText(displayName, max_name_w)

            local name_color = imgui.ImVec4(1, 1, 1, 1)
            dl:AddText(imgui.ImVec2(p_min.x + 10, p_min.y + 6), imgui.GetColorU32Vec4(name_color), truncDisplayName)
            local nextOffset = 10 + imgui.CalcTextSize(truncDisplayName).x
            
            if isVerified then
                local badge_center = imgui.ImVec2(p_min.x + nextOffset + (12 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                DrawVerificationBadge(dl, badge_center, 6.0 * scale, scale)
                
                local old_pos = imgui.GetCursorScreenPos()
                imgui.SetCursorScreenPos(imgui.ImVec2(badge_center.x - 6*scale, badge_center.y - 6*scale))
                imgui.InvisibleButton("##BadgeTipList" .. num, imgui.ImVec2(12*scale, 12*scale))
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Этот контакт официально верифицирован.") end
                imgui.SetCursorScreenPos(old_pos)
                
                nextOffset = nextOffset + (22 * scale)
            end
            if isPinned then
                local pin_center = imgui.ImVec2(p_min.x + nextOffset + (10 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                DrawPinBadge(dl, pin_center, 6.0 * scale, scale)
                
                local old_pos = imgui.GetCursorScreenPos()
                imgui.SetCursorScreenPos(imgui.ImVec2(pin_center.x - 6*scale, pin_center.y - 6*scale))
                imgui.InvisibleButton("##PinTipList" .. num, imgui.ImVec2(12*scale, 12*scale))
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Диалог закреплён") end
                imgui.SetCursorScreenPos(old_pos)
                
                nextOffset = nextOffset + (20 * scale)
            end
            if profile.muted and profile.muted[num] then
                local mute_center = imgui.ImVec2(p_min.x + nextOffset + (10 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                local mutedColor = active_theme_render.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
                DrawMuteBadge(dl, mute_center, 6.0 * scale, scale, mutedColor)
                
                local old_pos = imgui.GetCursorScreenPos()
                imgui.SetCursorScreenPos(imgui.ImVec2(mute_center.x - 6*scale, mute_center.y - 6*scale))
                imgui.InvisibleButton("##MuteTipList" .. num, imgui.ImVec2(12*scale, 12*scale))
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Уведомления отключены") end
                imgui.SetCursorScreenPos(old_pos)
                
                nextOffset = nextOffset + (20 * scale)
            end
            if profile.blocked and profile.blocked[num] then
                local block_center = imgui.ImVec2(p_min.x + nextOffset + (10 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                DrawBlockBadge(dl, block_center, 6.0 * scale, scale)
                
                local old_pos = imgui.GetCursorScreenPos()
                imgui.SetCursorScreenPos(imgui.ImVec2(block_center.x - 6*scale, block_center.y - 6*scale))
                imgui.InvisibleButton("##BlockTipList" .. num, imgui.ImVec2(12*scale, 12*scale))
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Контакт в чёрном списке") end
                imgui.SetCursorScreenPos(old_pos)
                
                nextOffset = nextOffset + (20 * scale)
            end
            if profile.nicknames and profile.nicknames[num] then
                local contactNick = profile.nicknames[num]
                if onlinePlayers[contactNick] then
                    local circle_center = imgui.ImVec2(p_min.x + nextOffset + (8 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                    local onlineCol = active_theme_render.online or imgui.ImVec4(0.2, 0.8, 0.2, 1.0)
                    dl:AddCircleFilled(circle_center, 4.0 * scale, imgui.GetColorU32Vec4(onlineCol))
                end
            end
            dl:AddText(imgui.ImVec2(p_max.x - time_w - (10 * scale), p_min.y + (6 * scale)), imgui.GetColorU32Vec4(imgui.ImVec4(0.6, 0.6, 0.6, 1.0)), time_str)
            if is_unread and not is_selected then
                local unreadCount = type(profile.unread[num]) == "number" and profile.unread[num] or 1
                local badgeText = tostring(unreadCount)
                local badgeTextSize = imgui.CalcTextSize(badgeText)
                local badgePadX = 6 * scale
                local badgePadY = 1 * scale
                local badgeW = math.max(badgeTextSize.x + badgePadX * 2, 18 * scale)
                local badgeH = badgeTextSize.y + badgePadY * 2
                local badge_x = p_max.x - badgeW - (10 * scale)
                local badge_y = p_min.y + (8 * scale) + imgui.GetTextLineHeight()
                local badgeColor = is_muted and active_theme_render.muted or active_theme_render.warn
                dl:AddRectFilled(imgui.ImVec2(badge_x, badge_y), imgui.ImVec2(badge_x + badgeW, badge_y + badgeH), imgui.GetColorU32Vec4(badgeColor), 10.0 * scale)
                local text_px = badge_x + (badgeW - badgeTextSize.x) / 2
                local text_py = badge_y + (badgeH - badgeTextSize.y) / 2
                dl:AddText(imgui.ImVec2(text_px, text_py), imgui.GetColorU32Vec4(active_theme_render.badge_text), badgeText)
            end
            local snippet_max_w = avail_w - (is_unread and (40 * scale) or (20 * scale))
            local has_draft = profile.drafts and profile.drafts[num] and profile.drafts[num] ~= ""
            if has_draft and activeContact ~= num then
                local draftLabel = u8"[Черновик]: "
                local draftLabelW = imgui.CalcTextSize(draftLabel).x
                local draftCol = active_theme_render.draft or imgui.ImVec4(0.8, 0.4, 0.4, 1.0)
                dl:AddText(imgui.ImVec2(p_min.x + 10, p_min.y + 6 + imgui.GetTextLineHeight() + 2), imgui.GetColorU32Vec4(draftCol), draftLabel)
                local draftText = u8(profile.drafts[num]):gsub("\n", " ")
                local trunc_snippet = truncateToLastWord(draftText, snippet_max_w - draftLabelW)
                dl:AddText(imgui.ImVec2(p_min.x + 10 + draftLabelW, p_min.y + 6 + imgui.GetTextLineHeight() + 2), imgui.GetColorU32Vec4(imgui.ImVec4(0.65, 0.65, 0.65, 1.0)), trunc_snippet)
            else
                local trunc_snippet = truncateToLastWord(snippet, snippet_max_w)
                dl:AddText(imgui.ImVec2(p_min.x + (10 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() + (2 * scale)), imgui.GetColorU32Vec4(imgui.ImVec4(0.65, 0.65, 0.65, 1.0)), trunc_snippet)
            end
            imgui.SetCursorPosY(imgui.GetCursorPosY() + (4 * scale))
            imgui.PopID()
        end
    end
    imgui.EndChild()
end

local function DrawChatHistory(scale, profile)
    if activeContact then
        local contactName = ""
        if activeContact == "banking" then
            contactName = u8"Банк"
        elseif activeContact == "system" then
            contactName = u8"Уведомления"
        else
            local rawName = profile.contacts[activeContact] or ""
            contactName = (rawName == "" and "#" .. activeContact or u8(rawName) .. " (" .. activeContact .. ")")
        end
        local isSystemChat = (activeContact == "banking" or activeContact == "system")
        imgui.AlignTextToFramePadding()
        imgui.Text(u8"Диалог: " .. contactName)
        local isVerifiedChat = (isSystemChat or (profile.verified and profile.verified[activeContact]))
        if isVerifiedChat then
            imgui.SameLine(0, 2 * scale)
            local dl = imgui.GetWindowDrawList()
            local c_pos = imgui.GetCursorScreenPos()
            local b_radius = 6.5 * scale
            local badge_center = imgui.ImVec2(c_pos.x + b_radius, c_pos.y + (imgui.GetTextLineHeight() / 2) + (2.0 * scale))
            DrawVerificationBadge(dl, badge_center, b_radius, scale)
            
            imgui.InvisibleButton("BadgeHintHead", imgui.ImVec2(b_radius * 2, b_radius * 2))
            if imgui.IsItemHovered() then
                imgui.SetTooltip(u8"Этот контакт официально верифицирован.")
            end
        end
        if profile.pinned and profile.pinned[activeContact] then
            imgui.SameLine(0, 4 * scale)
            local dl = imgui.GetWindowDrawList()
            local c_pos = imgui.GetCursorScreenPos()
            local b_radius = 6.5 * scale
            local badge_center = imgui.ImVec2(c_pos.x + b_radius, c_pos.y + (imgui.GetTextLineHeight() / 2) + (2.0 * scale))
            DrawPinBadge(dl, badge_center, b_radius, scale)
            
            imgui.InvisibleButton("PinHintHead", imgui.ImVec2(b_radius * 2, b_radius * 2))
            if imgui.IsItemHovered() then
                imgui.SetTooltip(u8"Диалог закреплён")
            end
        end
        if profile.muted and profile.muted[activeContact] then
            imgui.SameLine(0, 4 * scale)
            local dl = imgui.GetWindowDrawList()
            local c_pos = imgui.GetCursorScreenPos()
            local b_radius = 6.5 * scale
            local badge_center = imgui.ImVec2(c_pos.x + b_radius, c_pos.y + (imgui.GetTextLineHeight() / 2) + (2.0 * scale))
            local actTheme = GetActiveTheme()
            DrawMuteBadge(dl, badge_center, b_radius, scale, actTheme.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0))
            
            imgui.InvisibleButton("MuteHintHead", imgui.ImVec2(b_radius * 2, b_radius * 2))
            if imgui.IsItemHovered() then
                imgui.SetTooltip(u8"Уведомления отключены")
            end
        end
        if profile.blocked and profile.blocked[activeContact] then
            imgui.SameLine(0, 4 * scale)
            local dl = imgui.GetWindowDrawList()
            local c_pos = imgui.GetCursorScreenPos()
            local b_radius = 6.5 * scale
            local badge_center = imgui.ImVec2(c_pos.x + b_radius, c_pos.y + (imgui.GetTextLineHeight() / 2) + (2.0 * scale))
            DrawBlockBadge(dl, badge_center, b_radius, scale)
            
            imgui.InvisibleButton("BlockHintHead", imgui.ImVec2(b_radius * 2, b_radius * 2))
            if imgui.IsItemHovered() then
                imgui.SetTooltip(u8"Контакт в чёрном списке")
            end
        end
        if not isSystemChat then
            local framePadX = imgui.GetStyle().FramePadding.x
            local spaceX = imgui.GetStyle().ItemSpacing.x
            local geoBtnText = u8"Геопозиция"
            local searchBtnText = u8"Поиск"
            local galBtnText = u8"Галерея"
            local callHistBtnText = u8"История звонков"
            local geoBtnWidth = imgui.CalcTextSize(geoBtnText).x + (framePadX * 2.0)
            local searchBtnWidth = imgui.CalcTextSize(searchBtnText).x + (framePadX * 2.0)
            local galBtnWidth = imgui.CalcTextSize(galBtnText).x + (framePadX * 2.0)
            local callHistBtnWidth = imgui.CalcTextSize(callHistBtnText).x + (framePadX * 2.0)
            
            local totalRightBtnsWidth = searchBtnWidth + galBtnWidth + geoBtnWidth + callHistBtnWidth + (spaceX * 3)
            local right_edge = imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x
            
            if right_edge - totalRightBtnsWidth > imgui.GetCursorPosX() then
                imgui.SameLine()
                imgui.SetCursorPosX(right_edge - totalRightBtnsWidth)
            else
                imgui.Spacing()
            end
            
            if imgui.Button(callHistBtnText) then
                UI.showCallHistory = not UI.showCallHistory
                UI.viewingCallIndex = 0
                UI.callOpenedFromChat = false
                UI.showMessageSearch = false
                UI.showGallery[0] = false
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Посмотреть историю звонков с этим контактом") end
            imgui.SameLine(0, spaceX)
            
            if imgui.Button(galBtnText) then
                UI.showGallery[0] = not UI.showGallery[0]
                UI.showCallHistory = false
                UI.showMessageSearch = false
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Открыть галерею сохраненных изображений") end
            imgui.SameLine(0, spaceX)
            
            if imgui.Button(searchBtnText) then
                UI.showMessageSearch = not UI.showMessageSearch
                if UI.showMessageSearch then 
                    UI.showCallHistory = false
                    UI.showGallery[0] = false
                    UI.requestFocusSearch = true 
                else 
                    UI.inputSearchMessage[0] = 0 
                end
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Поиск по сообщениям в текущем диалоге") end
            
            imgui.SameLine(0, spaceX)
            if imgui.Button(geoBtnText) then
                    Macro.targetGeoNumber = tostring(activeContact):match("[%d%-]+")
                    if Macro.targetGeoNumber then
                        UI.windowState[0] = false 
                        Macro.autoGeo = true
                        Macro.geoStep = 1
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
                                Macro.autoGeo = false
                                UI.windowState[0] = true
                                return
                            end
                            local appFound = false
                            for i = 1, 50 do
                                wait(50)
                                for td = 2304, 0, -1 do
                                    if sampTextdrawIsExists(td) then
                                        local posX, posY = sampTextdrawGetPos(td)
                                        if posX >= 529.0 and posX <= 533.0 and posY >= 407.0 and posY <= 411.0 then
                                            sampSendClickTextdraw(td)
                                            appFound = true
                                            break
                                        end
                                    end
                                end
                                if appFound then break end
                            end
                            if not appFound then
                                showSystemNotification(u8"Ошибка: иконка сообщений не появилась.", 2)
                                Macro.autoGeo = false
                                UI.windowState[0] = true
                                return
                            end
                            Macro.geoStep = 2
                            wait(10000)
                            if Macro.autoGeo then
                                Macro.autoGeo = false
                                Macro.geoStep = 0
                                showSystemNotification(u8"Ошибка: Таймаут. Сервер не ответил на диалоги.", 2)
                                sampSendClickTextdraw(65535)
                                sampSendChat("/untd 2")
                                UI.windowState[0] = true 
                            end
                        end)
                    else
                        showSystemNotification(u8"Ошибка: неверный номер телефона.", 2)
                    end
                end
			if imgui.IsItemHovered() then imgui.SetTooltip(u8"Автоматически отправить свои координаты этому контакту") end
        else
            local searchBtnText = u8"Поиск"
            local framePadX = imgui.GetStyle().FramePadding.x
            local searchBtnWidth = imgui.CalcTextSize(searchBtnText).x + (framePadX * 2.0)
            local right_edge = imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x
            
            if right_edge - searchBtnWidth > imgui.GetCursorPosX() then
                imgui.SameLine()
                imgui.SetCursorPosX(right_edge - searchBtnWidth)
            else
                imgui.Spacing()
            end
            
            if imgui.Button(searchBtnText) then
                UI.showMessageSearch = not UI.showMessageSearch
                if UI.showMessageSearch then 
                    UI.requestFocusSearch = true 
                else 
                    UI.inputSearchMessage[0] = 0 
                end
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Поиск по сообщениям в текущем диалоге") end
        end
        if UI.showMessageSearch then
            imgui.Spacing()
            imgui.PushItemWidth(-1)
            if UI.requestFocusSearch then
                imgui.SetKeyboardFocusHere()
                UI.requestFocusSearch = false
            end
            imgui.InputTextWithHint("##SearchMessage", u8"Поиск по сообщениям...", UI.inputSearchMessage, 256)
            imgui.PopItemWidth()
        end
        imgui.Spacing()
        if UI.showCallHistory then
            imgui.BeginChild("CallHistoryView", imgui.ImVec2(0, -40 * scale), true)
            local cCalls = profile.calls and profile.calls[activeContact] or {}
            local deleteCallIndex = nil
            if UI.viewingCallIndex == 0 then
                if #cCalls > 0 then
                    for i = #cCalls, 1, -1 do
                        local callData = cCalls[i]
                        local dateStr = os.date("%d.%m.%Y %H:%M:%S", callData.timestamp)
                        local calc_duration = 0
                        if callData.duration and callData.duration > 0 then
                            calc_duration = callData.duration
                        elseif callData.messages and #callData.messages > 0 then
                            calc_duration = callData.messages[#callData.messages].timestamp - callData.messages[1].timestamp
                        end
                        local durationStr = ""
                        if calc_duration > 0 then
                            local h = math.floor(calc_duration / 3600)
                            local m = math.floor((calc_duration % 3600) / 60)
                            local s = calc_duration % 60
                            if h > 0 then
                                durationStr = string.format(" (%d ч. %d мин. %d сек.)", h, m, s)
                            elseif m > 0 then
                                durationStr = string.format(" (%d мин. %d сек.)", m, s)
                            else
                                durationStr = string.format(" (%d сек.)", s)
                            end
                        end
                        imgui.PushIDStr("callhist_"..i)
                        if imgui.Button(u8("Звонок от " .. dateStr .. durationStr) .. "##call" .. i, imgui.ImVec2(-1, 0)) then
                            UI.viewingCallIndex = i
                            UI.callOpenedFromChat = false
                        end
                        if imgui.BeginPopupContextItem("CallCtx_" .. i) then
                            if imgui.Selectable(u8"Удалить") then
                                deleteCallIndex = i
                            end
                            imgui.EndPopup()
                        elseif imgui.IsItemHovered() then
                            imgui.SetTooltip(u8"ПКМ - удалить звонок")
                        end
                        imgui.PopID()
                    end
                else
                    imgui.TextDisabled(u8"Нет записанных звонков с этим контактом.")
                end
            else
                local backBtnLabel = UI.callOpenedFromChat and u8"<- Назад к диалогу" or u8"<- Назад к списку звонков"
                if imgui.Button(backBtnLabel) then
                    if UI.callOpenedFromChat then
                        UI.showCallHistory = false
                        UI.viewingCallIndex = 0
                        UI.callOpenedFromChat = false
                    else
                        UI.viewingCallIndex = 0
                    end
                end
                imgui.Separator()
                local cCall = cCalls[UI.viewingCallIndex]
                local deleteCallMsgIndex = nil
                local actTheme = GetActiveTheme()
                if cCall and cCall.messages then
                    for i, msgData in ipairs(cCall.messages) do
                        local isMe = (msgData.sender == "me")
                        local color = isMe and (actTheme.call_me or imgui.ImVec4(0.4, 0.7, 1.0, 1.0)) or (actTheme.call_them or imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
                        local prefix = isMe and u8"Вы: " or u8"Собеседник: "
                        local timeStr = os.date("%H:%M:%S", msgData.timestamp)
                        imgui.TextColored(actTheme.call_time or imgui.ImVec4(0.5, 0.5, 0.5, 1.0), "[" .. timeStr .. "] ")
                        imgui.SameLine()
                        imgui.PushStyleColor(imgui.Col.Text, color)
                        imgui.PushTextWrapPos(imgui.GetWindowWidth() - 20 * scale)
                        imgui.Text(prefix .. u8(msgData.msg))
                        imgui.PopTextWrapPos()
                        imgui.PopStyleColor()
                        if imgui.BeginPopupContextItem("CallMsgCtx_" .. i) then
                            if imgui.Selectable(u8"Скопировать") then
                                imgui.SetClipboardText(u8(msgData.msg))
                            end
                            imgui.Separator()
                            if imgui.Selectable(u8"Удалить") then
                                deleteCallMsgIndex = i
                            end
                            imgui.EndPopup()
                        end
                    end
                else
                    imgui.TextDisabled(u8"Пустой диалог.")
                end
                if deleteCallMsgIndex then
                    table.remove(cCall.messages, deleteCallMsgIndex)
                    save_all_data()
                end
            end
            if deleteCallIndex then
                table.remove(profile.calls[activeContact], deleteCallIndex)
                save_all_data()
                needSortContacts = true
            end
            imgui.EndChild()
        else
            imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
            imgui.BeginChild("ChatHistory", imgui.ImVec2(0, -40 * scale), true)
            imgui.PopStyleVar()
            
            imgui.SetCursorPosY(10 * scale)
            
            if not UI.localBgCheckTime or os.clock() - UI.localBgCheckTime > 2.0 then
                UI.localBgCheckTime = os.clock()
                UI.localBgPath = nil
                if file_exists(imagesFolder .. "background.png") then UI.localBgPath = imagesFolder .. "background.png"
                elseif file_exists(imagesFolder .. "background.jpg") then UI.localBgPath = imagesFolder .. "background.jpg"
                end
            end

            local bgUrl = nil
            local isLocalBg = false
            
            if globalVerified[activeContact] and globalVerified[activeContact].background_url and globalVerified[activeContact].background_url ~= "" then
                bgUrl = globalVerified[activeContact].background_url
            elseif UI.localBgPath then
                bgUrl = UI.localBgPath
                isLocalBg = true
            end

            if bgUrl then
                if not imageCache[bgUrl] then
                    if isLocalBg then
                        imageCache[bgUrl] = { status = 1 }
                        lua_thread.create(function()
                            wait(0)
                            local rtex = renderLoadTextureFromFile(bgUrl)
                            if rtex then
                                local tex_w, tex_h = renderGetTextureSize(rtex)
                                renderReleaseTexture(rtex)
                                local tex = imgui.CreateTextureFromFile(bgUrl)
                                if tex then
                                    imageCache[bgUrl] = { status = 2, tex = tex, w = tex_w, h = tex_h, orig_w = tex_w, orig_h = tex_h }
                                else
                                    imageCache[bgUrl] = { status = 3 }
                                end
                            else
                                imageCache[bgUrl] = { status = 3 }
                            end
                        end)
                    else
                        if globalSettings.autoDownloadMedia then downloadImageToCache(bgUrl) else imageCache[bgUrl] = { status = 4 } end
                    end
                end
                
                local bg = imageCache[bgUrl]
                if bg and bg.status == 2 then
                    local dl = imgui.GetWindowDrawList()
                    local c_pos = imgui.GetWindowPos()
                    local c_size = imgui.GetWindowSize()
                    
                    local scale_w = c_size.x / bg.orig_w
                    local scale_h = c_size.y / bg.orig_h
                    local max_scale = math.max(scale_w, scale_h)
                    
                    local draw_w = bg.orig_w * max_scale
                    local draw_h = bg.orig_h * max_scale
                    local off_x = (c_size.x - draw_w) / 2
                    local off_y = (c_size.y - draw_h) / 2
                    
                    dl:AddImage(bg.tex, 
                        imgui.ImVec2(c_pos.x + off_x, c_pos.y + off_y), 
                        imgui.ImVec2(c_pos.x + off_x + draw_w, c_pos.y + off_y + draw_h), 
                        imgui.ImVec2(0, 0), imgui.ImVec2(1, 1), 
                        imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 0.15))
                    )
                end
            end
            
            local currentHistory = activeChatHistory or {}
            local cCalls = (profile.calls and profile.calls[activeContact]) or {}
            local deleteMsgIndex = nil
            local timeline = {}
            for idx, mData in ipairs(currentHistory) do
                table.insert(timeline, { itemType = "sms", index = idx, data = mData, timestamp = mData.timestamp or 0 })
            end
            for idx, cData in ipairs(cCalls) do
                table.insert(timeline, { itemType = "call", index = idx, data = cData, timestamp = cData.timestamp or 0 })
            end
            table.sort(timeline, function(a, b)
                if a.timestamp == b.timestamp then
                    if a.itemType ~= b.itemType then return a.itemType == "sms" end
                    return a.index < b.index
                end
                return a.timestamp < b.timestamp
            end)
            if #timeline > 0 then
                local last_date_str = ""
                local active_theme = GetActiveTheme()
                local scrollY = imgui.GetScrollY()
                local windowH = imgui.GetWindowHeight()
                local culling_buffer = 200 * scale
                local sMsgText = cp1251_lower(u8:decode(ffi.string(UI.inputSearchMessage)))
                local isMsgSearching = UI.showMessageSearch and sMsgText ~= ""
                for _, entry in ipairs(timeline) do
                    if entry.itemType == "call" then
                        if not isMsgSearching then
                            local callData = entry.data
                            local callIdx = entry.index
                            local current_date_str = get_day_string(callData.timestamp)
                            local has_date = (current_date_str ~= last_date_str)
                            if has_date then
                                imgui.Spacing()
                                local tSize = imgui.CalcTextSize(u8(current_date_str)).x
                                imgui.SetCursorPosX((imgui.GetWindowWidth() - tSize) / 2)
                                imgui.TextDisabled(u8(current_date_str))
                                imgui.Spacing()
                                last_date_str = current_date_str
                            end
                            local calc_duration = 0
                            local isOngoing = (CallState.active and CallState.number == activeContact and CallState.callIndex == callIdx)
                            if isOngoing then
                                calc_duration = os.time() - (CallState.startTime or os.time())
                            elseif callData.duration and callData.duration > 0 then
                                calc_duration = callData.duration
                            elseif callData.messages and #callData.messages > 0 then
                                calc_duration = callData.messages[#callData.messages].timestamp - callData.messages[1].timestamp
                            end
                            local callStr = isOngoing and ("Идёт звонок (" .. formatCallDuration(calc_duration) .. ")") or ("Звонок продлился " .. formatCallDuration(calc_duration))
                            local callTextU8 = u8(callStr)
                            imgui.Spacing()
                            local tSize = imgui.CalcTextSize(callTextU8)
                            local posX = (imgui.GetWindowWidth() - tSize.x) / 2
                            local posY = imgui.GetCursorPosY()
                            imgui.SetCursorPosX(posX)
                            local isCallHover = false
                            imgui.InvisibleButton("##chat_call_btn_" .. callIdx, imgui.ImVec2(tSize.x, tSize.y + 4 * scale))
                            if imgui.IsItemHovered() then
                                isCallHover = true
                                imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                                imgui.SetTooltip(u8"Нажмите, чтобы открыть запись звонка")
                                if imgui.IsMouseClicked(0) then
                                    UI.showCallHistory = true
                                    UI.viewingCallIndex = callIdx
                                    UI.callOpenedFromChat = true
                                end
                            end
                            imgui.SetCursorPos(imgui.ImVec2(posX, posY))
                            local callCol = isCallHover and imgui.ImVec4(0.55, 0.82, 1.0, 1.0) or imgui.ImVec4(0.35, 0.68, 1.0, 1.0)
                            imgui.TextColored(callCol, callTextU8)
                            imgui.Spacing()
                        end
                    else
                        local index = entry.index
                        local msgData = entry.data
                        local skipMsg = false
                        if isMsgSearching then
                            local lowerMsg = cp1251_lower(msgData.msg)
                            if not lowerMsg:find(sMsgText, 1, true) then
                                skipMsg = true
                            end
                        end
                        if not skipMsg then
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
                        local wrap_width = 300 * scale 
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
                            elseif imageCache[url] and imageCache[url].status == 4 then
                                loadedStr = loadedStr .. url .. "manual"
                            end
                        end
                        if not msgData.bubbleSize or msgData.cachedScale ~= scale or msgData.urlsStr ~= urlsStr or msgData.loadedStr ~= loadedStr then
                            local msgTextSize = imgui.ImVec2(0, 0)
                            if textToDisplay ~= "" then
                                msgTextSize = imgui.CalcTextSize(textToDisplay, nil, false, wrap_width)
                            end
                            local timeSize = imgui.CalcTextSize(timeText)
                            local padding = imgui.ImVec2(12 * scale, 8 * scale)
                            local b_width = 0
                            if textToDisplay ~= "" then
                                b_width = msgTextSize.x
                            end
                            local b_height = padding.y * 1.5 + timeSize.y
                            if textToDisplay ~= "" then
                                b_height = b_height + msgTextSize.y + 5
                            end
                            for _, url in ipairs(urls) do
                                local isImg = false
                                local lUrl = url:lower()
                                if lUrl:match("^https?://i%.imgur%.com/") then
                                    if lUrl:match("%.png$") or lUrl:match("%.jpe?g$") or lUrl:match("%.gif$") then
                                        isImg = true
                                    end
                                end
                                if isImg then
                                    if imageCache[url] and imageCache[url].status == 2 then
                                        b_width = math.max(b_width, imageCache[url].w * scale)
                                        b_height = b_height + (imageCache[url].h * scale) + 5
                                    elseif imageCache[url] and imageCache[url].status == 4 then
                                        local load_size = imgui.CalcTextSize(u8"Загрузить изображение")
                                        b_width = math.max(b_width, load_size.x + 20)
                                        b_height = b_height + imgui.GetFrameHeight() + 5
                                    else
                                        b_width = math.max(b_width, 150 * scale)
                                        b_height = b_height + 150 * scale + 5
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
                            msgData.cachedScale = scale
                            msgData.urls = urls
                            msgData.urlsStr = urlsStr
                            msgData.loadedStr = loadedStr
                            msgData.textToDisplay = textToDisplay
                        end
                        local bubbleSize = imgui.ImVec2(msgData.bubbleSize.x, msgData.bubbleSize.y)
                        local timeSize = imgui.ImVec2(msgData.timeSize.x, msgData.timeSize.y)
                        local padding = imgui.ImVec2(12 * scale, 8 * scale)
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
                            local cursorX = 10 * scale
                            if msgData.sender == "me" then
                                cursorX = windowWidth - bubbleSize.x - (25 * scale)
                            end
                            imgui.SetCursorPos(imgui.ImVec2(cursorX, bubble_start_y))
                            local screenPos = imgui.GetCursorScreenPos()
                            local color = msgData.sender == "me" and active_theme.me or active_theme.them
                            local unreadCount = type(profile.unread[activeContact]) == "number" and profile.unread[activeContact] or (profile.unread[activeContact] and 1 or 0)
                            local isMuted = profile.muted and profile.muted[activeContact]
                            local isUnreadMsg = (msgData.sender == "them" and unreadCount > 0 and index > (#currentHistory - unreadCount))
                            if isUnreadMsg and isMuted then
                                color = active_theme.bubble_muted or imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
                            end
                            imgui.GetWindowDrawList():AddRectFilled(
                                screenPos,
                                imgui.ImVec2(screenPos.x + bubbleSize.x, screenPos.y + bubbleSize.y),
                                imgui.GetColorU32Vec4(color), 
                                10.0 * scale
                            )
                            imgui.SetCursorPos(imgui.ImVec2(cursorX, bubble_start_y))
                            imgui.InvisibleButton("msgbtn_" .. index, bubbleSize)
                            imgui.SetItemAllowOverlap() 
                            if imgui.BeginPopupContextItem("MsgPopup_" .. index) then
                                if imgui.Selectable(u8"Скопировать") then
                                    imgui.SetClipboardText(text)
                                end
                                imgui.Separator()
                                if imgui.Selectable(u8"Удалить") then
                                    deleteMsgIndex = index
                                end
                                imgui.EndPopup()
                            elseif imgui.IsItemHovered() then
                                imgui.SetTooltip(u8"ПКМ - управление сообщением")
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
                                local isImg = false
                                local lUrl = url:lower()
                                if lUrl:match("^https?://i%.imgur%.com/") then
                                    if lUrl:match("%.png$") or lUrl:match("%.jpe?g$") or lUrl:match("%.gif$") then
                                        isImg = true
                                    end
                                end
                                if isImg then
                                    imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                    if not imageCache[url] then
                                        if globalSettings.autoDownloadMedia then
                                            downloadImageToCache(url)
                                        else
                                            imageCache[url] = { status = 4 }
                                        end
                                    end
                                    if imageCache[url].status == 1 then
                                        local p_size = 150 * scale
                                        local t_size = imgui.CalcTextSize(u8"Загрузка...")
                                        imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x + (p_size - t_size.x) / 2, currentOffset + (p_size - t_size.y) / 2))
                                        imgui.TextDisabled(u8"Загрузка...")
                                        currentOffset = currentOffset + p_size + 5
                                    elseif imageCache[url].status == 2 then
                                        imgui.Image(imageCache[url].tex, imgui.ImVec2(imageCache[url].w * scale, imageCache[url].h * scale))
                                        imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                        imgui.InvisibleButton("imgbtn_"..index.."_"..u_idx, imgui.ImVec2(imageCache[url].w * scale, imageCache[url].h * scale))
                                        imgui.SetItemAllowOverlap()
                                        if imgui.IsItemHovered() then
                                            imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                                            imgui.SetTooltip(u8"ЛКМ - на весь экран | ПКМ - меню")
                                            if imgui.IsMouseClicked(0) then
                                                UI.viewingImage = url
                                            end
                                        end
                                        if imgui.BeginPopupContextItem("ImgCtx_"..index.."_"..u_idx) then
                                            if imgui.Selectable(u8"В галерею") then
                                                globalSettings.gallery = globalSettings.gallery or {}
                                                local exists = false
                                                for _, v in ipairs(globalSettings.gallery) do if v == url then exists = true break end end
                                                if not exists then
                                                    table.insert(globalSettings.gallery, url)
                                                    save_all_data()
                                                    showSystemNotification(u8"Картинка сохранена в галерею", 1)
                                                else
                                                    showSystemNotification(u8"Картинка уже есть в галерее", 3)
                                                end
                                            end
                                            imgui.Separator()
                                            if imgui.Selectable(u8"Скопировать ссылку") then
                                                imgui.SetClipboardText(url)
                                            end
                                            if imgui.Selectable(u8"Открыть в браузере") then
                                                UI.linkToOpen = url
                                                UI.requestLinkModal = true
                                            end
                                            imgui.EndPopup()
                                        end
                                        currentOffset = currentOffset + (imageCache[url].h * scale) + 5
                                    elseif imageCache[url].status == 3 then
                                        local p_size = 150 * scale
                                        local t_size = imgui.CalcTextSize(u8"Ошибка загрузки")
                                        imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x + (p_size - t_size.x) / 2, currentOffset + (p_size - t_size.y) / 2))
                                        imgui.TextDisabled(u8"Ошибка загрузки")
                                        currentOffset = currentOffset + p_size + 5
                                    elseif imageCache[url].status == 4 then
                                        local p_size = 150 * scale
                                        local btn_w = imgui.CalcTextSize(u8"Загрузить").x + 20 * scale
                                        local btn_h = imgui.GetFrameHeight()
                                        imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x + (p_size - btn_w) / 2, currentOffset + (p_size - btn_h) / 2))
                                        if imgui.Button(u8"Загрузить##" .. index .. "_" .. u_idx, imgui.ImVec2(btn_w, btn_h)) then
                                            downloadImageToCache(url)
                                        end
                                        currentOffset = currentOffset + p_size + 5
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
                                            UI.linkToOpen = url
                                            UI.requestLinkModal = true
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
                end
                if deleteMsgIndex then
                    table.remove(currentHistory, deleteMsgIndex)
                    if #currentHistory > 0 then
                        local lMsg = currentHistory[#currentHistory]
                        profile.metadata[activeContact] = { sender = lMsg.sender, text = lMsg.msg, timestamp = lMsg.timestamp }
                    else
                        profile.metadata[activeContact] = nil
                    end
                    save_chat_data(myNick, activeContact, currentHistory)
                    save_all_data()
                    needSortContacts = true
                end
            end
            
            imgui.Dummy(imgui.ImVec2(0, 4 * scale))
            
            if UI.scrollToBottom then
                UI.scrollTicks = 2
                UI.scrollToBottom = false
            end
            
            if UI.scrollTicks and UI.scrollTicks > 0 then
                imgui.SetScrollY(imgui.GetScrollMaxY() + 999999.0)
                UI.scrollTicks = UI.scrollTicks - 1
            end
            
            imgui.EndChild()
        end
        if activeContact == "banking" or activeContact == "system" then
            local bText = u8"Это системный чат. Ответить на эти сообщения нельзя."
            local text_h = imgui.GetTextLineHeight()
            local offset_y = ((40 * scale) - text_h) / 2
            imgui.SetCursorPosY(imgui.GetCursorPosY() + offset_y)
            imgui.TextDisabled(bText)
        else
            if not UI.showCallHistory then
                imgui.Spacing()
                local currentPaddingY = imgui.GetStyle().FramePadding.y
                imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(10.0 * scale, currentPaddingY)) 
                imgui.PushItemWidth(-80 * scale) 
                if imgui.InputTextWithHint("##MessageInput", u8"Напишите сообщение...", UI.inputMessage, 2048, imgui.InputTextFlags.EnterReturnsTrue) then
                    sendMessage(activeContact)
                end
                if UI.requestFocus then
                    imgui.SetKeyboardFocusHere(-1)
                    UI.requestFocus = false
                end
                imgui.PopItemWidth()
                imgui.PopStyleVar(1) 
                imgui.SameLine()
                if imgui.Button(u8"Отправить", imgui.ImVec2(0, 0)) then
                    sendMessage(activeContact)
                end
            end
        end
    else
        local emptyText = u8"Выберите контакт для начала переписки."
        local tSize = imgui.CalcTextSize(emptyText)
        local avail = imgui.GetContentRegionAvail()
        local cPos = imgui.GetCursorPos()
        imgui.SetCursorPos(imgui.ImVec2(cPos.x + (avail.x - tSize.x) / 2, cPos.y + (avail.y - tSize.y) / 2))
        imgui.Text(emptyText)
    end
end

local function getContactInitials(num, rawName)
    if num == "banking" then return "B"
    elseif num == "system" then return "!" end
    if rawName and rawName ~= "" then
        local uName = u8(rawName)
        local firstChar = uName:match("^([%z\1-\127\194-\244][\128-\191]*)")
        if firstChar then return firstChar end
    end
    return "#"
end

local function getAvatarColor(str, alpha)
    alpha = alpha or 1.0
    local h = 0
    local s = tostring(str or "")
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 6 end
    local palette = {
        imgui.ImVec4(0.28, 0.52, 0.88, alpha),
        imgui.ImVec4(0.22, 0.68, 0.50, alpha),
        imgui.ImVec4(0.80, 0.38, 0.55, alpha),
        imgui.ImVec4(0.88, 0.54, 0.25, alpha),
        imgui.ImVec4(0.55, 0.42, 0.85, alpha),
        imgui.ImVec4(0.24, 0.66, 0.78, alpha)
    }
    return palette[h + 1]
end

local function DrawSmoothRoundedRect(dl, p_min, p_max, colU32, r)
    local x1, y1 = p_min.x, p_min.y
    local x2, y2 = p_max.x, p_max.y
    r = math.min(r, (x2 - x1) / 2, (y2 - y1) / 2)
    if r <= 0 then
        dl:AddRectFilled(p_min, p_max, colU32, 0.0)
        return
    end
    dl:AddCircleFilled(imgui.ImVec2(x1 + r, y1 + r), r, colU32, 48)
    dl:AddCircleFilled(imgui.ImVec2(x2 - r, y1 + r), r, colU32, 48)
    dl:AddCircleFilled(imgui.ImVec2(x1 + r, y2 - r), r, colU32, 48)
    dl:AddCircleFilled(imgui.ImVec2(x2 - r, y2 - r), r, colU32, 48)
    dl:AddRectFilled(imgui.ImVec2(x1 + r, y1), imgui.ImVec2(x2 - r, y2), colU32, 0.0)
    dl:AddRectFilled(imgui.ImVec2(x1, y1 + r), imgui.ImVec2(x1 + r, y2 - r), colU32, 0.0)
    dl:AddRectFilled(imgui.ImVec2(x2 - r, y1 + r), imgui.ImVec2(x2, y2 - r), colU32, 0.0)
end

local function DrawSmoothRoundedTop(dl, p_min, p_max, colU32, r)
    local x1, y1 = p_min.x, p_min.y
    local x2, y2 = p_max.x, p_max.y
    r = math.min(r, (x2 - x1) / 2, y2 - y1)
    dl:AddCircleFilled(imgui.ImVec2(x1 + r, y1 + r), r, colU32, 48)
    dl:AddCircleFilled(imgui.ImVec2(x2 - r, y1 + r), r, colU32, 48)
    dl:AddRectFilled(imgui.ImVec2(x1 + r, y1), imgui.ImVec2(x2 - r, y1 + r), colU32, 0.0)
    dl:AddRectFilled(imgui.ImVec2(x1, y1 + r), imgui.ImVec2(x2, y2), colU32, 0.0)
end

local function GetIosPalette()
    if globalSettings.iosTheme ~= 1 and globalSettings.iosTheme ~= 2 then
        globalSettings.iosTheme = 1
    end
    if globalSettings.iosTheme == 1 then
        return {
            isLight = true,
            bgMain = imgui.ImVec4(0.949, 0.949, 0.969, 1.0),
            bgChat = imgui.ImVec4(1.000, 1.000, 1.000, 1.0),
            headerBg = imgui.ImVec4(0.965, 0.965, 0.980, 1.0),
            cardBg = imgui.ImVec4(1.000, 1.000, 1.000, 1.0),
            cardHover = imgui.ImVec4(0.910, 0.915, 0.940, 1.0),
            popupBg = imgui.ImVec4(0.980, 0.980, 0.995, 0.98),
            glassBtn = imgui.ImVec4(0.890, 0.895, 0.925, 1.0),
            glassBtnHover = imgui.ImVec4(0.825, 0.835, 0.875, 1.0),
            glassBorder = imgui.ImVec4(0.0, 0.0, 0.0, 0.08),
            textPrimary = imgui.ImVec4(0.06, 0.06, 0.08, 1.0),
            textSecondary = imgui.ImVec4(0.50, 0.50, 0.55, 1.0),
            bubbleMe = imgui.ImVec4(0.000, 0.478, 1.000, 1.0),
            bubbleMeText = imgui.ImVec4(1.000, 1.000, 1.000, 1.0),
            bubbleMeTime = imgui.ImVec4(0.85, 0.92, 1.0, 0.85),
            bubbleThem = imgui.ImVec4(0.914, 0.914, 0.929, 1.0),
            bubbleThemText = imgui.ImVec4(0.06, 0.06, 0.08, 1.0),
            bubbleThemTime = imgui.ImVec4(0.45, 0.45, 0.50, 0.85),
            inputBg = imgui.ImVec4(0.910, 0.910, 0.930, 1.0),
            separator = imgui.ImVec4(0.0, 0.0, 0.0, 0.10),
            accent = imgui.ImVec4(0.000, 0.478, 1.000, 1.0),
            homeBar = imgui.ImVec4(0.15, 0.15, 0.18, 0.45),
            frameOuter = imgui.ImVec4(0.76, 0.78, 0.82, 1.0),
            frameBezel = imgui.ImVec4(0.08, 0.08, 0.10, 1.0)
        }
    else
        return {
            isLight = false,
            bgMain = imgui.ImVec4(0.000, 0.000, 0.000, 1.0),
            bgChat = imgui.ImVec4(0.000, 0.000, 0.000, 1.0),
            headerBg = imgui.ImVec4(0.075, 0.075, 0.085, 1.0),
            cardBg = imgui.ImVec4(0.110, 0.110, 0.120, 1.0),
            cardHover = imgui.ImVec4(0.175, 0.175, 0.190, 1.0),
            popupBg = imgui.ImVec4(0.140, 0.140, 0.155, 0.98),
            glassBtn = imgui.ImVec4(0.175, 0.175, 0.190, 1.0),
            glassBtnHover = imgui.ImVec4(0.245, 0.245, 0.265, 1.0),
            glassBorder = imgui.ImVec4(1.0, 1.0, 1.0, 0.12),
            textPrimary = imgui.ImVec4(1.000, 1.000, 1.000, 1.0),
            textSecondary = imgui.ImVec4(0.56, 0.56, 0.59, 1.0),
            bubbleMe = imgui.ImVec4(0.039, 0.518, 1.000, 1.0),
            bubbleMeText = imgui.ImVec4(1.000, 1.000, 1.000, 1.0),
            bubbleMeTime = imgui.ImVec4(0.85, 0.92, 1.0, 0.80),
            bubbleThem = imgui.ImVec4(0.150, 0.150, 0.165, 1.0),
            bubbleThemText = imgui.ImVec4(1.000, 1.000, 1.000, 1.0),
            bubbleThemTime = imgui.ImVec4(0.65, 0.65, 0.70, 0.80),
            inputBg = imgui.ImVec4(0.115, 0.115, 0.125, 1.0),
            separator = imgui.ImVec4(1.0, 1.0, 1.0, 0.12),
            accent = imgui.ImVec4(0.039, 0.518, 1.000, 1.0),
            homeBar = imgui.ImVec4(1.0, 1.0, 1.0, 0.45),
            frameOuter = imgui.ImVec4(0.32, 0.34, 0.37, 1.0),
            frameBezel = imgui.ImVec4(0.04, 0.04, 0.05, 1.0)
        }
    end
end

local function triggerAutoCleanMacro()
    UI.windowState[0] = false
    Macro.autoCleaning = true
    Macro.cleanStep = 1
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
            Macro.autoCleaning = false
            UI.windowState[0] = true
            return
        end
        local appFound = false
        for i = 1, 50 do
            wait(50)
            for td = 2304, 0, -1 do
                if sampTextdrawIsExists(td) then
                    local posX, posY = sampTextdrawGetPos(td)
                    if posX >= 529.0 and posX <= 533.0 and posY >= 407.0 and posY <= 411.0 then
                        sampSendClickTextdraw(td)
                        appFound = true
                        break
                    end
                end
            end
            if appFound then break end
        end
        if not appFound then
            showSystemNotification(u8"Ошибка: иконка сообщений не появилась.", 2)
            Macro.autoCleaning = false
            UI.windowState[0] = true
            return
        end
        Macro.cleanStep = 2
        wait(10000)
        if Macro.autoCleaning then
            Macro.autoCleaning = false
            Macro.cleanStep = 0
            showSystemNotification(u8"Ошибка: Таймаут. Сервер не ответил на диалоги.", 2)
            sampSendClickTextdraw(65535)
            sampSendChat("/untd 2")
            UI.windowState[0] = true
        end
    end)
end

local function triggerAutoGeoMacro(targetContact)
    Macro.targetGeoNumber = tostring(targetContact):match("[%d%-]+")
    if Macro.targetGeoNumber then
        UI.windowState[0] = false
        Macro.autoGeo = true
        Macro.geoStep = 1
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
                Macro.autoGeo = false
                UI.windowState[0] = true
                return
            end
            local appFound = false
            for i = 1, 50 do
                wait(50)
                for td = 2304, 0, -1 do
                    if sampTextdrawIsExists(td) then
                        local posX, posY = sampTextdrawGetPos(td)
                        if posX >= 529.0 and posX <= 533.0 and posY >= 407.0 and posY <= 411.0 then
                            sampSendClickTextdraw(td)
                            appFound = true
                            break
                        end
                    end
                end
                if appFound then break end
            end
            if not appFound then
                showSystemNotification(u8"Ошибка: иконка сообщений не появилась.", 2)
                Macro.autoGeo = false
                UI.windowState[0] = true
                return
            end
            Macro.geoStep = 2
            wait(10000)
            if Macro.autoGeo then
                Macro.autoGeo = false
                Macro.geoStep = 0
                showSystemNotification(u8"Ошибка: Таймаут. Сервер не ответил на диалоги.", 2)
                sampSendClickTextdraw(65535)
                sampSendChat("/untd 2")
                UI.windowState[0] = true
            end
        end)
    else
        showSystemNotification(u8"Ошибка: неверный номер телефона.", 2)
    end
end

local function DrawIosVectorBtn(id, iconType, radius, bgCol, hoverCol, iconCol, borderCol, scale)
    local pos = imgui.GetCursorScreenPos()
    local d = radius * 2
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(d, d))
    local hovered = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    local center = imgui.ImVec2(pos.x + radius, pos.y + radius)
    local fill = hovered and hoverCol or bgCol

    dl:AddCircleFilled(center, radius, imgui.GetColorU32Vec4(fill), 36)
    if borderCol then
        dl:AddCircle(center, radius, imgui.GetColorU32Vec4(borderCol), 36, 1.0)
    end

    local fg = imgui.GetColorU32Vec4(iconCol)
    local r = radius * 0.44
    local th = 2.0 * scale

    if iconType == "back" then
        dl:AddLine(imgui.ImVec2(center.x + r * 0.35, center.y - r * 0.85), imgui.ImVec2(center.x - r * 0.45, center.y), fg, th)
        dl:AddLine(imgui.ImVec2(center.x - r * 0.45, center.y), imgui.ImVec2(center.x + r * 0.35, center.y + r * 0.85), fg, th)
    elseif iconType == "close" then
        dl:AddLine(imgui.ImVec2(center.x - r * 0.65, center.y - r * 0.65), imgui.ImVec2(center.x + r * 0.65, center.y + r * 0.65), fg, th)
        dl:AddLine(imgui.ImVec2(center.x + r * 0.65, center.y - r * 0.65), imgui.ImVec2(center.x - r * 0.65, center.y + r * 0.65), fg, th)
    elseif iconType == "plus" then
        dl:AddLine(imgui.ImVec2(center.x - r * 0.75, center.y), imgui.ImVec2(center.x + r * 0.75, center.y), fg, th)
        dl:AddLine(imgui.ImVec2(center.x, center.y - r * 0.75), imgui.ImVec2(center.x, center.y + r * 0.75), fg, th)
    elseif iconType == "send" then
        dl:AddLine(imgui.ImVec2(center.x, center.y + r * 0.80), imgui.ImVec2(center.x, center.y - r * 0.80), fg, th * 1.1)
        dl:AddLine(imgui.ImVec2(center.x - r * 0.65, center.y - r * 0.15), imgui.ImVec2(center.x, center.y - r * 0.80), fg, th * 1.1)
        dl:AddLine(imgui.ImVec2(center.x + r * 0.65, center.y - r * 0.15), imgui.ImVec2(center.x, center.y - r * 0.80), fg, th * 1.1)
    elseif iconType == "settings" then
        for i = -1, 1 do
            local y = center.y + i * (r * 0.65)
            dl:AddLine(imgui.ImVec2(center.x - r * 0.80, y), imgui.ImVec2(center.x + r * 0.80, y), fg, 1.6 * scale)
            local kx = center.x + (i == 0 and r * 0.35 or -r * 0.35)
            dl:AddCircleFilled(imgui.ImVec2(kx, y), 2.4 * scale, fg, 12)
        end
    elseif iconType == "clean" then
        dl:AddLine(imgui.ImVec2(center.x - r * 0.75, center.y - r * 0.55), imgui.ImVec2(center.x + r * 0.75, center.y - r * 0.55), fg, 1.8 * scale)
        dl:AddLine(imgui.ImVec2(center.x - r * 0.30, center.y - r * 0.80), imgui.ImVec2(center.x + r * 0.30, center.y - r * 0.80), fg, 1.8 * scale)
        dl:AddRect(imgui.ImVec2(center.x - r * 0.55, center.y - r * 0.50), imgui.ImVec2(center.x + r * 0.55, center.y + r * 0.80), fg, 2.0 * scale)
    elseif iconType == "call" then
        dl:AddCircleFilled(imgui.ImVec2(center.x - r * 0.45, center.y - r * 0.45), 2.8 * scale, fg, 12)
        dl:AddCircleFilled(imgui.ImVec2(center.x + r * 0.45, center.y + r * 0.45), 2.8 * scale, fg, 12)
        dl:AddLine(imgui.ImVec2(center.x - r * 0.55, center.y - r * 0.35), imgui.ImVec2(center.x - r * 0.10, center.y + r * 0.25), fg, 2.4 * scale)
        dl:AddLine(imgui.ImVec2(center.x - r * 0.10, center.y + r * 0.25), imgui.ImVec2(center.x + r * 0.35, center.y + r * 0.55), fg, 2.4 * scale)
    elseif iconType == "msg" then
        dl:AddRectFilled(imgui.ImVec2(center.x - r * 0.85, center.y - r * 0.65), imgui.ImVec2(center.x + r * 0.85, center.y + r * 0.45), fg, 4.5 * scale)
        dl:AddTriangleFilled(
            imgui.ImVec2(center.x - r * 0.35, center.y + r * 0.40),
            imgui.ImVec2(center.x - r * 0.65, center.y + r * 0.85),
            imgui.ImVec2(center.x + r * 0.05, center.y + r * 0.40),
            fg
        )
    elseif iconType == "geo" then
        dl:AddTriangleFilled(
            imgui.ImVec2(center.x + r * 0.75, center.y - r * 0.75),
            imgui.ImVec2(center.x - r * 0.80, center.y - r * 0.05),
            imgui.ImVec2(center.x + r * 0.05, center.y + r * 0.80),
            fg
        )
    elseif iconType == "bell_on" or iconType == "bell_off" then
        dl:AddCircleFilled(imgui.ImVec2(center.x, center.y - r * 0.18), r * 0.55, fg, 18)
        dl:AddRectFilled(imgui.ImVec2(center.x - r * 0.55, center.y - r * 0.18), imgui.ImVec2(center.x + r * 0.55, center.y + r * 0.38), fg, 1.0 * scale)
        dl:AddRectFilled(imgui.ImVec2(center.x - r * 0.75, center.y + r * 0.25), imgui.ImVec2(center.x + r * 0.75, center.y + r * 0.45), fg, 1.5 * scale)
        dl:AddCircleFilled(imgui.ImVec2(center.x, center.y + r * 0.68), 2.2 * scale, fg, 10)
        if iconType == "bell_off" then
            local strikeCol = imgui.GetColorU32Vec4(imgui.ImVec4(0.95, 0.30, 0.30, 1.0))
            dl:AddLine(imgui.ImVec2(center.x - r * 0.85, center.y - r * 0.85), imgui.ImVec2(center.x + r * 0.85, center.y + r * 0.85), strikeCol, 2.2 * scale)
        end
    end

    if hovered then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
    return clicked, hovered
end

local function DrawIosCardRow(id, leftTitle, leftSub, rightText, titleCol, width, height, pal, scale)
    local pos = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton(id, imgui.ImVec2(width, height))
    local hovered = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    local bg = hovered and pal.cardHover or pal.cardBg
    DrawSmoothRoundedRect(dl, pos, imgui.ImVec2(pos.x + width, pos.y + height), imgui.GetColorU32Vec4(bg), 10.0 * scale)

    local padX = 12 * scale
    local tCol = imgui.GetColorU32Vec4(titleCol or pal.textPrimary)
    local sCol = imgui.GetColorU32Vec4(pal.textSecondary)

    if leftSub and leftSub ~= "" then
        dl:AddText(imgui.ImVec2(pos.x + padX, pos.y + 6 * scale), tCol, leftTitle)
        dl:AddText(imgui.ImVec2(pos.x + padX, pos.y + height - imgui.GetTextLineHeight() - 5 * scale), sCol, leftSub)
    else
        local ty = pos.y + (height - imgui.GetTextLineHeight()) / 2
        dl:AddText(imgui.ImVec2(pos.x + padX, ty), tCol, leftTitle)
    end

    if rightText and rightText ~= "" then
        local rSz = imgui.CalcTextSize(rightText)
        local ry = pos.y + (height - rSz.y) / 2
        dl:AddText(imgui.ImVec2(pos.x + width - rSz.x - padX, ry), sCol, rightText)
    end

    if hovered then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
    return clicked
end

local function DrawIosPhoneContent(scale, profile)
    local dl = imgui.GetWindowDrawList()
    local winPos = imgui.GetWindowPos()
    local winSize = imgui.GetWindowSize()
    local pal = GetIosPalette()

    -- Сброс висящего фокуса, если поле ввода сейчас не отрисовывается
    local isSystemChat = (activeContact == "banking" or activeContact == "system")
    if not activeContact or isSystemChat or UI.showContactProfile or UI.showCallHistory then
        UI.requestFocus = false
    end

    -- 1. Идеально гладкий корпус и экран телефона (48 сегментов на каждый угол)
    local outerMin = winPos
    local outerMax = imgui.ImVec2(winPos.x + winSize.x, winPos.y + winSize.y)
    local bezelMin = imgui.ImVec2(winPos.x + 2.5 * scale, winPos.y + 2.5 * scale)
    local bezelMax = imgui.ImVec2(winPos.x + winSize.x - 2.5 * scale, winPos.y + winSize.y - 2.5 * scale)
    local screenMin = imgui.ImVec2(winPos.x + 6.0 * scale, winPos.y + 6.0 * scale)
    local screenMax = imgui.ImVec2(winPos.x + winSize.x - 6.0 * scale, winPos.y + winSize.y - 6.0 * scale)

    DrawSmoothRoundedRect(dl, outerMin, outerMax, imgui.GetColorU32Vec4(pal.frameOuter), 34.0 * scale)
    DrawSmoothRoundedRect(dl, bezelMin, bezelMax, imgui.GetColorU32Vec4(pal.frameBezel), 31.5 * scale)

    local baseScreenBg = (activeContact and not UI.showContactProfile and not UI.showCallHistory) and pal.bgChat or pal.bgMain
    DrawSmoothRoundedRect(dl, screenMin, screenMax, imgui.GetColorU32Vec4(baseScreenBg), 28.0 * scale)

    -- 2. Бесшовная верхняя заливка в карточке контакта
    if activeContact and UI.showContactProfile and not UI.showCallHistory then
        local rawAv = getAvatarColor(activeContact, 1.0)
        local mix = pal.isLight and 0.35 or 0.42
        local topSolid = imgui.ImVec4(
            pal.bgMain.x * (1 - mix) + rawAv.x * mix,
            pal.bgMain.y * (1 - mix) + rawAv.y * mix,
            pal.bgMain.z * (1 - mix) + rawAv.z * mix,
            1.0
        )
        local topSolidU32 = imgui.GetColorU32Vec4(topSolid)
        local bgMainU32 = imgui.GetColorU32Vec4(pal.bgMain)
        local capBottomY = screenMin.y + 32 * scale
        DrawSmoothRoundedTop(dl, screenMin, imgui.ImVec2(screenMax.x, capBottomY), topSolidU32, 28.0 * scale)
        dl:AddRectFilledMultiColor(
            imgui.ImVec2(screenMin.x, capBottomY),
            imgui.ImVec2(screenMax.x, screenMin.y + 225 * scale),
            topSolidU32, topSolidU32, bgMainU32, bgMainU32
        )
    elseif activeContact and not UI.showContactProfile and not UI.showCallHistory then
        local headerBottomY = winPos.y + 94 * scale
        local headerU32 = imgui.GetColorU32Vec4(pal.headerBg)
        DrawSmoothRoundedTop(dl, screenMin, imgui.ImVec2(screenMax.x, headerBottomY), headerU32, 28.0 * scale)
        dl:AddLine(imgui.ImVec2(screenMin.x, headerBottomY), imgui.ImVec2(screenMax.x, headerBottomY), imgui.GetColorU32Vec4(pal.separator), 1.0)
    end

    -- 3. Dynamic Island (Фронталка) — закрытие по клику
    local islandW, islandH = 94 * scale, 22 * scale
    local islandX = winPos.x + (winSize.x - islandW) / 2
    local islandY = screenMin.y + 6 * scale
    DrawSmoothRoundedRect(dl, imgui.ImVec2(islandX, islandY), imgui.ImVec2(islandX + islandW, islandY + islandH), imgui.GetColorU32Vec4(imgui.ImVec4(0.03, 0.03, 0.04, 1.0)), 11.0 * scale)
    dl:AddCircleFilled(imgui.ImVec2(islandX + islandW - 14 * scale, islandY + islandH / 2), 4.2 * scale, imgui.GetColorU32Vec4(imgui.ImVec4(0.08, 0.13, 0.25, 1.0)), 16)
    dl:AddCircleFilled(imgui.ImVec2(islandX + islandW - 15 * scale, islandY + islandH / 2 - 1 * scale), 1.3 * scale, imgui.GetColorU32Vec4(imgui.ImVec4(0.35, 0.55, 0.90, 0.7)), 12)

    imgui.SetCursorScreenPos(imgui.ImVec2(islandX, islandY))
    if imgui.InvisibleButton("##ios_island_close", imgui.ImVec2(islandW, islandH)) then
        SaveCurrentDraft()
        UI.windowState[0] = false
    end
    if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end

    -- Часы и иконки статус-бара
    local statusColor = imgui.GetColorU32Vec4(pal.textPrimary)
    local clockStr = os.date("%H:%M")
    dl:AddText(imgui.ImVec2(screenMin.x + 18 * scale, islandY + (islandH - imgui.GetTextLineHeight()) / 2), statusColor, clockStr)

    local batX = screenMax.x - 36 * scale
    local batY = islandY + 5.5 * scale
    dl:AddRect(imgui.ImVec2(batX, batY), imgui.ImVec2(batX + 19 * scale, batY + 10.5 * scale), statusColor, 2.5 * scale)
    dl:AddRectFilled(imgui.ImVec2(batX + 2 * scale, batY + 2 * scale), imgui.ImVec2(batX + 15.5 * scale, batY + 8.5 * scale), statusColor, 1.2 * scale)
    for b = 1, 4 do
        local bh = (2 + b * 2) * scale
        local bx = batX - (22 - b * 4.2) * scale
        local by = batY + 10.5 * scale - bh
        dl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + 2.5 * scale, batY + 10.5 * scale), statusColor, 1.0 * scale)
    end

    -- 4. Нижняя полоска закрытия (Home Indicator)
    local homeW, homeH = 115 * scale, 4.5 * scale
    local homeX = winPos.x + (winSize.x - homeW) / 2
    local homeY = screenMax.y - 10 * scale
    imgui.SetCursorScreenPos(imgui.ImVec2(homeX - 10 * scale, homeY - 6 * scale))
    local homeClicked = imgui.InvisibleButton("##ios_home_bar_close", imgui.ImVec2(homeW + 20 * scale, 15 * scale))
    local homeHovered = imgui.IsItemHovered()
    local homeCol = homeHovered and pal.accent or pal.homeBar
    dl:AddRectFilled(imgui.ImVec2(homeX, homeY), imgui.ImVec2(homeX + homeW, homeY + homeH), imgui.GetColorU32Vec4(homeCol), 2.5 * scale)
    if homeHovered then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
    if homeClicked then
        SaveCurrentDraft()
        UI.windowState[0] = false
        return
    end

    -- Стилизация всех элементов, скроллбара и всплывающих меню под тему iOS
    imgui.PushStyleColor(imgui.Col.Text, pal.textPrimary)
    imgui.PushStyleColor(imgui.Col.PopupBg, pal.popupBg)
    imgui.PushStyleColor(imgui.Col.Border, pal.separator)
    imgui.PushStyleColor(imgui.Col.FrameBg, pal.inputBg)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, pal.cardHover)
    imgui.PushStyleColor(imgui.Col.FrameBgActive, pal.inputBg)
    imgui.PushStyleColor(imgui.Col.Header, pal.cardHover)
    imgui.PushStyleColor(imgui.Col.HeaderHovered, pal.cardHover)
    imgui.PushStyleColor(imgui.Col.HeaderActive, pal.cardHover)
    imgui.PushStyleColor(imgui.Col.ScrollbarBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.ScrollbarSize, 3.0 * scale)
    imgui.PushStyleVarFloat(imgui.StyleVar.PopupBorderSize, 1.0)

    local function popIosStyles()
        imgui.PopStyleVar(2)
        imgui.PopStyleColor(10)
    end

    -- =========================================================================
    -- ЭКРАН 1: СПИСОК СООБЩЕНИЙ И ЗАКРЕПЛЁННЫЕ (iOS 26)
    -- =========================================================================
    if not activeContact then
        imgui.SetCursorPos(imgui.ImVec2(16 * scale, 38 * scale))
        local cClick, cHov = DrawIosVectorBtn("##ios_clean", "clean", 15 * scale, pal.glassBtn, pal.glassBtnHover, pal.textPrimary, pal.glassBorder, scale)
        if cHov then imgui.SetTooltip(u8"Сброс лимита SMS") end
        if cClick then triggerAutoCleanMacro() end

        imgui.SetCursorPos(imgui.ImVec2(52 * scale, 38 * scale))
        local sClick, sHov = DrawIosVectorBtn("##ios_settings", "settings", 15 * scale, pal.glassBtn, pal.glassBtnHover, pal.textPrimary, pal.glassBorder, scale)
        if sHov then imgui.SetTooltip(u8"Настройки") end
        if sClick then imgui.OpenPopup("SettingsModal") end

        local titleStr = u8"Сообщения"
        local titleW = imgui.CalcTextSize(titleStr).x
        imgui.SetCursorPos(imgui.ImVec2((winSize.x - titleW) / 2, 43 * scale))
        imgui.Text(titleStr)

        imgui.SetCursorPos(imgui.ImVec2(winSize.x - 46 * scale, 38 * scale))
        local addClick, addHov = DrawIosVectorBtn("##ios_add_contact", "plus", 15 * scale, pal.accent, pal.accent, imgui.ImVec4(1, 1, 1, 1), nil, scale)
        if addHov then imgui.SetTooltip(u8"Новый контакт") end
        if addClick then
            UI.inputContactName[0] = 0
            UI.inputContactNumber[0] = 0
            UI.inputContactNick[0] = 0
            UI.requestContactModal = true
        end

        if needSortContacts then
            cachedSortedContacts = {}
            local uniqueNumbers = {}
            for num, _ in pairs(profile.contacts) do uniqueNumbers[num] = true end
            if profile.metadata then
                for num, _ in pairs(profile.metadata) do uniqueNumbers[num] = true end
            end
            if profile.calls then
                for num, _ in pairs(profile.calls) do uniqueNumbers[num] = true end
            end
            if profile.metadata and profile.metadata["banking"] then uniqueNumbers["banking"] = true end
            if profile.metadata and profile.metadata["system"] then uniqueNumbers["system"] = true end
            for num, _ in pairs(uniqueNumbers) do
                local name = profile.contacts[num] or ""
                local hasName = (name ~= "")
                local meta = profile.metadata and profile.metadata[num]
                local hasHistory = (meta ~= nil)
                local calls = profile.calls and profile.calls[num]
                local hasCalls = (calls and #calls > 0)
                local isSystem = (num == "banking" or num == "system")
                if hasName or hasHistory or hasCalls or isSystem then
                    local last_ts = 0
                    if hasHistory then last_ts = meta.timestamp or 0 end
                    if hasCalls then
                        local last_call_ts = calls[#calls].timestamp or 0
                        if last_call_ts > last_ts then last_ts = last_call_ts end
                    end
                    table.insert(cachedSortedContacts, {num = num, name = name, last_ts = last_ts})
                end
            end
            table.sort(cachedSortedContacts, function(a, b)
                local a_pin = profile.pinned and profile.pinned[a.num] or false
                local b_pin = profile.pinned and profile.pinned[b.num] or false
                if a_pin ~= b_pin then return a_pin end
                local mode = globalSettings.contactSortMode or 1
                if mode == 2 then
                    local a_saved = (a.name ~= "")
                    local b_saved = (b.name ~= "")
                    if a_saved ~= b_saved then return a_saved end
                elseif mode == 3 then
                    local a_nick = profile.nicknames and profile.nicknames[a.num]
                    local b_nick = profile.nicknames and profile.nicknames[b.num]
                    local a_online = a_nick and onlinePlayers[a_nick] or false
                    local b_online = b_nick and onlinePlayers[b_nick] or false
                    if a_online ~= b_online then return a_online and not b_online end
                end
                return a.last_ts > b.last_ts
            end)
            needSortContacts = false
        end

        imgui.SetCursorPos(imgui.ImVec2(0, 76 * scale))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0,0))
        -- Опускаем высоту списка, чтобы контакты скроллились ровно под полем поиска
        imgui.BeginChild("IosContactsScroll", imgui.ImVec2(winSize.x, winSize.y - 100 * scale), false)
        imgui.PopStyleVar()

        local sContactText = cp1251_lower(u8:decode(ffi.string(UI.inputSearchContact)))
        local cdl = imgui.GetWindowDrawList()
        local listAvailW = winSize.x

        -- Полное контекстное меню быстрых действий по ПКМ

        -- Полное контекстное меню быстрых действий по ПКМ
        local function drawContactContextMenu(num, name)
            if imgui.BeginPopupContextItem("IosContactPopup_" .. num) then
                if num ~= "system" and num ~= "banking" then
                    if imgui.Selectable(u8"Карточка контакта") then
                        activeContact = num
                        activeChatId = num
                        activeChatHistory = load_chat_history(myNick, num)
                        UI.showContactProfile = true
                    end
                    imgui.Separator()
                end
                local isPinned = profile.pinned and profile.pinned[num]
                if imgui.Selectable(isPinned and u8"Открепить диалог" or u8"Закрепить диалог") then
                    if not profile.pinned then profile.pinned = {} end
                    if isPinned then profile.pinned[num] = nil else profile.pinned[num] = true end
                    save_all_data()
                    needSortContacts = true
                end
                if profile.tagger and profile.tagger[num] then
                    if imgui.Selectable(u8"Открыть Nova (Social)") then
                        local url = "https://nova.gambit-rp.com/" .. profile.tagger[num]
                        shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
                    end
                end
                if num == "system" then
                    imgui.Separator()
                    if imgui.Selectable(u8"Очистить историю") then
                        save_chat_data(myNick, num, {})
                        profile.metadata[num] = nil
                        for _, p in pairs(phoneData) do
                            if p.unread then p.unread[num] = nil end
                            if p.muted then p.muted[num] = nil end
                            if p.drafts then p.drafts[num] = nil end
                        end
                        save_all_data()
                        needSortContacts = true
                    end
                elseif num == "banking" then
                    local muteText = profile.muted and profile.muted[num] and u8"Включить уведомления" or u8"Отключить уведомления"
                    if imgui.Selectable(muteText) then
                        if not profile.muted then profile.muted = {} end
                        profile.muted[num] = not profile.muted[num]
                        save_all_data()
                    end
                    imgui.Separator()
                    if imgui.Selectable(u8"Очистить историю") then
                        save_chat_data(myNick, num, {})
                        profile.metadata[num] = nil
                        profile.unread[num] = nil
                        save_all_data()
                        needSortContacts = true
                    end
                else
                    if imgui.Selectable(u8"Изменить") then
                        ffi.copy(UI.inputContactNumber, num)
                        ffi.copy(UI.inputContactName, u8(name))
                        local nick = (profile.nicknames and profile.nicknames[num]) and profile.nicknames[num] or ""
                        ffi.copy(UI.inputContactNick, nick)
                        UI.requestContactModal = true
                    end
                    if imgui.Selectable(u8"Позвонить") then
                        sampSendChat("/call " .. num)
                        UI.windowState[0] = false
                    end
                    local muteText = profile.muted and profile.muted[num] and u8"Включить уведомления" or u8"Отключить уведомления"
                    if imgui.Selectable(muteText) then
                        if not profile.muted then profile.muted = {} end
                        profile.muted[num] = not profile.muted[num]
                        save_all_data()
                    end
                    local isBlocked = profile.blocked and profile.blocked[num]
                    if imgui.Selectable(isBlocked and u8"Разблокировать" or u8"Заблокировать") then
                        Macro.autoBlock = true
                        sampSendChat("/blocknum " .. num)
                    end
                    imgui.Separator()
                    if imgui.Selectable(u8"Очистить историю") then
                        save_chat_data(myNick, num, {})
                        profile.metadata[num] = nil
                        profile.calls[num] = nil
                        profile.unread[num] = nil
                        save_all_data()
                        needSortContacts = true
                    end
                    if imgui.Selectable(u8"Удалить контакт") then
                        UI.contactToDelete = num
                        UI.requestDeletePopup = true
                    end
                end
                imgui.EndPopup()
            end
        end

        local function openChatWithContact(num)
            SaveCurrentDraft()
            activeContact = num
            activeChatId = num
            activeChatHistory = load_chat_history(myNick, num)
            UI.showContactProfile = false
            UI.showCallHistory = false
            UI.viewingCallIndex = 0
            LoadDraft(num)
            UI.showMessageSearch = false
            UI.inputSearchMessage[0] = 0
            if profile.unread and profile.unread[num] then
                profile.unread[num] = nil
                save_profile_data(myNick)
            end
            UI.scrollToBottom = true
            UI.requestFocus = true
        end

        local pinnedContacts = {}
        local regularContacts = {}
        for _, c in ipairs(cachedSortedContacts) do
            local num = c.num
            local name = c.name
            local skip = false
            if sContactText ~= "" then
                local lowerName = cp1251_lower(name)
                local lowerNum = cp1251_lower(num)
                local localDisplay = (num == "banking" and cp1251_lower(u8:decode(u8"Банк")))
                    or (num == "system" and cp1251_lower(u8:decode(u8"Уведомления")))
                    or (lowerName == "" and ("#" .. lowerNum) or (lowerName .. " (" .. lowerNum .. ")"))
                if not localDisplay:find(sContactText, 1, true) then skip = true end
            end

            if not skip then
                if profile.pinned and profile.pinned[num] and sContactText == "" then
                    table.insert(pinnedContacts, c)
                else
                    table.insert(regularContacts, c)
                end
            end
        end

        local screenPad = 6 * scale
        local listInnerW = winSize.x - screenPad * 2

        if #pinnedContacts > 0 then
            local cols = 3
            local cellW = listInnerW / cols
            local pinR = 25 * scale
            local rowStartY = imgui.GetCursorPosY() + 2 * scale
            local totalPinned = #pinnedContacts

            for idx, c in ipairs(pinnedContacts) do
                local colIdx = (idx - 1) % cols
                if idx > 1 and colIdx == 0 then
                    rowStartY = rowStartY + 76 * scale
                end
                local rowIndex = math.floor((idx - 1) / cols)
                local itemsInThisRow = math.min(cols, totalPinned - rowIndex * cols)
                local rowOffsetX = (listInnerW - itemsInThisRow * cellW) / 2
                local cellX = screenPad + rowOffsetX + colIdx * cellW

                imgui.SetCursorPos(imgui.ImVec2(cellX, rowStartY))
                local sPos = imgui.GetCursorScreenPos()

                imgui.PushIDStr("ios_pin_" .. c.num)
                local clicked = imgui.InvisibleButton("pin_btn_" .. c.num, imgui.ImVec2(cellW, 72 * scale))
                local hovered = imgui.IsItemHovered()
                drawContactContextMenu(c.num, c.name)
                if clicked then openChatWithContact(c.num) end
                if hovered then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end

                local avCenter = imgui.ImVec2(sPos.x + cellW / 2, sPos.y + pinR + 4 * scale)
                if hovered then
                    cdl:AddCircleFilled(avCenter, pinR + 2.5 * scale, imgui.GetColorU32Vec4(pal.accent), 36)
                end
                
                local drawnAv = false
                if globalVerified[c.num] and globalVerified[c.num].avatar_url and globalVerified[c.num].avatar_url ~= "" then
                    local url = globalVerified[c.num].avatar_url
                    if not imageCache[url] then
                        if globalSettings.autoDownloadMedia then downloadImageToCache(url) else imageCache[url] = { status = 4 } end
                    end
                    if imageCache[url] and imageCache[url].status == 2 then
                        cdl:AddImageRounded(imageCache[url].tex, imgui.ImVec2(avCenter.x - pinR, avCenter.y - pinR), imgui.ImVec2(avCenter.x + pinR, avCenter.y + pinR), imgui.ImVec2(0,0), imgui.ImVec2(1,1), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,1)), pinR)
                        
                        imgui.SetCursorScreenPos(imgui.ImVec2(avCenter.x - pinR, avCenter.y - pinR))
                        if imgui.InvisibleButton("ios_av_pin_" .. c.num, imgui.ImVec2(pinR * 2, pinR * 2)) then
                            UI.viewingImage = url
                        end
                        if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
                        
                        drawnAv = true
                    end
                end
                
                if not drawnAv then
                    cdl:AddCircleFilled(avCenter, pinR, imgui.GetColorU32Vec4(getAvatarColor(c.num, 1.0)), 36)
                    local initStr = getContactInitials(c.num, c.name)
                    local initSz = imgui.CalcTextSize(initStr)
                    cdl:AddText(imgui.ImVec2(avCenter.x - initSz.x / 2, avCenter.y - initSz.y / 2), imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 1)), initStr)
                end

                if profile.nicknames and profile.nicknames[c.num] and onlinePlayers[profile.nicknames[c.num]] then
                    local onCenter = imgui.ImVec2(avCenter.x + pinR * 0.72, avCenter.y + pinR * 0.72)
                    cdl:AddCircleFilled(onCenter, 5.5 * scale, imgui.GetColorU32Vec4(pal.bgMain), 16)
                    cdl:AddCircleFilled(onCenter, 4.2 * scale, imgui.GetColorU32Vec4(imgui.ImVec4(0.20, 0.82, 0.35, 1.0)), 16)
                end

                local is_unread = profile.unread and profile.unread[c.num]
                if is_unread then
                    local uCount = type(is_unread) == "number" and is_unread or 1
                    local bStr = tostring(uCount)
                    local bSz = imgui.CalcTextSize(bStr)
                    local bW = math.max(bSz.x + 8 * scale, 16 * scale)
                    local bH = 16 * scale
                    local bx = avCenter.x + pinR * 0.38
                    local by = avCenter.y - pinR * 0.90
                    cdl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + bW, by + bH), imgui.GetColorU32Vec4(pal.accent), 8 * scale)
                    cdl:AddText(imgui.ImVec2(bx + (bW - bSz.x) / 2, by + (bH - bSz.y) / 2), imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 1)), bStr)
                end

                local shortPinName = (c.num == "banking" and u8"Банк")
                    or (c.num == "system" and u8"Уведомления")
                    or (c.name ~= "" and u8(c.name) or ("#" .. c.num))
                local truncPin = truncateText(shortPinName, cellW - 8 * scale)
                local pNameW = imgui.CalcTextSize(truncPin).x
                cdl:AddText(
                    imgui.ImVec2(sPos.x + (cellW - pNameW) / 2, avCenter.y + pinR + 4 * scale),
                    imgui.GetColorU32Vec4(is_unread and pal.textPrimary or pal.textSecondary),
                    truncPin
                )
                imgui.PopID()
            end

            imgui.SetCursorPosY(rowStartY + 76 * scale)
            imgui.Dummy(imgui.ImVec2(0, 5 * scale))
        end

        for _, c in ipairs(regularContacts) do
            local num = c.num
            local name = c.name

            imgui.PushIDStr("ios_c_" .. num)
            local is_unread = profile.unread and profile.unread[num]
            local is_muted = profile.muted and profile.muted[num]
            local is_pinned = profile.pinned and profile.pinned[num]

            local displayName = ""
            if num == "banking" then displayName = u8"Банк"
            elseif num == "system" then displayName = u8"Уведомления"
            else
                if name == "" then displayName = "#" .. num
                elseif globalSettings.hideContactNumber then displayName = u8(name)
                else displayName = u8(name) .. " (" .. num .. ")" end
            end

            local cursorPos = imgui.GetCursorScreenPos()
            local item_h = 66 * scale
            local p_min = imgui.ImVec2(winPos.x + screenPad, cursorPos.y)
            local p_max = imgui.ImVec2(winPos.x + winSize.x - screenPad, cursorPos.y + item_h)

            imgui.SetCursorPosX(screenPad)
            local is_clicked = imgui.InvisibleButton("ios_cbtn_" .. num, imgui.ImVec2(winSize.x - screenPad * 2, item_h))
            local is_hovered = imgui.IsItemHovered()
            drawContactContextMenu(num, name)
            if is_clicked then openChatWithContact(num) end
            if is_hovered then
                imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                cdl:AddRectFilled(p_min, p_max, imgui.GetColorU32Vec4(pal.cardHover), 12.0 * scale)
            end

            local avRadius = 24 * scale
            local avCenter = imgui.ImVec2(p_min.x + 10 * scale + avRadius, p_min.y + item_h / 2)

            local drawnAv = false
            if globalVerified[num] and globalVerified[num].avatar_url and globalVerified[num].avatar_url ~= "" then
                local url = globalVerified[num].avatar_url
                if not imageCache[url] then
                    if globalSettings.autoDownloadMedia then downloadImageToCache(url) else imageCache[url] = { status = 4 } end
                end
                if imageCache[url] and imageCache[url].status == 2 then
                    cdl:AddImageRounded(imageCache[url].tex, imgui.ImVec2(avCenter.x - avRadius, avCenter.y - avRadius), imgui.ImVec2(avCenter.x + avRadius, avCenter.y + avRadius), imgui.ImVec2(0,0), imgui.ImVec2(1,1), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,1)), avRadius)
                    
                    imgui.SetCursorScreenPos(imgui.ImVec2(avCenter.x - avRadius, avCenter.y - avRadius))
                    if imgui.InvisibleButton("ios_av_reg_" .. num, imgui.ImVec2(avRadius * 2, avRadius * 2)) then
                        UI.viewingImage = url
                    end
                    if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
                    
                    drawnAv = true
                end
            end
            
            if not drawnAv then
                cdl:AddCircleFilled(avCenter, avRadius, imgui.GetColorU32Vec4(getAvatarColor(num, 1.0)), 32)
                local initStr = getContactInitials(num, name)
                local initSize = imgui.CalcTextSize(initStr)
                cdl:AddText(imgui.ImVec2(avCenter.x - initSize.x / 2, avCenter.y - initSize.y / 2), imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 1)), initStr)
            end

            if profile.nicknames and profile.nicknames[num] and onlinePlayers[profile.nicknames[num]] then
                local onCenter = imgui.ImVec2(avCenter.x + avRadius * 0.75, avCenter.y + avRadius * 0.75)
                cdl:AddCircleFilled(onCenter, 6.5 * scale, imgui.GetColorU32Vec4(pal.bgMain), 16)
                cdl:AddCircleFilled(onCenter, 4.5 * scale, imgui.GetColorU32Vec4(imgui.ImVec4(0.20, 0.82, 0.35, 1.0)), 16)
            end

            local textLeftX = p_min.x + 10 * scale + avRadius * 2 + 12 * scale
            local meta = profile.metadata and profile.metadata[num]
            local calls = profile.calls and profile.calls[num]
            local last_sms_ts = meta and meta.timestamp or 0
            local last_call_ts = (calls and #calls > 0) and calls[#calls].timestamp or 0
            local time_str = ""
            local snippet = ""
            if last_sms_ts > 0 or last_call_ts > 0 then
                if last_sms_ts >= last_call_ts then
                    time_str = formatMessageTime(last_sms_ts)
                    if num == "banking" then snippet = u8"Выписка из банка"
                    else
                        local prefix = (meta.sender == "me") and u8"Вы: " or ""
                        snippet = prefix .. u8(meta.text):gsub("\n", " ")
                    end
                else
                    time_str = formatMessageTime(last_call_ts)
                    snippet = u8"[Звонок]"
                end
            else
                snippet = u8"Нет сообщений"
            end

            local time_w = imgui.CalcTextSize(time_str).x
            cdl:AddText(imgui.ImVec2(p_max.x - time_w - 10 * scale, p_min.y + 10 * scale), imgui.GetColorU32Vec4(is_unread and pal.accent or pal.textSecondary), time_str)

            local badges_w = 0
            local isVerified = (num == "banking" or num == "system" or (profile.verified and profile.verified[num]))
            if isVerified then badges_w = badges_w + 18 * scale end
            if is_muted then badges_w = badges_w + 16 * scale end
            if is_pinned then badges_w = badges_w + 16 * scale end

            local maxNameW = (p_max.x - textLeftX) - time_w - badges_w - 16 * scale
            local truncName = truncateText(displayName, maxNameW)
            cdl:AddText(imgui.ImVec2(textLeftX, p_min.y + 10 * scale), imgui.GetColorU32Vec4(pal.textPrimary), truncName)

            local badgeX = textLeftX + imgui.CalcTextSize(truncName).x + 8 * scale
            local badgeY = p_min.y + 10 * scale + imgui.GetTextLineHeight() / 2
            
            if isVerified then
                DrawVerificationBadge(cdl, imgui.ImVec2(badgeX, badgeY), 5.5 * scale, scale)
                badgeX = badgeX + 16 * scale
            end
            if is_pinned then
                DrawPinBadge(cdl, imgui.ImVec2(badgeX, badgeY), 5.0 * scale, scale)
                badgeX = badgeX + 16 * scale
            end
            if is_muted then
                DrawMuteBadge(cdl, imgui.ImVec2(badgeX, badgeY), 5.0 * scale, scale, pal.textSecondary)
            end

            local rightReserve = 10 * scale
            if is_unread then
                local unreadCount = type(is_unread) == "number" and is_unread or 1
                local badgeTxt = tostring(unreadCount)
                local bSz = imgui.CalcTextSize(badgeTxt)
                local bW = math.max(bSz.x + 10 * scale, 18 * scale)
                local bH = 16 * scale
                local bx = p_max.x - bW - 10 * scale
                local by = p_min.y + 35 * scale
                local bCol = is_muted and pal.textSecondary or pal.accent
                cdl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + bW, by + bH), imgui.GetColorU32Vec4(bCol), 8.0 * scale)
                cdl:AddText(imgui.ImVec2(bx + (bW - bSz.x) / 2, by + (bH - bSz.y) / 2), imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 1)), badgeTxt)
                rightReserve = bW + 18 * scale
            end

            local has_draft = profile.drafts and profile.drafts[num] and profile.drafts[num] ~= ""
            local snipMaxW = (p_max.x - textLeftX) - rightReserve
            if has_draft then
                local dText = u8"Черновик: " .. u8(profile.drafts[num]):gsub("\n", " ")
                cdl:AddText(imgui.ImVec2(textLeftX, p_min.y + 35 * scale), imgui.GetColorU32Vec4(imgui.ImVec4(0.88, 0.32, 0.32, 1.0)), truncateToLastWord(dText, snipMaxW))
            else
                local snipCol = is_unread and pal.textPrimary or pal.textSecondary
                cdl:AddText(imgui.ImVec2(textLeftX, p_min.y + 35 * scale), imgui.GetColorU32Vec4(snipCol), truncateToLastWord(snippet, snipMaxW))
            end

            cdl:AddLine(imgui.ImVec2(textLeftX, p_max.y), imgui.ImVec2(p_max.x - 10 * scale, p_max.y), imgui.GetColorU32Vec4(pal.separator), 1.0)

            imgui.PopID()
        end
        
        -- Задаем большой отступ (пустышку), чтобы последний контакт в списке гарантированно поднимался ВЫШЕ наложенной строки поиска
        imgui.Dummy(imgui.ImVec2(0, 160 * scale)) 
        imgui.EndChild()
        -- PopStyleVar убран, так как мы переместили его в начало под BeginChild

        local searchW = winSize.x - 32 * scale
        local searchH = 38 * scale
        local searchY = winSize.y - searchH - 24 * scale

        imgui.SetCursorPos(imgui.ImVec2(16 * scale, searchY))
        -- Используем BeginChild вместо отдельного окна, чтобы поиск не пропадал при перетаскивании телефона
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0,0))
        if imgui.BeginChild("IosSearchBox", imgui.ImVec2(searchW, searchH), false, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoBackground) then
            
            -- Отрисовываем полупрозрачную подложку поиска
            local sdl = imgui.GetWindowDrawList()
            sdl:AddRectFilled(imgui.ImVec2(winPos.x + 16 * scale, winPos.y + searchY), imgui.ImVec2(winPos.x + 16 * scale + searchW, winPos.y + searchY + searchH), imgui.GetColorU32Vec4(imgui.ImVec4(pal.inputBg.x, pal.inputBg.y, pal.inputBg.z, 0.85)), 12.0 * scale)

            imgui.PushItemWidth(searchW)
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 12.0 * scale)
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(12 * scale, (searchH - imgui.GetTextLineHeight()) / 2))
            imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
            
            imgui.InputTextWithHint("##IosSearchContact", u8"Поиск", UI.inputSearchContact, 256)
            
            imgui.PopStyleColor()
            imgui.PopStyleVar(2)
            imgui.PopItemWidth()
            
            imgui.EndChild()
        end
        imgui.PopStyleVar()
        popIosStyles()
        return
    end

    -- Подготовка данных выбранного контакта
    local rawName = profile.contacts[activeContact] or ""
    local shortTitle = ""
    if activeContact == "banking" then shortTitle = u8"Банк"
    elseif activeContact == "system" then shortTitle = u8"Уведомления"
    else shortTitle = (rawName ~= "" and u8(rawName) or ("#" .. activeContact)) end
    local isVerifiedChat = (isSystemChat or (profile.verified and profile.verified[activeContact]))

    -- =========================================================================
    -- ЭКРАН 3: КАРТОЧКА КОНТАКТА iOS 26
    -- =========================================================================
    if UI.showContactProfile and not UI.showCallHistory then
        imgui.SetCursorPos(imgui.ImVec2(16 * scale, 38 * scale))
        local bClick = DrawIosVectorBtn("##ios_prof_back", "back", 15 * scale, pal.glassBtn, pal.glassBtnHover, pal.textPrimary, pal.glassBorder, scale)
        if bClick then UI.showContactProfile = false end

        if not isSystemChat then
            local editLabel = u8"Изм."
            local editW = imgui.CalcTextSize(editLabel).x + 22 * scale
            imgui.SetCursorPos(imgui.ImVec2(winSize.x - editW - 16 * scale, 38 * scale))
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 15.0 * scale)
            imgui.PushStyleColor(imgui.Col.Button, pal.glassBtn)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, pal.glassBtnHover)
            imgui.PushStyleColor(imgui.Col.Text, pal.textPrimary)
            if imgui.Button(editLabel, imgui.ImVec2(editW, 30 * scale)) then
                ffi.copy(UI.inputContactNumber, activeContact)
                ffi.copy(UI.inputContactName, u8(rawName))
                local nick = (profile.nicknames and profile.nicknames[activeContact]) and profile.nicknames[activeContact] or ""
                ffi.copy(UI.inputContactNick, nick)
                UI.requestContactModal = true
            end
            imgui.PopStyleColor(3)
            imgui.PopStyleVar(1)
        end

        -- Большой круглый аватар по центру
        local bigR = 36 * scale
        local avCenter = imgui.ImVec2(winPos.x + winSize.x / 2, winPos.y + 100 * scale)
        
        local drawnAv = false
        if globalVerified[activeContact] and globalVerified[activeContact].avatar_url and globalVerified[activeContact].avatar_url ~= "" then
            local url = globalVerified[activeContact].avatar_url
            if not imageCache[url] then
                if globalSettings.autoDownloadMedia then downloadImageToCache(url) else imageCache[url] = { status = 4 } end
            end
            if imageCache[url] and imageCache[url].status == 2 then
                dl:AddImageRounded(imageCache[url].tex, imgui.ImVec2(avCenter.x - bigR, avCenter.y - bigR), imgui.ImVec2(avCenter.x + bigR, avCenter.y + bigR), imgui.ImVec2(0,0), imgui.ImVec2(1,1), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,1)), bigR)
                
                -- Кнопка просмотра перенесена сюда в карточку контакта
                imgui.SetCursorScreenPos(imgui.ImVec2(avCenter.x - bigR, avCenter.y - bigR))
                if imgui.InvisibleButton("ios_av_prof", imgui.ImVec2(bigR * 2, bigR * 2)) then
                    UI.viewingImage = url
                end
                if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end
                
                drawnAv = true
            end
        end
        
        if not drawnAv then
            dl:AddCircleFilled(avCenter, bigR, imgui.GetColorU32Vec4(getAvatarColor(activeContact, 1.0)), 48)
            dl:AddCircle(avCenter, bigR, imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 0.50)), 48, 1.8 * scale)
            local initChar = getContactInitials(activeContact, rawName)
            local initSz = imgui.CalcTextSize(initChar)
            dl:AddText(imgui.ImVec2(avCenter.x - initSz.x / 2, avCenter.y - initSz.y / 2), imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 1)), initChar)
        end

        local cNick = (profile.nicknames and profile.nicknames[activeContact]) and profile.nicknames[activeContact] or nil
        local isOnline = cNick and onlinePlayers[cNick] or false
        local subStr = isSystemChat and u8"СИСТЕМНЫЙ КОНТАКТ" or ("#" .. tostring(activeContact) .. (cNick and ("  |  " .. cNick) or ""))
        local subW = imgui.CalcTextSize(subStr).x
        dl:AddText(imgui.ImVec2(winPos.x + (winSize.x - subW) / 2, winPos.y + 144 * scale), imgui.GetColorU32Vec4(pal.textSecondary), subStr)

        -- Идеально отцентрированное имя + галочка верификации
        local nameSz = imgui.CalcTextSize(shortTitle)
        local totalNameW = nameSz.x + (isVerifiedChat and (18 * scale) or 0)
        local nameStartX = winPos.x + (winSize.x - totalNameW) / 2
        local nameY = winPos.y + 163 * scale
        dl:AddText(imgui.ImVec2(nameStartX, nameY), imgui.GetColorU32Vec4(pal.textPrimary), shortTitle)
        if isVerifiedChat then
            DrawVerificationBadge(dl, imgui.ImVec2(nameStartX + nameSz.x + 10 * scale, nameY + nameSz.y / 2), 6.2 * scale, scale)
        end

        local nextY = 186 * scale
        if isOnline then
            local onTxt = u8"В сети"
            local onW = imgui.CalcTextSize(onTxt).x
            dl:AddText(imgui.ImVec2(winPos.x + (winSize.x - onW) / 2, winPos.y + 183 * scale), imgui.GetColorU32Vec4(imgui.ImVec4(0.18, 0.78, 0.32, 1.0)), onTxt)
            nextY = 204 * scale
        end

        -- Ряд из 4 круглых кнопок с описанием по наведению
        if not isSystemChat then
            local btnR = 19 * scale
            local gap = 20 * scale
            local totalRowW = (btnR * 2) * 4 + gap * 3
            local startX = (winSize.x - totalRowW) / 2

            local isMuted = profile.muted and profile.muted[activeContact]
            local actions = {
                { id = "##act_msg", icon = "msg", label = u8"СМС", tip = u8"Перейти к диалогу" },
                { id = "##act_call", icon = "call", label = u8"Вызов", tip = u8"Позвонить контакту" },
                { id = "##act_geo", icon = "geo", label = u8"Гео", tip = u8"Отправить геопозицию" },
                { id = "##act_mute", icon = isMuted and "bell_off" or "bell_on", label = u8"Звук", tip = isMuted and u8"Включить уведомления" or u8"Отключить уведомления" }
            }

            for i, act in ipairs(actions) do
                local bx = startX + (i - 1) * (btnR * 2 + gap)
                imgui.SetCursorPos(imgui.ImVec2(bx, nextY))
                local click, hov = DrawIosVectorBtn(act.id, act.icon, btnR, pal.cardBg, pal.cardHover, pal.accent, pal.glassBorder, scale)
                if hov then imgui.SetTooltip(act.tip) end
                if click then
                    if i == 1 then
                        UI.showContactProfile = false
                    elseif i == 2 then
                        sampSendChat("/call " .. activeContact)
                        UI.windowState[0] = false
                    elseif i == 3 then
                        triggerAutoGeoMacro(activeContact)
                    elseif i == 4 then
                        if not profile.muted then profile.muted = {} end
                        profile.muted[activeContact] = not profile.muted[activeContact]
                        save_all_data()
                    end
                end
                local lblW = imgui.CalcTextSize(act.label).x
                dl:AddText(imgui.ImVec2(winPos.x + bx + btnR - lblW / 2, winPos.y + nextY + btnR * 2 + 3 * scale), imgui.GetColorU32Vec4(pal.textSecondary), act.label)
            end
            nextY = nextY + btnR * 2 + 24 * scale
        end

        -- Аккуратные карточки действий в стиле iOS
        imgui.SetCursorPos(imgui.ImVec2(14 * scale, nextY))
        imgui.BeginChild("IosContactDetailsScroll", imgui.ImVec2(winSize.x - 28 * scale, winSize.y - nextY - 22 * scale), false)
        local cardW = imgui.GetContentRegionAvail().x
        local cCalls = (profile.calls and profile.calls[activeContact]) or {}

        if not isSystemChat then
            local latestCall = (#cCalls > 0) and cCalls[#cCalls] or nil
            if latestCall then
                local cDate = os.date("%d.%m.%Y в %H:%M", latestCall.timestamp)
                local dur = latestCall.duration or 0
                if dur == 0 and latestCall.messages and #latestCall.messages > 0 then
                    dur = latestCall.messages[#latestCall.messages].timestamp - latestCall.messages[1].timestamp
                end
                if DrawIosCardRow("##last_call_card", u8"Последний звонок", cDate, u8(formatCallDuration(dur) .. "  >"), nil, cardW, 44 * scale, pal, scale) then
                    UI.showCallHistory = true
                    UI.viewingCallIndex = #cCalls
                    UI.callOpenedFromChat = false
                end
                imgui.Dummy(imgui.ImVec2(0, 4 * scale))
            end

            if DrawIosCardRow("##open_call_hist", u8"История звонков", nil, tostring(#cCalls) .. "  >", nil, cardW, 34 * scale, pal, scale) then
                UI.showCallHistory = true
                UI.viewingCallIndex = 0
                UI.callOpenedFromChat = false
            end
            imgui.Dummy(imgui.ImVec2(0, 8 * scale))
        end

        if profile.tagger and profile.tagger[activeContact] then
            if DrawIosCardRow("##open_nova", u8"Профиль Nova (Social)", nil, "@" .. tostring(profile.tagger[activeContact]) .. "  >", pal.accent, cardW, 34 * scale, pal, scale) then
                local url = "https://nova.gambit-rp.com/" .. profile.tagger[activeContact]
                shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
            end
            imgui.Dummy(imgui.ImVec2(0, 8 * scale))
        end

        local isPinned = profile.pinned and profile.pinned[activeContact]
        if DrawIosCardRow("##pin_row", isPinned and u8"Открепить диалог" or u8"Закрепить диалог", nil, nil, nil, cardW, 34 * scale, pal, scale) then
            if not profile.pinned then profile.pinned = {} end
            if isPinned then profile.pinned[activeContact] = nil else profile.pinned[activeContact] = true end
            save_all_data()
            needSortContacts = true
        end
        imgui.Dummy(imgui.ImVec2(0, 4 * scale))

        if not isSystemChat then
            local isBlocked = profile.blocked and profile.blocked[activeContact]
            if DrawIosCardRow("##block_row", isBlocked and u8"Разблокировать номер" or u8"Заблокировать номер", nil, nil, nil, cardW, 34 * scale, pal, scale) then
                Macro.autoBlock = true
                sampSendChat("/blocknum " .. activeContact)
            end
            imgui.Dummy(imgui.ImVec2(0, 4 * scale))
        end

        if DrawIosCardRow("##clear_row", u8"Очистить историю сообщений", nil, nil, nil, cardW, 34 * scale, pal, scale) then
            save_chat_data(myNick, activeContact, {})
            activeChatHistory = {}
            profile.metadata[activeContact] = nil
            profile.calls[activeContact] = nil
            profile.unread[activeContact] = nil
            save_all_data()
            needSortContacts = true
            UI.showContactProfile = false
        end

        if not isSystemChat then
            imgui.Dummy(imgui.ImVec2(0, 8 * scale))
            if DrawIosCardRow("##del_row", u8"Удалить контакт", nil, nil, imgui.ImVec4(0.92, 0.25, 0.25, 1.0), cardW, 34 * scale, pal, scale) then
                UI.contactToDelete = activeContact
                UI.requestDeletePopup = true
            end
        end

        imgui.EndChild()
        popIosStyles()
        return
    end

    -- =========================================================================
    -- ЭКРАН 4: ИСТОРИЯ ЗВОНКОВ iOS 26
    -- =========================================================================
    if UI.showCallHistory then
        imgui.SetCursorPos(imgui.ImVec2(16 * scale, 38 * scale))
        local closeClick = DrawIosVectorBtn("##ios_call_close", UI.viewingCallIndex > 0 and "back" or "close", 15 * scale, pal.glassBtn, pal.glassBtnHover, pal.textPrimary, pal.glassBorder, scale)
        if closeClick then
            if UI.viewingCallIndex > 0 and not UI.callOpenedFromChat then
                UI.viewingCallIndex = 0
            else
                UI.showCallHistory = false
                UI.viewingCallIndex = 0
                UI.callOpenedFromChat = false
            end
        end

        local chTitle = UI.viewingCallIndex == 0 and u8"История звонков" or u8"Запись разговора"
        local chW = imgui.CalcTextSize(chTitle).x
        imgui.SetCursorPos(imgui.ImVec2((winSize.x - chW) / 2, 43 * scale))
        imgui.Text(chTitle)

        imgui.SetCursorPos(imgui.ImVec2(14 * scale, 78 * scale))
        imgui.BeginChild("IosCallHistoryCard", imgui.ImVec2(winSize.x - 28 * scale, winSize.y - 98 * scale), false)
        local cCalls = profile.calls and profile.calls[activeContact] or {}
        local deleteCallIndex = nil
        local cardW = imgui.GetContentRegionAvail().x

        if UI.viewingCallIndex == 0 then
            if #cCalls > 0 then
                for i = #cCalls, 1, -1 do
                    local callData = cCalls[i]
                    local dateStr = os.date("%d.%m.%Y в %H:%M", callData.timestamp)
                    local calc_duration = callData.duration or 0
                    if calc_duration == 0 and callData.messages and #callData.messages > 0 then
                        calc_duration = callData.messages[#callData.messages].timestamp - callData.messages[1].timestamp
                    end
                    imgui.PushIDStr("ios_call_" .. i)
                    if DrawIosCardRow("##call_item_" .. i, u8"Телефонный вызов", dateStr, u8(formatCallDuration(calc_duration) .. "  >"), nil, cardW, 44 * scale, pal, scale) then
                        UI.viewingCallIndex = i
                        UI.callOpenedFromChat = false
                    end
                    if imgui.BeginPopupContextItem("IosCallCtx_" .. i) then
                        if imgui.Selectable(u8"Удалить запись") then deleteCallIndex = i end
                        imgui.EndPopup()
                    end
                    imgui.Dummy(imgui.ImVec2(0, 4 * scale))
                    imgui.PopID()
                end
            else
                imgui.TextColored(pal.textSecondary, u8"Нет записанных звонков.")
            end
        else
            local cCall = cCalls[UI.viewingCallIndex]
            if cCall and cCall.messages and #cCall.messages > 0 then
                for i, msgData in ipairs(cCall.messages) do
                    local isMe = (msgData.sender == "me")
                    local color = isMe and pal.accent or pal.textPrimary
                    local prefix = isMe and u8"Вы: " or u8"Собеседник: "
                    local timeStr = os.date("%H:%M:%S", msgData.timestamp)
                    imgui.TextColored(pal.textSecondary, "[" .. timeStr .. "] ")
                    imgui.SameLine()
                    imgui.PushStyleColor(imgui.Col.Text, color)
                    imgui.PushTextWrapPos(cardW - 8 * scale)
                    imgui.Text(prefix .. u8(msgData.msg))
                    imgui.PopTextWrapPos()
                    imgui.PopStyleColor()
                    if imgui.BeginPopupContextItem("IosCallMsgCtx_" .. i) then
                        if imgui.Selectable(u8"Скопировать") then imgui.SetClipboardText(u8(msgData.msg)) end
                        imgui.EndPopup()
                    end
                end
            else
                imgui.TextColored(pal.textSecondary, u8"Пустой разговор.")
            end
        end
        if deleteCallIndex then
            table.remove(profile.calls[activeContact], deleteCallIndex)
            save_all_data()
            needSortContacts = true
        end
        imgui.EndChild()
        popIosStyles()
        return
    end

    -- =========================================================================
    -- ЭКРАН 2: ДИАЛОГ iMessage iOS 26
    -- =========================================================================
    imgui.SetCursorPos(imgui.ImVec2(16 * scale, 38 * scale))
    local backClick = DrawIosVectorBtn("##ios_back_list", "back", 15 * scale, pal.glassBtn, pal.glassBtnHover, pal.textPrimary, pal.glassBorder, scale)
    if backClick then
        SaveCurrentDraft()
        activeContact = nil
        activeChatId = nil
        activeChatHistory = nil
        UI.showMessageSearch = false
        popIosStyles()
        return
    end

    if not isSystemChat then
        imgui.SetCursorPos(imgui.ImVec2(winSize.x - 46 * scale, 38 * scale))
        local callClick, callHov = DrawIosVectorBtn("##ios_top_call", "call", 15 * scale, pal.glassBtn, pal.glassBtnHover, pal.accent, pal.glassBorder, scale)
        if callHov then imgui.SetTooltip(u8"Позвонить") end
        if callClick then
            sampSendChat("/call " .. activeContact)
            UI.windowState[0] = false
        end
    end

    -- Центральный аватар + капсула с именем контакта
    local headAvR = 16 * scale
    -- Приподнимаем чуть выше (на 52), чтобы освободить место и избежать "челки"
    local headAvCenter = imgui.ImVec2(winPos.x + winSize.x / 2, winPos.y + 52 * scale)
    
    local drawnAv = false
    if globalVerified[activeContact] and globalVerified[activeContact].avatar_url and globalVerified[activeContact].avatar_url ~= "" then
        local url = globalVerified[activeContact].avatar_url
        if not imageCache[url] then
            if globalSettings.autoDownloadMedia then downloadImageToCache(url) else imageCache[url] = { status = 4 } end
        end
        if imageCache[url] and imageCache[url].status == 2 then
            dl:AddImageRounded(imageCache[url].tex, imgui.ImVec2(headAvCenter.x - headAvR, headAvCenter.y - headAvR), imgui.ImVec2(headAvCenter.x + headAvR, headAvCenter.y + headAvR), imgui.ImVec2(0,0), imgui.ImVec2(1,1), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,1)), headAvR)
            
            -- В шапке мы оставляем прозрачную кнопку, но клик по ней просто игнорируется (чтобы не перекрывать кнопку карточки)
            imgui.SetCursorScreenPos(imgui.ImVec2(headAvCenter.x - headAvR, headAvCenter.y - headAvR))
            imgui.InvisibleButton("ios_av_head", imgui.ImVec2(headAvR * 2, headAvR * 2))
            
            drawnAv = true
        end
    end
    
    if not drawnAv then
        dl:AddCircleFilled(headAvCenter, headAvR, imgui.GetColorU32Vec4(getAvatarColor(activeContact, 1.0)), 32)
        local hInit = getContactInitials(activeContact, rawName)
        local hInitSz = imgui.CalcTextSize(hInit)
        dl:AddText(imgui.ImVec2(headAvCenter.x - hInitSz.x / 2, headAvCenter.y - hInitSz.y / 2), imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 1)), hInit)
    end

    local pillLabel = truncateText(shortTitle, 145 * scale)
    local pillTextSz = imgui.CalcTextSize(pillLabel)
    local badgeSpc = isVerifiedChat and (20 * scale) or 0
    local pillW = pillTextSz.x + badgeSpc + 16 * scale
    local pillH = pillTextSz.y + 6 * scale
    local pillMin = imgui.ImVec2(winPos.x + (winSize.x - pillW) / 2, headAvCenter.y + headAvR + 4 * scale)
    local pillMax = imgui.ImVec2(pillMin.x + pillW, pillMin.y + pillH)
    dl:AddRectFilled(pillMin, pillMax, imgui.GetColorU32Vec4(pal.glassBtn), pillH / 2)
    dl:AddText(imgui.ImVec2(pillMin.x + 8 * scale, pillMin.y + 3 * scale), imgui.GetColorU32Vec4(pal.textPrimary), pillLabel)
    if isVerifiedChat then
        DrawVerificationBadge(dl, imgui.ImVec2(pillMin.x + 8 * scale + pillTextSz.x + 10 * scale, pillMin.y + pillH / 2), 5.5 * scale, scale)
    end

    local clickBoxW = math.max(pillW, headAvR * 2)
    local clickBoxH = (pillMax.y - (headAvCenter.y - headAvR))
    imgui.SetCursorScreenPos(imgui.ImVec2(winPos.x + (winSize.x - clickBoxW) / 2, headAvCenter.y - headAvR))
    if imgui.InvisibleButton("##ios_open_contact_card", imgui.ImVec2(clickBoxW, clickBoxH)) then
        UI.showContactProfile = true
    end
    if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.Hand) end

    -- Опускаем зону скролла сообщений вниз
    local chatTopY = 104 * scale
    if UI.showMessageSearch then
        imgui.SetCursorPos(imgui.ImVec2(14 * scale, chatTopY + 2 * scale))
        imgui.PushItemWidth(winSize.x - 28 * scale)
        if UI.requestFocusSearch then
            imgui.SetKeyboardFocusHere()
            UI.requestFocusSearch = false
        end
        imgui.InputTextWithHint("##IosSearchMsg", u8"Поиск в диалоге...", UI.inputSearchMessage, 256)
        imgui.PopItemWidth()
        chatTopY = chatTopY + 32 * scale
    end

    imgui.SetCursorPos(imgui.ImVec2(8 * scale, chatTopY))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.BeginChild("IosChatHistory", imgui.ImVec2(winSize.x - 16 * scale, winSize.y - chatTopY - 58 * scale), false)
    imgui.PopStyleVar()

    imgui.Dummy(imgui.ImVec2(0, 8 * scale))
    local currentHistory = activeChatHistory or {}
    local cCalls = (profile.calls and profile.calls[activeContact]) or {}
    local deleteMsgIndex = nil
    local timeline = {}
    for idx, mData in ipairs(currentHistory) do
        table.insert(timeline, { itemType = "sms", index = idx, data = mData, timestamp = mData.timestamp or 0 })
    end
    for idx, cData in ipairs(cCalls) do
        table.insert(timeline, { itemType = "call", index = idx, data = cData, timestamp = cData.timestamp or 0 })
    end
    table.sort(timeline, function(a, b)
        if a.timestamp == b.timestamp then
            if a.itemType ~= b.itemType then return a.itemType == "sms" end
            return a.index < b.index
        end
        return a.timestamp < b.timestamp
    end)

    if #timeline > 0 then
        local last_date_str = ""
        local scrollY = imgui.GetScrollY()
        local windowH = imgui.GetWindowHeight()
        local culling_buffer = 200 * scale
        local sMsgText = cp1251_lower(u8:decode(ffi.string(UI.inputSearchMessage)))
        local isMsgSearching = UI.showMessageSearch and sMsgText ~= ""
        local wrap_width = 210 * scale

        for _, entry in ipairs(timeline) do
            if entry.itemType == "call" then
                if not isMsgSearching then
                    local callData = entry.data
                    local callIdx = entry.index
                    local current_date_str = get_day_string(callData.timestamp)
                    if current_date_str ~= last_date_str then
                        imgui.Spacing()
                        local tSize = imgui.CalcTextSize(u8(current_date_str)).x
                        imgui.SetCursorPosX((imgui.GetWindowWidth() - tSize) / 2)
                        imgui.TextColored(pal.textSecondary, u8(current_date_str))
                        imgui.Spacing()
                        last_date_str = current_date_str
                    end
                    local calc_duration = callData.duration or 0
                    if calc_duration == 0 and callData.messages and #callData.messages > 0 then
                        calc_duration = callData.messages[#callData.messages].timestamp - callData.messages[1].timestamp
                    end
                    local callTextU8 = u8("Звонок (" .. formatCallDuration(calc_duration) .. ")")
                    local tSize = imgui.CalcTextSize(callTextU8)
                    local posX = (imgui.GetWindowWidth() - tSize.x) / 2
                    local posY = imgui.GetCursorPosY()
                    imgui.SetCursorPosX(posX)
                    imgui.InvisibleButton("##ios_call_btn_" .. callIdx, imgui.ImVec2(tSize.x, tSize.y + 4 * scale))
                    if imgui.IsItemHovered() then
                        imgui.SetMouseCursor(imgui.MouseCursor.Hand)
                        if imgui.IsMouseClicked(0) then
                            UI.showCallHistory = true
                            UI.viewingCallIndex = callIdx
                            UI.callOpenedFromChat = true
                        end
                    end
                    imgui.SetCursorPos(imgui.ImVec2(posX, posY))
                    imgui.TextColored(pal.accent, callTextU8)
                    imgui.Spacing()
                end
            else
                local index = entry.index
                local msgData = entry.data
                local skipMsg = false
                if isMsgSearching then
                    local lowerMsg = cp1251_lower(msgData.msg)
                    if not lowerMsg:find(sMsgText, 1, true) then skipMsg = true end
                end
                if not skipMsg then
                    local text = u8(msgData.msg)
                    local urls = {}
                    local foundUrls = {}
                    local textToDisplay = text
                    for word in text:gmatch("%S+") do
                        local isUrl = false
                        if word:match("^https?://[a-zA-Z0-9_%-%.%?%.:/%+=&]+") then isUrl = true
                        elseif word:match("^[a-zA-Z0-9%-]+%.[a-zA-Z0-9%-%.]*[a-zA-Z][a-zA-Z]+[a-zA-Z0-9_%-%.%?%.:/%+=&]*$") then isUrl = true
                        elseif word:match("^%d+%.%d+%.%d+%.%d+[:%d]*$") then isUrl = true end
                        if isUrl and not foundUrls[word] then
                            foundUrls[word] = true
                            table.insert(urls, word)
                            local safeWord = word:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
                            textToDisplay = textToDisplay:gsub(safeWord, "")
                        end
                    end
                    textToDisplay = textToDisplay:gsub(" +", " "):match("^%s*(.-)%s*$") or ""
                    local current_date_str = get_day_string(msgData.timestamp)
                    local has_date = (current_date_str ~= last_date_str)
                    local date_h = has_date and (10 + imgui.GetTextLineHeight()) or 0
                    local timeText = (msgData.timestamp and msgData.timestamp > 0) and os.date("%H:%M", msgData.timestamp) or "00:00"

                    local urlsStr = table.concat(urls, "|")
                    local loadedStr = "ios_"
                    for _, url in ipairs(urls) do
                        if imageCache[url] and imageCache[url].status == 2 then
                            loadedStr = loadedStr .. url .. imageCache[url].w .. "x" .. imageCache[url].h
                        elseif imageCache[url] and imageCache[url].status == 3 then
                            loadedStr = loadedStr .. url .. "err"
                        elseif imageCache[url] and imageCache[url].status == 4 then
                            loadedStr = loadedStr .. url .. "manual"
                        end
                    end

                    if not msgData.bubbleSize or msgData.cachedScale ~= scale or msgData.urlsStr ~= urlsStr or msgData.loadedStr ~= loadedStr then
                        local msgTextSize = (textToDisplay ~= "") and imgui.CalcTextSize(textToDisplay, nil, false, wrap_width) or imgui.ImVec2(0, 0)
                        local timeSize = imgui.CalcTextSize(timeText)
                        local padding = imgui.ImVec2(12 * scale, 8 * scale)
                        local b_width = (textToDisplay ~= "") and msgTextSize.x or 0
                        local b_height = padding.y * 1.5 + timeSize.y
                        if textToDisplay ~= "" then b_height = b_height + msgTextSize.y + 4 end
                        for _, url in ipairs(urls) do
                            local lUrl = url:lower()
                            local isImg = lUrl:match("^https?://i%.imgur%.com/") and (lUrl:match("%.png$") or lUrl:match("%.jpe?g$") or lUrl:match("%.gif$"))
                            if isImg then
                                if imageCache[url] and imageCache[url].status == 2 then
                                    local iw = math.min(imageCache[url].w * scale, wrap_width)
                                    local ih = iw * (imageCache[url].h / imageCache[url].w)
                                    b_width = math.max(b_width, iw)
                                    b_height = b_height + ih + 5
                                else
                                    b_width = math.max(b_width, 130 * scale)
                                    b_height = b_height + 100 * scale + 5
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
                        msgData.cachedScale = scale
                        msgData.urls = urls
                        msgData.urlsStr = urlsStr
                        msgData.loadedStr = loadedStr
                        msgData.textToDisplay = textToDisplay
                    end

                    local bubbleSize = imgui.ImVec2(msgData.bubbleSize.x, msgData.bubbleSize.y)
                    local timeSize = imgui.ImVec2(msgData.timeSize.x, msgData.timeSize.y)
                    local padding = imgui.ImVec2(12 * scale, 8 * scale)
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
                            imgui.TextColored(pal.textSecondary, u8(current_date_str))
                            imgui.Spacing()
                            last_date_str = current_date_str
                        end
                        local bubble_start_y = imgui.GetCursorPosY()
                        local windowWidth = imgui.GetWindowWidth()
                        local isMe = (msgData.sender == "me")
                        local cursorX = isMe and (windowWidth - bubbleSize.x - 8 * scale) or (8 * scale)

                        imgui.SetCursorPos(imgui.ImVec2(cursorX, bubble_start_y))
                        local screenPos = imgui.GetCursorScreenPos()
                        local bColor = isMe and pal.bubbleMe or pal.bubbleThem
                        local tColor = isMe and pal.bubbleMeText or pal.bubbleThemText
                        local tmColor = isMe and pal.bubbleMeTime or pal.bubbleThemTime
                        local bdl = imgui.GetWindowDrawList()

                        DrawSmoothRoundedRect(
                            bdl,
                            screenPos,
                            imgui.ImVec2(screenPos.x + bubbleSize.x, screenPos.y + bubbleSize.y),
                            imgui.GetColorU32Vec4(bColor),
                            14.0 * scale
                        )

                        imgui.SetCursorPos(imgui.ImVec2(cursorX, bubble_start_y))
                        imgui.InvisibleButton("ios_msgbtn_" .. index, bubbleSize)
                        imgui.SetItemAllowOverlap()
                        if imgui.BeginPopupContextItem("IosMsgPopup_" .. index) then
                            if imgui.Selectable(u8"Скопировать") then imgui.SetClipboardText(text) end
                            imgui.Separator()
                            if imgui.Selectable(u8"Удалить") then deleteMsgIndex = index end
                            imgui.EndPopup()
                        end

                        local currentOffset = bubble_start_y + padding.y
                        if msgData.textToDisplay ~= "" then
                            imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                            imgui.PushStyleColor(imgui.Col.Text, tColor)
                            imgui.PushTextWrapPos(imgui.GetCursorPosX() + wrap_width)
                            imgui.Text(msgData.textToDisplay)
                            imgui.PopTextWrapPos()
                            imgui.PopStyleColor()
                            currentOffset = currentOffset + imgui.CalcTextSize(msgData.textToDisplay, nil, false, wrap_width).y + 4
                        end

                        for u_idx, url in ipairs(msgData.urls) do
                            local lUrl = url:lower()
                            local isImg = lUrl:match("^https?://i%.imgur%.com/") and (lUrl:match("%.png$") or lUrl:match("%.jpe?g$") or lUrl:match("%.gif$"))
                            if isImg then
                                imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                if not imageCache[url] then
                                    if globalSettings.autoDownloadMedia then downloadImageToCache(url) else imageCache[url] = { status = 4 } end
                                end
                                if imageCache[url].status == 2 then
                                    local iw = math.min(imageCache[url].w * scale, wrap_width)
                                    local ih = iw * (imageCache[url].h / imageCache[url].w)
                                    imgui.Image(imageCache[url].tex, imgui.ImVec2(iw, ih))
                                    imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                    imgui.InvisibleButton("ios_img_" .. index .. "_" .. u_idx, imgui.ImVec2(iw, ih))
                                    if imgui.IsItemHovered() and imgui.IsMouseClicked(0) then UI.viewingImage = url end
                                    if imgui.BeginPopupContextItem("IosImgCtx_" .. index .. "_" .. u_idx) then
                                        if imgui.Selectable(u8"В галерею") then
                                            globalSettings.gallery = globalSettings.gallery or {}
                                            local exists = false
                                            for _, v in ipairs(globalSettings.gallery) do if v == url then exists = true break end end
                                            if not exists then
                                                table.insert(globalSettings.gallery, url)
                                                save_all_data()
                                                showSystemNotification(u8"Картинка сохранена в галерею", 1)
                                            end
                                        end
                                        imgui.Separator()
                                        if imgui.Selectable(u8"Скопировать ссылку") then imgui.SetClipboardText(url) end
                                        if imgui.Selectable(u8"Открыть в браузере") then
                                            UI.linkToOpen = url
                                            UI.requestLinkModal = true
                                        end
                                        imgui.EndPopup()
                                    end
                                    currentOffset = currentOffset + ih + 5
                                else
                                    imgui.TextColored(tmColor, u8"Медиа...")
                                    currentOffset = currentOffset + 25 * scale
                                end
                            else
                                imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                local lnkCol = isMe and imgui.ImVec4(0.85, 0.95, 1.0, 1.0) or pal.accent
                                imgui.PushStyleColor(imgui.Col.Text, lnkCol)
                                imgui.PushTextWrapPos(imgui.GetCursorPosX() + wrap_width)
                                imgui.Text(url)
                                imgui.PopTextWrapPos()
                                imgui.PopStyleColor()
                                local linkSize = imgui.CalcTextSize(url, nil, false, wrap_width)
                                imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                if imgui.InvisibleButton("ios_lnk_" .. index .. "_" .. u_idx, linkSize) then
                                    UI.linkToOpen = url
                                    UI.requestLinkModal = true
                                end
                                currentOffset = currentOffset + linkSize.y + 5
                            end
                        end

                        local time_x = cursorX + bubbleSize.x - timeSize.x - padding.x + 4
                        local time_y = bubble_start_y + bubbleSize.y - timeSize.y - padding.y / 2
                        imgui.SetCursorPos(imgui.ImVec2(time_x, time_y))
                        imgui.TextColored(tmColor, timeText)
                        imgui.SetCursorPosY(bubble_start_y + bubbleSize.y + 6)
                    end
                end
            end
        end

        if deleteMsgIndex then
            table.remove(currentHistory, deleteMsgIndex)
            if #currentHistory > 0 then
                local lMsg = currentHistory[#currentHistory]
                profile.metadata[activeContact] = { sender = lMsg.sender, text = lMsg.msg, timestamp = lMsg.timestamp }
            else
                profile.metadata[activeContact] = nil
            end
            save_chat_data(myNick, activeContact, currentHistory)
            save_all_data()
            needSortContacts = true
        end
    end

    if UI.scrollToBottom then
        UI.scrollTicks = 2
        UI.scrollToBottom = false
    end
    if UI.scrollTicks and UI.scrollTicks > 0 then
        imgui.SetScrollY(imgui.GetScrollMaxY() + 999999.0)
        UI.scrollTicks = UI.scrollTicks - 1
    end
    imgui.EndChild()

    -- Нижняя панель ввода iOS 26 (поднята над скруглением и выровнена строго внутри рамки)
    local inputRowY = winSize.y - 52 * scale
    if isSystemChat then
        local bText = u8"Системный канал (только чтение)"
        local bw = imgui.CalcTextSize(bText).x
        imgui.SetCursorPos(imgui.ImVec2((winSize.x - bw) / 2, inputRowY + 4 * scale))
        imgui.TextColored(pal.textSecondary, bText)
    else
        imgui.SetCursorPos(imgui.ImVec2(16 * scale, inputRowY))
        local pClick, pHov = DrawIosVectorBtn("##ios_plus_btn", "plus", 14 * scale, pal.glassBtn, pal.glassBtnHover, pal.textPrimary, pal.glassBorder, scale)
        if pHov then imgui.SetTooltip(u8"Вложения и действия") end
        if pClick then imgui.OpenPopup("IosPlusMenu") end

        if imgui.BeginPopup("IosPlusMenu") then
            if imgui.Selectable(u8"Отправить геопозицию") then triggerAutoGeoMacro(activeContact) end
            if imgui.Selectable(u8"Галерея медиа") then UI.showGallery[0] = not UI.showGallery[0] end
            if imgui.Selectable(u8"Поиск по сообщениям") then
                UI.showMessageSearch = not UI.showMessageSearch
                if UI.showMessageSearch then UI.requestFocusSearch = true else UI.inputSearchMessage[0] = 0 end
            end
            if imgui.Selectable(u8"История звонков") then
                UI.showCallHistory = true
                UI.viewingCallIndex = 0
                UI.callOpenedFromChat = false
            end
            if imgui.Selectable(u8"Карточка контакта") then
                UI.showContactProfile = true
            end
            imgui.EndPopup()
        end

        local inputX = 50 * scale
        local sendBtnX = winSize.x - 44 * scale
        local inputW = sendBtnX - inputX - 6 * scale
        local padY = math.max(4 * scale, (28 * scale - imgui.GetTextLineHeight()) / 2)

        imgui.SetCursorPos(imgui.ImVec2(inputX, inputRowY))
        imgui.PushItemWidth(inputW)
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 14.0 * scale)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(12 * scale, padY))
        if imgui.InputTextWithHint("##IosMessageInput", u8"iMessage...", UI.inputMessage, 2048, imgui.InputTextFlags.EnterReturnsTrue) then
            sendMessage(activeContact)
        end
        if UI.requestFocus then
            imgui.SetKeyboardFocusHere(-1)
            UI.requestFocus = false
        end
        imgui.PopStyleVar(2)
        imgui.PopItemWidth()

        imgui.SetCursorPos(imgui.ImVec2(sendBtnX, inputRowY))
        local sClick = DrawIosVectorBtn("##ios_send_btn", "send", 14 * scale, pal.accent, pal.accent, imgui.ImVec4(1, 1, 1, 1), nil, scale)
        if sClick then sendMessage(activeContact) end
    end

    -- Маска рисуется ТОЛЬКО если мы находимся на главном экране (список контактов)
    if not activeContact then
        local finalDl = imgui.GetWindowDrawList()
        local fOuterMin = winPos
        local fOuterMax = imgui.ImVec2(winPos.x + winSize.x, winPos.y + winSize.y)
        local fBezelMin = imgui.ImVec2(winPos.x + 2.5 * scale, winPos.y + 2.5 * scale)
        local fBezelMax = imgui.ImVec2(winPos.x + winSize.x - 2.5 * scale, winPos.y + winSize.y - 2.5 * scale)
        finalDl:AddRect(fOuterMin, fOuterMax, imgui.GetColorU32Vec4(pal.frameOuter), 34.0 * scale, 15, 6.0 * scale)
        finalDl:AddRect(fBezelMin, fBezelMax, imgui.GetColorU32Vec4(pal.frameBezel), 31.5 * scale, 15, 6.0 * scale)
    end

    popIosStyles()
end

local wasWindowOpen = false
local newFrame = imgui.OnFrame(
    function() return UI.windowState[0] or UI.viewingImage ~= nil or UI.showGallery[0] end,
    function(player)
        local profile = phoneData[myNick]
        if not profile then return end

        if globalSettings.font and globalSettings.font > 1 and customFonts[globalSettings.font] then
            imgui.PushFont(customFonts[globalSettings.font])
        end
        
        local baseScale = globalSettings.uiScale or 1.0
        local fontScale = (globalSettings.fontSize or 14.0) / 14.0
        local scale = baseScale * fontScale
        local fontPreview = (globalSettings.fontSize or 14.0) / loadedFontSize
        imgui.GetIO().FontGlobalScale = baseScale * fontPreview
        
        local resX, resY = getScreenResolution()
        local active_theme = GetActiveTheme()
        ApplyTheme(active_theme, 0.95)

        local isPhone = globalSettings.iosPhoneMode

        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 6.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.PopupRounding, 10.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8.0 * scale)

        local sizeCond = UI.forceResize and imgui.Cond.Always or imgui.Cond.FirstUseEver
        DrawThemeEditor(scale, sizeCond)

        if UI.windowState[0] and not wasWindowOpen then
            imgui.SetNextWindowFocus()
        end
        wasWindowOpen = UI.windowState[0]

        if isPhone then
            imgui.SetNextWindowPos(imgui.ImVec2(resX - 28 * scale, resY - 28 * scale), imgui.Cond.FirstUseEver, imgui.ImVec2(1.0, 1.0))
            imgui.SetNextWindowSize(imgui.ImVec2(335 * scale, 610 * scale), imgui.Cond.Always)
            if UI.forceResize then UI.forceResize = false end

            imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0.0)
            local phoneFlags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoBackground
            local begun = imgui.Begin("##Ios26PhoneWindow", UI.windowState, phoneFlags)
            imgui.PopStyleVar(2)

            if begun then
                DrawModals(scale)
                profile = phoneData[myNick]
                DrawIosPhoneContent(scale, profile)
                imgui.End()
            end
        else
            imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
            imgui.SetNextWindowSize(imgui.ImVec2(750 * scale, 500 * scale), sizeCond)
            if UI.forceResize then UI.forceResize = false end

            if imgui.Begin(u8"Мессенджер", UI.windowState, imgui.WindowFlags.NoCollapse) then
                DrawModals(scale)
                profile = phoneData[myNick]
                imgui.Columns(2, "PhoneColumns", false)
                imgui.SetColumnWidth(0, 280 * scale)
                local leftAvailW = imgui.GetContentRegionAvail().x
                DrawContactsList(scale, profile, leftAvailW)
                imgui.NextColumn()
                DrawChatHistory(scale, profile)
                imgui.Columns(1)
                imgui.End()
            end
        end
        
        DrawGalleryWindow(scale)
        DrawImageViewer(scale, resX, resY)
        
        imgui.PopStyleVar(4)
        imgui.PopStyleColor(20) 
        
        if globalSettings.font and globalSettings.font > 1 and customFonts[globalSettings.font] then
            imgui.PopFont()
        end
    end
)

function sendMessage(number)
    local text = u8:decode(ffi.string(UI.inputMessage))
    text = text:gsub("[\r\n]+", " "):match("^%s*(.-)%s*$") or ""
    if text ~= "" then
        local prefixLen = 6 + #tostring(number)
        local maxLen = 128 - prefixLen - 1
        if maxLen < 20 then maxLen = 20 end
        
        local chunks = {}
        local rem = text
        while #rem > 0 do
            local isFirst = (#chunks == 0)
            local leadPlus = isFirst and "" or "+"
            local availLast = maxLen - #leadPlus
            if #rem <= availLast then
                table.insert(chunks, leadPlus .. rem)
                break
            else
                local availMore = maxLen - #leadPlus - 1
                local sub = rem:sub(1, availMore)
                local lastSpace = sub:match("^.*()%s")
                local part = ""
                if lastSpace and lastSpace > 1 then
                    part = rem:sub(1, lastSpace - 1):match("^(.-)%s*$")
                    rem = rem:sub(lastSpace + 1):match("^%s*(.*)$")
                else
                    part = sub
                    rem = rem:sub(availMore + 1):match("^%s*(.*)$")
                end
                table.insert(chunks, leadPlus .. part .. "+")
            end
        end
        
        local profile = phoneData[myNick]
        if profile then
            addSmsToHistory(profile, number, "me", text, os.time())
            syncGlobalVerified(number)
            needSortContacts = true
        end
        
        if not pendingLocalSms[number] or (os.clock() - pendingLocalSms[number].time >= 15.0) then
            pendingLocalSms[number] = { count = 0, time = os.clock() }
        end
        pendingLocalSms[number].count = pendingLocalSms[number].count + #chunks
        pendingLocalSms[number].time = os.clock()
        
        for i, chunk in ipairs(chunks) do
            if i == 1 and #smsOutQueue == 0 and (os.clock() - lastSmsOutTime > smsSendDelay) then
                lastSentSmsTask = { num = number, text = chunk }
                sampSendChat("/sms " .. number .. " " .. chunk)
                lastSmsOutTime = os.clock()
                smsSendDelay = 1.0
            else
                table.insert(smsOutQueue, { num = number, text = chunk })
            end
        end
        
        ClearDraft(number)
        UI.scrollToBottom = true
        UI.requestFocus = true
        
        for word in text:gmatch("%S+") do
            local lWord = word:lower()
            if lWord:match("^https?://i%.imgur%.com/") and (lWord:match("%.png$") or lWord:match("%.jpe?g$") or lWord:match("%.gif$")) then
                globalSettings.gallery = globalSettings.gallery or {}
                local exists = false
                for _, v in ipairs(globalSettings.gallery) do
                    if v == word then exists = true break end
                end
                if not exists then
                    table.insert(globalSettings.gallery, word)
                    save_all_data()
                end
            end
        end
    end
end
