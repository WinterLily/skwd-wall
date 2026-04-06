pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick
import ".."

QtObject {
  id: svc

  readonly property string _statusFilePath: Config.cacheDir + "/wallpaper/steam-dl-status.json"

  property var downloadStatus: ({})
  property var downloadProgress: ({})
  property string activeId: ""
  property string activeMessage: ""
  property int queueLength: 0
  property bool authPaused: false
  property var _failedAuth: []

  signal stateChanged()
  signal downloadFinished(string workshopId)

  Component.onCompleted: _recoverQueue()

  property string _recoverOutput: ""
  property var _recoverProc: Process {
    stdout: SplitParser {
      splitMarker: ""
      onRead: data => { svc._recoverOutput += data }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !svc._recoverOutput.trim()) return
      try {
        var obj = JSON.parse(svc._recoverOutput)
        var downloads = obj.downloads || {}
        var ids = Object.keys(downloads)
        var toQueue = []
        for (var i = 0; i < ids.length; i++) {
          var st = downloads[ids[i]].status
          if (st === "queued" || st === "downloading" || st === "auth_error")
            toQueue.push(ids[i])
        }
        if (toQueue.length > 0) {
          console.log("[SteamDownloadService] recovering " + toQueue.length + " incomplete downloads from status file")
          for (var j = 0; j < toQueue.length; j++)
            svc.requestDownload(toQueue[j])
        }
      } catch (e) {
        console.log("[SteamDownloadService] recovery parse error: " + e.message)
      }
    }
  }

  function _recoverQueue() {
    _recoverOutput = ""
    _recoverProc.command = ["cat", _statusFilePath]
    _recoverProc.running = true
  }

  readonly property string _requestFilePath: Config.cacheDir + "/wallpaper/steam-dl-request"

  property string _readResult: ""

  property var _requestReadProc: Process {
    id: readProc
    stdout: SplitParser {
      splitMarker: ""
      onRead: data => { svc._readResult += data }
    }
    onExited: function(exitCode, exitStatus) {
      var id = svc._readResult.trim().split("\n")[0] || ""
      console.log("[SteamDownloadService] pickUpRequest read id=" + JSON.stringify(id))
      svc._handleRequestData()
    }
  }

  function pickUpRequest() {
    _readResult = ""
    readProc.command = ["cat", _requestFilePath]
    readProc.running = true
  }

  property var _pendingSizes: ({})

  function _handleRequestData() {
    var lines = _readResult.trim().split("\n")
    var id = (lines[0] || "").trim()
    var sz = parseInt(lines[1]) || 0
    console.log("[SteamDownloadService] pickUpRequest read id=" + JSON.stringify(id) + " size=" + sz)
    if (id) {
      if (sz > 0) _pendingSizes[id] = sz
      requestDownload(id)
    }
  }

  function requestDownload(workshopId) {
    if (!workshopId) return
    var safeId = workshopId.toString().replace(/[^0-9]/g, "")
    if (!safeId || _activeDownloads[safeId]) return
    console.log("[SteamDownloadService] queuing download: " + safeId)

    var status = Object.assign({}, downloadStatus)
    status[safeId] = "queued"
    downloadStatus = status
    _activeDownloads[safeId] = true
    _downloadQueue.push(safeId)
    queueLength = _downloadQueue.length + _runningDownloads
    _writeStatus()
    _drainDownloadQueue()
  }

  property var _activeDownloads: ({})
  property var _downloadQueue: []
  property int _runningDownloads: 0
  readonly property int _maxConcurrent: 1

  function retryAuthFailed() {
    if (_failedAuth.length === 0) return
    console.log("[SteamDownloadService] retrying " + _failedAuth.length + " auth-failed downloads")
    authPaused = false
    var ids = _failedAuth.slice()
    _failedAuth = []
    for (var i = 0; i < ids.length; i++) {
      var st = Object.assign({}, downloadStatus)
      st[ids[i]] = "queued"
      downloadStatus = st
      _activeDownloads[ids[i]] = true
      _downloadQueue.push(ids[i])
    }
    queueLength = _downloadQueue.length + _runningDownloads
    _writeStatus()
    _drainDownloadQueue()
  }

  function _drainDownloadQueue() {
    while (_runningDownloads < _maxConcurrent && _downloadQueue.length > 0) {
      var id = _downloadQueue.shift()
      _runningDownloads++
      _spawnDownload(id)
    }
    queueLength = _downloadQueue.length + _runningDownloads
  }

  function _spawnDownload(workshopId) {
    activeId = workshopId
    activeMessage = "Starting steamcmd..."
    var s = Object.assign({}, downloadStatus)
    s[workshopId] = "downloading"
    downloadStatus = s
    _writeStatus()

    var comp = Qt.createComponent("../wallpaper/SteamWorkshopDownloadProc.qml")
    var expectedSz = svc._pendingSizes[workshopId] || 0
    var proc = comp.createObject(svc, {
      workshopId: workshopId,
      steamDir: Config.weDir.replace(/\/steamapps\/workshop\/content\/431960\/?$/, ""),
      steamUsername: Config.steamUsername,
      expectedSize: expectedSz
    })
    if (expectedSz > 0) delete svc._pendingSizes[workshopId]
    proc.onProgressUpdate.connect(function(id, pct) {
      var p = Object.assign({}, downloadProgress)
      p[id] = pct
      downloadProgress = p
      activeMessage = "Downloading " + Math.round(pct * 100) + "%"
      _writeStatus()
    })
    proc.onStatusMessage.connect(function(id, msg) {
      activeMessage = msg
      _writeStatus()
    })
    proc.onCredentialError.connect(function(id) {
      console.log("[SteamDownloadService] credential error for " + id + ", pausing queue")
      svc.authPaused = true
    })
    proc.onDone.connect(function(id, success) {
      _runningDownloads--
      var st = Object.assign({}, downloadStatus)
      if (success) {
        st[id] = "done"
        activeMessage = "Download complete"
        if (svc.authPaused) {
          svc.authPaused = false
          svc._failedAuth = []
        }
      } else if (svc.authPaused) {
        st[id] = "auth_error"
        activeMessage = "Steam login required"
        _failedAuth.push(id)
      } else {
        st[id] = "error"
        activeMessage = "Download failed"
      }
      downloadStatus = st
      downloadFinished(id)
      delete _activeDownloads[id]
      _writeStatus()
      proc.destroy()
      if (svc.authPaused) {
        while (_downloadQueue.length > 0) {
          var qid = _downloadQueue.shift()
          var s2 = Object.assign({}, downloadStatus)
          s2[qid] = "auth_error"
          downloadStatus = s2
          _failedAuth.push(qid)
          delete _activeDownloads[qid]
        }
        queueLength = 0
        _writeStatus()
      } else if (_downloadQueue.length > 0) {
        _drainDownloadQueue()
      } else {
        activeId = ""
        activeMessage = ""
        queueLength = 0
        _writeStatus()
      }
    })
    proc.running = true
  }

  property var _statusFileView: FileView { id: statusFile }

  function _writeStatus() {
    var obj = {
      downloads: {},
      activeId: activeId,
      activeMessage: activeMessage,
      queueLength: queueLength,
      authPaused: authPaused,
      authFailedCount: _failedAuth.length
    }
    var ids = Object.keys(downloadStatus)
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i]
      obj.downloads[id] = {
        status: downloadStatus[id] || "",
        progress: downloadProgress[id] || 0
      }
    }
    statusFile.path = _statusFilePath
    statusFile.setText(JSON.stringify(obj))
    svc.stateChanged()
  }
}
