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
    next_break = 0,  -- The time until the next break occurs
    break_interval = 1140, -- The length of time between breaks in seconds
    break_length = 240, -- The length of the break in seconds
}

function BreakTimer:init()
    self.timer_symbol = "\u{23F2}"  -- ⏲ timer symbol
    self.timer_letter = "B"

    self.break_interval = G_reader_settings:readSetting("break_timer_break_interval")
    self.break_length = G_reader_settings:readSetting("break_timer_break_length")

    self.break_callback = function()
        logger.dbg("time for scheduled break")
        self:unschedule()

        -- todo Display the amount of time remaining and update every minute.
        -- todo Go to sleep for the duration of the break?
        UIManager:show(InfoMessage:new{
                text = tip_text,
                timeout = self.break_length,
                dismissable = false,
                width = 350,
                height = 750,
        })

        self:rescheduleIn(self.break_interval + self.break_length)
        local tip_text = _("Time for a break")
    end

    self:rescheduleIn(self.break_interval)
    logger.dbg("scheduled initial break")

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

function BreakTimer:scheduled()
    return self.break_interval ~= 0
end

function BreakTimer:remaining()
    if self:scheduled() then
        -- Resolution: time.now() subsecond, os.time() two seconds
        local remaining_s = time.to_s(self.next_break - time.now())
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
    if self:scheduled() then
        UIManager:unschedule(self.break_callback)
        self.next_break = 0
    end
    UIManager:unschedule(self.update_status_bars, self)
end

function BreakTimer:rescheduleIn(seconds)
    self:unschedule()
    -- Resolution: time.now() subsecond, os.time() two seconds
    self.next_break = time.now() + time.s(seconds)
    UIManager:scheduleIn(seconds, self.break_callback)
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
                    local remain_time = {}
                    local remain_hours, remain_minutes = self:remainingTime()
                    if not remain_hours and not remain_minutes then
                        remain_time = G_reader_settings:readSetting("break_timer_remain_time")
                        if remain_time then
                            remain_hours = remain_time[1]
                            remain_minutes = remain_time[2]
                        end
                    end
                    local time_widget = DateTimeWidget:new{
                        hour = remain_hours or 0,
                        min = remain_minutes or 0,
                        hour_max = 17,
                        ok_text = _("Set break interval"),
                        title_text =  _("Set break timer interval"),
                        info_text = _("Enter a time in hours and minutes."),
                        callback = function(timer_time)
                            self:unschedule()
                            local seconds = timer_time.hour * 3600 + timer_time.min * 60
                            if seconds > 0 then
                                self.break_interval = seconds
                                self:rescheduleIn(seconds)
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Break interval is %1."),
                                             datetime.secondsToClockDuration(user_duration_format, seconds, true)),
                                    timeout = 5,
                                })
                                remain_time = {timer_time.hour, timer_time.min}
                                G_reader_settings:saveSetting("break_timer_remain_time", remain_time)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
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
                    local remain_time = {}
                    local remain_hours, remain_minutes = self:remainingTime()
                    if not remain_hours and not remain_minutes then
                        remain_time = G_reader_settings:readSetting("break_timer_break_length")
                        if remain_time then
                            remain_hours = remain_time[1]
                            remain_minutes = remain_time[2]
                        end
                    end
                    local time_widget = DateTimeWidget:new{
                        hour = remain_hours or 0,
                        min = remain_minutes or 0,
                        hour_max = 17,
                        ok_text = _("Set break length"),
                        title_text =  _("Set break timer break length"),
                        info_text = _("Enter a time in hours and minutes."),
                        callback = function(timer_time)
                            -- self:unschedule()
                            local seconds = timer_time.hour * 3600 + timer_time.min * 60
                            if seconds > 0 then
                                self.break_length = seconds
                                -- self:rescheduleIn(seconds)
                                local user_duration_format = G_reader_settings:readSetting("duration_format")
                                UIManager:show(InfoMessage:new{
                                    -- @translators This is a duration
                                    text = T(_("Break length is %1."),
                                             datetime.secondsToClockDuration(user_duration_format, seconds, true)),
                                    timeout = 5,
                                })
                                remain_time = {timer_time.hour, timer_time.min}
                                G_reader_settings:saveSetting("break_timer_break_length", remain_time)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
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

-- The UI ticks on a MONOTONIC time domain, while this plugin deals with REAL wall clock time.
function BreakTimer:onResume()
    if self:scheduled() then
        logger.dbg("BreakTimer: onResume with an active timer")
        local remainder = self:remaining()

        if remainder == 0 then
            -- Make sure we fire the alarm right away if it expired during suspend...
            -- self:break_callback()
            self:rescheduleIn(self.break_interval)
            -- self:unschedule()
        else
            -- ...and that we re-schedule the timer against the REAL time if it's still ticking.
            logger.dbg("BreakTimer: Rescheduling in", remainder, "seconds")
            self:unschedule()
            self:rescheduleIn(remainder)
        end
    end
end

return BreakTimer
