--!strict
-- The window half: draws what the app half saved. One small bar per limit sits in the session
-- header, and clicking the bars opens a card with each account's limits and reset times.

local plugin = require("@opencode/plugin")
local ui = require("@opencode/ui")
local shared = require("@self/shared")

local MINUTE = 60 * 1000
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR

local BUTTON_KEY = "claude-usage"
local POPOVER_ID = "details"

local NAME = table.freeze({ size = 11, lineHeight = 12, color = "text-chrome" :: Color, truncate = true })
local LABEL = table.freeze({ size = 11, lineHeight = 12, color = "text-muted" :: Color, truncate = true, w = 40 })
local PERCENT = table.freeze({
    size = 11,
    lineHeight = 12,
    color = "text-muted" :: Color,
    tabular = true,
    textAlign = "end" :: Align,
    w = 30,
})
local RESET = table.freeze({
    size = 11,
    lineHeight = 12,
    color = "text-faint" :: Color,
    tabular = true,
    textAlign = "end" :: Align,
    w = 26,
})
local NOTE = table.freeze({ size = 11, lineHeight = 12, color = "text-faint" :: Color })

-- How full a limit is right now. A limit whose reset time has passed is empty again.
local function percentNow(limit: shared.Limit, now: number): number
    if limit.resetsAt > 0 and limit.resetsAt <= now then
        return 0
    end
    return math.clamp(limit.percent, 0, 100)
end

-- The limits worth showing. A 5 hour limit with no reset time has no window running, so it is left out.
local function shownLimits(account: shared.Account): { shared.Limit }
    local limits: { shared.Limit } = {}
    for _, limit in account.limits do
        if limit.kind == "session" and limit.resetsAt == 0 then
            continue
        end
        table.insert(limits, limit)
    end
    return limits
end

-- A 3 point bar filled to `percent`. It turns orange at 70% and red at 90%.
local function bar(percent: number, grow: number?): ui.Node
    local ink: Color = "icon-base"
    if percent >= 90 then
        ink = "status-danger"
    elseif percent >= 70 then
        ink = "status-warning"
    end

    local filled = percent / 100
    local parts: { ui.Node } = {}
    if filled > 0 then
        table.insert(parts, ui.box({ h = 3, grow = filled, radius = 2, fill = ink }))
    end
    if filled < 1 then
        table.insert(parts, ui.spacer({ grow = 1 - filled }))
    end
    return ui.row({ h = 3, grow = grow, radius = 2, fill = "surface-3", clip = true }, parts)
end

