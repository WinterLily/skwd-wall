import Quickshell.Io
import QtQuick

Process {
  id: dlProc

  property string workshopId
  property string steamDir: ""
  property string steamUsername: ""
  property real expectedSize: 0

  signal progressUpdate(string id, real pct)
  signal done(string id, bool success)
  signal statusMessage(string id, string msg)
  signal credentialError(string id)

  property bool _credentialError: false
  property bool _downloading: false

  readonly property string _login: steamUsername || "anonymous"
  readonly property string _dlPath: {
    var base = steamDir || (Qt.resolvedUrl("").replace("file://", "") + "/../.local/share/Steam")
    return base + "/steamapps/workshop/downloads/431960/" + workshopId
  }
  readonly property string _contentPath: {
    var base = steamDir || (Qt.resolvedUrl("").replace("file://", "") + "/../.local/share/Steam")
    return base + "/steamapps/workshop/content/431960/" + workshopId
  }

  property var _sizePoller: Timer {
    interval: 800
    repeat: true
    running: dlProc._downloading && dlProc.expectedSize > 0
    onTriggered: dlProc._pollSize()
  }

  property string _pollOutput: ""
  property var _pollProc: Process {
    stdout: SplitParser {
      splitMarker: ""
      onRead: data => { dlProc._pollOutput += data }
    }
    onExited: function(exitCode) {
      var bytes = parseInt(dlProc._pollOutput.trim())
      if (bytes > 0 && dlProc.expectedSize > 0) {
        var pct = Math.min(bytes / dlProc.expectedSize, 0.99)
        dlProc.progressUpdate(dlProc.workshopId, pct)
        var mb = (bytes / 1048576).toFixed(1)
        var totalMb = (dlProc.expectedSize / 1048576).toFixed(1)
        dlProc.statusMessage(dlProc.workshopId, "Downloading " + mb + " / " + totalMb + " MB (" + Math.round(pct * 100) + "%)")
      }
    }
  }

  function _pollSize() {
    _pollOutput = ""
    _pollProc.command = ["bash", "-c",
      "(du -sb " + JSON.stringify(_dlPath) + " 2>/dev/null || du -sb " + JSON.stringify(_contentPath) + " 2>/dev/null || echo '0\tx')"
      + " | awk '{print $1}'"
    ]
    _pollProc.running = true
  }

  command: steamDir
    ? ["steamcmd", "+force_install_dir", steamDir, "+login", _login, "+workshop_download_item", "431960", workshopId, "+quit"]
    : ["steamcmd", "+login", _login, "+workshop_download_item", "431960", workshopId, "+quit"]

  stderr: SplitParser {
    splitMarker: "\n"
    onRead: data => {
      console.log("[Steam DL " + dlProc.workshopId + " stderr] " + data)
      var match = data.match(/(\d+)\s*\/\s*(\d+)\s*bytes/)
      if (match) {
        var got = parseInt(match[1])
        var total = parseInt(match[2])
        if (total > 0) dlProc.progressUpdate(dlProc.workshopId, got / total)
      }

      var pctMatch = data.match(/(\d+(?:\.\d+)?)\s*%/)
      if (pctMatch) {
        dlProc.progressUpdate(dlProc.workshopId, parseFloat(pctMatch[1]) / 100.0)
      }
    }
  }

  stdout: SplitParser {
    splitMarker: "\n"
    onRead: data => {
      console.log("[Steam DL " + dlProc.workshopId + " stdout] " + data)
      var match = data.match(/(\d+(?:\.\d+)?)\s*%/)
      if (match) {
        var pct = parseFloat(match[1]) / 100.0
        dlProc.progressUpdate(dlProc.workshopId, pct)
        dlProc.statusMessage(dlProc.workshopId, "Downloading " + Math.round(pct * 100) + "%")
      }

      if (data.indexOf("Success") >= 0 || data.indexOf("fully installed") >= 0) {
        dlProc.progressUpdate(dlProc.workshopId, 1.0)
        dlProc.statusMessage(dlProc.workshopId, "Download complete")
      }

      if (data.indexOf("Cached credentials not found") >= 0 || data.indexOf("Login Failure") >= 0) {
        dlProc._credentialError = true
        dlProc.statusMessage(dlProc.workshopId, "Steam login required. Run: steamcmd +login " + dlProc._login + " +quit")
        dlProc.credentialError(dlProc.workshopId)
      }
      
      if (data.indexOf("Checking for available update") >= 0)
        dlProc.statusMessage(dlProc.workshopId, "Checking for updates...")
      else if (data.indexOf("Verifying installation") >= 0)
        dlProc.statusMessage(dlProc.workshopId, "Verifying installation...")
      else if (data.indexOf("Downloading item") >= 0) {
        dlProc._downloading = true
        dlProc.statusMessage(dlProc.workshopId, "Downloading workshop item...")
      }
      else if (data.indexOf("Loading Steam API") >= 0)
        dlProc.statusMessage(dlProc.workshopId, "Connecting to Steam...")
      else if (data.indexOf("Logging in") >= 0 || data.indexOf("Waiting for user info") >= 0)
        dlProc.statusMessage(dlProc.workshopId, "Logging in...")
    }
  }

  onExited: function(exitCode, exitStatus) {
    console.log("[Steam DL " + dlProc.workshopId + "] exited with code " + exitCode)
    if (exitCode === 0) {
      dlProc.progressUpdate(dlProc.workshopId, 1.0)
      dlProc.done(dlProc.workshopId, true)
    } else {
      dlProc.done(dlProc.workshopId, false)
    }
  }
}
