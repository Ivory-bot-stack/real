-- ===== BUTTON FARM v5 (autoaprendizaje de cooldown) =====
getgenv().BtnFarm = getgenv().BtnFarm or {}
local C = getgenv().BtnFarm

-- Cuando tengas las 8 casas, pega aquí la lista que te da "Copiar lista de casas".
local DEFAULT_HOUSES = {
    -- Vector3.new(10.50, 3.00, -20.20),
}

-- ===== CONFIG =====
C.Enabled       = false
C.ScanEvery     = 0.5     -- cada cuántos segundos revisa casas listas (la revisión es barata)
C.SettleTime    = 0.35    -- espera tras el TP
C.StepDelay     = 0.3     -- espera entre casas
C.HeightOff     = 0       -- altura extra sobre la posición guardada
C.PromptRadius  = 10      -- radio para encontrar el botón junto a cada casa
C.UseFire       = false   -- fireproximityprompt (muchos ejecutores móviles no lo traen)
C.AutoLearn     = true    -- aprende la señal de cooldown y mide el de cada casa
C.LocalCooldown = 0       -- cooldown MANUAL en segundos (0 = automático)
C.MinRetry      = 5       -- reintento mínimo por casa cuando no hay señal de cooldown
C.ExcludeWords  = C.ExcludeWords or { "chest", "cofre" }

-- Si cambias de juego, se borra lo aprendido
if C.PlaceId ~= game.PlaceId then
    C.PlaceId = game.PlaceId
    C.Signal = nil
    C.noneTries = 0
    C.State = {}
    C.Houses = {}
end
if type(C.Houses) ~= "table" then C.Houses = {} end
if #C.Houses == 0 then
    for _, v in ipairs(DEFAULT_HOUSES) do table.insert(C.Houses, v) end
end
C.State = C.State or {}
local S = C.State   -- por casa: act (última activación), cd (cooldown medido), n (muestras), rt (texto "listo"), retryAt

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer

getgenv().BtnFarmRun = (getgenv().BtnFarmRun or 0) + 1
local runId = getgenv().BtnFarmRun

local promptCache = {}   -- índice de casa -> ProximityPrompt
local waiting = {}       -- índice de casa -> { d, t0, sawBusy } (midiendo cooldown)
local busy = false

-- ===== Utilidades =====
local function st(i)
    local s = S[i]
    if not s then s = {}; S[i] = s end
    return s
end

local function getPromptPos(prompt)
    local p = prompt.Parent
    if not p then return nil end
    if p:IsA("BasePart") then return p.Position end
    if p:IsA("Attachment") then return p.WorldPosition end
    if p:IsA("Model") then return p:GetPivot().Position end
    return nil
end

local function getHRP()
    local char = lp.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function isExcluded(d)
    local hay = (d:GetFullName() .. "|" .. d.ActionText .. "|" .. d.ObjectText):lower()
    for _, w in ipairs(C.ExcludeWords) do
        if w ~= "" and hay:find(w:lower(), 1, true) then return true end
    end
    return false
end

