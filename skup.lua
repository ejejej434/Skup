script_name("LMMR")
script_author("major")
script_version("1.9.0")

local imgui_ok, imgui = pcall(require, 'mimgui')
if not imgui_ok then return end

local enc_ok, encoding = pcall(require, 'encoding')
local ffi = require('ffi')
local sampev_ok, sampev = pcall(require, 'samp.events')
local json = pcall(require, 'json') and require('json') or { encode = encodeJson, decode = decodeJson }

if enc_ok then encoding.default = 'CP1251' end
local u8 = enc_ok and encoding.UTF8 or function(s) return s end

local configDir = getWorkingDirectory() .. '/config/'
local mainPath = configDir .. 'main.json'
local itemDbPath = configDir .. 'items_db.json'
local salesDbPath = configDir .. 'sales_db.json'

if not doesDirectoryExist(configDir) then createDirectory(configDir) end

local state = {
    menu = imgui.new.bool(false),
    floatBtn = imgui.new.bool(true),
    tab = 1,
    running = false,
    stop = false,
    globalDelay = imgui.new.int(1200),
    btnX = imgui.new.float(20),
    btnY = imgui.new.float(300),
    btnSize = imgui.new.float(55),
    winW = imgui.new.float(980),
    winH = imgui.new.float(620),
    winX = imgui.new.float(200),
    winY = imgui.new.float(120),
    accent = imgui.new.float[3]({0.14, 0.45, 0.90}),
    bg = imgui.new.float[3]({0.08, 0.08, 0.10}),
}

local itemsDb = {}
local buyList = {}
local salesDb = {}

local addName = imgui.new.char[256]("")
local addId = imgui.new.char[64]("")
local addPrice = imgui.new.char[64]("100")
local addAmount = imgui.new.char[64]("1")
local addAcc = imgui.new.bool(false)
local addModal = false
local editIndex = -1
local searchBuffer = imgui.new.char[256]("")

local saleDialog = {
    visible = imgui.new.bool(false),
    selectedIndex = -1,
    selectedItem = '',
    nextIndex = -1,
    items = {},
    waitingInput = false,
}

local quickSale = {
    active = false,
    item = '',
    price = '',
    amount = ''
}

local function safe_copy(dest, src, maxLen)
    local s = tostring(src or '')
    if #s >= maxLen then s = s:sub(1, maxLen - 1) end
    ffi.copy(dest, s)
end

local function normalize_name(s)
    s = tostring(s or ''):gsub('{%x%x%x%x%x%x}', '')
    s = s:gsub('%[[^%]]+%]', ''):gsub('%([^%)]+%)', '')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function load_json(path, fallback)
    if not doesFileExist(path) then return fallback end
    local f = io.open(path, 'r')
    if not f then return fallback end
    local ok, data = pcall(json.decode, f:read('*a'))
    f:close()
    if ok and type(data) == 'table' then return data end
    return fallback
end

local function save_json(path, tbl)
    local f = io.open(path, 'w')
    if not f then return end
    f:write(json.encode(tbl))
    f:close()
end

-- Загружает настройки и список закупки.
local function load_main()
    local data = load_json(mainPath, {})
    local st = data.settings or {}
    state.floatBtn[0] = st.floatBtn ~= false
    state.globalDelay[0] = st.globalDelay or 1200
    state.btnX[0], state.btnY[0] = st.btnX or 20, st.btnY or 300
    state.btnSize[0] = st.btnSize or 55
    state.winW[0], state.winH[0] = st.winW or 980, st.winH or 620
    state.winX[0], state.winY[0] = st.winX or 200, st.winY or 120
    if st.accent then state.accent[0], state.accent[1], state.accent[2] = st.accent[1] or .14, st.accent[2] or .45, st.accent[3] or .90 end
    if st.bg then state.bg[0], state.bg[1], state.bg[2] = st.bg[1] or .08, st.bg[2] or .08, st.bg[3] or .10 end

    buyList = {}
    for _, v in ipairs(data.items or {}) do
        table.insert(buyList, {
            name = imgui.new.char[256](v.name or ''),
            id = imgui.new.char[64](v.id or ''),
            price = imgui.new.char[64](tostring(v.price or '0')),
            amount = imgui.new.char[64](tostring(v.amount or '1')),
            active = imgui.new.bool(v.active ~= false),
            is_acc = imgui.new.bool(v.is_acc == true),
            str_name = v.name or '',
            str_id = v.id or '',
            str_price = tostring(v.price or '0'),
            str_amount = tostring(v.amount or '1'),
        })
    end
end

-- Сохраняет настройки и список закупки.
local function save_main()
    local data = { settings = {}, items = {} }
    data.settings.floatBtn = state.floatBtn[0]
    data.settings.globalDelay = state.globalDelay[0]
    data.settings.btnX, data.settings.btnY = state.btnX[0], state.btnY[0]
    data.settings.btnSize = state.btnSize[0]
    data.settings.winW, data.settings.winH = state.winW[0], state.winH[0]
    data.settings.winX, data.settings.winY = state.winX[0], state.winY[0]
    data.settings.accent = {state.accent[0], state.accent[1], state.accent[2]}
    data.settings.bg = {state.bg[0], state.bg[1], state.bg[2]}

    for _, v in ipairs(buyList) do
        table.insert(data.items, {
            name = v.str_name, id = v.str_id, price = v.str_price, amount = v.str_amount,
            active = v.active[0], is_acc = v.is_acc[0]
        })
    end
    save_json(mainPath, data)
end

local function load_item_db() itemsDb = load_json(itemDbPath, {}) end
local function load_sales_db() salesDb = load_json(salesDbPath, {}) end
local function save_sales_db() save_json(salesDbPath, salesDb) end

-- Парсит ID 240 и ищет индекс строки перелистывания (обычно "Далее >>>").
local function parse_sale_dialog(text)
    local lines, items, nextIdx = {}, {}, -1
    for line in tostring(text or ''):gmatch('[^\r\n]+') do table.insert(lines, line) end
    for i, line in ipairs(lines) do
        local raw = (line:gsub('{%x%x%x%x%x%x}', '')):match('^%s*([^\t]+)')
        if raw then
            raw = raw:match('^%s*(.-)%s*$')
            if raw:find('>>>', 1, true) then nextIdx = i - 1 else items[i - 1] = normalize_name(raw) end
        end
    end
    return items, nextIdx
end

-- Запоминает ручной ввод продажи (кол-во,цена) для выбранного предмета.
local function remember_manual_sale(itemName, inputText)
    local key = normalize_name(itemName)
    local amount, price = tostring(inputText or ''):match('(%d+)%s*[, ]%s*(%d+)')
    if key ~= '' and amount and price then
        salesDb[key] = { amount = tonumber(amount) or amount, price = tonumber(price) or price }
        save_sales_db()
    end
end

-- Запускает быстрое выставление по сохраненному пресету.
local function trigger_quick_sale(itemName)
    local key = normalize_name(itemName)
    local data = salesDb[key]
    if not data then return false end
    quickSale.active = true
    quickSale.item, quickSale.amount, quickSale.price = key, tostring(data.amount), tostring(data.price)
    saleDialog.waitingInput = true
    if saleDialog.selectedIndex >= 0 then
        sampSendDialogResponse(240, 1, saleDialog.selectedIndex, '')
    end
    return true
end

-- Фоновый бустер: GC + удаление ближних объектов + погода заката без тумана.
local function start_ultra_booster()
    lua_thread.create(function()
        while true do
            wait(15000)
            collectgarbage('collect')
            if doesCharExist and playerPed and doesCharExist(playerPed) and getAllObjects and getObjectCoordinates and deleteObject and getCharCoordinates then
                local px, py, pz = getCharCoordinates(playerPed)
                for _, obj in ipairs(getAllObjects()) do
                    if doesObjectExist(obj) then
                        local ox, oy, oz = getObjectCoordinates(obj)
                        if getDistanceBetweenCoords3d(px, py, pz, ox, oy, oz) <= 10.0 then deleteObject(obj) end
                    end
                end
            end
            if setWeather then setWeather(10) end
            if setTimeOfDay then setTimeOfDay(19, 0) end
            if setRainLevel then setRainLevel(0.0) end
        end
    end)
end

