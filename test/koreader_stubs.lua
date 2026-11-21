-- Minimal stand-ins for the KOReader modules used by the Break Timer plugin.
--
-- Time is fully simulated:
--   * `monotonic` backs time.now() and UIManager:getElapsedTimeSinceBoot()
--   * `wall` backs os.time() and is in UTC (os.date("%z") always returns +0000)
-- Scheduled callbacks only run when the test calls env.advance().

local Stubs = {}

local MAX_CALLBACKS_PER_ADVANCE = 10000

function Stubs.new(plugin_dir)
    local env = {
        monotonic = 0,
        wall = 12 * 3600, -- 12:00 UTC on 1970-01-01
        settings = {},
        scheduled = {},
        shown = {},
        last_datetime_widget = nil,
    }

    -- ui/time: fts values are microseconds
    local time = {
        now = function()
            return env.monotonic * 1e6
        end,
        s = function(seconds)
            return seconds * 1e6
        end,
        to_s = function(fts)
            return fts / 1e6
        end,
    }

    local UIManager = {}
    function UIManager:scheduleIn(seconds, fn, arg)
        assert(type(seconds) == "number" and seconds == seconds, "scheduleIn: invalid delay " .. tostring(seconds))
        assert(seconds < 1e9, "scheduleIn: absurdly long delay " .. tostring(seconds))
        assert(fn ~= nil, "scheduleIn: nil callback")
        table.insert(env.scheduled, { at = env.monotonic + math.max(seconds, 0), fn = fn, arg = arg })
    end
    function UIManager:unschedule(fn)
        for i = #env.scheduled, 1, -1 do
            if env.scheduled[i].fn == fn then
                table.remove(env.scheduled, i)
            end
        end
    end
    function UIManager:show(widget)
        env.shown[widget] = true
    end
    function UIManager:close(widget)
        if widget then
            env.shown[widget] = nil
        end
    end
    function UIManager:broadcastEvent() end
    function UIManager:getElapsedTimeSinceBoot()
        return time.now()
    end

    local function widgetClass(on_new)
        local Class = {}
        function Class:extend(o)
            o = o or {}
            setmetatable(o, { __index = self })
            return o
        end
        function Class:new(o)
            o = o or {}
            setmetatable(o, { __index = self })
            if on_new then
                on_new(o)
            end
            return o
        end
        function Class:addWidget() end
        return Class
    end

    local modules = {
        ["ui/widget/checkbutton"] = widgetClass(),
        ["ui/widget/datetimewidget"] = widgetClass(function(w)
            env.last_datetime_widget = w
        end),
        ["ui/widget/infomessage"] = widgetClass(function(w)
            w.is_info_message = true
        end),
        ["ui/widget/container/widgetcontainer"] = widgetClass(),
        ["ui/event"] = {
            new = function(_, name)
                return { name = name }
            end,
        },
        ["ui/uimanager"] = UIManager,
        ["ui/time"] = time,
        ["dbg"] = { guard = function() end },
        ["logger"] = { dbg = function() end, info = function() end, warn = function() end },
        ["datetime"] = {
            secondsToClock = function()
                return ""
            end,
            secondsToClockDuration = function()
                return ""
            end,
        },
        ["gettext"] = function(s)
            return s
        end,
        ["ffi/util"] = {
            template = function(s)
                return s
            end,
        },
    }

    -- Install the stubs. Returns a function restoring the previous global state.
    function env.install()
        local saved_preload, saved_loaded = {}, {}
        for name, mod in pairs(modules) do
            saved_preload[name] = package.preload[name]
            saved_loaded[name] = package.loaded[name]
            package.loaded[name] = nil
            package.preload[name] = function()
                return mod
            end
        end
        local saved_time, saved_date, saved_settings = os.time, os.date, G_reader_settings
        os.time = function(t)
            if t ~= nil then
                return saved_time(t)
            end
            return math.floor(env.wall)
        end
        os.date = function(fmt, ...)
            if fmt == "%z" then
                return "+0000"
            end
            return saved_date(fmt, ...)
        end
        G_reader_settings = {
            readSetting = function(_, key)
                return env.settings[key]
            end,
            saveSetting = function(_, key, value)
                env.settings[key] = value
            end,
        }
        return function()
            for name in pairs(modules) do
                package.preload[name] = saved_preload[name]
                package.loaded[name] = saved_loaded[name]
            end
            os.time, os.date, G_reader_settings = saved_time, saved_date, saved_settings
        end
    end

    -- Load a fresh copy of the plugin class.
    function env.loadPlugin()
        return dofile(plugin_dir .. "/main.lua")
    end

    -- Create and initialize a plugin instance, capturing its menu items.
    function env.newTimer()
        local BreakTimer = env.loadPlugin()
        local timer = BreakTimer:new {
            ui = {
                menu = { registerToMainMenu = function() end },
                view = {
                    footer = {
                        settings = { item_prefix = "icons" },
                        addAdditionalFooterContent = function() end,
                        removeAdditionalFooterContent = function() end,
                    },
                },
            },
        }
        timer:init()
        local menu_items = {}
        timer:addToMainMenu(menu_items)
        env.menu = menu_items.break_timer
        return timer
    end

    -- Simulate picking a time in one of the plugin's menu dialogs, by menu text.
    function env.setMenuTime(text, hour, min)
        local item
        for _, entry in ipairs(env.menu.sub_item_table) do
            if entry.text == text then
                item = entry
            end
        end
        assert(item, "no menu item named " .. text)
        env.last_datetime_widget = nil
        item.callback(nil)
        assert(env.last_datetime_widget, "menu item did not open a DateTimeWidget")
        env.last_datetime_widget.callback({ hour = hour, min = min })
    end

    -- Advance both clocks, running due callbacks in order.
    function env.advance(seconds)
        local target = env.monotonic + seconds
        local calls = 0
        while true do
            table.sort(env.scheduled, function(a, b)
                return a.at < b.at
            end)
            local entry = env.scheduled[1]
            if not entry or entry.at > target then
                break
            end
            table.remove(env.scheduled, 1)
            env.wall = env.wall + (entry.at - env.monotonic)
            env.monotonic = entry.at
            calls = calls + 1
            if calls > MAX_CALLBACKS_PER_ADVANCE then
                error(
                    string.format(
                        "busy loop: more than %d callbacks without time advancing past %.0f",
                        MAX_CALLBACKS_PER_ADVANCE,
                        env.monotonic
                    ),
                    2
                )
            end
            if entry.arg ~= nil then
                entry.fn(entry.arg)
            else
                entry.fn()
            end
        end
        env.wall = env.wall + (target - env.monotonic)
        env.monotonic = target
    end

    -- Simulate the device sleeping for the given number of seconds.
    function env.sleep(timer, seconds)
        timer:onSuspend()
        -- Callbacks don't fire while suspended. Anything still scheduled that
        -- came due while asleep fires on the next env.advance(), as in KOReader.
        env.monotonic = env.monotonic + seconds
        env.wall = env.wall + seconds
        timer:onResume()
    end

    -- Set the wall clock to the given time of day (UTC).
    function env.setTimeOfDay(hour, min, sec)
        env.wall = hour * 3600 + (min or 0) * 60 + (sec or 0)
    end

    function env.infoMessagesShown()
        local count = 0
        for widget in pairs(env.shown) do
            if widget.is_info_message then
                count = count + 1
            end
        end
        return count
    end

    return env
end

return Stubs
