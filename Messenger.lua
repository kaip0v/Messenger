script_name("ImGui Messenger")
local script_version = 1.84

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

math.randomseed(os.time())

local function generateGroupId()
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local id = ""
    for i = 1, 6 do
        local r = math.random(1, #chars)
        id = id .. chars:sub(r, r)
    end
    return id
end

ffi.cdef[[
    void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
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

local masterFile = getWorkingDirectory() .. '\\config\\Messenger.json'
local oldDataFile = getWorkingDirectory() .. '\\config\\messenger_data.json'
local oldSettingsFile = getWorkingDirectory() .. '\\config\\messenger_settings.json'

local phoneData = {}
local groupSmsQueue = {}
local lastGroupSmsTime = 0
local lastAttemptedGroupNum = nil
local lastAttemptedGroupId = nil
local cacheFolder = getWorkingDirectory() .. '\\config\\messenger_cache\\'
pcall(lfs.mkdir, cacheFolder)
local cacheClearTimer = 0
local cacheCleared = false

local function isImageSafe(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local bytes = f:read(4)
    f:close()
    if not bytes then return false end
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
    gallery = {}
}

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
local lastSmsGroupId = nil

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
    inputMessage = imgui.new.char[512](""),
    inputSearchContact = imgui.new.char[256](""),
    inputSearchMessage = imgui.new.char[256](""),
    inputOpenCommand = imgui.new.char[64](""),
    showMessageSearch = false,
    showCallHistory = false,
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
    showThemeEditor = imgui.new.bool(false),
    forceResize = false
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
    waitingForGeoConfirm = false
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

local themes = {
    { name = "Классический синий", me = imgui.ImVec4(0.18, 0.35, 0.58, 1.0), them = imgui.ImVec4(0.25, 0.25, 0.25, 1.0), warn = imgui.ImVec4(0.20, 0.60, 0.90, 1.0), notif_bg = imgui.ImVec4(0.12, 0.12, 0.12, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.20, 0.60, 0.90, 0.80) },
    { name = "Темная ночь", me = imgui.ImVec4(0.35, 0.35, 0.35, 1.0), them = imgui.ImVec4(0.12, 0.12, 0.12, 1.0), warn = imgui.ImVec4(0.70, 0.70, 0.70, 1.0), notif_bg = imgui.ImVec4(0.08, 0.08, 0.08, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.50, 0.50, 0.50, 0.80) },
    { name = "Telegram (Dark)", me = imgui.ImVec4(0.17, 0.35, 0.53, 1.0), them = imgui.ImVec4(0.11, 0.14, 0.18, 1.0), warn = imgui.ImVec4(0.25, 0.55, 0.85, 1.0), notif_bg = imgui.ImVec4(0.09, 0.11, 0.14, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.25, 0.55, 0.85, 0.80) },
    { name = "WhatsApp (Dark)", me = imgui.ImVec4(0.02, 0.38, 0.33, 1.0), them = imgui.ImVec4(0.12, 0.17, 0.20, 1.0), warn = imgui.ImVec4(0.10, 0.70, 0.40, 1.0), notif_bg = imgui.ImVec4(0.07, 0.12, 0.13, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.10, 0.70, 0.40, 0.80) },
    { name = "AMOLED Черный", me = imgui.ImVec4(0.25, 0.25, 0.25, 1.0), them = imgui.ImVec4(0.05, 0.05, 0.05, 1.0), warn = imgui.ImVec4(0.80, 0.80, 0.80, 1.0), notif_bg = imgui.ImVec4(0.0, 0.0, 0.0, 0.95), notif_text = imgui.ImVec4(0.95, 0.95, 0.95, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.60, 0.60, 0.60, 0.80) },
    { name = "Изумрудный", me = imgui.ImVec4(0.15, 0.45, 0.25, 1.0), them = imgui.ImVec4(0.20, 0.25, 0.20, 1.0), warn = imgui.ImVec4(0.20, 0.70, 0.30, 1.0), notif_bg = imgui.ImVec4(0.08, 0.15, 0.10, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.20, 0.70, 0.30, 0.80) },
    { name = "Малиновый закат", me = imgui.ImVec4(0.50, 0.20, 0.35, 1.0), them = imgui.ImVec4(0.25, 0.15, 0.20, 1.0), warn = imgui.ImVec4(0.80, 0.30, 0.50, 1.0), notif_bg = imgui.ImVec4(0.15, 0.08, 0.12, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.80, 0.30, 0.50, 0.80) },
    { name = "Осенний лес", me = imgui.ImVec4(0.65, 0.33, 0.05, 1.0), them = imgui.ImVec4(0.25, 0.32, 0.22, 1.0), warn = imgui.ImVec4(0.90, 0.50, 0.10, 1.0), notif_bg = imgui.ImVec4(0.15, 0.12, 0.08, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.90, 0.50, 0.10, 0.80) },
    { name = "Океанская бездна", me = imgui.ImVec4(0.05, 0.30, 0.45, 1.0), them = imgui.ImVec4(0.05, 0.15, 0.25, 1.0), warn = imgui.ImVec4(0.10, 0.60, 0.80, 1.0), notif_bg = imgui.ImVec4(0.04, 0.08, 0.15, 0.95), notif_text = imgui.ImVec4(0.9, 0.9, 0.9, 1.0), sys_ok = imgui.ImVec4(0.20, 0.80, 0.20, 0.80), sys_err = imgui.ImVec4(0.80, 0.20, 0.20, 0.80), sys_info = imgui.ImVec4(0.10, 0.60, 0.80, 0.80) },
    { name = "Townly светлая", me = imgui.ImVec4(0.12, 0.53, 0.90, 1.0), them = imgui.ImVec4(0.96, 0.97, 0.98, 1.0), warn = imgui.ImVec4(0.94, 0.30, 0.30, 1.0), notif_bg = imgui.ImVec4(0.10, 0.12, 0.15, 0.95), notif_text = imgui.ImVec4(0.95, 0.95, 0.95, 1.0), sys_ok = imgui.ImVec4(0.15, 0.75, 0.35, 0.80), sys_err = imgui.ImVec4(0.94, 0.30, 0.30, 0.80), sys_info = imgui.ImVec4(0.12, 0.53, 0.90, 0.80) },
    { name = "Townly тёмная", me = imgui.ImVec4(0.35, 0.65, 0.95, 1.0), them = imgui.ImVec4(0.11, 0.13, 0.16, 1.0), warn = imgui.ImVec4(0.95, 0.40, 0.40, 1.0), notif_bg = imgui.ImVec4(0.18, 0.22, 0.27, 0.95), notif_text = imgui.ImVec4(0.95, 0.95, 0.95, 1.0), sys_ok = imgui.ImVec4(0.20, 0.85, 0.40, 0.80), sys_err = imgui.ImVec4(0.95, 0.40, 0.40, 0.80), sys_info = imgui.ImVec4(0.35, 0.65, 0.95, 0.80) }
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

local function cleanupGhostFiles()
    local cfgPath = getWorkingDirectory() .. '\\config\\'
    pcall(lfs.mkdir, cacheFolder)
    pcall(function()
        for file in lfs.dir(cacheFolder) do
            if file ~= "." and file ~= ".." then
                pcall(os.remove, cacheFolder .. file)
            end
        end
        for file in lfs.dir(cfgPath) do
            if type(file) == 'string' then
                if file:match("%.tmp$") or file:match("^msg_update_%d+%.json$") or file:match("^msg_changelog_%d+%.txt$") or file:match("^temp_news_%d+%.txt$") or file:match("^verify_%d+%.json$") then
                    pcall(os.remove, cfgPath .. file)
                end
            end
        end
    end)
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

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

local function save_all_data()
    local toSave = {
        global_settings = globalSettings,
        profiles = phoneData
    }
    save_json(masterFile, toSave)
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
    if not profile.history[number] then profile.history[number] = {} end
    table.insert(profile.history[number], {sender = sender, msg = text, timestamp = ts})
    save_all_data()
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
    imageCache[url] = { status = 1 }
    local cleanUrl = url:match("([^%?]+)") or url
    local ext = cleanUrl:match("%.([^%.]+)$") or "png"
    local tempPath = getWorkingDirectory() .. "\\config\\img_" .. tostring(math.random(1000000,9999999)) .. "." .. ext
    activeTempFiles[tempPath] = true
    local dlstatus = require('moonloader').download_status
    
    downloadUrlToFile(url, tempPath, function(id, status)
        if status == dlstatus.STATUS_ENDDOWNLOADDATA then
            lua_thread.create(function()
                wait(150)
                if doesFileExist(tempPath) then
                    if not isImageSafe(tempPath) then
                        pcall(os.remove, tempPath)
                        activeTempFiles[tempPath] = nil
                        imageCache[url] = { status = 3 }
                        UI.scrollToBottom = true
                        return
                    end
                    
                    local rtex = renderLoadTextureFromFile(tempPath)
                    if rtex then
                        local tex_w, tex_h = renderGetTextureSize(rtex)
                        renderReleaseTexture(rtex)
                        
                        local tex = imgui.CreateTextureFromFile(tempPath)
                        if tex then
                            table.insert(imageCacheKeys, url)
                            if #imageCacheKeys > 15 then
                                local oldUrl = table.remove(imageCacheKeys, 1)
                                if imageCache[oldUrl] and imageCache[oldUrl].tex then
                                    imageCache[oldUrl].tex:Release() 
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
                    pcall(os.remove, tempPath)
                    activeTempFiles[tempPath] = nil
                else
                    imageCache[url] = { status = 3 }
                    UI.scrollToBottom = true
                    activeTempFiles[tempPath] = nil
                end
            end)
        elseif status == dlstatus.STATUS_EX_ERROR then
            pcall(os.remove, tempPath)
            activeTempFiles[tempPath] = nil
            imageCache[url] = { status = 3 }
            UI.scrollToBottom = true
        end
    end)
end

function checkUpdates()
    if not globalSettings.autoUpdate then return end
    
    local updateFile_tmp = getWorkingDirectory() .. '\\config\\msg_update_' .. tostring(math.random(100000, 999999)) .. '.json'
    activeTempFiles[updateFile_tmp] = true
    
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
                        local is_silent = (data.silent == true)
                        
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
                                                if decoded then
                                                    newCode = decoded
                                                end
                                            end
                                            
                                            local fOut = io.open(scriptPath, "wb")
                                            if fOut then
                                                fOut:write(newCode)
                                                fOut:close()
                                                
                                                if not is_silent then
                                                    showSystemNotification(u8"Успешно обновлено! Перезапуск...", 1)
                                                end
                                                lua_thread.create(function()
                                                    wait(1500)
                                                    thisScript():reload()
                                                end)
                                            elseif not is_silent then
                                                showSystemNotification(u8"Ошибка: Файл скрипта занят!", 2)
                                            end
                                        end
                                    elseif status2 == dlstatus.STATUS_EX_ERROR then
                                        pcall(os.remove, tempPath)
                                        activeTempFiles[tempPath] = nil
                                        if not is_silent then
                                            showSystemNotification(u8"Ошибка при скачивании обновления!", 2)
                                        end
                                    end
                                end)
                            end

                            if is_silent then
                                downloadAndInstallScript()
                            else
                                local changelogFile_tmp = getWorkingDirectory() .. '\\config\\msg_changelog_' .. tostring(math.random(100000, 999999)) .. '.txt'
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
                                        
                                        if changelogText ~= "" then
                                            local text_to_save = changelogText
                                            if changelogText:find("[\208\209][\128-\191]") then
                                                local decoded = u8:decode(changelogText)
                                                if decoded then text_to_save = decoded end
                                            end
                                            
                                            local sys_num = "System_News"
                                            local base_profile = nil
                                            for _, p in pairs(phoneData) do base_profile = p break end
                                            
                                            if base_profile then
                                                if not base_profile.contacts[sys_num] then base_profile.contacts[sys_num] = "Уведомления" end
                                                addSmsToHistory(base_profile, sys_num, "them", text_to_save, os.time())
                                            end
                                            
                                            for _, p in pairs(phoneData) do p.unread[sys_num] = true end
                                            save_all_data()
                                        end
                                        
                                        lua_thread.create(function()
                                            wait(100)
                                            downloadAndInstallScript()
                                        end)
                                    elseif status_cl == dlstatus.STATUS_EX_ERROR then
                                        pcall(os.remove, changelogFile_tmp)
                                        activeTempFiles[changelogFile_tmp] = nil
                                        downloadAndInstallScript()
                                    end
                                end)
                            end
                        end)
                    end
                end
            end
        elseif status == dlstatus.STATUS_EX_ERROR then
            pcall(os.remove, updateFile_tmp)
            activeTempFiles[updateFile_tmp] = nil
        end
    end)
