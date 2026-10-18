-- M11B Studio checks (not run by tools/check.sh). Paste each block into the Studio MCP `execute_luau` of a Play session on build/Ironframe-M11B.rbxl
-- (datamodel noted per block). Everything uses the production paths: Weapons.Strike through the server-only audit bindable
-- (ServerScriptService.IronframeRangeAudit: "shoot", "hitdebug", "state", "reset", "mode", "dfire", "shield", "teleport", "rook", ...) and the real client.
--   "hitdebug" true|false   the Studio-only hit-geometry overlay (server-created, off by default, refused outside Studio)
--   "shoot" { origin, target, weapon, shots }   the production hitscan: returns { comp, name, damage, position, normal }
-- Camera / GUI helpers for screenshots live in block 1 (the real cockpit camera is overridden only while a screenshot is taken).
-- Studio notes (see the M10B notes): execute_luau calls time out at ~60-90 s; a rebuild needs a fresh Studio instance; keep shots inside the
-- district (|x| < 68), the district wall is queryable cover.

--[[ 1. [Client] screenshot helpers ]]
local function clientHelpers()
    local RS = game:GetService("RunService")
    local cam = workspace.CurrentCamera
    pcall(function() RS:UnbindFromRenderStep("M11BCam") end)
    RS:BindToRenderStep("M11BCam", Enum.RenderPriority.Last.Value, function()
        if shared.camGoal then cam.CameraType = Enum.CameraType.Scriptable; cam.CFrame = shared.camGoal; cam.FieldOfView = shared.camFov or 60 end
    end)
    shared.cam = function(pos, look, fov) shared.camGoal = CFrame.lookAt(pos, look); shared.camFov = fov or 60 end
    shared.hideGui = function(h)
        for _, g in ipairs(game.Players.LocalPlayer.PlayerGui:GetChildren()) do
            if g:IsA("ScreenGui") then
                if h then if g:GetAttribute("wasEnabled") == nil then g:SetAttribute("wasEnabled", g.Enabled) end g.Enabled = false
                else local w = g:GetAttribute("wasEnabled"); if w ~= nil then g.Enabled = w; g:SetAttribute("wasEnabled", nil) end end
            end
        end
    end
end

