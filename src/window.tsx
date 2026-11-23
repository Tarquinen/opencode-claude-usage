import { createSignal, For, onCleanup, Show } from "solid-js"
import { Portal } from "solid-js/web"
import { Slot, Style, usePlugin, type Plugin } from "@opencode/plugin/gui"
import { Usage, type Account, type Limit } from "./contract"
import type { definition } from "./definition"
import css from "./usage.css?inline"

const MINUTE = 60 * 1000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

/** How full a limit is right now. A limit whose reset time has passed is empty again. */
function percentNow(limit: Limit, now: number) {
  if (limit.resetsAt && Date.parse(limit.resetsAt) <= now) {
    return 0
  }
  return Math.min(100, Math.max(0, limit.percent))
}

function level(percent: number) {
  if (percent >= 90) {
    return "danger"
  }
  if (percent >= 70) {
    return "warning"
  }
  return "normal"
}

/** The limits worth showing. A 5 hour limit with no reset time has no window running, so it is left out. */
function shownLimits(account: Account) {
  const limits: Limit[] = []
  for (const limit of account.limits) {
    if (limit.kind === "session" && !limit.resetsAt) {
      continue
    }
    limits.push(limit)
  }
  return limits
}

/** The 5 hour limit, if the account has one, and the weekly limit that is closest to running out. */
function summary(account: Account, now: number) {
  let hasSession = false
  let session = 0
  let weekly = 0
  for (const limit of shownLimits(account)) {
    const percent = percentNow(limit, now)
    if (limit.kind === "session") {
      hasSession = true
      session = percent
    } else if (percent > weekly) {
      weekly = percent
    }
  }
  return { hasSession, session, weekly }
}

export const setup: Plugin.Setup<typeof definition> = (ctx) => {
  ctx.add(Style, css)
  ctx.add(Slot, { at: "session.header", order: 5, render: () => <UsageButton /> })
}

function UsageButton() {
  const ctx = usePlugin<typeof definition>()
  const ui = ctx.ui
  const usage = ctx.main(Usage)

  const [now, setNow] = createSignal(Date.now())
  const timer = setInterval(() => setNow(Date.now()), MINUTE)
  onCleanup(() => clearInterval(timer))

  const accounts = () => usage.state()?.accounts ?? []

  // Clicking the bars pins the details open until the user clicks elsewhere or presses Escape.
  const [open, setOpen] = createSignal(false)
  const [position, setPosition] = createSignal({ top: 0, right: 0 })
  let anchor: HTMLSpanElement | undefined
  let card: HTMLDivElement | undefined

  const toggle = () => {
    if (open()) {
      setOpen(false)
      return
    }
    if (!anchor) {
      return
    }
    const rect = anchor.getBoundingClientRect()
    setPosition({ top: rect.bottom + 6, right: window.innerWidth - rect.right })
    setOpen(true)
    void usage.refresh().catch(() => {})
  }

  const onPointerDown = (event: PointerEvent) => {
    if (!(event.target instanceof Node)) {
      return
    }
    if (anchor?.contains(event.target) || card?.contains(event.target)) {
      return
    }
    setOpen(false)
  }
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      setOpen(false)
    }
  }
  const close = () => setOpen(false)
  document.addEventListener("pointerdown", onPointerDown)
  document.addEventListener("keydown", onKeyDown)
  window.addEventListener("resize", close)
  onCleanup(() => {
    document.removeEventListener("pointerdown", onPointerDown)
    document.removeEventListener("keydown", onKeyDown)
    window.removeEventListener("resize", close)
  })

  const span = (time: number, key: "reset" | "stale" | "updated") => {
    if (time >= DAY) {
      return ctx.t(`${key}.days`, { count: Math.round(time / DAY) })
    }
    if (time >= HOUR) {
      return ctx.t(`${key}.hours`, { count: Math.round(time / HOUR) })
    }
    return ctx.t(`${key}.minutes`, { count: Math.max(1, Math.round(time / MINUTE)) })
  }

  const limitName = (limit: Limit) => {
    if (limit.kind === "session") {
      return ctx.t("limit.session")
    }
    if (limit.kind === "weekly") {
      return ctx.t("limit.weekly")
    }
    return limit.model
  }

  const resetIn = (limit: Limit) => {
    if (!limit.resetsAt || Date.parse(limit.resetsAt) <= now()) {
      return ctx.t("reset.none")
    }
    return span(Date.parse(limit.resetsAt) - now(), "reset")
  }

  const updated = () => {
    let latest = 0
    for (const account of accounts()) {
      if (account.checkedAt > latest) {
        latest = account.checkedAt
      }
    }
    if (now() - latest < MINUTE) {
      return ctx.t("updated.now")
    }
    return span(now() - latest, "updated")
  }

  const details = () => (
    <div class="claude-usage-details">
      <For each={accounts()}>
        {(account) => (
          <div class="claude-usage-card" data-stale={account.stale}>
            <div class="claude-usage-name">{account.email || account.dir}</div>
            <For each={shownLimits(account)}>
              {(limit) => (
                <div class="claude-usage-row">
                  <span class="claude-usage-label">{limitName(limit)}</span>
                  <span class="claude-usage-bar" data-level={level(percentNow(limit, now()))}>
                    <span style={{ width: `${percentNow(limit, now())}%` }} />
                  </span>
                  <span class="claude-usage-percent">{Math.round(percentNow(limit, now()))}%</span>
                  <span class="claude-usage-reset">{resetIn(limit)}</span>
                </div>
              )}
            </For>
            <Show when={account.stale && account.checkedAt > 0}>
              <div class="claude-usage-note">{span(now() - account.checkedAt, "stale")}</div>
            </Show>
          </div>
        )}
      </For>
      <div class="claude-usage-note">{updated()}</div>
    </div>
  )

  const button = () => (
    <ui.Button variant="ghost-muted" class="claude-usage-button" onClick={toggle}>
      <span class="claude-usage-meter" role="img" aria-label={ctx.t("title")}>
        <For each={accounts()}>
          {(account) => (
            <span class="claude-usage-account" data-stale={account.stale}>
              <Show when={summary(account, now()).hasSession}>
                <span class="claude-usage-bar" data-level={level(summary(account, now()).session)}>
                  <span style={{ width: `${summary(account, now()).session}%` }} />
                </span>
              </Show>
              <span class="claude-usage-bar" data-level={level(summary(account, now()).weekly)}>
                <span style={{ width: `${summary(account, now()).weekly}%` }} />
              </span>
            </span>
          )}
        </For>
      </span>
    </ui.Button>
  )

  return (
    <Show when={accounts().length > 0}>
      <span class="claude-usage-anchor" ref={anchor} data-open={open()}>
        {/* Hovering previews the details; once pinned, the tooltip would only repeat the card. */}
        <Show when={open()} fallback={<ui.Tooltip value={details()} placement="bottom">{button()}</ui.Tooltip>}>
          {button()}
        </Show>
      </span>
      <Show when={open()}>
        <Portal>
          <div
            class="claude-usage-popover"
            ref={card}
            style={{ top: `${position().top}px`, right: `${position().right}px` }}
          >
            {details()}
          </div>
        </Portal>
      </Show>
    </Show>
  )
}
