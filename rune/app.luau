--!strict
-- The app half: runs once for the whole app. Every 5 minutes it finds the signed-in Claude Code
-- config folders, asks Anthropic how much of each account's limits is used, and saves the answer
-- in the plugin's store, where every window reads it.

local plugin = require("@opencode/plugin")
local shared = require("./shared")

local USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
local POLL_SECONDS = 5 * 60
-- Anthropic rate limits this endpoint, so a click cannot check more often than this.
local MIN_GAP_MS = 30 * 1000
-- Anthropic often answers 429 here, so one failed check does not make the numbers stale.
local STALE_MS = 15 * 60 * 1000

-- Plugins cannot read files outside the workspace, so a small shell script reads the Claude Code
-- config folders (~/.claude, ~/.claude-1, and so on). For each signed-in folder it prints three
-- lines: the folder, its credentials file on one line, and the first email in its profile.
local READ_SCRIPT = [[
for dir in "$HOME/.claude" "$HOME"/.claude-*; do
    [ -f "$dir/.credentials.json" ] || continue
    printf 'dir\t%s\n' "$dir"
    printf 'credentials\t%s\n' "$(tr -d '\n' < "$dir/.credentials.json")"
    # The default folder keeps its profile one level up, in ~/.claude.json.
    profile="$dir/.claude.json"
    if [ ! -f "$profile" ] && [ "$dir" = "$HOME/.claude" ]; then
        profile="$HOME/.claude.json"
    fi
    if [ -f "$profile" ]; then
        printf 'email\t%s\n' "$(grep -o '"emailAddress" *: *"[^"]*"' "$profile" | head -n 1)"
    fi
done
]]

type Folder = {
    dir: string,
    email: string,
    accessToken: string,
    expiresAt: number,
}

-- Days from 1970-01-01 to the given date in the Gregorian calendar.
local function daysFromCivil(year: number, month: number, day: number): number
    local y = if month <= 2 then year - 1 else year
    local era = math.floor(y / 400)
    local yearOfEra = y - era * 400
    local shiftedMonth = if month > 2 then month - 3 else month + 9
    local dayOfYear = math.floor((153 * shiftedMonth + 2) / 5) + day - 1
    local dayOfEra = yearOfEra * 365 + math.floor(yearOfEra / 4) - math.floor(yearOfEra / 100) + dayOfYear
    return era * 146097 + dayOfEra - 719468
end

-- An ISO date such as 2026-11-27T18:00:00.123+00:00 as milliseconds since the Unix epoch.
-- 0 when the text is not a date.
local function parseIsoDate(text: string): number
    local year, month, day, hour, minute, second, rest = text:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)(.*)$")
    if not year then
        return 0
    end
    local days = daysFromCivil(tonumber(year) :: number, tonumber(month) :: number, tonumber(day) :: number)
    local seconds = days * 86400
        + (tonumber(hour) :: number) * 3600
        + (tonumber(minute) :: number) * 60
        + (tonumber(second) :: number)

    -- A time zone such as +02:00 is ahead of UTC, so it is taken off. "Z" or nothing means UTC.
    local sign, zoneHours, zoneMinutes = (rest :: string):match("([+-])(%d%d):?(%d%d)$")
    if sign then
        local offset = (tonumber(zoneHours) :: number) * 3600 + (tonumber(zoneMinutes) :: number) * 60
        if sign == "+" then
            seconds -= offset
        else
            seconds += offset
        end
    end
    return seconds * 1000
end