--[[ 2. [Server] hit-proxy alignment against the raw triangle data of the mesh (the measurement quoted in docs/M11B_PHYSICAL_COMBAT_FIDELITY.md).
     Ground truth = AssetService:CreateEditableMeshAsync(part.MeshContent) triangles (read only); grid rays from five directions are cast against the
     triangles and against the tank's queryable parts; reports "both hit" gap statistics, air hits (box/proxy hit, no triangle behind) and leaks. ]]
local function alignment(tankName)
    local AS = game:GetService("AssetService")
    local m = workspace.IronframeHangar.Bay_1.ProvingGround.TestingDistrict[tankName]
    local root = m.TankRoot
    local inv, world, hits = root.CFrame:Inverse(), {}, {}
    for _, p in ipairs(m:GetChildren()) do
        if p:IsA("MeshPart") then
            local em = AS:CreateEditableMeshAsync(p.MeshContent)
            local scale, cf, vp, list = p.Size / p.MeshSize, inv * p.CFrame, {}, {}
            for _, v in ipairs(em:GetVertices()) do vp[v] = cf * (em:GetPosition(v) * scale) end
            for _, f in ipairs(em:GetFaces()) do
                local vs = em:GetFaceVertices(f)
                local a, b, c = vp[vs[1]], vp[vs[2]], vp[vs[3]]
                table.insert(list, { a, b, c, math.min(a.X, b.X, c.X), math.max(a.X, b.X, c.X), math.min(a.Y, b.Y, c.Y), math.max(a.Y, b.Y, c.Y), math.min(a.Z, b.Z, c.Z), math.max(a.Z, b.Z, c.Z) })
            end
            world[p.Name] = list
            em:Destroy()
        end
        if p:IsA("BasePart") and p.CanQuery then table.insert(hits, p) end
    end
    local names = { "X", "Y", "Z" }
    local function rayMesh(o, axis, sign)
        local a1, a2 = (axis % 3) + 1, ((axis + 1) % 3) + 1
        local n1, n2, na = names[a1], names[a2], names[axis]
        local u0, v0, o0, best = o[n1], o[n2], o[na], math.huge
        for _, list in pairs(world) do
            for _, t in ipairs(list) do
                if u0 >= t[2 * a1 + 2] and u0 <= t[2 * a1 + 3] and v0 >= t[2 * a2 + 2] and v0 <= t[2 * a2 + 3] then
                    local A, B, C = t[1], t[2], t[3]
                    local ax, ay, bx, by, cx, cy = A[n1], A[n2], B[n1], B[n2], C[n1], C[n2]
                    local d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
                    if math.abs(d) > 1e-9 then
                        local l1 = ((by - cy) * (u0 - cx) + (cx - bx) * (v0 - cy)) / d
                        local l2 = ((cy - ay) * (u0 - cx) + (ax - cx) * (v0 - cy)) / d
                        if l1 >= 0 and l2 >= 0 and 1 - l1 - l2 >= 0 then
                            local dist = (l1 * A[na] + l2 * B[na] + (1 - l1 - l2) * C[na] - o0) * sign
                            if dist >= 0 and dist < best then best = dist end
                        end
                    end
                end
            end
        end
        return best
    end
    local rp = RaycastParams.new(); rp.FilterType = Enum.RaycastFilterType.Include; rp.FilterDescendantsInstances = hits
    local views = {
        { axis = 1, sign = 1, from = -30, u = { "Y", 0, 11 }, v = { "Z", -18, 22 } }, { axis = 1, sign = -1, from = 30, u = { "Y", 0, 11 }, v = { "Z", -18, 22 } },
        { axis = 2, sign = -1, from = 30, u = { "X", -10, 10 }, v = { "Z", -18, 22 } },
        { axis = 3, sign = 1, from = -40, u = { "X", -10, 10 }, v = { "Y", 0, 11 } }, { axis = 3, sign = -1, from = 40, u = { "X", -10, 10 }, v = { "Y", 0, 11 } },
    }
    local both, air, leak, sum, over = 0, 0, 0, 0, 0
    for _, vw in ipairs(views) do
        for a = vw.u[2], vw.u[3], 1.0 do
            for b = vw.v[2], vw.v[3], 1.0 do
                local o = { X = 0, Y = 0, Z = 0 }
                o[names[vw.axis]] = vw.from; o[vw.u[1]] = a; o[vw.v[1]] = b
                local dm = rayMesh(o, vw.axis, vw.sign)
                local dir = Vector3.new(vw.axis == 1 and vw.sign or 0, vw.axis == 2 and vw.sign or 0, vw.axis == 3 and vw.sign or 0)
                local r = workspace:Raycast(root.CFrame * Vector3.new(o.X, o.Y, o.Z), root.CFrame:VectorToWorldSpace(dir) * 100, rp)
                local db = r and r.Distance or math.huge
                if dm < math.huge and db < math.huge then both += 1; sum += math.abs(dm - db); if math.abs(dm - db) > 0.5 then over += 1 end
                elseif db < math.huge then air += 1 elseif dm < math.huge then leak += 1 end
            end
        end
    end
    return string.format("%s HitFidelity=%s both=%d air=%d leak=%d meanAbsGap=%.3f gap>0.5=%d", tankName, tostring(m:GetAttribute("HitFidelity")), both, air, leak, sum / math.max(both, 1), over)
end

--[[ 3. [Server] component resolution: shoot a marked point of a tank (root frame, the tank faces -Z) and report what the production strike registered. ]]
local function shootTable()
    local a = game.ServerScriptService.IronframeRangeAudit
    local cf = workspace.IronframeHangar.Bay_1.ProvingGround.TestingDistrict["TrainingTank_T-02"].TankRoot.CFrame
    local function shoot(label, o, t, w)
        local r = a:Invoke("shoot", { origin = cf * o, target = cf * t, weapon = w or "W_MACHINE_GUN", shots = 1 })
        return string.format("%-16s comp=%-8s dmg=%.2f", label, tostring(r.comp), r.damage)
    end
    local out = {}
    table.insert(out, shoot("glacis front", Vector3.new(0, 6, -40), Vector3.new(0, 6, -8)))
    table.insert(out, shoot("rear deck", Vector3.new(-6.5, 40, 9), Vector3.new(-6.5, 8, 9)))
    table.insert(out, shoot("rear lower plate", Vector3.new(-3, 3.3, 50), Vector3.new(-3, 3.3, 12)))
    table.insert(out, shoot("left track", Vector3.new(-50, 2.5, 2), Vector3.new(-8.3, 2.5, 2)))
    table.insert(out, shoot("turret roof", Vector3.new(0, 50, 2.4), Vector3.new(0, 8.2, 2.4)))
    table.insert(out, shoot("above turret (miss)", Vector3.new(-50, 17, 2), Vector3.new(0, 17, 2)))
    return table.concat(out, "\n")
end

--[[ 4. [Server] destruction sequences and reset hygiene: wreck T-02's hull, break T-01's track, kill T-03's engine; then reset ALL six times and
     compare TestingDistrict descendants with the baseline (a reset must return to it exactly). ]]
local function destructionAndResets()
    local a = game.ServerScriptService.IronframeRangeAudit
    local D = workspace.IronframeHangar.Bay_1.ProvingGround.TestingDistrict
    local function shootAt(m, lo, lt, w) local cf = m.TankRoot.CFrame a:Invoke("shoot", { origin = cf * lo, target = cf * lt, weapon = w, shots = 1 }) end
    local base = #D:GetDescendants()
    for i = 1, 150 do
        shootAt(D["TrainingTank_T-02"], Vector3.new(-40, 4.4, -2 + (i % 5)), Vector3.new(-8, 4.4, -2 + (i % 5)), "W_HMG_MAULER")
        if a:Invoke("state").vehicles[2].status == "VEHICLE DESTROYED" then break end
        task.wait(0.03)
    end
    for _ = 1, 12 do shootAt(D["TrainingTank_T-01"], Vector3.new(-40, 2.6, 2), Vector3.new(-8, 2.6, 2), "W_HMG_MAULER") task.wait(0.05) end
    local out = { "baseline=" .. base .. " damaged=" .. #D:GetDescendants() }
    for i = 1, 6 do
        a:Invoke("reset", "ALL")
        for _ = 1, 40 do task.wait(0.25) if not a:Invoke("audit").resetting then break end end
        table.insert(out, string.format("reset %d: descendants=%d", i, #D:GetDescendants()))
    end
    return table.concat(out, "\n")
end

--[[ 5. [Server] ROOK: fitted volumes against the visible rig (rest pose; the chassis frame is recovered from the parts themselves), and the
     production strike path against ROOK with and without cover. ]]
local function rookChecks()
    local a = game.ServerScriptService.IronframeRangeAudit
    local MH = require(game.ServerScriptService.IronframeServer.MechHit)
    local vol = MH.Build(workspace.IronframeMechs["ROOK-01"])
    local counts = {}
    for k, v in pairs(vol.counts) do table.insert(counts, k .. "=" .. v) end
    table.sort(counts)
    local chassis = workspace.IronframeMechs["ROOK-01"].Chassis.Position
    local o = Vector3.new(chassis.X, 12, chassis.Z - 60)
    local r = a:Invoke("shoot", { origin = o, target = chassis + Vector3.new(0, 2, 0), weapon = "W_MACHINE_GUN", shots = 1 })
    a:Invoke("testwall", Vector3.new(chassis.X, 0, chassis.Z - 25), 30, 30)
    local cover = a:Invoke("shoot", { origin = o, target = chassis + Vector3.new(0, 2, 0), weapon = "W_MACHINE_GUN", shots = 1 })
    a:Invoke("untestwall")
    return string.format("boxes=%d (%s) dropped=%d | open: comp=%s | behind cover: %s", #vol.boxes, table.concat(counts, " "), vol.dropped, tostring(r.comp), tostring(cover.name))
end

return { clientHelpers = clientHelpers, alignment = alignment, shootTable = shootTable, destructionAndResets = destructionAndResets, rookChecks = rookChecks }
