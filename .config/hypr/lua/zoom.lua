-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/
--
-- KDE Plasma's screen zoom, replicated.
-- Constants below are KWin's own defaults, from kwin/src/plugins/zoom/zoom.kcfg.

local ZOOM_STEP = 1.2    -- ZoomFactor, applied multiplicatively
local MIN_ZOOM  = 1.0    -- std::clamp(value, 1.0, 100.0)
local MAX_ZOOM  = 100.0

-- Zoom drags the cursor between the hardware plane and the framebuffer: the
-- zoomLock in Hyprland's Renderer.cpp is a function-local static shared by
-- every monitor, so the unzoomed one runs unlockSoftwareAll() and clears it
-- every frame, undoing the lock the zoomed one just took. Each handover back to
-- the plane can strand a stale cursor on it -- unmagnified, surviving until
-- something else repaints, and invisible to screenshots because screencopy
-- never sees the cursor plane. Only DP-1 shows it; HDMI-A-1 is rotated, and
-- rotated outputs already fall back to software cursors.
--
-- Toggling this per zoom just moved the handover to zoom-out, so the cursor
-- stays composited full time and there is no handover left to strand anything.
local HW_CURSORS_OFF = 1

-- Damage is tracked against the unzoomed cursor rect, so a magnified pointer
-- outruns it. A whole-monitor repaint costs nothing we care about while zoomed.
local DAMAGE_MONITOR = 1  -- whole monitor damaged every frame
local DAMAGE_FULL    = 2  -- Hyprland's fine-grained default

-- cursor:zoom_factor is animated, so the render is still ramping down after we
-- write 1.0. Hold the full-damage frames until it lands.
local SETTLE_MS = 300

local function config_dir()
	local src = debug.getinfo(1, "S").source
	if src:sub(1, 1) == "@" then
		local dir = src:sub(2):match("^(.*)/lua/[^/]+$")
		if dir then return dir end
	end
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then return xdg .. "/hypr" end
	return (os.getenv("HOME") or "") .. "/.config/hypr"
end

local SHADER = config_dir() .. "/shaders/zoom.frag"

hl.config({
	cursor = {
		zoom_factor = MIN_ZOOM,        -- InitialZoom; 1.0 is Hyprland's "off", not 0
		zoom_rigid = false,            -- == MouseTrackingProportional, KWin's default
		zoom_detached_camera = false,
		zoom_disable_aa = false,       -- the shader does the filtering, keep GL_LINEAR
		no_hardware_cursors = HW_CURSORS_OFF,
	},
	decoration = {
		screen_shader = "",
	},
	debug = {
		damage_tracking = DAMAGE_FULL,
	},
})

-- KWin keeps m_targetZoom apart from the animating m_zoom; so do we, since the
-- compositor animates cursor:zoom_factor out from under us.
local target = hl.get_config("cursor.zoom_factor") or MIN_ZOOM
if target < MIN_ZOOM then target = MIN_ZOOM end

local zoomed = false
local settle = nil

local function cancelSettle()
	if not settle then return end
	pcall(function() settle:set_enabled(false) end)
	settle = nil
end

-- The shader picks the pixel grid or the sharp upscaler off its own
-- derivatives, so all this has to decide is whether the zoom is running.
local function applyZoomState(zoom)
	if zoom > MIN_ZOOM then
		cancelSettle()
		if zoomed then return end
		zoomed = true
		hl.config({
			decoration = { screen_shader = SHADER },
			debug = { damage_tracking = DAMAGE_MONITOR },
		})
	elseif zoomed and not settle then
		settle = hl.timer(function()
			settle = nil
			zoomed = false
			hl.config({
				decoration = { screen_shader = "" },
				debug = { damage_tracking = DAMAGE_FULL },
			})
		end, { timeout = SETTLE_MS, type = "oneshot" })
	end
end

local function setTargetZoom(value)
	value = math.min(MAX_ZOOM, math.max(MIN_ZOOM, value))
	if value == target then return end
	target = value
	hl.config({ cursor = { zoom_factor = value } })
	applyZoomState(value)
end

local function zoomIn()    setTargetZoom(target * ZOOM_STEP) end
local function zoomOut()   setTargetZoom(target / ZOOM_STEP) end
local function zoomReset() setTargetZoom(MIN_ZOOM) end

hl.bind("SUPER + CTRL + EQUAL",  zoomIn,  { repeating = true })
hl.bind("SUPER + CTRL + PLUS",   zoomIn,  { repeating = true })
hl.bind("SUPER + CTRL + MINUS",  zoomOut, { repeating = true })
hl.bind("SUPER + CTRL + 0",      zoomReset)

-- KWin's PointerAxisGestureModifiers defaults to Meta+Control.
hl.bind("SUPER + CTRL + mouse_up",    zoomIn)
hl.bind("SUPER + CTRL + mouse_down",  zoomOut)
hl.bind("SUPER + CTRL + mouse:274",   zoomReset)
