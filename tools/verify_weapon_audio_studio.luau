-- CLIENT after registering weapon audio (tools/roblox_audio_upload.py) and restarting Play. Verifies every registered
-- original weapon WAV loads for this account/experience, has the expected transcoded duration and decodes a signal.
local config=require(game.ReplicatedStorage.IronframeShared.WeaponPresentation).audio
local checks={
    {name="LR-12",id=config.laserAssetId,min=0.2,max=0.4},
    {name="HMG-20",id=config.maulerAssetId,min=0.45,max=0.8},
}
local report={}
for _,check in ipairs(checks) do
    assert(check.id~="",check.name.." original WAV has not been uploaded/registered. See assets/audio/README.md")
    local sound=Instance.new("Sound")
    sound.Name,sound.SoundId,sound.Volume="WeaponImportVerification",check.id,0.45
    sound.Parent=game:GetService("SoundService")
    local ok,result=pcall(function()
        game:GetService("ContentProvider"):PreloadAsync({sound})
        assert(sound.IsLoaded,"Audio inaccessible/moderation pending; inspect Studio Output and experience permissions")
        assert(sound.TimeLength>=check.min and sound.TimeLength<=check.max,"Wrong asset or unexpected transcoded duration "..sound.TimeLength)
        sound:Play()
        local peak=0
        for i=1,40 do task.wait(0.02);peak=math.max(peak,sound.PlaybackLoudness) end
        return {assetId=sound.SoundId,loaded=sound.IsLoaded,duration=sound.TimeLength,peakDecodedLoudness=peak}
    end)
    sound:Destroy()
    assert(ok,check.name..": "..tostring(result))
    report[check.name]=result
end
report.note="Loading/decoded signal is not a listening-quality verdict. Listen to real shots in cockpit and exterior views."
return report
