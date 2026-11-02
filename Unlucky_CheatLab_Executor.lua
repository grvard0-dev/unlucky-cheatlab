--!nonstrict
-- UNLUCKY CHEAT LAB v1.1 | Самостоятельный клиентский Lua-скрипт.
-- Запуск: загрузи свой тестовый place, вставь ВЕСЬ файл в Lua-окно исполнителя
-- и нажми Execute. Нужен доступ к обычному Roblox client API: game/Instance/task.
-- Не зависит от переменной script и не требует Roblox Studio.
-- RightShift скрывает панель. X выключает функции, восстанавливает свойства и закрывает её.
-- Совместимость с конкретным исполнителем не гарантируется; в нём скрипт не проверялся.
-- Мягкий профиль = небольшие изменения + плавный разгон, НЕ гарантия незаметности.
-- Это клиентские изменения для изучения репликации. Серверная защита их может отменять.
-- Нет загрузчиков, HTTP-запросов, сторонних модулей и доступа к чужим RemoteEvents.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

if not RunService:IsClient() then
    warn("[CheatLab] Нужен клиентский Roblox Lua-контекст.")
    return
end

local player = Players.LocalPlayer
if not player then
    warn("[CheatLab] Сначала дождись загрузки игрока в своём тестовом place.")
    return
end
local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 15)
if not playerGui then
    warn("[CheatLab] PlayerGui пока недоступен. Повтори запуск после загрузки игрока.")
    return
end
local previous = playerGui:FindFirstChild("UnluckyCheatLab")
if previous then
    local shutdown = previous:FindFirstChild("Shutdown")
    if shutdown and shutdown:IsA("BindableEvent") then
        shutdown:Fire()
    end
    previous:Destroy()
end

local profiles = {
    { name = "МЯГКИЙ", speed = 18, jump = 56, fly = 18, ramp = 1.5,
      flightBlend = 4, shift = 12, duration = 1.2 },
    { name = "ЯВНЫЙ", speed = 64, jump = 110, fly = 60, ramp = 1000,
      flightBlend = 1000, shift = 60, duration = 0 },
}
local profileIndex = 1
local settings = { speed = 18, jump = 56, fly = 18 }
local enabled = { speed = false, jump = false, fly = false, noclip = false }
local connections, characterConnections = {}, {}
local character, humanoid, root
local parts, collisionRestore = {}, {}
local savedSpeed, savedJump, savedFly
local walkValue, flyAttachment, flyMover
local waypoint, smoothMove
local generation, closed = 0, false
local gui, panel, statusLabel, telemetryLabel, profileButton, reopenButton
local toggleButtons, valueBoxes = {}, {}

local function connect(signal, callback, list)
    local connection = signal:Connect(callback)
    table.insert(list or connections, connection)
    return connection
end

local function disconnectAll(list)
    for _, connection in ipairs(list) do
        connection:Disconnect()
    end
    table.clear(list)
end

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function readNumber(text, minimum, maximum)
    local value = tonumber(text)
    if finite(value) and value >= minimum and value <= maximum then
        return value
    end
    return nil
end

local function ready()
    return not closed and character and character.Parent and humanoid
        and humanoid.Parent and humanoid.Health > 0 and root and root.Parent
end

local function notify(message)
    if statusLabel then
        statusLabel.Text = message
    end
end

local function syncButtons()
    for name, button in pairs(toggleButtons) do
        button.Text = enabled[name] and "ВКЛ" or "ВЫКЛ"
        button.BackgroundColor3 = enabled[name]
            and Color3.fromRGB(42, 111, 238) or Color3.fromRGB(37, 45, 65)
    end
end

local function restoreCollisions()
    for part, original in pairs(collisionRestore) do
        if part.Parent then
            part.CanCollide = original
        end
    end
    table.clear(collisionRestore)
end

local function makeNonColliding(part)
    if collisionRestore[part] == nil then
        collisionRestore[part] = part.CanCollide
    end
    part.CanCollide = false
end

