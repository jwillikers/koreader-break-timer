local CheckButton = require("ui/widget/checkbutton")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local dbg = require("dbg")
local logger = require("logger")
local datetime = require("datetime")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

-- todo Implement the break screen / dialog using something that doesn't respond to input events.
-- Currently, it's possible to move the dialog around.

local BreakTimer = WidgetContainer:extend{
    name = "breaktimer",
    next_event = 0,  -- The time until the next break starts or the current break ends
    break_interval = 1140, -- The length of time between breaks in seconds
    break_length = 240, -- The length of the break in seconds
    idle_start = 0, -- The time when suspend (idle) started
    is_break = false,

    -- Variables for bed time functionality.
    -- Breaking this out into it's own plugin seems like the correct thing, but it would be a rather difficult task.
    -- The BedTime plugin needs to communicate with the BreakTimer plugin to effectively pause breaks during bedtime and restart breaks after bed time.
    -- Since I'm no expert on KOReaders architecture or Lua for that matter, I'm implementing the bed time functionality as part of this class.
    -- If I can figure out proper message passing or perhaps encapsulation, I should probably do that instead.
    bed_time_start_seconds = 0, -- The hour when bed time starts
    bed_time_duration_seconds = 0, -- The length of bed time in seconds. Setting this to zero disables the bed time functionality.
    bed_time_dialog = nil,
}

function BreakTimer:isBedTimeEnabled()
    return self.bed_time_duration_seconds > 0
end

function BreakTimer:utcOffset()
    -- From koplugins/calibre.koplugin/search.lua

    -- To that end, compute the local timezone's offset to UTC via strftime's %z token...
    local tz = os.date("%z") -- +hhmm or -hhmm
    -- We deal with a time_t, so, convert that to seconds...
    local tz_sign, tz_hours, tz_minutes = tz:match("([+-])(%d%d)(%d%d)")
    local utc_diff = (tonumber(tz_hours) * 60 * 60) + (tonumber(tz_minutes) * 60)
    if tz_sign == "-" then
        utc_diff = -utc_diff
    end

    logger.dbg(string.format("BreakTimer: utcOffset return: %d", utc_diff))
    return utc_diff
end

-- The number of seconds into the current day
function BreakTimer:secondsIntoDay(seconds, adjust_for_timezone)
    if adjust_for_timezone then
        return (seconds + self:utcOffset()) % (24 * 3600)
    else
        return seconds % (24 * 3600)
    end
end

-- Determine if it is currently bed time
function BreakTimer:isBedTime(seconds)
    if self:isBedTimeEnabled() then
        -- Bed Time: 22:00 - 05:59
        -- Not Bed Time: 06:00 - 21:59
        --
        -- 00:00 -> Bed Time
        -- 03:00 -> Bed Time
        -- 05:45 -> Bed Time
        -- 06:00 -> Not Bed Time
        -- 06:01 -> Not Bed Time
        -- 08:17 -> Not Bed Time
        -- 13:24 -> Not Bed Time
        -- 17:00 -> Not Bed Time
        -- 19:59 -> Not Bed Time
        -- 22:00 -> Bed Time
        -- 23:00 -> Bed Time
        -- 23:59 -> Bed Time
        --
        -- Assumptions:
        --   * Bed time duration is a positive integer.
        --   * Bed time duration cannot exceed 24 hours
        --   * Bed time start is a positive integer.
        --   * Bed time start cannot exceed 24 hours
        --   * Bed time duration will not be 0 unless bed time is disabled
        --
        -- A single day will be split into two or three blocks of time depending on the bed time start and length.
        --
        -- Examples:
        --    * Bed time starts at 22:00 and lasts for 2 hours.
        --      Awake time is from 00:00 to 21:59.
        --      Bed time is from 22:00 to 11:59.
        --    * Bed time starts at 22:00 and lasts for 8 hours.
        --      Bed time is from 00:00 to 05:59.
        --      Awake time is from 06:00 to 21:59.
        --      Bed time is from 22:00 to 23:59.
        --    * Bed time starts at 08:00 and lasts for 6 hours.
        --      Awake time is from 00:00 to 07:59.
        --      Bed time is from 08:00 to 13:59.
        --      Awake time is from 14:00 to 23:59.
        --
        -- Algorithm must determine which slot a given time value falls into on any given day.
        -- Will do all calculations using seconds.
        -- First step is to determine the start and end times for each of the bed time and awake time blocks.
        -- There will be only two blocks of time if bed time or awake time starts or ends at 00:00 / 23:59.
        -- Determine the which bucket the current time falls into, ignoring any seconds related to the date.

        local seconds_into_day = self:secondsIntoDay(seconds, true)
        logger.dbg(string.format("BreakTimer: isBedTime seconds: %d", seconds))
        logger.dbg(string.format("BreakTimer: isBedTime seconds_into_day: %d", seconds_into_day))

        -- Determine the time when bed time ends.
        local bed_time_end = (self.bed_time_start_seconds + self.bed_time_duration_seconds) % (24 * 3600)

        if bed_time_end < self.bed_time_start_seconds then
            return seconds_into_day <= bed_time_end or seconds_into_day >= self.bed_time_start_seconds
        else
            return seconds_into_day >= self.bed_time_start_seconds and seconds_into_day <= bed_time_end
        end

        -- Create the buckets representing when bed time begins and ends in the day.
    --     local bed_time_schedule_table = {}
    --     if bed_time_end < self.bed_time_start_seconds then
    --         bed_time_schedule_table[0] = true
    --         -- Add an additional second here as that's when it switches to not being bed time.
    --         bed_time_schedule_table[bed_time_end + 1] = false
    --         bed_time_schedule_table[self.bed_time_start_seconds] = true
    --     else
    --         bed_time_schedule_table[0] = false
    --         bed_time_schedule_table[self.bed_time_start_seconds] = true
    --         -- Add an additional second here as that's when it switches to not being bed time.
    --         bed_time_schedule_table[bed_time_end + 1] = false
    --     end

    --     -- Sort the start times in reverse order
    --     -- local bed_time_schedule_table_keys = {}
    --     -- for key in pairs(bed_time_schedule_table) do
    --     --     table.insert(bed_time_schedule_table_keys, key)
    --     -- end
    --     -- table.sort(bed_time_schedule_table_keys, function(a, b) return a[1] >= b[1] end)
    --     table.sort(bed_time_schedule_table, function(a, b) return a[1] >= b[1] end)

    --     -- Now find in which bucket the current time resides.
    --     for start_time, is_bed_time in ipairs(bed_time_schedule_table) do
    --         if seconds_into_day >= start_time then
    --             if is_bed_time then
    --                 logger.dbg("BreakTimer: isBedTime return: true")
    --             else
    --                 logger.dbg("BreakTimer: isBedTime return: false")
    --             end
    --             return is_bed_time
    --         end
    --     end

    --     -- We shouldn't ever get here since it would require the the current time to be negative to make in the previous loop.
    --     return false
    else
        return false
    end
