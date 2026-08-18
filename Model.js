.pragma library

// Pure formatting for the OpenRouter widget. Kept out of the QML so the
// wording and rounding rules are readable in one place.

// -1 is the widget's "OpenRouter did not say", which is not the same as zero
// credit left, and must never be drawn as a figure.
function known(value) {
  return typeof value === "number" && isFinite(value) && value >= 0
}

function group(digits) {
  return String(digits).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// Credits are dollars on OpenRouter, so they read as money.
function money(value, decimals) {
  if (typeof value !== "number" || !isFinite(value)) return "—"
  var places = decimals === undefined ? 2 : decimals
  var fixed = Math.abs(value).toFixed(places)
  var parts = fixed.split(".")
  parts[0] = group(parts[0])
  return (value < 0 ? "-$" : "$") + parts.join(".")
}

// The bar has room for a figure, not for a ledger: cents below a thousand,
// whole credits above it, and thousands once the account is large enough that
// the exact cent stopped being the point.
function compactMoney(value) {
  if (typeof value !== "number" || !isFinite(value)) return "—"
  var magnitude = Math.abs(value)
  if (magnitude >= 10000) return (value < 0 ? "-$" : "$") + (magnitude / 1000).toFixed(1) + "k"
  if (magnitude >= 1000) return money(value, 0)
  return money(value, 2)
}

function percent(ratio) {
  if (typeof ratio !== "number" || !isFinite(ratio) || ratio < 0) return "—"
  return Math.round(ratio * 100) + "%"
}

function resetPhrase(reset) {
  var value = String(reset || "").toLowerCase()
  if (value === "daily") return "resets daily"
  if (value === "weekly") return "resets weekly"
  if (value === "monthly") return "resets monthly"
  return ""
}

// What the headline figure actually is, so the panel never leaves the reader
// guessing whether they are looking at an account or a single key.
function sourceMeta(source, freeTier) {
  if (source === "account") return "Account balance"
  if (source === "key") return "Key spend cap"
  if (source === "usage") return freeTier ? "Free tier" : "Spend only"
  return "Not connected"
}

function balanceDetail(funded, spent) {
  if (!known(funded) || !known(spent)) return ""
  return "Spent " + money(spent) + " of " + money(funded) + " purchased"
}

// The primary caption under the balance meter once today's account-wide
// spend is known; balanceDetail is the fallback for keys that cannot read
// /activity, which is most of them.
function todaySpendDetail(spendToday) {
  if (!known(spendToday)) return ""
  return "Spent " + money(spendToday) + " today"
}

function capDetail(limit, remaining, reset) {
  if (!known(limit)) return ""
  var used = known(remaining) ? limit - remaining : -1
  var text = known(used) ? "Used " + money(used) + " of " + money(limit) : "Cap " + money(limit)
  var phrase = resetPhrase(reset)
  return phrase === "" ? text : text + " · " + phrase
}

function relativeAge(fetchedAtSeconds, nowMs) {
  if (!fetchedAtSeconds) return ""
  var seconds = Math.max(0, Math.round(nowMs / 1000 - fetchedAtSeconds))
  if (seconds < 45) return "just now"
  if (seconds < 90) return "1 min ago"
  if (seconds < 3600) return Math.round(seconds / 60) + " min ago"
  var hours = Math.round(seconds / 3600)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.round(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}

// Bar tooltip: the figure plus what it is a figure of. `hasRemaining` is
// passed rather than inferred, because an overspent account reports a
// negative balance and that is a figure worth showing.
function tooltip(source, remaining, hasRemaining, freeTier) {
  var label = sourceMeta(source, freeTier)
  if (!hasRemaining) return "OpenRouter · " + label
  return "OpenRouter · " + money(remaining) + " left · " + label.toLowerCase()
}

// Spend rows, skipping any window OpenRouter did not report rather than
// drawing it as $0.00 and claiming a quiet day. Today is not one of these
// rows: it already has its own line under the balance meter above.
function spendRows(weekly, monthly, allTime) {
  var rows = []
  if (known(weekly)) rows.push({ label: "This week", value: money(weekly) })
  if (known(monthly)) rows.push({ label: "This month", value: money(monthly) })
  if (known(allTime)) rows.push({ label: "All time", value: money(allTime) })
  return rows
}
