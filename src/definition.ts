import { Plugin } from "@opencode/plugin/gui"

export const definition = Plugin.define({
  i18n: {
    en: {
      title: "Claude usage",
      "limit.session": "5h",
      "limit.weekly": "7d",
      "reset.none": "·",
      "reset.minutes": "{{count}}m",
      "reset.hours": "{{count}}h",
      "reset.days": "{{count}}d",
      "stale.minutes": "Last checked {{count}}m ago",
      "stale.hours": "Last checked {{count}}h ago",
      "stale.days": "Last checked {{count}}d ago",
      "updated.now": "Updated just now",
      "updated.minutes": "Updated {{count}}m ago",
      "updated.hours": "Updated {{count}}h ago",
      "updated.days": "Updated {{count}}d ago",
    },
  },
})
