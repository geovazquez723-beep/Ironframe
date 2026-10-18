-- Cockpit contract (M11C). Pure data, no Roblox types, so the compiler and the offline tests can load it.
--
-- Three separate concepts compose into one cockpit:
--   LAYOUT     the physical frame of ONE chassis: eye point, field of view, head-look limits, which displays exist and where the optional
--              equipment mounts are. A future chassis adds its own layout (different geometry, eye point, console arrangement) here.
--   PACKAGE    a `cockpit` entry of the ComponentRegistry: equipment fitted into a layout (extra display housings, palette, bays).
--   AVIONICS   `avionics` registry entries: functional modules. They never depend on the layout; the sensor service computes contacts,
--              locks and thermal signatures once and any layout presents them on whatever displays it has.
-- Layout and package are linked by NAME only (`package.layouts` lists the layouts it fits; `chassis.cockpit.layout` names the frame).

local Layouts = {}

-- Colour palettes, 0..255 RGB. `primary` carries data and healthy state, `secondary` carries labels and cautions, `warn` / `crit` are the
-- only caution / emergency colours in either package, `light` tints the practical cabin lamps.
Layouts.palettes = {
    INDUSTRIAL = {
        name = "INDUSTRIAL", primary = { 108, 226, 128 }, primaryDim = { 26, 92, 44 }, secondary = { 255, 176, 52 }, secondaryDim = { 110, 70, 14 },
        text = { 220, 236, 224 }, dimText = { 112, 148, 120 }, panel = { 9, 15, 11 }, warn = { 255, 176, 52 }, crit = { 255, 62, 52 },
        light = { dash = { 150, 230, 150 }, console = { 255, 176, 52 }, fill = { 190, 205, 170 }, strip = { 108, 226, 128 }, strip2 = { 255, 176, 52 } },
        lightScale = 0.8, -- subdued work lighting
    },
    RECON = {
        name = "RECON", primary = { 128, 206, 255 }, primaryDim = { 24, 70, 104 }, secondary = { 232, 244, 255 }, secondaryDim = { 70, 90, 110 },
        text = { 226, 240, 252 }, dimText = { 112, 150, 176 }, panel = { 7, 12, 19 }, warn = { 255, 190, 74 }, crit = { 255, 62, 52 },
        light = { dash = { 170, 214, 255 }, console = { 200, 228, 255 }, fill = { 190, 214, 240 }, strip = { 128, 206, 255 }, strip2 = { 232, 244, 255 } },
        lightScale = 1.0, -- cool tactical lighting
    },
}

Layouts.frames = {
    BASTION_FRAME = {
        id = "BASTION_FRAME", name = "IF-42 Bastion cockpit frame",
        eye = { 0, 4.3, -0.55 }, -- torso joint frame (mech faces -Z)
        fov = 74, maxHFov = 106,
        -- The displays this frame has and their drawing surfaces (the HUD builds one SurfaceGui per entry; size in pixels).
        displays = {
            MFD_L = { title = "STRUCTURE", canvas = { 640, 490 } }, MFD_C = { title = "REACTOR", canvas = { 480, 490 } },
            MFD_R = { title = "ARMAMENT", canvas = { 640, 490 } }, ConsoleL = { title = "TARGETING", canvas = { 460, 482 } },
            ConsoleR = { title = "SENSORS", canvas = { 460, 482 } }, Overhead = { title = "SYSTEMS", canvas = { 1000, 250 } },
        },
        -- Equipment mounts: where a package may hang additional hardware. Torso-frame centre and the point the housing faces. All lie outside the
        -- central forward cone (+-37 deg wide, +21 / -15 deg tall) so no package ever blocks the canopy view.
        mounts = {
            auxLeft = { pos = { -2.0, 4.55, -2.5 }, aim = { -0.7, 4.0, -0.55 } },
            auxRight = { pos = { 2.0, 4.55, -2.5 }, aim = { 0.7, 4.0, -0.55 } },
            hood = { pos = { 0, 5.35, -1.6 }, aim = { 0, 4.6, -0.55 } },
        },
        annunciators = { "CAP", "RCTR", "SENS", "THRM", "WPN", "CORE" },
    },
}

function Layouts.Frame(id: string): any?
    return Layouts.frames[id]
end

function Layouts.Palette(id: string?): any
    return Layouts.palettes[id or "INDUSTRIAL"] or Layouts.palettes.INDUSTRIAL
end

return Layouts