end
dbg:guard(BreakTimer, 'isBedTime',
    function(self, seconds)
        assert(seconds >= 0, "Only positive seconds allowed")
    end)

function BreakTimer:hasBedTimeBreakStarted()
    return self.bed_time_dialog ~= nil
end

-- Seconds until the next bed time starts if it is not currently bed time, otherwise math.huge seconds
function BreakTimer:secondsUntilBedTime(seconds)
    if not self:isBedTimeEnabled() or self:isBedTime(seconds) then
        return math.huge
    end

    local seconds_into_day = self:secondsIntoDay(seconds, true)
    logger.dbg(string.format("BreakTimer: secondsUntilBedTime seconds: %d", seconds))
    logger.dbg(string.format("BreakTimer: secondsUntilBedTime seconds_into_day: %d", seconds_into_day))

    -- Determine the time when bed time ends.
    local bed_time_end = (self.bed_time_start_seconds + self.bed_time_duration_seconds) % (24 * 3600)
    logger.dbg(string.format("BreakTimer: secondsUntilBedTime bed_time_end: %d", bed_time_end))

    if seconds_into_day < self.bed_time_start_seconds then
        logger.dbg(string.format("BreakTimer: secondsUntilBedTime return: %d", self.bed_time_start_seconds - seconds_into_day))
        return self.bed_time_start_seconds - seconds_into_day
    else
        logger.dbg(string.format("BreakTimer: secondsUntilBedTime return: %d", (self.bed_time_start_seconds + (24 * 3600)) - seconds_into_day))
        -- Bed time doesn't start until tomorrow now.
        return (self.bed_time_start_seconds + (24 * 3600)) - seconds_into_day
    end
end
dbg:guard(BreakTimer, 'secondsUntilBedTime',
    function(self, seconds)
        assert(seconds >= 0, "Only positive seconds allowed")
    end)

-- Seconds remaining during the current bed time otherwise math.huge seconds
function BreakTimer:bedTimeSecondsRemaining(seconds)
    if not self:isBedTimeEnabled() or not self:isBedTime(seconds) then
        return math.huge
    end

    local seconds_into_day = self:secondsIntoDay(seconds, true)
    logger.dbg(string.format("BreakTimer: bedTimeSecondsRemaining seconds: %d", seconds))
    logger.dbg(string.format("BreakTimer: bedTimeSecondsRemaining seconds_into_day: %d", seconds_into_day))

    -- Determine the time when bed time ends.
    local bed_time_end = (self.bed_time_start_seconds + self.bed_time_duration_seconds) % (24 * 3600)
    logger.dbg(string.format("BreakTimer: bedTimeSecondsRemaining bed_time_end: %d", (self.bed_time_start_seconds + self.bed_time_duration_seconds) % (24 * 3600)))

    if seconds_into_day > bed_time_end then
        logger.dbg(string.format("BreakTimer: bedTimeSecondsRemaining return: %d", (bed_time_end + (24 * 3600)) - seconds_into_day))
        -- Bed time doesn't end until tomorrow now.
        return (bed_time_end + (24 * 3600)) - seconds_into_day
    else
        logger.dbg(string.format("BreakTimer: bedTimeSecondsRemaining return: %d", bed_time_end - seconds_into_day))
        return bed_time_end - seconds_into_day
    end
end
dbg:guard(BreakTimer, 'bedTimeSecondsRemaining',
    function(self, seconds)
        assert(seconds >= 0, "Only positive seconds allowed")
    end)

function BreakTimer:startBedTime()
    logger.dbg("BreakTimer: startBedTime")
    if self:isBedTimeEnabled() then
        if self:isBedTime(os.time()) then
            logger.dbg("BreakTimer: Starting bed time")
            local seconds_until_bed_time_ends = self:bedTimeSecondsRemaining(os.time())
            if self:enabled() then
                logger.dbg(string.format("BreakTimer: Scheduling next break to begin after bed time ends in %d seconds", seconds_until_bed_time_ends + self.break_interval))
                self:resetBreakAndRescheduleIn(seconds_until_bed_time_ends + self.break_interval)
            end

            logger.dbg("BreakTimer: Creating bed time dialog")
            self.bed_time_dialog = InfoMessage:new{
                text = _("Time for bed"),
                dismissable = false,
                width = 800,
                height = 1200,
            }
            UIManager:show(self.bed_time_dialog)

            UIManager:scheduleIn(seconds_until_bed_time_ends, self.bed_time_end_callback)
        else
            logger.dbg("BreakTimer: Spurious call of startBedTime outside of bed time")
            local seconds_until_bed_time = self:secondsUntilBedTime(os.time())
            logger.dbg(string.format("BreakTimer: Rescheduling beginning of bed time in %d seconds", seconds_until_bed_time))
            UIManager:scheduleIn(seconds_until_bed_time, self.bed_time_start_callback)

            if self.bed_time_dialog ~= nil then
                logger.dbg("BreakTimer: Bed time dialog exists even though it isn't bed time. Closing bed time dialog")
                UIManager:close(self.bed_time_dialog)
                self.bed_time_dialog = nil
            end

            -- Ensure that breaks are scheduled to resume after bed time.
            if self:enabled() and not self:scheduled() then
                logger.dbg(string.format("BreakTimer: Breaks enabled but not currently scheduled! Scheduling next break in %d seconds", self.break_interval))
                self:resetBreakAndRescheduleIn(self.break_interval)
            end
        end
    end