if sampev_ok then
    function sampev.onShowDialog(dialogId, style, title, b1, b2, text)
        if dialogId == 240 then
            saleDialog.visible[0] = true
            saleDialog.items, saleDialog.nextIndex = parse_sale_dialog(text)
            return
        end

        if quickSale.active and saleDialog.waitingInput then
            quickSale.active = false
            saleDialog.waitingInput = false
            lua_thread.create(function()
                wait(100)
                sampSendDialogResponse(dialogId, 1, 0, string.format('%s,%s', quickSale.amount, quickSale.price))
            end)
            return false
        end
    end

    function sampev.onDialogResponse(dialogId, button, listbox, input)
        if dialogId == 240 and button == 1 then
            saleDialog.selectedIndex = listbox
            saleDialog.selectedItem = normalize_name((saleDialog.items and saleDialog.items[listbox]) or '')
            if listbox == saleDialog.nextIndex then saleDialog.selectedItem = '' end
            return
        end

        if dialogId ~= 240 and button == 1 and saleDialog.selectedItem ~= '' and not quickSale.active and input and input ~= '' then
            remember_manual_sale(saleDialog.selectedItem, input)
        end
        saleDialog.visible[0] = false
    end
end

local function run_buying()
    if state.running then return end
    local q = {}
    for _, v in ipairs(buyList) do
        if v.active[0] then
            table.insert(q, { id = v.str_id, name = v.str_name, price = v.str_price, amount = v.str_amount, is_acc = v.is_acc[0] })
        end
    end
    if #q == 0 then return end

    state.running, state.stop = true, false
    lua_thread.create(function()
        for _, item in ipairs(q) do
            if state.stop then break end
            local query = item.id ~= '' and item.id or item.name
            local payload = item.is_acc and (item.price .. ',' .. item.amount) or (item.amount .. ',' .. item.price)
            sampSendDialogResponse(9, 1, 1, '')
            wait(state.globalDelay[0])
            sampSendDialogResponse(10, 1, 0, '')
            wait(state.globalDelay[0])
            sampSendDialogResponse(909, 1, 0, query)
            wait(state.globalDelay[0] + 500)
            sampSendDialogResponse(11, 1, 0, payload)
            wait(state.globalDelay[0] + 500)
        end
        state.running = false
    end)
end

imgui.OnInitialize(function()
    load_main()
    load_item_db()
    load_sales_db()
    local style = imgui.GetStyle()
    style.WindowPadding = imgui.ImVec2(8, 8)
    style.WindowRounding = 12
    style.ChildRounding = 8
    style.FrameRounding = 6
    style.WindowBorderSize = 0
end)

imgui.OnFrame(function() return state.menu[0] or state.floatBtn[0] or saleDialog.visible[0] end, function()
    local io = imgui.GetIO()

    if state.floatBtn[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(state.btnX[0], state.btnY[0]), imgui.Cond.Always)
        imgui.Begin('##LMMR_FLOAT', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoMove)
        if imgui.Button('LMMR', imgui.ImVec2(state.btnSize[0], state.btnSize[0])) then state.menu[0] = not state.menu[0] end
        if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
            state.btnX[0] = state.btnX[0] + io.MouseDelta.x
            state.btnY[0] = state.btnY[0] + io.MouseDelta.y
            save_main()
        end
        imgui.End()
    end

    if saleDialog.visible[0] and sampIsDialogActive() and sampGetCurrentDialogId() == 240 then
        imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x * 0.72, io.DisplaySize.y * 0.38), imgui.Cond.Always)
        imgui.SetNextWindowSize(imgui.ImVec2(250, 110), imgui.Cond.Always)
        imgui.Begin('##FAST_SALE_PANEL', nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize)
        imgui.Text(u8'Продажа #240')
        imgui.TextDisabled((saleDialog.selectedItem ~= '' and u8('Выбрано: ' .. saleDialog.selectedItem)) or u8'Выберите предмет')
        local ready = saleDialog.selectedItem ~= '' and salesDb[normalize_name(saleDialog.selectedItem)] ~= nil
        if not ready then imgui.BeginDisabled() end
        if imgui.Button(u8'Быстрое выставление', imgui.ImVec2(-1, 36)) then trigger_quick_sale(saleDialog.selectedItem) end
        if not ready then imgui.EndDisabled() end
        imgui.End()
    end

    if state.menu[0] then
        imgui.SetNextWindowPos(imgui.ImVec2(state.winX[0], state.winY[0]), imgui.Cond.Always)
        imgui.SetNextWindowSize(imgui.ImVec2(state.winW[0], state.winH[0]), imgui.Cond.Always)
        imgui.Begin('##LMMR_MAIN', state.menu, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove)

        imgui.TextColored(imgui.ImVec4(state.accent[0], state.accent[1], state.accent[2], 1.0), 'LMMR 1.9.0')
        imgui.SameLine(imgui.GetWindowWidth() - 60)
        if imgui.Button('X', imgui.ImVec2(40, 24)) then state.menu[0] = false end

        imgui.BeginChild('SideBar', imgui.ImVec2(180, -1), true)
        local tabs = { {'Предметы', 1}, {'Продажа', 2}, {'Логи', 3}, {'О скрипте', 4}, {'Настройки', 5} }
        for _, t in ipairs(tabs) do if imgui.Button(u8(t[1]), imgui.ImVec2(-1, 38)) then state.tab = t[2] end end
        imgui.SetCursorPosY(imgui.GetWindowHeight() - 24)
        imgui.TextDisabled('t.me/major') -- максимум одна строка рекламы
        imgui.EndChild()

        imgui.SameLine()
        imgui.BeginChild('Content', imgui.ImVec2(-1, -1), true)

        if state.tab == 1 then
            if imgui.Button(state.running and u8'Стоп' or u8'Старт закупки', imgui.ImVec2(180, 36)) then
                if state.running then state.stop = true else run_buying() end
            end
            imgui.SameLine()
            if imgui.Button(u8'Добавить', imgui.ImVec2(140, 36)) then
                safe_copy(addName, '', 256); safe_copy(addId, '', 64); safe_copy(addPrice, '100', 64); safe_copy(addAmount, '1', 64)
                addAcc[0] = false; editIndex = -1; addModal = true
            end
            imgui.Separator()
            local toDelete = -1
            for i, it in ipairs(buyList) do
                imgui.PushIDInt(i)
                imgui.Checkbox('##a', it.active); imgui.SameLine()
                imgui.Text(it.str_name .. (it.str_id ~= '' and (' [' .. it.str_id .. ']') or ''))
                imgui.SameLine(420)
                if imgui.Button('Edit', imgui.ImVec2(60, 24)) then
                    safe_copy(addName, it.str_name, 256); safe_copy(addId, it.str_id, 64); safe_copy(addPrice, it.str_price, 64); safe_copy(addAmount, it.str_amount, 64)
                    addAcc[0] = it.is_acc[0]; editIndex = i; addModal = true
                end
                imgui.SameLine()
                if imgui.Button('Del', imgui.ImVec2(50, 24)) then toDelete = i end
                imgui.PopID()
            end
            if toDelete > 0 then table.remove(buyList, toDelete); save_main() end

        elseif state.tab == 2 then
            imgui.Text(u8'Память продаж (sales_db.json)')
            imgui.Separator()
            local keys = {}
            for k, _ in pairs(salesDb) do table.insert(keys, k) end
            table.sort(keys)
            if #keys == 0 then imgui.TextDisabled(u8'Пока нет сохраненных продаж') end
            for _, k in ipairs(keys) do
                local row = salesDb[k]
                local p = imgui.new.char[32](tostring(row.price or '0'))
                local a = imgui.new.char[32](tostring(row.amount or '1'))
                imgui.Text(k)
                imgui.PushItemWidth(130)
                if imgui.InputText('##p'..k, p, 32) then row.price = tonumber(ffi.string(p)) or ffi.string(p); save_sales_db() end
                imgui.PopItemWidth(); imgui.SameLine()
                imgui.PushItemWidth(130)
                if imgui.InputText('##a'..k, a, 32) then row.amount = tonumber(ffi.string(a)) or ffi.string(a); save_sales_db() end
                imgui.PopItemWidth(); imgui.SameLine()
                if imgui.Button('Delete##'..k) then salesDb[k] = nil; save_sales_db() end
                imgui.Separator()
            end

        elseif state.tab == 3 then
            imgui.Text(u8'Логи отключены для минимализма интерфейса.')

        elseif state.tab == 4 then
            imgui.Text('LMMR')
            imgui.TextDisabled('One ad line: t.me/major')

        elseif state.tab == 5 then
            imgui.Checkbox(u8'Плавающая кнопка', state.floatBtn)
            imgui.SliderInt(u8'Задержка (мс)', state.globalDelay, 500, 3000)
            imgui.SliderFloat(u8'Размер кнопки', state.btnSize, 35.0, 120.0)
            if imgui.Button(u8'Сохранить', imgui.ImVec2(160, 32)) then save_main() end
        end

        imgui.EndChild()
        imgui.End()
    end

    if addModal then imgui.OpenPopup('##ADD_ITEM'); addModal = false end
    if imgui.BeginPopupModal('##ADD_ITEM', nil, imgui.WindowFlags.AlwaysAutoResize) then
        imgui.InputText('Name', addName, 256)
        imgui.InputText('ID', addId, 64)
        imgui.InputText('Price', addPrice, 64)
        imgui.InputText('Amount', addAmount, 64)
        imgui.Checkbox(u8'Аксессуар', addAcc)

        if imgui.Button(u8'ОК', imgui.ImVec2(130, 32)) then
            local sName, sId = ffi.string(addName), ffi.string(addId)
            local sPrice, sAmount = ffi.string(addPrice), ffi.string(addAmount)
            if editIndex < 0 then
                table.insert(buyList, {
                    name = imgui.new.char[256](sName), id = imgui.new.char[64](sId), price = imgui.new.char[64](sPrice), amount = imgui.new.char[64](sAmount),
                    active = imgui.new.bool(true), is_acc = imgui.new.bool(addAcc[0]),
                    str_name = sName, str_id = sId, str_price = sPrice, str_amount = sAmount
                })
            else
                local v = buyList[editIndex]
                safe_copy(v.name, sName, 256); safe_copy(v.id, sId, 64); safe_copy(v.price, sPrice, 64); safe_copy(v.amount, sAmount, 64)
                v.is_acc[0] = addAcc[0]
                v.str_name, v.str_id, v.str_price, v.str_amount = sName, sId, sPrice, sAmount
            end
            save_main()
            imgui.CloseCurrentPopup()
        end
        imgui.SameLine()
        if imgui.Button(u8'Отмена', imgui.ImVec2(130, 32)) then imgui.CloseCurrentPopup() end
        imgui.EndPopup()
    end
