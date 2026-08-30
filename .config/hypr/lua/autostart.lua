-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

hl.on("hyprland.start", function()
    -- first, not last: it is the only one of these anybody can see, and
    -- everything below it is background plumbing competing for a cold
    -- page cache. Every ms spent here is black screen before the arrival.
    hl.exec_cmd("qs")
    hl.exec_cmd("kitty -1 --start-as=hidden --listen-on unix:@kitty-socket")
	hl.exec_cmd("wl-paste --type image --watch cliphist store")
	hl.exec_cmd("wl-paste --type text --watch cliphist store")
	hl.exec_cmd("dbus-update-activation-environment --all")
	hl.exec_cmd("systemctl --user start hyprpolkitagent")
	hl.exec_cmd("wl-clip-persist --clipboard regular")
end)
