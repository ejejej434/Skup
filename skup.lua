script_name("LMMR")
script_author("major")
script_version("1.8.2")

local imgui_status, imgui = pcall(require, 'mimgui')
local encoding_status, encoding = pcall(require, 'encoding')
local ffi = require('ffi')
local sampev_status, sampev = pcall(require, 'samp.events')
local json = pcall(require, "json") and require("json") or {
     encode = encodeJson,
     decode = decodeJson
}

if not imgui_status then
     print("Ошибка: mimgui не установлен!")
    return
end

if encoding_status then
    encoding.default = 'CP1251'
end
local u8 = encoding_status and encoding.UTF8 or function(str) return str end

local configDir = getWorkingDirectory() .. '/config/'
local filePath = configDir .. 'main.json'
local dbPath = configDir .. 'items_db.json'
local logsPath = configDir .. 'logs_db.json'

if not doesDirectoryExist(configDir) then
     createDirectory(configDir)
end

local function ru_lower(str)
    local res = {}
    for i = 1, #str do
        local b = string.byte(str, i)
        if b >= 65 and b <= 90 then 
            res[i] = string.char(b + 32)
        elseif b >= 192 and b <= 223 then 
            res[i] = string.char(b + 32)
        elseif b == 168 then 
            res[i] = string.char(184) 
        else
            res[i] = string.char(b)
        end
    end
    return table.concat(res)
end

local function safe_copy(dest, src, max_len)
    if src == nil then src = "" end
    local str = tostring(src)
    if #str >= max_len then
        str = string.sub(str, 1, max_len - 1)
    end
    ffi.copy(dest, str)
end

local isRunning = false
local isScanning = false
local stopProcess = false
local CentralGlMenu = imgui.new.bool(false)
local show_custom_lavka = imgui.new.bool(false)
local active_preset_name = ""
local currentTab = 1
local open_add_modal = false
local editIndex = -1

local storage = {
    settings = {
         win_W = 950,
         win_H = 600,
         accent = {0.14, 0.45, 0.90},
         background = {0.07, 0.07, 0.08},
         saved_key = "",
         show_btn = false,
         btn_color = {0.14, 0.45, 0.90},
         btn_size = 55.0,
         global_delay = 1200,
         menu_opacity = 1.0
      },
    items = {},
    profiles = {}
}

local vars = {}
local logs = {}
local log_dates = {}
local selected_date = ""

local item_db = {}
local filtered_cache = {}
local last_search = nil

local win_posX = imgui.new.float(-1)
local win_posY = imgui.new.float(-1)
local btn_posX = imgui.new.float(-1)
local btn_posY = imgui.new.float(-1)

local is_btn_dragging = false
local is_win_dragging = false
local global_drag_active = false 

