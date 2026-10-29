import QtQuick
import QtQuick.Effects
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui as UI

// Windscribe for the Omarchy bar: a status icon, and a popup to connect,
// pick a location, tune the connection, and manage split tunneling.
//
// Everything that touches Windscribe goes through backend.py, a small JSON
// adapter over windscribe-cli, so this file only draws state and sends
// intents. The layout follows the stock Network panel: hero, a stat grid,
// then lists, with the two settings pages one click away.
UI.Panel {
  id: root
  moduleName: "io.github.aryanhamedani.windscribe"
  ipcTarget: moduleName
  manageIpc: false

  // ---- State, as last reported by the backend.
  property var snapshot: ({ state: "unknown" })
  property var preferences: ({ domains: [], rangeCount: 0 })
  property var bypass: ({ country: "", updated: "" })
  property var locations: []
  property var presets: []
  property bool loaded: false

  property string page: "main"            // main | settings | bypass
  property string errorText: ""
  property string messageText: ""
  property bool confirmDisconnect: false
  property string pendingKind: ""         // what the running action is, for the hero
  property int cursor: -1                 // keyboard highlight in the location list

  readonly property string country: String(setting("bypassCountry", "IR")).toUpperCase()
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("backend.py").toString().replace(/^file:\/\//, ""))
  readonly property bool busy: actionProcess.running
  readonly property string vpnState: snapshot.state || "unknown"
  readonly property bool connected: vpnState === "connected" || vpnState === "testing"
  readonly property bool tunnelOn: connected || vpnState === "connecting"
  readonly property bool firewallOn: snapshot.firewall === "On" || snapshot.firewall === "Always On"

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent

  readonly property string statusLine: {
    if (pendingKind === "connect") return "CONNECTING…"
    if (pendingKind === "disconnect") return "DISCONNECTING…"
    switch (vpnState) {
      case "connected": return "CONNECTED" + (snapshot.nickname ? " · " + snapshot.nickname.toUpperCase() : "")
      case "testing": return "VERIFYING TUNNEL"
      case "connecting": return "CONNECTING…"
      case "blocked": return "OFF · TRAFFIC BLOCKED"
      case "disconnected": return "OFF · NOT PROTECTED"
      case "signedOut": return "SIGNED OUT"
    }
    return loaded ? "UNAVAILABLE" : "CHECKING…"
  }

  readonly property string protocolName: String(snapshot.protocol || "").split(":")[0]
  readonly property string protocolChoiceValue: preferences.ConnectionMode === "Auto"
    ? "Auto" : (preferences.ManualConnectionProtocol || "Auto")

  // Regions named in `pinnedRegions` (prefixes, so "US" pins all three US
  // regions) and the one you are connected to come first; the rest follow
  // alphabetically, as the CLI lists them.
  readonly property var pinnedRegions: {
    var list = setting("pinnedRegions", [])
    return Array.isArray(list) ? list.map(function(r) { return String(r).toLowerCase() }) : []
  }
  readonly property var filteredLocations: {
    var q = searchField.text.trim().toLowerCase()
    var current = root.connected ? String(root.snapshot.city || "") : ""
    var pinned = [], rest = []
    for (var i = 0; i < locations.length; i++) {
      var row = locations[i]
      if (q !== "" && (row.region + " " + row.city + " " + row.id).toLowerCase().indexOf(q) < 0) continue
      var region = row.region.toLowerCase()
      var isPinned = root.pinnedRegions.some(function(p) { return region.indexOf(p) === 0 })
      ;(isPinned ? pinned : rest).push(row)
    }
    var all = pinned.concat(rest)
    if (current === "") return all
    var currentRegion = (all.filter(function(r) { return r.city === current })[0] || {}).region
    return all.filter(function(r) { return r.region === currentRegion })
      .concat(all.filter(function(r) { return r.region !== currentRegion }))
  }

  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  // ---- Backend plumbing.
  function refresh() { if (!statusProcess.running) statusProcess.running = true }
  function loadCatalog() { if (!catalogProcess.running) catalogProcess.running = true }

  function perform(args, kind) {
    if (busy) return
    errorText = ""
    messageText = ""
    confirmDisconnect = false
    pendingKind = kind || ""
    actionProcess.command = ["python3", helper].concat(args)
    actionProcess.running = true
  }

  function connectTo(id) { perform(id ? ["connect", id] : ["connect"], "connect") }
  function disconnect() { perform(["disconnect"], "disconnect") }
  function setOption(key, value) { perform(["set", key, value]) }

  function toggleTunnel() {
    if (busy || vpnState === "unknown") return
    if (vpnState === "signedOut") return signIn()
    if (tunnelOn) {
      // From the bar's middle click too: the question needs the panel to be seen.
      if (!opened) open()
      page = "main"
      confirmDisconnect = true
    } else connectTo("")
  }

  function signIn() {
    if (bar) bar.run("omarchy-launch-floating-terminal-with-presentation windscribe-cli login")
    close()
  }

  function receive(text, kind) {
    var result
    try { result = JSON.parse(text) } catch (e) { result = { ok: false, error: "The Windscribe helper did not answer." } }
    if (kind === "status") {
      loaded = true
      if (!result.ok) {
        snapshot = { state: "unknown" }
        errorText = result.error
        return
      }
      snapshot = result.status
      preferences = result.settings
      bypass = result.bypass
      // A connect started here is done once the daemon stops reporting a transition.
      if (pendingKind !== "" && vpnState !== "connecting") pendingKind = ""
      // Dropdowns assign their value internally on pick; reconcile with what was saved.
      protocolChoice.value = root.protocolChoiceValue
      presetChoice.value = preferences.AmneziawgPreset || ""
    } else if (kind === "catalog") {
      if (result.ok) { locations = result.locations; presets = result.presets }
      else errorText = result.error
    } else {
      if (!result.ok) { errorText = result.error; pendingKind = "" }
      else { messageText = result.message || ""; messageTimer.restart() }
      refresh()
    }
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      loadCatalog()
    } else {
      confirmDisconnect = false
      errorText = ""
      page = "main"
      cursor = -1
    }
  }

  Timer {
    // The bar icon needs to know about a dropped tunnel without the popup open.
    interval: root.opened || root.pendingKind !== "" ? 2000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer { id: messageTimer; interval: 4000; onTriggered: root.messageText = "" }

  Process {
    id: statusProcess
    command: ["python3", root.helper, "status"]
    stdout: StdioCollector { onStreamFinished: root.receive(text, "status") }
  }

  Process {
    id: catalogProcess
    command: ["python3", root.helper, "catalog"]
    stdout: StdioCollector { onStreamFinished: root.receive(text, "catalog") }
  }

  Process {
    id: actionProcess
    stdout: StdioCollector { onStreamFinished: root.receive(text, "action") }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): void { root.connectTo("") }
    function disconnect(): void { root.disconnect() }
    function view(name: string): void {
      if (["main", "settings", "bypass"].indexOf(name) < 0) return
      root.open()
      root.page = name
    }
    function inspect(): string {
      return JSON.stringify({ page: root.page, opened: root.opened, state: root.vpnState,
        locations: root.locations.length, domains: (root.preferences.domains || []).length,
        error: root.errorText })
    }
  }

  // ---- Bar icon. Plain when protected, struck through when off, and in the
  //      urgent color when off with no firewall: traffic is going out bare.
  UI.BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Windscribe · " + root.statusLine.charAt(0) + root.statusLine.slice(1).toLowerCase()
      + (root.connected && root.snapshot.city ? "\n" + root.snapshot.city : "")
    iconComponent: Component {
      Item {
        BrandIcon {
          anchors.centerIn: parent
          size: Math.round(Style.bar.iconCanvas * 0.78)
          tint: root.vpnState === "disconnected" || root.vpnState === "signedOut" ? root.urgent : root.barForeground
          crossed: !root.tunnelOn && root.loaded
          SequentialAnimation on opacity {
            running: root.vpnState === "connecting" || root.pendingKind === "connect"
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
          }
        }
      }
    }
    onPressed: function(button) {
      if (button === Qt.MiddleButton) root.toggleTunnel()
      else root.toggle()
    }
  }

  UI.KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.page === "main" ? searchField : body
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    FocusScope {
      id: body
      anchors.fill: parent
      Keys.onEscapePressed: root.page !== "main" ? root.page = "main" : root.close()

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Connections { target: root; function onPageChanged() { scroller.contentY = 0 } }

        Column {
          id: content
          width: scroller.width
          spacing: Style.space(14)

          UI.PanelHero {
            title: root.connected && root.snapshot.city ? root.snapshot.city : "Windscribe"
            meta: root.statusLine
            detail: root.connected ? root.protocolName : ""
            foreground: root.fg
            fontFamily: root.fontFamily
            iconComponent: Component {
              BrandIcon {
                size: Style.font.display
                tint: root.connected ? Commons.Color.accent : root.fg
                crossed: !root.tunnelOn && root.loaded
                opacity: root.connected ? 1 : 0.6
              }
            }
            trailingControl: Component {
              UI.ToggleSwitch {
                id: tunnelSwitch
                checked: root.tunnelOn || root.pendingKind === "connect"
                busy: root.busy || root.vpnState === "connecting" || !root.loaded
                foreground: root.fg
                activeFocusOnTab: true
                onToggled: root.toggleTunnel()
                Keys.onSpacePressed: root.toggleTunnel()
                UI.PanelToolTip {
                  visible: tunnelSwitch.containsMouse
                  text: root.vpnState === "signedOut" ? "Sign in" : root.tunnelOn ? "Disconnect" : "Connect to your last location"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          // ---- One line of feedback: an error until the next action, a
          //      confirmation for a few seconds, or the disconnect question.
          Notice {
            visible: root.errorText !== ""
            tone: "error"
            text: root.errorText
          }

          Notice {
            visible: root.vpnState === "signedOut" && root.errorText === ""
            text: "Windscribe is signed out."
            actionText: "Sign in"
            onAction: root.signIn()
          }

          Notice {
            visible: root.confirmDisconnect
            tone: root.firewallOn ? "normal" : "error"
            text: root.firewallOn
              ? "The firewall stays on, so the internet is blocked until you connect again"
                + (root.preferences.AllowLANTraffic === "true" ? " (your LAN still works)." : ".")
              : "The firewall is off: your traffic will leave without the VPN."
            actionText: "Disconnect"
            secondaryText: "Cancel"
            onAction: root.disconnect()
            onSecondary: root.confirmDisconnect = false
          }

          Notice {
            visible: root.messageText !== "" && root.errorText === "" && !root.confirmDisconnect
            tone: "quiet"
            text: root.messageText
          }

          // ---- Main page.
          Column {
            visible: root.page === "main"
            width: parent.width
            spacing: Style.space(14)

            GridLayout {
              width: parent.width
              columns: 4
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

              InfoLabel { text: "VPN IP" }
              InfoValue {
                text: root.connected && root.snapshot.ip ? root.snapshot.ip : "--"
                copyable: root.connected && root.snapshot.ip !== ""
              }
              InfoLabel { text: "Data" }
              InfoValue { text: String(root.snapshot.usage || "--").split(" / ")[0] }

              InfoLabel { text: "Firewall" }
              InfoValue {
                text: root.snapshot.firewall || "--"
                color: root.firewallOn || !root.loaded ? root.fg : root.urgent
              }
              InfoLabel { text: "DNS" }
              InfoValue { text: root.preferences.ConnectedDNSMode === "Auto" ? "R.O.B.E.R.T." : (root.preferences.ConnectedDNSMode || "--") }

              InfoLabel { text: "LAN" }
              InfoValue { text: root.preferences.AllowLANTraffic === "true" ? "Allowed" : "Blocked" }
              InfoLabel { text: "Bypass" }
              InfoValue {
                text: root.preferences.SplitTunnelingEnabled === "true"
                  ? (root.bypass.country || root.country) + " · " + (root.preferences.domains || []).length + " hosts"
                  : "Off"
              }
            }

            UI.PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: locationsHeader.implicitHeight

              UI.PanelSectionHeader {
                id: locationsHeader
                text: "LOCATIONS"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: catalogProcess.running && root.locations.length === 0 ? "Loading…" : root.filteredLocations.length + " servers"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            UI.TextField {
              id: searchField
              width: parent.width
              placeholderText: "Search country, city or server"
              foreground: root.fg
              font.family: root.fontFamily
              onTextChanged: root.cursor = text === "" ? -1 : 0
              Keys.onPressed: function(event) {
                var count = root.filteredLocations.length
                if (event.key === Qt.Key_Down) {
                  root.cursor = Math.min(count - 1, root.cursor + 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.cursor = Math.max(-1, root.cursor - 1)
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (root.cursor >= 0 && root.cursor < count) root.connectTo(root.filteredLocations[root.cursor].id)
                  else if (text === "") root.connectTo("best")
                  event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  if (text !== "") text = ""
                  else root.close()
                  event.accepted = true
                }
              }
            }

            LocationRow {
              visible: searchField.text === ""
              width: parent.width
              title: "Best location"
              subtitle: "Fastest server for you right now"
              iconText: "󱐋"
              onActivated: root.connectTo("best")
            }

            ListView {
              id: locationList
              width: parent.width
              height: Math.min(contentHeight, Style.space(232))
              clip: true
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
              model: root.filteredLocations
              currentIndex: root.cursor
              onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

              delegate: Column {
                id: entry
                required property var modelData
                required property int index
                readonly property bool firstOfRegion: index === 0 || root.filteredLocations[index - 1].region !== modelData.region
                width: ListView.view.width
                spacing: Style.space(2)

                UI.PanelSectionHeader {
                  visible: entry.firstOfRegion
                  topPadding: entry.index === 0 ? 0 : Style.space(8)
                  text: entry.modelData.region.toUpperCase()
                  foreground: root.fg
                  fontFamily: root.fontFamily
                }

                LocationRow {
                  width: parent.width
                  title: entry.modelData.city
                  trailing: entry.modelData.id
                  current: root.connected && root.snapshot.nickname === entry.modelData.id
                  highlighted: root.cursor === entry.index
                  onActivated: root.connectTo(entry.modelData.id)
                  onHoveredChanged: if (hovered) root.cursor = entry.index
                }
              }
            }

            UI.PanelSeparator { width: parent.width; foreground: root.fg }

            Row {
              id: navRow
              width: parent.width
              spacing: Style.space(6)
              readonly property real cellWidth: (width - spacing) / 2

              UI.Button {
                width: navRow.cellWidth
                text: "Connection"
                iconText: "󰒓"
                bordered: true
                focusable: true
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.page = "settings"
              }

              UI.Button {
                width: navRow.cellWidth
                text: "Split tunneling"
                iconText: "󰕒"
                bordered: true
                focusable: true
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.page = "bypass"
              }
            }
          }

          // ---- Connection settings.
          Column {
            visible: root.page === "settings"
            width: parent.width
            spacing: Style.space(12)

            PageHeader { text: "CONNECTION" }

            Option { label: "Auto-connect"; description: "Connect at login, to your last location"; keyName: "Autoconnect" }

            UI.Dropdown {
              id: protocolChoice
              width: parent.width
              label: "Protocol (port 443)"
              value: root.protocolChoiceValue
              options: ["Auto", "WireGuard", "Stealth", "WStunnel", "UDP", "TCP"]
              enabled: !root.busy
              foreground: root.fg
              fontFamily: root.fontFamily
              onChanged: function(value) {
                if (value === "Auto") root.setOption("ConnectionMode", "Auto")
                else root.setOption("ManualConnectionProtocol", value)
              }
            }

            Caption {
              text: "Stealth and WStunnel wrap the tunnel in TLS or WebSockets. Try them when WireGuard is blocked."
            }

            UI.PanelSeparator { width: parent.width; foreground: root.fg }
            UI.PanelSectionHeader { text: "CENSORSHIP"; foreground: root.fg; fontFamily: root.fontFamily }

            Option { label: "Circumvent censorship"; description: "Disguise WireGuard as other traffic (AmneziaWG)"; keyName: "CircumventCensorship" }

            UI.Dropdown {
              id: presetChoice
              width: parent.width
              label: "AmneziaWG preset"
              value: root.preferences.AmneziawgPreset || ""
              options: root.presets
              enabled: !root.busy && root.presets.length > 0
              foreground: root.fg
              fontFamily: root.fontFamily
              onChanged: function(value) { root.perform(["preset", value]) }
            }

            UI.PanelSeparator { width: parent.width; foreground: root.fg }
            UI.PanelSectionHeader { text: "PROTECTION"; foreground: root.fg; fontFamily: root.fontFamily }

            Detail { label: "Firewall"; value: root.preferences.FirewallMode || "--" }
            Option { label: "Allow LAN traffic"; description: "Reach printers, NAS and other local devices"; keyName: "AllowLANTraffic" }

            UI.Button {
              width: parent.width
              text: "R.O.B.E.R.T. rules"
              iconText: "󰖟"
              tooltipText: "Opens your Windscribe account in the browser"
              bordered: true
              focusable: true
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: { Qt.openUrlExternally("https://windscribe.com/myaccount#robertrules"); root.close() }
            }

            Caption { text: "R.O.B.E.R.T. filters DNS for every site, bypassed or not. A site that resolves to 0.0.0.0 needs allowing there." }
          }

          // ---- Split tunneling.
          Column {
            visible: root.page === "bypass"
            width: parent.width
            spacing: Style.space(12)

            PageHeader { text: "SPLIT TUNNELING" }

            Option {
              label: "Bypass the VPN"
              description: "Traffic to " + (root.bypass.country || root.country) + " networks and the hostnames below goes out directly"
              keyName: "SplitTunnelingEnabled"
            }

            Notice {
              visible: root.preferences.SplitTunnelingMode !== "" && root.preferences.SplitTunnelingMode !== "Exclude"
              tone: "error"
              text: "Split tunneling is in " + root.preferences.SplitTunnelingMode + " mode; this list expects Exclude."
            }

            GridLayout {
              width: parent.width
              columns: 2
              rowSpacing: Style.spacing.labelGap
              InfoLabel { text: "Country"; Layout.fillWidth: true }
              InfoValue { text: root.bypass.country || root.country }
              InfoLabel { text: "Ranges" }
              InfoValue { text: String(root.preferences.rangeCount || 0) }
              InfoLabel { text: "Refreshed" }
              InfoValue { text: root.bypass.updated ? Qt.formatDateTime(new Date(root.bypass.updated), "d MMM yyyy, HH:mm") : "Not yet" }
            }

            UI.Button {
              width: parent.width
              text: root.busy && root.pendingKind === "ranges" ? "Fetching ranges…" : "Refresh " + root.country + " ranges now"
              iconText: "󰑐"
              iconSpinning: root.busy && root.pendingKind === "ranges"
              bordered: true
              focusable: true
              enabled: !root.busy
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.perform(["refresh-ranges", root.country], "ranges")
            }

            UI.PanelSeparator { width: parent.width; foreground: root.fg }

            Item {
              width: parent.width
              height: hostsHeader.implicitHeight
              UI.PanelSectionHeader { id: hostsHeader; text: "HOSTNAMES"; foreground: root.fg; fontFamily: root.fontFamily }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: (root.preferences.domains || []).length + " / 50"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)
              UI.TextField {
                id: domainInput
                Layout.fillWidth: true
                placeholderText: "app.example.ir"
                foreground: root.fg
                font.family: root.fontFamily
                onAccepted: addHost()
                function addHost() {
                  if (root.busy || text.trim() === "") return
                  root.perform(["domain", "add", text.trim()])
                  text = ""
                }
              }
              UI.Button {
                text: "Add"
                iconText: "󰐕"
                bordered: true
                focusable: true
                enabled: !root.busy && domainInput.text.trim() !== ""
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: domainInput.addHost()
              }
            }

            Caption { text: "Exact hostnames: www.example.ir and example.ir are separate entries. Use this for services hosted outside the country's ranges." }

            ListView {
              width: parent.width
              height: Math.min(contentHeight, Style.space(220))
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
              model: root.preferences.domains || []
              delegate: UI.CursorSurface {
                id: hostRow
                required property string modelData
                width: ListView.view.width
                implicitHeight: Style.spacing.controlHeight
                foreground: root.fg
                hasCursor: hostMouse.containsMouse
                MouseArea { id: hostMouse; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: removeButton.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: hostRow.modelData
                  textFormat: Text.PlainText
                  elide: Text.ElideMiddle
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                UI.PanelActionButton {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  opacity: hostMouse.containsMouse || removeHot ? 1 : 0.35
                  iconText: "󰅖"
                  tooltipText: "Remove " + hostRow.modelData
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  enabled: !root.busy
                  onClicked: root.perform(["domain", "remove", hostRow.modelData])
                  property bool removeHot: false
                  onHovered: function(on) { removeHot = on }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- Pieces.

  // The Windscribe mark, tinted to the theme, with the same strike-through
  // the stock Tailscale icon uses for "off".
  component BrandIcon: Item {
    id: brand
    property real size: Style.font.display
    property color tint: root.fg
    property bool crossed: false
    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    Image {
      id: mark
      anchors.fill: parent
      source: Qt.resolvedUrl("assets/windscribe.svg")
      sourceSize: Qt.size(Math.ceil(brand.size * 3), Math.ceil(brand.size * 3))
      fillMode: Image.PreserveAspectFit
      smooth: true
      visible: false
    }
    MultiEffect {
      anchors.fill: mark
      source: mark
      colorization: 1
      colorizationColor: brand.tint
    }
    Rectangle {
      visible: brand.crossed
      anchors.centerIn: parent
      width: parent.width * 1.2
      height: Math.max(2, parent.height * 0.12)
      radius: height / 2
      rotation: -45
      color: brand.tint
      border.width: Math.max(1, height * 0.35)
      border.color: root.bar ? root.bar.background : Commons.Color.background
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    id: value
    property bool copyable: false
    textFormat: Text.PlainText
    color: root.fg
    elide: Text.ElideRight
    horizontalAlignment: Text.AlignRight
    Layout.fillWidth: true
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall

    MouseArea {
      id: copyMouse
      anchors.fill: parent
      enabled: value.copyable
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: Quickshell.clipboardText = value.text
    }
    UI.PanelToolTip {
      visible: copyMouse.enabled && copyMouse.containsMouse
      text: "Copy to clipboard"
      fontFamily: root.fontFamily
    }
  }

  component Caption: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Detail: RowLayout {
    property string label: ""
    property string value: ""
    width: parent ? parent.width : implicitWidth
    InfoLabel { text: parent.label; Layout.fillWidth: true }
    InfoValue { text: parent.value; Layout.fillWidth: false }
  }

  component PageHeader: RowLayout {
    property string text: ""
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)
    UI.PanelActionButton {
      iconText: "󰁍"
      tooltipText: "Back (Esc)"
      focusable: true
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.page = "main"
    }
    UI.PanelSectionHeader {
      text: parent.text
      foreground: root.fg
      fontFamily: root.fontFamily
      Layout.fillWidth: true
    }
  }

  // A feedback strip: text, and up to two buttons beside it.
  component Notice: UI.CursorSurface {
    id: notice
    property string text: ""
    property string tone: "normal"   // normal | error | quiet
    property string actionText: ""
    property string secondaryText: ""
    signal action()
    signal secondary()
    readonly property color toneColor: tone === "error" ? root.urgent : root.fg

    width: parent ? parent.width : implicitWidth
    implicitHeight: noticeRow.implicitHeight + Style.space(16)
    foreground: notice.toneColor
    bordered: tone !== "quiet"
    color: tone === "quiet" ? "transparent" : Qt.rgba(toneColor.r, toneColor.g, toneColor.b, 0.07)

    RowLayout {
      id: noticeRow
      anchors.fill: parent
      anchors.margins: Style.space(8)
      anchors.leftMargin: notice.tone === "quiet" ? 0 : Style.space(10)
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        text: notice.text
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        maximumLineCount: 4
        elide: Text.ElideRight
        color: notice.tone === "quiet" ? root.dim : notice.toneColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      UI.Button {
        visible: notice.secondaryText !== ""
        text: notice.secondaryText
        focusable: true
        fontSize: Style.font.bodySmall
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: notice.secondary()
      }
      UI.Button {
        visible: notice.actionText !== ""
        text: notice.actionText
        bordered: true
        focusable: true
        fontSize: Style.font.bodySmall
        foreground: notice.toneColor
        fontFamily: root.fontFamily
        onClicked: notice.action()
      }
    }
  }

  component LocationRow: UI.CursorSurface {
    id: row
    property string title: ""
    property string subtitle: ""
    property string trailing: ""
    property string iconText: ""
    property bool highlighted: false
    readonly property bool hovered: rowMouse.containsMouse
    signal activated()

    implicitHeight: Math.max(Style.spacing.controlHeight, rowContent.implicitHeight + Style.space(10))
    foreground: root.fg
    hasCursor: highlighted || rowMouse.containsMouse

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: !root.busy
      onClicked: row.activated()
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        visible: row.iconText !== ""
        text: row.iconText
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        Layout.fillWidth: true
        spacing: Style.space(1)
        Text {
          width: parent.width
          text: row.title
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: row.current
        }
        Text {
          visible: row.subtitle !== ""
          width: parent.width
          text: row.subtitle
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        visible: text !== ""
        text: row.current ? "Connected" : row.trailing
        textFormat: Text.PlainText
        color: row.current ? root.fg : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // A labelled switch bound to one boolean in windscribe_cli.conf.
  component Option: Item {
    id: option
    property string keyName
    property string label
    property string description: ""
    width: parent ? parent.width : implicitWidth
    implicitHeight: optionRow.implicitHeight

    RowLayout {
      id: optionRow
      width: parent.width
      spacing: Style.space(12)
      Column {
        Layout.fillWidth: true
        spacing: Style.space(2)
        Text {
          width: parent.width
          text: option.label
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          visible: text !== ""
          width: parent.width
          text: option.description
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      UI.ToggleSwitch {
        checked: root.preferences[option.keyName] === "true"
        busy: root.busy
        foreground: root.fg
        activeFocusOnTab: true
        function flip() { if (!root.busy) root.setOption(option.keyName, checked ? "false" : "true") }
        onToggled: flip()
        Keys.onSpacePressed: flip()
        Keys.onReturnPressed: flip()
      }
    }
  }
}
