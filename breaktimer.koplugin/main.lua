local CheckButton = require("ui/widget/checkbutton")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local datetime = require("datetime")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

local BreakTimer = WidgetContainer:extend{
    name = "breaktimer",
    next_event = 0,  -- The time until the next break starts or the current break ends
    break_interval = 1140, -- The length of time between breaks in seconds
    break_length = 240, -- The length of the break in seconds
    idle_start = 0, -- The time when suspend (idle) started
}

function BreakTimer:startBreak()
    logger.dbg("BreakTimer: Starting scheduled break")
    if self:enabled() and not self:isBreak() then
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
    return self.break_dialog ~= nil
end

function BreakTimer:endBreak()
    logger.dbg("BreakTimer: Ending scheduled break")
    if self:isBreak() then
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
    if self:enabled() then
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

    local break_interval_hours = 0
    local break_interval_minutes = 19
    local break_interval = G_reader_settings:readSetting("break_timer_break_interval")
    if break_interval then
        break_interval_hours = break_interval[1]
        break_interval_minutes = break_interval[2]
    end
    self.break_interval = break_interval_hours * 3600 + break_interval_minutes * 60
    logger.dbg(string.format("Break interval is %d seconds", self.break_interval))

    local break_length_hours = 0
    local break_length_minutes = 4
    local break_length = G_reader_settings:readSetting("break_timer_break_length")
    if break_length then
        break_length_hours = break_length[1]
        break_length_minutes = break_length[2]
    end
    self.break_length = break_length_hours * 3600 + break_length_minutes * 60
    logger.dbg(string.format("Break length is %d seconds", self.break_length))

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
        local remaining_s = self.next_event - os.time()
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
    if self.break_callback then
        UIManager:unschedule(self.break_callback)
    end
    self.next_event = 0
    -- end
    UIManager:unschedule(self.update_status_bars, self)
end

function BreakTimer:rescheduleIn(seconds)
    self:unschedule()
    -- Resolution: time.now() subsecond, os.time() two seconds
    self.next_event = os.time() + seconds
    -- local next_event_fts = time.now() + time.s(seconds)
    UIManager:scheduleIn(seconds, self.break_callback)
    -- UIManager:schedule(next_event_fts, self.break_callback)
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
                text = _("Set interval"),
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
                            G_reader_settings:saveSetting("break_timer_break_interval", break_interval_time)
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
                            else
                                self:unschedule()
                                if self.break_dialog then
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
                            G_reader_settings:saveSetting("break_timer_break_length", break_length_time)
                            if seconds > 0 then
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Break length is %1."),
                                             datetime.secondsToClockDuration(user_duration_format, seconds, true)),
                                    timeout = 5,
                                })
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            else
                                self:unschedule()
                                if self.break_dialog then
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
        },
    }
end

function BreakTimer:onSuspend()
    -- todo Trigger suspend after a break starts for the length of the break and set a timer to resume when the break finishes
    logger.dbg("BreakTimer: onSuspend")
    if self:disabled() then
        return
    end
    if self:scheduled() then
        logger.dbg("BreakTimer: Recording idle start time")
        -- self.idle_start = time.now()
        self.idle_start = os.time()
        logger.dbg(string.format("BreakTimer: Recorded idle start time as %d seconds", self.idle_start))
        -- local ui_time = time.to_s(UIManager:getTime())
        -- logger.dbg(string.format("BreakTimer: UIManager time is %d seconds", ui_time))
    end
end

-- function sleep(n)
--   os.execute("sleep " .. tonumber(n))
-- end

-- The UI ticks on a MONOTONIC time domain, while this plugin deals with REAL wall clock time.
function BreakTimer:onResume()
    logger.dbg("BreakTimer: onResume")
    if self:disabled() then
        return
    end
    if self:scheduled() then
        -- Wait for the current time to be updated
        -- sleep(1)
        -- If we were suspended for at least the length of a break, reset the break period.
        -- It doesn't matter whether a break was currently active or not.
        local now_s = os.time()
        logger.dbg(string.format("BreakTimer: Current time is %d seconds", now_s))
        -- local ui_time = time.to_s(UIManager:getTime())
        -- logger.dbg(string.format("BreakTimer: UIManager time is %d seconds", ui_time))
        local time_idle_s = now_s - self.idle_start
        logger.dbg(string.format("BreakTimer: Was idle for %d seconds", time_idle_s))
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

return BreakTimer