-- Снимки свойств делаются при включении, а не задаются константами 16/50.
-- Поэтому выключение возвращает именно исходную конфигурацию этого персонажа.
local function setFeature(name, state)
    if enabled[name] == nil then
        return false
    end
    if enabled[name] == state then
        return true
    end
    if state and not ready() then
        notify("Сначала дождись живого персонажа.")
        return false
    end
    if state and name == "fly" and humanoid.SeatPart then
        notify("Перед полётом выйди из транспорта.")
        return false
    end

    if name == "speed" then
        if state then
            savedSpeed = humanoid.WalkSpeed
            walkValue = savedSpeed
        elseif savedSpeed ~= nil and humanoid and humanoid.Parent then
            humanoid.WalkSpeed = savedSpeed
        end
        if not state then savedSpeed = nil end
    elseif name == "jump" then
        if state then
            savedJump = { usePower = humanoid.UseJumpPower,
                power = humanoid.JumpPower, height = humanoid.JumpHeight }
        elseif savedJump and humanoid and humanoid.Parent then
            humanoid.UseJumpPower = savedJump.usePower
            humanoid.JumpPower = savedJump.power
            humanoid.JumpHeight = savedJump.height
        end
        if not state then savedJump = nil end
    elseif name == "fly" then
        if state then
            savedFly = { autoRotate = humanoid.AutoRotate,
                platformStand = humanoid.PlatformStand }
            flyAttachment = Instance.new("Attachment")
            flyAttachment.Name = "CheatLabFlightAttachment"
            flyAttachment.Parent = root
            flyMover = Instance.new("LinearVelocity")
            flyMover.Name = "CheatLabFlightVelocity"
            flyMover.Attachment0 = flyAttachment
            flyMover.RelativeTo = Enum.ActuatorRelativeTo.World
            flyMover.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
            flyMover.ForceLimitsEnabled = false
            flyMover.VectorVelocity = Vector3.zero
            flyMover.Parent = root
            humanoid.PlatformStand = true
            humanoid.AutoRotate = false
        else
            if flyMover then flyMover:Destroy() end
            if flyAttachment then flyAttachment:Destroy() end
            flyMover, flyAttachment = nil, nil
            if savedFly and humanoid and humanoid.Parent then
                humanoid.AutoRotate = savedFly.autoRotate
                humanoid.PlatformStand = savedFly.platformStand
                if not savedFly.platformStand and humanoid.Health > 0 then
                    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                end
            end
            if root and root.Parent then
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end
            savedFly = nil
        end
    elseif name == "noclip" then
        if state then
            for part in pairs(parts) do
                if part.Parent then makeNonColliding(part) end
            end
        else
            restoreCollisions()
        end
    end
    enabled[name] = state
    syncButtons()
    return true
end

local function resetFeatures()
    smoothMove = nil
    for _, name in ipairs({ "speed", "jump", "fly", "noclip" }) do
        setFeature(name, false)
    end
end

local function selectProfile(index)
    profileIndex = index
    local profile = profiles[index]
    for _, key in ipairs({ "speed", "jump", "fly" }) do
        settings[key] = profile[key]
        if valueBoxes[key] then valueBoxes[key].Text = tostring(profile[key]) end
    end
    if profileButton then profileButton.Text = "ПРОФИЛЬ: " .. profile.name .. "  /  сменить" end
    notify(index == 1 and "Малые изменения и плавный разгон. Это не невидимость."
        or "Заметные изменения для проверки базовых детектов.")
end

-- Цель задаётся для HumanoidRootPart, с сохранением смещения pivot модели.
local function moveRootTo(target)
    local offset = root.CFrame:ToObjectSpace(character:GetPivot())
    character:PivotTo(target * offset)
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function teleport(target, duration)
    if not ready() then
        notify("Персонаж пока не готов.")
        return false
    end
    if humanoid.SeatPart then
        notify("Перед перемещением выйди из транспорта.")
        return false
    end
    if duration > 0 then
        smoothMove = { start = root.CFrame, target = target, elapsed = 0, duration = duration }
    else
        smoothMove = nil
        moveRootTo(target)
    end
    return true
end

local function flatForward()
    local camera = Workspace.CurrentCamera
    local look = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)
    local flat = Vector3.new(look.X, 0, look.Z)
    return flat.Magnitude > 0.001 and flat.Unit or Vector3.new(0, 0, -1)
end

