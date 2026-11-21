-- Unit tests for the Break Timer plugin.
--
-- Run from the repository root with either:
--   lua test/test_breaktimer.lua
--   luajit test/test_breaktimer.lua
-- Optionally pass a pattern to run only matching tests:
--   lua test/test_breaktimer.lua "bed time"

local script_dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local Stubs = require("koreader_stubs")
local PLUGIN_DIR = os.getenv("BREAKTIMER_PLUGIN_DIR") or (script_dir .. "/../breaktimer.koplugin")

local MINUTE, HOUR = 60, 3600
local DEFAULT_INTERVAL, DEFAULT_LENGTH = 19 * MINUTE, 4 * MINUTE

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

local function assertNear(actual, expected, message)
    if type(actual) ~= "number" or math.abs(actual - expected) >= 1 then
        error(string.format("%s: expected ~%s, got %s", message or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function assertBreakShown(env, timer, expected)
    local shown = timer.break_dialog ~= nil and env.shown[timer.break_dialog] == true
    if timer:isBreak() ~= expected or shown ~= expected then
        error(string.format("expected break %s, got isBreak=%s dialog shown=%s",
            expected and "active" or "inactive", tostring(timer:isBreak()), tostring(shown)), 2)
    end
end

local function assertBedTimeShown(env, timer, expected)
    local shown = timer.bed_time_dialog ~= nil and env.shown[timer.bed_time_dialog] == true
    if shown ~= expected then
        error(string.format("expected bed time dialog %s", expected and "shown" or "hidden"), 2)
    end
end

local function enableBedTime(env, start_hour, duration_hours)
    env.settings.break_timer_bed_time_start = { start_hour, 0 }
    env.settings.break_timer_bed_time_duration = { duration_hours, 0 }
end

---------------------------------------------------------------------------
-- Break schedule
---------------------------------------------------------------------------

test("uses the default interval and length", function(env)
    local timer = env.newTimer()
    assert(timer:enabled())
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until first break")
    env.advance(DEFAULT_INTERVAL - 1)
    assertBreakShown(env, timer, false)
    env.advance(1)
    assertBreakShown(env, timer, true)
    env.advance(DEFAULT_LENGTH)
    assertBreakShown(env, timer, false)
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until next break")
end)

test("reads the interval and length from settings", function(env)
    env.settings.break_timer_break_interval = { 1, 0 }
    env.settings.break_timer_break_length = { 0, 10 }
    local timer = env.newTimer()
    assertNear(timer:remaining(), HOUR, "time until first break")
    env.advance(HOUR)
    assertBreakShown(env, timer, true)
    assertNear(timer:remaining(), 10 * MINUTE, "break length")
end)

test("repeats breaks", function(env)
    local timer = env.newTimer()
    for _ = 1, 3 do
        env.advance(DEFAULT_INTERVAL)
        assertBreakShown(env, timer, true)
        env.advance(DEFAULT_LENGTH)
        assertBreakShown(env, timer, false)
    end
end)

test("is not scheduled at startup when the break length is 0", function(env)
    env.settings.break_timer_break_length = { 0, 0 }
    local timer = env.newTimer()
    assert(not timer:enabled())
    assert(not timer:scheduled())
end)

test("is not scheduled at startup when the break interval is 0", function(env)
    env.settings.break_timer_break_interval = { 0, 0 }
    local timer = env.newTimer()
    assert(not timer:scheduled())
end)

---------------------------------------------------------------------------
-- Changing the break length
---------------------------------------------------------------------------

test("saves the break length setting", function(env)
    local timer = env.newTimer()
    env.setMenuTime("Set break length", 0, 7)
    assert(timer.break_length == 7 * MINUTE)
    assert(env.settings.break_timer_break_length[1] == 0 and env.settings.break_timer_break_length[2] == 7)
end)

test("a new break length applies to the next break", function(env)
    local timer = env.newTimer()
    env.setMenuTime("Set break length", 0, 7)
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until first break is unchanged")
    env.advance(DEFAULT_INTERVAL)
    assertBreakShown(env, timer, true)
    env.advance(7 * MINUTE - 1)
    assertBreakShown(env, timer, true)
    env.advance(1)
    assertBreakShown(env, timer, false)
end)

test("setting the break length to 0 disables breaks", function(env)
    local timer = env.newTimer()
    env.setMenuTime("Set break length", 0, 0)
    assert(not timer:scheduled())
    env.advance(10 * HOUR)
    assertBreakShown(env, timer, false)
end)

test("setting the break length to 0 during a break ends it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + 10)
    assertBreakShown(env, timer, true)
    env.setMenuTime("Set break length", 0, 0)
    assertBreakShown(env, timer, false)
    assert(not timer:scheduled())
end)

test("re-enabling the break length schedules breaks again", function(env)
    local timer = env.newTimer()
    env.setMenuTime("Set break length", 0, 0)
    env.setMenuTime("Set break length", 0, 5)
    assert(timer:scheduled())
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until first break")
    env.advance(DEFAULT_INTERVAL)
    assertBreakShown(env, timer, true)
    env.advance(5 * MINUTE)
    assertBreakShown(env, timer, false)
end)

test("enabling breaks when both settings were 0 at startup", function(env)
    env.settings.break_timer_break_interval = { 0, 0 }
    env.settings.break_timer_break_length = { 0, 0 }
    local timer = env.newTimer()
    env.setMenuTime("Set break interval", 0, 10)
    env.setMenuTime("Set break length", 0, 2)
    assertNear(timer:remaining(), 10 * MINUTE, "time until first break")
    env.advance(10 * MINUTE)
    assertBreakShown(env, timer, true)
end)

test("lengthening the break during a break extends it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + MINUTE) -- 3 minutes left
    env.setMenuTime("Set break length", 0, 10) -- +6 minutes
    assertNear(timer:remaining(), 9 * MINUTE, "time left in break")
    env.advance(9 * MINUTE - 1)
    assertBreakShown(env, timer, true)
    env.advance(1)
    assertBreakShown(env, timer, false)
end)

test("shortening the break during a break shortens it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + MINUTE) -- 3 minutes left
    env.setMenuTime("Set break length", 0, 2) -- -2 minutes
    assertNear(timer:remaining(), MINUTE, "time left in break")
    env.advance(MINUTE)
    assertBreakShown(env, timer, false)
end)

test("shortening the break below the time already taken ends it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + 3 * MINUTE)
    env.setMenuTime("Set break length", 0, 2)
    assertBreakShown(env, timer, false)
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until next break")
end)

---------------------------------------------------------------------------
-- Changing the break interval
---------------------------------------------------------------------------

test("changing the break interval restarts the countdown", function(env)
    local timer = env.newTimer()
    env.advance(5 * MINUTE)
    env.setMenuTime("Set break interval", 0, 30)
    assert(env.settings.break_timer_break_interval[2] == 30)
    assertNear(timer:remaining(), 30 * MINUTE, "time until next break")
end)

test("changing the break interval during a break ends it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + 10)
    env.setMenuTime("Set break interval", 0, 30)
    assertBreakShown(env, timer, false)
    assertNear(timer:remaining(), 30 * MINUTE, "time until next break")
end)

test("setting the break interval to 0 disables breaks", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + 10)
    env.setMenuTime("Set break interval", 0, 0)
    assertBreakShown(env, timer, false)
    assert(not timer:scheduled())
end)

test("changing the break interval does not enable breaks when the length is 0", function(env)
    env.settings.break_timer_break_length = { 0, 0 }
    local timer = env.newTimer()
    env.setMenuTime("Set break interval", 0, 30)
    assert(not timer:scheduled())
end)

---------------------------------------------------------------------------
-- Suspend and resume
---------------------------------------------------------------------------

test("sleeping does not count towards the next break", function(env)
    local timer = env.newTimer()
    env.advance(10 * MINUTE)
    env.sleep(timer, 2 * MINUTE)
    assertNear(timer:remaining(), DEFAULT_INTERVAL - 10 * MINUTE, "time until next break")
    env.advance(DEFAULT_INTERVAL - 10 * MINUTE)
    assertBreakShown(env, timer, true)
end)

test("sleeping for at least the break length resets the countdown", function(env)
    local timer = env.newTimer()
    env.advance(10 * MINUTE)
    env.sleep(timer, DEFAULT_LENGTH)
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until next break")
end)

test("sleeping through the end of a break ends it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL + MINUTE)
    env.sleep(timer, DEFAULT_LENGTH)
    env.advance(1)
    assertBreakShown(env, timer, false)
    assert(timer:scheduled())
end)

test("sleeping part of a break keeps the rest of it", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL)
    env.sleep(timer, MINUTE)
    assertBreakShown(env, timer, true)
    assertNear(timer:remaining(), DEFAULT_LENGTH - MINUTE, "time left in break")
end)

