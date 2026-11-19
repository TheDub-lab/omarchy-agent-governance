import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

Item {
  id: root
  visible: false

  property var settings: ({})
  property bool panelOpen: false

  readonly property string bridgePath: decodeURIComponent(String(Qt.resolvedUrl("bridge.py")).replace(/^file:\/\//, ""))
  readonly property string mockGuardPath: decodeURIComponent(String(Qt.resolvedUrl("mock_guard.py")).replace(/^file:\/\//, ""))

  readonly property string guardUrl: String(setting("guardUrl", "http://127.0.0.1:8080"))
  readonly property string mcpControlUrl: String(setting("mcpControlUrl", "http://127.0.0.1:8788"))
  readonly property string approverName: String(setting("approverName", "operator"))
  readonly property string approverSecretFile: String(setting("approverSecretFile", ""))
  readonly property int pollIntervalSec: Math.max(1, Math.min(60, Number(setting("pollIntervalSec", 3))))
  readonly property bool notifyOnPending: setting("notifyOnPending", true) !== false
  readonly property string botpoliceLogPath: String(setting("botpoliceLogPath", "~/Projects/botpolice/events.jsonl"))
  readonly property bool notifyOnBotpoliceHigh: setting("notifyOnBotpoliceHigh", true) !== false

  // Live snapshot state
  property bool connected: false
  property bool guardConnected: false
  property bool mcpConnected: false
  property bool demo: false
  property string agentId: ""
  property string userId: ""
  property string state: "offline"   // active | frozen | revoked | offline
  property string mode: "enforce"    // enforce | shadow
  property var allowedActionTypes: []
  property var budgetLimit: null
  property int lintCount: 0
  property bool shippingEnabled: false

  property int actionCount: 0
  property int allowedCount: 0
  property int blockedCount: 0
  property int approvalPendingCount: 0
  property real totalCost: 0.0
  property real uptimeSeconds: 0.0

  property var pending: []
  property var audit: []

  // BotPolice honeypot state
  property bool botpolicePresent: false
  property int botpoliceTotal: 0
  property int botpoliceHigh: 0
  property int botpoliceMedium: 0
  property var botpoliceEvents: []
  property int botpoliceUnreadHigh: 0
  property var seenBotpoliceHashes: ({})

  property string authError: ""
  property string lastMessage: ""
  property bool lastMessageIsError: false
  property bool busy: false
  property bool demoManaged: demoProcess.running

  readonly property bool frozen: state === "frozen" || state === "revoked"
  readonly property bool hasPending: pending.length > 0
  readonly property bool alarming: frozen || hasPending || botpoliceUnreadHigh > 0

  // Track seen pending tokens so notifications fire once per token.
  property var seenTokens: ({})
  property bool initialPollDone: false
  property string pendingActionKind: ""
  property string pendingActionLabel: ""

  signal stateRefreshed()
  signal notificationRequested(string title, string body)
  signal botpoliceAlertRequested(string serviceName, string summary)

  function clearBotpoliceUnread() {
    botpoliceUnreadHigh = 0
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function clearMessage() {
    lastMessage = ""
    lastMessageIsError = false
  }

  function showMessage(text, isError) {
    lastMessage = String(text || "")
    lastMessageIsError = !!isError
    messageClearTimer.restart()
  }

  function refresh() {
    if (pollProcess.running) return
    pollProcess.command = [
      "python3",
      bridgePath,
      "poll",
      guardUrl,
      mcpControlUrl,
      approverSecretFile,
      botpoliceLogPath
    ]
    pollProcess.running = true
  }

  function decideApproval(item, approved) {
    if (!item || !item.token || actionProcess.running) return
    busy = true
    pendingActionKind = approved ? "approve" : "deny"
    pendingActionLabel = String(item.target || item.actionType || item.token)
    actionProcess.command = [
      "python3",
      bridgePath,
      "decide",
      guardUrl,
      mcpControlUrl,
      approverSecretFile,
      String(item.source || "guard"),
      String(item.token),
      approved ? "true" : "false",
      approverName
    ]
    actionProcess.running = true
  }

  function engageKillswitch(reason) {
    if (!guardConnected || actionProcess.running) return
    busy = true
    pendingActionKind = "killswitch"
    pendingActionLabel = agentId || "guard"
    actionProcess.command = [
      "python3",
      bridgePath,
      "killswitch",
      guardUrl,
      String(reason || "Operator kill switch")
    ]
    actionProcess.running = true
  }

  function simulateRequest() {
    if (!demo || actionProcess.running) return
    busy = true
    pendingActionKind = "simulate"
    pendingActionLabel = ""
    actionProcess.command = [
      "python3",
      bridgePath,
      "simulate",
      guardUrl
    ]
    actionProcess.running = true
  }

  function startDemoGuard() {
    if (demoProcess.running) return
    demoProcess.command = ["python3", mockGuardPath, "--host", "127.0.0.1", "--port", "8080"]
    demoProcess.running = true
    demoStartPollTimer.restart()
  }

  function stopDemoGuard() {
    if (!demoProcess.running) return
    demoProcess.signal(15)
    demoStartPollTimer.restart()
  }

  function applyPollOutput(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (e) {
      return
    }
    if (!parsed || typeof parsed !== "object") return

    connected = parsed.connected === true
    guardConnected = parsed.guardConnected === true
    mcpConnected = parsed.mcpConnected === true
    demo = parsed.demo === true
    agentId = String(parsed.agentId || "")
    userId = String(parsed.userId || "")
    state = String(parsed.state || (connected ? "active" : "offline"))
    mode = String(parsed.mode || "enforce")
    allowedActionTypes = Array.isArray(parsed.allowedActionTypes) ? parsed.allowedActionTypes : []
    budgetLimit = (parsed.budgetLimit !== null && parsed.budgetLimit !== undefined && isFinite(Number(parsed.budgetLimit)))
      ? Number(parsed.budgetLimit)
      : null
    lintCount = Number(parsed.lintCount || 0)
    shippingEnabled = parsed.shippingEnabled === true

    var mon = parsed.monitor || {}
    actionCount = Number(mon.actionCount || 0)
    allowedCount = Number(mon.allowed || 0)
    blockedCount = Number(mon.blocked || 0)
    approvalPendingCount = Number(mon.approvalPending || 0)
    totalCost = Number(mon.totalCost || 0)
    uptimeSeconds = Number(mon.uptimeSeconds || 0)

    var nextPending = Array.isArray(parsed.pending) ? parsed.pending : []
    notifyNewApprovals(nextPending)
    pending = nextPending

    audit = Array.isArray(parsed.audit) ? parsed.audit : []

    var bp = parsed.botpolice && typeof parsed.botpolice === "object" ? parsed.botpolice : {}
    botpolicePresent = bp.present === true
    botpoliceTotal = Number(bp.total || 0)
    botpoliceHigh = Number(bp.high || 0)
    botpoliceMedium = Number(bp.medium || 0)
    var nextBpEvents = Array.isArray(bp.events) ? bp.events : []
    notifyNewBotpoliceAlerts(nextBpEvents)
    botpoliceEvents = nextBpEvents

    authError = String(parsed.authError || "")
    initialPollDone = true
    stateRefreshed()
  }

  function notifyNewBotpoliceAlerts(nextEvents) {
    var nextSeen = Object.assign({}, seenBotpoliceHashes)
    for (var i = 0; i < nextEvents.length; i++) {
      var ev = nextEvents[i]
      if (!ev) continue
      var key = String(ev.hash || (String(ev.timestamp || "") + ":" + String(ev.event || "")))
      if (key === "") continue
      if (!nextSeen[key]) {
        nextSeen[key] = true
        if (initialPollDone && String(ev.severity || "") === "high") {
          if (!panelOpen) botpoliceUnreadHigh += 1
          if (notifyOnBotpoliceHigh) {
            var svc = String(ev.service || "decoy").toUpperCase()
            var detail = String(ev.summary || ev.event || "High-severity hit")
            botpoliceAlertRequested(svc, detail)
          }
        }
      }
    }
    seenBotpoliceHashes = nextSeen
  }

  function notifyNewApprovals(nextPending) {
    var nextSeen = {}
    for (var i = 0; i < nextPending.length; i++) {
      var item = nextPending[i]
      if (!item || !item.token) continue
      var token = String(item.token)
      nextSeen[token] = true
      if (initialPollDone && notifyOnPending && !seenTokens[token]) {
        var costText = item.estimatedCost > 0
          ? "$" + Commons.I18n.formatNumber(item.estimatedCost, 2)
          : String(item.urgency || "approval")
        notificationRequested(
          String(item.actionType || "action"),
          String(item.target || token) + " (" + costText + ")"
        )
      }
    }
    seenTokens = nextSeen
  }

  function applyActionOutput(raw) {
    busy = false
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (e) {
      parsed = { ok: false, error: "Invalid bridge response" }
    }
    if (parsed && parsed.ok === true) {
      if (pendingActionKind === "approve") showMessage("Approved: " + pendingActionLabel, false)
      else if (pendingActionKind === "deny") showMessage("Denied: " + pendingActionLabel, false)
      else if (pendingActionKind === "killswitch") showMessage("Kill switch engaged", false)
    } else {
      var err = parsed && parsed.error ? String(parsed.error) : "Request failed"
      showMessage(err, true)
    }
    pendingActionKind = ""
    pendingActionLabel = ""
    refresh()
  }

  Component.onCompleted: refresh()

  Timer {
    id: pollTimer
    interval: (root.panelOpen ? Math.min(2, root.pollIntervalSec) : root.pollIntervalSec) * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: demoStartPollTimer
    interval: 450
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: messageClearTimer
    interval: 4000
    repeat: false
    onTriggered: root.clearMessage()
  }

  Process {
    id: pollProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPollOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("thedub.governance/poll", text.trim())
    }
  }

  Process {
    id: actionProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyActionOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("thedub.governance/action", text.trim())
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.busy) {
        root.busy = false
        root.showMessage("Bridge exited with code " + exitCode, true)
      }
    }
  }

  Process {
    id: demoProcess
    running: false
    onExited: root.refresh()
  }
}
