-- ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
-- ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
-- └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
-- https://github.com/kbuckleys/

local MAX_ZOOM = 3.0
local MIN_ZOOM = 1.0
local ZOOM_TOGGLE = 2.0
local ZOOM_STEP = 0.25
local ZOOM_DURATION = 160
local FRAME_MS = 8
local ZOOM_SCROLL_DURATION = 90
local SCROLL_FRAME_MS = 5

local zoom_timer = nil

local function setZoomFactor(v)
    hl.config({ cursor = { zoom_factor = v } })
end

local function animateZoom(from, to, onDone, duration, frameMs)
    if zoom_timer then
        pcall(function() zoom_timer:set_enabled(false) end)
        zoom_timer = nil
    end
    if from == to then
        setZoomFactor(to)
        if onDone then onDone() end
        return
    end
    duration = duration or ZOOM_DURATION
    frameMs = frameMs or FRAME_MS
    local steps = math.max(1, math.ceil(duration / frameMs))
    local frame = 0
    local delta = to - from
    zoom_timer = hl.timer(function()
        frame = frame + 1
        local t = frame / steps
        if t > 1 then t = 1 end
        local eased = 1 - (1 - t) ^ 3
        local cur = from + delta * eased
        if frame >= steps then
            if zoom_timer then pcall(function() zoom_timer:set_enabled(false) end) zoom_timer = nil end
            setZoomFactor(to)
            if onDone then onDone() end
            return
        end
        setZoomFactor(cur)
    end, { timeout = frameMs, type = "repeat" })
end

local function zoom(offset, isScroll)
    local cur = hl.get_config("cursor.zoom_factor")
    local target
    if offset ~= nil then
        if cur == 0 then cur = 1.0 end
        target = cur + offset
    else
        if cur ~= 0 then
            target = 0
        else
            target = ZOOM_TOGGLE
        end
    end

    if target ~= 0 and target < MIN_ZOOM then target = 0 end
    if target ~= 0 then target = math.min(MAX_ZOOM, math.max(MIN_ZOOM, target)) end

    pcall(function() hl.config({ cursor = { zoom_rigid = false, zoom_detached_camera = false, zoom_disable_aa = false } }) end)

    local animFrom = hl.get_config("cursor.zoom_factor")
    if animFrom == 0 then animFrom = 1.0 end

    if target == 0 then
        if animFrom <= 1.01 then
            if zoom_timer then pcall(function() zoom_timer:set_enabled(false) end) zoom_timer = nil end
            setZoomFactor(0)
            return
        end
        local d = isScroll and ZOOM_SCROLL_DURATION or ZOOM_DURATION
        local f = isScroll and SCROLL_FRAME_MS or FRAME_MS
        animateZoom(animFrom, 1.0, function() setZoomFactor(0) end, d, f)
    else
        local d = isScroll and ZOOM_SCROLL_DURATION or ZOOM_DURATION
        local f = isScroll and SCROLL_FRAME_MS or FRAME_MS
        animateZoom(animFrom, target, nil, d, f)
    end
end

hl.bind("SUPER + CTRL + 0", zoom)
hl.bind("SUPER + CTRL + EQUAL", function()
    zoom(ZOOM_STEP)
end, { repeating = true })
hl.bind("SUPER + CTRL + MINUS", function()
    zoom(-ZOOM_STEP)
end, { repeating = true })

hl.bind("SUPER + CTRL + mouse:274", zoom)
hl.bind("SUPER + CTRL + mouse_up", function()
    zoom(ZOOM_STEP, true)
end)
hl.bind("SUPER + CTRL + mouse_down", function()
    zoom(-ZOOM_STEP, true)
end)