test("resuming with breaks disabled and bed time enabled does not schedule breaks", function(env)
    enableBedTime(env, 22, 8)
    local timer = env.newTimer()
    env.setMenuTime("Set break length", 0, 0)
    env.sleep(timer, 30)
    assert(not timer:scheduled())
    env.advance(DEFAULT_INTERVAL * 2)
    assertBreakShown(env, timer, false)
end)

test("a break shortened to nothing by sleep is skipped", function(env)
    local timer = env.newTimer()
    env.advance(DEFAULT_INTERVAL - 10)
    timer:startBreakWithReducedLength(DEFAULT_LENGTH + 1)
    assertBreakShown(env, timer, false)
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until next break")
end)

---------------------------------------------------------------------------
-- Bed time calculations
---------------------------------------------------------------------------

test("isBedTime handles bed time that wraps past midnight", function(env)
    enableBedTime(env, 22, 8) -- 22:00 to 06:00
    env.setTimeOfDay(12, 0)
    local timer = env.newTimer()
    local function at(h, m, s) return h * HOUR + (m or 0) * MINUTE + (s or 0) end
    assert(not timer:isBedTime(at(21, 59, 59)))
    assert(timer:isBedTime(at(22, 0)))
    assert(timer:isBedTime(at(0, 0)))
    assert(timer:isBedTime(at(5, 59, 59)))
    assert(not timer:isBedTime(at(6, 0)), "bed time end is exclusive")
    assert(not timer:isBedTime(at(12, 0)))
end)