return plugin.defineWindow(function(ctx)
    local I18n = ctx:GetService("I18n")
    local Store = ctx:GetService("Store")
    local System = ctx:GetService("System")
    local Popover = ctx:GetService("Popover")
    local Contracts = ctx:GetService("Contracts")
    local Theme = ctx:GetService("Theme")

    local stored = Store:Value(shared.STORE, {} :: { shared.Account })
    local app = Contracts:Use(shared.CONTRACT)

    -- Fired when the drawing should change: new numbers arrived, or a minute passed and the
    -- reset times read differently.
    local changed = ctx:CreateSignal()
    stored.Changed:Connect(function()
        changed:Fire()
    end)
    task.spawn(function()
        while true do
            task.wait(60)
            changed:Fire()
        end
    end)

    -- Everything the drawing depends on. A render builds again only when this text changes.
    local function version(): string
        return `{stored:Version()}:{changed:Version()}:{Popover:IsOpen(POPOVER_ID)}:{Theme:Current().id}:{Theme:IsDark()}`
    end

    -- A length of time in short words, such as "3h" or "Updated 5m ago".
    local function span(time: number, key: string): string
        if time >= DAY then
            return I18n:T(`{key}.days`, { count = math.round(time / DAY) })
        end
        if time >= HOUR then
            return I18n:T(`{key}.hours`, { count = math.round(time / HOUR) })
        end
        return I18n:T(`{key}.minutes`, { count = math.max(1, math.round(time / MINUTE)) })
    end

    local function limitName(limit: shared.Limit): string
        if limit.kind == "session" then
            return I18n:T("limit.session")
        end
        if limit.kind == "weekly" then
            return I18n:T("limit.weekly")
        end
        return limit.model
    end

    local function resetIn(limit: shared.Limit, now: number): string
        if limit.resetsAt == 0 or limit.resetsAt <= now then
            return I18n:T("reset.none")
        end
        return span(limit.resetsAt - now, "reset")
    end

    local function updated(accounts: { shared.Account }, now: number): string
        local latest = 0
        for _, account in accounts do
            if account.checkedAt > latest then
                latest = account.checkedAt
            end
        end
        if now - latest < MINUTE then
            return I18n:T("updated.now")
        end
        return span(now - latest, "updated")
    end

    local function toggle()
        local wasOpen = Popover:IsOpen(POPOVER_ID)
        Popover:Toggle({ id = POPOVER_ID, anchorKey = BUTTON_KEY, side = "bottom", align = "end", gap = 6 })
        if wasOpen then
            return
        end
        -- Opening the card checks again, so the numbers are fresh.
        local api = app:Get() :: shared.Api?
        if app:State() == "active" and api then
            api.refresh()
        end
    end

    -- The header button: one column of bars per account.
    ctx:AddSlot({
        id = "meter",
        at = "session.header",
        order = 5,
        render = function(view, _props)
            local accounts = stored:Get()
            if #accounts == 0 then
                return nil
            end
            return view:Memo("claude-usage-header", version(), function()
                local now = System:Now()
                local columns: { ui.Node } = {}
                for _, account in accounts do
                    local bars: { ui.Node } = {}
                    for _, limit in shownLimits(account) do
                        table.insert(bars, bar(percentNow(limit, now)))
                    end
                    table.insert(columns, ui.col({ w = 16, gap = 2, opacity = if account.stale then 0.5 else 1 }, bars))
                end
                -- The memo keys its root, so the button's own key sits a level down.
                return ui.row({}, {
                    ui.row({
                        key = BUTTON_KEY,
                        role = "button",
                        h = 28,
                        px = 6,
                        gap = 4,
                        align = "center",
                        radius = 6,
                        hover = "surface-hover",
                        press = "surface-press",
                        hoverTransition = "instant",
                        fill = if Popover:IsOpen(POPOVER_ID) then "surface-press" else nil,
                        label = I18n:T("title"),
                        help = I18n:T("title"),
                        onPress = view:Handler(toggle),
                    }, columns),
                })
            end)
        end,
    })

    -- The card: each account's limits with their numbers and reset times.
    ctx:AddPopover({
        id = POPOVER_ID,
        title = I18n:T("title"),
        render = function(view, _props)
            return view:Memo("claude-usage-details", version(), function()
                local now = System:Now()
                local accounts = stored:Get()
                local cards: { ui.Node } = {}
                for _, account in accounts do
                    local dim = if account.stale then 0.5 else 1
                    local name = if account.email ~= "" then account.email else account.dir
                    local lines: { ui.Node } = { ui.text(name, NAME) }
                    for _, limit in shownLimits(account) do
                        local percent = percentNow(limit, now)
                        table.insert(
                            lines,
                            ui.row({ gap = 6, align = "center", opacity = dim }, {
                                ui.text(limitName(limit), LABEL),
                                bar(percent, 1),
                                ui.text(`{math.round(percent)}%`, PERCENT),
                                ui.text(resetIn(limit, now), RESET),
                            })
                        )
                    end
                    if account.stale and account.checkedAt > 0 then
                        table.insert(lines, ui.text(span(now - account.checkedAt, "stale"), NOTE))
                    end
                    table.insert(cards, ui.col({ gap = 5 }, lines))
                end
                table.insert(cards, ui.text(updated(accounts, now), NOTE))

                return ui.col({
                    w = 236,
                    pad = 8,
                    gap = 10,
                    radius = 6,
                    fill = "surface-1",
                    shadow = "floating",
                    label = I18n:T("title"),
                }, cards)
            end)
        end,
    })
end)