local function flyDirection()
    if UserInputService:GetFocusedTextBox() then return Vector3.zero end
    local forward = flatForward()
    local right = Vector3.new(-forward.Z, 0, forward.X)
    local direction = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + forward end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - forward end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + right end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - right end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction = direction + Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
        direction = direction - Vector3.yAxis
    end
    -- Диагональное движение не даёт скрытого множителя скорости.
    return direction.Magnitude > 1 and direction.Unit or direction
end

local function step(deltaTime)
    if not ready() then return end
    -- Ограничиваем только шаг сглаживания: зависание кадра не даёт огромного скачка.
    local dt = math.clamp(deltaTime, 0, 0.25)
    local profile = profiles[profileIndex]
    if enabled.speed then
        local difference = settings.speed - walkValue
        local limit = profile.ramp * dt
        walkValue = walkValue + math.clamp(difference, -limit, limit)
        humanoid.WalkSpeed = walkValue
    end
    if enabled.jump then
        humanoid.UseJumpPower = true
        humanoid.JumpPower = settings.jump
    end
    if enabled.noclip then
        for part in pairs(parts) do
            if part.Parent then makeNonColliding(part) end
        end
    end
    if enabled.fly and flyMover then
        humanoid.PlatformStand = true
        humanoid.AutoRotate = false
        local targetVelocity = smoothMove and Vector3.zero or flyDirection() * settings.fly
        local alpha = 1 - math.exp(-profile.flightBlend * dt)
        flyMover.VectorVelocity = flyMover.VectorVelocity:Lerp(targetVelocity, alpha)
        root.AssemblyAngularVelocity = Vector3.zero
    end
    if smoothMove then
        smoothMove.elapsed = math.min(smoothMove.duration, smoothMove.elapsed + dt)
        local alpha = smoothMove.elapsed / smoothMove.duration
        -- Smoothstep даёт плавный старт и остановку, но путь остаётся прямым.
        local eased = alpha * alpha * (3 - 2 * alpha)
        moveRootTo(smoothMove.start:Lerp(smoothMove.target, eased))
        if alpha >= 1 then smoothMove = nil end
    end
end

local function bindCharacter(nextCharacter)
    generation = generation + 1
    local ticket = generation
    resetFeatures()
    disconnectAll(characterConnections)
    table.clear(parts)
    waypoint = nil
    character, humanoid, root = nextCharacter, nil, nil
    if not nextCharacter then
        notify("Жду появления персонажа…")
        return
    end
    notify("Подключаю персонажа…")
    task.spawn(function()
        local nextHumanoid = nextCharacter:WaitForChild("Humanoid", 10)
        local nextRoot = nextCharacter:WaitForChild("HumanoidRootPart", 10)
        if closed or ticket ~= generation or player.Character ~= nextCharacter then return end
        if not nextHumanoid or not nextHumanoid:IsA("Humanoid")
            or not nextRoot or not nextRoot:IsA("BasePart") then
            notify("Нужен стандартный персонаж R6/R15 с HumanoidRootPart.")
            return
        end
        humanoid, root = nextHumanoid, nextRoot
        for _, item in ipairs(nextCharacter:GetDescendants()) do
            if item:IsA("BasePart") then parts[item] = true end
        end
        connect(nextCharacter.DescendantAdded, function(item)
            if item:IsA("BasePart") then
                parts[item] = true
                if enabled.noclip then makeNonColliding(item) end
            end
        end, characterConnections)
        connect(nextCharacter.DescendantRemoving, function(item)
            if collisionRestore[item] ~= nil then
                item.CanCollide = collisionRestore[item]
                collisionRestore[item] = nil
            end
            parts[item] = nil
        end, characterConnections)
        connect(humanoid.Died, function()
            resetFeatures()
            notify("Персонаж погиб. Функции выключены.")
        end, characterConnections)
        notify("Готов. Выбери функцию; RightShift скрывает панель.")
    end)
end

-- UI: все надписи и значения видны в обычном PlayerGui, без обфускации.
local function create(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties) do object[key] = value end
    object.Parent = parent
    return object
end

local function round(object, radius)
    create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, object)
end

gui = create("ScreenGui", { Name = "UnluckyCheatLab", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 30 }, playerGui)
local shutdown = create("BindableEvent", { Name = "Shutdown" }, gui)
panel = create("Frame", { Name = "Panel", Size = UDim2.fromOffset(380, 626),
    AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
    BackgroundColor3 = Color3.fromRGB(18, 23, 36), BorderSizePixel = 0 }, gui)
