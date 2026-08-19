import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OpenRouter credit in the bar, with the ledger behind it in a popup.
//
// The bar answers one question — how much is left — and the panel answers the
// follow-ups: what was purchased against it, what this key is capped at, and
// what has been spent today, this week, and this month.
Panel {
  id: root
  moduleName: "io.github.spoilheap.openrouter"
  ipcTarget: "io.github.spoilheap.openrouter"
  manageIpc: false

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Util.alpha(foreground, 0.16)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Nerd Font marks, written as escapes rather than pasted glyphs. These
  // live in the private-use planes, where a mangled copy renders as a
  // notdef box instead of failing loudly; the escape cannot be mangled.
  readonly property string glyph: "\uf09d"          // nf-fa-credit_card
  readonly property string glyphRefresh: "\uf021"   // nf-fa-refresh
  readonly property string glyphPlus: "\uf067"      // nf-fa-plus
  readonly property string glyphChart: "\uf201"     // nf-fa-line_chart
  readonly property string glyphKey: "\uf084"       // nf-fa-key
  readonly property string glyphEye: "\uf06e"       // nf-fa-eye
  readonly property string glyphEyeOff: "\uf070"    // nf-fa-eye_slash
  readonly property string glyphSave: "\uf00c"      // nf-fa-check
  readonly property string glyphCancel: "\uf00d"    // nf-fa-close

  // A vertical bar has no room for a figure, so it falls back to the icon the
  // same way the media and clock widgets do.
  readonly property bool iconOnly: vertical || String(setting("barLabel", "Amount")) === "Icon only"
  readonly property string figure: service.hasRemaining ? Model.compactMoney(service.remaining) : "—"
  // Two spaces, not one: the Nerd Font icon variants are double-width and
  // a single space leaves the figure touching the mark.
  readonly property string barText: iconOnly ? glyph : glyph + "  " + figure
  readonly property bool barAlarming: service.alarming
  readonly property bool barDimmed: !service.ok && service.loaded

  property bool cursorActive: false
  property int rowIndex: 0

  property bool keyEditing: false
  property bool keyRevealed: false

  // With no key at all there is nothing else the panel could usefully show,
  // so the field is the panel. A key that exists but was refused keeps the
  // reason on screen and offers the field as a row instead, so a transient
  // network failure does not nag for a key that is already correct.
  readonly property bool formVisible: keyEditing || (service.loaded && service.keySource === "")

  readonly property string keyFormHint: {
    if (service.saveError !== "") return service.saveError
    if (service.keyOverridden)
      return service.keySource + " is set and takes precedence over the key file, so a key saved here will not be used until that is unset."
    return "Saved to ~/.config/omarchy/openrouter/key, readable only by you."
  }
  readonly property bool keyFormHintIsError: service.saveError !== "" || service.keyOverridden

  // Where a click goes next. Signed in, that is topping up or reading the
  // activity log; signed out, the only useful move is minting a key.
  readonly property var actionRows: {
    var mint = { key: "mint", icon: root.glyphKey, title: "Create an API key",
      subtitle: "openrouter.ai/settings/keys", url: "https://openrouter.ai/settings/keys" }
    // While the field is up the only other row worth keeping is the one that
    // gets you a key to paste into it.
    if (formVisible) return service.ok ? [] : [mint]
    if (service.ok) return [
      { key: "topup", icon: root.glyphPlus, title: "Add credits",
        subtitle: "openrouter.ai/credits", url: "https://openrouter.ai/credits" },
      { key: "activity", icon: root.glyphChart, title: "Activity",
        subtitle: "Requests, spend, and models by day", url: "https://openrouter.ai/activity" },
      { key: "rekey", icon: root.glyphKey, title: "Replace API key",
        subtitle: service.keyFromFile ? "Paste a new key" : "Currently from " + service.keySource, edit: true }
    ]
    return [
      mint,
      { key: "enter", icon: root.glyphSave, title: "Enter API key", subtitle: "Paste it into the panel", edit: true }
    ]
  }

  // All-time spend: the account ledger when it is readable, else whatever
  // this one key has itself spent over its lifetime.
  readonly property real spendAllTime: Model.known(service.spent) ? service.spent : service.keyUsage
  readonly property var spendRows: Model.spendRows(service.usageWeekly, service.usageMonthly, root.spendAllTime)
  // Week/month need /activity, which needs a management key; most single
  // inference keys are not one, so this note is the common case, not the rare one.
  readonly property string spendHint: service.ok && service.activityError !== ""
    ? "Week and month need a management key · openrouter.ai/settings/management-keys" : ""

  readonly property string heroMeta: Model.sourceMeta(service.source, service.freeTier)
  readonly property string footerText: {
    if (!service.ok) return ""
    var age = Model.relativeAge(service.fetchedAt, tick.date.getTime())
    var label = service.keyLabel
    if (age === "" && label === "") return ""
    if (label === "") return "Updated " + age
    if (age === "") return label
    return "Updated " + age + " · " + label
  }

  // The account ledger needs a management key; an inference key gets a 403
  // there and still has plenty to say, so that refusal is a note rather than
  // an error.
  readonly property string noticeText: {
    if (service.error !== "") return service.error
    if (service.source === "usage") return "This key has no spend cap, and reading the account balance needs a management key."
    return ""
  }
  readonly property bool noticeIsError: service.error !== ""

  function refresh() {
    service.refresh()
  }

  function focusPanel() {
    if (formVisible) keyField.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function startKeyEdit() {
    service.saveError = ""
    keyRevealed = false
    keyEditing = true
    Qt.callLater(function() {
      keyField.text = ""
      root.focusPanel()
    })
  }

  function cancelKeyEdit() {
    keyEditing = false
    keyRevealed = false
    keyField.text = ""
    service.saveError = ""
    Qt.callLater(root.focusPanel)
  }

  function commitKey() {
    if (keyField.text.replace(/\s/g, "") === "") return
    service.saveKey(keyField.text)
    keyField.text = ""
  }

  function openUrl(url) {
    if (!url) return
    Qt.openUrlExternally(String(url))
    close()
  }

  function selectedRow() {
    if (actionRows.length === 0) return null
    return actionRows[Math.max(0, Math.min(rowIndex, actionRows.length - 1))]
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || actionRows.length === 0) return
    rowIndex = Math.max(0, Math.min(actionRows.length - 1, rowIndex + dy))
  }

  function activateRow(row) {
    if (!row) return
    if (row.edit === true) startKeyEdit()
    else openUrl(row.url)
  }

  function activateCursor() {
    activateRow(selectedRow())
  }

  function setRowCursor(index) {
    cursorActive = true
    rowIndex = index
  }

  // Left click is the panel, right click a refresh without opening anything,
  // middle click the top-up page — the one action worth reaching without
  // reading the panel first.
  function pressed(button) {
    if (button === Qt.RightButton) refresh()
    else if (button === Qt.MiddleButton) Qt.openUrlExternally("https://openrouter.ai/credits")
    else toggle()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property real openPanelIndicatorWidth: button.labelWidth

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = 0
    keyEditing = false
    keyRevealed = false
    if (panelFlick) panelFlick.contentY = 0
    service.refresh()
    Qt.callLater(root.focusPanel)
  }

  onFormVisibleChanged: if (opened) Qt.callLater(root.focusPanel)

  Service {
    id: service
    settings: root.settings
  }

  Connections {
    target: service
    function onKeySaved() {
      root.keyEditing = false
      root.keyRevealed = false
      Qt.callLater(root.focusPanel)
    }
  }

  SystemClock {
    id: tick
    precision: SystemClock.Minutes
    enabled: root.opened
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function remaining(): string {
      return service.hasRemaining ? Model.money(service.remaining) : "unknown"
    }
    function status(): string {
      if (!service.loaded) return "loading"
      if (!service.ok) return service.error
      return Model.sourceMeta(service.source, service.freeTier) + ": "
        + (service.hasRemaining ? Model.money(service.remaining) : "unknown")
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    fontSize: root.iconOnly ? Style.bar.iconFont : Style.font.body
    active: root.barAlarming
    dimmed: root.barDimmed
    horizontalMargin: 8.5
    tooltipText: Model.tooltip(service.source, service.remaining, service.hasRemaining, service.freeTier)
    onPressed: function(code) { root.pressed(code) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Typing a key must not be read as panel navigation: j, k, r and t are
      // all plausible characters inside a secret.
      blocked: keyField.activeFocus || service.saving
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.cursorActive) root.activateCursor()
        else root.refresh()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "r") root.refresh()
        else if (key === "t") root.openUrl("https://openrouter.ai/credits")
        else if (key === "a") root.openUrl("https://openrouter.ai/activity")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "OpenRouter"
            meta: root.heroMeta
            detail: service.hasRemaining ? Model.money(service.remaining) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: root.glyph
                textFormat: Text.PlainText
                color: service.alarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                id: refreshButton
                iconText: root.glyphRefresh
                tooltipText: "Refresh"
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                enabled: !service.refreshing
                onClicked: root.refresh()

                RotationAnimation on rotation {
                  running: service.refreshing
                  loops: Animation.Infinite
                  from: 0
                  to: 360
                  duration: 900
                  onRunningChanged: if (!running) refreshButton.rotation = 0
                }
              }
            }
          }

          Text {
            visible: root.noticeText !== ""
            width: parent.width
            text: root.noticeText
            textFormat: Text.PlainText
            color: root.noticeIsError ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: service.hint !== ""
            width: parent.width
            text: service.hint
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Balance ----------
          PanelSeparator {
            visible: balanceSection.visible || capSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: service.ok && service.source === "account"
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            LedgerRow {
              width: parent.width
              label: "Balance remaining"
              value: service.hasRemaining ? Model.money(service.remaining) : "—"
              alarming: service.alarming
            }

            Meter {
              visible: service.todayRatio >= 0 || service.fundedRatio >= 0
              width: parent.width
              value: service.todayRatio >= 0 ? service.todayRatio : service.fundedRatio
              alarming: service.alarming
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: service.todayRatio >= 0 ? Model.todaySpendDetail(service.spendToday)
                : Model.balanceDetail(service.funded, service.spent)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Key cap ----------
          Column {
            id: capSection
            visible: service.ok && service.keyLimit > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              width: parent.width
              text: "KEY CAP"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            LedgerRow {
              width: parent.width
              label: "Cap remaining"
              value: service.keyLimitRemaining >= 0 ? Model.money(service.keyLimitRemaining) : "—"
              alarming: service.capRatio >= 0 && service.capRatio <= 0.1
            }

            Meter {
              visible: service.capRatio >= 0
              width: parent.width
              value: service.capRatio
              alarming: service.capRatio <= 0.1
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: Model.capDetail(service.keyLimit, service.keyLimitRemaining, service.keyLimitReset)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Spend ----------
          PanelSeparator {
            visible: spendSection.visible
            foreground: root.foreground
          }

          Column {
            id: spendSection
            visible: service.ok && (root.spendRows.length > 0 || root.spendHint !== "")
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              width: parent.width
              text: "SPEND"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: root.spendRows

              LedgerRow {
                required property var modelData
                width: spendSection.width
                label: modelData.label
                value: modelData.value
              }
            }

            Text {
              visible: text !== ""
              width: spendSection.width
              text: root.spendHint
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- API key ----------
          PanelSeparator {
            visible: keyForm.visible
            foreground: root.foreground
          }

          Column {
            id: keyForm
            visible: root.formVisible
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: service.keySource === "" ? "API KEY" : "REPLACE API KEY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: keyField
                Layout.fillWidth: true
                // readOnly, not disabled: disabling drops activeFocus, which
                // unblocks the key catcher mid-save and lets the Return that
                // started the save land on the panel behind the field.
                readOnly: service.saving
                password: !root.keyRevealed
                placeholderText: "sk-or-v1-\u2026"
                foreground: root.foreground
                font.family: root.fontFamily

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitKey()
                    event.accepted = true
                    return
                  }
                  if (event.key === Qt.Key_Escape) {
                    // With no key on file the field cannot be dismissed, so
                    // Escape keeps its usual meaning and closes the panel.
                    if (service.keySource === "") root.close()
                    else root.cancelKeyEdit()
                    event.accepted = true
                  }
                }
              }

              PanelActionButton {
                iconText: root.keyRevealed ? root.glyphEyeOff : root.glyphEye
                tooltipText: root.keyRevealed ? "Hide the key" : "Show the key"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.keyRevealed = !root.keyRevealed
              }

              PanelActionButton {
                iconText: root.glyphSave
                tooltipText: "Save the key"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !service.saving && keyField.text.replace(/\s/g, "") !== ""
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.commitKey()
              }

              PanelActionButton {
                visible: service.keySource !== ""
                iconText: root.glyphCancel
                tooltipText: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.cancelKeyEdit()
              }
            }

            Text {
              width: parent.width
              text: service.saving ? "Saving\u2026" : root.keyFormHint
              textFormat: Text.PlainText
              color: !service.saving && root.keyFormHintIsError ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Actions ----------
          PanelSeparator {
            visible: actionColumn.visible
            foreground: root.foreground
          }

          Column {
            id: actionColumn
            visible: root.actionRows.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.actionRows

              ActionRow {
                required property var modelData
                required property int index
                width: actionColumn.width
                row: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // Label on the left, figure on the right, with the gap between them doing
  // the aligning so the figures line up down the panel.
  component LedgerRow: Item {
    id: ledgerRow
    property string label: ""
    property string value: ""
    property bool alarming: false

    implicitHeight: Math.max(ledgerLabel.implicitHeight, ledgerValue.implicitHeight)

    Text {
      id: ledgerLabel
      text: ledgerRow.label
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.right: ledgerValue.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: ledgerValue
      text: ledgerRow.value
      textFormat: Text.PlainText
      color: ledgerRow.alarming ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Rounded track showing how much of the allowance is still there.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * Math.max(0, Math.min(1, meter.value))
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var row: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.rowIndex === rowIndex
    foreground: root.foreground

    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setRowCursor(actionRow.rowIndex)
      onClicked: root.activateRow(actionRow.row)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: actionRow.row ? String(actionRow.row.icon) : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: actionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: actionRow.row ? String(actionRow.row.title) : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: actionRow.row ? String(actionRow.row.subtitle) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
