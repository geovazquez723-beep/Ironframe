-- Cockpit and hangar atmosphere (M06A) built ONLY from audio files that ship inside the Roblox client
-- (rbxasset://sounds/*), shaped with the Audio API (low-pass filters, playback speed, faders). No cloud audio asset is
-- assumed to exist and none is generated: if any piece fails to build it is skipped and reported by Audio.Report().
--   reactor hum   explosion sample, looped, pitched down and low-passed -> deep machine rumble
--   air handling  swim sample, looped, low-passed -> faint ventilation wash
--   hangar bed    plastic-footstep sample, very slow, low-passed, quiet -> distant industrial thuds
--   indicator     slider sample, pitched up, short and quiet -> startup blips

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Audio = {}

local FILES = {
    hum = "rbxasset://sounds/impact_explosion_03.mp3",
    air = "rbxasset://sounds/action_swim.mp3",
    hangar = "rbxasset://sounds/action_footsteps_plastic.mp3",
    blip = "rbxasset://sounds/volume_slider.ogg",
}

local container: Folder? = nil
local voices: { [string]: { player: AudioPlayer, fader: AudioFader, filter: AudioFilter?, target: number, current: number, baseSpeed: number } } = {}
local report: { [string]: string } = {}
local cockpitMix, spool = 0, 0 -- 0..1 targets
local started = false

local function wire(source: Instance, target: Instance)
    local w = Instance.new("Wire")
    w.SourceInstance, w.TargetInstance = source, target
    w.Parent = container
end

local function voice(name: string, file: string, lowpass: number?, speed: number, looped: boolean)
    local ok, err = pcall(function()
        local player = Instance.new("AudioPlayer")
        player.Name = name
        player.AssetId = file
        player.Looping = looped
        player.PlaybackSpeed = speed
        player.Volume = 1
        player.Parent = container
        local fader = Instance.new("AudioFader")
        fader.Name = name .. "Fader"
        fader.Volume = 0
        fader.Parent = container
        local filter: AudioFilter? = nil
        if lowpass then
            filter = Instance.new("AudioFilter")
            filter.Name = name .. "Lowpass"
            filter.FilterType = Enum.AudioFilterType.Lowpass24dB
            filter.Frequency = lowpass
            filter.Parent = container
            wire(player, filter)
            wire(filter, fader)
        else
            wire(player, fader)
        end
        wire(fader, container:FindFirstChild("Output") :: Instance)
        voices[name] = { player = player, fader = fader, filter = filter, target = 0, current = 0, baseSpeed = speed }
    end)
    report[name] = if ok then "built" else ("FAILED: " .. tostring(err))
end

function Audio.Start()
    if started then
        return
    end
    started = true
    container = Instance.new("Folder")
    container.Name = "IronframeCockpitAudio"
    container.Parent = SoundService
    local ok, err = pcall(function()
        local output = Instance.new("AudioDeviceOutput")
        output.Name = "Output"
        output.Parent = container
    end)
    if not ok then
        report.output = "FAILED: " .. tostring(err)
        return
    end
    voice("hum", FILES.hum, 150, 0.32, true)
    voice("air", FILES.air, 420, 0.5, true)
    voice("hangar", FILES.hangar, 260, 0.35, true)
    for _, v in pairs(voices) do
        v.player:Play()
    end
    RunService.Heartbeat:Connect(function(dt)
        local t = os.clock()
        -- Slow smoothing of every voice level; hum pitch follows the reactor spool.
        local hum, air, hangar = voices.hum, voices.air, voices.hangar
        if hum then
            hum.target = (0.04 + 0.5 * cockpitMix) * spool
            hum.player.PlaybackSpeed = hum.baseSpeed * (0.8 + 0.5 * spool) * (1 + 0.012 * math.sin(t * 0.7))
        end
        if air then
            air.target = 0.05 * cockpitMix * spool
        end
        if hangar then
            hangar.target = 0.1 * (1 - 0.6 * cockpitMix)
        end
        local alpha = 1 - math.exp(-dt * 2.2)
        for _, v in pairs(voices) do
            v.current += (v.target - v.current) * alpha
            v.fader.Volume = v.current
        end
    end)
end

-- 0 = standing in the hangar view, 1 = sealed inside the cockpit.
function Audio.SetCockpit(amount: number)
    cockpitMix = amount
end

-- 0 = reactor cold, 1 = nominal idle. Driven by the boot sequence.
function Audio.SetSpool(amount: number)
    spool = amount
end

-- Quiet one-shot indicator blip.
function Audio.Blip(pitch: number?)
    if not container or report.blip == "FAILED" then
        return
    end
    pcall(function()
        local output = container:FindFirstChild("Output")
        local player = Instance.new("AudioPlayer")
        player.AssetId = FILES.blip
        player.PlaybackSpeed = pitch or 2
        player.Volume = 0.18
        player.Parent = container
        wire(player, output :: Instance)
        player:Play()
        task.delay(0.6, function()
            player:Destroy()
        end)
        report.blip = "ok"
    end)
end

function Audio.Report(): { [string]: string }
    local out = table.clone(report)
    for name, v in pairs(voices) do
        out[name] = string.format("%s len=%.1fs playing=%s vol=%.3f", report[name], v.player.TimeLength, tostring(v.player.IsPlaying), v.fader.Volume)
    end
    return out
end

return Audio