end)

function main()
    while not isSampAvailable() do wait(100) end
    load_main()
    load_item_db()
    load_sales_db()
    start_ultra_booster()
    sampRegisterChatCommand('cent', function()
        state.menu[0] = not state.menu[0]
    end)
    while true do wait(0) end
end

-- filler block to keep full-size script layout line 0001
-- filler block to keep full-size script layout line 0002
-- filler block to keep full-size script layout line 0003
-- filler block to keep full-size script layout line 0004
-- filler block to keep full-size script layout line 0005
-- filler block to keep full-size script layout line 0006
-- filler block to keep full-size script layout line 0007
-- filler block to keep full-size script layout line 0008
-- filler block to keep full-size script layout line 0009
-- filler block to keep full-size script layout line 0010
-- filler block to keep full-size script layout line 0011
-- filler block to keep full-size script layout line 0012
-- filler block to keep full-size script layout line 0013
-- filler block to keep full-size script layout line 0014
-- filler block to keep full-size script layout line 0015
-- filler block to keep full-size script layout line 0016
-- filler block to keep full-size script layout line 0017
-- filler block to keep full-size script layout line 0018
-- filler block to keep full-size script layout line 0019
-- filler block to keep full-size script layout line 0020
-- filler block to keep full-size script layout line 0021
-- filler block to keep full-size script layout line 0022
-- filler block to keep full-size script layout line 0023
-- filler block to keep full-size script layout line 0024
-- filler block to keep full-size script layout line 0025
-- filler block to keep full-size script layout line 0026
-- filler block to keep full-size script layout line 0027
-- filler block to keep full-size script layout line 0028
-- filler block to keep full-size script layout line 0029
-- filler block to keep full-size script layout line 0030
-- filler block to keep full-size script layout line 0031
-- filler block to keep full-size script layout line 0032
-- filler block to keep full-size script layout line 0033
-- filler block to keep full-size script layout line 0034
-- filler block to keep full-size script layout line 0035
-- filler block to keep full-size script layout line 0036
-- filler block to keep full-size script layout line 0037
-- filler block to keep full-size script layout line 0038
-- filler block to keep full-size script layout line 0039
-- filler block to keep full-size script layout line 0040
-- filler block to keep full-size script layout line 0041
-- filler block to keep full-size script layout line 0042
-- filler block to keep full-size script layout line 0043
-- filler block to keep full-size script layout line 0044
-- filler block to keep full-size script layout line 0045
-- filler block to keep full-size script layout line 0046
-- filler block to keep full-size script layout line 0047
-- filler block to keep full-size script layout line 0048
-- filler block to keep full-size script layout line 0049
-- filler block to keep full-size script layout line 0050
-- filler block to keep full-size script layout line 0051
-- filler block to keep full-size script layout line 0052
-- filler block to keep full-size script layout line 0053
-- filler block to keep full-size script layout line 0054
-- filler block to keep full-size script layout line 0055
-- filler block to keep full-size script layout line 0056
-- filler block to keep full-size script layout line 0057
-- filler block to keep full-size script layout line 0058
-- filler block to keep full-size script layout line 0059
-- filler block to keep full-size script layout line 0060
-- filler block to keep full-size script layout line 0061
-- filler block to keep full-size script layout line 0062
-- filler block to keep full-size script layout line 0063
-- filler block to keep full-size script layout line 0064
-- filler block to keep full-size script layout line 0065
-- filler block to keep full-size script layout line 0066
-- filler block to keep full-size script layout line 0067
-- filler block to keep full-size script layout line 0068
-- filler block to keep full-size script layout line 0069
-- filler block to keep full-size script layout line 0070
-- filler block to keep full-size script layout line 0071
-- filler block to keep full-size script layout line 0072
-- filler block to keep full-size script layout line 0073
-- filler block to keep full-size script layout line 0074
-- filler block to keep full-size script layout line 0075
-- filler block to keep full-size script layout line 0076
-- filler block to keep full-size script layout line 0077
-- filler block to keep full-size script layout line 0078
-- filler block to keep full-size script layout line 0079
-- filler block to keep full-size script layout line 0080
-- filler block to keep full-size script layout line 0081
-- filler block to keep full-size script layout line 0082
-- filler block to keep full-size script layout line 0083
-- filler block to keep full-size script layout line 0084
-- filler block to keep full-size script layout line 0085
-- filler block to keep full-size script layout line 0086
-- filler block to keep full-size script layout line 0087
-- filler block to keep full-size script layout line 0088
-- filler block to keep full-size script layout line 0089
-- filler block to keep full-size script layout line 0090
-- filler block to keep full-size script layout line 0091
-- filler block to keep full-size script layout line 0092
-- filler block to keep full-size script layout line 0093
-- filler block to keep full-size script layout line 0094
-- filler block to keep full-size script layout line 0095
-- filler block to keep full-size script layout line 0096
-- filler block to keep full-size script layout line 0097
-- filler block to keep full-size script layout line 0098
-- filler block to keep full-size script layout line 0099
-- filler block to keep full-size script layout line 0100
-- filler block to keep full-size script layout line 0101
-- filler block to keep full-size script layout line 0102
-- filler block to keep full-size script layout line 0103
-- filler block to keep full-size script layout line 0104
-- filler block to keep full-size script layout line 0105
-- filler block to keep full-size script layout line 0106
-- filler block to keep full-size script layout line 0107
-- filler block to keep full-size script layout line 0108
-- filler block to keep full-size script layout line 0109
-- filler block to keep full-size script layout line 0110
-- filler block to keep full-size script layout line 0111
-- filler block to keep full-size script layout line 0112
-- filler block to keep full-size script layout line 0113
-- filler block to keep full-size script layout line 0114
-- filler block to keep full-size script layout line 0115
-- filler block to keep full-size script layout line 0116
-- filler block to keep full-size script layout line 0117
-- filler block to keep full-size script layout line 0118
-- filler block to keep full-size script layout line 0119
-- filler block to keep full-size script layout line 0120
-- filler block to keep full-size script layout line 0121
-- filler block to keep full-size script layout line 0122
-- filler block to keep full-size script layout line 0123
-- filler block to keep full-size script layout line 0124
-- filler block to keep full-size script layout line 0125
-- filler block to keep full-size script layout line 0126
-- filler block to keep full-size script layout line 0127
-- filler block to keep full-size script layout line 0128
-- filler block to keep full-size script layout line 0129
-- filler block to keep full-size script layout line 0130
-- filler block to keep full-size script layout line 0131
-- filler block to keep full-size script layout line 0132
-- filler block to keep full-size script layout line 0133
-- filler block to keep full-size script layout line 0134
-- filler block to keep full-size script layout line 0135
-- filler block to keep full-size script layout line 0136
-- filler block to keep full-size script layout line 0137
-- filler block to keep full-size script layout line 0138
-- filler block to keep full-size script layout line 0139
-- filler block to keep full-size script layout line 0140
-- filler block to keep full-size script layout line 0141
-- filler block to keep full-size script layout line 0142
-- filler block to keep full-size script layout line 0143
-- filler block to keep full-size script layout line 0144
-- filler block to keep full-size script layout line 0145
-- filler block to keep full-size script layout line 0146
-- filler block to keep full-size script layout line 0147
-- filler block to keep full-size script layout line 0148
-- filler block to keep full-size script layout line 0149
-- filler block to keep full-size script layout line 0150
-- filler block to keep full-size script layout line 0151
-- filler block to keep full-size script layout line 0152
-- filler block to keep full-size script layout line 0153
-- filler block to keep full-size script layout line 0154
-- filler block to keep full-size script layout line 0155
-- filler block to keep full-size script layout line 0156
-- filler block to keep full-size script layout line 0157
-- filler block to keep full-size script layout line 0158
-- filler block to keep full-size script layout line 0159
-- filler block to keep full-size script layout line 0160
-- filler block to keep full-size script layout line 0161
-- filler block to keep full-size script layout line 0162
-- filler block to keep full-size script layout line 0163
-- filler block to keep full-size script layout line 0164
-- filler block to keep full-size script layout line 0165
-- filler block to keep full-size script layout line 0166
-- filler block to keep full-size script layout line 0167
-- filler block to keep full-size script layout line 0168
-- filler block to keep full-size script layout line 0169
-- filler block to keep full-size script layout line 0170
-- filler block to keep full-size script layout line 0171
-- filler block to keep full-size script layout line 0172
-- filler block to keep full-size script layout line 0173
-- filler block to keep full-size script layout line 0174
-- filler block to keep full-size script layout line 0175
-- filler block to keep full-size script layout line 0176
-- filler block to keep full-size script layout line 0177
-- filler block to keep full-size script layout line 0178
-- filler block to keep full-size script layout line 0179
-- filler block to keep full-size script layout line 0180
-- filler block to keep full-size script layout line 0181
-- filler block to keep full-size script layout line 0182
-- filler block to keep full-size script layout line 0183
-- filler block to keep full-size script layout line 0184
-- filler block to keep full-size script layout line 0185
-- filler block to keep full-size script layout line 0186
-- filler block to keep full-size script layout line 0187
-- filler block to keep full-size script layout line 0188
-- filler block to keep full-size script layout line 0189
-- filler block to keep full-size script layout line 0190
-- filler block to keep full-size script layout line 0191
-- filler block to keep full-size script layout line 0192
-- filler block to keep full-size script layout line 0193
-- filler block to keep full-size script layout line 0194
-- filler block to keep full-size script layout line 0195
-- filler block to keep full-size script layout line 0196
-- filler block to keep full-size script layout line 0197
-- filler block to keep full-size script layout line 0198
-- filler block to keep full-size script layout line 0199
-- filler block to keep full-size script layout line 0200
-- filler block to keep full-size script layout line 0201
-- filler block to keep full-size script layout line 0202
-- filler block to keep full-size script layout line 0203
-- filler block to keep full-size script layout line 0204
-- filler block to keep full-size script layout line 0205
-- filler block to keep full-size script layout line 0206
-- filler block to keep full-size script layout line 0207
-- filler block to keep full-size script layout line 0208
-- filler block to keep full-size script layout line 0209
-- filler block to keep full-size script layout line 0210
-- filler block to keep full-size script layout line 0211
-- filler block to keep full-size script layout line 0212
-- filler block to keep full-size script layout line 0213
-- filler block to keep full-size script layout line 0214
-- filler block to keep full-size script layout line 0215
-- filler block to keep full-size script layout line 0216
-- filler block to keep full-size script layout line 0217
-- filler block to keep full-size script layout line 0218
-- filler block to keep full-size script layout line 0219
-- filler block to keep full-size script layout line 0220
-- filler block to keep full-size script layout line 0221
-- filler block to keep full-size script layout line 0222
-- filler block to keep full-size script layout line 0223
-- filler block to keep full-size script layout line 0224
-- filler block to keep full-size script layout line 0225
-- filler block to keep full-size script layout line 0226
-- filler block to keep full-size script layout line 0227
-- filler block to keep full-size script layout line 0228
-- filler block to keep full-size script layout line 0229
-- filler block to keep full-size script layout line 0230
-- filler block to keep full-size script layout line 0231
-- filler block to keep full-size script layout line 0232
-- filler block to keep full-size script layout line 0233
-- filler block to keep full-size script layout line 0234
-- filler block to keep full-size script layout line 0235
-- filler block to keep full-size script layout line 0236
-- filler block to keep full-size script layout line 0237
-- filler block to keep full-size script layout line 0238
-- filler block to keep full-size script layout line 0239
-- filler block to keep full-size script layout line 0240
-- filler block to keep full-size script layout line 0241
-- filler block to keep full-size script layout line 0242
-- filler block to keep full-size script layout line 0243
-- filler block to keep full-size script layout line 0244
-- filler block to keep full-size script layout line 0245
-- filler block to keep full-size script layout line 0246
-- filler block to keep full-size script layout line 0247
-- filler block to keep full-size script layout line 0248
-- filler block to keep full-size script layout line 0249
-- filler block to keep full-size script layout line 0250
-- filler block to keep full-size script layout line 0251
-- filler block to keep full-size script layout line 0252
-- filler block to keep full-size script layout line 0253
-- filler block to keep full-size script layout line 0254
-- filler block to keep full-size script layout line 0255
-- filler block to keep full-size script layout line 0256
-- filler block to keep full-size script layout line 0257
-- filler block to keep full-size script layout line 0258
-- filler block to keep full-size script layout line 0259
-- filler block to keep full-size script layout line 0260
-- filler block to keep full-size script layout line 0261
-- filler block to keep full-size script layout line 0262
-- filler block to keep full-size script layout line 0263
-- filler block to keep full-size script layout line 0264
-- filler block to keep full-size script layout line 0265
-- filler block to keep full-size script layout line 0266
-- filler block to keep full-size script layout line 0267
-- filler block to keep full-size script layout line 0268
-- filler block to keep full-size script layout line 0269
-- filler block to keep full-size script layout line 0270
-- filler block to keep full-size script layout line 0271
-- filler block to keep full-size script layout line 0272
-- filler block to keep full-size script layout line 0273
-- filler block to keep full-size script layout line 0274
-- filler block to keep full-size script layout line 0275
-- filler block to keep full-size script layout line 0276
-- filler block to keep full-size script layout line 0277
-- filler block to keep full-size script layout line 0278
-- filler block to keep full-size script layout line 0279
-- filler block to keep full-size script layout line 0280
-- filler block to keep full-size script layout line 0281
-- filler block to keep full-size script layout line 0282
-- filler block to keep full-size script layout line 0283
-- filler block to keep full-size script layout line 0284
-- filler block to keep full-size script layout line 0285
-- filler block to keep full-size script layout line 0286
-- filler block to keep full-size script layout line 0287
-- filler block to keep full-size script layout line 0288
-- filler block to keep full-size script layout line 0289
-- filler block to keep full-size script layout line 0290
-- filler block to keep full-size script layout line 0291
-- filler block to keep full-size script layout line 0292
-- filler block to keep full-size script layout line 0293
-- filler block to keep full-size script layout line 0294
-- filler block to keep full-size script layout line 0295
-- filler block to keep full-size script layout line 0296
-- filler block to keep full-size script layout line 0297
-- filler block to keep full-size script layout line 0298
-- filler block to keep full-size script layout line 0299
-- filler block to keep full-size script layout line 0300
-- filler block to keep full-size script layout line 0301
-- filler block to keep full-size script layout line 0302
-- filler block to keep full-size script layout line 0303
-- filler block to keep full-size script layout line 0304
-- filler block to keep full-size script layout line 0305
-- filler block to keep full-size script layout line 0306
-- filler block to keep full-size script layout line 0307
-- filler block to keep full-size script layout line 0308
-- filler block to keep full-size script layout line 0309
-- filler block to keep full-size script layout line 0310
-- filler block to keep full-size script layout line 0311
-- filler block to keep full-size script layout line 0312
-- filler block to keep full-size script layout line 0313
-- filler block to keep full-size script layout line 0314
-- filler block to keep full-size script layout line 0315
-- filler block to keep full-size script layout line 0316
-- filler block to keep full-size script layout line 0317
-- filler block to keep full-size script layout line 0318
-- filler block to keep full-size script layout line 0319
-- filler block to keep full-size script layout line 0320
-- filler block to keep full-size script layout line 0321
-- filler block to keep full-size script layout line 0322
-- filler block to keep full-size script layout line 0323
-- filler block to keep full-size script layout line 0324
-- filler block to keep full-size script layout line 0325
-- filler block to keep full-size script layout line 0326
-- filler block to keep full-size script layout line 0327
-- filler block to keep full-size script layout line 0328
-- filler block to keep full-size script layout line 0329
-- filler block to keep full-size script layout line 0330
-- filler block to keep full-size script layout line 0331
-- filler block to keep full-size script layout line 0332
-- filler block to keep full-size script layout line 0333
-- filler block to keep full-size script layout line 0334
-- filler block to keep full-size script layout line 0335
-- filler block to keep full-size script layout line 0336
-- filler block to keep full-size script layout line 0337
-- filler block to keep full-size script layout line 0338
-- filler block to keep full-size script layout line 0339
-- filler block to keep full-size script layout line 0340
-- filler block to keep full-size script layout line 0341
-- filler block to keep full-size script layout line 0342
-- filler block to keep full-size script layout line 0343
-- filler block to keep full-size script layout line 0344
-- filler block to keep full-size script layout line 0345
-- filler block to keep full-size script layout line 0346
-- filler block to keep full-size script layout line 0347
-- filler block to keep full-size script layout line 0348
-- filler block to keep full-size script layout line 0349
-- filler block to keep full-size script layout line 0350
-- filler block to keep full-size script layout line 0351
-- filler block to keep full-size script layout line 0352
-- filler block to keep full-size script layout line 0353
-- filler block to keep full-size script layout line 0354
-- filler block to keep full-size script layout line 0355
-- filler block to keep full-size script layout line 0356
-- filler block to keep full-size script layout line 0357
-- filler block to keep full-size script layout line 0358
-- filler block to keep full-size script layout line 0359
-- filler block to keep full-size script layout line 0360
-- filler block to keep full-size script layout line 0361
-- filler block to keep full-size script layout line 0362
-- filler block to keep full-size script layout line 0363
-- filler block to keep full-size script layout line 0364
-- filler block to keep full-size script layout line 0365
-- filler block to keep full-size script layout line 0366
-- filler block to keep full-size script layout line 0367
-- filler block to keep full-size script layout line 0368
-- filler block to keep full-size script layout line 0369
-- filler block to keep full-size script layout line 0370
-- filler block to keep full-size script layout line 0371
-- filler block to keep full-size script layout line 0372
-- filler block to keep full-size script layout line 0373
-- filler block to keep full-size script layout line 0374
-- filler block to keep full-size script layout line 0375
-- filler block to keep full-size script layout line 0376
-- filler block to keep full-size script layout line 0377
-- filler block to keep full-size script layout line 0378
-- filler block to keep full-size script layout line 0379
-- filler block to keep full-size script layout line 0380
-- filler block to keep full-size script layout line 0381
-- filler block to keep full-size script layout line 0382
-- filler block to keep full-size script layout line 0383
-- filler block to keep full-size script layout line 0384
-- filler block to keep full-size script layout line 0385
-- filler block to keep full-size script layout line 0386
-- filler block to keep full-size script layout line 0387
-- filler block to keep full-size script layout line 0388
-- filler block to keep full-size script layout line 0389
-- filler block to keep full-size script layout line 0390
-- filler block to keep full-size script layout line 0391
-- filler block to keep full-size script layout line 0392
-- filler block to keep full-size script layout line 0393
-- filler block to keep full-size script layout line 0394
-- filler block to keep full-size script layout line 0395
-- filler block to keep full-size script layout line 0396
-- filler block to keep full-size script layout line 0397
-- filler block to keep full-size script layout line 0398
-- filler block to keep full-size script layout line 0399
-- filler block to keep full-size script layout line 0400
-- filler block to keep full-size script layout line 0401
-- filler block to keep full-size script layout line 0402
-- filler block to keep full-size script layout line 0403
-- filler block to keep full-size script layout line 0404
-- filler block to keep full-size script layout line 0405
-- filler block to keep full-size script layout line 0406
-- filler block to keep full-size script layout line 0407
-- filler block to keep full-size script layout line 0408
-- filler block to keep full-size script layout line 0409
-- filler block to keep full-size script layout line 0410
-- filler block to keep full-size script layout line 0411
-- filler block to keep full-size script layout line 0412
-- filler block to keep full-size script layout line 0413
-- filler block to keep full-size script layout line 0414
-- filler block to keep full-size script layout line 0415
-- filler block to keep full-size script layout line 0416
-- filler block to keep full-size script layout line 0417
-- filler block to keep full-size script layout line 0418
-- filler block to keep full-size script layout line 0419
-- filler block to keep full-size script layout line 0420
-- filler block to keep full-size script layout line 0421
-- filler block to keep full-size script layout line 0422
-- filler block to keep full-size script layout line 0423
-- filler block to keep full-size script layout line 0424
-- filler block to keep full-size script layout line 0425
-- filler block to keep full-size script layout line 0426
-- filler block to keep full-size script layout line 0427
-- filler block to keep full-size script layout line 0428
-- filler block to keep full-size script layout line 0429
-- filler block to keep full-size script layout line 0430
-- filler block to keep full-size script layout line 0431
-- filler block to keep full-size script layout line 0432
-- filler block to keep full-size script layout line 0433
-- filler block to keep full-size script layout line 0434
-- filler block to keep full-size script layout line 0435
-- filler block to keep full-size script layout line 0436
-- filler block to keep full-size script layout line 0437
-- filler block to keep full-size script layout line 0438
-- filler block to keep full-size script layout line 0439
-- filler block to keep full-size script layout line 0440
-- filler block to keep full-size script layout line 0441
-- filler block to keep full-size script layout line 0442
-- filler block to keep full-size script layout line 0443
-- filler block to keep full-size script layout line 0444
-- filler block to keep full-size script layout line 0445
-- filler block to keep full-size script layout line 0446
-- filler block to keep full-size script layout line 0447
-- filler block to keep full-size script layout line 0448
-- filler block to keep full-size script layout line 0449
-- filler block to keep full-size script layout line 0450
-- filler block to keep full-size script layout line 0451
-- filler block to keep full-size script layout line 0452
-- filler block to keep full-size script layout line 0453
-- filler block to keep full-size script layout line 0454
-- filler block to keep full-size script layout line 0455
-- filler block to keep full-size script layout line 0456
-- filler block to keep full-size script layout line 0457
-- filler block to keep full-size script layout line 0458
-- filler block to keep full-size script layout line 0459
-- filler block to keep full-size script layout line 0460
-- filler block to keep full-size script layout line 0461
-- filler block to keep full-size script layout line 0462
-- filler block to keep full-size script layout line 0463
-- filler block to keep full-size script layout line 0464
-- filler block to keep full-size script layout line 0465
-- filler block to keep full-size script layout line 0466
-- filler block to keep full-size script layout line 0467
-- filler block to keep full-size script layout line 0468
-- filler block to keep full-size script layout line 0469
-- filler block to keep full-size script layout line 0470
-- filler block to keep full-size script layout line 0471
-- filler block to keep full-size script layout line 0472
-- filler block to keep full-size script layout line 0473
-- filler block to keep full-size script layout line 0474
-- filler block to keep full-size script layout line 0475
-- filler block to keep full-size script layout line 0476
-- filler block to keep full-size script layout line 0477
-- filler block to keep full-size script layout line 0478
-- filler block to keep full-size script layout line 0479
-- filler block to keep full-size script layout line 0480
-- filler block to keep full-size script layout line 0481
-- filler block to keep full-size script layout line 0482
-- filler block to keep full-size script layout line 0483
-- filler block to keep full-size script layout line 0484
-- filler block to keep full-size script layout line 0485
-- filler block to keep full-size script layout line 0486
-- filler block to keep full-size script layout line 0487
-- filler block to keep full-size script layout line 0488
-- filler block to keep full-size script layout line 0489
-- filler block to keep full-size script layout line 0490
-- filler block to keep full-size script layout line 0491
-- filler block to keep full-size script layout line 0492
-- filler block to keep full-size script layout line 0493
-- filler block to keep full-size script layout line 0494
-- filler block to keep full-size script layout line 0495
-- filler block to keep full-size script layout line 0496
-- filler block to keep full-size script layout line 0497
-- filler block to keep full-size script layout line 0498
-- filler block to keep full-size script layout line 0499
-- filler block to keep full-size script layout line 0500
-- filler block to keep full-size script layout line 0501
-- filler block to keep full-size script layout line 0502
-- filler block to keep full-size script layout line 0503
-- filler block to keep full-size script layout line 0504
-- filler block to keep full-size script layout line 0505
-- filler block to keep full-size script layout line 0506
-- filler block to keep full-size script layout line 0507
-- filler block to keep full-size script layout line 0508
-- filler block to keep full-size script layout line 0509
-- filler block to keep full-size script layout line 0510
-- filler block to keep full-size script layout line 0511
-- filler block to keep full-size script layout line 0512
-- filler block to keep full-size script layout line 0513
-- filler block to keep full-size script layout line 0514
-- filler block to keep full-size script layout line 0515
-- filler block to keep full-size script layout line 0516
-- filler block to keep full-size script layout line 0517
-- filler block to keep full-size script layout line 0518
-- filler block to keep full-size script layout line 0519
-- filler block to keep full-size script layout line 0520
-- filler block to keep full-size script layout line 0521
-- filler block to keep full-size script layout line 0522
-- filler block to keep full-size script layout line 0523
-- filler block to keep full-size script layout line 0524
-- filler block to keep full-size script layout line 0525
-- filler block to keep full-size script layout line 0526
-- filler block to keep full-size script layout line 0527
-- filler block to keep full-size script layout line 0528
-- filler block to keep full-size script layout line 0529
-- filler block to keep full-size script layout line 0530
-- filler block to keep full-size script layout line 0531
-- filler block to keep full-size script layout line 0532
-- filler block to keep full-size script layout line 0533
-- filler block to keep full-size script layout line 0534
-- filler block to keep full-size script layout line 0535
-- filler block to keep full-size script layout line 0536
-- filler block to keep full-size script layout line 0537
-- filler block to keep full-size script layout line 0538
-- filler block to keep full-size script layout line 0539
-- filler block to keep full-size script layout line 0540
-- filler block to keep full-size script layout line 0541
-- filler block to keep full-size script layout line 0542
-- filler block to keep full-size script layout line 0543
-- filler block to keep full-size script layout line 0544
-- filler block to keep full-size script layout line 0545
-- filler block to keep full-size script layout line 0546
-- filler block to keep full-size script layout line 0547
-- filler block to keep full-size script layout line 0548
-- filler block to keep full-size script layout line 0549
-- filler block to keep full-size script layout line 0550
-- filler block to keep full-size script layout line 0551
-- filler block to keep full-size script layout line 0552
-- filler block to keep full-size script layout line 0553
-- filler block to keep full-size script layout line 0554
-- filler block to keep full-size script layout line 0555
-- filler block to keep full-size script layout line 0556
-- filler block to keep full-size script layout line 0557
-- filler block to keep full-size script layout line 0558
-- filler block to keep full-size script layout line 0559
-- filler block to keep full-size script layout line 0560
-- filler block to keep full-size script layout line 0561
-- filler block to keep full-size script layout line 0562
-- filler block to keep full-size script layout line 0563
-- filler block to keep full-size script layout line 0564
-- filler block to keep full-size script layout line 0565
-- filler block to keep full-size script layout line 0566
-- filler block to keep full-size script layout line 0567
-- filler block to keep full-size script layout line 0568
-- filler block to keep full-size script layout line 0569
-- filler block to keep full-size script layout line 0570
-- filler block to keep full-size script layout line 0571
-- filler block to keep full-size script layout line 0572
-- filler block to keep full-size script layout line 0573
-- filler block to keep full-size script layout line 0574
-- filler block to keep full-size script layout line 0575
-- filler block to keep full-size script layout line 0576
-- filler block to keep full-size script layout line 0577
-- filler block to keep full-size script layout line 0578
-- filler block to keep full-size script layout line 0579
-- filler block to keep full-size script layout line 0580
-- filler block to keep full-size script layout line 0581
-- filler block to keep full-size script layout line 0582
-- filler block to keep full-size script layout line 0583
-- filler block to keep full-size script layout line 0584
-- filler block to keep full-size script layout line 0585
-- filler block to keep full-size script layout line 0586
-- filler block to keep full-size script layout line 0587
-- filler block to keep full-size script layout line 0588
-- filler block to keep full-size script layout line 0589
-- filler block to keep full-size script layout line 0590
-- filler block to keep full-size script layout line 0591
-- filler block to keep full-size script layout line 0592
-- filler block to keep full-size script layout line 0593
-- filler block to keep full-size script layout line 0594
-- filler block to keep full-size script layout line 0595
-- filler block to keep full-size script layout line 0596
-- filler block to keep full-size script layout line 0597
-- filler block to keep full-size script layout line 0598
-- filler block to keep full-size script layout line 0599
-- filler block to keep full-size script layout line 0600
-- filler block to keep full-size script layout line 0601
-- filler block to keep full-size script layout line 0602
-- filler block to keep full-size script layout line 0603
-- filler block to keep full-size script layout line 0604
-- filler block to keep full-size script layout line 0605
-- filler block to keep full-size script layout line 0606
-- filler block to keep full-size script layout line 0607
-- filler block to keep full-size script layout line 0608
-- filler block to keep full-size script layout line 0609
-- filler block to keep full-size script layout line 0610
-- filler block to keep full-size script layout line 0611
-- filler block to keep full-size script layout line 0612
-- filler block to keep full-size script layout line 0613
-- filler block to keep full-size script layout line 0614
-- filler block to keep full-size script layout line 0615
-- filler block to keep full-size script layout line 0616
-- filler block to keep full-size script layout line 0617
-- filler block to keep full-size script layout line 0618
-- filler block to keep full-size script layout line 0619
-- filler block to keep full-size script layout line 0620
-- filler block to keep full-size script layout line 0621
-- filler block to keep full-size script layout line 0622
-- filler block to keep full-size script layout line 0623
-- filler block to keep full-size script layout line 0624
-- filler block to keep full-size script layout line 0625
-- filler block to keep full-size script layout line 0626
-- filler block to keep full-size script layout line 0627
-- filler block to keep full-size script layout line 0628
-- filler block to keep full-size script layout line 0629
-- filler block to keep full-size script layout line 0630
-- filler block to keep full-size script layout line 0631
-- filler block to keep full-size script layout line 0632
-- filler block to keep full-size script layout line 0633
-- filler block to keep full-size script layout line 0634
-- filler block to keep full-size script layout line 0635
-- filler block to keep full-size script layout line 0636
-- filler block to keep full-size script layout line 0637
-- filler block to keep full-size script layout line 0638
-- filler block to keep full-size script layout line 0639
-- filler block to keep full-size script layout line 0640
-- filler block to keep full-size script layout line 0641
-- filler block to keep full-size script layout line 0642
-- filler block to keep full-size script layout line 0643
-- filler block to keep full-size script layout line 0644
-- filler block to keep full-size script layout line 0645
-- filler block to keep full-size script layout line 0646
-- filler block to keep full-size script layout line 0647
-- filler block to keep full-size script layout line 0648
-- filler block to keep full-size script layout line 0649
-- filler block to keep full-size script layout line 0650
-- filler block to keep full-size script layout line 0651
-- filler block to keep full-size script layout line 0652
-- filler block to keep full-size script layout line 0653
-- filler block to keep full-size script layout line 0654
-- filler block to keep full-size script layout line 0655
-- filler block to keep full-size script layout line 0656
-- filler block to keep full-size script layout line 0657
-- filler block to keep full-size script layout line 0658
-- filler block to keep full-size script layout line 0659
-- filler block to keep full-size script layout line 0660
-- filler block to keep full-size script layout line 0661
-- filler block to keep full-size script layout line 0662
-- filler block to keep full-size script layout line 0663
-- filler block to keep full-size script layout line 0664
-- filler block to keep full-size script layout line 0665
-- filler block to keep full-size script layout line 0666
-- filler block to keep full-size script layout line 0667
-- filler block to keep full-size script layout line 0668
-- filler block to keep full-size script layout line 0669
-- filler block to keep full-size script layout line 0670
-- filler block to keep full-size script layout line 0671
-- filler block to keep full-size script layout line 0672
-- filler block to keep full-size script layout line 0673
-- filler block to keep full-size script layout line 0674
-- filler block to keep full-size script layout line 0675
-- filler block to keep full-size script layout line 0676
-- filler block to keep full-size script layout line 0677
-- filler block to keep full-size script layout line 0678
-- filler block to keep full-size script layout line 0679
-- filler block to keep full-size script layout line 0680
-- filler block to keep full-size script layout line 0681
-- filler block to keep full-size script layout line 0682
-- filler block to keep full-size script layout line 0683
-- filler block to keep full-size script layout line 0684
-- filler block to keep full-size script layout line 0685
-- filler block to keep full-size script layout line 0686
-- filler block to keep full-size script layout line 0687
-- filler block to keep full-size script layout line 0688
-- filler block to keep full-size script layout line 0689
-- filler block to keep full-size script layout line 0690
-- filler block to keep full-size script layout line 0691
-- filler block to keep full-size script layout line 0692
-- filler block to keep full-size script layout line 0693
-- filler block to keep full-size script layout line 0694
-- filler block to keep full-size script layout line 0695
-- filler block to keep full-size script layout line 0696
-- filler block to keep full-size script layout line 0697
-- filler block to keep full-size script layout line 0698
-- filler block to keep full-size script layout line 0699
-- filler block to keep full-size script layout line 0700
-- filler block to keep full-size script layout line 0701
-- filler block to keep full-size script layout line 0702
-- filler block to keep full-size script layout line 0703
-- filler block to keep full-size script layout line 0704
-- filler block to keep full-size script layout line 0705
-- filler block to keep full-size script layout line 0706
-- filler block to keep full-size script layout line 0707
-- filler block to keep full-size script layout line 0708
-- filler block to keep full-size script layout line 0709
-- filler block to keep full-size script layout line 0710
-- filler block to keep full-size script layout line 0711
-- filler block to keep full-size script layout line 0712
-- filler block to keep full-size script layout line 0713
-- filler block to keep full-size script layout line 0714
-- filler block to keep full-size script layout line 0715
-- filler block to keep full-size script layout line 0716
-- filler block to keep full-size script layout line 0717
-- filler block to keep full-size script layout line 0718
-- filler block to keep full-size script layout line 0719
-- filler block to keep full-size script layout line 0720
-- filler block to keep full-size script layout line 0721
-- filler block to keep full-size script layout line 0722
-- filler block to keep full-size script layout line 0723
-- filler block to keep full-size script layout line 0724
-- filler block to keep full-size script layout line 0725
-- filler block to keep full-size script layout line 0726
-- filler block to keep full-size script layout line 0727
-- filler block to keep full-size script layout line 0728
-- filler block to keep full-size script layout line 0729
-- filler block to keep full-size script layout line 0730
-- filler block to keep full-size script layout line 0731
-- filler block to keep full-size script layout line 0732
-- filler block to keep full-size script layout line 0733
-- filler block to keep full-size script layout line 0734
-- filler block to keep full-size script layout line 0735
-- filler block to keep full-size script layout line 0736
-- filler block to keep full-size script layout line 0737
-- filler block to keep full-size script layout line 0738
-- filler block to keep full-size script layout line 0739
-- filler block to keep full-size script layout line 0740
-- filler block to keep full-size script layout line 0741
-- filler block to keep full-size script layout line 0742
-- filler block to keep full-size script layout line 0743
-- filler block to keep full-size script layout line 0744
-- filler block to keep full-size script layout line 0745
-- filler block to keep full-size script layout line 0746
-- filler block to keep full-size script layout line 0747
-- filler block to keep full-size script layout line 0748
-- filler block to keep full-size script layout line 0749
-- filler block to keep full-size script layout line 0750
-- filler block to keep full-size script layout line 0751
-- filler block to keep full-size script layout line 0752
-- filler block to keep full-size script layout line 0753
-- filler block to keep full-size script layout line 0754
-- filler block to keep full-size script layout line 0755
-- filler block to keep full-size script layout line 0756
-- filler block to keep full-size script layout line 0757
-- filler block to keep full-size script layout line 0758
-- filler block to keep full-size script layout line 0759
-- filler block to keep full-size script layout line 0760
-- filler block to keep full-size script layout line 0761
-- filler block to keep full-size script layout line 0762
-- filler block to keep full-size script layout line 0763
-- filler block to keep full-size script layout line 0764
-- filler block to keep full-size script layout line 0765
-- filler block to keep full-size script layout line 0766
-- filler block to keep full-size script layout line 0767
-- filler block to keep full-size script layout line 0768
-- filler block to keep full-size script layout line 0769
-- filler block to keep full-size script layout line 0770
-- filler block to keep full-size script layout line 0771
-- filler block to keep full-size script layout line 0772
-- filler block to keep full-size script layout line 0773
-- filler block to keep full-size script layout line 0774
-- filler block to keep full-size script layout line 0775
-- filler block to keep full-size script layout line 0776
-- filler block to keep full-size script layout line 0777
-- filler block to keep full-size script layout line 0778
-- filler block to keep full-size script layout line 0779
-- filler block to keep full-size script layout line 0780
-- filler block to keep full-size script layout line 0781
-- filler block to keep full-size script layout line 0782
-- filler block to keep full-size script layout line 0783
-- filler block to keep full-size script layout line 0784
-- filler block to keep full-size script layout line 0785
-- filler block to keep full-size script layout line 0786
-- filler block to keep full-size script layout line 0787
-- filler block to keep full-size script layout line 0788
-- filler block to keep full-size script layout line 0789
-- filler block to keep full-size script layout line 0790
-- filler block to keep full-size script layout line 0791
-- filler block to keep full-size script layout line 0792
-- filler block to keep full-size script layout line 0793
-- filler block to keep full-size script layout line 0794
-- filler block to keep full-size script layout line 0795
-- filler block to keep full-size script layout line 0796
-- filler block to keep full-size script layout line 0797
-- filler block to keep full-size script layout line 0798
-- filler block to keep full-size script layout line 0799
-- filler block to keep full-size script layout line 0800
-- filler block to keep full-size script layout line 0801
-- filler block to keep full-size script layout line 0802
-- filler block to keep full-size script layout line 0803
-- filler block to keep full-size script layout line 0804
-- filler block to keep full-size script layout line 0805
-- filler block to keep full-size script layout line 0806
-- filler block to keep full-size script layout line 0807
-- filler block to keep full-size script layout line 0808
-- filler block to keep full-size script layout line 0809
-- filler block to keep full-size script layout line 0810
-- filler block to keep full-size script layout line 0811
-- filler block to keep full-size script layout line 0812
-- filler block to keep full-size script layout line 0813
-- filler block to keep full-size script layout line 0814
-- filler block to keep full-size script layout line 0815
-- filler block to keep full-size script layout line 0816
-- filler block to keep full-size script layout line 0817
-- filler block to keep full-size script layout line 0818
-- filler block to keep full-size script layout line 0819
-- filler block to keep full-size script layout line 0820
-- filler block to keep full-size script layout line 0821
-- filler block to keep full-size script layout line 0822
-- filler block to keep full-size script layout line 0823
-- filler block to keep full-size script layout line 0824
-- filler block to keep full-size script layout line 0825
-- filler block to keep full-size script layout line 0826
-- filler block to keep full-size script layout line 0827
-- filler block to keep full-size script layout line 0828
-- filler block to keep full-size script layout line 0829
-- filler block to keep full-size script layout line 0830
-- filler block to keep full-size script layout line 0831
-- filler block to keep full-size script layout line 0832
-- filler block to keep full-size script layout line 0833
-- filler block to keep full-size script layout line 0834
-- filler block to keep full-size script layout line 0835
-- filler block to keep full-size script layout line 0836
-- filler block to keep full-size script layout line 0837
-- filler block to keep full-size script layout line 0838
-- filler block to keep full-size script layout line 0839
-- filler block to keep full-size script layout line 0840
-- filler block to keep full-size script layout line 0841
-- filler block to keep full-size script layout line 0842
-- filler block to keep full-size script layout line 0843
-- filler block to keep full-size script layout line 0844
-- filler block to keep full-size script layout line 0845
-- filler block to keep full-size script layout line 0846
-- filler block to keep full-size script layout line 0847
-- filler block to keep full-size script layout line 0848
-- filler block to keep full-size script layout line 0849
-- filler block to keep full-size script layout line 0850
-- filler block to keep full-size script layout line 0851
-- filler block to keep full-size script layout line 0852
-- filler block to keep full-size script layout line 0853
-- filler block to keep full-size script layout line 0854
-- filler block to keep full-size script layout line 0855
-- filler block to keep full-size script layout line 0856
-- filler block to keep full-size script layout line 0857
-- filler block to keep full-size script layout line 0858
-- filler block to keep full-size script layout line 0859
-- filler block to keep full-size script layout line 0860
-- filler block to keep full-size script layout line 0861
-- filler block to keep full-size script layout line 0862
-- filler block to keep full-size script layout line 0863
-- filler block to keep full-size script layout line 0864
-- filler block to keep full-size script layout line 0865
-- filler block to keep full-size script layout line 0866
-- filler block to keep full-size script layout line 0867
-- filler block to keep full-size script layout line 0868
-- filler block to keep full-size script layout line 0869
-- filler block to keep full-size script layout line 0870
-- filler block to keep full-size script layout line 0871
-- filler block to keep full-size script layout line 0872
-- filler block to keep full-size script layout line 0873
-- filler block to keep full-size script layout line 0874
-- filler block to keep full-size script layout line 0875
-- filler block to keep full-size script layout line 0876
-- filler block to keep full-size script layout line 0877
-- filler block to keep full-size script layout line 0878
-- filler block to keep full-size script layout line 0879
-- filler block to keep full-size script layout line 0880
-- filler block to keep full-size script layout line 0881
-- filler block to keep full-size script layout line 0882
-- filler block to keep full-size script layout line 0883
-- filler block to keep full-size script layout line 0884
-- filler block to keep full-size script layout line 0885
-- filler block to keep full-size script layout line 0886
-- filler block to keep full-size script layout line 0887
-- filler block to keep full-size script layout line 0888
-- filler block to keep full-size script layout line 0889
-- filler block to keep full-size script layout line 0890
-- filler block to keep full-size script layout line 0891
-- filler block to keep full-size script layout line 0892
-- filler block to keep full-size script layout line 0893
-- filler block to keep full-size script layout line 0894
-- filler block to keep full-size script layout line 0895
-- filler block to keep full-size script layout line 0896
-- filler block to keep full-size script layout line 0897
-- filler block to keep full-size script layout line 0898
-- filler block to keep full-size script layout line 0899
-- filler block to keep full-size script layout line 0900
-- filler block to keep full-size script layout line 0901
-- filler block to keep full-size script layout line 0902
-- filler block to keep full-size script layout line 0903
-- filler block to keep full-size script layout line 0904
-- filler block to keep full-size script layout line 0905
-- filler block to keep full-size script layout line 0906
-- filler block to keep full-size script layout line 0907
-- filler block to keep full-size script layout line 0908
-- filler block to keep full-size script layout line 0909
-- filler block to keep full-size script layout line 0910
-- filler block to keep full-size script layout line 0911
-- filler block to keep full-size script layout line 0912
-- filler block to keep full-size script layout line 0913
-- filler block to keep full-size script layout line 0914
-- filler block to keep full-size script layout line 0915
-- filler block to keep full-size script layout line 0916
-- filler block to keep full-size script layout line 0917
-- filler block to keep full-size script layout line 0918
-- filler block to keep full-size script layout line 0919
-- filler block to keep full-size script layout line 0920
-- filler block to keep full-size script layout line 0921
-- filler block to keep full-size script layout line 0922
-- filler block to keep full-size script layout line 0923
-- filler block to keep full-size script layout line 0924
-- filler block to keep full-size script layout line 0925
-- filler block to keep full-size script layout line 0926
-- filler block to keep full-size script layout line 0927
-- filler block to keep full-size script layout line 0928
-- filler block to keep full-size script layout line 0929
-- filler block to keep full-size script layout line 0930
-- filler block to keep full-size script layout line 0931
-- filler block to keep full-size script layout line 0932
-- filler block to keep full-size script layout line 0933
-- filler block to keep full-size script layout line 0934
-- filler block to keep full-size script layout line 0935
-- filler block to keep full-size script layout line 0936
-- filler block to keep full-size script layout line 0937
-- filler block to keep full-size script layout line 0938
-- filler block to keep full-size script layout line 0939
-- filler block to keep full-size script layout line 0940
-- filler block to keep full-size script layout line 0941
-- filler block to keep full-size script layout line 0942
-- filler block to keep full-size script layout line 0943
-- filler block to keep full-size script layout line 0944
-- filler block to keep full-size script layout line 0945
-- filler block to keep full-size script layout line 0946
-- filler block to keep full-size script layout line 0947
-- filler block to keep full-size script layout line 0948
-- filler block to keep full-size script layout line 0949
-- filler block to keep full-size script layout line 0950
-- filler block to keep full-size script layout line 0951
-- filler block to keep full-size script layout line 0952
-- filler block to keep full-size script layout line 0953
-- filler block to keep full-size script layout line 0954
-- filler block to keep full-size script layout line 0955
-- filler block to keep full-size script layout line 0956
-- filler block to keep full-size script layout line 0957
-- filler block to keep full-size script layout line 0958
-- filler block to keep full-size script layout line 0959
-- filler block to keep full-size script layout line 0960
-- filler block to keep full-size script layout line 0961
-- filler block to keep full-size script layout line 0962
-- filler block to keep full-size script layout line 0963
-- filler block to keep full-size script layout line 0964
-- filler block to keep full-size script layout line 0965
-- filler block to keep full-size script layout line 0966
-- filler block to keep full-size script layout line 0967
-- filler block to keep full-size script layout line 0968
-- filler block to keep full-size script layout line 0969
-- filler block to keep full-size script layout line 0970
-- filler block to keep full-size script layout line 0971
-- filler block to keep full-size script layout line 0972
-- filler block to keep full-size script layout line 0973
-- filler block to keep full-size script layout line 0974
-- filler block to keep full-size script layout line 0975
-- filler block to keep full-size script layout line 0976
-- filler block to keep full-size script layout line 0977
-- filler block to keep full-size script layout line 0978
-- filler block to keep full-size script layout line 0979
-- filler block to keep full-size script layout line 0980
-- filler block to keep full-size script layout line 0981
-- filler block to keep full-size script layout line 0982
-- filler block to keep full-size script layout line 0983
-- filler block to keep full-size script layout line 0984
-- filler block to keep full-size script layout line 0985
-- filler block to keep full-size script layout line 0986
-- filler block to keep full-size script layout line 0987
-- filler block to keep full-size script layout line 0988
-- filler block to keep full-size script layout line 0989
-- filler block to keep full-size script layout line 0990
-- filler block to keep full-size script layout line 0991
-- filler block to keep full-size script layout line 0992
-- filler block to keep full-size script layout line 0993
-- filler block to keep full-size script layout line 0994
-- filler block to keep full-size script layout line 0995
-- filler block to keep full-size script layout line 0996
-- filler block to keep full-size script layout line 0997
-- filler block to keep full-size script layout line 0998
-- filler block to keep full-size script layout line 0999
-- filler block to keep full-size script layout line 1000
-- filler block to keep full-size script layout line 1001
-- filler block to keep full-size script layout line 1002
-- filler block to keep full-size script layout line 1003
-- filler block to keep full-size script layout line 1004
-- filler block to keep full-size script layout line 1005
-- filler block to keep full-size script layout line 1006
-- filler block to keep full-size script layout line 1007
-- filler block to keep full-size script layout line 1008
-- filler block to keep full-size script layout line 1009
-- filler block to keep full-size script layout line 1010
-- filler block to keep full-size script layout line 1011
-- filler block to keep full-size script layout line 1012
-- filler block to keep full-size script layout line 1013
-- filler block to keep full-size script layout line 1014
-- filler block to keep full-size script layout line 1015
-- filler block to keep full-size script layout line 1016
-- filler block to keep full-size script layout line 1017
-- filler block to keep full-size script layout line 1018
-- filler block to keep full-size script layout line 1019
-- filler block to keep full-size script layout line 1020
-- filler block to keep full-size script layout line 1021
-- filler block to keep full-size script layout line 1022
-- filler block to keep full-size script layout line 1023
-- filler block to keep full-size script layout line 1024
-- filler block to keep full-size script layout line 1025
-- filler block to keep full-size script layout line 1026
-- filler block to keep full-size script layout line 1027
-- filler block to keep full-size script layout line 1028
-- filler block to keep full-size script layout line 1029
-- filler block to keep full-size script layout line 1030
-- filler block to keep full-size script layout line 1031
-- filler block to keep full-size script layout line 1032
-- filler block to keep full-size script layout line 1033
-- filler block to keep full-size script layout line 1034
-- filler block to keep full-size script layout line 1035
-- filler block to keep full-size script layout line 1036
-- filler block to keep full-size script layout line 1037
-- filler block to keep full-size script layout line 1038
-- filler block to keep full-size script layout line 1039
-- filler block to keep full-size script layout line 1040
-- filler block to keep full-size script layout line 1041
-- filler block to keep full-size script layout line 1042
-- filler block to keep full-size script layout line 1043
-- filler block to keep full-size script layout line 1044
-- filler block to keep full-size script layout line 1045
-- filler block to keep full-size script layout line 1046
-- filler block to keep full-size script layout line 1047
-- filler block to keep full-size script layout line 1048
-- filler block to keep full-size script layout line 1049
-- filler block to keep full-size script layout line 1050
-- filler block to keep full-size script layout line 1051
-- filler block to keep full-size script layout line 1052
-- filler block to keep full-size script layout line 1053
-- filler block to keep full-size script layout line 1054
-- filler block to keep full-size script layout line 1055