end

function BreakTimer:endBedTime()
    logger.dbg("BreakTimer: endBedTime")
    if self:isBedTime(os.time()) then
        logger.dbg("BreakTimer: Spurious call of endBedTime during bed time")
        local bed_time_remaining_seconds = self:bedTimeSecondsRemaining(os.time())
        logger.dbg(string.format("BreakTimer: Rescheduling end of bed time in %d seconds", bed_time_remaining_seconds))
        UIManager:scheduleIn(bed_time_remaining_seconds, self.bed_time_end_callback)

        if self.bed_time_dialog == nil then
            logger.dbg("BreakTimer: The bed time dialog does not exist! Creating and showing the bed time dialog")
            self.bed_time_dialog = InfoMessage:new{
                text = _("Time for bed"),
                dismissable = false,
                width = 800,
                height = 1200,
            }
            UIManager:show(self.bed_time_dialog)
        else
            logger.dbg("BreakTimer: Ensuring that the bed time dialog is shown")
            UIManager:show(self.bed_time_dialog)
        end
    else
        logger.dbg("BreakTimer: Closing bed time dialog")
        UIManager:close(self.bed_time_dialog)
        self.bed_time_dialog = nil

        local seconds_until_bed_time_starts = self:secondsUntilBedTime(os.time())
        logger.dbg(string.format("BreakTimer: Scheduling bed time to start in %d seconds", seconds_until_bed_time_starts))
        UIManager:scheduleIn(seconds_until_bed_time_starts, self.bed_time_start_callback)

        if self:enabled() and not self:scheduled() then
            logger.dbg("BreakTimer: Rescheduling next break now that bed time has ended")
            self:resetBreakAndRescheduleIn(self.break_interval_time)
        end
    end
end

function BreakTimer:startBreak()
    logger.dbg("BreakTimer: Starting scheduled break")
    if self:enabled() and not self:isBreak() then
        self.is_break = true
        self:unschedule()
        logger.dbg("BreakTimer: Creating break dialog")
        self.break_dialog = InfoMessage:new{
            text = _("Time for a break"),
            dismissable = false,
            width = 800,
            height = 1200,
        }
        UIManager:show(self.break_dialog)
        logger.dbg(string.format("BreakTimer: Scheduling end of break in %d seconds", self.break_length))
        self:rescheduleIn(self.break_length)
    end
end

-- Starts a one-off break for a reduced amount of time.
-- The provided seconds are subtracted from the configured break length.
-- If the result is less than zero, the break will end immediately.
function BreakTimer:startBreakWithReducedLength(seconds)
    logger.dbg("BreakTimer: Starting scheduled break with reduced length")
    if self:disabled() then
        return
    end
    local reduced_break_length = self.break_length - seconds
    if self:isBreak() and reduced_break_length <= 0 then
        logger.dbg("BreakTimer: Break length reduced to 0 or lower. Ending Break")
        self:endBreak()
    elseif not self:isBreak() then
        self.is_break = true
        self:unschedule()
        -- self.break_start = time.now()
        -- self.break_end = self.break_start + time.s(self.break_length)
        logger.dbg("BreakTimer: Opening break dialog for a reduced amount of time")
        self.break_dialog = InfoMessage:new{
            text = _("Time for a break"),
            -- timeout = self.break_length,
            dismissable = false,
            width = 800,
            height = 1200,
        }
        UIManager:show(self.break_dialog)
        logger.dbg(string.format("BreakTimer: Scheduling end of break in %d seconds", reduced_break_length))
        self:rescheduleIn(reduced_break_length)
    end
end

function BreakTimer:isBreak()
    return self.is_break
end

function BreakTimer:endBreak()
    logger.dbg("BreakTimer: Ending scheduled break")
    if self:isBreak() then
        self.is_break = false
        self:unschedule()
        logger.dbg("BreakTimer: Closing break dialog")
        UIManager:close(self.break_dialog)
        self.break_dialog = nil
        self:rescheduleIn(self.break_interval)
    end
end

function BreakTimer:resetBreakAndRescheduleIn(seconds)
    logger.dbg("BreakTimer: resetBreakAndRescheduleIn")
    self:unschedule()
    if self:isBreak() then
        self.is_break = false
        logger.dbg("BreakTimer: Closing break dialog")
        UIManager:close(self.break_dialog)
        self.break_dialog = nil
    end
    if self:enabled() then
        self:rescheduleIn(seconds)
    end
end

function BreakTimer:resetBreak()
    logger.dbg("BreakTimer: Resetting break")
    self:resetBreakAndRescheduleIn(self.break_interval)
end

function BreakTimer:toggleBreak()
    -- self:unschedule()
    logger.dbg("BreakTimer: Toggling break")
    if self:isBedTimeEnabled() then
        if self:isBedTime(os.time()) then
            if self:hasBedTimeBreakStarted() then
                logger.dbg("BreakTimer: Turns out the bed time break has already started. Skipping toggling current break and not rescheduling")
            else
                logger.dbg("BreakTimer: Turns out it's bed time but the bed time break hasn't started yet. Starting bed time break")
                self:startBedTime()
            end
            return
        else
            if self:hasBedTimeBreakStarted() then
                logger.dbg("BreakTimer: For some reason the bed time break hasn't ended despite the fact that it's no longer bed time. Ending bed time break and skipping toggling current break")
                self:endBedTime()
                return
            end
        end
    end
    if self:enabled() then
        local remaining_s = self:remaining()
        if remaining_s > 0 then
            logger.dbg(string.format("BreakTimer: Spurious callback before the next event should trigger in %d seconds", remaining_s))
            return
        end
        if self:isBreak() then
            self:endBreak()
        else
            self:startBreak()
        end
    end