end

function samp.onShowTextDraw(id, data)
    if CallState.active and not CallState.number then
        if type(data.text) == "string" then
            local tnum = data.text:match("^%d%d%d%d%d%d?$")
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
        if wparam == vkeys.VK_ESCAPE and (UI.windowState[0] or UI.viewingImage) then
            consumeWindowMessage(true, false)
            if msg == 0x0100 then
                if UI.viewingImage then
                    UI.viewingImage = nil
                    Sys.wasTypingEscape = true
                    return
                end
                Sys.wasTypingEscape = imgui.GetIO().WantCaptureKeyboard
            elseif msg == 0x0101 then
                if not Sys.wasTypingEscape then
                    UI.windowState[0] = false
                    if activeContact and phoneData[myNick] and phoneData[myNick].drafts then
                        local currentText = ffi.string(UI.inputMessage)
                        if currentText ~= "" then
                            phoneData[myNick].drafts[activeContact] = u8:decode(currentText)
                        else
                            phoneData[myNick].drafts[activeContact] = nil
                        end
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
    
    if file_exists(masterFile) then
        local masterData = load_json(masterFile)
        
        if type(masterData) == "table" then
            if masterData.global_settings then
                for k, v in pairs(masterData.global_settings) do
                    globalSettings[k] = v
                end
                if globalSettings.customTheme then
                    globalSettings.customThemes = { globalSettings.customTheme }
                    globalSettings.customTheme = nil
                    if globalSettings.theme == 0 then
                        globalSettings.theme = #themes + 1
                    end
                    save_all_data()
                end
            end
            if masterData.profiles then
                phoneData = masterData.profiles
            end
        elseif masterData == false then
            sampAddChatMessage("ImGui Messenger: {FF0000}Ошибка чтения базы данных! Создана резервная копия, чтобы не потерять историю.", -1)
            os.rename(masterFile, masterFile .. ".bak_" .. tostring(os.time()))
        end
    else
        if file_exists(oldDataFile) then
            phoneData = load_json(oldDataFile)
            pcall(os.remove, oldDataFile)
        end
        if file_exists(oldSettingsFile) then
            local loadedSettings = load_json(oldSettingsFile)
            for k, v in pairs(loadedSettings) do
                globalSettings[k] = v
            end
            pcall(os.remove, oldSettingsFile)
        end
        save_all_data()
    end
    
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
            if activeContact and phoneData[myNick] and phoneData[myNick].drafts then
                local currentText = ffi.string(UI.inputMessage)
                if currentText ~= "" then
                    phoneData[myNick].drafts[activeContact] = u8:decode(currentText)
                else
                    phoneData[myNick].drafts[activeContact] = nil
                end
            end
        end
    end)
	
	sampRegisterChatCommand("testgroup", function(param)
        local action, rest = param:match("^(%w+)%s*(.*)")
        if not action then
            sampAddChatMessage("Формат: /testgroup create [ТвойНомер] [ID] [НомераДрузей_через_запятую] [Имя]", 0xFFCC00)
            sampAddChatMessage("Формат: /testgroup send [ID] [Текст]", 0xFFCC00)
            return
        end
        
        local profile = phoneData[myNick]
        if action == "create" then
            local myNum, numsStr, gName = rest:match("^(%d+)%s+([%d%,]+)%s+(.*)")
            if myNum and numsStr and gName then
                local membersList = {}
                for n in numsStr:gmatch("%d+") do
                    table.insert(membersList, n)
                end
                
                if #membersList > 3 then
                    sampAddChatMessage("Ошибка: максимум 3 друга в группе!", 0xFF0000)
                    return
                end
                
                local gId = generateGroupId()
                if not profile.groups then profile.groups = {} end
                local profileMembers = {}
                for _, n in ipairs(membersList) do profileMembers[n] = true end
                
                profile.groups[gId] = { name = gName, members = profileMembers, history = {} }
                save_all_data()
                needSortContacts = true
                
                for i, targetNum in ipairs(membersList) do
                    local payloadMembers = {myNum}
                    for j, otherNum in ipairs(membersList) do
                        if i ~= j then table.insert(payloadMembers, otherNum) end
                    end
                    local payloadStr = table.concat(payloadMembers, ",")
                    table.insert(groupSmsQueue, {num = targetNum, text = "!GRP_INV|" .. gId .. "|" .. payloadStr .. "|" .. gName, groupId = gId})
                end
                
                sampAddChatMessage("Группа '"..gName.."' (ID: "..gId..") создана! Инвайты отправляются.", 0x00FF00)
            else
                sampAddChatMessage("Ошибка! Пример: /testgroup create 9999 1111,2222 Банда", 0xFF0000)
            end
        elseif action == "send" then
            local gId, text = rest:match("^(%w+)%s+(.*)")
            if gId and text and profile.groups and profile.groups[gId] then
                table.insert(profile.groups[gId].history, {sender = "me", msg = text, timestamp = os.time()})
                save_all_data()
                needSortContacts = true
                for memNum, _ in pairs(profile.groups[gId].members) do
                    table.insert(groupSmsQueue, {num = memNum, text = "#" .. gId .. " " .. text, groupId = gId})
                end
                sampAddChatMessage("Сообщение добавлено в очередь рассылки!", 0x00FF00)
            else
                sampAddChatMessage("Группа не найдена или ошибка ввода.", 0xFF0000)
            end
        end
    end)

    local result, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if result then
        local tempNick = sampGetPlayerNickname(myId)
        lastSeenNick = tempNick
        if tempNick:find("_") and not tempNick:match("^Mask_%d+$") then
            myNick = tempNick
            actualPlayerNick = tempNick
        end
    end
    
    local master_news_hist = nil
    for _, pData in pairs(phoneData) do
        if pData.history and pData.history["System_News"] then
            master_news_hist = pData.history["System_News"]
            break
        end
    end
    if not master_news_hist then master_news_hist = {} end
    
    for pName, pData in pairs(phoneData) do
        if not pData.unread then pData.unread = {} end
        if not pData.contacts then pData.contacts = {} end
        if not pData.history then pData.history = {} end
        if not pData.nicknames then pData.nicknames = {} end
        if not pData.muted then pData.muted = {} end
        if not pData.drafts then pData.drafts = {} end
        if not pData.calls then pData.calls = {} end
		if not pData.groups then pData.groups = {} end
        
        pData.history["System_News"] = master_news_hist
        pData.contacts["System_News"] = "Уведомления"
        
        pData.numbers = nil
        pData.activeNumber = nil
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
        phoneData[myNick] = { contacts = {}, history = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, groups = {} }
        phoneData[myNick].history["System_News"] = master_news_hist
        phoneData[myNick].contacts["System_News"] = "Уведомления"
        save_all_data()
    end
    
    checkUpdates()

    local verifyFile_tmp = getWorkingDirectory() .. '\\config\\verify_' .. tostring(math.random(100000, 999999)) .. '.json'
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

                        for num, _ in pairs(profile.history or {}) do
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

    local temp_news_file = getWorkingDirectory() .. '\\config\\temp_news_' .. tostring(math.random(100000, 999999)) .. '.txt'
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
                        local profile = phoneData[myNick]
                        if profile then
                            local text_cp1251 = u8:decode(text_utf8)
                            
                            if globalSettings.lastNewsText ~= text_cp1251 then
                                globalSettings.lastNewsText = text_cp1251
                                save_all_data()
                                
                                local sys_num = "System_News"
                                if not profile.contacts[sys_num] then profile.contacts[sys_num] = "Уведомления" end
                                addSmsToHistory(profile, sys_num, "them", text_cp1251, os.time())

                                if activeContact ~= sys_num or not UI.windowState[0] then
                                    for _, p in pairs(phoneData) do p.unread[sys_num] = true end
                                    if globalSettings.useScreenNotifications and not globalSettings.dndMode then
                                        Sys.activeNotification = {
                                            number = sys_num,
                                            name = "Уведомления",
                                            text = text_cp1251,
                                            time = os.clock()
                                        }
                                    end
                                end
                                save_all_data()
                                if activeContact == sys_num then UI.scrollToBottom = true end
                                needSortContacts = true
                            end
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

    while true do
        wait(0)
        
		if #groupSmsQueue > 0 and (os.clock() - lastGroupSmsTime > 1.5) then
            local task = table.remove(groupSmsQueue, 1)
            sampSendChat("/sms " .. task.num .. " " .. task.text)
            lastAttemptedGroupNum = task.num
            lastAttemptedGroupId = task.groupId
            lastGroupSmsTime = os.clock()
        end
		
        if os.clock() - lastNickCheck > 1.0 then
            lastNickCheck = os.clock()
            
            local currentOnline = {}
            local currentOnlineById = {}
            for i = 0, sampGetMaxPlayerId(false) do
                if sampIsPlayerConnected(i) then
                    local n = sampGetPlayerNickname(i)
                    if n then
                        currentOnline[n] = true
                        currentOnlineById[i] = n
                    end
                end
            end
            onlinePlayers = currentOnline
            onlinePlayersById = currentOnlineById

            if sampIsLocalPlayerSpawned() then
                local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if r then
                    local currentInGameNick = sampGetPlayerNickname(id)
                    if currentInGameNick ~= lastSeenNick then
                        lastSeenNick = currentInGameNick
                        
                        if currentInGameNick:find("_") and not currentInGameNick:match("^Mask_%d+$") then
                            actualPlayerNick = currentInGameNick
                            myNick = currentInGameNick
                            activeContact = nil
                            needSortContacts = true
                            
                            if not phoneData[myNick] then
                                phoneData[myNick] = { contacts = {}, history = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, groups = {} }
                                local m_hist = nil
                                for _, p in pairs(phoneData) do
                                    if p.history and p.history["System_News"] then m_hist = p.history["System_News"] break end
                                end
                                phoneData[myNick].history["System_News"] = m_hist or {}
                                phoneData[myNick].contacts["System_News"] = "Уведомления"
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
    if Macro.autoCleaning and id == 32700 then
        local tStr = tostring(title)
        local txtStr = tostring(text)
        
        if Macro.cleanStep == 2 and tStr:find("Сообщения") and not tStr:find("Последние") then
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
            
        elseif Macro.cleanStep == 3 and (tStr:find("Последние сообщения") or txtStr:find("Отправитель")) then
            Macro.cleanStep = 4
            lua_thread.create(function()
                wait(300)
                sampSendDialogResponse(id, 0, 0, "")
            end)
            return false
            
        elseif Macro.cleanStep == 4 and tStr:find("Сообщения") and not tStr:find("Последние") then
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
            
        elseif Macro.cleanStep == 5 and txtStr:find("действительно хотите удалить") then
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

    if Macro.autoGeo and id == 32700 then
        local tStr = tostring(title)
        local txtStr = tostring(text)
        local cleanTitle = tStr:gsub("{.-}", "")
        local cleanText = txtStr:gsub("{.-}", "")
        
        if Macro.geoStep == 2 and cleanTitle:find("Сообщения") and not cleanTitle:find("Последние") then
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
            
        elseif Macro.geoStep == 3 and (cleanTitle:find("Новое сообщение") or cleanText:find("Введите номер")) then
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
end