round(panel, 14)
create("UIStroke", { Color = Color3.fromRGB(62, 85, 130), Thickness = 1 }, panel)
local scale = create("UIScale", { Scale = 1 }, panel)

local function label(text, x, y, width, height, size, parent)
    return create("TextLabel", { Text = text, Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(width, height), BackgroundTransparency = 1,
        TextColor3 = Color3.fromRGB(220, 230, 248), Font = Enum.Font.Gotham,
        TextSize = size or 14, TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true }, parent or panel)
end

local function button(text, x, y, width, height, callback, parent)
    local object = create("TextButton", { Text = text, Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(width, height), BackgroundColor3 = Color3.fromRGB(37, 45, 65),
        TextColor3 = Color3.fromRGB(235, 241, 255), Font = Enum.Font.GothamMedium,
        TextSize = 13, BorderSizePixel = 0, AutoButtonColor = true }, parent or panel)
    round(object)
    connect(object.Activated, callback)
    return object
end

local function textBox(text, placeholder, x, y, width)
    local object = create("TextBox", { Text = text, PlaceholderText = placeholder,
        Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, 34),
        BackgroundColor3 = Color3.fromRGB(28, 35, 53), TextColor3 = Color3.fromRGB(214, 231, 255),
        PlaceholderColor3 = Color3.fromRGB(133, 149, 177), Font = Enum.Font.Code,
        TextSize = 15, ClearTextOnFocus = false, BorderSizePixel = 0 }, panel)
    round(object)
    return object
end

local title = label("UNLUCKY · CHEAT LAB", 16, 9, 274, 25, 18)
title.Font = Enum.Font.GothamBold
title.TextColor3 = Color3.fromRGB(119, 178, 255)
title.Active = true
label("Клиентский тест • Lua runner", 16, 35, 300, 16, 12)

local function setPanelVisible(visible)
    panel.Visible = visible
    reopenButton.Visible = not visible
end

local function cleanup()
    if closed then return end
    resetFeatures()
    closed = true
    generation = generation + 1
    disconnectAll(characterConnections)
    disconnectAll(connections)
    gui:Destroy()
end

button("—", 294, 12, 30, 28, function() setPanelVisible(false) end)
button("X", 332, 12, 30, 28, cleanup)
reopenButton = button("Открыть Cheat Lab", 16, 80, 166, 34,
    function() setPanelVisible(true) end, gui)
reopenButton.Visible = false
profileButton = button("", 16, 64, 348, 32, function()
    selectProfile(profileIndex == 1 and 2 or 1)
end)
label("Мягкий профиль проверяет чувствительность детектора.", 16, 101, 348, 22, 11)

for index, entry in ipairs({ { "speed", "Скорость", 1, 200 },
    { "jump", "Сила прыжка", 1, 180 }, { "fly", "Полёт", 1, 150 },
    { "noclip", "Сквозь стены" } }) do
    local name, caption, minimum, maximum = entry[1], entry[2], entry[3], entry[4]
    local y = 132 + (index - 1) * 42
    label(caption, 16, y, 158, 34, 14)
    if name ~= "noclip" then
        local box = textBox(tostring(settings[name]), "число", 176, y, 86)
        valueBoxes[name] = box
        connect(box.FocusLost, function()
            local value = readNumber(box.Text, minimum, maximum)
            if value then
                settings[name] = value
                notify(caption .. ": " .. tostring(value))
            else
                box.Text = tostring(settings[name])
                notify("Нужно конечное число " .. minimum .. "–" .. maximum .. ".")
            end
        end)
    end
    toggleButtons[name] = button("ВЫКЛ", 276, y, 88, 34, function()
        setFeature(name, not enabled[name])
    end)
end

label("Полёт: WASD · Space вверх · Ctrl вниз\nRightShift: скрыть / показать; функции продолжают работать.",
    16, 302, 348, 29, 11)
