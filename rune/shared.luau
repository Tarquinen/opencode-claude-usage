--!strict
-- The types both halves share. The app half saves a list of accounts in the plugin's store, and
-- each window draws that list.

local shared = {}

export type Limit = {
    -- "session" is the 5 hour window, "weekly" the 7 day one, and "model" a 7 day limit for one model.
    kind: string,
    -- The model's name for a "model" limit, such as "Fable". Empty otherwise.
    model: string,
    -- How much of the limit is used, from 0 to 100.
    percent: number,
    -- When the limit resets, in milliseconds since the Unix epoch. 0 when no window is running.
    resetsAt: number,
}

export type Account = {
    -- The Claude Code config folder, such as /home/me/.claude.
    dir: string,
    -- The account's email. Empty when the folder does not record one.
    email: string,
    limits: { Limit },
    -- When the limits were last read from Anthropic, in milliseconds. 0 when they never were.
    checkedAt: number,
    -- The last check failed, so the limits are what an earlier check found.
    stale: boolean,
}

-- What the app half provides to the windows as the "claude-usage" contract.
export type Api = {
    -- Checks every account again now.
    refresh: () -> (),
}

shared.STORE = "accounts"
shared.CONTRACT = "claude-usage"

return shared