local script_keys = (function() local _A={ {75,57,70,50,65,49,66,56,67,55,68,54,69,53,71,52}, {72,51,74,50,75,49,76,57,77,56,78,55,80,54,81,53}, {82,52,83,53,84,54,85,55,86,56,87,57,88,49,89,50}, {90,51,65,52,66,53,67,54,68,55,69,56,70,57,71,48}, {81,49,87,50,69,51,82,52,84,53,89,54,85,55,73,56}, {79,57,80,48,65,49,83,50,68,51,70,52,71,53,72,54}, {74,55,75,56,76,57,90,48,88,49,67,50,86,51,66,52}, {78,53,77,54,81,55,87,56,69,57,82,48,84,49,89,50}, {85,51,73,52,79,53,80,54,65,55,83,56,68,57,70,48}, {71,49,72,50,74,51,75,52,76,53,90,54,88,55,67,56} } local _B={} for _C=1,#_A do local _D="" for _E=1,#_A[_C] do _D=_D..string.char(_A[_C][_E]) end _B[_C]=_D end return _B end)()

local isAuthorized = false
local authKeyBuffer = imgui.new.char[256]("")
local authError = false

local searchBuffer = imgui.new.char[256]("")
local currentPage = 1
local itemsPerPage = 100 

local addName = imgui.new.char[256]("")
local addId = imgui.new.char[64]("")
local addPrice = imgui.new.char[64]("")
local addAmount = imgui.new.char[64]("1")
local addIsAccessory = imgui.new.bool(false)

local profileNameBuffer = imgui.new.char[256]("")

local win_W = imgui.new.float(storage.settings.win_W)
local win_H = imgui.new.float(storage.settings.win_H)
local cAcc = imgui.new.float[3]({
    storage.settings.accent[1],
    storage.settings.accent[2],
    storage.settings.accent[3]
})
local cBg = imgui.new.float[3]({
    storage.settings.background[1],
    storage.settings.background[2],
    storage.settings.background[3]
})
local show_screen_btn = imgui.new.bool(storage.settings.show_btn)
local cBtn = imgui.new.float[3]({
    storage.settings.btn_color[1],
    storage.settings.btn_color[2],
    storage.settings.btn_color[3]
})
local btn_size = imgui.new.float(storage.settings.btn_size or 55.0)
local global_delay = imgui.new.int(storage.settings.global_delay or 1200)
local menu_opacity = imgui.new.float(storage.settings.menu_opacity or 1.0)

function load_logs()
    logs = {}
    log_dates = {}
    selected_date = ""
    
    if doesFileExist(logsPath) then
        local file = io.open(logsPath, "r")
        if file then
            local status, decoded = pcall(json.decode, file:read("*a"))
            file:close()
            if status and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    if type(k) == "string" and type(v) == "table" then
                        logs[k] = v
                    end
                end
            end
        end
    end
    
    for k, v in pairs(logs) do 
        table.insert(log_dates, tostring(k)) 
    end
    
    table.sort(log_dates, function(a, b) return tostring(a) > tostring(b) end)
    
    if #log_dates > 0 then 
        selected_date = log_dates[1] 
    end
end

function save_logs()
    local file = io.open(logsPath, "w")
    if file then
        file:write(json.encode(logs))
        file:close()
    end
end

function addLog(text)
    local today = os.date("%Y-%m-%d")
    if not logs[today] then
        logs[today] = {}
        table.insert(log_dates, 1, today)
        table.sort(log_dates, function(a, b) return tostring(a) > tostring(b) end)
        if selected_date == "" then selected_date = today end
    end
    table.insert(logs[today], 1, os.date("[%H:%M] ") .. text)
    if #logs[today] > 100 then table.remove(logs[today]) end
    save_logs()
end

if sampev_status then
    function sampev.onServerMessage(color, text)
        local lower_text = ru_lower(text)
        if lower_text:find("купил") or lower_text:find("продал") or lower_text:find("приобрел") or lower_text:find("успешно") then
            local clean_text = text:gsub("{%x%x%x%x%x%x}", "")
            addLog("{00FFFF}[СДЕЛКА] {FFFFFF}" .. clean_text)
        end
    end
    
    function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
        if dialogId == 9 and not isRunning then
            show_custom_lavka[0] = true
            return false
        end
    end
end

function load_item_db()
    item_db = {}
    last_search = nil 
    if doesFileExist(dbPath) then
        local file = io.open(dbPath, "r")
        if file then
            local status, decoded = pcall(json.decode, file:read("*a"))
            file:close()
            if status and type(decoded) == "table" then
                for _, v in ipairs(decoded) do
                     local decoded_name = u8:decode(v.name or "")
                     local decoded_id = u8:decode(v.id or "")
                     local dspName = decoded_id ~= "" and (decoded_name .. " [" .. decoded_id .. "]") or decoded_name
                     
                     table.insert(item_db, {
                        name = decoded_name,
                        lower_name = ru_lower(decoded_name),
                        id = decoded_id,
                        u8_name = u8(decoded_name),
                        u8_id = u8(decoded_id),
                        dsp_name = u8(dspName)
                    })
                 end
            end
        end
    end
end

function save_item_db()
    local file = io.open(dbPath, "w")
    if file then
        local t = {}
        for _, v in ipairs(item_db) do
             table.insert(t, {
                name = v.u8_name,
                id = v.u8_id
            })
         end
        file:write(json.encode(t))
        file:close()
    end
end

function runAutoScan()
    if isScanning then return end
    isScanning = true
    stopProcess = false
    lua_thread.create(function()
        if not sampIsDialogActive() then
            isScanning = false
            return
        end
        
        local seen_items = {}
        for _, v in ipairs(item_db) do
            if v.id ~= "" then
                seen_items[v.id] = true
            else
                seen_items[v.name] = true
            end
        end

        local pagesScanned = 0
        while sampIsDialogActive() and not stopProcess do
            local curId = sampGetCurrentDialogId()
            local text = sampGetDialogText()
            if not text or text == "" then break end
            
            local lines = {}
            for line in text:gmatch("[^\r\n]+") do
                 table.insert(lines, line)
             end
             
            local nextPageIdx = -1
            for i, line in ipairs(lines) do
                local cleanLine = line:gsub("{%x%x%x%x%x%x}", "")
                local rawName = cleanLine:match("^%s*([^\t]+)")
                if rawName then
                    rawName = rawName:match("^%s*(.-)%s*$")
                    if rawName == "Далее" or rawName:find(">>>") or rawName:find("Следующая") then
                        nextPageIdx = i - 1
                    elseif rawName ~= "Поиск предмета по названию / индексу"
                        and rawName ~= "Поиск по категории / Весь список |"
                        and rawName ~= "Назад"
                        and rawName ~= "Закрыть" then
                        
                        local namePart, idPart = rawName:match("^(.-)%s*%[(%d+)%]$")
                        if not namePart then
                            namePart, idPart = rawName:match("^(.-)%s*%((%d+)%)$")
                        end
                        
                        if namePart and idPart then
                            if not seen_items[idPart] then
                                 seen_items[idPart] = true
                                 local dspName = namePart .. " [" .. idPart .. "]"
                                 table.insert(item_db, {
                                    name = namePart, 
                                    lower_name = ru_lower(namePart), 
                                    id = idPart,
                                    u8_name = u8(namePart),
                                    u8_id = u8(idPart),
                                    dsp_name = u8(dspName)
                                })
                             end
                        else
                            if not seen_items[rawName] then
                                 seen_items[rawName] = true
                                 table.insert(item_db, {
                                    name = rawName, 
                                    lower_name = ru_lower(rawName), 
                                    id = "",
                                    u8_name = u8(rawName),
                                    u8_id = "",
                                    dsp_name = u8(rawName)
                                })
                             end
                        end
                    end
                end
            end
            pagesScanned = pagesScanned + 1
            if nextPageIdx ~= -1 then
                sampSendDialogResponse(curId, 1, nextPageIdx, "")
                wait(1200)
            else
                break
            end
        end
        save_item_db()
        last_search = nil 
        isScanning = false
    end)
end

function save_main_json()
    storage.items = {}
    for _, v in ipairs(vars) do
        table.insert(storage.items, {
            name = u8:decode(ffi.string(v.name)),
            id = u8:decode(ffi.string(v.id)),
            price = u8:decode(ffi.string(v.price)),
            amount = u8:decode(ffi.string(v.amount)),
            active = v.active[0],
            is_acc = v.is_acc[0]
        })
    end
    storage.settings.win_W = win_W[0]
    storage.settings.win_H = win_H[0]
    storage.settings.accent = {cAcc[0], cAcc[1], cAcc[2]}
    storage.settings.background = {cBg[0], cBg[1], cBg[2]}
    storage.settings.show_btn = show_screen_btn[0]
    storage.settings.btn_color = {cBtn[0], cBtn[1], cBtn[2]}
    storage.settings.btn_size = btn_size[0]
    storage.settings.global_delay = global_delay[0]
    storage.settings.menu_opacity = menu_opacity[0]
    
    storage.settings.win_posX = win_posX[0]
    storage.settings.win_posY = win_posY[0]
    storage.settings.pos_converted = true
    storage.settings.btn_posX = btn_posX[0]
    storage.settings.btn_posY = btn_posY[0]
    
    local file = io.open(filePath, "w")
    if file then
         file:write(json.encode(storage))
         file:close()
    end
end

function load_main_json()
    if not doesFileExist(filePath) then return end
    local file = io.open(filePath, "r")
    if file then
        local status, decoded = pcall(json.decode, file:read("*a"))
        file:close()
        if status and decoded then
            storage = decoded
            storage.profiles = decoded.profiles or {}
            
            win_W[0] = storage.settings.win_W or 950
            win_H[0] = storage.settings.win_H or 600
            
            local loaded_key = storage.settings.saved_key or ""
            isAuthorized = false
            for _, k in ipairs(script_keys) do
                if loaded_key == k then
                    isAuthorized = true
                    break
                end
            end
            if storage.settings.accent then
                 cAcc[0], cAcc[1], cAcc[2] = unpack(storage.settings.accent)
            end
            if storage.settings.background then
                 cBg[0], cBg[1], cBg[2] = unpack(storage.settings.background)
            end
            if storage.settings.show_btn ~= nil then
                 show_screen_btn[0] = storage.settings.show_btn
            end
            if storage.settings.btn_color then
                 cBtn[0], cBtn[1], cBtn[2] = unpack(storage.settings.btn_color)
            end
            if storage.settings.btn_size then
                 btn_size[0] = storage.settings.btn_size
            end
            if storage.settings.global_delay then
                 global_delay[0] = storage.settings.global_delay
            end
            if storage.settings.menu_opacity then
                 menu_opacity[0] = storage.settings.menu_opacity
            end
            
            vars = {}
            for _, item in ipairs(storage.items or {}) do
                table.insert(vars, {
                    name = imgui.new.char[256](string.sub(u8(item.name or ""), 1, 255)),
                    id = imgui.new.char[64](string.sub(u8(item.id or ""), 1, 63)),
                    price = imgui.new.char[64](string.sub(u8(item.price or "0"), 1, 63)),
                    amount = imgui.new.char[64](string.sub(u8(item.amount or "1"), 1, 63)),
                    active = imgui.new.bool(item.active or false),
                    is_acc = imgui.new.bool(item.is_acc or false),
                    str_name = u8(item.name or ""),
                    str_id = u8(item.id or ""),
                    str_price = u8(item.price or "0"),
                    str_amount = u8(item.amount or "1")
                })
            end
        end
    end
end

function runBuyingProcess()
    if #vars == 0 then return end
    
    local buy_queue = {}
    for _, v in ipairs(vars) do
        if v.active[0] then
            table.insert(buy_queue, {
                id = u8:decode(v.str_id),
                name = u8:decode(v.str_name),
                price = u8:decode(v.str_price),
                amount = u8:decode(v.str_amount),
                is_acc = v.is_acc[0]
            })
        end
    end
    
    if #buy_queue == 0 then return end

    isRunning = true
    stopProcess = false
    lua_thread.create(function()
        for i, item in ipairs(buy_queue) do
            if stopProcess then break end
            
            local query = (item.id ~= "" and item.id) or item.name
            local send_data = ""
            if item.is_acc then
                send_data = item.price .. "," .. item.amount
            else
                send_data = item.amount .. "," .. item.price
            end

            sampSendDialogResponse(9, 1, 1, "")
            wait(global_delay[0])
            if stopProcess then break end
            
            sampSendDialogResponse(10, 1, 0, "")
            wait(global_delay[0])
            if stopProcess then break end
            
            sampSendDialogResponse(909, 1, 0, query)
            wait(global_delay[0] + 600)
            if stopProcess then break end
            
            sampSendDialogResponse(11, 1, 0, send_data)
            wait(global_delay[0] + 500)
        end
        isRunning = false
    end)
end

imgui.OnInitialize(function()
    load_main_json()
    load_item_db()
    load_logs()
    local style = imgui.GetStyle()
    style.WindowPadding = imgui.ImVec2(0, 0)
    style.WindowRounding = 18.0
    style.ChildRounding = 15.0
    style.FrameRounding = 10.0
    style.PopupRounding = 15.0
    style.ScrollbarSize = 5.0
    style.WindowBorderSize = 0.0
    style.ItemSpacing = imgui.ImVec2(12, 12)
end)

imgui.OnFrame(function() return CentralGlMenu[0] or show_screen_btn[0] or show_custom_lavka[0] end, function()
    local resX = imgui.GetIO().DisplaySize.x
    local resY = imgui.GetIO().DisplaySize.y
    
    if win_W[0] > resX then win_W[0] = resX end
    if win_H[0] > resY then win_H[0] = resY end
    
    if imgui.IsMouseDragging(0, 5.0) then
        global_drag_active = true
    end

    if win_posX[0] == -1 then
        if storage.settings.pos_converted then
            win_posX[0] = storage.settings.win_posX or (resX / 2 - win_W[0] / 2)
            win_posY[0] = storage.settings.win_posY or (resY / 2 - win_H[0] / 2)
        else
            local cx = storage.settings.win_posX or (resX / 2)
            local cy = storage.settings.win_posY or (resY / 2)
            win_posX[0] = cx - (win_W[0] / 2)
            win_posY[0] = cy - (win_H[0] / 2)
            storage.settings.pos_converted = true
        end
    end
    if btn_posX[0] == -1 then
        btn_posX[0] = storage.settings.btn_posX or 10
        btn_posY[0] = storage.settings.btn_posY or (resY / 2)
    end
    
    if show_screen_btn[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(btn_posX[0], btn_posY[0]), imgui.Cond.Always)
        imgui.Begin("##FloatingButtonLMMR", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoMove)
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(cBtn[0], cBtn[1], cBtn[2], 0.85))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(cBtn[0], cBtn[1], cBtn[2], 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(cBtn[0] - 0.1, cBtn[1] - 0.1, cBtn[2] - 0.1, 1.0))
        
        local clicked = imgui.Button("LMMR", imgui.ImVec2(btn_size[0], btn_size[0]))
        
        if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
            is_btn_dragging = true
            btn_posX[0] = btn_posX[0] + imgui.GetIO().MouseDelta.x
            btn_posY[0] = btn_posY[0] + imgui.GetIO().MouseDelta.y
        end
        
        if clicked and not is_btn_dragging then
            CentralGlMenu[0] = not CentralGlMenu[0]
        end
        
        if imgui.IsMouseReleased(0) then
            if is_btn_dragging then
                save_main_json()
            end
            is_btn_dragging = false
        end
        
        imgui.PopStyleColor(3)
        imgui.End()
    end
    
    if show_custom_lavka[0] then
        local lavkaW = math.min(600, resX * 0.75)
        local lavkaH = math.min(380, resY * 0.7)

        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(cBg[0], cBg[1], cBg[2], menu_opacity[0]))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(cBg[0] + 0.03, cBg[1] + 0.03, cBg[2] + 0.03, menu_opacity[0] * 0.75))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 0.85))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(cAcc[0] - 0.1, cAcc[1] - 0.1, cAcc[2] - 0.1, 1.0))
        imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(cBg[0], cBg[1], cBg[2], 1.0))
        imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 0.3))
        
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 15.0)
        imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 10.0)
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8.0)

        imgui.SetNextWindowSize(imgui.ImVec2(lavkaW, lavkaH), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        
        imgui.Begin("##CustomLavka", show_custom_lavka, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
        
        local titleText = u8"УПРАВЛЕНИЕ ЛАВКОЙ"
        local titleW = imgui.CalcTextSize(titleText).x
        imgui.SetCursorPos(imgui.ImVec2((lavkaW - titleW) / 2, 15))
        imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), titleText)
        
        imgui.SetCursorPos(imgui.ImVec2(lavkaW - 35, 10))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.3, 0.3, 1.0))
        if imgui.Button("X", imgui.ImVec2(25, 25)) then
            show_custom_lavka[0] = false
            sampSendDialogResponse(9, 0, 0, "")
        end
        imgui.PopStyleColor(2)
        
        imgui.SetCursorPos(imgui.ImVec2(15, 45))
        local colW = (lavkaW / 2) - 20
        local btnH = 35
        
        imgui.BeginChild("LeftCol", imgui.ImVec2(colW, -15), true)
        imgui.SetCursorPosX((colW - imgui.CalcTextSize(u8"Скрипт LMMR").x) / 2)
        imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), u8"Скрипт LMMR")
        imgui.Separator()
        
        if imgui.Button(u8"Открыть меню LMMR", imgui.ImVec2(-1, btnH)) then
            CentralGlMenu[0] = true
            show_custom_lavka[0] = false
        end
        if imgui.Button(u8"Выбрать конфиг", imgui.ImVec2(-1, btnH)) then
            imgui.OpenPopup(u8"Выбор конфига")
        end
        
        imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.Appearing, imgui.ImVec2(0.5, 0.5))
        if imgui.BeginPopupModal(u8"Выбор конфига", nil, imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoMove) then
            imgui.Text(u8"Выберите конфига для загрузки:")
            imgui.Separator()
            imgui.Spacing()
            
            local has_p = false
            for pName, pItems in pairs(storage.profiles) do
                has_p = true
                if imgui.Button(u8(pName), imgui.ImVec2(250, 35)) then
                    vars = {}
                    for _, item in ipairs(pItems) do
                        table.insert(vars, {
                            name = imgui.new.char[256](string.sub(u8(item.name or ""), 1, 255)),
                            id = imgui.new.char[64](string.sub(u8(item.id or ""), 1, 63)),
                            price = imgui.new.char[64](string.sub(u8(item.price or "0"), 1, 63)),
                            amount = imgui.new.char[64](string.sub(u8(item.amount or "1"), 1, 63)),
                            active = imgui.new.bool(item.active or false),
                            is_acc = imgui.new.bool(item.is_acc or false),
                            str_name = u8(item.name or ""),
                            str_id = u8(item.id or ""),
                            str_price = u8(item.price or "0"),
                            str_amount = u8(item.amount or "1")
                        })
                    end
                    active_preset_name = u8(pName)
                    save_main_json()
                    imgui.CloseCurrentPopup()
                end
                imgui.Spacing()
            end
            if not has_p then 
                imgui.TextDisabled(u8"Нет сохраненных конфигов") 
            end
            
            imgui.Spacing()
            imgui.Separator()
            if imgui.Button(u8"Закрыть", imgui.ImVec2(250, 35)) then
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
        end
        
        imgui.Spacing()
        local c_preset = active_preset_name ~= "" and active_preset_name or "Main.json"
        imgui.TextDisabled(u8"Пресет: " .. c_preset)
        imgui.Spacing()
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.7, 0.2, 0.8))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.2, 0.8, 0.2, 1.0))
        if imgui.Button(u8"Выставить скупку", imgui.ImVec2(-1, btnH + 10)) then
            runBuyingProcess()
            show_custom_lavka[0] = false
        end
        imgui.PopStyleColor(2)
        
        imgui.EndChild()
        
        imgui.SameLine()
        
        imgui.BeginChild("RightCol", imgui.ImVec2(colW, -15), true)
        imgui.SetCursorPosX((colW - imgui.CalcTextSize(u8"Серверная лавка").x) / 2)
        imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), u8"Серверная лавкаэ")
        imgui.Separator()
        
        local tBtnW = (colW - 15) / 2
        
        if imgui.Button(u8"Продажа", imgui.ImVec2(tBtnW, btnH)) then
            sampSendDialogResponse(9, 1, 0, "")
            show_custom_lavka[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Скупка", imgui.ImVec2(tBtnW, btnH)) then
            sampSendDialogResponse(9, 1, 1, "")
            show_custom_lavka[0] = false
        end
        
        if imgui.Button(u8"Название", imgui.ImVec2(tBtnW, btnH)) then
            sampSendDialogResponse(9, 1, 5, "")
            show_custom_lavka[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Товары", imgui.ImVec2(tBtnW, btnH)) then
            sampSendDialogResponse(9, 1, 3, "")
            show_custom_lavka[0] = false
        end
        
        if imgui.Button(u8"История сделок", imgui.ImVec2(-1, btnH)) then
            sampSendDialogResponse(9, 1, 4, "")
            show_custom_lavka[0] = false
        end
        
        imgui.Spacing()
        imgui.TextDisabled(u8"Прекратить:")
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.7))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.3, 0.3, 1.0))
        if imgui.Button(u8"Скуп", imgui.ImVec2(tBtnW, btnH)) then
            sampSendDialogResponse(9, 1, 2, "")
            show_custom_lavka[0] = false
        end
        imgui.SameLine()
        if imgui.Button(u8"Аренду", imgui.ImVec2(tBtnW, btnH)) then
            sampSendDialogResponse(9, 1, 6, "")
            show_custom_lavka[0] = false
        end
        imgui.PopStyleColor(2)
        
        imgui.EndChild()
        
        imgui.End()
        imgui.PopStyleVar(3)
        imgui.PopStyleColor(8)
    end
    
    if imgui.IsMouseReleased(0) then
        global_drag_active = false
    end

    if CentralGlMenu[0] then 
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(cBg[0], cBg[1], cBg[2], menu_opacity[0]))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(cBg[0] + 0.02, cBg[1] + 0.02, cBg[2] + 0.02, menu_opacity[0] * 0.75))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 0.85))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(cAcc[0] - 0.1, cAcc[1] - 0.1, cAcc[2] - 1.0, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.12, 0.12, 0.15, 0.85))

        if not isAuthorized then
            imgui.SetNextWindowSize(imgui.ImVec2(350, 200), imgui.Cond.Always)
            imgui.SetNextWindowPos(imgui.ImVec2(resX/2, resY/2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
            imgui.Begin("##AuthWindow", CentralGlMenu, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize)
            
            imgui.SetCursorPos(imgui.ImVec2(20, 20))
            imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), u8"АВТОРИЗАЦИЯ LMMR")
            imgui.Separator()
            
            imgui.SetCursorPos(imgui.ImVec2(20, 60))
            imgui.Text(u8"Введите ключ доступа:")
            
            imgui.SetCursorPos(imgui.ImVec2(20, 85))
            imgui.PushItemWidth(310)
            imgui.InputText("##auth_input", authKeyBuffer, 256)
            imgui.PopItemWidth()
            
            if authError then
                imgui.SetCursorPos(imgui.ImVec2(20, 115))
                imgui.TextColored(imgui.ImVec4(1.0, 0.2, 0.2, 1.0), u8"Неверный ключ!")
            end
            
            imgui.SetCursorPos(imgui.ImVec2(20, 135))
            if imgui.Button(u8"ВОЙТИ", imgui.ImVec2(310, 45)) then
                if not global_drag_active then
                    local entered = ffi.string(authKeyBuffer)
                    local valid = false
                    for _, k in ipairs(script_keys) do
                        if entered == k then
                            valid = true
                            break
                        end
                    end
                    if valid then
                        isAuthorized = true
                        authError = false
                        storage.settings.saved_key = entered
                        save_main_json()
                    else
                        authError = true
                    end
                end
            end
            
            imgui.End()
        else
            imgui.SetNextWindowSizeConstraints(imgui.ImVec2(math.min(750, resX), math.min(450, resY)), imgui.ImVec2(resX, resY))        
            imgui.SetNextWindowSize(imgui.ImVec2(win_W[0], win_H[0]), imgui.Cond.Always)
            imgui.SetNextWindowPos(imgui.ImVec2(win_posX[0], win_posY[0]), imgui.Cond.Always)
            imgui.Begin("##MAIN_WINDOW", CentralGlMenu, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)
            
            imgui.BeginChild("TopPanel", imgui.ImVec2(-1, 75), false)
            
            imgui.InvisibleButton("DragZone", imgui.ImVec2(imgui.GetWindowWidth() - 180, 75))
            if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
                win_posX[0] = win_posX[0] + imgui.GetIO().MouseDelta.x
                win_posY[0] = win_posY[0] + imgui.GetIO().MouseDelta.y
                is_win_dragging = true
            end
            if is_win_dragging and imgui.IsMouseReleased(0) then
                is_win_dragging = false
                save_main_json()
            end
            
            imgui.SetCursorPos(imgui.ImVec2(30, 25))
            imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), "LMMR 1.8.2")
            
            imgui.SetCursorPos(imgui.ImVec2(imgui.GetWindowWidth() - 180, 15))
            if imgui.Button(u8"Настройки", imgui.ImVec2(120, 45)) and not global_drag_active then
                 currentTab = 4
             end
            imgui.SetCursorPos(imgui.ImVec2(imgui.GetWindowWidth() - 55, 15))
            if imgui.Button("X", imgui.ImVec2(45, 45)) and not global_drag_active then
                 CentralGlMenu[0] = false
             end
            imgui.EndChild()
            
            imgui.SetCursorPos(imgui.ImVec2(15, 90))
            imgui.BeginChild("SideBar", imgui.ImVec2(210, -15), true)
            imgui.SetCursorPosY(20)
            local nav_items = {
                {u8"Предметы", 1},
                {u8"Логи", 2},
                {u8"Инфо", 3},
                {u8"Конфиги", 5}
            }
            for _, nav in ipairs(nav_items) do
                imgui.SetCursorPosX(15)
                if imgui.Button(nav[1] .. "##side", imgui.ImVec2(180, 55)) and not global_drag_active then
                     currentTab = nav[2]
                 end
                imgui.Spacing()
            end
            
            imgui.SetCursorPos(imgui.ImVec2(20, imgui.GetWindowHeight() - 35))
            imgui.TextDisabled("Authors: major ")
            imgui.EndChild()
            
            imgui.SameLine()
            imgui.SetCursorPosY(90)
            imgui.BeginChild("ContentArea", imgui.ImVec2(-15, -15), true)
            
            if currentTab == 1 then
                local halfW = (imgui.GetWindowWidth() / 2) - 10
                
                imgui.BeginChild("DB_Area", imgui.ImVec2(halfW, -1), true)
                imgui.PushItemWidth(-1)
                
                local q_changed = imgui.InputTextWithHint("##srch", u8"Поиск...", searchBuffer, 256)
                imgui.PopItemWidth()
                
                if q_changed or last_search == nil then
                    local current_q = ru_lower(u8:decode(ffi.string(searchBuffer)))
                    last_search = current_q
                    filtered_cache = {}
                    for _, v in ipairs(item_db) do
                        if not v.lower_name then
                            v.lower_name = ru_lower(v.name)
                        end
                        
                        if current_q == "" or v.lower_name:find(current_q, 1, true) or v.id:find(current_q, 1, true) then
                            table.insert(filtered_cache, v)
                        end
                    end
                    currentPage = 1 
                end
                
                imgui.BeginChild("DbScroll", imgui.ImVec2(-1, -45))
                local start = (currentPage - 1) * itemsPerPage + 1
                for i = start, math.min(start + itemsPerPage - 1, #filtered_cache) do
                    if filtered_cache[i] then
                        local item = filtered_cache[i]
                        if imgui.Button(item.dsp_name .. "##db" .. i, imgui.ImVec2(-1, 35)) then
                            if not global_drag_active then
                                safe_copy(addName, item.u8_name, 256)
                                safe_copy(addId, item.u8_id, 64)
                                safe_copy(addPrice, "100", 64)
                                safe_copy(addAmount, "1", 64)
                                addIsAccessory[0] = false
                                editIndex = -1
                                open_add_modal = true
                            end
                        end
                    end
                end
                if imgui.IsWindowHovered(33) and imgui.IsMouseDragging(0, 0.0) then
                    imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
                end
                imgui.EndChild()
                
                local maxPages = math.max(1, math.ceil(#filtered_cache / itemsPerPage))
                if imgui.Button("<", imgui.ImVec2(35, 30)) and not global_drag_active and currentPage > 1 then
                     currentPage = currentPage - 1
                 end
                imgui.SameLine()
                 imgui.Text(string.format("%d / %d", currentPage, maxPages))
                imgui.SameLine()
                if imgui.Button(">", imgui.ImVec2(35, 30)) and not global_drag_active and currentPage < maxPages then
                     currentPage = currentPage + 1
                 end
                imgui.EndChild()
                
                imgui.SameLine()
                
                imgui.BeginChild("Queue_Area", imgui.ImVec2(halfW, -1), true)
                if imgui.Button(isRunning and u8"Остановить" or u8"Запустить скуп", imgui.ImVec2(-1, 55)) and not global_drag_active then
                    if isRunning then
                         stopProcess = true
                     else
                         runBuyingProcess()
                     end
                end
                imgui.Separator()
                
                imgui.BeginChild("ListScroll", imgui.ImVec2(-1, -1))
                local item_to_delete = -1 
                for i, item in ipairs(vars) do
                    imgui.BeginChild("ItemEntry" .. i, imgui.ImVec2(-1, 95), true, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
                    imgui.SetCursorPos(imgui.ImVec2(10, 35))
                    if imgui.Checkbox("##act" .. i, item.active) then
                         save_main_json()
                     end
                    
                    imgui.SameLine(40)
                    imgui.BeginGroup()
                    local idStr = item.str_id ~= "" and (" [ID: " .. item.str_id .. "]") or ""
                    imgui.Text(item.str_name .. idStr)
                    
                    local label_amt = item.is_acc[0] and u8"Цвет: " or u8"Кол: "
                    imgui.TextDisabled(item.str_price .. u8" $ | " .. label_amt .. item.str_amount)
                    imgui.EndGroup()
                    
                    imgui.SameLine(imgui.GetWindowWidth() - 110)
                    imgui.SetCursorPosY(25)
                    if imgui.Button(u8" ##ed" .. i, imgui.ImVec2(45, 45)) then
                        if not global_drag_active then
                            safe_copy(addName, item.str_name, 256)
                            safe_copy(addId, item.str_id, 64)
                            safe_copy(addPrice, item.str_price, 64)
                            safe_copy(addAmount, item.str_amount, 64)
                            addIsAccessory[0] = item.is_acc[0]
                            editIndex = i
                            open_add_modal = true
                        end
                    end
                    imgui.SameLine()
                    if imgui.Button("X##dl" .. i, imgui.ImVec2(45, 45)) then
                        if not global_drag_active then
                            item_to_delete = i
                        end
                    end
                    imgui.EndChild()
                end
                
                if item_to_delete ~= -1 then
                    table.remove(vars, item_to_delete)
                    save_main_json()
                end
                
                if imgui.IsWindowHovered(33) and imgui.IsMouseDragging(0, 0.0) then
                    imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
                end
                imgui.EndChild()
                imgui.EndChild()
                
            elseif currentTab == 2 then
                imgui.BeginChild("LogDates", imgui.ImVec2(150, -1), true)
                if #log_dates > 0 then
                    for _, dateStr in ipairs(log_dates) do
                        if imgui.Selectable(tostring(dateStr), selected_date == dateStr) then
                            selected_date = tostring(dateStr)
                        end
                    end
                else
                    imgui.TextDisabled(u8"Пусто")
                end
                if imgui.IsWindowHovered(33) and imgui.IsMouseDragging(0, 0.0) then
                    imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
                end
                imgui.EndChild()
                
                imgui.SameLine()
                
                imgui.BeginChild("LogsFrame", imgui.ImVec2(-1, -1), true)
                if selected_date ~= "" and logs[selected_date] then
                    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.8))
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.3, 0.3, 1.0))
                    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.7, 0.1, 0.1, 1.0))
                    if imgui.Button(u8"Удалить логи за " .. selected_date, imgui.ImVec2(-1, 35)) and not global_drag_active then
                        logs[selected_date] = nil
                        save_logs()
                        load_logs() 
                    end
                    imgui.PopStyleColor(3)
                    imgui.Separator()
                    
                    imgui.BeginChild("LogTextScroll", imgui.ImVec2(-1, -1))
                    for _, msg in ipairs(logs[selected_date] or {}) do
                         imgui.TextWrapped(u8(tostring(msg)))
                    end
                    if imgui.IsWindowHovered(33) and imgui.IsMouseDragging(0, 0.0) then
                        imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
                    end
                    imgui.EndChild()
                else
                     imgui.TextDisabled(u8"Нет записей.")
                end
                imgui.EndChild()
                
            elseif currentTab == 3 then
                imgui.SetCursorPos(imgui.ImVec2(40, 40))
                imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1), "LMMR")
                imgui.Text(u8"База данных: " .. #item_db .. u8" предметов")
                imgui.Text(u8"жди обнову")
                imgui.Spacing()
                imgui.TextDisabled(u8"100 слотов максимум пока что")
                
            elseif currentTab == 4 then
                imgui.BeginChild("SettingsScroll", imgui.ImVec2(-1, -85))
                
                imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1), u8"БАЗА ПРЕДМЕТОВ (АВТОСКАН)")
                imgui.TextWrapped(u8"Откройте диалог 'Скупка: 1/132 (Весь список)' в лавке и нажмите кнопку. Скрипт сам пролистает все страницы и запишет названия с ID.")
                local scanBtnText = isScanning and u8"ОСТАНОВИТЬ СКАНИРОВАНИЕ" or u8"ОТСКАНИРОВАТЬ ПРЕДМЕТЫ"
                if imgui.Button(scanBtnText, imgui.ImVec2(-1, 55)) and not global_drag_active then
                    if isScanning then
                         stopProcess = true
                        isScanning = false
                     else
                         runAutoScan()
                     end
                end
                imgui.Spacing()
                 imgui.Separator()
                 imgui.Spacing()
                
                imgui.Text(u8"Настройки окна и задержки:")
                imgui.PushItemWidth(350)
                
                local max_w = tonumber(resX) and math.min(2560, resX) or 2560
                local temp_w = imgui.new.int(win_W[0])
                if imgui.SliderInt(u8"Ширина", temp_w, 750, max_w) then
                    win_W[0] = temp_w[0]
                end
                if imgui.IsItemDeactivatedAfterEdit() then save_main_json() end
                
                local max_h = tonumber(resY) and math.min(1080, resY) or 1080
                local temp_h = imgui.new.int(win_H[0])
                if imgui.SliderInt(u8"Высота", temp_h, 450, max_h) then
                    win_H[0] = temp_h[0]
                end
                if imgui.IsItemDeactivatedAfterEdit() then save_main_json() end
                
                imgui.SliderInt(u8"Задержка (мс)", global_delay, 500, 3000)
                if imgui.IsItemDeactivatedAfterEdit() then save_main_json() end
                
                imgui.SliderFloat(u8"Прозрачность фона", menu_opacity, 0.2, 1.0, "%.2f")
                if imgui.IsItemDeactivatedAfterEdit() then save_main_json() end
                
                imgui.PopItemWidth()
                
                imgui.Spacing()
                imgui.Text(u8"Настройки плавающей кнопки:")
                if imgui.Checkbox(u8"Показывать кнопку на экране (открытие без /cent)", show_screen_btn) then
                    save_main_json()
                end
                imgui.PushItemWidth(350)
                imgui.SliderFloat(u8"Размер кнопки", btn_size, 30.0, 150.0)
                if imgui.IsItemDeactivatedAfterEdit() then save_main_json() end
                imgui.PopItemWidth()
                
                imgui.Spacing()
                imgui.Text(u8"Цвета интерфейса")
                
                imgui.Text("R: " .. math.floor(cAcc[0]*255))
                 imgui.SameLine(80)
                imgui.Text("G: " .. math.floor(cAcc[1]*255))
                 imgui.SameLine(160)
                imgui.Text("B: " .. math.floor(cAcc[2]*255))
                 imgui.SameLine(240)
                if imgui.ColorButton("##AccBtn", imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), 0, imgui.ImVec2(35, 35)) then
                     imgui.OpenPopup("PickerAcc")
                 end
                imgui.SameLine()
                 imgui.Text(u8"Акцент")
                if imgui.BeginPopup("PickerAcc") then
                     imgui.ColorPicker3("##p1", cAcc)
                     save_main_json()
                     imgui.EndPopup()
                 end
                imgui.Spacing()
                
                imgui.Text("R: " .. math.floor(cBg[0]*255))
                 imgui.SameLine(80)
                imgui.Text("G: " .. math.floor(cBg[1]*255))
                 imgui.SameLine(160)
                imgui.Text("B: " .. math.floor(cBg[2]*255))
                 imgui.SameLine(240)
                if imgui.ColorButton("##BgBtn", imgui.ImVec4(cBg[0], cBg[1], cBg[2], 1.0), 0, imgui.ImVec2(35, 35)) then
                     imgui.OpenPopup("PickerBg")
                 end
                imgui.SameLine()
                 imgui.Text(u8"Фон")
                if imgui.BeginPopup("PickerBg") then
                     imgui.ColorPicker3("##p2", cBg)
                     save_main_json()
                     imgui.EndPopup()
                 end
                 
                imgui.Spacing()
                imgui.Text("R: " .. math.floor(cBtn[0]*255))
                 imgui.SameLine(80)
                imgui.Text("G: " .. math.floor(cBtn[1]*255))
                 imgui.SameLine(160)
                imgui.Text("B: " .. math.floor(cBtn[2]*255))
                 imgui.SameLine(240)
                if imgui.ColorButton("##FloatBtnColor", imgui.ImVec4(cBtn[0], cBtn[1], cBtn[2], 1.0), 0, imgui.ImVec2(35, 35)) then
                     imgui.OpenPopup("PickerBtn")
                 end
                imgui.SameLine()
                 imgui.Text(u8"Цвет кнопки")
                if imgui.BeginPopup("PickerBtn") then
                     imgui.ColorPicker3("##p3", cBtn)
                     save_main_json()
                     imgui.EndPopup()
                 end
                
                if imgui.IsWindowHovered(33) and imgui.IsMouseDragging(0, 0.0) then
                    imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
                end
                imgui.EndChild()
                
                imgui.SetCursorPosY(imgui.GetWindowHeight() - 75)
                if imgui.Button(u8"Сохранить", imgui.ImVec2(-1, 55)) and not global_drag_active then
                    save_main_json()
                end
                
            elseif currentTab == 5 then 
                imgui.BeginChild("ProfilesArea", imgui.ImVec2(-1, -1), true)
                imgui.SetCursorPos(imgui.ImVec2(20, 20))
                imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), u8"Настройка конфигов")
                imgui.Separator()
                imgui.Spacing()
                
                imgui.SetCursorPosX(20)
                imgui.Text(u8"Название нового конфига:")
                imgui.SetCursorPosX(20)
                imgui.PushItemWidth(300)
                imgui.InputText("##prof_name", profileNameBuffer, 256)
                imgui.PopItemWidth()
                imgui.SameLine()
                if imgui.Button(u8"Сохранить конфиг", imgui.ImVec2(200, 35)) and not global_drag_active then
                    local pName = u8:decode(ffi.string(profileNameBuffer))
                    if pName ~= "" then
                        local pItems = {}
                        for _, v in ipairs(vars) do
                            table.insert(pItems, {
                                name = u8:decode(v.str_name),
                                id = u8:decode(v.str_id),
                                price = u8:decode(v.str_price),
                                amount = u8:decode(v.str_amount),
                                active = v.active[0],
                                is_acc = v.is_acc[0]
                            })
                        end
                        storage.profiles[pName] = pItems
                        save_main_json()
                    end
                end
                
                imgui.Spacing()
                imgui.SetCursorPosX(20)
                imgui.Text(u8"Ваши сохраненные конфиги:")
                imgui.SetCursorPosX(20)
                imgui.BeginChild("ProfList", imgui.ImVec2(-20, -15), true)
                
                local has_profiles = false
                for pName, pItems in pairs(storage.profiles) do
                    has_profiles = true
                    imgui.SetCursorPosX(15)
                    imgui.Text(u8(pName) .. " (" .. #pItems .. u8" предметов)")
                    
                    imgui.SameLine(imgui.GetWindowWidth() - 250)
                    if imgui.Button(u8"Загрузить##ld" .. pName, imgui.ImVec2(100, 35)) and not global_drag_active then
                        vars = {}
                        for _, item in ipairs(pItems) do
                            table.insert(vars, {
                                name = imgui.new.char[256](string.sub(u8(item.name or ""), 1, 255)),
                                id = imgui.new.char[64](string.sub(u8(item.id or ""), 1, 63)),
                                price = imgui.new.char[64](string.sub(u8(item.price or "0"), 1, 63)),
                                amount = imgui.new.char[64](string.sub(u8(item.amount or "1"), 1, 63)),
                                active = imgui.new.bool(item.active or false),
                                is_acc = imgui.new.bool(item.is_acc or false),
                                str_name = u8(item.name or ""),
                                str_id = u8(item.id or ""),
                                str_price = u8(item.price or "0"),
                                str_amount = u8(item.amount or "1")
                            })
                        end
                        save_main_json()
                    end
                    
                    imgui.SameLine()
                    if imgui.Button(u8"Удалить##dl" .. pName, imgui.ImVec2(100, 35)) and not global_drag_active then
                        storage.profiles[pName] = nil
                        save_main_json()
                    end
                    imgui.Separator()
                end
                
                if not has_profiles then
                    imgui.SetCursorPosX(15)
                    imgui.TextDisabled(u8"У вас пока нет сохраненных конфигов.")
                end
                
                if imgui.IsWindowHovered(33) and imgui.IsMouseDragging(0, 0.0) then
                    imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
                end
                imgui.EndChild()
                imgui.EndChild()
            end
            imgui.EndChild()

            if open_add_modal then
                 imgui.OpenPopup("CEF_Modal")
                 open_add_modal = false
             end
             
            imgui.SetNextWindowSize(imgui.ImVec2(650, 600), imgui.Cond.Always)
            imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
            if imgui.BeginPopupModal("CEF_Modal", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize) then
                imgui.SetCursorPos(imgui.ImVec2(30, 30))
                imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), editIndex == -1 and u8"ДОБАВЛЕНИЕ ПРЕДМЕТА" or u8"ИЗМЕНЕНИЕ ПРЕДМЕТА")
                imgui.Separator()
                
                imgui.SetCursorPos(imgui.ImVec2(30, 80))
                imgui.BeginGroup()
                
                imgui.PushItemWidth(590) 
                imgui.Text(u8"Название (для себя):")
                imgui.InputText("##name_in", addName, 256)
                imgui.Spacing()
                
                imgui.Text(u8"ID Предмета:")
                imgui.InputText("##id_in", addId, 64)
                imgui.Spacing()
                
                imgui.Text(u8"Цена за 1 шт:")
                imgui.InputText("##prc_in", addPrice, 64)
                imgui.Spacing()
                
                imgui.Checkbox(u8"Это аксессуар?", addIsAccessory)
                imgui.Spacing()

                if addIsAccessory[0] then
                    imgui.Text(u8"ID цвета (0-12):")
                else
                    imgui.Text(u8"Количество:")
                end
                imgui.InputText("##amt_in", addAmount, 64)
                
                imgui.PopItemWidth()
                imgui.EndGroup()
                
                imgui.SetCursorPos(imgui.ImVec2(30, 510)) 
                if imgui.Button(u8"Сохранить", imgui.ImVec2(285, 60)) and not global_drag_active then
                    local s_name = ffi.string(addName)
                    local s_id = ffi.string(addId)
                    local s_price = ffi.string(addPrice)
                    local s_amount = ffi.string(addAmount)

                    if editIndex == -1 then
                        table.insert(vars, {
                            name = imgui.new.char[256](string.sub(s_name, 1, 255)),
                            id = imgui.new.char[64](string.sub(s_id, 1, 63)),
                            price = imgui.new.char[64](string.sub(s_price, 1, 63)),
                            amount = imgui.new.char[64](string.sub(s_amount, 1, 63)),
                            active = imgui.new.bool(true),
                            is_acc = imgui.new.bool(addIsAccessory[0]),
                            str_name = s_name,
                            str_id = s_id,
                            str_price = s_price,
                            str_amount = s_amount
                        })
                    else
                        safe_copy(vars[editIndex].name, s_name, 256)
                        safe_copy(vars[editIndex].id, s_id, 64)
                        safe_copy(vars[editIndex].price, s_price, 64)
                        safe_copy(vars[editIndex].amount, s_amount, 64)
                        vars[editIndex].is_acc[0] = addIsAccessory[0]
                        
                        vars[editIndex].str_name = s_name
                        vars[editIndex].str_id = s_id
                        vars[editIndex].str_price = s_price
                        vars[editIndex].str_amount = s_amount
                    end
                    save_main_json()
                    imgui.CloseCurrentPopup()
                end
                imgui.SameLine()
                imgui.SetCursorPosX(335)
                if imgui.Button(u8"Отмена", imgui.ImVec2(285, 60)) and not global_drag_active then
                     imgui.CloseCurrentPopup()
                 end
                imgui.EndPopup()
            end
            imgui.End()
        end
        imgui.PopStyleColor(7)
    end
end)

function main()
    while not isSampAvailable() do wait(100) end
    load_main_json()
    load_item_db()
    load_logs()
    sampRegisterChatCommand('cent', function()
         CentralGlMenu[0] = not CentralGlMenu[0]
     end)
    sampAddChatMessage("{00BFFF}[LMMR 1.8.2]{FFFFFF} Скрипт загружен. /cent", -1)
    while true do
         wait(0)
     end
end
