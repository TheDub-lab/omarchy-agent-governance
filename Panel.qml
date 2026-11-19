import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "thedub.governance"
  ipcTarget: "thedub.governance"
  manageIpc: false

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool killswitchArmed: false
  property double nowSec: Date.now() / 1000.0

  readonly property string shieldGlyph: {
    if (service.frozen) return "󰦞"
    if (service.connected && service.mode === "shadow") return "󰒄"
    return "󰒃"
  }

  readonly property color barIconColor: {
    if (service.frozen || service.hasPending) return urgent
    if (!service.connected) return Qt.darker(barForeground, 1.65)
    return barForeground
  }

  readonly property color heroIconColor: {
    if (service.frozen || service.hasPending) return urgent
    if (!service.connected) return dim
    if (service.mode === "shadow") return accent
    return foreground
  }

  readonly property string statusPill: {
    if (!service.connected) return strings.t("pill.offline")
    if (service.state === "frozen") return strings.t("pill.frozen")
    if (service.state === "revoked") return strings.t("pill.revoked")
    if (service.demo) return strings.t("pill.demo")
    if (service.mode === "shadow") return strings.t("pill.shadow")
    return strings.t("pill.enforce")
  }

  readonly property string heroMeta: {
    if (!service.connected) return strings.t("meta.offline")
    if (service.state === "frozen") return strings.t("meta.frozen")
    if (service.state === "revoked") return strings.t("meta.revoked")
    if (service.hasPending) {
      return strings.tn("meta.pending", service.pending.length)
        .arg(Commons.I18n.formatNumber(service.pending.length))
    }
    var modeLabel = service.mode === "shadow" ? strings.t("pill.shadow") : strings.t("pill.enforce")
    return strings.tn("meta.active", service.actionCount)
      .arg(modeLabel)
      .arg(Commons.I18n.formatNumber(service.actionCount))
  }

  readonly property real budgetRatio: {
    if (service.budgetLimit === null || service.budgetLimit <= 0) return -1
    return Math.max(0, Math.min(1, service.totalCost / service.budgetLimit))
  }

  function formatUsd(amount) {
    var num = Number(amount)
    if (!isFinite(num)) num = 0
    return "$" + Commons.I18n.formatNumber(num, 2)
  }

  function formatExpiry(expiresAt) {
    var ts = Number(expiresAt || 0)
    if (!isFinite(ts) || ts <= 0) return ""
    var left = Math.floor(ts - nowSec)
    if (left <= 0) return strings.t("pending.expired")
    var mins = Math.floor(left / 60)
    var secs = left % 60
    var dur = mins > 0
      ? Commons.I18n.formatNumber(mins) + "m " + Commons.I18n.formatNumber(secs) + "s"
      : Commons.I18n.formatNumber(secs) + "s"
    return strings.t("pending.expires").arg(dur)
  }

  function formatAge(ts) {
    var value = Number(ts || 0)
    if (!isFinite(value) || value <= 0) return ""
    var delta = Math.max(0, Math.floor(nowSec - value))
    if (delta < 5) return strings.t("audit.justNow")
    if (delta < 60) return strings.t("audit.secondsAgo").arg(Commons.I18n.formatNumber(delta))
    var mins = Math.floor(delta / 60)
    if (mins < 60) return strings.t("audit.minutesAgo").arg(Commons.I18n.formatNumber(mins))
    var hours = Math.floor(mins / 60)
    return strings.t("audit.hoursAgo").arg(Commons.I18n.formatNumber(hours))
  }

  function auditGlyph(ev) {
    var kind = String(ev && ev.eventType || "")
    if (kind === "action_allowed" || kind === "action_executed") return "󰄬"
    if (kind === "action_blocked" || kind === "approval_rejected") return "󰜺"
    if (kind === "killswitch_engaged" || kind === "binding_revoked") return "󰦞"
    if (kind === "action_pending_approval" || kind === "approval_requested") return "󰀦"
    if (kind === "approval_decision") return ev.approved === true ? "󰄬" : "󰜺"
    return "󰒃"
  }

  function auditColor(ev) {
    var kind = String(ev && ev.eventType || "")
    if (kind === "action_blocked" || kind === "killswitch_engaged" || kind === "binding_revoked" || kind === "approval_rejected") return urgent
    if (kind === "action_pending_approval" || kind === "approval_requested") return accent
    if (kind === "approval_decision") return ev.approved === true ? foreground : urgent
    return foreground
  }

  function auditHeadline(ev) {
    if (!ev) return ""
    var action = String(ev.actionType || "")
    var target = String(ev.target || "")
    if (action !== "" && target !== "") return action + " · " + target
    if (target !== "") return target
    return String(ev.eventType || "").replace(/_/g, " ")
  }

  function sendApprovalNotification(actionType, detail) {
    Util.execArgv([
      "omarchy-notification-send",
      "-u", "critical",
      "-g", "󰒃",
      strings.t("notify.title"),
      actionType + " · " + detail
    ])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    killswitchArmed = false
    if (opened) {
      nowSec = Date.now() / 1000.0
      if (panelFlick) panelFlick.contentY = 0
      service.refresh()
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
    }
  }

  Service {
    id: service
    settings: root.settings
    panelOpen: root.opened
    onNotificationRequested: function(actionType, detail) {
      root.sendApprovalNotification(actionType, detail)
    }
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000.0
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function status(): string {
      return JSON.stringify({
        connected: service.connected,
        agentId: service.agentId,
        state: service.state,
        mode: service.mode,
        pending: service.pending.length,
        allowed: service.allowedCount,
        blocked: service.blockedCount,
        totalCost: service.totalCost
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: service.alarming
    iconComponent: Component {
      Item {
        implicitWidth: button.iconSize
        implicitHeight: button.iconSize

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: root.shieldGlyph
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: button.iconSize
        }

        // Urgent dot badge when approvals are pending or kill switch is engaged.
        Rectangle {
          visible: service.hasPending || service.frozen
          width: Math.max(5, Math.round(button.iconSize * 0.34))
          height: width
          radius: width / 2
          color: root.urgent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -1
          anchors.topMargin: -1
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      implicitHeight: column.implicitHeight
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          panelFlick.contentY = Math.max(
            0,
            Math.min(
              Math.max(0, panelFlick.contentHeight - panelFlick.height),
              panelFlick.contentY + dy * Style.space(48)
            )
          )
        }
      }
      onCloseRequested: {
        if (root.killswitchArmed) root.killswitchArmed = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") service.refresh()
        else if ((t === "k" || t === "K") && service.guardConnected && !service.frozen) root.killswitchArmed = !root.killswitchArmed
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
        ScrollBar.vertical: ScrollBar {
          id: panelScroll
          policy: ScrollBar.AsNeeded
        }

        Column {
          id: column
          width: panelFlick.width - (panelFlick.interactive ? panelScroll.width + Style.space(6) : 0)
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            id: hero
            width: parent.width
            title: service.connected && service.agentId !== "" ? service.agentId : strings.t("title")
            meta: root.heroMeta
            detail: root.statusPill
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: service.connected ? 1.0 : 0.45

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.shieldGlyph
                color: root.heroIconColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: strings.t("action.refresh")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: service.refresh()
                }

                PanelActionButton {
                  visible: service.guardConnected
                  enabled: !service.frozen && !service.busy
                  iconText: "󰦞"
                  tooltipText: service.frozen ? strings.t("action.killswitchEngaged") : strings.t("action.killswitch")
                  foreground: service.frozen ? root.urgent : root.foreground
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: root.killswitchArmed = !root.killswitchArmed
                }
              }
            }
          }

          // ---------- Inline Kill Switch Confirmation ----------
          BorderSurface {
            visible: root.killswitchArmed && service.guardConnected && !service.frozen
            width: parent.width
            implicitHeight: ksConfirmCol.implicitHeight + Style.space(20)
            color: Style.hoverFillFor(root.urgent, root.urgent)
            borderSpec: Border.flat(root.urgent, 1)
            radius: Style.cornerRadius

            Column {
              id: ksConfirmCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: strings.t("killswitch.prompt").arg(service.agentId || "guard-agent")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Row {
                spacing: Style.space(8)

                Button {
                  text: strings.t("action.confirmFreeze")
                  iconText: "󰦞"
                  foreground: root.urgent
                  accent: root.urgent
                  bordered: true
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    root.killswitchArmed = false
                    service.engageKillswitch(strings.t("killswitch.reason"))
                  }
                }

                Button {
                  text: strings.t("action.cancel")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.killswitchArmed = false
                }
              }
            }
          }

          // ---------- Status / Auth Feedback ----------
          Text {
            textFormat: Text.PlainText
            visible: service.lastMessage !== "" || service.authError !== ""
            width: parent.width
            text: service.lastMessage !== "" ? service.lastMessage : service.authError
            color: (service.lastMessageIsError || service.authError !== "") ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ---------- Offline Quick-Connect Card ----------
          BorderSurface {
            visible: !service.connected
            width: parent.width
            implicitHeight: offlineCol.implicitHeight + Style.space(24)
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
            radius: Style.cornerRadius

            Column {
              id: offlineCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(10)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: strings.t("offline.heading")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: strings.t("offline.body").arg(service.guardUrl).arg(service.mcpControlUrl)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: strings.t("offline.hint")
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Row {
                spacing: Style.space(8)

                Button {
                  text: strings.t("action.startDemo")
                  iconText: "󰐊"
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: service.startDemoGuard()
                }
              }
            }
          }

          // ---------- Telemetry Strip (when connected) ----------
          Row {
            id: metricRow
            visible: service.connected
            width: parent.width
            spacing: Style.space(8)

            MetricTile {
              width: (metricRow.width - metricRow.spacing * 2) / 3
              label: strings.t("metric.allowed")
              value: Commons.I18n.formatNumber(service.allowedCount)
              valueColor: root.foreground
            }

            MetricTile {
              width: (metricRow.width - metricRow.spacing * 2) / 3
              label: strings.t("metric.blocked")
              value: Commons.I18n.formatNumber(service.blockedCount)
              valueColor: service.blockedCount > 0 ? root.urgent : root.foreground
            }

            MetricTile {
              width: (metricRow.width - metricRow.spacing * 2) / 3
              label: strings.t("metric.spend")
              value: root.formatUsd(service.totalCost)
              valueColor: root.budgetRatio >= 0.85 ? root.urgent : root.foreground
            }
          }

          // ---------- Budget Progress Bar (when budget_limit is reported) ----------
          Column {
            visible: service.connected && root.budgetRatio >= 0
            width: parent.width
            spacing: Style.space(4)

            RowLayout {
              width: parent.width

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: strings.t("metric.spend")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: root.formatUsd(service.totalCost) + " / " + root.formatUsd(service.budgetLimit)
                color: root.budgetRatio >= 0.85 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(6)
              radius: height / 2
              color: root.track

              Rectangle {
                width: Math.max(height, parent.width * root.budgetRatio)
                height: parent.height
                radius: height / 2
                color: root.budgetRatio >= 0.85 ? root.urgent : root.accent

                Behavior on width {
                  NumberAnimation {
                    duration: Style.duration(180)
                    easing.type: Easing.Bezier
                    easing.bezierCurve: Style.easeOut
                  }
                }
              }
            }
          }

          // ---------- Pending Approvals ----------
          PanelSeparator {
            visible: service.hasPending
            foreground: root.foreground
          }

          Column {
            visible: service.hasPending
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.tn("section.pending", service.pending.length)
                .arg(Commons.I18n.formatNumber(service.pending.length))
              foreground: root.urgent
              fontFamily: root.fontFamily
            }

            Repeater {
              model: service.pending

              BorderSurface {
                id: pendingCard
                required property var modelData
                width: parent.width
                implicitHeight: pendingCol.implicitHeight + Style.space(20)
                color: Style.hoverFillFor(root.urgent, root.urgent)
                borderSpec: Border.flat(root.urgent, 1)
                radius: Style.cornerRadius

                Column {
                  id: pendingCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(10)
                  spacing: Style.space(6)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(6)

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: String(pendingCard.modelData.actionType || "action")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: Number(pendingCard.modelData.estimatedCost || 0) > 0
                      text: root.formatUsd(pendingCard.modelData.estimatedCost)
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: String(pendingCard.modelData.target || "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WrapAnywhere
                  }

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: {
                        var parts = [strings.t("pending.token").arg(String(pendingCard.modelData.token || ""))]
                        var exp = root.formatExpiry(pendingCard.modelData.expiresAt)
                        if (exp !== "") parts.push(exp)
                        return parts.join(" · ")
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Row {
                    spacing: Style.space(8)

                    Button {
                      text: strings.t("action.approve")
                      iconText: "󰄬"
                      enabled: !service.busy
                      foreground: root.foreground
                      accent: root.accent
                      bordered: true
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      onClicked: service.decideApproval(pendingCard.modelData, true)
                    }

                    Button {
                      text: strings.t("action.deny")
                      iconText: "󰜺"
                      enabled: !service.busy
                      foreground: root.urgent
                      accent: root.urgent
                      bordered: true
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      onClicked: service.decideApproval(pendingCard.modelData, false)
                    }
                  }
                }
              }
            }
          }

          // ---------- Policy & Scope Summary ----------
          PanelSeparator {
            visible: service.guardConnected
            foreground: root.foreground
          }

          Column {
            visible: service.guardConnected
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("section.policy")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: service.allowedActionTypes.length > 0
              width: parent.width
              text: strings.t("policy.vocab").arg(service.allowedActionTypes.join(" · "))
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                var lintText = service.lintCount === 0
                  ? strings.t("policy.lintClean")
                  : strings.tn("policy.lintIssues", service.lintCount).arg(Commons.I18n.formatNumber(service.lintCount))
                var shipText = service.shippingEnabled ? strings.t("policy.shippingOn") : strings.t("policy.shippingOff")
                return lintText + " · " + shipText
              }
              color: service.lintCount > 0 ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // ---------- Hash-Chained Audit Trail ----------
          PanelSeparator {
            visible: service.guardConnected
            foreground: root.foreground
          }

          Column {
            visible: service.guardConnected
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.t("section.audit")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: service.audit.length === 0
              width: parent.width
              text: strings.t("audit.empty")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: service.audit.slice(0, 8)

              RowLayout {
                id: auditRow
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.auditGlyph(auditRow.modelData)
                  color: root.auditColor(auditRow.modelData)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.space(1)
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.auditHeadline(auditRow.modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: String(auditRow.modelData.reason || "") !== ""
                    Layout.fillWidth: true
                    text: String(auditRow.modelData.reason || "")
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: {
                      var parts = []
                      var age = root.formatAge(auditRow.modelData.timestamp)
                      if (age !== "") parts.push(age)
                      if (Number(auditRow.modelData.cost || 0) > 0) parts.push(root.formatUsd(auditRow.modelData.cost))
                      if (String(auditRow.modelData.entryHash || "") !== "") parts.push("#" + String(auditRow.modelData.entryHash).slice(0, 8))
                      return parts.join(" · ")
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }

          // ---------- Demo Controls (only when connected to local demo guard) ----------
          PanelSeparator {
            visible: service.demo
            foreground: root.foreground
          }

          Row {
            visible: service.demo
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: strings.t("action.simulateEvent")
              iconText: "󰁨"
              enabled: !service.busy
              foreground: root.foreground
              accent: root.accent
              bordered: true
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: service.simulateRequest()
            }

            Button {
              visible: service.demoManaged
              text: strings.t("action.stopDemo")
              iconText: "󰓛"
              foreground: root.dim
              bordered: true
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: service.stopDemoGuard()
            }
          }

          // ---------- Footer ----------
          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(2)
            text: service.demo ? strings.t("footer.demo") : strings.t("footer.keys")
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

  component MetricTile: BorderSurface {
    id: tile
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    implicitHeight: tileCol.implicitHeight + Style.space(14)
    color: root.track
    radius: Style.cornerRadius

    Column {
      id: tileCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(7)
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.value
        color: tile.valueColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }
  }
}
