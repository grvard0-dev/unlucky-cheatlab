--[[
UNLUCKY | EGG MOUNTAIN v1.0 — клиентская панель для executor / инжектора.
Открой файл, скопируй ВЕСЬ код в редактор инжектора и нажми Execute.
RightCtrl — показать/скрыть; F — полёт; End — отключить панель полностью.
В полёте: WASD, Space вверх, LeftCtrl вниз. Значения применяются после Enter.
При открытом меню мышь освобождается автоматически.

Функции работают на клиенте; сервер может отклонить перемещение или запрос.
Название игры: Egg Mountain, https://www.roblox.com/games/77031829535714
Исследование механик: https://t.me/s/fixeeye (публикации 1–2 ноября 2026).
Точный исходный код игры, имена RemoteEvent и структура яиц не получены.
Поиск яиц эвристический; ESP видит только загруженные клиентом объекты.
Поле «Имя содержит» уточняет поиск, например GoldenEgg или WorldEgg.
Имя папки с яйцами не считается именем каждого объекта внутри неё.

ПОВТОР СБОРА:
1. Нажми «Запись запросов 8с», затем один раз собери яйцо обычным способом.
2. Дождись конца записи; кнопками < / > выбери соответствующий RemoteEvent.
3. Проверь путь и аргументы; включи «Повтор выбранного запроса».
Повтор отправляет ТО ЖЕ содержимое: устаревший ID яйца, nonce и серверный
cooldown могут привести к отказу. Успешная отправка не означает выдачу яйца.
RemoteFunction не повторяются. Запись требует hookmetamethod/getnamecallmethod.
Если запись не поддерживается, остальные функции продолжают работать.
Рядом с яйцами можно попробовать автонажатие ProximityPrompt/ClickDetector.
Его работа зависит от того, использует ли игра именно эти объекты.

Не требует ключей, сторонних UI-библиотек, HttpGet или удалённого загрузчика.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
assert(player, "Запускай скрипт в игровом клиенте, после загрузки персонажа")
local env = (type(getgenv) == "function" and getgenv()) or _G
local old = env.__UnluckyEggMountain
if type(old) == "table" and type(old.Destroy) == "function" then
    pcall(function() old:Destroy() end)
end

local api = {}
env.__UnluckyEggMountain = api
local alive = true
local connections = {}
local flags = {speed=false, jump=false, noclip=false, fly=false,
    airjump=false, esp=false, auto=false, replay=false, cursor=false}
local settings = {speed=48, jump=100, fly=55, interval=0.5, attempts=50, filter=""}
local baseline = setmetatable({}, {__mode="k"})
local collisions = setmetatable({}, {__mode="k"})
local character, humanoid, root
local flight
local savedPoint
local candidates, seen = {}, {}
local visuals = {}
local captures, selected = {}, 1
local captureUntil = 0
local replayCount = 0
local revision = 0
local lastError = 0
local promptBusy = setmetatable({}, {__mode="k"})
local clickTimes = setmetatable({}, {__mode="k"})
local heldPrompts = {}
local gui, espRoot, statusLabel, captureLabel, countLabel, body
local toggles = {}
local originalMouse = {behavior=UIS.MouseBehavior, icon=UIS.MouseIconEnabled}
local mouseBound = false
local renderKey = "UnluckyEggCursor_" .. HttpService:GenerateGUID(false)
local scanBusy = false

local function connect(signal, fn)
    local c = signal:Connect(fn)
    connections[#connections+1] = c
    return c
end

local function tell(message)
    if statusLabel and statusLabel.Parent then statusLabel.Text = tostring(message) end
end

local function guard(fn)
    return function(...)
        if not alive then return end
        local ok, err = pcall(fn, ...)
        if not ok and os.clock() - lastError > 2 then
            lastError = os.clock()
            tell("Ошибка: " .. tostring(err):sub(1,180))
            warn("[Unlucky Egg Mountain] " .. tostring(err))
        end
    end
end

local function make(class, properties, parent)
    local obj = Instance.new(class)
    for k,v in pairs(properties or {}) do obj[k] = v end
    obj.Parent = parent
    return obj
end

local function round(obj, radius)
    make("UICorner", {CornerRadius=UDim.new(0,radius or 8)}, obj)
end

local function remember(h)
    if h and not baseline[h] then
        baseline[h] = {WalkSpeed=h.WalkSpeed, JumpPower=h.JumpPower,
            JumpHeight=h.JumpHeight, AutoRotate=h.AutoRotate}
    end
end

local function restoreCollision()
    for part, value in pairs(collisions) do
        if part.Parent then pcall(function() part.CanCollide = value end) end
        collisions[part] = nil
    end
end

local function stopFlight()
    if flight then
        for _,obj in ipairs({flight.velocity, flight.orientation, flight.attachment}) do
            if obj then obj:Destroy() end
        end
        if flight.humanoid and flight.humanoid.Parent then
            flight.humanoid.AutoRotate = flight.autoRotate
        end
        if flight.root and flight.root.Parent then
            flight.root.AssemblyLinearVelocity = Vector3.zero
        end
        flight = nil
    end
end

local function startFlight()
    if not root or not humanoid or humanoid.Health <= 0 or root.Anchored then return end
    stopFlight()
    local attachment = make("Attachment", {Name="UnluckyFlightAttachment"}, root)
    local velocity = make("LinearVelocity", {Name="UnluckyFlightVelocity",
        Attachment0=attachment, RelativeTo=Enum.ActuatorRelativeTo.World,
        VelocityConstraintMode=Enum.VelocityConstraintMode.Vector,
        ForceLimitsEnabled=false, VectorVelocity=Vector3.zero}, root)
    local orientation = make("AlignOrientation", {Name="UnluckyFlightOrientation",
        Attachment0=attachment, Mode=Enum.OrientationAlignmentMode.OneAttachment,
        RigidityEnabled=true, MaxTorque=1e9, Responsiveness=35}, root)
    flight = {attachment=attachment, velocity=velocity, orientation=orientation,
        humanoid=humanoid, root=root, autoRotate=humanoid.AutoRotate}
    humanoid.AutoRotate = false
end

local function bindCharacter(c)
    revision = revision + 1
    local current = revision
    stopFlight()
    restoreCollision()
    character, humanoid, root = c, nil, nil
    task.spawn(function()
        local h = c:WaitForChild("Humanoid", 10)
        local r = c:WaitForChild("HumanoidRootPart", 10)
        if not alive or current ~= revision or not h or not r then return end
        humanoid, root = h, r
        remember(h)
    end)
end

local function partOf(obj)
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then
        return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function belongsToCharacter(obj)
    local current = obj
    while current and current ~= Workspace do
        if current:IsA("Model") and current:FindFirstChildOfClass("Humanoid") then
            return true
        end
        current = current.Parent
    end
    return false
end

local function nameMatches(obj)
    local name = string.lower(obj.Name)
    local custom = string.lower(settings.filter)
    if custom ~= "" then return string.find(name, custom, 1, true) ~= nil end
    return string.find(name, "egg", 1, true) ~= nil
        or string.find(name, "яй", 1, true) ~= nil
        or obj:GetAttribute("EggId") ~= nil or obj:GetAttribute("EggType") ~= nil
        or obj:GetAttribute("IsEgg") == true
end

local function candidateOf(obj)
    if not (obj:IsA("Model") or obj:IsA("BasePart")) then return nil end
    if not obj:IsDescendantOf(Workspace) or belongsToCharacter(obj) then return nil end
    -- Prefer an individual named egg Model over its individual mesh parts.
    if obj.Parent and obj.Parent:IsA("Model") and nameMatches(obj.Parent) then return nil end
    if not nameMatches(obj) then return nil end
    local part = partOf(obj)
    if not part then return nil end
    if obj:IsA("Model") then
        local ok, size = pcall(function() return obj:GetExtentsSize() end)
        if ok and size.Magnitude > 90 then return nil end
    elseif part.Size.Magnitude > 90 then return nil end
    return part
end

local function addCandidate(obj)
    if seen[obj] then return end
    local p = candidateOf(obj)
    if p then
        seen[obj] = true
        candidates[#candidates+1] = {object=obj, part=p}
    end
end

local function scan()
    if scanBusy or not alive then return end
    scanBusy = true
    local ok, err = pcall(function()
        candidates, seen = {}, {}
        local all = Workspace:GetDescendants()
        for index,obj in ipairs(all) do
            if not alive then break end
            addCandidate(obj)
            if index % 400 == 0 then task.wait() end
        end
        tell("Найдено предполагаемых яиц: " .. #candidates .. ". При ошибках уточни фильтр.")
    end)
    scanBusy = false
    if not ok then tell("Ошибка сканирования: " .. tostring(err)) end
end

local function valid(entry)
    return entry.object.Parent and entry.part.Parent
        and entry.object:IsDescendantOf(Workspace)
        and (entry.part==entry.object or entry.part:IsDescendantOf(entry.object))
end

local function nearest()
    if not root then return nil end
    local best, distance
    for _,entry in ipairs(candidates) do
        if valid(entry) then
            local d = (entry.part.Position - root.Position).Magnitude
            if not distance or d < distance then best, distance = entry, d end
        end
    end
    return best, distance
end

local function clearVisuals()
    for obj,v in pairs(visuals) do
        v.highlight:Destroy()
        v.billboard:Destroy()
        visuals[obj] = nil
    end
end

local function updateESP()
    if not flags.esp or not root then clearVisuals() return end
    local sorted = {}
    for _,entry in ipairs(candidates) do
        if valid(entry) then
            sorted[#sorted+1] = {entry=entry, distance=(entry.part.Position-root.Position).Magnitude}
        end
    end
    table.sort(sorted, function(a,b) return a.distance < b.distance end)
    local keep = {}
    -- Highlight budgets are engine-dependent; cap simultaneous decorations.
    for i=1,math.min(24,#sorted) do
        local data = sorted[i]
        local obj, part = data.entry.object, data.entry.part
        keep[obj] = true
        local v = visuals[obj]
        if not v then
            local golden = string.find(string.lower(obj.Name), "gold", 1, true) ~= nil
            local color = golden and Color3.fromRGB(255,203,67) or Color3.fromRGB(91,169,255)
            local highlight = make("Highlight", {Name="UnluckyEggHighlight", Adornee=obj,
                DepthMode=Enum.HighlightDepthMode.AlwaysOnTop, FillColor=color,
                OutlineColor=color, FillTransparency=0.7, OutlineTransparency=0}, espRoot)
            local billboard = make("BillboardGui", {Name="UnluckyEggLabel", Adornee=part,
                Size=UDim2.fromOffset(190,40), StudsOffset=Vector3.new(0,2.5,0),
                AlwaysOnTop=true, MaxDistance=1800}, gui)
            local text = make("TextLabel", {Size=UDim2.fromScale(1,1), BackgroundTransparency=1,
                TextColor3=color, TextStrokeTransparency=0.3, Font=Enum.Font.GothamBold,
                TextSize=12, TextWrapped=true}, billboard)
            v = {highlight=highlight,billboard=billboard,text=text,part=part}
            visuals[obj] = v
        end
        v.billboard.Adornee = part
        v.text.Text = obj.Name .. " · " .. math.floor(data.distance) .. " st"
    end
    for obj,v in pairs(visuals) do
        if not keep[obj] then
            v.highlight:Destroy()
            v.billboard:Destroy()
            visuals[obj] = nil
        end
    end
end

local function setFlag(name, value)
    local wasEnabled=flags[name]
    if value and not wasEnabled and humanoid then
        remember(humanoid)
        local b=baseline[humanoid]
        if name=="speed" then b.WalkSpeed=humanoid.WalkSpeed
        elseif name=="jump" then b.JumpPower=humanoid.JumpPower b.JumpHeight=humanoid.JumpHeight end
    end
    flags[name] = value
    if name == "speed" and not value and humanoid and baseline[humanoid] then
        if baseline[humanoid].speedChanged then humanoid.WalkSpeed = baseline[humanoid].WalkSpeed end
        baseline[humanoid].speedChanged=false
    elseif name == "jump" and not value and humanoid and baseline[humanoid] then
        if baseline[humanoid].jumpChanged then
            humanoid.JumpPower = baseline[humanoid].JumpPower
            humanoid.JumpHeight = baseline[humanoid].JumpHeight
        end
        baseline[humanoid].jumpChanged=false
    elseif name == "noclip" and not value then restoreCollision()
    elseif name == "fly" and not value then stopFlight()
    elseif name == "esp" and not value then clearVisuals()
    elseif name == "replay" and value then
        if captureUntil > os.clock() then flags.replay=false tell("Сначала закончи запись")
        elseif not captures[selected] then flags.replay=false tell("Сначала запиши запрос сбора")
        else replayCount=0 end
    end
    if toggles[name] then toggles[name]() end
end

local function summarize(value, depth)
    local t = typeof(value)
    if t == "Instance" then return "@" .. value:GetFullName() end
    if t == "string" then return string.format("%q",value:sub(1,100)) end
    if t == "table" then
        if depth > 1 then return "{...}" end
        local out, n = {}, 0
        for k,v in pairs(value) do
            n=n+1
            if n>8 then out[#out+1]="..." break end
            out[#out+1]=tostring(k).."="..summarize(v,depth+1)
        end
        return "{"..table.concat(out,", ").."}"
    end
    return tostring(value)
end

local function snapshot(value, depth, memo)
    if type(value) ~= "table" then return value end
    if memo[value] then return memo[value] end
    if depth > 10 then error("Слишком глубокая таблица аргументов") end
    local result = {}
    memo[value] = result
    local count=0
    for k,v in pairs(value) do
        count=count+1
        if count>1000 then error("Слишком большая таблица аргументов") end
        result[k]=snapshot(v,depth+1,memo)
    end
    return result
end

local function describeCapture()
    local item = captures[selected]
    if not item then
        captureLabel.Text = "Записей нет. Запусти запись и собери одно яйцо вручную."
        return
    end
    local out={}
    for i=1,item.args.n do out[i]=summarize(item.args[i],0) end
    captureLabel.Text = selected .. "/" .. #captures .. " · " .. item.remote:GetFullName()
        .. "\n(" .. table.concat(out,", ") .. ")"
end

local function installRecorder()
    local broker = env.__UnluckyEggRecorder
    if not (type(broker)=="table" and broker.installed) then
        if type(hookmetamethod)~="function" or type(getnamecallmethod)~="function" then
            return nil, "Инжектор не поддерживает hookmetamethod/getnamecallmethod"
        end
        broker={installed=false,listener=nil}
        local previous
        local function intercept(self,...)
            local method=getnamecallmethod()
            if method=="FireServer" and broker.listener then
                -- Capture failures must never prevent the original game call.
                pcall(broker.listener,self,table.pack(...))
            end
            return previous(self,...)
        end
        local wrapped = (type(newcclosure)=="function" and newcclosure(intercept)) or intercept
        local ok, result = pcall(function()
            previous=hookmetamethod(game,"__namecall",wrapped)
            assert(type(previous)=="function","hookmetamethod не вернул исходную функцию")
        end)
        if not ok then return nil,tostring(result) end
        broker.installed=true
        env.__UnluckyEggRecorder=broker
    end
    broker.listener=function(remote,args)
        if not alive or captureUntil<=os.clock() or #captures>=40 then return end
        if typeof(remote)~="Instance" or not remote:IsA("RemoteEvent") then return end
        local copied=snapshot(args,0,{})
        local digest={remote:GetFullName()}
        for i=1,args.n do digest[#digest+1]=summarize(args[i],0) end
        local signature=table.concat(digest,"|")
        for _,item in ipairs(captures) do if item.signature==signature then return end end
        captures[#captures+1]={remote=remote,args=copied,signature=signature}
        selected=#captures
        task.defer(function() if alive then describeCapture() end end)
    end
    return broker
end

local function beginCapture()
    setFlag("replay",false)
    local broker, err=installRecorder()
    if not broker then tell(err) return end
    captures,selected={},1
    captureUntil=os.clock()+8
    describeCapture()
    tell("Запись 8 секунд: собери одно яйцо вручную")
    local deadline=captureUntil
    task.delay(8,function()
        if not alive or captureUntil~=deadline then return end
        captureUntil=0
        broker.listener=nil
        describeCapture()
        tell("Запись завершена. Запросов: "..#captures..". Выбери команду сбора.")
    end)
end

local function replayOnce()
    local item=captures[selected]
    if not item or not item.remote.Parent then
        setFlag("replay",false) tell("Запрос исчез; запиши заново") return
    end
    local ok, err=pcall(function()
        local args=snapshot(item.args,0,{})
        item.remote:FireServer(table.unpack(args,1,args.n))
    end)
    if not ok then setFlag("replay",false) tell("Отправка не удалась: "..tostring(err)) return end
    replayCount=replayCount+1
    tell("Отправлено "..replayCount.."/"..settings.attempts..". Результат проверяй в игре.")
    if replayCount>=settings.attempts then setFlag("replay",false) end
end

local function autoInteract()
    if not root then return end
    local entry, distance=nearest()
    if not entry or distance>18 then return end
    local found=false
    local targets=entry.object:GetDescendants()
    for _,obj in ipairs(targets) do
        if obj:IsA("ProximityPrompt") and obj.Enabled and not promptBusy[obj] then
            found=true
            promptBusy[obj]=true
            task.spawn(function()
                if not alive or not flags.auto or not obj.Parent then promptBusy[obj]=nil return end
                local ok,err=pcall(function()
                    if type(fireproximityprompt)=="function" then
                        fireproximityprompt(obj)
                    else
                        heldPrompts[obj]=true
                        obj:InputHoldBegin()
                        task.wait(math.min(obj.HoldDuration,10)+0.05)
                        if obj.Parent then obj:InputHoldEnd() end
                        heldPrompts[obj]=nil
                    end
                end)
                heldPrompts[obj]=nil
                if not ok and alive then tell("Prompt: "..tostring(err):sub(1,120)) end
                task.wait(0.2)
                promptBusy[obj]=nil
            end)
            break
        elseif obj:IsA("ClickDetector") and type(fireclickdetector)=="function" then
            found=true
            if os.clock()-(clickTimes[obj] or -1)>0.3 then
                clickTimes[obj]=os.clock()
                fireclickdetector(obj)
            end
            break
        end
    end
    if not found then
        tell("У ближайшего яйца нет Prompt/ClickDetector; используй запись запроса")
    end
end

local color={bg=Color3.fromRGB(14,19,31),card=Color3.fromRGB(25,33,51),
    text=Color3.fromRGB(231,239,255),muted=Color3.fromRGB(145,163,193),
    blue=Color3.fromRGB(60,122,242),red=Color3.fromRGB(148,53,72)}
gui=make("ScreenGui",{Name="UnluckyEggMountain",ResetOnSpawn=false,
    IgnoreGuiInset=false,DisplayOrder=5000,ZIndexBehavior=Enum.ZIndexBehavior.Sibling})
local parent=player:WaitForChild("PlayerGui")
if type(gethui)=="function" then
    local ok,result=pcall(gethui)
    if ok and typeof(result)=="Instance" then parent=result end
end
gui.Parent=parent
espRoot=make("Folder",{Name="UnluckyEggESP"},Workspace)
local panel=make("Frame",{Name="Panel",Size=UDim2.new(0,390,0.82,0),
    Position=UDim2.new(0,24,0.09,0),BackgroundColor3=color.bg,BorderSizePixel=0},gui)
round(panel,13)
make("UISizeConstraint",{MinSize=Vector2.new(310,280),MaxSize=Vector2.new(430,700)},panel)
make("UIStroke",{Color=Color3.fromRGB(48,73,109),Thickness=1},panel)
local header=make("TextLabel",{Size=UDim2.new(1,-88,0,38),Position=UDim2.fromOffset(15,7),
    BackgroundTransparency=1,Text="UNLUCKY / EGG MOUNTAIN",TextColor3=color.text,
    Font=Enum.Font.GothamBold,TextSize=15,TextXAlignment=Enum.TextXAlignment.Left,Active=true},panel)
make("TextLabel",{Size=UDim2.new(1,-30,0,20),Position=UDim2.fromOffset(15,40),
    BackgroundTransparency=1,Text="RightCtrl: меню  ·  F: полёт  ·  End: выход",
    TextColor3=color.muted,Font=Enum.Font.Gotham,TextSize=11,
    TextXAlignment=Enum.TextXAlignment.Left},panel)
local close=make("TextButton",{Size=UDim2.fromOffset(28,28),Position=UDim2.new(1,-38,0,13),
    BackgroundColor3=color.red,Text="×",TextColor3=color.text,TextSize=20,BorderSizePixel=0},panel)
round(close,7)
local mini=make("TextButton",{Size=UDim2.fromOffset(28,28),Position=UDim2.new(1,-70,0,13),
    BackgroundColor3=color.card,Text="−",TextColor3=color.text,TextSize=20,BorderSizePixel=0},panel)
round(mini,7)
body=make("ScrollingFrame",{Size=UDim2.new(1,-24,1,-127),Position=UDim2.fromOffset(12,66),
    BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=4,
    ScrollBarImageColor3=color.blue,CanvasSize=UDim2.new(),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y},panel)
make("UIListLayout",{Padding=UDim.new(0,7),SortOrder=Enum.SortOrder.LayoutOrder},body)
make("UIPadding",{PaddingBottom=UDim.new(0,8),PaddingRight=UDim.new(0,5)},body)
statusLabel=make("TextLabel",{Size=UDim2.new(1,-28,0,48),Position=UDim2.new(0,14,1,-54),
    BackgroundTransparency=1,Text="Загрузка…",TextColor3=color.muted,
    Font=Enum.Font.Gotham,TextSize=11,TextWrapped=true,
    TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top},panel)
local order=0
local function row(height)
    order=order+1
    local r=make("Frame",{Size=UDim2.new(1,0,0,height or 36),BackgroundColor3=color.card,
        BorderSizePixel=0,LayoutOrder=order},body)
    round(r,7)
    return r
end
local function note(text,height)
    local r=row(height or 42)
    return make("TextLabel",{Size=UDim2.new(1,-18,1,-8),Position=UDim2.fromOffset(9,4),
        BackgroundTransparency=1,Text=text,TextColor3=color.muted,Font=Enum.Font.Gotham,
        TextSize=11,TextWrapped=true,TextXAlignment=Enum.TextXAlignment.Left},r)
end
local function section(text)
    local r=row(25)
    r.BackgroundTransparency=1
    make("TextLabel",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,Text=text,
        TextColor3=Color3.fromRGB(104,167,255),Font=Enum.Font.GothamBold,TextSize=12,
        TextXAlignment=Enum.TextXAlignment.Left},r)
end
local function button(text,fn)
    local r=row(35)
    local b=make("TextButton",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,
        Text=text,TextColor3=color.text,Font=Enum.Font.Gotham,TextSize=12},r)
    connect(b.Activated,guard(fn))
    return b
end
local function toggle(text,key)
    local r=row(35)
    local b=make("TextButton",{Size=UDim2.fromScale(1,1),BackgroundTransparency=1,
        TextColor3=color.text,Font=Enum.Font.Gotham,TextSize=12,
        TextXAlignment=Enum.TextXAlignment.Left},r)
    toggles[key]=function()
        b.Text="   "..text.."    ["..(flags[key] and "ВКЛ" or "ВЫКЛ").."]"
        r.BackgroundColor3=flags[key] and Color3.fromRGB(30,67,119) or color.card
    end
    connect(b.Activated,guard(function() setFlag(key,not flags[key]) end))
    toggles[key]()
end
local function input(text,key,minimum,maximum)
    local r=row(35)
    make("TextLabel",{Size=UDim2.new(1,-122,1,0),Position=UDim2.fromOffset(10,0),
        BackgroundTransparency=1,Text=text,TextColor3=color.text,Font=Enum.Font.Gotham,
        TextSize=12,TextXAlignment=Enum.TextXAlignment.Left},r)
    local box=make("TextBox",{Size=UDim2.fromOffset(100,25),Position=UDim2.new(1,-108,0,5),
        BackgroundColor3=color.bg,BorderSizePixel=0,Text=tostring(settings[key]),
        ClearTextOnFocus=false,TextColor3=color.text,Font=Enum.Font.Gotham,TextSize=12},r)
    round(box,5)
    connect(box.FocusLost,guard(function()
        if key=="filter" then
            settings.filter=box.Text:sub(1,64)
            clearVisuals()
            task.spawn(scan)
            return
        end
        local value=tonumber((box.Text:gsub(",",".")))
        if value and value==value and math.abs(value)<math.huge then
            settings[key]=math.clamp(value,minimum,maximum)
            if key=="attempts" then settings[key]=math.floor(settings[key]) end
        end
        box.Text=tostring(settings[key])
    end))
end

section("ПЕРЕДВИЖЕНИЕ")
toggle("Ускорение","speed")
input("Скорость, st/s","speed",1,200)
toggle("Высокий прыжок","jump")
input("Сила прыжка","jump",20,220)
toggle("Прыжки в воздухе","airjump")
toggle("Сквозь стены","noclip")
toggle("Полёт · F","fly")
input("Скорость полёта","fly",5,200)
toggle("Свободная мышь","cursor")
note("Полёт: WASD, Space вверх, LeftCtrl вниз. На время ввода текста управление полётом отключается.",44)

section("ЯЙЦА / ОБЪЕКТЫ")
toggle("ESP сквозь стены","esp")
input("Имя содержит","filter")
countLabel=note("Поиск объектов…",28)
button("Пересканировать яйца",function() task.spawn(scan) end)
button("Телепорт к ближайшему яйцу",function()
    local entry=nearest()
    if not entry or not root then tell("Яйца не найдены — уточни фильтр и пересканируй") return end
    root.CFrame=CFrame.new(entry.part.Position+Vector3.new(0,4,0))
    root.AssemblyLinearVelocity=Vector3.zero
    tell("Телепорт к "..entry.object.Name)
end)
button("Сохранить точку / базу",function()
    if root then savedPoint=root.CFrame tell("Точка сохранена") end
end)
button("Вернуться в сохранённую точку",function()
    if root and savedPoint then
        root.CFrame=savedPoint
        root.AssemblyLinearVelocity=Vector3.zero
        tell("Возврат в сохранённую точку")
    else tell("Сначала сохрани точку") end
end)
toggle("Авто Prompt / Click рядом","auto")
note("Поиск по имени и атрибутам: возможны ложные цели. ESP: максимум 24 ближайших загруженных объекта. Авто Prompt не подтверждает получение яйца.",58)

section("ЗАПРОС СБОРА / ПОВТОР")
button("Запись запросов 8с",beginCapture)
captureLabel=note("Записей нет. Запусти запись и собери одно яйцо вручную.",100)
button("< Предыдущий запрос",function()
    if #captures>0 then setFlag("replay",false) selected=(selected-2)%#captures+1 describeCapture() end
end)
button("Следующий запрос >",function()
    if #captures>0 then setFlag("replay",false) selected=selected%#captures+1 describeCapture() end
end)
input("Интервал запроса, сек","interval",0.2,10)
input("Количество повторов","attempts",1,500)
toggle("Повтор выбранного запроса","replay")
note("Запись → собери 1 яйцо → выбери команду → повтор. Записываются RemoteEvent. Аргументы повторяются без изменения: сервер может их отклонить.",58)

section("ДИАГНОСТИКА")
button("Показать / скопировать отчёт",function()
    local lines={"UNLUCKY EGG MOUNTAIN v1.0", "PlaceId="..game.PlaceId,
        "GameId="..game.GameId, "FILTER="..settings.filter,
        "[EXECUTOR]", "fireproximityprompt="..tostring(type(fireproximityprompt)=="function"),
        "fireclickdetector="..tostring(type(fireclickdetector)=="function"),
        "hookmetamethod="..tostring(type(hookmetamethod)=="function"),"[EGG CANDIDATES]"}
    local included=0
    for _,entry in ipairs(candidates) do
        if valid(entry) and included<100 then
            included=included+1
            lines[#lines+1]=entry.object:GetFullName().." | "..tostring(entry.part.Position)
        end
    end
    lines[#lines+1]="[REPLICATED STORAGE REMOTE PATHS — NO CALLS]"
    local remoteCount=0
    for _,obj in ipairs(ReplicatedStorage:GetDescendants()) do
        if obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") or obj:IsA("UnreliableRemoteEvent") then
            remoteCount=remoteCount+1
            if remoteCount<=200 then lines[#lines+1]=obj.ClassName.." "..obj:GetFullName() end
        end
    end
    lines[#lines+1]="[CAPTURED FIRE SERVER]"
    for index,item in ipairs(captures) do
        local args={}
        for n=1,item.args.n do args[n]=summarize(item.args[n],0) end
        lines[#lines+1]=index..": "..item.remote:GetFullName().."("..table.concat(args,", ")..")"
    end
    local text=table.concat(lines,"\n")
    local copied=false
    if type(setclipboard)=="function" then copied=pcall(setclipboard,text) end
    local previous=gui:FindFirstChild("Report")
    if previous then previous:Destroy() end
    local frame=make("Frame",{Name="Report",Size=UDim2.fromScale(0.75,0.75),
        Position=UDim2.fromScale(0.125,0.125),BackgroundColor3=color.bg,
        BorderSizePixel=0,ZIndex=20},gui)
    round(frame,10)
    local box=make("TextBox",{Size=UDim2.new(1,-24,1,-62),Position=UDim2.fromOffset(12,12),
        BackgroundColor3=color.card,TextColor3=color.text,Text=text,ClearTextOnFocus=false,
        MultiLine=true,TextEditable=false,TextSize=11,Font=Enum.Font.Code,TextWrapped=true,
        TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
        ZIndex=21},frame)
    local done=make("TextButton",{Size=UDim2.new(1,-24,0,32),Position=UDim2.new(0,12,1,-42),
        Text=copied and "Отчёт скопирован · Закрыть" or "Выдели текст и скопируй · Закрыть",
        BackgroundColor3=color.blue,TextColor3=color.text,Font=Enum.Font.Gotham,
        TextSize=12,ZIndex=21},frame)
    connect(done.Activated,function() frame:Destroy() end)
    box:CaptureFocus()
    tell("Отчёт содержит пути объектов и аргументы запросов. Проверь перед отправкой.")
end)
button("Выключить все функции",function()
    for name in pairs(flags) do setFlag(name,false) end
    captureUntil=0
    local broker=env.__UnluckyEggRecorder
    if broker then broker.listener=nil end
    for obj in pairs(heldPrompts) do pcall(function() obj:InputHoldEnd() end) end
    tell("Все функции выключены")
end)

-- Drag only by the title. Scroll and text input keep their normal behavior.
local dragInput, dragStart, panelStart
connect(header.InputBegan,guard(function(inputObject)
    if inputObject.UserInputType==Enum.UserInputType.MouseButton1
        or inputObject.UserInputType==Enum.UserInputType.Touch then
        dragInput=inputObject
        dragStart=inputObject.Position
        panelStart=panel.Position
    end
end))
connect(UIS.InputChanged,guard(function(inputObject)
    if not dragInput then return end
    if inputObject.UserInputType==Enum.UserInputType.MouseMovement or inputObject==dragInput then
        local d=inputObject.Position-dragStart
        panel.Position=UDim2.new(panelStart.X.Scale,panelStart.X.Offset+d.X,
            panelStart.Y.Scale,panelStart.Y.Offset+d.Y)
    end
end))
connect(UIS.InputEnded,function(inputObject)
    if inputObject==dragInput then dragInput=nil end
end)
connect(mini.Activated,function() panel.Visible=false end)
connect(close.Activated,function() api:Destroy() end)
connect(UIS.InputBegan,guard(function(inputObject,processed)
    if UIS:GetFocusedTextBox() then return end
    if inputObject.KeyCode==Enum.KeyCode.RightControl then
        panel.Visible=not panel.Visible
        if not panel.Visible then
            local report=gui:FindFirstChild("Report")
            if report then report:Destroy() end
        end
    elseif inputObject.KeyCode==Enum.KeyCode.End then api:Destroy()
    elseif inputObject.KeyCode==Enum.KeyCode.F and not processed then setFlag("fly",not flags.fly) end
end))
connect(UIS.JumpRequest,guard(function()
    if flags.airjump and humanoid and humanoid.Health>0 and not UIS:GetFocusedTextBox() then
        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end))
connect(player.CharacterAdded,bindCharacter)
connect(player.CharacterRemoving,function(c)
    if character==c then revision=revision+1 stopFlight() restoreCollision() character,humanoid,root=nil,nil,nil end
end)
connect(Workspace.DescendantAdded,guard(function(obj)
    task.defer(function()
        if alive then
            addCandidate(obj)
            if obj.Parent and obj.Parent:IsA("Model") then addCandidate(obj.Parent) end
        end
    end)
end))

connect(RunService.Stepped,guard(function()
    if flags.noclip and character then
        for _,part in ipairs(character:GetDescendants()) do
            if part:IsA("BasePart") then
                if collisions[part]==nil then collisions[part]=part.CanCollide end
                part.CanCollide=false
            end
        end
    end
end))

connect(RunService.Heartbeat,guard(function()
    if not humanoid or not root or humanoid.Health<=0 then stopFlight() return end
    if flags.speed then
        baseline[humanoid].speedChanged=true
        humanoid.WalkSpeed=settings.speed
    end
    if flags.jump then
        baseline[humanoid].jumpChanged=true
        if humanoid.UseJumpPower then humanoid.JumpPower=settings.jump
        else humanoid.JumpHeight=settings.jump*settings.jump/(2*math.max(Workspace.Gravity,1)) end
    end
    if flags.fly then
        if root.Anchored then stopFlight() return end
        if not flight or flight.root~=root or not flight.velocity.Parent then startFlight() end
        local camera=Workspace.CurrentCamera
        if flight and camera then
            local move=Vector3.zero
            if not UIS:GetFocusedTextBox() then
                if UIS:IsKeyDown(Enum.KeyCode.W) then move=move+camera.CFrame.LookVector end
                if UIS:IsKeyDown(Enum.KeyCode.S) then move=move-camera.CFrame.LookVector end
                if UIS:IsKeyDown(Enum.KeyCode.D) then move=move+camera.CFrame.RightVector end
                if UIS:IsKeyDown(Enum.KeyCode.A) then move=move-camera.CFrame.RightVector end
                if UIS:IsKeyDown(Enum.KeyCode.Space) then move=move+Vector3.yAxis end
                if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then move=move-Vector3.yAxis end
            end
            flight.velocity.VectorVelocity=move.Magnitude>0 and move.Unit*settings.fly or Vector3.zero
            flight.orientation.CFrame=camera.CFrame.Rotation
        end
    end
end))

-- An explicit late render priority overrides first-person camera mouse lock.
RunService:BindToRenderStep(renderKey,Enum.RenderPriority.Last.Value+1,guard(function()
    if flags.cursor or panel.Visible or gui:FindFirstChild("Report") then
        if not mouseBound then
            originalMouse={behavior=UIS.MouseBehavior,icon=UIS.MouseIconEnabled}
            mouseBound=true
        end
        UIS.MouseBehavior=Enum.MouseBehavior.Default
        UIS.MouseIconEnabled=true
    elseif mouseBound then
        UIS.MouseBehavior=originalMouse.behavior
        UIS.MouseIconEnabled=originalMouse.icon
        mouseBound=false
    end
end))

function api:Destroy()
    if not alive then return end
    alive=false
    revision=revision+1
    captureUntil=0
    local broker=env.__UnluckyEggRecorder
    if broker then broker.listener=nil end
    -- Shared hook stays as a transparent pass-through; never overwrite another hook.
    for name in pairs(flags) do flags[name]=false end
    for _,c in ipairs(connections) do c:Disconnect() end
    RunService:UnbindFromRenderStep(renderKey)
    stopFlight()
    restoreCollision()
    for h,values in pairs(baseline) do
        if h.Parent then
            pcall(function()
                if values.speedChanged then h.WalkSpeed=values.WalkSpeed end
                if values.jumpChanged then h.JumpPower=values.JumpPower h.JumpHeight=values.JumpHeight end
            end)
        end
    end
    for obj in pairs(heldPrompts) do pcall(function() obj:InputHoldEnd() end) end
    if mouseBound then
        UIS.MouseBehavior=originalMouse.behavior
        UIS.MouseIconEnabled=originalMouse.icon
    end
    clearVisuals()
    if espRoot then espRoot:Destroy() end
    if gui then gui:Destroy() end
    if env.__UnluckyEggMountain==self then env.__UnluckyEggMountain=nil end
end

if player.Character then bindCharacter(player.Character) end
task.spawn(scan)
task.spawn(function()
    local espAt, autoAt, replayAt, compactAt=0,0,0,0
    while alive do
        local now=os.clock()
        if now>=espAt then
            espAt=now+0.4
            guard(updateESP)()
            if countLabel.Parent then
                countLabel.Text="Объектов: "..#candidates.." · ESP: до 24 · PlaceId "..game.PlaceId
            end
        end
        if flags.auto and now>=autoAt then autoAt=now+0.5 guard(autoInteract)() end
        if flags.replay and now>=replayAt then replayAt=now+settings.interval guard(replayOnce)() end
        if now>=compactAt then
            compactAt=now+5
            local fresh, known={},{}
            for _,entry in ipairs(candidates) do
                if valid(entry) then fresh[#fresh+1]=entry known[entry.object]=true end
            end
            candidates,seen=fresh,known
        end
        task.wait(0.1)
    end
end)
tell("Готово. Включай функции по одной; RightCtrl открывает панель.")