function samp.onServerMessage(color, text)
    if actualPlayerNick == "Default" or not phoneData[actualPlayerNick] then return end
    local profile = phoneData[actualPlayerNick]
    local ts = os.time()
    
    local plain_text = text:gsub("{%x%x%x%x%x%x}", "")
	
	if plain_text:find("Сообщение не отправлено%. Абонент вне зоны действия сети") then
        if lastAttemptedGroupId and lastAttemptedGroupNum and (os.clock() - lastGroupSmsTime < 2.0) then
            if profile.groups and profile.groups[lastAttemptedGroupId] then
                profile.groups[lastAttemptedGroupId].members[lastAttemptedGroupNum] = nil
                save_all_data()
                showSystemNotification(u8"Номер " .. lastAttemptedGroupNum .. u8" удален из группы (недоступен).", 3)
            end
        end
        return false
    end
    
    local is_incoming = plain_text:match("^%s*%[Телефон%] Входящий вызов%.%.%.")
    local out_match = plain_text:match("^%s*%[Телефон%] Исходящий вызов (%d+)%.%.%.")

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
    
    local geo_num = plain_text:match("^%| Геопозиция на номер (%d+) отправлена%.")
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
                    if not profile.contacts["Bank_System"] then profile.contacts["Bank_System"] = "Банк" end
                    addSmsToHistory(profile, "Bank_System", "them", full_text, os.time())
                    needSortContacts = true
                    if myNick == actualPlayerNick and activeContact ~= "Bank_System" or not UI.windowState[0] then
                        profile.unread["Bank_System"] = (type(profile.unread["Bank_System"]) == "number" and profile.unread["Bank_System"] or 0) + 1
                        if not profile.muted["Bank_System"] then
                            if globalSettings.useScreenNotifications and not globalSettings.dndMode then
                                Sys.activeNotification = { number = "Bank_System", name = "Банк", text = "Получена новая выписка с банковского счета.", time = os.clock() }
                            end
                        end
                    end
                    save_all_data()
                    if myNick == actualPlayerNick and activeContact == "Bank_System" then UI.scrollToBottom = true end
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
    
    local inc_str, inc_num, inc_text = clean_sms_text:match("^%s*SMS от (.-) %(тел%. (%d+)%): (.*)")
    if not inc_num then
        inc_num, inc_text = clean_sms_text:match("^%s*SMS от #?(%d+): (.*)")
        inc_str = ""
    end
    
    if inc_num and inc_text then
		local cmd, payload = inc_text:match("^!(GRP_[A-Z]+)%|(.*)")
        if cmd then
            if cmd == "GRP_INV" then
                local gId, gNums, gName = payload:match("^(%w+)%|([%d%,]+)%|(.*)")
                if gId then
                    if not profile.groups then profile.groups = {} end
                    if not profile.groups[gId] then
                        profile.groups[gId] = { name = gName, members = {}, history = {} }
                    end
                    for n in gNums:gmatch("%d+") do
                        profile.groups[gId].members[n] = true
                    end
                    profile.groups[gId].members[inc_num] = true
                    save_all_data()
                    needSortContacts = true
                end
            elseif cmd == "GRP_LV" then
                local gId = payload:match("^(%w+)")
                if gId and profile.groups and profile.groups[gId] then
                    profile.groups[gId].members[inc_num] = nil
                    save_all_data()
                end
            end
            return
        end

        local gId, real_text = inc_text:match("^#(%w+) (.*)")
        if gId and profile.groups and profile.groups[gId] then
            table.insert(profile.groups[gId].history, {sender = inc_num, msg = real_text, timestamp = ts})
            profile.unread[gId] = (type(profile.unread[gId]) == "number" and profile.unread[gId] or 0) + 1
            save_all_data()
            needSortContacts = true
            
            lastSmsPhone = inc_num
            lastSmsGroupId = gId
            lastSmsSysTime = os.clock()
            lastSmsIsDup = false
            lastSmsIsUnread = false
            
            if myNick == actualPlayerNick and activeContact == gId then UI.scrollToBottom = true end
            if not profile.muted[gId] and globalSettings.useScreenNotifications and not globalSettings.dndMode then
                Sys.activeNotification = { number = gId, name = profile.groups[gId].name, text = real_text, time = os.clock() }
            end
            if globalSettings.useScreenNotifications then return false else return end
        end

        local is_dup = false
        if is_unread and profile.history[inc_num] then
            local hist = profile.history[inc_num]
            local search_text = inc_text:gsub("%s*%.%.%.?%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            for i = #hist, math.max(1, #hist - 100), -1 do
                local h_text = hist[i].msg:gsub("^%s+", ""):gsub("%s+$", "")
                if h_text:sub(1, #search_text) == search_text then
                    is_dup = true
                    break
                end
            end
        end
        
        lastSmsPhone = inc_num
        lastSmsIsUnread = is_unread
        lastSmsIsDup = is_dup
        lastSmsSysTime = os.clock()
        
        if not is_dup then
            addSmsToHistory(profile, inc_num, "them", inc_text, ts)
            syncGlobalVerified(inc_num)
            needSortContacts = true
            if myNick ~= actualPlayerNick or activeContact ~= inc_num or not UI.windowState[0] then
                profile.unread[inc_num] = (type(profile.unread[inc_num]) == "number" and profile.unread[inc_num] or 0) + 1
                if not profile.muted[inc_num] then
                    if globalSettings.useScreenNotifications and not globalSettings.dndMode then
                        local cName = profile.contacts[inc_num] or ""
                        Sys.activeNotification = { number = inc_num, name = (cName == "" and inc_num or cName), text = inc_text, time = os.clock() }
                    end
                end
            end
            save_all_data()
            if myNick == actualPlayerNick and activeContact == inc_num then UI.scrollToBottom = true end
        end
        
        if is_unread and globalSettings.hideUnreadOnLogin then return false
        elseif globalSettings.useScreenNotifications then return false
        else
            local cName = profile.contacts[inc_num] or ""
            if cName ~= "" then
                local new_text = ""
                if inc_str ~= "" then
                    local safe_sender = inc_str:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
                    new_text = text:gsub("SMS от " .. safe_sender, "SMS от " .. cName)
                else
                    new_text = text:gsub("SMS от #" .. inc_num, "SMS от " .. cName)
                end
                return {color, new_text}
            end
            return 
        end
    end

    local out_str, out_num, out_text = clean_sms_text:match("^%s*SMS к (.-) %(тел%. (%d+)%): (.*)")
    if not out_num then
        out_num, out_text = clean_sms_text:match("^%s*SMS к #?(%d+): (.*)")
        out_str = ""
    end
    
    if out_num and out_text then
        local is_sys_grp = out_text:match("^!GRP_")
        local gId = out_text:match("^#(%w+) ")
        if is_sys_grp then return false end
        
        if gId and profile.groups and profile.groups[gId] then
            lastSmsPhone = out_num
            lastSmsGroupId = gId
            lastSmsSysTime = os.clock()
            lastSmsIsDup = false
            lastSmsIsUnread = false
            if globalSettings.useScreenNotifications then return false else return end
        end

        lastSmsPhone = out_num
        lastSmsGroupId = nil
        lastSmsIsUnread = false
        lastSmsIsDup = false
        lastSmsSysTime = os.clock()
        addSmsToHistory(profile, out_num, "me", out_text, ts)
        syncGlobalVerified(out_num)
        needSortContacts = true
        if myNick == actualPlayerNick and activeContact == out_num then UI.scrollToBottom = true end
        
        if globalSettings.useScreenNotifications then return false
        else
            local cName = profile.contacts[out_num] or ""
            if cName ~= "" then
                local new_text = ""
                if out_str ~= "" then
                    local safe_receiver = out_str:gsub("[%-%^%$%(%)%%%.%[%]%*%+%?]", "%%%1")
                    new_text = text:gsub("SMS к " .. safe_receiver, "SMS к " .. cName)
                else
                    new_text = text:gsub("SMS к #" .. out_num, "SMS к " .. cName)
                end
                return {color, new_text}
            end
            return 
        end
    end

    local continued_text = plain_text:match("^%.%.%.?%s*(.*)")
    if continued_text then
        if lastSmsPhone and (os.clock() - lastSmsSysTime <= 0.5) then
            if not lastSmsIsDup then
                local targetHist = nil
                if lastSmsGroupId and profile.groups and profile.groups[lastSmsGroupId] then
                    targetHist = profile.groups[lastSmsGroupId].history
                else
                    targetHist = profile.history[lastSmsPhone]
                end
                
                if targetHist and #targetHist > 0 then
                    local prev_msg = targetHist[#targetHist].msg
                    prev_msg = prev_msg:gsub("%s*%.%.%.?%s*$", "")
                    targetHist[#targetHist].msg = prev_msg .. " " .. continued_text
                    targetHist[#targetHist].bubbleSize = nil 
                    save_all_data()
                    local aContact = lastSmsGroupId or lastSmsPhone
                    if myNick == actualPlayerNick and activeContact == aContact then UI.scrollToBottom = true end
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
        local scale = globalSettings.uiScale or 1.0
        imgui.GetIO().FontGlobalScale = scale
        
        if not Sys.activeNotification then return end

        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY * 0.15), imgui.Cond.Always, imgui.ImVec2(0.5, 0.0))
        
        local profile = phoneData[actualPlayerNick]
        if not profile then return end
        
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
        imgui.PopStyleColor(22)
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
        local scale = globalSettings.uiScale or 1.0
        imgui.GetIO().FontGlobalScale = scale
        
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
    end
)
unreadIndicatorFrame.HideCursor = true

local newFrame = imgui.OnFrame(
    function() return UI.windowState[0] or UI.viewingImage ~= nil or UI.showGallery[0] end,
    function(player)
        local scale = globalSettings.uiScale or 1.0
        imgui.GetIO().FontGlobalScale = scale
        
        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        
        local sizeCond = UI.forceResize and imgui.Cond.Always or imgui.Cond.FirstUseEver
        imgui.SetNextWindowSize(imgui.ImVec2(750 * scale, 500 * scale), sizeCond)
        
        local profile = phoneData[myNick]
        if not profile then return end
        
        local active_theme = GetActiveTheme()
        ApplyTheme(active_theme, 0.95)
        
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 6.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.PopupRounding, 6.0 * scale)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8.0 * scale)
        
        if UI.showThemeEditor[0] then
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
                imgui.ColorPicker4("##Picker_"..curKey, ThemeEditor.temp[curKey], 
                    imgui.ColorEditFlags.AlphaBar + 
                    imgui.ColorEditFlags.DisplayHex + 
                    imgui.ColorEditFlags.DisplayRGB + 
                    imgui.ColorEditFlags.AlphaPreview)
                
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

        if imgui.Begin(u8"Мессенджер", UI.windowState, imgui.WindowFlags.NoCollapse) then

            if UI.requestLinkModal then
                imgui.OpenPopup("LinkConfirmModal")
                UI.requestLinkModal = false
            end
            
            if imgui.BeginPopupModal("LinkConfirmModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
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

            if UI.requestDeletePopup then
                imgui.OpenPopup("DeleteContactConfirm")
                UI.requestDeletePopup = false
            end

            if imgui.BeginPopupModal("DeleteContactConfirm", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
                imgui.Text(u8"Подтверждение")
                if UI.contactToDelete then
                    local rawName = profile.contacts[UI.contactToDelete] or ""
                    
                    local cName = ""
                    if UI.contactToDelete == "Bank_System" then
                        cName = u8"Банк"
                    elseif UI.contactToDelete == "System_News" then
                        cName = u8"Уведомления"
                    else
                        cName = (rawName == "" and "#" .. UI.contactToDelete or u8(rawName) .. " (" .. UI.contactToDelete .. ")")
                    end
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
                        profile.history[UI.contactToDelete] = nil
                        profile.calls[UI.contactToDelete] = nil
                        profile.unread[UI.contactToDelete] = nil
                        if profile.muted then profile.muted[UI.contactToDelete] = nil end
                        if profile.drafts then profile.drafts[UI.contactToDelete] = nil end
                        if activeContact == UI.contactToDelete then activeContact = nil end
                        save_all_data()
                        needSortContacts = true
                    end
                    UI.contactToDelete = nil
                    imgui.CloseCurrentPopup()
                end
                imgui.SameLine()
                if imgui.Button(u8"Отмена", imgui.ImVec2(btnWidth, 0)) then
                    UI.contactToDelete = nil
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end
            
            if UI.requestContactModal then
                imgui.OpenPopup("ContactModal")
                UI.requestContactModal = false
            end
            
            if imgui.BeginPopupModal("ContactModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
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
                        if nick:lower():find(lower_input, 1, true) and nick ~= current_nick_input then
                            table.insert(suggestions, nick)
                        end
                    end
                    if #suggestions > 0 then
                        table.sort(suggestions)
                        local item_height = imgui.GetTextLineHeightWithSpacing()
                        local padding_y = imgui.GetStyle().WindowPadding.y
                        local visible_items = math.min(#suggestions, 5)
                        local list_height = visible_items * item_height + padding_y * 2
                        imgui.BeginChild("SuggestList", imgui.ImVec2(0, list_height), true)
                        for _, s_nick in ipairs(suggestions) do
                            if imgui.Selectable(s_nick) then
                                ffi.copy(UI.inputContactNick, s_nick)
                            end
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
                        if nick ~= "" then
                            profile.nicknames[number] = nick
                        else
                            profile.nicknames[number] = nil
                        end
                        save_all_data()
                        needSortContacts = true
                        imgui.CloseCurrentPopup()
                    end
                end
                imgui.SameLine()
                if imgui.Button(u8"Отмена", imgui.ImVec2(btnW, 0)) then
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end

            if imgui.BeginPopupModal("SettingsModal", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoTitleBar) then
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
                            needSortContacts = true
                        end
                    end
                    imgui.EndCombo()
                end
                imgui.PopItemWidth()
                
                imgui.SameLine(btnOffset)
                if imgui.Button(u8"Удалить профиль##char", imgui.ImVec2(130 * scale, 0)) then
                    local actualNick = "Default"
                    local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                    if r then actualNick = sampGetPlayerNickname(id) end
                    
                    phoneData[myNick] = nil
                    
                    if myNick == actualNick and actualNick:find("_") and not actualNick:match("^Mask_%d+$") then
						phoneData[actualNick] = { contacts = {}, history = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {} }
						local m_hist = nil
						for nick, p in pairs(phoneData) do if nick ~= actualNick and p.history["System_News"] then m_hist = p.history["System_News"] break end end
						phoneData[actualNick].history["System_News"] = m_hist or {}
						phoneData[actualNick].contacts["System_News"] = "Уведомления"
					else
						if actualNick:find("_") and not actualNick:match("^Mask_%d+$") then
							myNick = actualNick
							if not phoneData[myNick] then
								phoneData[myNick] = { contacts = {}, history = {}, unread = {}, nicknames = {}, muted = {}, drafts = {}, calls = {}, groups = {} }
								local m_hist = nil
								for nick, p in pairs(phoneData) do if nick ~= myNick and p.history["System_News"] then m_hist = p.history["System_News"] break end end
								phoneData[myNick].history["System_News"] = m_hist or {}
								phoneData[myNick].contacts["System_News"] = "Уведомления"
							end
						else
                            local local_any = next(phoneData)
                            if local_any then myNick = local_any else myNick = "Default" end
                        end
                    end
                    
                    profile = phoneData[myNick]
                    activeContact = nil
                    needSortContacts = true
                    save_all_data()
                end
                
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                imgui.Text(u8"Внешний вид:")
                
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
                
                if globalSettings.theme > #themes then
                    imgui.SameLine()
                    if imgui.Button(u8"Удалить тему") then
                        table.remove(globalSettings.customThemes, globalSettings.theme - #themes)
                        globalSettings.theme = 1
                        save_all_data()
                    end
                end
                
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
                
                imgui.SameLine()
                if imgui.Button(u8"Сбросить размер") then
                    globalSettings.uiScale = 1.0
                    UI.forceResize = true
                    save_all_data()
                end
                
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
                
                imgui.PushItemWidth(150 * scale)
                imgui.InputTextWithHint("##CmdInput", u8"Команда", UI.inputOpenCommand, 64)
                if imgui.Button(u8"Сохранить команду и перезагрузить") then
                    globalSettings.openCommand = ffi.string(UI.inputOpenCommand)
                    save_all_data()
                    thisScript():reload()
                end
                imgui.PopItemWidth()

                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                imgui.Text(u8"Дополнительные функции:")
                imgui.Spacing()
                
                UI.settingHideUnread[0] = globalSettings.hideUnreadOnLogin or false
                if imgui.Checkbox(u8"Скрывать непрочитанные при входе", UI.settingHideUnread) then
                    globalSettings.hideUnreadOnLogin = UI.settingHideUnread[0]
                    save_all_data()
                end
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Скрывать из чата оффлайн-сообщения (UNREAD SMS), которые приходят при авторизации. Они всё равно будут сохранены в историю.") end

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
                if imgui.IsItemHovered() then imgui.SetTooltip(u8"Проверять наличие новых версий скрипта при запуске.") end
                
                imgui.Spacing()
                imgui.Separator()
                imgui.Spacing()
                
                local dbSize = 0
                if file_exists(masterFile) then
                    dbSize = lfs.attributes(masterFile, "size") or 0
                end
                
                local sizeText = ""
                if dbSize < 1024 then
                    sizeText = string.format("%d B", dbSize)
                elseif dbSize < 1048576 then
                    sizeText = string.format("%.2f KB", dbSize / 1024.0)
                else
                    sizeText = string.format("%.2f MB", dbSize / 1048576.0)
                end
                
                local btnWidth = 100 * scale
                local currentY = imgui.GetCursorPosY()
                
                imgui.AlignTextToFramePadding()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1.0), u8"Размер базы данных: " .. sizeText)
                
                imgui.SameLine()
                local availRight = imgui.GetContentRegionAvail().x
                if availRight > btnWidth then
                    imgui.SetCursorPosX(imgui.GetCursorPosX() + availRight - btnWidth)
                end
                
                imgui.SetCursorPosY(currentY)
                if imgui.Button(u8"Закрыть", imgui.ImVec2(btnWidth, 0)) then
                    imgui.CloseCurrentPopup()
                end
                
                imgui.EndPopup()
            end

            imgui.Columns(2, "PhoneColumns", false)
            imgui.SetColumnWidth(0, 280 * scale) 

            local leftAvailW = imgui.GetContentRegionAvail().x

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
                        -- Перебираем текстдравы с конца, чтобы кликнуть по верхнему слою (кнопке)
                        for td = 2304, 0, -1 do
                            if sampTextdrawIsExists(td) then
                                local posX, posY = sampTextdrawGetPos(td)
                                -- Ищем иконку сообщений в доке (правый нижний угол)
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
            
            imgui.Spacing()

            if needSortContacts then
                cachedSortedContacts = {}
                
                local uniqueNumbers = {}
                for num, _ in pairs(profile.contacts) do uniqueNumbers[num] = true end
                if profile.history then
                    for num, _ in pairs(profile.history) do uniqueNumbers[num] = true end
                end
                if profile.calls then
                    for num, _ in pairs(profile.calls) do uniqueNumbers[num] = true end
                end
                if profile.history and profile.history["Bank_System"] then uniqueNumbers["Bank_System"] = true end
                if profile.history and profile.history["System_News"] then uniqueNumbers["System_News"] = true end
                if profile.groups then
                    for gId, _ in pairs(profile.groups) do uniqueNumbers[gId] = true end
                end
                
                for num, _ in pairs(uniqueNumbers) do
                    local isGroup = profile.groups and profile.groups[num]
                    local name = isGroup and profile.groups[num].name or (profile.contacts[num] or "")
                    local hasName = (name ~= "")
                    local hist = isGroup and profile.groups[num].history or (profile.history and profile.history[num])
                    local hasHistory = (hist and #hist > 0)
                    local calls = profile.calls and profile.calls[num]
                    local hasCalls = (calls and #calls > 0)
                    local isSystem = (num == "Bank_System" or num == "System_News")
                    
                    if hasName or hasHistory or hasCalls or isSystem or isGroup then
                        local last_ts = 0
                        if hasHistory then
                            last_ts = hist[#hist].timestamp or 0
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
                    if num == "Bank_System" then 
                        localDisplay = cp1251_lower(u8:decode(u8"Банк"))
                    elseif num == "System_News" then 
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
                        save_all_data()
                        is_unread = false
                    end
                    
                    local isGroup = profile.groups and profile.groups[num]
                    local displayName = ""
                    if num == "Bank_System" then
                        displayName = u8"Банк"
                    elseif num == "System_News" then
                        displayName = u8"Уведомления"
                    elseif isGroup then
                        displayName = u8"[Группа] " .. u8(profile.groups[num].name)
                    else
                        displayName = (name == "" and "#" .. num or u8(name) .. " (" .. num .. ")")
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
                            if activeContact then
                                local currentText = ffi.string(UI.inputMessage)
                                if currentText ~= "" then
                                    profile.drafts[activeContact] = u8:decode(currentText)
                                else
                                    profile.drafts[activeContact] = nil
                                end
                            end
                            activeContact = num
                            UI.showCallHistory = false
                            UI.viewingCallIndex = 0
                            local draftText = profile.drafts[num] or ""
                            ffi.copy(UI.inputMessage, u8(draftText))
                            UI.showMessageSearch = false
                            UI.inputSearchMessage[0] = 0
                        end
                        UI.scrollToBottom = true
                        UI.requestFocus = true
                    end
                    
                    if imgui.BeginPopupContextItem("ContactPopup_" .. num) then
                        if profile.tagger and profile.tagger[num] then
                            if imgui.Selectable(u8"Открыть Tagger (Social)") then
                                local url = "https://tagger.gambit-rp.com/" .. profile.tagger[num]
                                shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
                            end
                            imgui.Separator()
                        end
                        
                        if num == "System_News" then
                            if imgui.Selectable(u8"Очистить историю") then
                                local nhist = profile.history[num]
                                if nhist then
                                    for k in pairs(nhist) do nhist[k] = nil end
                                end
                                for _, p in pairs(phoneData) do
                                    if p.unread then p.unread[num] = nil end
                                    if p.muted then p.muted[num] = nil end
                                    if p.drafts then p.drafts[num] = nil end
                                end
                                if activeContact == num then activeContact = nil end
                                save_all_data()
                                needSortContacts = true
                            end
                        elseif num == "Bank_System" then
                            local muteText = profile.muted and profile.muted[num] and u8"Включить уведомления" or u8"Отключить уведомления"
                            if imgui.Selectable(muteText) then
                                if not profile.muted then profile.muted = {} end
                                profile.muted[num] = not profile.muted[num]
                                if profile.muted[num] and Sys.activeNotification and Sys.activeNotification.number == num then
                                    Sys.activeNotification = nil
                                end
                                save_all_data()
                            end
                            imgui.Separator()
                            if imgui.Selectable(u8"Очистить историю") then
                                profile.history[num] = nil
                                profile.unread[num] = nil
                                if profile.muted then profile.muted[num] = nil end
                                if profile.drafts then profile.drafts[num] = nil end
                                if activeContact == num then activeContact = nil end
                                save_all_data()
                                needSortContacts = true
                            end
                        elseif isGroup then
                            local muteText = profile.muted and profile.muted[num] and u8"Включить уведомления" or u8"Отключить уведомления"
                            if imgui.Selectable(muteText) then
                                if not profile.muted then profile.muted = {} end
                                profile.muted[num] = not profile.muted[num]
                                if profile.muted[num] and Sys.activeNotification and Sys.activeNotification.number == num then
                                    Sys.activeNotification = nil
                                end
                                save_all_data()
                            end
                            imgui.Separator()
                            if imgui.Selectable(u8"Очистить историю") then
                                profile.groups[num].history = {}
                                profile.unread[num] = nil
                                save_all_data()
                                needSortContacts = true
                            end
                            if imgui.Selectable(u8"Удалить группу") then
                                for memNum, _ in pairs(profile.groups[num].members) do
                                    table.insert(groupSmsQueue, {num = memNum, text = "!GRP_LV|" .. num, groupId = num})
                                end
                                profile.groups[num] = nil
                                profile.unread[num] = nil
                                if profile.muted then profile.muted[num] = nil end
                                if profile.drafts then profile.drafts[num] = nil end
                                if activeContact == num then activeContact = nil end
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
                                if profile.muted[num] and Sys.activeNotification and Sys.activeNotification.number == num then
                                    Sys.activeNotification = nil
                                end
                                save_all_data()
                            end
                            imgui.Separator()
                            if imgui.Selectable(u8"Очистить историю") then
                                profile.history[num] = nil
                                profile.calls[num] = nil
                                profile.unread[num] = nil
                                save_all_data()
                                needSortContacts = true
                            end
                            if imgui.Selectable(u8"Удалить контакт") then
                                profile.contacts[num] = nil
                                profile.history[num] = nil
                                profile.calls[num] = nil
                                profile.unread[num] = nil
                                if profile.muted then profile.muted[num] = nil end
                                if profile.drafts then profile.drafts[num] = nil end
                                if activeContact == num then activeContact = nil end
                                save_all_data()
                                needSortContacts = true
                            end
                        end
                        imgui.EndPopup()
                    end
                    
                    local active_theme_render = GetActiveTheme()
                    
                    local dl = imgui.GetWindowDrawList()
                    local bg_color = imgui.ImVec4(0, 0, 0, 0)
                    
                    local is_muted = profile.muted and profile.muted[num]
                    
                    if is_selected then
                        bg_color = active_theme_render.me
                    elseif is_hovered then
                        bg_color = imgui.ImVec4(active_theme_render.me.x, active_theme_render.me.y, active_theme_render.me.z, 0.6)
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
                    local hist = isGroup and profile.groups[num].history or (profile.history and profile.history[num])
                    local calls = profile.calls and profile.calls[num]
                    
                    local last_sms_ts = (hist and #hist > 0) and hist[#hist].timestamp or 0
                    local last_call_ts = (calls and #calls > 0) and calls[#calls].timestamp or 0
                    
                    if last_sms_ts > 0 or last_call_ts > 0 then
                        if last_sms_ts >= last_call_ts then
                            time_str = formatMessageTime(last_sms_ts)
                            if num == "Bank_System" then
                                snippet = u8"Вам пришла выписка из банка"
                            elseif num == "System_News" then
                                local prefix = (hist[#hist].sender == "me") and u8"Вы: " or ""
                                snippet = prefix .. u8(hist[#hist].msg):gsub("\n", " ")
                            else
                                local prefix = (hist[#hist].sender == "me") and u8"Вы: " or ""
                                snippet = prefix .. u8(hist[#hist].msg):gsub("\n", " ")
                            end
                        else
                            time_str = formatMessageTime(last_call_ts)
                            snippet = u8"[Звонок]"
                        end
                    else
                        snippet = u8"Нет сообщений"
                    end
                    
                    local name_color = imgui.ImVec4(1, 1, 1, 1)
                    dl:AddText(imgui.ImVec2(p_min.x + 10, p_min.y + 6), imgui.GetColorU32Vec4(name_color), displayName)
                    
                    local nextOffset = 10 + imgui.CalcTextSize(displayName).x
                    
                    local isVerified = (num == "Bank_System" or num == "System_News" or (profile.verified and profile.verified[num]))
                    if isVerified then
                        local badge_center = imgui.ImVec2(p_min.x + nextOffset + (12 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                        DrawVerificationBadge(dl, badge_center, 6.0 * scale, scale)
                        
                        local ret_pos = imgui.GetCursorScreenPos()
                        imgui.SetCursorScreenPos(imgui.ImVec2(badge_center.x - 8, badge_center.y - 8))
                        imgui.InvisibleButton("BadgeHint_" .. num, imgui.ImVec2(16, 16))
                        if imgui.IsItemHovered() then
                            imgui.SetTooltip(u8"Этот контакт официально верифицирован.")
                        end
                        imgui.SetCursorScreenPos(ret_pos)
                        
                        nextOffset = nextOffset + (22 * scale)
                    end

                    if profile.muted and profile.muted[num] then
                        local mutedText = u8" [Мут]"
                        local mutedColor = active_theme_render.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0)
                        dl:AddText(imgui.ImVec2(p_min.x + nextOffset, p_min.y + 6), imgui.GetColorU32Vec4(mutedColor), mutedText)
                        nextOffset = nextOffset + imgui.CalcTextSize(mutedText).x
                    end
                    
                    if profile.nicknames and profile.nicknames[num] then
                        local contactNick = profile.nicknames[num]
                        if onlinePlayers[contactNick] then
                            local circle_center = imgui.ImVec2(p_min.x + nextOffset + (8 * scale), p_min.y + (6 * scale) + imgui.GetTextLineHeight() / 2)
                            local onlineCol = active_theme_render.online or imgui.ImVec4(0.2, 0.8, 0.2, 1.0)
                            dl:AddCircleFilled(circle_center, 4.0 * scale, imgui.GetColorU32Vec4(onlineCol))
                        end
                    end
                    
                    local time_w = imgui.CalcTextSize(time_str).x
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
                        
                        local is_muted = profile.muted and profile.muted[num]
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

            imgui.NextColumn()

            if activeContact then
                local isGroup = profile.groups and profile.groups[activeContact]
                local contactName = ""
                if activeContact == "Bank_System" then
                    contactName = u8"Банк"
                elseif activeContact == "System_News" then
                    contactName = u8"Уведомления"
                elseif isGroup then
                    contactName = u8"[Группа] " .. u8(profile.groups[activeContact].name)
                else
                    local rawName = profile.contacts[activeContact] or ""
                    contactName = (rawName == "" and "#" .. activeContact or u8(rawName))
                end
                
                local isSystemChat = (activeContact == "Bank_System" or activeContact == "System_News")
                
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
                    
                    local ret_pos = imgui.GetCursorScreenPos()
                    imgui.SetCursorScreenPos(imgui.ImVec2(badge_center.x - 8, badge_center.y - 8))
                    imgui.InvisibleButton("BadgeHintHead", imgui.ImVec2(16, 16))
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip(u8"Этот контакт официально верифицирован.")
                    end
                    imgui.SetCursorScreenPos(ret_pos)
                    
                    imgui.SetCursorPosX(imgui.GetCursorPosX() + (b_radius * 2) + (2 * scale))
                end

                if profile.muted and profile.muted[activeContact] then
                    imgui.SameLine(0, 4 * scale)
                    local actTheme = GetActiveTheme()
                    imgui.TextColored(actTheme.muted or imgui.ImVec4(0.6, 0.6, 0.6, 1.0), u8"[Мут]")
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
                    
                    local totalRightBtnsWidth = searchBtnWidth + geoBtnWidth + callHistBtnWidth + galBtnWidth + (spaceX * 3)
                    
                    local right_edge = imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x
                    imgui.SameLine()
                    if right_edge - totalRightBtnsWidth > imgui.GetCursorPosX() then
                        imgui.SetCursorPosX(right_edge - totalRightBtnsWidth)
                    end
                    
                    if imgui.Button(callHistBtnText) then
                        UI.showCallHistory = not UI.showCallHistory
                        UI.viewingCallIndex = 0
                        UI.showMessageSearch = false
                        UI.showGallery[0] = false
                    end
                    
                    imgui.SameLine(0, spaceX)
                    if imgui.Button(galBtnText) then
                        UI.showGallery[0] = not UI.showGallery[0]
                        UI.showCallHistory = false
                        UI.showMessageSearch = false
                    end
                    
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
                    
                    imgui.SameLine(0, spaceX)
                    if imgui.Button(geoBtnText) then
                        Macro.targetGeoNumber = tostring(activeContact):match("%d+")
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
                else
                    local searchBtnText = u8"Поиск"
                    local framePadX = imgui.GetStyle().FramePadding.x
                    local searchBtnWidth = imgui.CalcTextSize(searchBtnText).x + (framePadX * 2.0)
                    
                    imgui.SameLine()
                    local availRight = imgui.GetContentRegionAvail().x
                    if availRight > searchBtnWidth then
                        imgui.SetCursorPosX(imgui.GetCursorPosX() + availRight - searchBtnWidth)
                    end
                    
                    if imgui.Button(searchBtnText) then
                        UI.showMessageSearch = not UI.showMessageSearch
                        if UI.showMessageSearch then 
                            UI.requestFocusSearch = true 
                        else 
                            UI.inputSearchMessage[0] = 0 
                        end
                    end
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
                                end
                                if imgui.BeginPopupContextItem("CallCtx_" .. i) then
                                    if imgui.Selectable(u8"Удалить") then
                                        deleteCallIndex = i
                                    end
                                    imgui.EndPopup()
                                elseif imgui.IsItemHovered() then
                                    imgui.SetTooltip(u8"ПКМ — удалить звонок")
                                end
                                imgui.PopID()
                            end
                        else
                            imgui.TextDisabled(u8"Нет записанных звонков с этим контактом.")
                        end
                    else
                        if imgui.Button(u8"<- Назад к списку звонков") then
                            UI.viewingCallIndex = 0
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
                    imgui.BeginChild("ChatHistory", imgui.ImVec2(0, -40 * scale), true)
                    
                    local currentHistory = isGroup and profile.groups[activeContact].history or profile.history[activeContact]
                    local deleteMsgIndex = nil
                    
                    if currentHistory then
                        local last_date_str = ""
                        local active_theme = GetActiveTheme()
                        
                        local scrollY = imgui.GetScrollY()
                        local windowH = imgui.GetWindowHeight()
                        local culling_buffer = 200 * scale
                        
                        local sMsgText = cp1251_lower(u8:decode(ffi.string(UI.inputSearchMessage)))
                        local isMsgSearching = UI.showMessageSearch and sMsgText ~= ""
                        
                        for index, msgData in ipairs(currentHistory) do
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
                                
                                local sName = nil
                                local isVer = false
                                if isGroup and msgData.sender ~= "me" then
                                    sName = profile.contacts[msgData.sender]
                                    sName = (sName and sName ~= "") and sName or msgData.sender
                                    isVer = profile.verified and profile.verified[msgData.sender]
                                end
                                
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

                                if not msgData.bubbleSize or msgData.urlsStr ~= urlsStr or msgData.loadedStr ~= loadedStr then
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
                                    
                                    local nameTextSize = imgui.ImVec2(0, 0)
                                    if sName then
                                        nameTextSize = imgui.CalcTextSize(u8(tostring(sName)))
                                        if isVer then nameTextSize.x = nameTextSize.x + 16 * scale end
                                        b_width = math.max(b_width, nameTextSize.x)
                                    end
                                    
                                    local b_height = padding.y * 1.5 + timeSize.y
                                    if textToDisplay ~= "" then
                                        b_height = b_height + msgTextSize.y + 5
                                    end
                                    if sName then
                                        b_height = b_height + nameTextSize.y + 2 * scale
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
                                    local cursorX = imgui.GetCursorPosX()

                                    if msgData.sender == "me" then
                                        cursorX = windowWidth - bubbleSize.x - 20
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
                                        imgui.SetTooltip(u8"ПКМ — управление сообщением")
                                    end

                                    local currentOffset = bubble_start_y + padding.y

                                    if sName then
                                        imgui.SetCursorPos(imgui.ImVec2(cursorX + padding.x, currentOffset))
                                        local hash = 0
                                        for i = 1, #msgData.sender do hash = (hash + msgData.sender:byte(i)) % 5 end
                                        local colors = {
                                            imgui.ImVec4(0.9, 0.35, 0.35, 1.0),
                                            imgui.ImVec4(0.25, 0.75, 0.45, 1.0),
                                            imgui.ImVec4(0.35, 0.55, 0.95, 1.0),
                                            imgui.ImVec4(0.8, 0.4, 0.8, 1.0),
                                            imgui.ImVec4(0.95, 0.65, 0.25, 1.0)
                                        }
                                        imgui.TextColored(colors[hash + 1], u8(tostring(sName)))
                                        if isVer then
                                            imgui.SameLine(0, 4 * scale)
                                            local dl = imgui.GetWindowDrawList()
                                            local c_pos = imgui.GetCursorScreenPos()
                                            local b_radius = 5.5 * scale
                                            local badge_center = imgui.ImVec2(c_pos.x + b_radius, c_pos.y + (imgui.GetTextLineHeight() / 2))
                                            DrawVerificationBadge(dl, badge_center, b_radius, scale)
                                        end
                                        currentOffset = currentOffset + imgui.GetTextLineHeight() + 2 * scale
                                    end

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
                        
                        if deleteMsgIndex then
                            table.remove(profile.history[activeContact], deleteMsgIndex)
                            save_all_data()
                            needSortContacts = true
                        end
                    end
                    
                    imgui.Spacing()
                    
                    if UI.scrollToBottom then
                        imgui.SetScrollY(imgui.GetScrollMaxY() + 999999)
                        UI.scrollToBottom = false
                    end
                    
                    imgui.EndChild()
                end
                
                if activeContact == "Bank_System" or activeContact == "System_News" then
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
                        
                        if imgui.InputTextWithHint("##MessageInput", u8"Напишите сообщение...", UI.inputMessage, 512, imgui.InputTextFlags.EnterReturnsTrue) then
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

            imgui.Columns(1)
            imgui.End()
        end
        
		if UI.showGallery[0] then
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
                                imgui.SetTooltip(u8"ЛКМ - вставить ссылку | ПКМ - удалить")
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
		
        if UI.viewingImage then
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
        
        imgui.PopStyleVar(4)
        imgui.PopStyleColor(20) 
        if UI.forceResize then UI.forceResize = false end
    end
)

function sendMessage(number)
    local text = u8:decode(ffi.string(UI.inputMessage))
    if text ~= "" then
        local profile = phoneData[myNick]
        local isGroup = profile and profile.groups and profile.groups[number]
        
        if isGroup then
            table.insert(profile.groups[number].history, {sender = "me", msg = text, timestamp = os.time()})
            for memNum, _ in pairs(profile.groups[number].members) do
                table.insert(groupSmsQueue, {num = memNum, text = "#" .. number .. " " .. text, groupId = number})
            end
            save_all_data()
            needSortContacts = true
        else
            sampSendChat("/sms " .. number .. " " .. text)
        end
        
        UI.inputMessage[0] = 0
        if profile and profile.drafts then
            profile.drafts[number] = nil
        end
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