end

function BreakTimer:init()
    self.timer_symbol = "\u{23F2}"  -- ⏲ timer symbol
    self.timer_letter = "B"

    -- Read the BedTime settings
    local bed_time_duration_hours = 0
    local bed_time_duration_minutes = 0
    local bed_time_duration = G_reader_settings:readSetting("break_timer_bed_time_duration")
    if bed_time_duration then
        bed_time_duration_hours = bed_time_duration[1]
        bed_time_duration_minutes = bed_time_duration[2]
    end
    self.bed_time_duration_seconds = bed_time_duration_hours * 3600 + bed_time_duration_minutes * 60
    logger.dbg(string.format("BreakTimer: The bed time duration is %d seconds", self.bed_time_duration_seconds))

    local bed_time_start_hour = 22
    local bed_time_start_minute = 0
    local bed_time_start = G_reader_settings:readSetting("break_timer_bed_time_start")
    if bed_time_start then
        bed_time_start_hour = bed_time_start[1]
        bed_time_start_minute = bed_time_start[2]
    end
    self.bed_time_start_seconds = bed_time_start_hour * 3600 + bed_time_start_minute * 60
    local bed_time_start_hour_and_minute = datetime.secondsToClock(self.bed_time_start_seconds, false, false)
    logger.dbg(string.format("BreakTimer: Bed time is at %s", bed_time_start_hour_and_minute))

    self.bed_time_start_callback = function()
        logger.dbg("BreakTimer: bed time start callback function called")
        self:startBedTime()
    end
    self.bed_time_end_callback = function()
        logger.dbg("BreakTimer: bed time end callback function called")
        self:endBedTime()
    end

    -- Schedule bed time
    local os_time = os.time()
    if self:isBedTimeEnabled() then
        if self:isBedTime(os_time) then
            -- It's bed time.
            logger.dbg("BreakTimer: It's bed time")
            -- Ensure that the bed time break has started.
            if self:hasBedTimeBreakStarted() then
                -- I don't think this is possible in the init stage, but probably not a bad idea to be cautious.
                -- Reschedule the end of bed time.
                local remainder_seconds = self:bedTimeSecondsRemaining(os_time)
                if remainder_seconds == math.huge then
                    -- Should not be possible.
                    logger.dbg("BreakTimer: bedTimeSecondsRemaining returned math.huge when bed time is enabled and it is currently bed time!")
                else
                    logger.dbg(string.format("BreakTimer: Scheduling the end of bed time in %d seconds", remainder_seconds))
                    UIManager:scheduleIn(remainder_seconds, self.bed_time_end_callback)
                end
            else
                -- Initiate bed time.
                logger.dbg("BreakTimer: It is bed time but the bed time break has not yet started. Starting bed time break")
                -- UIManager:unschedule(self.bed_time_start_callback)
                self:startBedTime()
            end
        else
            -- It's not bed time.
            logger.dbg("BreakTimer: It's not bed time")
            -- Reschedule the start of bed time to be correct.
            if self:hasBedTimeBreakStarted() then
                -- Bed time is over
                -- UIManager:unschedule(self.bed_time_end_callback)
                logger.dbg("BreakTimer: It is not bed time but the bed time break is active. Ending bed time break")
                self:endBedTime()
            else
                -- Reschedule the beginning of bed time.
                local remainder_seconds = self:secondsUntilBedTime(os_time)
                if remainder_seconds == math.huge then
                    -- Should not be possible.
                    logger.dbg("BreakTimer: secondsUntilBedTime returned math.huge when bed time is enabled and it is not currently bed time!")
                else
                    logger.dbg(string.format("BreakTimer: Rescheduling start of bed time in %d seconds", remainder_seconds))
                    UIManager:scheduleIn(remainder_seconds, self.bed_time_start_callback)
                end
            end
        end
    end
    logger.dbg("BreakTimer: Finished initializing the bed time timers")

    -- Read the BreakTimer settings
    local break_length_hours = 0
    local break_length_minutes = 4
    local break_length = G_reader_settings:readSetting("break_timer_break_length")
    if break_length then
        break_length_hours = break_length[1]
        break_length_minutes = break_length[2]
    end
    self.break_length = break_length_hours * 3600 + break_length_minutes * 60
    logger.dbg(string.format("BreakTimer: Break length is %d seconds", self.break_length))

    local break_interval_hours = 0
    local break_interval_minutes = 19
    local break_interval = G_reader_settings:readSetting("break_timer_break_interval")
    if break_interval then
        break_interval_hours = break_interval[1]
        break_interval_minutes = break_interval[2]
    end
    self.break_interval = break_interval_hours * 3600 + break_interval_minutes * 60
    logger.dbg(string.format("BreakTimer: Break interval is %d seconds", self.break_interval))

    local break_length_hours = 0
    local break_length_minutes = 4
    local break_length = G_reader_settings:readSetting("break_timer_break_length")
    if break_length then
        break_length_hours = break_length[1]
        break_length_minutes = break_length[2]
    end
    self.break_length = break_length_hours * 3600 + break_length_minutes * 60
    logger.dbg(string.format("BreakTimer: Break length is %d seconds", self.break_length))

    -- local tip_text =

    -- todo Display the amount of time remaining and update every minute.
    -- todo Go to sleep for the duration of the break?
    -- todo When idle for the duration of the break length, reset the break timer.
    -- self.break_dialog = InfoMessage:new{
    --     text = tip_text,
    --     -- timeout = self.break_length,
    --     dismissable = false,
    --     width = 400,
    --     height = 800,
    -- }
    if not (self.break_interval == 0 and self.break_length == 0) then
        self.break_callback = function()
            logger.dbg("BreakTimer: break callback function called")
            self:toggleBreak()
        end

        logger.dbg(string.format("BreakTimer: Scheduling initial break in %d seconds", self.break_interval))
        self:rescheduleIn(self.break_interval)
    end

    self.additional_header_content_func = function()
        if self:scheduled() then
            local hours, minutes, dummy = self:remainingTime(1)
            local timer_info = string.format("%02d:%02d", hours, minutes)
            return self.timer_symbol .. timer_info
        end
        return
    end

    self.additional_footer_content_func = function()
        if self:scheduled() then
            local item_prefix = self.ui.view.footer.settings.item_prefix
            local hours, minutes, dummy = self:remainingTime(1)
            local timer_info = string.format("%02d:%02d", hours, minutes)

            if item_prefix == "icons" then
                return self.timer_symbol .. " " .. timer_info
            elseif item_prefix == "compact_items" then
                return self.timer_symbol .. timer_info
            else
                return self.timer_letter .. ": " .. timer_info
            end
        end
        return
    end

    self.show_value_in_header = G_reader_settings:readSetting("BreakTimer_show_value_in_header")
    self.show_value_in_footer = G_reader_settings:readSetting("BreakTimer_show_value_in_footer")

    if self.show_value_in_header then
        self:addAdditionalHeaderContent()
    end

    if self.show_value_in_footer then
        self:addAdditionalFooterContent()
    end

    self.ui.menu:registerToMainMenu(self)
    logger.dbg("registered to main menu")

