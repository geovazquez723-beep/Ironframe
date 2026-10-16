#!/usr/bin/env bash
# Standalone Luau syntax/lint check. Roblox globals (CFrame, Enum, script, ...) are unknown to the
# stock analyzer, so those diagnostics are filtered; everything else is reported.
LUAU_BIN="${LUAU_BIN:-$LOCALAPPDATA/Programs/Luau/bin}"
cd "$(dirname "$0")/.." || exit 1
files=$(find src -name '*.luau')
for f in $files; do "$LUAU_BIN/luau-compile.exe" --text "$f" >/dev/null 2>/tmp/if_compile.txt || { echo "SYNTAX FAIL $f"; cat /tmp/if_compile.txt; rc=1; }; done
"$LUAU_BIN/luau-analyze.exe" $files 2>&1 | grep -vE "Unknown (global|type) '(CFrame|Vector3|Vector2|Color3|Enum|Instance|game|script|workspace|task|Model|BasePart|Part|UDim2|UDim|TweenInfo|Players|RemoteEvent|RemoteFunction|Folder|Random|Ray|Region3|os|Player|Humanoid|Decal|Accessory|Camera|Attachment|Vector3int16|CFrameValue|RaycastParams|Instance)'" 
exit ${rc:-0}