button("Сдвиг вперёд по профилю", 16, 339, 348, 32, function()
    if not ready() then notify("Дождись персонажа."); return end
    local profile = profiles[profileIndex]
    local position = root.Position + flatForward() * profile.shift
    if teleport(CFrame.new(position) * root.CFrame.Rotation, profile.duration) then
        notify(profile.duration > 0 and "Плавный прямой сдвиг на 12 studs."
            or "Резкий сдвиг на 60 studs.")
    end
end)
button("Запомнить точку", 16, 379, 169, 32, function()
    if ready() then waypoint = root.CFrame; notify("Точка сохранена до респавна.") end
end)
button("Вернуться", 195, 379, 169, 32, function()
    if waypoint then
        if teleport(waypoint, 0) then notify("Возврат в сохранённую точку.") end
    else
        notify("Сначала запомни точку.")
    end
end)
local xBox = textBox("", "X", 16, 422, 109)
local yBox = textBox("", "Y", 135, 422, 110)
local zBox = textBox("", "Z", 255, 422, 109)
button("Телепорт к X / Y / Z  ·  мгновенно", 16, 466, 348, 32, function()
    local x = readNumber(xBox.Text, -10000, 10000)
    local y = readNumber(yBox.Text, -10000, 10000)
    local z = readNumber(zBox.Text, -10000, 10000)
    if not x or not y or not z then notify("Укажи три числа от −10000 до 10000."); return end
    if not ready() then notify("Дождись персонажа."); return end
    if teleport(CFrame.new(x, y, z) * root.CFrame.Rotation, 0) then
        notify("Мгновенный телепорт выполнен на клиенте.")
    end
end)
button("ВЫКЛЮЧИТЬ ВСЕ ФУНКЦИИ", 16, 508, 348, 32, function()
    resetFeatures()
    notify("Функции выключены; исходные свойства восстановлены.")
end)
telemetryLabel = label("Локальная телеметрия: ожидание…", 16, 548, 348, 32, 11)
statusLabel = label("", 16, 588, 348, 27, 11)
statusLabel.TextColor3 = Color3.fromRGB(151, 184, 230)

-- Перетаскивание за заголовок. Никаких скрытых обработчиков ввода.
local dragging, dragStart, panelStart = false, nil, nil
connect(title.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragStart, panelStart = true, input.Position, panel.Position
    end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)
connect(UserInputService.InputChanged, function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local difference = input.Position - dragStart
        panel.Position = UDim2.new(panelStart.X.Scale, panelStart.X.Offset + difference.X,
            panelStart.Y.Scale, panelStart.Y.Offset + difference.Y)
    end
end)
connect(UserInputService.InputBegan, function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift
        and not UserInputService:GetFocusedTextBox() then
        setPanelVisible(not panel.Visible)
    end
end)

local telemetryTime, lastPosition, telemetryCharacter = 0, nil, nil
connect(RunService.Heartbeat, function(dt)
    telemetryTime = telemetryTime + dt
    if telemetryTime < 0.25 then return end
    local elapsed = telemetryTime
    telemetryTime = 0
    local camera = Workspace.CurrentCamera
    if camera then
        local size = camera.ViewportSize
        scale.Scale = math.clamp(math.min((size.X - 24) / 380, (size.Y - 72) / 626), 0.4, 1)
    end
    if ready() then
        if telemetryCharacter ~= character then lastPosition = nil end
        local position = root.Position
        local delta = lastPosition and position - lastPosition or Vector3.zero
        local horizontal = Vector3.new(delta.X, 0, delta.Z).Magnitude / elapsed
        telemetryLabel.Text = string.format("КЛИЕНТ  X %.1f  Y %.1f  Z %.1f\nСдвиг по XZ: %.1f studs/s  |  WalkSpeed: %.1f",
            position.X, position.Y, position.Z, horizontal, humanoid.WalkSpeed)
        lastPosition, telemetryCharacter = position, character
    else
        telemetryLabel.Text = "Локальная телеметрия: персонаж не готов."
        lastPosition, telemetryCharacter = nil, nil
    end
end)

connect(shutdown.Event, cleanup)
-- У исполнителя переменной script может не быть. Время жизни привязано к самой панели.
-- Удаление GUI также отключает эффекты и освобождает все соединения.
connect(gui.Destroying, cleanup)
connect(RunService.PreSimulation, step)
connect(player.CharacterAdded, bindCharacter)
connect(player.CharacterRemoving, function(oldCharacter)
    if character == oldCharacter then bindCharacter(nil) end
end)
selectProfile(1)
syncButtons()
if player.Character then bindCharacter(player.Character) else notify("Жду появления персонажа…") end