return plugin.defineApp(function(ctx)
    local Process = ctx:GetService("Process")
    local Http = ctx:GetService("Http")
    local Store = ctx:GetService("Store")
    local System = ctx:GetService("System")
    local Contracts = ctx:GetService("Contracts")
    local Console = ctx:GetService("Console")

    -- Kept on disk so an account whose token ran out still shows what it last used.
    local stored = Store:Value(shared.STORE, {} :: { shared.Account })

    local checking = false
    local lastCheck = 0

    -- Every Claude Code config folder that is signed in, with its token and email.
    local function findFolders(): { Folder }
        local out = Process:RunAsync({ program = "sh", args = { "-c", READ_SCRIPT }, timeout = 20 })
        if not out.ok then
            Console:Warn("claude usage: reading the config folders failed", out.error or out.stderr)
            return {}
        end

        local folders: { Folder } = {}
        local current: Folder? = nil
        for line in out.stdout:gmatch("[^\n]+") do
            local name, value = line:match("^(%a+)\t(.*)$")
            if name == "dir" then
                current = { dir = value :: string, email = "", accessToken = "", expiresAt = 0 }
                table.insert(folders, current :: Folder)
            elseif name == "credentials" and current then
                -- The Claude subscription's token is the one under "claudeAiOauth".
                local start = (value :: string):find('"claudeAiOauth"', 1, true)
                if start then
                    local oauth = (value :: string):sub(start)
                    current.accessToken = oauth:match('"accessToken"%s*:%s*"([^"]+)"') or ""
                    current.expiresAt = tonumber(oauth:match('"expiresAt"%s*:%s*(%d+)')) or 0
                end
            elseif name == "email" and current then
                current.email = (value :: string):match(':%s*"([^"]*)"') or ""
            end
        end
        return folders
    end

    -- The account's limits, or nil when they cannot be read right now.
    local function fetchLimits(folder: Folder): { shared.Limit }?
        if folder.accessToken == "" then
            return nil
        end
        -- Claude Code renews the token the next time the account is used. Renewing it here could
        -- sign that account out.
        if folder.expiresAt <= System:Now() then
            return nil
        end

        local response = Http:FetchAsync({
            url = USAGE_URL,
            headers = {
                Authorization = `Bearer {folder.accessToken}`,
                ["anthropic-beta"] = "oauth-2025-04-20",
            },
            timeout = 20,
        })
        if not response.ok then
            Console:Warn("claude usage: Anthropic answered", response.status, folder.dir)
            return nil
        end
        local body: any = response.json
        if type(body) ~= "table" or type(body.limits) ~= "table" then
            Console:Warn("claude usage: Anthropic sent usage in a shape this plugin does not know", folder.dir)
            return nil
        end

        -- Only the limits the account really has: some plans have no 5 hour window at all.
        local sessions: { shared.Limit } = {}
        local weeklies: { shared.Limit } = {}
        local models: { shared.Limit } = {}
        for _, item in body.limits do
            if type(item) ~= "table" or type(item.percent) ~= "number" then
                continue
            end
            local resetsAt = 0
            if type(item.resets_at) == "string" then
                resetsAt = parseIsoDate(item.resets_at)
            end

            if item.kind == "session" then
                table.insert(sessions, { kind = "session", model = "", percent = item.percent, resetsAt = resetsAt })
            end
            if item.kind == "weekly_all" then
                table.insert(weeklies, { kind = "weekly", model = "", percent = item.percent, resetsAt = resetsAt })
            end
            if item.kind == "weekly_scoped" then
                local model = ""
                if type(item.scope) == "table" and type(item.scope.model) == "table" then
                    if type(item.scope.model.display_name) == "string" then
                        model = item.scope.model.display_name
                    end
                end
                if model ~= "" then
                    table.insert(models, { kind = "model", model = model, percent = item.percent, resetsAt = resetsAt })
                end
            end
        end

        local limits: { shared.Limit } = {}
        for _, limit in sessions do
            table.insert(limits, limit)
        end
        for _, limit in weeklies do
            table.insert(limits, limit)
        end
        for _, limit in models do
            table.insert(limits, limit)
        end
        return limits
    end

    local function readAccounts(): { shared.Account }
        local accounts: { shared.Account } = {}
        for _, folder in findFolders() do
            local limits = fetchLimits(folder)
            local now = System:Now()

            if limits then
                table.insert(accounts, {
                    dir = folder.dir,
                    email = folder.email,
                    limits = limits,
                    checkedAt = now,
                    stale = false,
                })
                continue
            end

            -- The check failed, so keep what the last good check found.
            local before: shared.Account? = nil
            for _, account in stored:Get() do
                if account.dir == folder.dir then
                    before = account
                end
            end
            local checkedAt = if before then before.checkedAt else 0
            table.insert(accounts, {
                dir = folder.dir,
                email = folder.email,
                limits = if before then before.limits else {},
                checkedAt = checkedAt,
                stale = now - checkedAt > STALE_MS,
            })
        end
        return accounts
    end

    local function check()
        local now = System:Now()
        if checking or now - lastCheck < MIN_GAP_MS then
            return
        end
        checking = true
        lastCheck = now

        local ok, problem = pcall(function()
            stored:Set(readAccounts())
        end)
        if not ok then
            Console:Warn("claude usage: check failed", tostring(problem))
        end
        checking = false
    end

    local api: shared.Api = {
        refresh = function()
            task.spawn(check)
        end,
    }
    Contracts:Provide(shared.CONTRACT, api)

    task.spawn(function()
        while true do
            check()
            task.wait(POLL_SECONDS)
        end
    end)
end)
