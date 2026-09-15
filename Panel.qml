import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar dot + popup for up to 10 IP-monitored servers. Green when every
// configured server answers a ping, red when one or more don't. Click opens a
// panel with the live status list on top and the 10-slot name/IP editor below
// it. A blank IP means "not configured" and is skipped by both the list and
// the checker, per spec.
Panel {
  id: root
  moduleName: "iserrano.uptime-monitor"
  ipcTarget: "iserrano.uptime-monitor"

  readonly property color upColor: "#3fb950"
  readonly property color downColor: root.bar ? root.bar.urgent : Color.urgent
  readonly property color unknownColor: Color.muted

  readonly property int checkIntervalMs: 30 * 60 * 1000
  readonly property int pingTimeoutSec: 2

  // "list" = main page (status list), "settings" = the 10-slot editor behind
  // the gear icon. Always reopens on "list" — see onOpenedChanged below.
  property string page: "list"

  // Saved config, always 10 entries (Model.normalizeServers pads/truncates).
  property var servers: Model.normalizeServers([])
  // Per-slot result: null = not configured / not checked yet, true = up,
  // false = down. Indexes line up 1:1 with `servers`.
  property var status: Model.emptyStatuses()

  readonly property var configuredIdx: Model.configuredIndexes(servers)
  readonly property bool hasServers: configuredIdx.length > 0
  readonly property bool anyDown: {
    for (var i = 0; i < configuredIdx.length; i++) {
      if (status[configuredIdx[i]] === false) return true
    }
    return false
  }
  readonly property bool haveResult: {
    for (var i = 0; i < configuredIdx.length; i++) {
      if (status[configuredIdx[i]] !== null) return true
    }
    return false
  }
  // Grey until there's something to show, green once everything monitored
  // answers, red the moment anything doesn't.
  readonly property color dotColor: (!hasServers || !haveResult) ? unknownColor : (anyDown ? downColor : upColor)
  readonly property bool checking: check0.running || check1.running || check2.running || check3.running || check4.running
    || check5.running || check6.running || check7.running || check8.running || check9.running

  // ---- editable form buffers, separate from `servers` so typing doesn't
  // reformat mid-edit or get clobbered by an external file reload ----
  property var formName: Model.emptyStrings()
  property var formIp: Model.emptyStrings()
  property bool dirty: false
  property string saveMessage: ""

  function loadFormFromServers() {
    var names = [], ips = []
    for (var i = 0; i < Model.MAX_SERVERS; i++) {
      names.push(servers[i] ? servers[i].name : "")
      ips.push(servers[i] ? servers[i].ip : "")
    }
    formName = names
    formIp = ips
    dirty = false
  }

  function setFormName(i, value) {
    var next = formName.slice()
    next[i] = value
    formName = next
    dirty = true
    saveMessage = ""
  }

  function setFormIp(i, value) {
    var next = formIp.slice()
    next[i] = value
    formIp = next
    dirty = true
    saveMessage = ""
  }

  function saveServers() {
    var next = []
    for (var i = 0; i < Model.MAX_SERVERS; i++) next.push({ name: formName[i], ip: formIp[i] })
    root.applyServers(next)
    serversFile.setText(Model.serversToFileText(root.servers))
    root.dirty = false
    root.saveMessage = "Saved."
    saveMessageTimer.restart()
    root.runChecks()
  }

  // Reset results when a slot changes so a newly entered server never inherits
  // the previous server's state or alert-suppression state.
  function applyServers(nextServers) {
    var normalized = Model.normalizeServers(nextServers)
    var nextStatus = status.slice()
    for (var i = 0; i < Model.MAX_SERVERS; i++) {
      var oldIp = servers[i] ? servers[i].ip : ""
      if (oldIp !== normalized[i].ip) nextStatus[i] = null
    }
    servers = normalized
    status = nextStatus
  }

  // Pick up any hand-edits to the state file the moment the popup opens, as
  // long as the user isn't mid-edit in the form, and always land back on the
  // status list rather than reopening wherever it was left.
  onOpenedChanged: {
    if (!opened) return
    root.page = "list"
    if (!dirty) loadFormFromServers()
  }

  Timer {
    id: saveMessageTimer
    interval: 2500
    onTriggered: root.saveMessage = ""
  }

  FileView {
    id: serversFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/uptime-monitor.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.applyServers(Model.parseServersFile(text()))
      if (!root.dirty) root.loadFormFromServers()
      root.runChecks()
    }
    onLoadFailed: {
      root.applyServers([])
      if (!root.dirty) root.loadFormFromServers()
    }
    onFileChanged: reload()
  }

  // Belt-and-suspenders: make sure the settings dir exists before the first
  // save, in case nothing else under ~/.local/state/omarchy has created it.
  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy/settings"]
  }

  Component.onCompleted: {
    ensureDirProc.running = true
    serversFile.reload()
  }

  function statusColorFor(i) {
    var s = status[i]
    if (s === true) return upColor
    if (s === false) return downColor
    return unknownColor
  }

  function statusTextFor(i) {
    var s = status[i]
    if (s === true) return "Up"
    if (s === false) return "Down"
    return "Checking…"
  }

  function setStatus(i, up) {
    var next = status.slice()
    next[i] = up
    status = next
  }

  function notifyServerDown(name, ip) {
    var when = Qt.formatDateTime(new Date(), "yyyy-MM-dd HH:mm:ss")
    var headline = "Server down: " + (name || ip)
    var body = "IP: " + ip + "\nDate and time: " + when
    try {
      Quickshell.execDetached([
        "/usr/bin/omarchy-notification-send",
        "--app-name", "my-servers-uptime-monitor",
        "-u", "critical",
        headline,
        body
      ])
    } catch (e) {
      // Monitoring must continue even if desktop notification delivery fails.
    }
  }

  function handleCheckExit(i, exitCode, checkedName, checkedIp) {
    // A settings reload can change a slot while its old ping is still running.
    // Ignore that stale result and immediately check the replacement target.
    var current = root.servers[i]
    if (!current || current.ip !== checkedIp) {
      root.setStatus(i, null)
      Qt.callLater(root.runChecks)
      return
    }

    var wasDown = root.status[i] === false
    var isUp = exitCode === 0
    root.setStatus(i, isUp)
    // Notify once when an outage is first detected. A recovery resets the
    // state, so a later outage generates a fresh notification without sending
    // the same alert every 30 minutes while the server remains down.
    if (!isUp && !wasDown) root.notifyServerDown(checkedName, checkedIp)
  }

  // Fixed 1-Process-per-slot pool: the 10-server cap means no dynamic Process
  // creation is needed, and each slot's check can't stomp on another's.
  function processFor(i) {
    switch (i) {
      case 0: return check0
      case 1: return check1
      case 2: return check2
      case 3: return check3
      case 4: return check4
      case 5: return check5
      case 6: return check6
      case 7: return check7
      case 8: return check8
      default: return check9
    }
  }

  function runChecks() {
    for (var i = 0; i < Model.MAX_SERVERS; i++) {
      var server = root.servers[i]
      if (!Model.isConfigured(server)) {
        root.setStatus(i, null)
        continue
      }
      var proc = processFor(i)
      if (proc.running) continue
      proc.checkedName = Model.displayName(server)
      proc.checkedIp = server.ip
      proc.command = ["ping", "-c", "1", "-W", String(root.pingTimeoutSec), server.ip]
      proc.running = true
    }
  }

  Process {
    id: check0
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(0, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check1
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(1, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check2
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(2, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check3
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(3, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check4
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(4, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check5
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(5, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check6
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(6, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check7
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(7, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check8
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(8, exitCode, checkedName, checkedIp) }
  }
  Process {
    id: check9
    property string checkedName: ""
    property string checkedIp: ""
    onExited: function(exitCode) { root.handleCheckExit(9, exitCode, checkedName, checkedIp) }
  }

  Timer {
    interval: root.checkIntervalMs
    running: true
    repeat: true
    onTriggered: root.runChecks()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    tooltipText: !root.hasServers ? "My Servers Uptime Monitor — no servers configured"
      : (root.anyDown ? "My Servers Uptime Monitor — some servers are down" : "My Servers Uptime Monitor — all servers up")
    iconComponent: dotComponent
    onPressed: function(b) { root.toggle() }
  }

  Component {
    id: dotComponent
    Rectangle {
      anchors.centerIn: parent
      width: Math.max(7, Math.round(Style.font.body * 0.6))
      height: width
      radius: width / 2
      color: root.dotColor
      border.width: 1
      border.color: Qt.rgba(0, 0, 0, 0.35)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    // Just enough keyboard handling to close with Escape. Deliberately not
    // PanelKeyCatcher: its j/k/h/l/Tab/Space capture (Keys.priority
    // BeforeItem) would steal cursor movement and Tab-between-fields from
    // the TextFields below, and this panel has no list to navigate anyway.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(14)

          // ==================== List page ====================
          Column {
            width: column.width
            spacing: Style.space(14)
            visible: root.page === "list"

            RowLayout {
              width: parent.width
              spacing: Style.space(12)

              Rectangle {
                Layout.alignment: Qt.AlignVCenter
                width: Style.space(16)
                height: width
                radius: width / 2
                color: root.dotColor
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: Style.space(2)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: "My Servers Uptime Monitor"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: !root.hasServers ? "No servers configured"
                    : (!root.haveResult ? "Checking…" : (root.anyDown ? "Some servers are down" : "All servers up"))
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Button {
                Layout.alignment: Qt.AlignVCenter
                iconText: "⚙"
                tooltipText: "Configure servers"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                iconSize: Style.font.subtitle * 1.3
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(3)
                onClicked: root.page = "settings"
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            PanelSectionHeader {
              text: "MONITORED SERVERS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              visible: !root.hasServers
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "No servers yet — tap the gear above to add up to 10."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Repeater {
              model: root.configuredIdx

              delegate: Item {
                id: serverRowItem
                required property int modelData
                width: column.width
                implicitHeight: serverRow.implicitHeight

                Row {
                  id: serverRow
                  width: parent.width
                  spacing: Style.space(10)

                  Rectangle {
                    width: Style.space(9)
                    height: width
                    radius: width / 2
                    color: root.statusColorFor(serverRowItem.modelData)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    width: parent.width - Style.space(9) - Style.space(10) - statusLabel.implicitWidth - Style.space(10)
                    spacing: Style.space(1)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      elide: Text.ElideRight
                      text: Model.displayName(root.servers[serverRowItem.modelData])
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      elide: Text.ElideRight
                      text: root.servers[serverRowItem.modelData].ip
                      color: Qt.darker(root.bar.foreground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    id: statusLabel
                    textFormat: Text.PlainText
                    text: root.statusTextFor(serverRowItem.modelData)
                    color: root.statusColorFor(serverRowItem.modelData)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }

            Row {
              visible: root.hasServers
              spacing: Style.space(10)

              Button {
                text: root.checking ? "Checking…" : "Check now"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.runChecks()
              }
              Text {
                textFormat: Text.PlainText
                text: "Checks automatically every 30 min."
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item { width: 1; height: Style.space(4) }
          }

          // ==================== Settings page ====================
          Column {
            width: column.width
            spacing: Style.space(14)
            visible: root.page === "settings"

            RowLayout {
              width: parent.width
              spacing: Style.space(10)

              Button {
                Layout.alignment: Qt.AlignVCenter
                iconText: "←"
                tooltipText: "Back"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                iconSize: Style.font.subtitle * 1.3
                horizontalPadding: Style.space(6)
                verticalPadding: Style.space(3)
                onClicked: root.page = "list"
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: "Configure Servers"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            PanelSeparator { foreground: root.bar.foreground }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              text: "Up to 10 servers. Leave a slot's IP blank to skip it."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Repeater {
              model: Model.MAX_SERVERS

              delegate: Column {
                id: slotColumn
                required property int index
                width: column.width
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Server " + (slotColumn.index + 1)
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  TextField {
                    width: Math.round((parent.width - Style.space(8)) * 0.42)
                    placeholderText: "Server name"
                    text: root.formName[slotColumn.index]
                    foreground: root.bar.foreground
                    onTextChanged: if (text !== root.formName[slotColumn.index]) root.setFormName(slotColumn.index, text)
                  }
                  TextField {
                    width: Math.round((parent.width - Style.space(8)) * 0.58)
                    placeholderText: "IP address"
                    text: root.formIp[slotColumn.index]
                    foreground: root.bar.foreground
                    onTextChanged: if (text !== root.formIp[slotColumn.index]) root.setFormIp(slotColumn.index, text)
                  }
                }
              }
            }

            Row {
              spacing: Style.space(10)

              Button {
                text: "Save"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                onClicked: root.saveServers()
              }
              Text {
                textFormat: Text.PlainText
                visible: root.saveMessage !== ""
                text: root.saveMessage
                color: root.upColor
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Item { width: 1; height: Style.space(4) }
          }
        }
      }
    }
  }
}