end

function BreakTimer:update_status_bars(seconds)
    if self.show_value_in_header then
        UIManager:broadcastEvent(Event:new("UpdateHeader"))
    end
    if self.show_value_in_footer then
        UIManager:broadcastEvent(Event:new("RefreshAdditionalContent"))
    end
    -- if seconds schedule 1ms later
    if seconds and seconds >= 0 then
        UIManager:scheduleIn(math.max(math.floor(seconds)%60, 0.001), self.update_status_bars, self)
    elseif seconds and seconds < 0 and self:scheduled() then
        UIManager:scheduleIn(math.max(math.floor(self:remaining())%60, 0.001), self.update_status_bars, self)
    else
        UIManager:scheduleIn(60, self.update_status_bars, self)
    end
end

function BreakTimer:enabled()
    return self.break_interval ~= 0 and self.break_length ~= 0
end

function BreakTimer:disabled()
    return not self:enabled()
end

function BreakTimer:scheduled()
    return self.next_event ~= 0
end

function BreakTimer:remaining()
    if self:scheduled() then
        -- local remaining_s = time.to_s(self.next_event - UIManager:getElapsedTimeSinceBoot())
        local remaining_s = time.to_s(self.next_event - time.now())
        -- Account for the time the that the system was idle
        -- if self.idle_start > 0 then
        --     local time_idle = os.time() - self.idle_start
        --     remaining_s = remaining_s - time_idle
        -- end
        -- Resolution: time.now() subsecond, os.time() two seconds
        if remaining_s > 0 then
            return remaining_s
        else
            return 0
        end
    else
        return math.huge
    end
end

-- can round
function BreakTimer:remainingTime(round)
    if self:scheduled() then
        local remainder = self:remaining()
        if round then
            if round < 0 then -- round down
                remainder = remainder - 59
            elseif round == 0 then
                remainder = remainder + 30
            else -- round up
                remainder = remainder + 59
            end
            remainder = math.floor(remainder * (1/60)) * 60
        end

        local hours = math.floor(remainder * (1/3600))
        local minutes = math.floor(remainder % 3600 * (1/60))
        local seconds = math.floor(remainder % 60)
        return hours, minutes, seconds
    end
end

function BreakTimer:addAdditionalHeaderContent()
    if self.ui.crelistener then
        self.ui.crelistener:addAdditionalHeaderContent(self.additional_header_content_func)
        self:update_status_bars(-1)
    end
end
function BreakTimer:addAdditionalFooterContent()
    if self.ui.view then
        self.ui.view.footer:addAdditionalFooterContent(self.additional_footer_content_func)
        self:update_status_bars(-1)
    end
end

function BreakTimer:removeAdditionalHeaderContent()
    if self.ui.crelistener then
        self.ui.crelistener:removeAdditionalHeaderContent(self.additional_header_content_func)
        self:update_status_bars(-1)
        UIManager:broadcastEvent(Event:new("UpdateHeader"))
    end
end

function BreakTimer:removeAdditionalFooterContent()
    if self.ui.view then
        self.ui.view.footer:removeAdditionalFooterContent(self.additional_footer_content_func)
        self:update_status_bars(-1)
        UIManager:broadcastEvent(Event:new("UpdateFooter", true))
    end
end

function BreakTimer:unschedule()
    -- if self:scheduled() then
    if self.break_callback ~= nil then
        UIManager:unschedule(self.break_callback)
    end
    self.next_event = 0
    -- end
    UIManager:unschedule(self.update_status_bars, self)
end

function BreakTimer:rescheduleIn(seconds)
    self:unschedule()
    -- Resolution: time.now() subsecond, os.time() two seconds
    -- self.next_event = UIManager:getElapsedTimeSinceBoot() + time.s(seconds)
    self.next_event = time.now() + time.s(seconds)
    -- self.next_event = UIManager:getElapsedTimeSinceBoot() + time.s(seconds)
    -- local next_event_fts = time.now() + time.s(seconds)
    UIManager:scheduleIn(seconds, self.break_callback)
    -- UIManager:schedule(self.next_event, self.break_callback)
    if self:isBreak() then
        logger.dbg(string.format("BreakTimer: Break end scheduled in %d seconds", seconds))
    else
        logger.dbg(string.format("BreakTimer: Next break scheduled in %d seconds", seconds))
    end
    if self.show_value_in_header or self.show_value_in_footer then
        self:update_status_bars(seconds)
    end
end

