import { readdir, readFile } from "node:fs/promises"
import { homedir } from "node:os"
import path from "node:path"
import type { Plugin } from "@opencode/plugin/gui"
import { Schema } from "effect"
import { Account, Usage, type Limit } from "./contract"

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
const POLL_MS = 5 * 60 * 1000
// Anthropic rate limits this endpoint, so a click cannot check more often than this.
const MIN_GAP_MS = 30 * 1000
// Anthropic often answers 429 here, so one failed check does not make the numbers stale.
const STALE_MS = 15 * 60 * 1000

const Credentials = Schema.Struct({
  claudeAiOauth: Schema.Struct({
    accessToken: Schema.String,
    expiresAt: Schema.Number,
  }),
})

const Profile = Schema.Struct({
  oauthAccount: Schema.Struct({
    emailAddress: Schema.String,
  }),
})

const UsageResponse = Schema.Struct({
  limits: Schema.Array(
    Schema.Struct({
      kind: Schema.String,
      percent: Schema.Number,
      resets_at: Schema.NullOr(Schema.String),
      scope: Schema.NullOr(
        Schema.Struct({
          model: Schema.NullOr(Schema.Struct({ display_name: Schema.NullOr(Schema.String) })),
        }),
      ),
    }),
  ),
})

async function readJson(file: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(file, "utf8"))
  } catch {
    return undefined
  }
}

/** Every Claude Code config folder that is signed in: `~/.claude`, `~/.claude-1`, and so on. */
async function findConfigDirs() {
  const home = homedir()
  const names = await readdir(home)
  names.sort()

  const dirs: string[] = []
  for (const name of names) {
    if (name !== ".claude" && !name.startsWith(".claude-")) {
      continue
    }
    const dir = path.join(home, name)
    const credentials = await readJson(path.join(dir, ".credentials.json"))
    if (credentials !== undefined) {
      dirs.push(dir)
    }
  }
  return dirs
}

async function readEmail(dir: string) {
  // The default folder keeps its profile one level up, in `~/.claude.json`.
  const files = [path.join(dir, ".claude.json")]
  if (dir === path.join(homedir(), ".claude")) {
    files.push(path.join(homedir(), ".claude.json"))
  }

  for (const file of files) {
    const profile = Schema.decodeUnknownOption(Profile)(await readJson(file))
    if (profile._tag === "Some") {
      return profile.value.oauthAccount.emailAddress
    }
  }
  return ""
}

/** The account's limits, or undefined when they cannot be read right now. */
async function fetchLimits(dir: string): Promise<Limit[] | undefined> {
  const credentials = Schema.decodeUnknownOption(Credentials)(await readJson(path.join(dir, ".credentials.json")))
  if (credentials._tag === "None") {
    return undefined
  }
  // Claude Code renews the token the next time the account is used. Renewing it here could sign that account out.
  if (credentials.value.claudeAiOauth.expiresAt <= Date.now()) {
    return undefined
  }

  const response = await fetch(USAGE_URL, {
    headers: {
      Authorization: `Bearer ${credentials.value.claudeAiOauth.accessToken}`,
      "anthropic-beta": "oauth-2025-04-20",
    },
    signal: AbortSignal.timeout(20_000),
  })
  if (!response.ok) {
    throw new Error(`Anthropic answered ${response.status}`)
  }
  const usage = Schema.decodeUnknownOption(UsageResponse)(await response.json())
  if (usage._tag === "None") {
    throw new Error("Anthropic sent usage in a shape this plugin does not know")
  }

  // Only the limits the account really has: some plans have no 5 hour window at all.
  const sessions: Limit[] = []
  const weeklies: Limit[] = []
  const models: Limit[] = []
  for (const item of usage.value.limits) {
    const resetsAt = item.resets_at ?? ""
    if (item.kind === "session") {
      sessions.push({ kind: "session", model: "", percent: item.percent, resetsAt })
    }
    if (item.kind === "weekly_all") {
      weeklies.push({ kind: "weekly", model: "", percent: item.percent, resetsAt })
    }
    if (item.kind === "weekly_scoped") {
      const model = item.scope?.model?.display_name
      if (model) {
        models.push({ kind: "model", model, percent: item.percent, resetsAt })
      }
    }
  }
  return [...sessions, ...weeklies, ...models]
}

export const main: Plugin.MainSetup = (ctx) => {
  // Kept on disk so an account whose token ran out still shows what it last used.
  const stored = ctx.storage.store("accounts", { schema: Schema.Array(Account), initial: [] })

  let checking = false
  let lastCheck = 0

  const provider = ctx.provide(Usage, {
    state: () => ({ accounts: stored.value }),
    refresh: () => check(),
  })

  async function check() {
    if (checking || Date.now() - lastCheck < MIN_GAP_MS) {
      return
    }
    checking = true
    lastCheck = Date.now()

    try {
      stored.set(await readAccounts())
      provider.changed()
    } catch (cause) {
      ctx.log.write("warn", "claude usage check failed", { error: String(cause) })
    }
    checking = false
  }

  async function readAccounts() {
    const accounts: Account[] = []
    for (const dir of await findConfigDirs()) {
      const email = await readEmail(dir)

      let limits: Limit[] | undefined
      try {
        limits = await fetchLimits(dir)
      } catch (cause) {
        ctx.log.write("warn", "claude usage check failed", { dir, error: String(cause) })
      }

      if (limits) {
        accounts.push({ dir, email, limits, checkedAt: Date.now(), stale: false })
        continue
      }

      let before: Account | undefined
      for (const account of stored.value) {
        if (account.dir === dir) {
          before = account
        }
      }
      const checkedAt = before?.checkedAt ?? 0
      accounts.push({
        dir,
        email,
        limits: before?.limits ?? [],
        checkedAt,
        stale: Date.now() - checkedAt > STALE_MS,
      })
    }
    return accounts
  }

  void check()
  const timer = setInterval(() => void check(), POLL_MS)

  return () => clearInterval(timer)
}
