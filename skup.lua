script_name("LMMR")
script_author("major")
script_version("1.9.0")

local imgui_status, imgui = pcall(require, 'mimgui')
local encoding_status, encoding = pcall(require, 'encoding')
local ffi = require('ffi')
local sampev_status, sampev = pcall(require, 'samp.events')
local json = pcall(require, "json") and require("json") or {
    encode = encodeJson,
    decode = decodeJson
}

if not imgui_status then return end
if encoding_status then encoding.default = 'CP1251' end
local u8 = encoding_status and encoding.UTF8 or function(str) return str end

local configDir = getWorkingDirectory() .. '/config/'
local filePath = configDir .. 'main.json'
local dbPath = configDir .. 'items_db.json'
local logsPath = configDir .. 'logs_db.json'
local salesDbPath = configDir .. 'sales_db.json'

if not doesDirectoryExist(configDir) then createDirectory(configDir) end

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
    src = tostring(src or "")
    if #src >= max_len then src = src:sub(1, max_len - 1) end
    ffi.copy(dest, src)
end

local function trim(s)
    return tostring(s or ""):match('^%s*(.-)%s*$')
end

local function split_lines(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    return lines
end

local storage = {
    settings = {
        win_W = 950,
        win_H = 600,
        accent = {0.14, 0.45, 0.90},
        background = {0.07, 0.07, 0.08},
        show_btn = true,
        btn_color = {0.14, 0.45, 0.90},
        btn_size = 55.0,
        global_delay = 1200,
        menu_opacity = 1.0
    },
    items = {},
    profiles = {}
}

local vars, logs, log_dates = {}, {}, {}
local selected_date = ""
local item_db, filtered_cache = {}, {}
local last_search = nil

local sales_db = {}
local sale_names_cache = {}

local isRunning, isScanning, stopProcess = false, false, false
local CentralGlMenu = imgui.new.bool(false)
local show_custom_lavka = imgui.new.bool(false)
local show_sale_overlay = imgui.new.bool(false)
local currentTab = 1
local open_add_modal = false
local editIndex = -1

local win_posX, win_posY = imgui.new.float(-1), imgui.new.float(-1)
local btn_posX, btn_posY = imgui.new.float(-1), imgui.new.float(-1)
local is_btn_dragging, is_win_dragging, global_drag_active = false, false, false

local searchBuffer = imgui.new.char[256]("")
local currentPage, itemsPerPage = 1, 100

local addName = imgui.new.char[256]("")
local addId = imgui.new.char[64]("")
local addPrice = imgui.new.char[64]("")
local addAmount = imgui.new.char[64]("1")
local addIsAccessory = imgui.new.bool(false)
local profileNameBuffer = imgui.new.char[256]("")

local win_W = imgui.new.float(storage.settings.win_W)
local win_H = imgui.new.float(storage.settings.win_H)
local cAcc = imgui.new.float[3]({storage.settings.accent[1], storage.settings.accent[2], storage.settings.accent[3]})
local cBg = imgui.new.float[3]({storage.settings.background[1], storage.settings.background[2], storage.settings.background[3]})
local show_screen_btn = imgui.new.bool(storage.settings.show_btn)
local cBtn = imgui.new.float[3]({storage.settings.btn_color[1], storage.settings.btn_color[2], storage.settings.btn_color[3]})
local btn_size = imgui.new.float(storage.settings.btn_size or 55.0)
local global_delay = imgui.new.int(storage.settings.global_delay or 1200)
local menu_opacity = imgui.new.float(storage.settings.menu_opacity or 1.0)

local saleDialogState = {
    active = false,
    id = 240,
    lines = {},
    entries = {},
    nextPageIndex = -1,
    selectedIndex = 1,
    pendingItemName = nil,
    quickPayload = nil,
    lastDialogText = ""
}

local sale_edit_buffers = {}

local function rebuild_sale_names_cache()
    sale_names_cache = {}
    for name in pairs(sales_db) do table.insert(sale_names_cache, name) end
    table.sort(sale_names_cache, function(a, b) return ru_lower(a) < ru_lower(b) end)
end

local function ensure_sale_buffers(name)
    if not sale_edit_buffers[name] then
        local rec = sales_db[name] or {price = "", amount = "1"}
        sale_edit_buffers[name] = {
            price = imgui.new.char[64](tostring(rec.price or "")),
            amount = imgui.new.char[64](tostring(rec.amount or "1"))
        }
    end
    return sale_edit_buffers[name]
end

-- Чтение базы автопродажи (только JSON)
local function load_sales_db()
    sales_db = {}
    sale_edit_buffers = {}
    if doesFileExist(salesDbPath) then
        local f = io.open(salesDbPath, 'r')
        if f then
            local ok, data = pcall(json.decode, f:read('*a'))
            f:close()
            if ok and type(data) == 'table' then
                for k, v in pairs(data) do
                    if type(k) == 'string' and type(v) == 'table' then
                        sales_db[k] = {
                            price = tostring(v.price or ''),
                            amount = tostring(v.amount or '1')
                        }
                    end
                end
            end
        end
    end
    rebuild_sale_names_cache()
end

-- Сохранение базы автопродажи (только JSON)
local function save_sales_db()
    local f = io.open(salesDbPath, 'w')
    if not f then return end
    f:write(json.encode(sales_db))
    f:close()
end

-- Обновление/создание записи автопродажи в памяти и файле
local function upsert_sale_memory(itemName, price, amount)
    local cleanName = trim(itemName)
    if cleanName == '' then return end
    sales_db[cleanName] = {
        price = tostring(trim(price)),
        amount = tostring(trim(amount))
    }
    sale_edit_buffers[cleanName] = nil
    rebuild_sale_names_cache()
    save_sales_db()
end

local function load_logs()
    logs, log_dates, selected_date = {}, {}, ""
    if doesFileExist(logsPath) then
        local file = io.open(logsPath, "r")
        if file then
            local ok, decoded = pcall(json.decode, file:read("*a"))
            file:close()
            if ok and type(decoded) == "table" then
                for k, v in pairs(decoded) do
                    if type(k) == "string" and type(v) == "table" then logs[k] = v end
                end
            end
        end
    end
    for k in pairs(logs) do table.insert(log_dates, tostring(k)) end
    table.sort(log_dates, function(a, b) return tostring(a) > tostring(b) end)
    if #log_dates > 0 then selected_date = log_dates[1] end
end

local function save_logs()
    local file = io.open(logsPath, "w")
    if file then file:write(json.encode(logs)); file:close() end
end

local function addLog(text)
    local today = os.date("%Y-%m-%d")
    logs[today] = logs[today] or {}
    if #logs[today] == 0 then table.insert(log_dates, 1, today) end
    table.insert(logs[today], 1, os.date("[%H:%M] ") .. text)
    if #logs[today] > 100 then table.remove(logs[today]) end
    save_logs()
end

local function load_item_db()
    item_db, last_search = {}, nil
    if doesFileExist(dbPath) then
        local file = io.open(dbPath, "r")
        if file then
            local ok, decoded = pcall(json.decode, file:read("*a"))
            file:close()
            if ok and type(decoded) == "table" then
                for _, v in ipairs(decoded) do
                    local n = u8:decode(v.name or "")
                    local id = u8:decode(v.id or "")
                    local dsp = id ~= "" and (n .. " [" .. id .. "]") or n
                    table.insert(item_db, {name = n, lower_name = ru_lower(n), id = id, u8_name = u8(n), u8_id = u8(id), dsp_name = u8(dsp)})
                end
            end
        end
    end
end

local function save_item_db()
    local file = io.open(dbPath, "w")
    if not file then return end
    local t = {}
    for _, v in ipairs(item_db) do table.insert(t, {name = v.u8_name, id = v.u8_id}) end
    file:write(json.encode(t)); file:close()
end

local function save_main_json()
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
    storage.settings.win_W, storage.settings.win_H = win_W[0], win_H[0]
    storage.settings.accent, storage.settings.background = {cAcc[0], cAcc[1], cAcc[2]}, {cBg[0], cBg[1], cBg[2]}
    storage.settings.show_btn, storage.settings.btn_color = show_screen_btn[0], {cBtn[0], cBtn[1], cBtn[2]}
    storage.settings.btn_size, storage.settings.global_delay, storage.settings.menu_opacity = btn_size[0], global_delay[0], menu_opacity[0]
    storage.settings.win_posX, storage.settings.win_posY = win_posX[0], win_posY[0]
    storage.settings.pos_converted = true
    storage.settings.btn_posX, storage.settings.btn_posY = btn_posX[0], btn_posY[0]
    local file = io.open(filePath, "w")
    if file then file:write(json.encode(storage)); file:close() end
end

local function load_main_json()
    if not doesFileExist(filePath) then return end
    local file = io.open(filePath, "r")
    if not file then return end
    local ok, decoded = pcall(json.decode, file:read("*a"))
    file:close()
    if not ok or not decoded then return end
    storage = decoded
    storage.profiles = storage.profiles or {}
    win_W[0], win_H[0] = storage.settings.win_W or 950, storage.settings.win_H or 600
    if storage.settings.accent then cAcc[0], cAcc[1], cAcc[2] = unpack(storage.settings.accent) end
    if storage.settings.background then cBg[0], cBg[1], cBg[2] = unpack(storage.settings.background) end
    if storage.settings.show_btn ~= nil then show_screen_btn[0] = storage.settings.show_btn end
    if storage.settings.btn_color then cBtn[0], cBtn[1], cBtn[2] = unpack(storage.settings.btn_color) end
    if storage.settings.btn_size then btn_size[0] = storage.settings.btn_size end
    if storage.settings.global_delay then global_delay[0] = storage.settings.global_delay end
    if storage.settings.menu_opacity then menu_opacity[0] = storage.settings.menu_opacity end
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

local function parse_sale_dialog(text)
    saleDialogState.lines = split_lines(text)
    saleDialogState.entries = {}
    saleDialogState.nextPageIndex = -1
    saleDialogState.lastDialogText = text or ""
    for i, line in ipairs(saleDialogState.lines) do
        local clean = trim(line:gsub('{%x%x%x%x%x%x}', ''))
        if clean ~= '' then
            if clean:find('>>>') or ru_lower(clean):find('далее', 1, true) then
                saleDialogState.nextPageIndex = i - 1
            else
                table.insert(saleDialogState.entries, {index = i - 1, name = clean})
            end
        end
    end
    if saleDialogState.selectedIndex > #saleDialogState.entries then saleDialogState.selectedIndex = 1 end
end

-- Пытаемся извлечь имя предмета из текстового инпута диалога продажи
local function extract_sale_item_name(inputText)
    local txt = trim((inputText or ""):gsub('{%x%x%x%x%x%x}', ''))
    if txt == '' then return nil end
    local n = txt:match('^([^,]+),%s*%d+') or txt:match('^([^,]+),%s*%d+,%s*%d+')
    if n and trim(n) ~= '' then return trim(n) end
    if saleDialogState.entries[saleDialogState.selectedIndex] then
        return saleDialogState.entries[saleDialogState.selectedIndex].name
    end
    return nil
end

-- Быстрое выставление: отправка сохраненных количества/цены в следующий вводный диалог
local function trigger_quick_sale()
    local entry = saleDialogState.entries[saleDialogState.selectedIndex]
    if not entry then return end
    local mem = sales_db[entry.name]
    if not mem or trim(mem.price) == '' or trim(mem.amount) == '' then return end
    saleDialogState.pendingItemName = entry.name
    saleDialogState.quickPayload = tostring(mem.price) .. ',' .. tostring(mem.amount)
    sampSendDialogResponse(240, 1, entry.index, "")
end

local function runBuyingProcess()
    if #vars == 0 then return end
    local buy_queue = {}
    for _, v in ipairs(vars) do
        if v.active[0] then
            table.insert(buy_queue, {id = u8:decode(v.str_id), name = u8:decode(v.str_name), price = u8:decode(v.str_price), amount = u8:decode(v.str_amount), is_acc = v.is_acc[0]})
        end
    end
    if #buy_queue == 0 then return end
    isRunning, stopProcess = true, false
    lua_thread.create(function()
        for _, item in ipairs(buy_queue) do
            if stopProcess then break end
            local query = (item.id ~= "" and item.id) or item.name
            local send_data = item.is_acc and (item.price .. "," .. item.amount) or (item.amount .. "," .. item.price)
            sampSendDialogResponse(9, 1, 1, "")
            wait(global_delay[0]); if stopProcess then break end
            sampSendDialogResponse(10, 1, 0, "")
            wait(global_delay[0]); if stopProcess then break end
            sampSendDialogResponse(909, 1, 0, query)
            wait(global_delay[0] + 600); if stopProcess then break end
            sampSendDialogResponse(11, 1, 0, send_data)
            wait(global_delay[0] + 500)
        end
        isRunning = false
    end)
end

-- Оптимизация Rodina Ultra Booster: сборщик мусора, очистка ближайших объектов, фиксация погоды
local function run_ultra_booster_tick()
    collectgarbage('collect')
    if type(getAllObjects) == 'function' and type(getCharCoordinates) == 'function' and type(getObjectCoordinates) == 'function' and type(deleteObject) == 'function' then
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        for _, obj in ipairs(getAllObjects()) do
            local ox, oy, oz = getObjectCoordinates(obj)
            local dx, dy, dz = ox - px, oy - py, oz - pz
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= 10.0 then pcall(deleteObject, obj) end
        end
    end
    if type(setWeather) == 'function' then pcall(setWeather, 10) end -- Закат
    if type(setTimeOfDay) == 'function' then pcall(setTimeOfDay, 19, 0) end
    if type(setFarClipDistance) == 'function' then pcall(setFarClipDistance, 1200.0) end -- против плотного тумана
end

local function runAutoScan()
    if isScanning then return end
    isScanning, stopProcess = true, false
    lua_thread.create(function()
        if not sampIsDialogActive() then isScanning = false return end
        local seen_items = {}
        for _, v in ipairs(item_db) do seen_items[(v.id ~= "" and v.id) or v.name] = true end
        while sampIsDialogActive() and not stopProcess do
            local curId, text = sampGetCurrentDialogId(), sampGetDialogText()
            if not text or text == "" then break end
            local lines, nextPageIdx = split_lines(text), -1
            for i, line in ipairs(lines) do
                local clean = trim(line:gsub("{%x%x%x%x%x%x}", ""))
                local rawName = clean:match("^%s*([^\t]+)")
                if rawName then
                    if rawName == "Далее" or rawName:find(">>>") then
                        nextPageIdx = i - 1
                    else
                        local n, id = rawName:match("^(.-)%s*%[(%d+)%]$")
                        if not n then n, id = rawName:match("^(.-)%s*%((%d+)%)$") end
                        if n and id then
                            if not seen_items[id] then
                                seen_items[id] = true
                                table.insert(item_db, {name = n, lower_name = ru_lower(n), id = id, u8_name = u8(n), u8_id = u8(id), dsp_name = u8(n .. " [" .. id .. "]")})
                            end
                        elseif rawName ~= "" and not seen_items[rawName] then
                            seen_items[rawName] = true
                            table.insert(item_db, {name = rawName, lower_name = ru_lower(rawName), id = "", u8_name = u8(rawName), u8_id = "", dsp_name = u8(rawName)})
                        end
                    end
                end
            end
            if nextPageIdx ~= -1 then sampSendDialogResponse(curId, 1, nextPageIdx, ""); wait(1200) else break end
        end
        save_item_db(); last_search = nil; isScanning = false
    end)
end

if sampev_status then
    function sampev.onServerMessage(color, text)
        local lower_text = ru_lower(text)
        if lower_text:find("куп") or lower_text:find("прод") or lower_text:find("выстав") then
            addLog(text:gsub("{%x%x%x%x%x%x}", ""))
        end
    end

    function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
        if dialogId == 9 and not isRunning then
            show_custom_lavka[0] = true
            return false
        end

        if dialogId == 240 then
            saleDialogState.active = true
            show_sale_overlay[0] = true
            parse_sale_dialog(text)
        else
            saleDialogState.active = false
            show_sale_overlay[0] = false
        end

        if saleDialogState.quickPayload and saleDialogState.pendingItemName and dialogId ~= 240 then
            local payload = saleDialogState.quickPayload
            saleDialogState.quickPayload = nil
            sampSendDialogResponse(dialogId, 1, 0, payload)
            upsert_sale_memory(saleDialogState.pendingItemName, payload:match('^(.-),') or '', payload:match(',(.+)$') or '')
            return false
        end
    end

    function sampev.onSendDialogResponse(dialogId, button, listbox, input)
        if dialogId == 240 and button == 1 then
            if listbox == saleDialogState.nextPageIndex then return end
            local selected = saleDialogState.entries[saleDialogState.selectedIndex]
            if selected then saleDialogState.pendingItemName = selected.name end
        end

        local p, a = tostring(input or ''):match('^(%d+)%s*,%s*(%d+)$')
        if p and a then
            local item = saleDialogState.pendingItemName or extract_sale_item_name(input)
            if item then upsert_sale_memory(item, p, a) end
        end
    end
end

imgui.OnInitialize(function()
    load_main_json(); load_item_db(); load_logs(); load_sales_db()
    local style = imgui.GetStyle()
    style.WindowPadding = imgui.ImVec2(0, 0)
    style.WindowRounding = 18.0
    style.ChildRounding = 10.0
    style.FrameRounding = 8.0
    style.ScrollbarSize = 5.0
    style.WindowBorderSize = 0.0
    style.ItemSpacing = imgui.ImVec2(10, 10)
end)

imgui.OnFrame(function() return CentralGlMenu[0] or show_screen_btn[0] or show_custom_lavka[0] or show_sale_overlay[0] end, function()
    local resX, resY = imgui.GetIO().DisplaySize.x, imgui.GetIO().DisplaySize.y
    if win_posX[0] == -1 then
        win_posX[0] = storage.settings.win_posX or (resX / 2 - win_W[0] / 2)
        win_posY[0] = storage.settings.win_posY or (resY / 2 - win_H[0] / 2)
    end
    if btn_posX[0] == -1 then
        btn_posX[0] = storage.settings.btn_posX or 10
        btn_posY[0] = storage.settings.btn_posY or (resY / 2)
    end

    if show_screen_btn[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(btn_posX[0], btn_posY[0]), imgui.Cond.Always)
        imgui.Begin("##FloatingButtonLMMR", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoMove)
        if imgui.Button("LMMR", imgui.ImVec2(btn_size[0], btn_size[0])) and not is_btn_dragging then CentralGlMenu[0] = not CentralGlMenu[0] end
        if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
            is_btn_dragging = true
            btn_posX[0] = btn_posX[0] + imgui.GetIO().MouseDelta.x
            btn_posY[0] = btn_posY[0] + imgui.GetIO().MouseDelta.y
        end
        if imgui.IsMouseReleased(0) then if is_btn_dragging then save_main_json() end; is_btn_dragging = false end
        imgui.End()
    end

    -- Кнопка быстрого выставления поверх диалога продажи (ID 240)
    if show_sale_overlay[0] and saleDialogState.active then
        imgui.SetNextWindowPos(imgui.ImVec2(resX - 360, resY * 0.25), imgui.Cond.Always)
        imgui.SetNextWindowSize(imgui.ImVec2(340, 220), imgui.Cond.Always)
        imgui.Begin(u8"LMMR Продажа##overlay", nil, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        imgui.Text(u8"Выбор предмета:")
        if imgui.BeginCombo("##salepick", saleDialogState.entries[saleDialogState.selectedIndex] and u8(saleDialogState.entries[saleDialogState.selectedIndex].name) or u8"Нет") then
            for i, e in ipairs(saleDialogState.entries) do
                local selected = (i == saleDialogState.selectedIndex)
                if imgui.Selectable(u8(e.name), selected) then
                    saleDialogState.selectedIndex = i
                    saleDialogState.pendingItemName = e.name
                end
            end
            imgui.EndCombo()
        end
        local selectedEntry = saleDialogState.entries[saleDialogState.selectedIndex]
        local hasMem = selectedEntry and sales_db[selectedEntry.name]
        if imgui.Button(u8"Быстрое выставление", imgui.ImVec2(-1, 35)) and hasMem then trigger_quick_sale() end
        if selectedEntry and hasMem then
            imgui.TextDisabled(u8("Сохранено: цена " .. tostring(sales_db[selectedEntry.name].price) .. ", кол-во " .. tostring(sales_db[selectedEntry.name].amount)))
        else
            imgui.TextDisabled(u8"Для предмета нет памяти цены/количества")
        end
        if saleDialogState.nextPageIndex >= 0 then
            imgui.TextDisabled(u8("Нижняя кнопка перелистывания: индекс " .. tostring(saleDialogState.nextPageIndex)))
        end
        imgui.End()
    end

    if CentralGlMenu[0] then
        imgui.SetNextWindowSize(imgui.ImVec2(win_W[0], win_H[0]), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(win_posX[0], win_posY[0]), imgui.Cond.Always)
        imgui.Begin("##MAIN_WINDOW", CentralGlMenu, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)

        imgui.BeginChild("TopPanel", imgui.ImVec2(-1, 60), false)
        imgui.TextColored(imgui.ImVec4(cAcc[0], cAcc[1], cAcc[2], 1.0), "LMMR 1.9.0")
        imgui.SameLine(imgui.GetWindowWidth() - 55)
        if imgui.Button("X", imgui.ImVec2(45, 35)) then CentralGlMenu[0] = false end
        imgui.EndChild()

        imgui.SetCursorPos(imgui.ImVec2(15, 75))
        imgui.BeginChild("SideBar", imgui.ImVec2(200, -15), true)
        local nav_items = {
            {u8"Предметы", 1},
            {u8"Продажа", 2},
            {u8"Логи", 3},
            {u8"Инфо", 4},
            {u8"Настройки", 5},
            {u8"Профили", 6}
        }
        for _, nav in ipairs(nav_items) do
            if imgui.Button(nav[1], imgui.ImVec2(-1, 40)) then currentTab = nav[2] end
        end
        imgui.SetCursorPosY(imgui.GetWindowHeight() - 20)
        imgui.TextDisabled("major")
        imgui.EndChild()

        imgui.SameLine()
        imgui.SetCursorPosY(75)
        imgui.BeginChild("ContentArea", imgui.ImVec2(-15, -15), true)

        if currentTab == 1 then
            local halfW = (imgui.GetWindowWidth() / 2) - 10
            imgui.BeginChild("DB_Area", imgui.ImVec2(halfW, -1), true)
            local q_changed = imgui.InputTextWithHint("##srch", u8"Поиск...", searchBuffer, 256)
            if q_changed or last_search == nil then
                local current_q = ru_lower(u8:decode(ffi.string(searchBuffer)))
                last_search, filtered_cache = current_q, {}
                for _, v in ipairs(item_db) do
                    if current_q == "" or v.lower_name:find(current_q, 1, true) or v.id:find(current_q, 1, true) then table.insert(filtered_cache, v) end
                end
                currentPage = 1
            end
            local start = (currentPage - 1) * itemsPerPage + 1
            for i = start, math.min(start + itemsPerPage - 1, #filtered_cache) do
                local item = filtered_cache[i]
                if imgui.Button(item.dsp_name .. "##db" .. i, imgui.ImVec2(-1, 28)) then
                    safe_copy(addName, item.u8_name, 256); safe_copy(addId, item.u8_id, 64)
                    safe_copy(addPrice, "100", 64); safe_copy(addAmount, "1", 64)
                    addIsAccessory[0], editIndex, open_add_modal = false, -1, true
                end
            end
            imgui.EndChild()

            imgui.SameLine()
            imgui.BeginChild("Queue_Area", imgui.ImVec2(halfW, -1), true)
            if imgui.Button(isRunning and u8"Остановить" or u8"Запустить закуп", imgui.ImVec2(-1, 40)) then
                if isRunning then stopProcess = true else runBuyingProcess() end
            end
            local item_to_delete = -1
            for i, item in ipairs(vars) do
                imgui.Text(item.str_name .. (item.str_id ~= "" and (" [ID: " .. item.str_id .. "]") or ""))
                imgui.SameLine(imgui.GetWindowWidth() - 80)
                if imgui.Button("X##" .. i, imgui.ImVec2(30, 22)) then item_to_delete = i end
            end
            if item_to_delete ~= -1 then table.remove(vars, item_to_delete); save_main_json() end
            imgui.EndChild()

        elseif currentTab == 2 then
            imgui.Text(u8"Запомненные предметы продажи")
            for _, name in ipairs(sale_names_cache) do
                local rec = sales_db[name]
                local buf = ensure_sale_buffers(name)
                imgui.Text(u8(name))
                imgui.PushItemWidth(120)
                if imgui.InputText("Цена##" .. name, buf.price, 64) then
                    upsert_sale_memory(name, ffi.string(buf.price), ffi.string(buf.amount))
                end
                imgui.SameLine()
                if imgui.InputText("Кол-во##" .. name, buf.amount, 64) then
                    upsert_sale_memory(name, ffi.string(buf.price), ffi.string(buf.amount))
                end
                imgui.PopItemWidth()
            end
            if #sale_names_cache == 0 then imgui.TextDisabled(u8"Пока нет сохраненных продаж") end

        elseif currentTab == 3 then
            if selected_date ~= "" and logs[selected_date] then
                for _, msg in ipairs(logs[selected_date]) do imgui.TextWrapped(u8(msg)) end
            else
                imgui.TextDisabled(u8"Логи пусты")
            end

        elseif currentTab == 4 then
            imgui.Text(u8"LMMR для MonetLoader / mimgui")

        elseif currentTab == 5 then
            if imgui.Checkbox(u8"Плавающая кнопка", show_screen_btn) then save_main_json() end
            if imgui.SliderFloat(u8"Размер кнопки", btn_size, 30.0, 150.0) then save_main_json() end
            if imgui.SliderInt(u8"Задержка (мс)", global_delay, 500, 3000) then save_main_json() end
            if imgui.Button(isScanning and u8"Остановить скан" or u8"Сканировать предметы", imgui.ImVec2(-1, 35)) then
                if isScanning then stopProcess = true else runAutoScan() end
            end

        elseif currentTab == 6 then
            imgui.InputText("##prof_name", profileNameBuffer, 256)
            if imgui.Button(u8"Сохранить профиль", imgui.ImVec2(180, 30)) then
                local pName = u8:decode(ffi.string(profileNameBuffer))
                if pName ~= "" then
                    local pItems = {}
                    for _, v in ipairs(vars) do
                        table.insert(pItems, {name = u8:decode(v.str_name), id = u8:decode(v.str_id), price = u8:decode(v.str_price), amount = u8:decode(v.str_amount), active = v.active[0], is_acc = v.is_acc[0]})
                    end
                    storage.profiles[pName] = pItems
                    save_main_json()
                end
            end
        end

        if open_add_modal then imgui.OpenPopup("CEF_Modal"); open_add_modal = false end
        if imgui.BeginPopupModal("CEF_Modal", nil, imgui.WindowFlags.AlwaysAutoResize) then
            imgui.InputText("Название", addName, 256)
            imgui.InputText("ID", addId, 64)
            imgui.InputText("Цена", addPrice, 64)
            imgui.InputText("Кол-во", addAmount, 64)
            imgui.Checkbox(u8"Аксессуар", addIsAccessory)
            if imgui.Button(u8"Сохранить", imgui.ImVec2(150, 30)) then
                local s_name, s_id = ffi.string(addName), ffi.string(addId)
                local s_price, s_amount = ffi.string(addPrice), ffi.string(addAmount)
                if editIndex == -1 then
                    table.insert(vars, {
                        name = imgui.new.char[256](string.sub(s_name, 1, 255)), id = imgui.new.char[64](string.sub(s_id, 1, 63)),
                        price = imgui.new.char[64](string.sub(s_price, 1, 63)), amount = imgui.new.char[64](string.sub(s_amount, 1, 63)),
                        active = imgui.new.bool(true), is_acc = imgui.new.bool(addIsAccessory[0]),
                        str_name = s_name, str_id = s_id, str_price = s_price, str_amount = s_amount
                    })
                end
                save_main_json(); imgui.CloseCurrentPopup()
            end
            imgui.SameLine()
            if imgui.Button(u8"Отмена", imgui.ImVec2(150, 30)) then imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end

        imgui.EndChild()
        imgui.End()
    end
end)

function main()
    while not isSampAvailable() do wait(100) end
    load_main_json(); load_item_db(); load_logs(); load_sales_db()

    lua_thread.create(function()
        while true do
            wait(15000)
            pcall(run_ultra_booster_tick)
        end
    end)

    while true do wait(0) end
end
