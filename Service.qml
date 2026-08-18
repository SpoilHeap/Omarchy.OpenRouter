import QtQuick
import Quickshell
import Quickshell.Io

// Runs credits.sh on a timer and holds whatever came back. The helper always
// exits 0 with JSON, so a failed fetch is a state to render rather than an
// error to swallow.
Item {
  id: root

  property var settings: ({})

  // -1 stands for "OpenRouter did not report this". Every figure below it is
  // one that cannot be negative in practice, so the sentinel is unambiguous.
  // `remaining` is the exception — an overspent account really can go below
  // zero — so its presence is tracked by hasRemaining instead.
  property bool ok: false
  property bool loaded: false
  property bool refreshing: false
  property string error: ""
  property string hint: ""
  property string accountError: ""
  property string keyError: ""
  property string activityError: ""
  property string source: "none"          // account | key | usage | none
  property real remaining: 0
  property bool hasRemaining: false
  property real funded: -1
  property real spent: -1
  property real keyLimit: -1
  property real keyLimitRemaining: -1
  property string keyLimitReset: ""
  property string keyLabel: ""
  property real keyUsage: -1
  property real spendToday: -1
  property real usageWeekly: -1
  property real usageMonthly: -1
  property bool freeTier: false
  property double fetchedAt: 0

  // Which of the four key sources answered. The panel shows this, because a
  // key saved to the file while an environment variable is exported would
  // otherwise look like it was ignored at random.
  property string keySource: ""
  property bool saving: false
  property string saveError: ""

  signal keySaved()

  readonly property string helperPath: String(Qt.resolvedUrl("credits.sh")).replace(/^file:\/\//, "")
  readonly property string saveHelperPath: String(Qt.resolvedUrl("save-key.sh")).replace(/^file:\/\//, "")

  readonly property bool keyFromFile: keySource.charAt(0) === "/"
  readonly property bool keyOverridden: keySource !== "" && !keyFromFile

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 60, 21600)
  readonly property real lowBalance: numSetting("lowBalance", 5, 0, 1000000)
  readonly property string keyCommand: String(setting("keyCommand", ""))

  readonly property bool alarming: hasRemaining && remaining <= lowBalance
  // Ratio of the balance still unspent, so the meter drains toward empty
  // rather than filling toward a cap.
  readonly property real fundedRatio: funded > 0 && hasRemaining ? clamp(remaining / funded, 0, 1) : -1
  readonly property real capRatio: keyLimit > 0 && keyLimitRemaining >= 0 ? clamp(keyLimitRemaining / keyLimit, 0, 1) : -1
  // How much of today's starting balance is left, so the meter moves day to
  // day instead of sitting pinned near-empty for the rest of a funded
  // account's life. Falls back to fundedRatio when /activity could not be
  // read (spendToday unknown), which is the common case for a key that is
  // not itself a management key.
  readonly property real todayRatio: hasRemaining && spendToday >= 0 ? clamp(remaining / (remaining + spendToday), 0, 1) : -1

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function numSetting(name, fallback, min, max) {
    var value = parseFloat(String(setting(name, fallback)))
    if (!isFinite(value)) value = fallback
    return clamp(value, min, max)
  }

  function intSetting(name, fallback, min, max) {
    return Math.round(numSetting(name, fallback, min, max))
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value))
  }

  // The key goes to the helper over stdin, never argv, so it stays out of `ps`.
  function saveKey(key) {
    var trimmed = String(key || "").replace(/\s/g, "")
    if (trimmed === "" || saving || saveHelperPath === "") return
    saveError = ""
    saving = true
    saveProc.pendingKey = trimmed
    saveProc.command = ["bash", saveHelperPath]
    saveProc.running = true
  }

  function refresh() {
    if (proc.running || helperPath === "") return
    refreshing = true
    proc.command = ["bash", helperPath, keyCommand]
    proc.running = true
  }

  // Absent and null both mean unreported; anything else has to parse as a
  // finite number before it is allowed to become a figure on screen.
  function num(value) {
    if (value === null || value === undefined) return -1
    var parsed = Number(value)
    return isFinite(parsed) ? parsed : -1
  }

  function apply(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      parsed = null
    }

    loaded = true

    if (!parsed || typeof parsed !== "object") {
      ok = false
      error = "Could not read the OpenRouter helper output"
      hint = ""
      return
    }

    ok = parsed.ok === true
    keySource = String(parsed.keySource || "")
    error = String(parsed.error || "")
    hint = String(parsed.hint || "")
    accountError = String(parsed.accountError || "")
    keyError = String(parsed.keyError || "")
    activityError = String(parsed.activityError || "")
    source = String(parsed.source || "none")

    hasRemaining = parsed.remaining !== null && parsed.remaining !== undefined
      && isFinite(Number(parsed.remaining))
    remaining = hasRemaining ? Number(parsed.remaining) : 0

    funded = num(parsed.funded)
    spent = num(parsed.spent)
    keyLimit = num(parsed.keyLimit)
    keyLimitRemaining = num(parsed.keyLimitRemaining)
    keyLimitReset = String(parsed.keyLimitReset || "")
    keyLabel = String(parsed.keyLabel || "")
    keyUsage = num(parsed.keyUsage)
    spendToday = num(parsed.spendToday)
    usageWeekly = num(parsed.usageWeekly)
    usageMonthly = num(parsed.usageMonthly)
    freeTier = parsed.freeTier === true
    fetchedAt = Number(parsed.fetchedAt || 0)
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: saveProc
    property string pendingKey: ""
    running: false
    command: []
    stdinEnabled: true
    onStarted: {
      write(pendingKey + "\n")
      pendingKey = ""
    }
    stdout: StdioCollector { id: saveOut; waitForEnd: true }
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.saving = false
      var parsed = null
      try {
        parsed = JSON.parse(String(saveOut.text || ""))
      } catch (e) {
        parsed = null
      }
      if (parsed && parsed.ok === true) {
        root.saveError = ""
        root.keySaved()
        root.refresh()
        return
      }
      root.saveError = (parsed && parsed.error ? String(parsed.error) : String(saveErr.text || "").trim())
        || "Could not save the key"
    }
  }

  Process {
    id: proc
    running: false
    command: []
    stdout: StdioCollector { id: helperOut; waitForEnd: true }
    stderr: StdioCollector { id: helperErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) {
        root.apply(helperOut.text)
        return
      }
      // The helper exits 0 even when OpenRouter refuses, so a non-zero exit
      // means the helper itself could not run.
      root.loaded = true
      root.ok = false
      root.hint = ""
      root.error = String(helperErr.text || "").trim() || "The OpenRouter helper could not run"
    }
  }
}
