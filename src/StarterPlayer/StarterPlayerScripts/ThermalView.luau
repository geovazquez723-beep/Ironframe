-- Simulated thermal imager view (M11C). Presentation only: the SERVER decides which machines have a thermal signature the pilot can see (real line of sight,
-- the imager's range, the machine's signature level), and sends only those. This module just renders them.
--
--   FULL      camera-local colour correction (grey world, lifted contrast, a slight cold tint) + a light blur, a scanline layer, and one
--             `Highlight` per hot machine with DepthMode = Occluded: the glow is drawn only where the machine is actually visible, so cover blocks
--             it exactly as it blocks the eye. No AlwaysOnTop, no X-ray.
--   BASIC     colour correction only (low graphics quality); the highlights still apply.
--   MARKERS   no highlights at all (the instance could not be created): the tracking overlay draws heat blobs at the machines' screen positions,
--             again only for machines the server reported visible.
-- It is a GAME effect, not heat physics (see docs/M11C_COCKPIT_ENGINEERING.md, limitations). The post effects are parented to the Camera, so
-- nothing outside this client's view changes, and every instance is removed on SetActive(false) and Destroy.

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

local View = {}
View.__index = View

local MAX_HIGHLIGHTS = 4
local FADE = 0.25

local function heatColor(level: number): Color3
    if level < 0.4 then
        return Color3.fromRGB(70, 92, 124):Lerp(Color3.fromRGB(235, 124, 44), level / 0.4)
    elseif level < 0.7 then
        return Color3.fromRGB(235, 124, 44):Lerp(Color3.fromRGB(255, 214, 120), (level - 0.4) / 0.3)
    end
    return Color3.fromRGB(255, 214, 120):Lerp(Color3.fromRGB(255, 250, 238), math.min((level - 0.7) / 0.3, 1))
end
View.HeatColor = heatColor

-- "FULL" | "BASIC" | "MARKERS". Low graphics quality drops the blur and scanlines; a player attribute (ThermalMode) forces a mode for testing.
function View.DetectMode(): string
    local forced = Players.LocalPlayer and Players.LocalPlayer:GetAttribute("ThermalMode")
    if forced == "FULL" or forced == "BASIC" or forced == "MARKERS" then
        return forced
    end
    local ok, probe = pcall(function()
        local h = Instance.new("Highlight")
        h:Destroy()
        return true
    end)
    if not ok or not probe then
        return "MARKERS"
    end
    local qualityOk, quality = pcall(function()
        return settings().Rendering.QualityLevel.Value
    end)
    if qualityOk and quality >= 1 and quality <= 2 then
        return "BASIC"
    end
    return "FULL"
end

function View.New()
    local self = setmetatable({
        active = false, mode = View.DetectMode(), highlights = {}, targets = {}, token = 0,
        folder = nil :: Folder?, cc = nil :: ColorCorrectionEffect?, blur = nil :: BlurEffect?, gui = nil :: ScreenGui?,
    }, View)
    return self
end