function BreakTimer:addCheckboxes(widget)
    local checkbox_header = CheckButton:new{
        text = _("Show timer in alt status bar"),
        checked = self.show_value_in_header,
        parent = widget,
        callback = function()
            self.show_value_in_header = not self.show_value_in_header
            G_reader_settings:saveSetting("BreakTimer_show_value_in_header", self.show_value_in_header)
            if self.show_value_in_header then
                self:addAdditionalHeaderContent()
            else
                self:removeAdditionalHeaderContent()
            end
        end,
    }
    local checkbox_footer = CheckButton:new{
        text = _("Show timer in status bar"),
        checked = self.show_value_in_footer,
        parent = widget,
        callback = function()
            self.show_value_in_footer = not self.show_value_in_footer
            G_reader_settings:saveSetting("BreakTimer_show_value_in_footer", self.show_value_in_footer)
            if self.show_value_in_footer then
                self:addAdditionalFooterContent()
            else
                self:removeAdditionalFooterContent()
            end
        end,
    }
    widget:addWidget(checkbox_header)
    widget:addWidget(checkbox_footer)
end

function BreakTimer:addToMainMenu(menu_items)
    menu_items.break_timer = {
        text_func = function()
            if self:scheduled() then
                local user_duration_format = G_reader_settings:readSetting("duration_format")
                return T(_("Break timer (%1)"),
                    datetime.secondsToClockDuration(user_duration_format, self:remaining(), false))
            else
                return _("Break timer")
            end
        end,
        checked_func = function()
            return self:scheduled()
        end,
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Set break interval"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local break_interval_time = {}
                    local break_interval_hours = 0
                    local break_interval_minutes = 19
                    break_interval_time = G_reader_settings:readSetting("break_timer_break_interval")
                    if break_interval_time then
                        break_interval_hours = break_interval_time[1]
                        break_interval_minutes = break_interval_time[2]
                    end
                    local previous_break_interval = self.break_interval
                    local time_widget = DateTimeWidget:new{
                        hour = break_interval_hours or 0,
                        min = break_interval_minutes or 19,
                        hour_max = 17,
                        ok_text = _("Set break interval"),
                        title_text =  _("Set break timer interval"),
                        info_text = _("Enter a time in hours and minutes."),
                        callback = function(timer_time)
                            self:unschedule()
                            local seconds = timer_time.hour * 3600 + timer_time.min * 60
                            self.break_interval = seconds
                            break_interval_time = {timer_time.hour, timer_time.min}
                            if previous_break_interval ~= self.break_interval then
                                G_reader_settings:saveSetting("break_timer_break_interval", break_interval_time)
                            end
                            if seconds > 0 then
                                self:resetBreak()
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Break interval is %1."),
                                             datetime.secondsToClockDuration(user_duration_format, seconds, true)),
                                    timeout = 5,
                                })
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                if self:enabled() and previous_break_interval ~= self.break_interval then
                                    logger.dbg("BreakTimer: Break interval updated")
                                    logger.dbg(string.format("BreakTimer: Rescheduling break in %d seconds", self.break_interval))
                                    self:rescheduleIn(self.break_interval)
                                end
                            else
                                self:unschedule()
                                logger.dbg("BreakTimer: Break interval set to 0. Disabling breaking")
                                if self.break_dialog then
                                    self.is_break = false
                                    UIManager:close(self.break_dialog)
                                    self.break_dialog = nil
                                end
                            end
                        end
                    }
                    self:addCheckboxes(time_widget)
                    UIManager:show(time_widget)
                end,
            },
            {
                text = _("Set break length"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local break_length_time = {}
                    local break_length_hours = 0
                    local break_length_minutes = 4
                    break_length_time = G_reader_settings:readSetting("break_timer_break_length")
                    if break_length_time then
                        break_length_hours = break_length_time[1]
                        break_length_minutes = break_length_time[2]
                    end
                    local previously_enabled = self:enabled()
                    local previous_break_length = self.break_length
                    local time_widget = DateTimeWidget:new{
                        hour = break_length_hours or 0,
                        min = break_length_minutes or 4,
                        hour_max = 17,
                        ok_text = _("Set break length"),
                        title_text =  _("Set break timer break length"),
                        info_text = _("Enter a time in hours and minutes."),
                        callback = function(timer_time)
                            local seconds = timer_time.hour * 3600 + timer_time.min * 60
                            self.break_length = seconds
                            break_length_time = {timer_time.hour, timer_time.min}
                            if previous_break_length ~= self.break_length then
                                G_reader_settings:saveSetting("break_timer_break_length", break_length_time)
                            end
                            if seconds > 0 then
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Break length is %1."),
                                             datetime.secondsToClockDuration(user_duration_format, seconds, true)),
                                    timeout = 5,
                                })
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                if not previously_enabled and self:enabled() then
                                    logger.dbg(string.format("BreakTimer: Break duration updated to %d seconds", self.break_length))
                                    logger.dbg(string.format("BreakTimer: Scheduling initial break in %d seconds", self.break_interval))
                                    self:rescheduleIn(self.break_interval)
                                end
                            else
                                self:unschedule()
                                logger.dbg("BreakTimer: Break duration set to 0. Disabling breaking")
                                if self.break_dialog then
                                    self.is_break = false
                                    UIManager:close(self.break_dialog)
                                    self.break_dialog = nil
                                end
                            end
                        end
                    }
                    UIManager:show(time_widget)
                end,
            },
            {
                text = _("Set bed time"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local break_timer_bed_time_start = {}
                    local break_timer_bed_time_start_hour = 22
                    local break_timer_bed_time_start_minute = 0
                    break_timer_bed_time_start = G_reader_settings:readSetting("break_timer_bed_time_start")
                    if break_timer_bed_time_start then
                        break_timer_bed_time_start_hour = break_timer_bed_time_start[1]
                        break_timer_bed_time_start_minute = break_timer_bed_time_start[2]
                    end
                    local previous_bed_time_start_seconds = self.bed_time_start_seconds
                    local time_widget = DateTimeWidget:new{
                        hour = break_timer_bed_time_start_hour or 22,
                        min = break_timer_bed_time_start_minute or 0,
                        hour_max = 23,
                        ok_text = _("Set bed time"),
                        title_text =  _("Set bed time"),
                        info_text = _("Enter the hour and minute when bed time begins."),
                        callback = function(timer_time)
                            local seconds = timer_time.hour * 3600 + timer_time.min * 60
                            self.bed_time_start_seconds = seconds
                            break_timer_bed_time_start = {timer_time.hour, timer_time.min}
                            if previous_bed_time_start_seconds ~= self.bed_time_start_seconds then
                                G_reader_settings:saveSetting("break_timer_bed_time_start", break_timer_bed_time_start)
                            end
                            if seconds > 0 then
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Bed time is at %1."),
                                             datetime.secondsToClock(seconds, false, false)),
                                    timeout = 5,
                                })
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                if self:isBedTimeEnabled() and previous_bed_time_start_seconds ~= self.bed_time_start_seconds then
                                    if self:isBedTime(os.time()) and not self:hasBedTimeBreakStarted() then
                                        self:startBedTime()
                                    elseif not self:isBedTime(os.time()) and self:hasBedTimeBreakStarted() then
                                        self:endBedTime()
                                    else
                                        -- Reschedule when bed time starts.
                                        UIManager:unschedule(self.bed_time_start_callback)
                                        local seconds_until_bed_time = self:secondsUntilBedTime(os.time())
                                        logger.dbg(string.format("BreakTimer: Rescheduling beginning of bed time in %d seconds", seconds_until_bed_time))
                                        UIManager:scheduleIn(seconds_until_bed_time, self.bed_time_start_callback)
                                    end
                                end
                            end
                        end
                    }
                    UIManager:show(time_widget)
                end,
            },
            {
                text = _("Set bed time duration"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local bed_time_duration = {}
                    local bed_time_duration_hours = 0
                    local bed_time_duration_minutes = 0
                    bed_time_duration = G_reader_settings:readSetting("break_timer_bed_time_duration")
                    if bed_time_duration then
                        bed_time_duration_hours = bed_time_duration[1]
                        bed_time_duration_minutes = bed_time_duration[2]
                    end
                    local previous_bed_time_duration_seconds = self.bed_time_duration_seconds
                    local time_widget = DateTimeWidget:new{
                        hour = bed_time_duration_hours or 8,
                        min = bed_time_duration_minutes or 0,
                        hour_max = 23,
                        ok_text = _("Set bed time duration"),
                        title_text =  _("Set bed time duration"),
                        info_text = _("Enter a time in hours and minutes."),
                        callback = function(timer_time)
                            local seconds = timer_time.hour * 3600 + timer_time.min * 60
                            self.bed_time_duration_seconds = seconds
                            bed_time_duration = {timer_time.hour, timer_time.min}
                            if previous_bed_time_duration_seconds ~= self.bed_time_duration_seconds then
                                G_reader_settings:saveSetting("break_timer_bed_time_duration", bed_time_duration)
                            end
                            if seconds > 0 then
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Bed time duration is %1."),
                                             datetime.secondsToClockDuration(user_duration_format, seconds, true)),
                                    timeout = 5,
                                })
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                                if previous_bed_time_duration_seconds ~= self.bed_time_duration_seconds then
                                    if self:isBedTime(os.time()) then
                                        if self:hasBedTimeBreakStarted() then
                                            -- Reschedule the end of bed time.
                                            UIManager:unschedule(self.bed_time_end_callback)
                                            local bed_time_seconds_remaining = self:bedTimeSecondsRemaining(os.time())
                                            logger.dbg(string.format("BreakTimer: Rescheduling the end of bed time in %d seconds", bed_time_seconds_remaining))
                                            UIManager:scheduleIn(bed_time_seconds_remaining, self.bed_time_end_callback)
                                            if self:enabled() then
                                                local seconds_until_bed_time_ends = self:bedTimeSecondsRemaining(os.time())
                                                -- Schedule breaks to resume after bed time ends.
                                                logger.dbg(string.format("BreakTimer: Scheduling next break to begin after bed time ends in %d seconds", seconds_until_bed_time_ends + self.break_interval))
                                                self:resetBreakAndRescheduleIn(seconds_until_bed_time_ends + self.break_interval)
                                            end
                                        else
                                            self:startBedTime()
                                        end
                                    elseif not self:isBedTime(os.time()) and self:hasBedTimeBreakStarted() then
                                        self:endBedTime()
                                    end
                                else
                                    -- Reschedule the break end time?
                                end
                            else
                                UIManager:unschedule(self.bed_time_start_callback)
                                UIManager:unschedule(self.bed_time_end_callback)
                                if self.bed_time_dialog ~= nil then
                                    UIManager:close(self.bed_time_dialog)
                                    self.bed_time_dialog = nil
                                end
                            end
                        end
                    }
                    UIManager:show(time_widget)
                end,
            },
        },
    }