test("isBedTime handles bed time within a single day", function(env)
    enableBedTime(env, 8, 6) -- 08:00 to 14:00
    local timer = env.newTimer()
    assert(not timer:isBedTime(7 * HOUR + 59 * MINUTE))
    assert(timer:isBedTime(8 * HOUR))
    assert(timer:isBedTime(13 * HOUR + 59 * MINUTE))
    assert(not timer:isBedTime(14 * HOUR))
end)

test("isBedTime is false when bed time is disabled", function(env)
    local timer = env.newTimer()
    assert(not timer:isBedTimeEnabled())
    assert(not timer:isBedTime(23 * HOUR))
end)

test("secondsUntilBedTime and bedTimeSecondsRemaining", function(env)
    enableBedTime(env, 22, 8)
    local timer = env.newTimer()
    assertNear(timer:secondsUntilBedTime(20 * HOUR), 2 * HOUR, "until bed time")
    assert(timer:secondsUntilBedTime(23 * HOUR) == math.huge)
    assertNear(timer:bedTimeSecondsRemaining(23 * HOUR), 7 * HOUR, "remaining before midnight")
    assertNear(timer:bedTimeSecondsRemaining(2 * HOUR), 4 * HOUR, "remaining after midnight")
    assert(timer:bedTimeSecondsRemaining(12 * HOUR) == math.huge)
end)

---------------------------------------------------------------------------
-- Bed time behavior
---------------------------------------------------------------------------

test("bed time starts on schedule and pauses breaks", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(21, 50)
    local timer = env.newTimer()
    assertBedTimeShown(env, timer, false)
    env.advance(10 * MINUTE)
    assertBedTimeShown(env, timer, true)
    assertNear(timer:remaining(), 8 * HOUR + DEFAULT_INTERVAL, "first break after bed time")
end)

test("starting up during bed time schedules breaks for after bed time", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    assertBedTimeShown(env, timer, true)
    assertNear(timer:remaining(), 7 * HOUR + DEFAULT_INTERVAL, "first break after bed time")
end)

test("bed time ends on schedule without busy looping", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    env.advance(7 * HOUR)
    assertBedTimeShown(env, timer, false)
    assert(timer:scheduled())
    env.advance(DEFAULT_INTERVAL)
    assertBreakShown(env, timer, true)
end)

test("bed time ending reschedules breaks when none are scheduled", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    timer:unschedule()
    env.advance(7 * HOUR)
    assertBedTimeShown(env, timer, false)
    assertNear(timer:remaining(), DEFAULT_INTERVAL, "time until next break")
end)

test("changing the break interval during bed time waits for bed time to end", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    env.setMenuTime("Set break interval", 0, 30)
    assertNear(timer:remaining(), 7 * HOUR + 30 * MINUTE, "first break after bed time")
end)

test("re-enabling the break length during bed time waits for bed time to end", function(env)
    enableBedTime(env, 22, 8)
    env.settings.break_timer_break_length = { 0, 0 }
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    env.setMenuTime("Set break length", 0, 5)
    assertNear(timer:remaining(), 7 * HOUR + DEFAULT_INTERVAL, "first break after bed time")
end)

test("disabling bed time closes the bed time dialog", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    env.setMenuTime("Set bed time duration", 0, 0)
    assertBedTimeShown(env, timer, false)
    assert(not timer:isBedTimeEnabled())
end)

test("closing the plugin cleans up everything", function(env)
    enableBedTime(env, 22, 8)
    env.setTimeOfDay(23, 0)
    local timer = env.newTimer()
    timer:onCloseWidget()
    assertBedTimeShown(env, timer, false)
    assert(not timer:scheduled())
    for _, entry in ipairs(env.scheduled) do
        assert(entry.fn ~= timer.bed_time_start_callback and entry.fn ~= timer.bed_time_end_callback,
            "bed time callback still scheduled")
    end
end)

---------------------------------------------------------------------------
-- Runner
---------------------------------------------------------------------------

local pattern = arg and arg[1]
local passed, failed, skipped = 0, 0, 0
for _, t in ipairs(tests) do
    if pattern and not t.name:find(pattern, 1, true) then
        skipped = skipped + 1
    else
        local env = Stubs.new(PLUGIN_DIR)
        local restore = env.install()
        local ok, err = xpcall(function() t.fn(env) end, debug.traceback)
        restore()
        if ok then
            passed = passed + 1
            print("ok   " .. t.name)
        else
            failed = failed + 1
            print("FAIL " .. t.name .. "\n     " .. tostring(err):gsub("\n", "\n     "))
        end
    end
end
print(string.format("\n%d passed, %d failed%s", passed, failed,
    skipped > 0 and string.format(", %d skipped", skipped) or ""))
os.exit(failed == 0 and 0 or 1)
