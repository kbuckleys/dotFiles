-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

-- DEFAULTS
local term = "footclient"
local web = "firefox"

-- MISC
hl.bind("SUPER + SHIFT + ESCAPE",  hl.dsp.exec_cmd("hyprshutdown"), { locked = true })
hl.bind("SUPER + SHIFT + S",       hl.dsp.exec_cmd(term .. " -T sysmon btop"))
hl.bind("SUPER + RETURN",          hl.dsp.exec_cmd(term))
hl.bind("SUPER + P",               hl.dsp.exec_cmd(term .. " -T ZENU ~/.config/scripts/ZENU.lua"))
hl.bind("SUPER + SHIFT + P",       hl.dsp.exec_cmd(term .. " -T ZENU ~/.config/scripts/ZENU.lua update"))
hl.bind("SUPER + CONTROL + P",     hl.dsp.exec_cmd("hyprpicker -a"))
hl.bind("SUPER + B",               hl.dsp.exec_cmd(web))

-- QS
hl.bind("SUPER + ESCAPE",     hl.dsp.exec_cmd("qs ipc call Erebus toggle"))
hl.bind("SUPER + SPACE",      hl.dsp.exec_cmd("qs ipc call Cynosure toggle"))
-- spawn, not toggle: it shows the hidden window if there is one and opens a
-- new one otherwise, so the key never closes a file manager you were using
hl.bind("SUPER + E",          hl.dsp.exec_cmd("qs ipc call Terminus spawn ''"))
hl.bind("SUPER + C",          hl.dsp.exec_cmd("qs ipc call Folio toggle"))
hl.bind("SUPER + SHIFT + C",  hl.dsp.exec_cmd("qs ipc call Adder toggle"))
hl.bind("SUPER + S",          hl.dsp.exec_cmd("qs ipc call Scout toggle"))
hl.bind("SUPER + J",          hl.dsp.exec_cmd("qs ipc call Ideo emoji"))
hl.bind("SUPER + SHIFT + J",  hl.dsp.exec_cmd("qs ipc call Ideo nerd"))
hl.bind("SUPER + V",          hl.dsp.exec_cmd("qs ipc call Vault toggle"))
hl.bind("SUPER + K",          hl.dsp.exec_cmd("qs ipc call Zeus toggle"))
hl.bind("SUPER + D",          hl.dsp.exec_cmd("qs ipc call Lexi toggle"))
hl.bind("SUPER + SHIFT + D",  hl.dsp.exec_cmd("qs ipc call Lexi translate"))
hl.bind("SUPER + SHIFT + B",  hl.dsp.exec_cmd("qs ipc call Picasso toggle"))

-- spoot
hl.bind("SUPER + M",          hl.dsp.exec_cmd("~/Projects/spoot/bin/spoot"))
hl.bind("SUPER + SHIFT + M",  hl.dsp.exec_cmd("~/Projects/spoot/bin/spoot --listen"))

-- WORKSPACES
hl.bind("SUPER + GRAVE",  hl.dsp.workspace.toggle_special("special"))
hl.bind("SUPER + 1",      hl.dsp.focus({ workspace = 1 }))
hl.bind("SUPER + 2",      hl.dsp.focus({ workspace = 2 }))
hl.bind("SUPER + 3",      hl.dsp.focus({ workspace = 3 }))
hl.bind("SUPER + 4",      hl.dsp.focus({ workspace = 4 }))
hl.bind("SUPER + 5",      hl.dsp.focus({ workspace = 5 }))

local function move_and_center(ws)
	hl.dispatch(hl.dsp.window.move({ workspace = ws }))
	local win = hl.get_active_window()
	if win and win.floating then
		hl.dispatch(hl.dsp.window.center())
	end
end

hl.bind("SUPER + SHIFT + GRAVE",  function() move_and_center("special:special") end)
hl.bind("SUPER + SHIFT + 1",      function() move_and_center(1) end)
hl.bind("SUPER + SHIFT + 2",      function() move_and_center(2) end)
hl.bind("SUPER + SHIFT + 3",      function() move_and_center(3) end)
hl.bind("SUPER + SHIFT + 4",      function() move_and_center(4) end)
hl.bind("SUPER + SHIFT + 5",      function() move_and_center(5) end)

-- WINDOW MANIPULATION
hl.bind("SUPER + SHIFT + F",  hl.dsp.window.fullscreen())
hl.bind("SUPER + SHIFT + W",  hl.dsp.window.center())
hl.bind("SUPER + SHIFT + Q",  hl.dsp.window.kill())
hl.bind("SUPER + X",          hl.dsp.layout("togglesplit"))
hl.bind("SUPER + W",          hl.dsp.window.pseudo())
hl.bind("SUPER + Q",          hl.dsp.window.close())
hl.bind("SUPER + Z",          hl.dsp.window.fullscreen({ mode = "maximized" }))