end

function BreakTimer:onSuspend()
    -- todo Trigger suspend after a break starts for the length of the break and set a timer to resume when the break finishes
    logger.dbg("BreakTimer: onSuspend")
    if self:disabled() and not self:isBedTimeEnabled() then
        return
    end
    if self:scheduled() then
        -- Unschedule the break timer while leaving the value of self.next_event intact
        logger.dbg("BreakTimer: Unscheduling break callback and status bar update")
        if self.break_callback ~= nil then
            UIManager:unschedule(self.break_callback)
            -- Try calling twice?
            UIManager:unschedule(self.break_callback)
        end
        logger.dbg("BreakTimer: Recording idle start time")
        -- self.idle_start = time.now()
        -- local ui_time = time.to_s(UIManager:getTime())
        -- logger.dbg(string.format("BreakTimer: UIManager time is %d seconds", ui_time))
    end
    UIManager:unschedule(self.update_status_bars, self)

    -- Unschedule bed time callbacks
    UIManager:unschedule(self.bed_time_start_callback)
    UIManager:unschedule(self.bed_time_end_callback)

    self.idle_start = UIManager:getElapsedTimeSinceBoot()
    logger.dbg(string.format("BreakTimer: Recorded idle start time as %d seconds", time.to_s(self.idle_start)))
