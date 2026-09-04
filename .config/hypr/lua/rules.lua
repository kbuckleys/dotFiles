-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

hl.window_rule({ match = { class = "org.quickshell", title = "terminus" },         float = true, size = { 1000, 1000 }})
hl.window_rule({ match = { class = "org.quickshell", title = "terminus-picker" },  float = true, size = { 1000, 450 }})
hl.window_rule({ match = { class = "steam", title = "Steam Settings" },         float = true })
hl.window_rule({ match = { class = "footclient", title = "runner" },            float = true, size = { 1000, 1000 }})
hl.window_rule({ match = { class = "footclient",title = "sysmon" },             float = true, size = { 1000, 1100 }})
hl.window_rule({ match = { class = "footclient",title = "ZENU" },               float = true, size = { 1000, 1100 }})
hl.window_rule({ match = { class = "swayimg" },                                 float = true })
hl.window_rule({ match = { class = "mpv" },                                     float = true })

-- BORDERS
hl.window_rule({ match = { fullscreen = true },  border_color = "#fab38799", border_size = 2, rounding = 5 })
hl.window_rule({ match = { float = true },       border_color = "#b6e0a499", border_size = 2, rounding = 5 })

-- DISABLE SHADOWS FOR TILES
hl.window_rule({ match = { float = false }, no_shadow = true })
hl.window_rule({ match = { class = "^$" }, no_shadow = false })

-- GLOBAL BLUR
hl.layer_rule({ match = { namespace = ".*" }, blur = true, ignore_alpha = 0.5 })

-- SPECIAL WORKSPACE
hl.workspace_rule({ workspace = "special:special", gaps_out = 30 })

-- FIREFOX
hl.window_rule({ match = { class = "firefox", title = "Firefox - Choose a profile" },  float = true })
hl.window_rule({ match = { class = "firefox", title = "About Mozilla Firefox" },       float = true })
hl.window_rule({ match = { class = "firefox", title = "Choose Application" },          float = true })
hl.window_rule({ match = { class = "firefox", title = "Library" },                     float = true, size = { 1000, 1000 }})