hl.bind("SUPER + F", function()
    hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
    hl.dispatch(hl.dsp.window.center())
end)

-- Mouse
hl.bind("SUPER + mouse:272",  hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273",  hl.dsp.window.resize(), { mouse = true })

-- Focus
hl.bind("SUPER + RIGHT",  hl.dsp.focus({ direction = "r" }))
hl.bind("SUPER + DOWN",   hl.dsp.focus({ direction = "d" }))
hl.bind("SUPER + LEFT",   hl.dsp.focus({ direction = "l" }))
hl.bind("SUPER + UP",     hl.dsp.focus({ direction = "u" }))

-- Resize
hl.bind("SUPER + CONTROL + RIGHT",  hl.dsp.window.resize({ x = 100, y = 0, relative = true }), { repeating = true })
hl.bind("SUPER + CONTROL + DOWN",   hl.dsp.window.resize({ x = 0, y = 100, relative = true }), { repeating = true })
hl.bind("SUPER + CONTROL + LEFT",   hl.dsp.window.resize({ x = -100, y = 0, relative = true }), { repeating = true })
hl.bind("SUPER + CONTROL + UP",     hl.dsp.window.resize({ x = 0, y = -100, relative = true }), { repeating = true })

-- Swap Window
hl.bind("SUPER + ALT + RIGHT",  hl.dsp.window.swap({ direction = "r" }), { description = "Swap window to the right" })
hl.bind("SUPER + ALT + DOWN",   hl.dsp.window.swap({ direction = "d" }), { description = "Swap window down" })
hl.bind("SUPER + ALT + LEFT",   hl.dsp.window.swap({ direction = "l" }), { description = "Swap window to the left" })
hl.bind("SUPER + ALT + UP",     hl.dsp.window.swap({ direction = "u" }), { description = "Swap window up" })

-- Window Switching
hl.bind("SUPER + TAB", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
end)

hl.bind("SUPER + SHIFT + TAB", function()
    local ws = hl.get_active_workspace()
    if not ws then return end

    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "bottom" }))

    local top
    for _, win in ipairs(hl.get_windows({ workspace = ws, mapped = true })) do
        if not win.hidden then top = win end
    end
    if top then
        hl.dispatch(hl.dsp.focus({ window = top }))
    end
end)

-- GROUPING
hl.bind("SUPER + SHIFT + G",  hl.dsp.group.toggle())
hl.bind("SUPER + G",          hl.dsp.group.lock_active({ action = "toggle" }))

hl.bind("ALT + SHIFT + TAB",  hl.dsp.group.prev(), { repeating = true })
hl.bind("ALT + TAB",          hl.dsp.group.next(), { repeating = true })

hl.bind("SUPER + SHIFT + ALT + RIGHT",  hl.dsp.window.move({ into_group = "r" }))
hl.bind("SUPER + SHIFT + ALT + DOWN",   hl.dsp.window.move({ into_group = "d" }))
hl.bind("SUPER + SHIFT + ALT + LEFT",   hl.dsp.window.move({ into_group = "l" }))
hl.bind("SUPER + SHIFT + ALT + UP",     hl.dsp.window.move({ into_group = "u" }))

hl.bind("SUPER + SHIFT + CONTROL + RIGHT",  hl.dsp.window.move({ out_of_group = true }))
hl.bind("SUPER + SHIFT + CONTROL + DOWN",   hl.dsp.window.move({ out_of_group = true }))
hl.bind("SUPER + SHIFT + CONTROL + LEFT",   hl.dsp.window.move({ out_of_group = true }))
hl.bind("SUPER + SHIFT + CONTROL + UP",     hl.dsp.window.move({ out_of_group = true }))

-- AUDIO
hl.bind("SUPER + EQUAL",  hl.dsp.exec_cmd("pamixer -i 1"), { repeating = true })
hl.bind("SUPER + MINUS",  hl.dsp.exec_cmd("pamixer -d 1"), { repeating = true })
hl.bind("SUPER + 9",      hl.dsp.exec_cmd(term .. " -T Wiremix wiremix"))
hl.bind("SUPER + 0",      hl.dsp.exec_cmd("pamixer -t"))

hl.bind("SUPER + SHIFT + EQUAL",  hl.dsp.exec_cmd("playerctl next"))
hl.bind("SUPER + SHIFT + MINUS",  hl.dsp.exec_cmd("playerctl play-pause"))
hl.bind("SUPER + SHIFT + 0",      hl.dsp.exec_cmd("playerctl previous"))