end

-- The UI ticks on a MONOTONIC time domain, while this plugin deals with REAL wall clock time.
function BreakTimer:onResume()
    logger.dbg("BreakTimer: onResume")
    if self:disabled() and not self:isBedTimeEnabled() then
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    logger.dbg(string.format("BreakTimer: Current time is %d seconds", time.to_s(now)))
    local time_idle_s = time.to_s(now - self.idle_start)
    logger.dbg(string.format("BreakTimer: Was idle for %d seconds", time_idle_s))

    local os_time = os.time()

    if self:isBedTimeEnabled() then
        if self:isBedTime(os_time) then
            -- It's bed time.
            logger.dbg("BreakTimer: It's bed time")
            -- Ensure that the bed time break has started.
            if self:hasBedTimeBreakStarted() then
                -- Reschedule the end of bed time.
                -- todo remaining seconds
                local remainder_seconds = self:bedTimeSecondsRemaining(os_time)
                if remainder_seconds == math.huge then
                    -- Should not be possible.
                    logger.dbg("BreakTimer: bedTimeSecondsRemaining returned math.huge when bed time is enabled and it is currently bed time!")
                else
                    logger.dbg(string.format("BreakTimer: Rescheduling end of bed time in %d seconds", remainder_seconds))
                    UIManager:scheduleIn(remainder_seconds, self.bed_time_end_callback)
                end
            else
                -- Initiate bed time.
                logger.dbg("BreakTimer: It is bed time but the bed time break has not yet started. Starting bed time break")
                -- UIManager:unschedule(self.bed_time_start_callback)
                self:startBedTime()
            end
        else
            -- It's not bed time.
            logger.dbg("BreakTimer: It's not bed time")
            -- Reschedule the start of bed time to be correct.
            if self:hasBedTimeBreakStarted() then
                -- Bed time is over
                -- UIManager:unschedule(self.bed_time_end_callback)
                logger.dbg("BreakTimer: It is not bed time but the bed time break is active. Ending bed time break")
                self:endBedTime()
            else
                -- Reschedule the beginning of bed time.
                local remainder_seconds = self:secondsUntilBedTime(os_time)
                if remainder_seconds == math.huge then
                    -- Should not be possible.
                    logger.dbg("BreakTimer: secondsUntilBedTime returned math.huge when bed time is enabled and it is not currently bed time!")
                else
                    logger.dbg(string.format("BreakTimer: Rescheduling start of bed time in %d seconds", remainder_seconds))
                    UIManager:scheduleIn(remainder_seconds, self.bed_time_start_callback)
                end
            end
        end
    end

    -- At this point, if it is bed time, breaks will already have been unscheduled and this part will be skipped.
    if self:enabled() and self:scheduled() then
        -- If we were suspended for at least the length of a break, reset the break period.
        -- It doesn't matter whether a break was currently active or not.
        -- local ui_time = time.to_s(UIManager:getTime())
        -- logger.dbg(string.format("BreakTimer: UIManager time is %d seconds", ui_time))
        if time_idle_s >= self.break_length then
            logger.dbg(string.format("BreakTimer: Idle time (%d seconds) was greater than or equal to the break length (%d seconds), resetting break", time_idle_s, self.break_length))
            self:resetBreak()
        else
            -- The remaining time automatically takes into account any idle time using the self.idle_start variable.
            local remainder = self:remaining()
            logger.dbg(string.format("BreakTimer: Remainder %d seconds", remainder))
            if remainder <= 0 then
                -- The break should have already finished or started by now.
                if self:isBreak() then
                    logger.dbg("BreakTimer: The break should have ended already. Ending break.")
                    -- The break should have ended by now.
                    self:resetBreak()
                else
                    -- The break should have started by now.
                    logger.dbg(string.format("BreakTimer: The break should have started already. Starting reduced break shortened by %d seconds", time_idle_s))
                    -- Reduce the length of the break by the amount of time the system was idle, i.e. suspended.
                    self:startBreakWithReducedLength(time_idle_s)
                end
            elseif remainder == math.huge then
                -- Should not be possible.
                logger.dbg("BreakTimer: remaining() returned math.huge when breaks are scheduled!")
            else
                -- There is still time remaining until the next break starts or the current break finishes.
                -- The timer scheduled before sleeping is now wrong.
                -- So, reschedule the timer to occur after the remaining time elapses.
                if self:isBreak() then
                    -- If a break is ongoing, just reschedule the break for the time remaining.
                    self:rescheduleIn(remainder)
                    logger.dbg(string.format("BreakTimer: %d seconds remaining in the current break", remainder))
                else
                    -- If there is no break ongoing, ignore the time that the system was idle when rescheduling the break.
                    -- In effect, this doesn't count the time idle towards the next break.
                    -- Only time that is spent reading should count towards the next break.
                    self:rescheduleIn(remainder + time_idle_s)
                    logger.dbg(string.format("BreakTimer: %d seconds remaining before the next break", remainder + time_idle_s))
                end
            end
        end
        self.idle_start = 0
    else
        if self:isBreak() then
            logger.dbg("BreakTimer: Not scheduled. Resetting current break.")
            self:resetBreak()
        else
            logger.dbg("BreakTimer: Not scheduled. Scheduling.")
            self:rescheduleIn(self.break_interval)
        end
    end
end

function BreakTimer:onCloseWidget()
    logger.dbg("BreakTimer: onCloseWidget")
    self.next_event = 0
    self.is_break = false
    if self.break_dialog ~= nil then
        UIManager:close(self.break_dialog)
        self.break_dialog = nil
    end
    UIManager:unschedule(self.break_callback)
    UIManager:unschedule(self.update_status_bars, self)
    self.break_callback = nil

    UIManager:unschedule(self.bed_time_start_callback)
    UIManager:unschedule(self.bed_time_end_callback)
    if self.bed_time_dialog ~= nil then
        UIManager:close(self.bed_time_dialog)
        self.bed_time_dialog = nil
    end
end

return BreakTimer
