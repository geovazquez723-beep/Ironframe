-- CLIENT after importing assets/audio/lr12_discharge.wav, setting WeaponPresentation.audio.laserAssetId and restarting Play.
local config=require(game.ReplicatedStorage.IronframeShared.WeaponPresentation).audio
assert(config.laserAssetId~="","Original LR-12 WAV has not been uploaded/registered. See assets/audio/README.md")
local sound=Instance.new("Sound")
sound.Name,sound.SoundId,sound.Volume="LR12ImportVerification",config.laserAssetId,0.45
sound.Parent=game:GetService("SoundService")
local ok,result=pcall(function()
    game:GetService("ContentProvider"):PreloadAsync({sound})
    assert(sound.IsLoaded,"Audio inaccessible/moderation pending; inspect Studio Output and experience permissions")
    assert(sound.TimeLength>=0.2 and sound.TimeLength<=0.4,"Wrong asset or unexpected transcoded duration")
    sound:Play()
    local peak=0
    for i=1,30 do task.wait(0.02);peak=math.max(peak,sound.PlaybackLoudness) end
    return {assetId=sound.SoundId,loaded=sound.IsLoaded,duration=sound.TimeLength,peakDecodedLoudness=peak,
        note="Loading/decoded signal is not a listening-quality verdict. Listen, then test actual shots in cockpit and exterior in the intended experience."}
end)
sound:Destroy()
assert(ok,result)
return result