local function ensureEffects(self)
    local camera = workspace.CurrentCamera
    if not self.folder or not self.folder.Parent then
        self.folder = Instance.new("Folder")
        self.folder.Name = "IronframeThermalClient" -- client-created, never replicated
        self.folder.Parent = workspace
    end
    if not self.cc or not self.cc.Parent then
        local cc = Instance.new("ColorCorrectionEffect")
        cc.Name = "IronframeThermalCC"
        cc.Enabled = false
        cc.Parent = camera
        self.cc = cc
    end
    if self.mode == "FULL" and (not self.blur or not self.blur.Parent) then
        local blur = Instance.new("BlurEffect")
        blur.Name = "IronframeThermalBlur"
        blur.Size = 0
        blur.Enabled = false
        blur.Parent = camera
        self.blur = blur
    end
    if self.mode == "FULL" and (not self.gui or not self.gui.Parent) then
        local gui = Instance.new("ScreenGui")
        gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset, gui.DisplayOrder, gui.Enabled = "IronframeThermalGui", false, true, 18, false
        gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
        for i = 0, 53 do
            local line = Instance.new("Frame")
            line.Size = UDim2.new(1, 0, 0, 2)
            line.Position = UDim2.new(0, 0, i / 54, 0)
            line.BackgroundColor3 = Color3.new(0, 0, 0)
            line.BackgroundTransparency = 0.88
            line.BorderSizePixel = 0
            line.Parent = gui
        end
        for _, edge in ipairs({ { UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0.12, 0), 90 }, { UDim2.new(0, 0, 0.88, 0), UDim2.new(1, 0, 0.12, 0), 270 },
            { UDim2.new(0, 0, 0, 0), UDim2.new(0.1, 0, 1, 0), 0 }, { UDim2.new(0.9, 0, 0, 0), UDim2.new(0.1, 0, 1, 0), 180 } }) do
            local frame = Instance.new("Frame")
            frame.Position, frame.Size, frame.BorderSizePixel, frame.BackgroundColor3 = edge[1], edge[2], 0, Color3.new(0, 0, 0)
            local gradient = Instance.new("UIGradient")
            gradient.Rotation = edge[3]
            gradient.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
            gradient.Parent = frame
            frame.Parent = gui
        end
        local tag = Instance.new("TextLabel")
        tag.Name = "Tag"
        tag.Size, tag.Position, tag.BackgroundTransparency = UDim2.fromOffset(260, 22), UDim2.new(0.5, -130, 1, -96), 1
        tag.Font, tag.TextSize, tag.TextColor3, tag.TextXAlignment, tag.Text = Enum.Font.RobotoMono, 16, Color3.fromRGB(255, 232, 190), Enum.TextXAlignment.Center, "THERMAL IMAGER  WHITE-HOT"
        tag.Parent = gui
        self.gui = gui
    end
    while self.mode ~= "MARKERS" and #self.highlights < MAX_HIGHLIGHTS do
        local ok, h = pcall(function()
            local highlight = Instance.new("Highlight")
            highlight.Name = "Hot" .. (#self.highlights + 1)
            highlight.DepthMode = Enum.HighlightDepthMode.Occluded -- hidden behind solid cover, exactly like the machine itself
            highlight.Enabled = false
            highlight.Parent = self.folder
            return highlight
        end)
        if not ok then
            self.mode = "MARKERS"
            break
        end
        table.insert(self.highlights, h)
    end
end

-- Forces a presentation mode (tests, or a settings hook): the thermal view must be off while it changes.
function View.SetMode(self, mode: string)
    if not self.active and (mode == "FULL" or mode == "BASIC" or mode == "MARKERS") then
        self.mode = mode
    end
end

function View.SetActive(self, on: boolean)
    if on == self.active then
        return
    end
    self.active = on
    self.token += 1
    local token = self.token
    if on then
        ensureEffects(self)
        local cc = self.cc :: ColorCorrectionEffect
        cc.Enabled = true
        TweenService:Create(cc, TweenInfo.new(FADE), { Saturation = -0.7, Contrast = 0.25, Brightness = 0.02, TintColor = Color3.fromRGB(205, 224, 255) }):Play()
        if self.blur then
            self.blur.Enabled = true
            TweenService:Create(self.blur, TweenInfo.new(FADE), { Size = 1.5 }):Play()
        end
        if self.gui then
            self.gui.Enabled = true
        end
    else
        for _, h in ipairs(self.highlights) do
            h.Enabled = false
            h.Adornee = nil
        end
        if self.gui then
            self.gui.Enabled = false
        end
        local cc = self.cc
        if cc then
            local tween = TweenService:Create(cc, TweenInfo.new(FADE), { Saturation = 0, Contrast = 0, Brightness = 0, TintColor = Color3.new(1, 1, 1) })
            tween:Play()
            task.delay(FADE + 0.05, function()
                if self.token == token and cc.Parent then
                    cc.Enabled = false
                end
            end)
        end
        if self.blur then
            local blur = self.blur
            TweenService:Create(blur, TweenInfo.new(FADE), { Size = 0 }):Play()
            task.delay(FADE + 0.05, function()
                if self.token == token and blur.Parent then
                    blur.Enabled = false
                end
            end)
        end
    end
end

-- list = { { m = Instance, lv = 0..1 } } from the server (only machines in line of sight, in range, and warm enough to show).
function View.SetTargets(self, list: { any }?)
    self.targets = list or {}
    if not self.active or self.mode == "MARKERS" then
        return
    end
    for i, h in ipairs(self.highlights) do
        local entry = self.targets[i]
        if entry and typeof(entry.m) == "Instance" and entry.m.Parent then
            local level = math.clamp(entry.lv or 0, 0, 1)
            local color = heatColor(level)
            h.Adornee = entry.m
            h.FillColor = color
            h.FillTransparency = 0.8 - 0.55 * level
            h.OutlineColor = color:Lerp(Color3.new(1, 1, 1), 0.4)
            h.OutlineTransparency = 0.55 - 0.45 * level
            h.Enabled = true
        else
            h.Enabled = false
            h.Adornee = nil
        end
    end
end

function View.Report(self)
    local lit = 0
    for _, h in ipairs(self.highlights) do
        if h.Enabled and h.Adornee then
            lit += 1
        end
    end
    local descendants = 0
    if self.folder then
        descendants += #self.folder:GetDescendants()
    end
    return {
        active = self.active, mode = self.mode, lit = lit, highlights = #self.highlights, targets = #self.targets,
        cc = self.cc ~= nil and self.cc.Enabled, saturation = self.cc ~= nil and self.cc.Saturation or nil, blur = self.blur ~= nil and self.blur.Enabled, gui = self.gui ~= nil and self.gui.Enabled,
        instances = descendants + (if self.gui then #self.gui:GetDescendants() + 1 else 0) + (if self.cc then 1 else 0) + (if self.blur then 1 else 0),
        depthModeOccluded = self.highlights[1] ~= nil and self.highlights[1].DepthMode == Enum.HighlightDepthMode.Occluded,
    }
end

function View.Destroy(self)
    self.active = false
    self.token += 1
    if self.folder then self.folder:Destroy() end
    if self.cc then self.cc:Destroy() end
    if self.blur then self.blur:Destroy() end
    if self.gui then self.gui:Destroy() end
    self.folder, self.cc, self.blur, self.gui = nil, nil, nil, nil
    table.clear(self.highlights)
end

return View
