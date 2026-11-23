import { Schema } from "effect"
import { Ipc } from "@opencode/plugin/gui"

export const PLUGIN_ID = "opencode-claude-usage"

export const Limit = Schema.Struct({
  /** `session` is the 5 hour window, `weekly` the 7 day one, and `model` a 7 day limit for one model. */
  kind: Schema.Literals(["session", "weekly", "model"]),
  /** The model's name for a `model` limit, e.g. `Fable`. Empty otherwise. */
  model: Schema.String,
  /** How much of the limit is used, from 0 to 100. */
  percent: Schema.Number,
  /** When the limit resets, as an ISO date. Empty when no window is running. */
  resetsAt: Schema.String,
})
export type Limit = typeof Limit.Type

export const Account = Schema.Struct({
  /** The Claude Code config folder, e.g. `/home/me/.claude`. */
  dir: Schema.String,
  /** The account's email. Empty when the folder does not record one. */
  email: Schema.String,
  limits: Schema.Array(Limit),
  /** When `limits` was last read from Anthropic, in milliseconds. 0 when it never was. */
  checkedAt: Schema.Number,
  /** The last check failed, so `limits` is what an earlier check found. */
  stale: Schema.Boolean,
})
export type Account = typeof Account.Type

export const Usage = Ipc.define({
  id: `${PLUGIN_ID}.usage`,
  state: Schema.Struct({
    accounts: Schema.Array(Account),
  }),
  methods: {
    /** Checks every account again now. */
    refresh: {},
  },
  events: {},
})