-- Una sola pasada por el workspace para asignar botón a las casas que no lo tienen
local function refreshPrompts()
    local missing = {}
    for i = 1, #C.Houses do
        local d = promptCache[i]
        if not (d and d:IsDescendantOf(workspace)) then
            promptCache[i] = nil
            table.insert(missing, i)
        end
    end
    if #missing == 0 then return end

    local best = {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and not isExcluded(d) then
            local p = getPromptPos(d)
            if p then
                for _, i in ipairs(missing) do
                    local dist = (p - C.Houses[i]).Magnitude
                    if dist <= C.PromptRadius and (not best[i] or dist < best[i].dist) then
                        best[i] = { prompt = d, dist = dist }
                    end
                end
            end
        end
    end
    for _, i in ipairs(missing) do
        promptCache[i] = best[i] and best[i].prompt or nil
    end
end

-- ===== Detección de cooldown =====
local function textKey(d) return d.ActionText .. "|" .. d.ObjectText end

-- ¿Está listo según la señal aprendida?
local function sigReady(i, d)
    if C.Signal == "enabled" then return d.Enabled end
    local s = st(i)
    return s.rt == nil or textKey(d) == s.rt
end

local function isReady(i, d, now)
    local s = st(i)
    if s.act and now - s.act < 1 then return false end      -- evita repetir al instante
    if not d.Enabled then return false end
    if C.LocalCooldown > 0 then                              -- modo manual
        return (not s.act) or (now - s.act >= C.LocalCooldown)
    end
    if C.AutoLearn and (C.Signal == "enabled" or C.Signal == "text") then
        return sigReady(i, d)                                -- modo automático con señal
    end
    if s.act and now - s.act < C.MinRetry then return false end  -- sin señal: por tiempo
    return true
end

-- Tras activar, mira ~2 s qué cambia en el botón para saber cómo avisa el juego del cooldown
local function detectSignal(d, en0, key0)
    local t0 = os.clock()
    while os.clock() - t0 < 2 do
        if not d:IsDescendantOf(workspace) then return "none" end
        if d.Enabled ~= en0 then return "enabled" end
        if textKey(d) ~= key0 then return "text" end
        task.wait(0.05)
    end
    return "none"
end

-- Mide cuánto tarda cada casa en volver a estar lista (mientras su botón siga cargado)
local hbConn
hbConn = RunService.Heartbeat:Connect(function()
    if runId ~= getgenv().BtnFarmRun then hbConn:Disconnect() return end
    if C.Signal ~= "enabled" and C.Signal ~= "text" then return end
    local now = os.clock()
    for i, w in pairs(waiting) do
        local d = w.d
        if not d:IsDescendantOf(workspace) or now - w.t0 > 1800 then
            waiting[i] = nil
        elseif not sigReady(i, d) then
            w.sawBusy = true
        elseif w.sawBusy then
            local s = st(i)
            s.cd = now - w.t0
            s.n = (s.n or 0) + 1
            waiting[i] = nil
        end
    end
end)

local function scanReady()
    local stats = { total = #C.Houses, ready = 0, cooldown = 0, missing = 0 }
    local ready = {}
    refreshPrompts()
    local now = os.clock()
    for i, h in ipairs(C.Houses) do
        local s = st(i)
        local d = promptCache[i]
        if (s.retryAt or 0) > now then
            stats.missing += 1
        elseif d then
            if isReady(i, d, now) then
                stats.ready += 1
                table.insert(ready, { i = i, prompt = d, pos = h })
            else
                stats.cooldown += 1
            end
        else
            -- botón no cargado: si nunca se activó o ya pasó su cooldown medido, ir a cargarlo
            local due = (not s.act) or (s.cd and now - s.act >= s.cd)
            if due then
                stats.ready += 1
                table.insert(ready, { i = i, prompt = nil, pos = h })
            else
                stats.missing += 1
            end
        end
    end
    return ready, stats
end

-- ===== Ciclo =====
local function activate(prompt)
    if C.UseFire and fireproximityprompt then
        fireproximityprompt(prompt)
    else
        prompt:InputHoldBegin()
        task.wait(prompt.HoldDuration + 0.05)
        prompt:InputHoldEnd()
    end
end

local function runBatch(ready, force)
    local hrp = getHRP()
    if not hrp or #ready == 0 then return end
    local origin = hrp.CFrame

    -- orden por vecino más cercano
    local cur = hrp.Position
    local ordered = {}
    while #ready > 0 do
        local bi, bd = 1, math.huge
        for k, t in ipairs(ready) do
            local dd = (t.pos - cur).Magnitude
            if dd < bd then bi, bd = k, dd end
        end
        local t = table.remove(ready, bi)
        table.insert(ordered, t)
        cur = t.pos
    end

    for _, t in ipairs(ordered) do
        if runId ~= getgenv().BtnFarmRun or not (force or C.Enabled) then break end
        hrp = getHRP()
        if not hrp then break end
        local i = t.i
        local s = st(i)

        hrp.CFrame = CFrame.new(t.pos + Vector3.new(0, C.HeightOff, 0))
        hrp.AssemblyLinearVelocity = Vector3.zero
        task.wait(C.SettleTime)

        local d = t.prompt
        if not (d and d:IsDescendantOf(workspace)) then
            promptCache[i] = nil
            refreshPrompts()
            d = promptCache[i]
        end

        if not d then
            s.retryAt = os.clock() + 10          -- no hay botón aquí; no insistir al instante
        elseif isReady(i, d, os.clock()) then
            local en0, key0 = d.Enabled, textKey(d)
            s.rt = s.rt or key0                  -- texto del botón en estado "listo"
            activate(d)
            s.act = os.clock()

            if C.AutoLearn and C.LocalCooldown == 0 then
                if C.Signal == nil then
                    local res = detectSignal(d, en0, key0)
                    if res == "none" then
                        C.noneTries = (C.noneTries or 0) + 1
                        if C.noneTries >= 3 then C.Signal = "none" end
                    else
                        C.Signal = res
                    end
                end
                if C.Signal == "enabled" or C.Signal == "text" then
                    waiting[i] = { d = d, t0 = s.act, sawBusy = false }
                end
            end
        end
        task.wait(C.StepDelay)
    end

    local hrp2 = getHRP()
    if hrp2 then hrp2.CFrame = origin end
end

local function doPass(force)
    if busy then return end
    busy = true
    local ok, err = pcall(function()
        local ready = scanReady()
        runBatch(ready, force)
    end)
    busy = false
    if not ok then warn("[BtnFarm] " .. tostring(err)) end
end

task.spawn(function()
    while runId == getgenv().BtnFarmRun do
        task.wait(math.max(0.2, C.ScanEvery))
        if runId ~= getgenv().BtnFarmRun then break end
        if C.Enabled then doPass(false) end
    end
end)

-- ===== UI (Obsidian, móvil) =====
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/main/Library.lua"))()
pcall(function() Library:SetDPIScale(80) end)  -- baja a 70 si la ventana aún se ve grande

local OutLabel
local lastOut = ""

local function show(txt)
    lastOut = txt
    print("[BtnFarm] " .. txt)
    pcall(function() Library:Notify(txt, 6) end)
    if OutLabel then pcall(function() OutLabel:SetText(txt) end) end
end

local function modeText()
    if C.LocalCooldown > 0 then return "manual (" .. C.LocalCooldown .. "s)" end
    if C.Signal == "enabled" then return "automático (señal: Enabled)" end
    if C.Signal == "text" then return "automático (señal: texto)" end
    if C.Signal == "none" then return "sin señal del juego (usa reintento mínimo)" end
    return "aún sin aprender (se aprende al activar la primera casa)"
end

local Window = Library:CreateWindow({
    Title = "Button Farm",
    Footer = "v5 auto-cooldown",
    ToggleKeybind = Enum.KeyCode.RightControl,
})

local Tab = Window:AddTab("Main", "house")
local Box = Tab:AddLeftGroupbox("Auto farm")
local HouseBox = Tab:AddRightGroupbox("Casas")
local OutBox = Tab:AddRightGroupbox("Resultados")

-- Botón flotante "UI" (arrastrable)
local floatGui
do
    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    floatGui = Instance.new("ScreenGui")
    floatGui.Name = "BtnFarmToggle"
    floatGui.ResetOnSpawn = false
    floatGui.DisplayOrder = 999
    local ok = pcall(function() floatGui.Parent = parent end)
    if not ok or not floatGui.Parent then floatGui.Parent = lp:WaitForChild("PlayerGui") end

    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(46, 46)
    b.Position = UDim2.new(0, 10, 0.5, -23)
    b.Text = "UI"
    b.Font = Enum.Font.GothamBold
    b.TextSize = 16
    b.TextColor3 = Color3.new(1, 1, 1)
    b.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    b.BackgroundTransparency = 0.15
    b.Active = true
    b.Draggable = true
    b.Parent = floatGui
    Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0)
    b.MouseButton1Click:Connect(function()
        pcall(function() Library:Toggle() end)
    end)
end

-- ----- Controles principales -----
Box:AddToggle("BtnFarm_Enabled", {
    Text = "Activar",
    Default = C.Enabled,
    Callback = function(v) C.Enabled = v end,
})

Box:AddToggle("BtnFarm_AutoLearn", {
    Text = "Autoaprender cooldown",
    Default = C.AutoLearn,
    Callback = function(v) C.AutoLearn = v end,
})

Box:AddSlider("BtnFarm_ScanEvery", {
    Text = "Revisar cada (s)",
    Default = C.ScanEvery, Min = 0.2, Max = 5, Rounding = 1,
    Callback = function(v) C.ScanEvery = v end,
})

Box:AddSlider("BtnFarm_Settle", {
    Text = "Espera tras TP (s)",
    Default = C.SettleTime, Min = 0.05, Max = 1.5, Rounding = 2,
    Callback = function(v) C.SettleTime = v end,
})

Box:AddSlider("BtnFarm_Step", {
    Text = "Espera entre casas (s)",
    Default = C.StepDelay, Min = 0, Max = 2, Rounding = 2,
    Callback = function(v) C.StepDelay = v end,
})

Box:AddSlider("BtnFarm_Height", {
    Text = "Altura extra sobre la casa",
    Default = C.HeightOff, Min = 0, Max = 10, Rounding = 1,
    Callback = function(v) C.HeightOff = v end,
})

Box:AddSlider("BtnFarm_PromptRadius", {
    Text = "Radio del botón (studs)",
    Default = C.PromptRadius, Min = 2, Max = 30, Rounding = 0,
    Callback = function(v) C.PromptRadius = v; promptCache = {} end,
})

Box:AddSlider("BtnFarm_MinRetry", {
    Text = "Reintento mínimo sin señal (s)",
    Default = C.MinRetry, Min = 1, Max = 120, Rounding = 0,
    Callback = function(v) C.MinRetry = v end,
})

Box:AddSlider("BtnFarm_LocalCd", {
    Text = "Cooldown manual (s, 0 = auto)",
    Default = C.LocalCooldown, Min = 0, Max = 600, Rounding = 0,
    Callback = function(v) C.LocalCooldown = v end,
})

Box:AddToggle("BtnFarm_UseFire", {
    Text = "Usar fireproximityprompt",
    Default = C.UseFire,
    Callback = function(v) C.UseFire = v end,
})

Box:AddButton({
    Text = "Probar una pasada ahora",
    Func = function() task.spawn(doPass, true) end,
})

-- ----- Casas -----
local CountLabel = HouseBox:AddLabel("Casas guardadas: " .. #C.Houses)
local function refreshCount()
    pcall(function() CountLabel:SetText("Casas guardadas: " .. #C.Houses) end)
end

HouseBox:AddLabel("Párate junto al botón de cada casa:")
HouseBox:AddButton({
    Text = "Guardar casa aquí",
    Func = function()
        local hrp = getHRP()
        if not hrp then return show("No hay personaje.") end
        for _, h in ipairs(C.Houses) do
            if (h - hrp.Position).Magnitude < 3 then
                return show("Esa casa ya estaba guardada.")
            end
        end
        table.insert(C.Houses, hrp.Position)
        promptCache = {}
        refreshCount()
        local p = hrp.Position
        show(string.format("Casa %d guardada: %.1f, %.1f, %.1f", #C.Houses, p.X, p.Y, p.Z))
    end,
})

HouseBox:AddButton({
    Text = "Quitar última",
    Func = function()
        local n = #C.Houses
        table.remove(C.Houses)
        S[n] = nil
        waiting[n] = nil
        promptCache = {}
        refreshCount()
    end,
})

HouseBox:AddButton({
    Text = "Borrar todas",
    Func = function()
        C.Houses = {}
        for k in pairs(S) do S[k] = nil end
        for k in pairs(waiting) do waiting[k] = nil end
        promptCache = {}
        refreshCount()
        show("Lista de casas borrada.")
    end,
})

HouseBox:AddInput("BtnFarm_Words", {
    Text = "Palabras excluidas (coma)",
    Default = table.concat(C.ExcludeWords, ","),
    Placeholder = "chest,cofre",
    Finished = true,
    Callback = function(v)
        local t = {}
        for w in string.gmatch(v, "[^,]+") do
            w = w:gsub("^%s+", ""):gsub("%s+$", "")
            if w ~= "" then table.insert(t, w) end
        end
        C.ExcludeWords = t
        promptCache = {}
    end,
})

-- ----- Resultados (sin F9) -----
do
    local ok
    ok, OutLabel = pcall(function()
        return OutBox:AddLabel({ Text = "Aquí aparecen los resultados.", DoesWrap = true })
    end)
    if not ok or not OutLabel then OutLabel = OutBox:AddLabel("Aquí aparecen los resultados.") end
end

OutBox:AddButton({
    Text = "Estado: ¿cuántos listos?",
    Func = function()
        if #C.Houses == 0 then return show("Aún no hay casas guardadas.") end
        local _, s = scanReady()
        show(string.format("Casas: %d | LISTAS: %d | cooldown: %d | sin botón/espera: %d\nModo: %s",
            s.total, s.ready, s.cooldown, s.missing, modeText()))
    end,
})

OutBox:AddButton({
    Text = "Ver cooldowns aprendidos",
    Func = function()
        if #C.Houses == 0 then return show("Aún no hay casas guardadas.") end
        refreshPrompts()
        local now = os.clock()
        local lines = { "Modo: " .. modeText() }
        for i = 1, #C.Houses do
            local s = st(i)
            local cd = s.cd and string.format("%.1fs (%d med.)", s.cd, s.n or 1) or "sin medir"
            local d = promptCache[i]
            local estado = "no cargado"
            if d then estado = isReady(i, d, now) and "LISTA" or "en cooldown" end
            table.insert(lines, string.format("Casa %d: cd %s | %s", i, cd, estado))
        end
        show(table.concat(lines, "\n"))
    end,
})

OutBox:AddButton({
    Text = "Reaprender desde cero",
    Func = function()
        C.Signal = nil
        C.noneTries = 0
        for _, s in pairs(S) do s.cd = nil; s.n = nil; s.rt = nil; s.act = nil; s.retryAt = nil end
        for k in pairs(waiting) do waiting[k] = nil end
        show("Aprendizaje borrado. Se vuelve a aprender al activar la próxima casa.")
    end,
})

OutBox:AddButton({
    Text = "Inspeccionar botón de la casa 1",
    Func = function()
        if #C.Houses == 0 then return show("Aún no hay casas guardadas.") end
        refreshPrompts()
        local d = promptCache[1]
        if not d then return show("No encuentro el botón de la casa 1. Acércate a ella.") end
        local lines = {
            "Ruta: " .. d:GetFullName(),
            string.format("Enabled: %s | Action: '%s' | Object: '%s'", tostring(d.Enabled), d.ActionText, d.ObjectText),
            string.format("Hold: %s | MaxDist: %s | LoS: %s", d.HoldDuration, d.MaxActivationDistance, tostring(d.RequiresLineOfSight)),
        }
        for k, v in pairs(d:GetAttributes()) do table.insert(lines, "attr prompt: " .. k .. " = " .. tostring(v)) end
        if d.Parent then
            for k, v in pairs(d.Parent:GetAttributes()) do table.insert(lines, "attr padre: " .. k .. " = " .. tostring(v)) end
        end
        show(table.concat(lines, "\n"))
    end,
})

OutBox:AddButton({
    Text = "Copiar lista de casas",
    Func = function()
        local lines = {}
        for _, p in ipairs(C.Houses) do
            table.insert(lines, string.format("    Vector3.new(%.2f, %.2f, %.2f),", p.X, p.Y, p.Z))
        end
        local txt = table.concat(lines, "\n")
        lastOut = txt
        if setclipboard then
            setclipboard(txt)
            show("Lista copiada (" .. #C.Houses .. " casas). Pégala en DEFAULT_HOUSES.")
        else
            show("Tu ejecutor no tiene setclipboard. Lista:\n" .. txt)
        end
    end,
})

OutBox:AddButton({
    Text = "Copiar último resultado",
    Func = function()
        if setclipboard and lastOut ~= "" then
            setclipboard(lastOut)
            pcall(function() Library:Notify("Copiado.", 3) end)
        else
            pcall(function() Library:Notify("Tu ejecutor no tiene setclipboard.", 3) end)
        end
    end,
})

Library:OnUnload(function()
    getgenv().BtnFarmRun = (getgenv().BtnFarmRun or 0) + 1
    if hbConn then hbConn:Disconnect() end
    if floatGui then floatGui:Destroy() end
end)