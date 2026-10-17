# Dev helper: rebuild the Rojo place and reopen it in a NEW Studio instance, closing only the instance this
# script previously opened (tracked in build/studio.pid). Never touches other Studio windows.
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (Test-Path build\studio.pid) {
    $old = [int](Get-Content build\studio.pid)
    Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force build | Out-Null
$rojo = "C:\tools\rojo\rojo.exe"
& $rojo build default.project.json -o build\Ironframe.rbxl
# Resolve the Studio executable robustly: another running instance, or the newest installed version.
$exe = (Get-Process RobloxStudioBeta -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1).Path
if (-not $exe) {
    $exe = (Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions" -Recurse -Filter RobloxStudioBeta.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
$known = @((Get-Process RobloxStudioBeta -ErrorAction SilentlyContinue).Id)
Start-Process $exe -ArgumentList "`"$root\build\Ironframe.rbxl`""
Start-Sleep 20
$new = (Get-Process RobloxStudioBeta | Where-Object { $known -notcontains $_.Id }).Id
if ($new) { Set-Content build\studio.pid $new }
"opened studio pid: $new"
