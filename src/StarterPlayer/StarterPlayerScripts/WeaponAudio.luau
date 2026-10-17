-- Fixed voice pool. Legacy spatial Sounds coexist with CockpitAudio's modular atmosphere, using its perspective mix.
local Shared=game.ReplicatedStorage.IronframeShared
local Config=require(Shared.WeaponPresentation).audio
local Atmosphere=require(script.Parent.CockpitAudio)
-- Cockpit EQ targets (dB at full cockpit mix): low, mid, high. The heavy cannon keeps more body and loses more bite.
local BASE_EQ,HEAVY_EQ={0,-2,-14},{3,-4,-20}
local Audio={}
Audio.__index=Audio
function Audio.New(root)
    local folder=Instance.new("Folder")
    folder.Name,folder.Parent="Audio",root
    local self=setmetatable({folder=folder,voices={},random=Random.new(),lastDetail=-100,
        stats={played=0,stolen=0,missingLaser=0,missingMauler=0,peak=0}},Audio)
    for i=1,Config.dischargeVoices+Config.detailVoices do
        local emitter=Instance.new("Part")
        emitter.Name,emitter.Size,emitter.Transparency="WeaponAudioEmitter",Vector3.one*0.1,1
        emitter.Anchored,emitter.CanCollide,emitter.CanQuery,emitter.CanTouch=true,false,false,false
        emitter.Parent=folder
        local sound=Instance.new("Sound")
        sound.Name,sound.RollOffMinDistance,sound.RollOffMaxDistance,sound.RollOffMode="WeaponVoice",12,Config.maxDistance,Enum.RollOffMode.InverseTapered
        sound.PlaybackRegionsEnabled=true
        sound.Parent=emitter
        local eq=Instance.new("EqualizerSoundEffect")
        eq.Name,eq.Parent="CockpitMuffle",sound
        table.insert(self.voices,{emitter=emitter,sound=sound,eq=eq,detail=i>Config.dischargeVoices,untilAt=0,born=0})
    end
    if Config.maulerAssetId=="" then warn("[IF-WEAPON-AUDIO] HMG-20 original WAV not registered; see assets/audio/README.md (no substitute sample)") end
    if Config.laserAssetId=="" then warn("[IF-WEAPON-AUDIO] LR-12 original WAV awaits audio import; see assets/audio/README.md (no UI-beep substitute)") end
    return self
end
function Audio:Play(kind,position,owner,socket)
    local now=os.clock()
    if (workspace.CurrentCamera.CFrame.Position-position).Magnitude>Config.maxDistance then return end
    local detail=kind=="receiver" or kind=="casing" or kind=="receiverHeavy" or kind=="casingHeavy"
    if detail and now-self.lastDetail<0.04 then return end
    local asset,duration,volume,pitch
    if kind=="laser" then
        if Config.laserAssetId=="" then self.stats.missingLaser+=1;return end
        asset,duration,volume,pitch=Config.laserAssetId,Config.laserDuration,Config.laserVolume,1
    elseif kind=="mauler" then
        if Config.maulerAssetId=="" then self.stats.missingMauler+=1;return end
        asset,duration,volume,pitch=Config.maulerAssetId,Config.maulerDuration,Config.maulerVolume,1
    elseif kind=="receiverHeavy" then asset,duration,volume,pitch=Config.mechanismSound,0.12,0.16,1.05
    elseif kind=="casingHeavy" then asset,duration,volume,pitch=Config.mechanismSound,0.16,0.075,1.35
    elseif kind=="machine" then asset,duration,volume,pitch=Config.machineSound,0.13,0.27,1.7
    elseif kind=="receiver" then asset,duration,volume,pitch=Config.mechanismSound,0.055,0.075,2.2
    elseif kind=="casing" then asset,duration,volume,pitch=Config.mechanismSound,0.09,0.035,2.7
    else return end
    local chosen
    for _,v in ipairs(self.voices) do
        if v.detail==detail then
            if v.untilAt<=now then chosen=v;break end
            if not chosen or v.untilAt<chosen.untilAt then chosen=v end
        end
    end
    if not chosen then return end
    if chosen.untilAt>now then self.stats.stolen+=1 end
    local v=chosen
    v.sound:Stop()
    v.sound.SoundId=asset
    v.speed=pitch*self.random:NextNumber(1-Config.pitchVariation,1+Config.pitchVariation)
    v.sound.PlaybackSpeed=v.speed
    v.sound.PlaybackRegion=NumberRange.new(0,duration*v.speed)
    v.sound.RollOffMinDistance=if kind=="mauler" then 22 else 12
    v.emitter.Position=position
    v.owner,v.socket,v.kind,v.volume,v.born,v.duration,v.untilAt=owner,socket,kind,volume,now,duration,now+duration
    local mix=Atmosphere.CockpitMix()
    v.sound.Volume=volume*(1-0.38*mix)
    v.cockpitEq=if kind=="mauler" then HEAVY_EQ else BASE_EQ
    v.eq.LowGain,v.eq.MidGain,v.eq.HighGain=v.cockpitEq[1]*mix,v.cockpitEq[2]*mix,v.cockpitEq[3]*mix
    v.sound:Play()
    self.stats.played+=1
    if detail then self.lastDetail=now end
end
function Audio:Step()
    local now,mix=os.clock(),Atmosphere.CockpitMix()
    local active=0
    for _,v in ipairs(self.voices) do
        if v.untilAt>now then
            if not v.owner or not v.owner.Parent or v.owner:GetAttribute("Deployment")~="ACTIVE" or v.owner:GetAttribute("State")~="OPERATIONAL" or v.owner:GetAttribute("WeaponSocket")~=v.socket then
                v.untilAt=0;v.sound:Stop();continue
            end
            active+=1
            -- Apply the cockpit mix during view transitions too; retain bass and tame upper frequencies.
            local eq=v.cockpitEq or BASE_EQ
            v.eq.LowGain,v.eq.MidGain,v.eq.HighGain=eq[1]*mix,eq[2]*mix,eq[3]*mix
            local t=(now-v.born)/v.duration
            local tail=if t<0.65 then 1 else math.clamp((1-t)/0.35,0,1)
            v.sound.Volume=v.volume*(1-0.38*mix)*tail
        else
            if v.sound.IsPlaying then v.sound:Stop() end
            v.owner,v.socket=nil,nil
        end
    end
    self.stats.peak=math.max(self.stats.peak,active)
end
function Audio:Clear()
    for _,v in ipairs(self.voices) do v.untilAt=0;v.sound:Stop();v.owner,v.socket=nil,nil end
end
function Audio:Report()
    local result=table.clone(self.stats)
    result.active=0;result.limit=#self.voices;result.laserConfigured=Config.laserAssetId~=""
    result.laserAssetId=Config.laserAssetId;result.maulerConfigured=Config.maulerAssetId~="";result.maulerAssetId=Config.maulerAssetId;result.cockpitMix=Atmosphere.CockpitMix()
    result.loaded={}
    for _,v in ipairs(self.voices) do
        if v.untilAt>os.clock() then result.active+=1 end
        if v.sound.SoundId~="" then result.loaded[v.sound.SoundId]=v.sound.IsLoaded end
    end
    return result
end
return Audio
