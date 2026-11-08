// Borne — QML UI.
// All data comes from the Rust core through the local API (HTTP); events
// (gamepads, pairing, sync, downloads) through the WebSocket. No business logic here.
import QtQuick
import QtQuick.Window
import QtCore
import QtWebSockets
import Borne.Theme
import "components"

Window {
    id: win
    width: 1280
    height: 720
    visible: true
    title: "Borne"
    color: theme.bg

    // Provided by the launcher (environment variables set by the core)
    property string apiBase: ""
    property string wsUrl: ""
    property bool safeMode: false
    property int uiRestarts: 0
    property string uiRoot: ""
    property string qtVersion: ""

    // ---------- State ----------
    property string screen: "boot"       // boot | server | profiles | pairing | library
    property var status: null
    property var systems: [{ id: "all", name: qsTr("All games") }, { id: "local", name: qsTr("Installed", "systems bar") }]
    property int systemIndex: 0
    property int focusIndex: 0
    property string layoutId: "grid"
    property string overlay: ""          // "", "theme", "diag", "launch"
    property bool hud: false
    property bool trailers: true
    property bool ready: false
    property string fatal: ""
    property int loadMs: 0
    property bool coreOnline: false
    property string lastInput: "—"
    property var inputCounts: ({ keyboard: 0, pad: 0 })
    property bool gameMode: false        // game running: UI unloaded, GPU freed
    property int libRevision: 0
    property var pairing: null
    property var pairingProfile: null
    property int qrRevision: 0
    property var indexByRom: ({})

    ListModel { id: libModel }

    // Themes
    ThemeBase { id: defaultTheme }
    property QtObject theme: defaultTheme
    property var themeEntries: []
    property var themeRejected: []
    property var currentTheme: null
    readonly property string defaultCardUrl: uiRoot + "/components/DefaultCard.qml"
    property string cardUrl: defaultCardUrl
    property int themeApplyMs: 0
    property double themeApplyStart: 0

    readonly property var focusedGame: {
        libRevision
        return libModel.count ? libModel.get(Math.min(focusIndex, libModel.count - 1)) : null
    }
    readonly property var opts: currentTheme ? currentTheme.options : ({ trailerDelayMs: 1500, trailerVolume: 0, backgroundBlur: false })
    readonly property var activeProfile: status ? status.active_profile : null
    readonly property bool textEntry: screen === "server" || nameEntry.visible

    // ---------- Local API ----------
    function api(method, path, body, cb) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            let data = null
            try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null } catch (e) { data = null }
            if (xhr.status >= 200 && xhr.status < 300) cb && cb(data, null)
            else cb && cb(null, data && data.error ? data.error : (xhr.status === 0 ? qsTr("core unreachable") : qsTr("error %1").arg(xhr.status)))
        }
        xhr.open(method, apiBase + path)
        if (body !== null && body !== undefined) xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(body === null || body === undefined ? null : JSON.stringify(body))
    }
    function fileUrl(path, version) {
        return path ? apiBase + "/file?path=" + encodeURIComponent(path) + (version ? "&v=" + encodeURIComponent(version) : "") : ""
    }
    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }

    function refreshStatus(cb) {
        api("GET", "/api/v1/status", null, function (s) { if (s) status = s; if (cb) cb(s) })
    }

    // ---------- Library ----------
    function toRow(g) {
        const server = status && status.server_url ? status.server_url : ""
        return {
            rom_id: g.rom_id, name: g.name, platform_name: g.platform_name, platform_slug: g.platform_slug,
            year: g.year || 0, genres: g.genres || "", regions: g.regions || "", players: g.players || "",
            summary: g.summary || "", fs_size: g.fs_size || 0,
            cover: g.cover_local ? fileUrl(g.cover_local, g.cover_stamp) : "",
            trailer: g.video_remote && server ? server + encodeURI(g.video_remote) : "",
            local_state: g.local_state, dl_state: g.download_state || "", dl_received: g.download_received || 0,
            dl_total: g.download_total || 0, dl_error: g.download_error || "", hue: (g.rom_id * 47) % 360
        }
    }
    function loadPlatforms() {
        api("GET", "/api/v1/platforms", null, function (list) {
            if (!list) return
            const current = systems[systemIndex] ? systems[systemIndex].id : "all"
            const sys = [{ id: "all", name: qsTr("All games") }, { id: "local", name: qsTr("Installed", "systems bar") }]
            // Short names for the systems bar (RomM returns full names).
            const shortNames = { "nes": "NES", "snes": "Super Nintendo", "n64": "Nintendo 64", "gb": "Game Boy", "gbc": "Game Boy Color",
                            "gba": "Game Boy Advance", "nds": "Nintendo DS", "genesis": "Mega Drive", "sms": "Master System",
                            "ngc": "GameCube", "wii": "Wii", "wiiu": "Wii U", "switch": "Switch", "ps": "PlayStation", "psx": "PlayStation",
                            "ps2": "PS2", "ps3": "PS3", "psp": "PSP", "dc": "Dreamcast", "saturn": "Saturn", "arcade": "Arcade" }
            for (const p of list) sys.push({ id: p.slug, name: shortNames[p.slug] || p.name })
            systems = sys
            systemIndex = Math.max(0, sys.findIndex(s => s.id === current))
        })
    }
    // Reloads the list keeping the selection; updates in place if the list did not change.
    function loadLibrary(resetFocus) {
        const s = systems[systemIndex] || systems[0]
        const q = s.id === "all" ? "" : s.id === "local" ? "?local=1" : "?platform=" + encodeURIComponent(s.id)
        const keep = !resetFocus && focusedGame ? focusedGame.rom_id : -1
        const t0 = Date.now()
        api("GET", "/api/v1/library" + q, null, function (list, err) {
            if (!list) { if (err) toasts.show(qsTr("Library unavailable: %1").arg(err), "error"); return }
            const rows = list.map(toRow)
            const same = rows.length === libModel.count && rows.every((r, i) => libModel.get(i).rom_id === r.rom_id)
            if (same) {
                for (let i = 0; i < rows.length; i++) libModel.set(i, rows[i])
            } else {
                libModel.clear()
                libModel.append(rows)
            }
            const idx = {}
            rows.forEach((r, i) => idx[r.rom_id] = i)
            indexByRom = idx
            if (keep >= 0 && idx[keep] !== undefined) focusIndex = idx[keep]
            else if (resetFocus || focusIndex >= rows.length) focusIndex = 0
            loadMs = Date.now() - t0
            ready = true
            libRevision++
        })
    }
    Timer { id: libReload; interval: 300; onTriggered: { win.loadPlatforms(); win.loadLibrary(false) } }

    function onDownloadEvent(m) {
        const i = indexByRom[m.rom_id]
        if (i !== undefined && i < libModel.count) {
            libModel.setProperty(i, "dl_state", m.state === "done" || m.state === "cancelled" ? "" : m.state)
            libModel.setProperty(i, "dl_received", m.received || 0)
            libModel.setProperty(i, "dl_total", m.total || 0)
            libModel.setProperty(i, "dl_error", m.error || "")
            libRevision++
        }
        const name = i !== undefined && i < libModel.count ? libModel.get(i).name : qsTr("The game")
        if (m.state === "done") toasts.show(qsTr("%1 is installed.").arg(name), "ok")
        if (m.state === "failed") toasts.show(qsTr("%1: %2").arg(name).arg(m.error || qsTr("download failed")), "error")
        if (downloadsPanel.visible) downloadsRefresh.restart()
    }

    // ---------- Game actions ----------
    function download(g) {
        api("POST", "/api/v1/games/" + g.rom_id + "/download", {}, function (r, err) {
            if (err) toasts.show(err, "error")
            else toasts.show(qsTr("Downloading %1 (%2).").arg(g.name).arg(fmtSize(g.fs_size)), "info")
        })
    }
    function cancelDownload(g) {
        api("GET", "/api/v1/downloads", null, function (list) {
            const d = (list || []).find(x => x.rom_id === g.rom_id && ["queued", "downloading", "verifying", "extracting", "failed"].indexOf(x.state) >= 0)
            if (d) api("DELETE", "/api/v1/downloads/" + d.id, null, function () { libReload.restart() })
        })
    }
    function deleteLocal(g) {
        menu.open(qsTr("Delete “%1” from this device?").arg(g.name), qsTr("The game stays available on RomM and can be downloaded again."),
                  [{ id: "yes", label: qsTr("Delete from this device") }, { id: "no", label: qsTr("Cancel") }], function (c) {
            if (c !== "yes") return
            api("DELETE", "/api/v1/games/" + g.rom_id + "/local", null, function (r, err) {
                if (err) toasts.show(err, "error"); else toasts.show(qsTr("%1 deleted from this device.").arg(g.name), "ok")
            })
        })
    }
    function primaryAction() {
        const g = focusedGame
        if (!g) return
        const active = ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
        if (active) gameMenu()
        else if (g.local_state === "local") toasts.show(qsTr("Launching games arrives with stage 3 (emulators)."), "info")
        else download(g)
    }
    function gameMenu() {
        const g = focusedGame
        if (!g) return
        const active = ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
        let items = []
        if (active) items = [{ id: "cancel", label: qsTr("Cancel download") }]
        else if (g.dl_state === "failed") items = [{ id: "download", label: qsTr("Retry download"), detail: g.dl_error }, { id: "cancel", label: qsTr("Give up") }]
        else if (g.local_state === "local") items = [{ id: "play", label: qsTr("Play"), detail: qsTr("Arrives with stage 3 (emulators)"), disabled: true }, { id: "delete", label: qsTr("Delete from this device") }]
        else if (g.local_state === "missing") items = [{ id: "download", label: qsTr("Download again") }, { id: "delete", label: qsTr("Forget the local copy") }]
        else items = [{ id: "download", label: qsTr("Download"), detail: fmtSize(g.fs_size) }]
        items.push({ id: "close", label: qsTr("Close") })
        menu.open(g.name, g.platform_name + (g.year > 0 ? " · " + g.year : ""), items, function (c) {
            if (c === "download") download(g)
            else if (c === "cancel") cancelDownload(g)
            else if (c === "delete") deleteLocal(g)
        })
    }
    function mainMenu() {
        const inLib = screen === "library"
        const sync = status ? status.sync : null
        let items = []
        if (inLib) {
            items.push({ id: "sync", label: qsTr("Sync library"), detail: sync && sync.running ? qsTr("In progress…") : (sync && sync.last_sync ? qsTr("Last: %1").arg(new Date(sync.last_sync * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)) : ""), disabled: sync && sync.running })
            items.push({ id: "downloads", label: qsTr("Downloads") })
            items.push({ id: "theme", label: qsTr("Theme"), detail: currentTheme ? currentTheme.name : "" })
            items.push({ id: "layout", label: layoutId === "grid" ? qsTr("Switch to detailed view") : qsTr("Switch to grid view") })
            items.push({ id: "profile", label: qsTr("Switch profile"), detail: activeProfile ? activeProfile.name : "" })
        }
        items.push({ id: "server", label: qsTr("RomM server"), detail: status && status.server_url ? status.server_url : qsTr("not configured") })
        items.push({ id: "diag", label: qsTr("Diagnostics and measurements") })
        items.push({ id: "quit", label: qsTr("Quit Borne") })
        menu.open(qsTr("Menu"), activeProfile && inLib ? qsTr("Profile: %1").arg(activeProfile.name) : "", items, function (c) {
            if (c === "sync") api("POST", "/api/v1/sync", {}, function (r, err) { if (err) toasts.show(err, "error"); else toasts.show(qsTr("Sync started."), "info") })
            else if (c === "downloads") openDownloads()
            else if (c === "theme") themePicker.open()
            else if (c === "layout") layoutId = layoutId === "grid" ? "list" : "grid"
            else if (c === "profile") showProfiles()
            else if (c === "server") showServer()
            else if (c === "diag") diag.open()
            else if (c === "quit") Qt.quit()
        })
    }
    function openDownloads() {
        downloadsPanel.index = 0
        downloadsPanel.visible = true
        refreshDownloads()
    }
    function refreshDownloads() {
        api("GET", "/api/v1/downloads", null, function (l) { if (l) downloadsPanel.downloads = l })
    }
    Timer { id: downloadsRefresh; interval: 400; onTriggered: win.refreshDownloads() }

    // ---------- Screens ----------
    function showServer() {
        setup.reset(status && status.server_url ? status.server_url : "http://")
        screen = "server"
    }
    function showProfiles() {
        refreshStatus(function (s) {
            if (!s) return
            picker.profiles = s.profiles
            picker.lastUsed = s.active_profile ? s.active_profile.id : ""
            picker.focusLastUsed()
            screen = "profiles"
        })
    }
    function enterLibrary(profile) {
        api("POST", "/api/v1/profiles/" + profile.id + "/activate", {}, function (r, err) {
            if (err) { toasts.show(err, "error"); return }
            refreshStatus()
            screen = "library"
            systemIndex = 0
            loadPlatforms()
            loadLibrary(true)
        })
    }
    function startPairing(profile) {
        pairingProfile = profile
        pairing = null
        screen = "pairing"
        api("POST", "/api/v1/profiles/" + profile.id + "/pair", {}, function (p, err) {
            if (err) pairing = { state: "error", error: err, user_code: "", verification_url: "", expires_at: 0 }
            else { pairing = p; qrRevision++ }
        })
    }
    function profileOptions(p) {
        menu.open(p.name, p.paired ? qsTr("RomM account: %1").arg(p.romm_user) : qsTr("Profile not paired"),
                  [{ id: "pair", label: p.paired ? qsTr("Pair with RomM again") : qsTr("Pair with RomM") },
                   { id: "rename", label: qsTr("Rename") },
                   { id: "delete", label: qsTr("Delete profile"), detail: qsTr("Its saves stay on disk") },
                   { id: "close", label: qsTr("Close") }], function (c) {
            if (c === "pair") startPairing(p)
            else if (c === "rename") nameEntry.open(qsTr("Rename profile"), p.name, function (name) {
                api("PUT", "/api/v1/profiles/" + p.id, { name: name }, function (r, err) { if (err) toasts.show(err, "error"); showProfiles() })
            })
            else if (c === "delete") menu.open(qsTr("Delete profile “%1”?").arg(p.name), qsTr("Its RomM pairing will be forgotten on this device."),
                                               [{ id: "yes", label: qsTr("Delete") }, { id: "no", label: qsTr("Cancel") }], function (c2) {
                if (c2 === "yes") api("DELETE", "/api/v1/profiles/" + p.id, null, function () { showProfiles() })
            })
        })
    }
    function addProfile() {
        nameEntry.open(qsTr("New profile"), "", function (name) {
            api("POST", "/api/v1/profiles", { name: name }, function (p, err) {
                if (err) { toasts.show(err, "error"); showProfiles(); return }
                startPairing(p)
            })
        })
    }

    // ---------- Input ----------
    function move(a) {
        const n = libModel.count
        if (!n) return
        const cols = layoutId === "grid" && libraryLoader.item ? libraryLoader.item.columns : 1
        let i = focusIndex
        if (a === "left") i -= (layoutId === "grid" ? 1 : 10)
        else if (a === "right") i += (layoutId === "grid" ? 1 : 10)
        else if (a === "up") i -= cols
        else if (a === "down") {
            if (Math.floor(i / cols) < Math.floor((n - 1) / cols)) i = Math.min(n - 1, i + cols)
        }
        focusIndex = Math.max(0, Math.min(n - 1, i))
    }
    function setSystem(d) {
        systemIndex = (systemIndex + d + systems.length) % systems.length
        loadLibrary(true)
    }

    function dispatch(a, source) {
        inputCounts[source] = (inputCounts[source] || 0) + 1
        inputCountsChanged()
        lastInput = a + " via " + source
        if (bench.running && a !== "start") return
        if (menu.visible) return menu.handle(a)
        if (nameEntry.visible) return nameEntry.handle(a)
        if (downloadsPanel.visible) return downloadsPanel.handle(a)
        if (overlay === "theme") return themePicker.handle(a)
        if (overlay === "diag") return diag.handle(a)
        if (overlay === "launch") { if (a === "b") { overlay = ""; gameMode = false } return }
        if (screen === "server") return setup.handle(a)
        if (screen === "profiles") return picker.handle(a)
        if (screen === "pairing") return pairingScreen.handle(a)
        if (screen !== "library") return
        if (a === "a") primaryAction()
        else if (a === "y") gameMenu()
        else if (a === "x") layoutId = layoutId === "grid" ? "list" : "grid"
        else if (a === "start") mainMenu()
        else if (a === "select") hud = !hud
        else if (a === "b") { /* root: nothing to close */ }
        else if (a === "lb") setSystem(-1)
        else if (a === "rb") setSystem(1)
        else move(a)
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            // Text entry: the physical keyboard types directly.
            if (win.textEntry && !menu.visible) {
                const target = nameEntry.visible ? nameEntry : setup
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { e.accepted = true; target.handle("start"); return }
                if (e.key === Qt.Key_Escape) { e.accepted = true; target.handle("select"); return }
                if (e.key === Qt.Key_Backspace) { e.accepted = true; target.backspace(); return }
                if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 32) { e.accepted = true; target.typeText(e.text); return }
            }
            const map = {}
            map[Qt.Key_Up] = "up"; map[Qt.Key_Down] = "down"; map[Qt.Key_Left] = "left"; map[Qt.Key_Right] = "right"
            map[Qt.Key_Return] = "a"; map[Qt.Key_Enter] = "a"; map[Qt.Key_Space] = "a"
            map[Qt.Key_Escape] = "b"; map[Qt.Key_Backspace] = "b"
            map[Qt.Key_X] = "x"; map[Qt.Key_T] = "y"; map[Qt.Key_Y] = "y"; map[Qt.Key_F1] = "start"; map[Qt.Key_M] = "start"; map[Qt.Key_F2] = "select"
            map[Qt.Key_PageUp] = "lb"; map[Qt.Key_Q] = "lb"; map[Qt.Key_PageDown] = "rb"; map[Qt.Key_E] = "rb"
            const a = map[e.key]
            if (a) { e.accepted = true; dispatch(a, "keyboard") }
        }
    }

    // Core events. Reconnects automatically if the core restarts.
    WebSocket {
        id: ws
        url: win.wsUrl
        active: win.wsUrl !== ""
        onTextMessageReceived: (msg) => {
            let m
            try { m = JSON.parse(msg) } catch (e) { return }
            if (m.type === "hello") win.coreOnline = true
            else if (m.type === "pad") win.dispatch(m.action, "pad")
            else if (m.type === "download") win.onDownloadEvent(m)
            else if (m.type === "library") libReload.restart()
            else if (m.type === "sync") {
                if (win.status) { const s = win.status; s.sync = m.sync; win.status = s; win.statusChanged() }
                if (!m.sync.running && m.sync.error) toasts.show(qsTr("Sync: %1").arg(m.sync.error), "error")
                if (!m.sync.running) libReload.restart()
            }
            else if (m.type === "status") win.refreshStatus()
            else if (m.type === "profiles") {
                // Data update only: never change screens on an event.
                win.refreshStatus(function (s) { if (s) picker.profiles = s.profiles })
            }
            else if (m.type === "pairing") {
                win.pairing = m.pairing
                win.qrRevision++
                if (m.pairing && m.pairing.state === "approved" && win.screen === "pairing" && win.pairingProfile) {
                    toasts.show(qsTr("Profile “%1” paired with RomM.").arg(win.pairingProfile.name), "ok")
                    pairedTimer.restart()
                }
            }
        }
        onStatusChanged: (st) => {
            if (st === WebSocket.Open) win.coreOnline = true
            if (st === WebSocket.Error || st === WebSocket.Closed) { win.coreOnline = false; reconnect.start() }
        }
    }
    Timer { id: reconnect; interval: 2000; onTriggered: { ws.active = false; ws.active = true } }
    Timer { id: pairedTimer; interval: 1200; onTriggered: win.enterLibrary(win.pairingProfile) }

    // ---------- Themes ----------
    function validateManifest(m) {
        if (!m || typeof m !== "object") throw "unreadable manifest"
        if (m.schema !== 1) throw "unsupported schema " + m.schema
        if (m.api !== undefined && m.api !== 1) throw "unsupported theme API " + m.api + " (expected: 1)"
        if (typeof m.id !== "string" || !/^[a-z0-9-]{2,40}$/.test(m.id)) throw "invalid id"
        if (typeof m.name !== "string" || !m.name.trim()) throw "invalid name"
        const layout = m.layout || "grid"
        if (layout !== "grid" && layout !== "list") throw "unknown layout: " + layout
        const o = m.options || {}
        const num = (v, d, lo, hi) => { if (v === undefined) return d; if (typeof v !== "number" || v < lo || v > hi) throw "option out of range: " + v; return v }
        return {
            id: m.id, name: m.name, author: m.author || "", layout: layout,
            options: { trailerDelayMs: num(o.trailerDelayMs, 1500, 0, 10000), trailerVolume: num(o.trailerVolume, 0, 0, 1), backgroundBlur: o.backgroundBlur === true }
        }
    }
    function loadThemes(done) {
        api("GET", "/api/v1/themes", null, function (list, err) {
            const ok = [], bad = []
            for (const t of (list || [])) {
                try {
                    if (t.files.indexOf("Theme.qml") < 0) throw "missing Theme.qml"
                    const m = validateManifest(JSON.parse(t.manifest))
                    if (ok.some(e => e.id === m.id)) throw "id already used: " + m.id
                    m.builtin = t.builtin
                    m.dirUrl = "file://" + t.dir
                    m.files = t.files
                    ok.push(m)
                } catch (e) { bad.push({ source: t.dir, reason: String(e) }) }
            }
            themeEntries = ok
            themeRejected = bad
            done()
        })
    }
    // Isolated loading: any error -> default theme, reason shown, never a stuck UI.
    function applyTheme(entry) {
        themeApplyStart = Date.now()
        try {
            const comp = Qt.createComponent(entry.dirUrl + "/Theme.qml")
            if (comp.status !== Component.Ready) throw comp.errorString()
            const obj = comp.createObject(win)
            if (!obj || obj.apiVersion !== 1) throw "Theme.qml must inherit from ThemeBase (API 1)"
            let card = defaultCardUrl
            if (entry.files.indexOf("Card.qml") >= 0) {
                // Validate before use: an invalid card must never break the grid.
                const c = Qt.createComponent(entry.dirUrl + "/Card.qml")
                if (c.status === Component.Ready) card = entry.dirUrl + "/Card.qml"
                else themeRejected = themeRejected.concat([{ source: entry.id + "/Card.qml", reason: c.errorString() }])
            }
            const old = theme
            theme = obj
            cardUrl = card
            currentTheme = entry
            if (old !== defaultTheme) old.destroy()
        } catch (e) {
            themeRejected = themeRejected.concat([{ source: entry.id, reason: String(e) }])
            theme = defaultTheme
            cardUrl = defaultCardUrl
            currentTheme = themeEntries.find(t => t.id === "nocturne") || null
        }
    }


    // ---------- Scene (library) ----------
    Loader {
        id: bgLoader
        anchors.fill: parent
        active: win.screen === "library" && win.ready && win.layoutId === "grid" && !win.gameMode
        sourceComponent: TrailerStage {
            game: win.focusedGame
            theme: win.theme
            delayMs: win.opts.trailerDelayMs
            volume: win.opts.trailerVolume
            blur: win.opts.backgroundBlur
            active: win.trailers
            paused: win.overlay !== "" || menu.visible
        }
    }

    Item {
        id: topbar
        width: parent.width; height: 72
        visible: win.screen === "library" && !win.gameMode
        Text {
            x: 64; anchors.verticalCenter: parent.verticalCenter
            text: "Borne"; color: theme.fg
            font { family: theme.displayFont; pixelSize: 22; bold: true }
        }
        Text {
            anchors { right: sysBar.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
            text: "LB"; color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 11; bold: true }
        }
        // Systems bar: scrolls to keep the active system visible, without overflowing.
        ListView {
            id: sysBar
            anchors.centerIn: parent
            width: Math.min(contentWidth, parent.width - 2 * 260)
            height: 34
            orientation: ListView.Horizontal
            spacing: 8
            clip: true
            interactive: false
            model: win.systems
            currentIndex: win.systemIndex
            highlightFollowsCurrentItem: true
            highlightRangeMode: ListView.ApplyRange
            preferredHighlightBegin: width * 0.25
            preferredHighlightEnd: width * 0.75
            highlightMoveDuration: theme.scrollMs
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool cur: index === win.systemIndex
                width: lbl.implicitWidth + 28; height: 34; radius: 17
                color: cur ? theme.accent : "transparent"
                Text {
                    id: lbl; anchors.centerIn: parent
                    text: modelData.name
                    color: parent.cur ? theme.accentFg : theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 15; bold: parent.cur }
                }
            }
        }
        Text {
            anchors { left: sysBar.right; leftMargin: 10; verticalCenter: parent.verticalCenter }
            text: "RB"; color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 11; bold: true }
        }
        Row {
            anchors { right: parent.right; rightMargin: 64; verticalCenter: parent.verticalCenter }
            spacing: 14
            Text {
                anchors.verticalCenter: parent.verticalCenter
                readonly property var s: win.status ? win.status.sync : null
                visible: s && (s.running || s.covers_pending > 0)
                text: s ? (s.running ? qsTr("Syncing %1/%2").arg(s.done).arg(s.total) : qsTr("Covers… %1").arg(s.covers_pending)) : ""
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 13 }
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 10; height: 10; radius: 5
                color: win.status && win.status.online ? theme.ok : theme.bad
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (win.activeProfile ? win.activeProfile.name : "") + (win.status && !win.status.online ? " · " + qsTr("offline") : "")
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 14 }
            }
        }
    }

    Loader {
        id: libraryLoader
        anchors { top: topbar.bottom; left: parent.left; right: parent.right; bottom: info.top }
        active: win.screen === "library" && win.ready && !win.gameMode
        sourceComponent: win.layoutId === "grid" ? gridComp : listComp
    }
    Component {
        id: gridComp
        PosterGrid {
            games: libModel; currentIndex: win.focusIndex; theme: win.theme; cardUrl: win.cardUrl
            emptyText: {
                const s = win.status ? win.status.sync : null
                if (s && s.running) return qsTr("Syncing the library…")
                if (win.systems[win.systemIndex] && win.systems[win.systemIndex].id === "local")
                    return qsTr("No game installed. Pick a game in “All games” and press A to download it.")
                return qsTr("No games here.")
            }
        }
    }
    Component {
        id: listComp
        DetailView { games: libModel; currentIndex: win.focusIndex; game: win.focusedGame; theme: win.theme; options: win.opts; trailers: win.trailers; paused: win.overlay !== "" || menu.visible }
    }

    Item {
        id: info
        anchors { left: parent.left; right: parent.right; bottom: hints.top }
        height: win.layoutId === "grid" ? 96 : 0
        visible: win.screen === "library" && win.layoutId === "grid" && !win.gameMode && win.focusedGame !== null
        Column {
            x: 64; y: 8
            Text {
                text: win.focusedGame ? (theme.uppercaseTitles ? win.focusedGame.name.toUpperCase() : win.focusedGame.name) : ""
                color: theme.fg
                font { family: theme.displayFont; pixelSize: theme.titleSize; bold: true }
            }
            Text {
                readonly property var g: win.focusedGame
                text: g ? [g.platform_name, g.year > 0 ? g.year : "", g.genres,
                           g.local_state === "local" ? qsTr("Installed") : g.dl_state ? "" : qsTr("%1 to download").arg(win.fmtSize(g.fs_size))].filter(x => x).join(" · ") : ""
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 15 }
            }
        }
    }

    Row {
        id: hints
        anchors { left: parent.left; leftMargin: 64; bottom: parent.bottom }
        height: 56
        spacing: 28
        visible: win.screen === "library" && !win.gameMode
        Repeater {
            model: {
                const g = win.focusedGame
                const active = g && ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
                const a = !g ? "" : active ? qsTr("Cancel…") : g.local_state === "local" ? qsTr("Play") : qsTr("Download")
                return [["A", a], ["Y", qsTr("Options")], ["X", win.layoutId === "grid" ? qsTr("Detailed view") : qsTr("Grid view")], ["LB/RB", qsTr("System")], ["Start", qsTr("Menu")]].filter(h => h[1])
            }
            Row {
                required property var modelData
                spacing: 6
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    width: k.implicitWidth + 12; height: 20; radius: 6; color: theme.fg
                    Text { id: k; anchors.centerIn: parent; text: modelData[0]; color: theme.bg; font { family: theme.fontFamily; pixelSize: 11; bold: true } }
                }
                Text { text: modelData[1]; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14 } }
            }
        }
    }

    // ---------- Screens outside the library ----------
    ServerSetup {
        id: setup
        anchors.fill: parent
        visible: win.screen === "server"
        theme: win.theme
        onSubmit: (url) => {
            busy = true
            win.api("POST", "/api/v1/server", { url: url }, function (r, err) {
                setup.busy = false
                if (err) { setup.error = err; return }
                toasts.show(qsTr("Connected to RomM (%1).").arg(r.url), "ok")
                win.showProfiles()
            })
        }
        onCancelled: if (win.status && win.status.server_url) win.showProfiles()
    }
    ProfilePicker {
        id: picker
        anchors.fill: parent
        visible: win.screen === "profiles"
        theme: win.theme
        serverUrl: win.status && win.status.server_url ? win.status.server_url : ""
        online: win.status ? win.status.online : false
        onChoose: (p) => p.paired ? win.enterLibrary(p) : win.startPairing(p)
        onAdd: win.addProfile()
        onOptions: (p) => win.profileOptions(p)
        onMainMenu: win.mainMenu()
    }
    PairingScreen {
        id: pairingScreen
        anchors.fill: parent
        visible: win.screen === "pairing"
        theme: win.theme
        pairing: win.pairing
        profileName: win.pairingProfile ? win.pairingProfile.name : ""
        qrUrl: win.apiBase + "/api/v1/pairing/qr.svg"
        qrRevision: win.qrRevision
        onRetry: win.startPairing(win.pairingProfile)
        onBack: { win.api("DELETE", "/api/v1/pairing", null, null); win.showProfiles() }
    }
    Text {
        visible: win.screen === "boot" || (win.screen === "library" && !win.ready)
        anchors.centerIn: parent
        text: win.fatal || (win.apiBase ? qsTr("Loading…") : qsTr("Start through borne (BORNE_API / BORNE_WS variables missing)."))
        color: win.fatal ? theme.bad : theme.fgMuted
        font { family: theme.fontFamily; pixelSize: 18 }
    }

    // Name entry (profile) with the on-screen keyboard.
    Rectangle {
        id: nameEntry
        visible: false
        anchors.fill: parent
        color: theme.bg
        z: 70
        property string title: ""
        property var callback: null
        function open(t, initial, cb) { title = t; nameKb.text = initial; callback = cb; visible = true }
        function handle(a) { nameKb.handle(a) }
        function typeText(t) { nameKb.typeText(t) }
        function backspace() { nameKb.backspace() }
        Column {
            anchors.centerIn: parent
            spacing: 20
            Text { text: nameEntry.title; color: theme.fg; font { family: theme.displayFont; pixelSize: 28; bold: true } }
            OnScreenKeyboard {
                id: nameKb
                width: implicitWidth; height: implicitHeight
                theme: win.theme
                maxLength: 40
                placeholder: qsTr("Profile name")
                onAccepted: (t) => {
                    const name = t.trim()
                    if (!name) return
                    const cb = nameEntry.callback
                    nameEntry.visible = false
                    if (cb) cb(name)
                }
                onCancelled: nameEntry.visible = false
            }
            Text { text: qsTr("A  Key     B  Erase     Start  Confirm     Select  Cancel"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
        }
    }

    // Status banners
    Rectangle {
        visible: !win.coreOnline && win.screen !== "boot"
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
        width: rc.implicitWidth + 28; height: 30; radius: 15; color: theme.bad
        z: 50
        Text { id: rc; anchors.centerIn: parent; text: qsTr("Borne core unreachable — reconnecting…"); color: "white"; font { family: theme.fontFamily; pixelSize: 13; bold: true } }
    }
    Rectangle {
        visible: win.safeMode
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 60 }
        width: sm.implicitWidth + 28; height: 30; radius: 15; color: theme.accent
        z: 50
        Text { id: sm; anchors.centerIn: parent; text: qsTr("Safe mode: default theme (the UI crashed %n time(s))", "", win.uiRestarts); color: theme.accentFg; font { family: theme.fontFamily; pixelSize: 13; bold: true } }
    }

    // Measurement HUD
    Rectangle {
        visible: win.hud && !win.gameMode
        anchors { right: parent.right; rightMargin: 16; top: parent.top; topMargin: 78 }
        width: hudCol.width + 24; height: hudCol.height + 16; radius: 8
        color: Qt.rgba(0, 0, 0, 0.65)
        z: 40
        Column {
            id: hudCol; x: 12; y: 8
            Text { text: frames.fps + " fps"; color: frames.fps < 55 ? "#f87171" : "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 16; bold: true } }
            Text { text: "p95 " + frames.p95 + " ms · p99 " + frames.p99 + " ms"; color: "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 12 } }
            Text { text: "stutters >25 ms: " + frames.jank + " / 10 s"; color: frames.jank > 0 ? "#f87171" : "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 12 } }
            Text { text: "video: " + win.videoFrames + " frames"; color: "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 12 } }
            Text { text: win.lastInput; color: "#8b97ab"; font { family: "DejaVu Sans Mono"; pixelSize: 12 } }
        }
    }

    // Simulated game (game mode): used by the diagnostics VRAM test.
    Rectangle {
        visible: win.overlay === "launch"
        anchors.fill: parent
        color: "black"
        z: 30
        Text { anchors.centerIn: parent; text: qsTr("Game mode (test) — B to go back"); color: "#8b97ab"; font { family: theme.fontFamily; pixelSize: 16 } }
    }

    DownloadsPanel {
        id: downloadsPanel
        theme: win.theme
        z: 60
        onCancel: (d) => win.api("DELETE", "/api/v1/downloads/" + d.id, null, function () { win.refreshDownloads() })
        onRetry: (d) => win.api("POST", "/api/v1/games/" + d.rom_id + "/download", {}, function (r, err) { if (err) toasts.show(err, "error"); win.refreshDownloads() })
    }
    ActionMenu { id: menu; theme: win.theme; z: 80 }
    Toasts {
        id: toasts
        theme: win.theme
        z: 90
        anchors { right: parent.right; rightMargin: 24; bottom: parent.bottom; bottomMargin: 64 }
    }

    // ---------- Frame timing ----------
    QtObject {
        id: frames
        property var ring: []
        property real fps: 0
        property real p95: 0
        property real p99: 0
        property int jank: 0
        property var recording: null
        function summarize(a) {
            const s = a.filter(t => t > 0).sort((x, y) => x - y)
            if (!s.length) return { frames: 0, fps_avg: 0, ms_avg: 0, ms_p95: 0, ms_p99: 0, ms_max: 0, janks: 0 }
            const sum = s.reduce((x, y) => x + y, 0)
            const q = p => s[Math.min(s.length - 1, Math.floor(p * s.length))]
            const r = v => Math.round(v * 10) / 10
            return { frames: s.length, fps_avg: r(1000 / (sum / s.length)), ms_avg: r(sum / s.length), ms_p95: r(q(0.95)), ms_p99: r(q(0.99)), ms_max: r(s[s.length - 1]), janks: s.filter(t => t > 25).length }
        }
    }
    FrameAnimation {
        running: true
        property real acc: 0
        onTriggered: {
            const ms = frameTime * 1000
            frames.ring.push(ms)
            if (frames.ring.length > 600) frames.ring.shift()
            if (frames.recording) frames.recording.push(ms)
            if (win.themeApplyStart > 0) { win.themeApplyMs = Date.now() - win.themeApplyStart; win.themeApplyStart = 0 }
            acc += frameTime
            if (acc > 0.5) {
                acc = 0
                const s = frames.summarize(frames.ring)
                frames.fps = Math.round(s.fps_avg); frames.p95 = s.ms_p95; frames.p99 = s.ms_p99; frames.jank = s.janks
            }
        }
    }
    readonly property int videoFrames: (bgLoader.item ? bgLoader.item.framesDecoded : 0)
                                       + (libraryLoader.item && libraryLoader.item.stage ? libraryLoader.item.stage.framesDecoded : 0)

    // ---------- Theme picker ----------
    Rectangle {
        id: themePicker
        visible: win.overlay === "theme"
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.6)
        property int index: 0
        property var original: null
        function open() {
            original = win.currentTheme
            index = Math.max(0, win.themeEntries.indexOf(win.currentTheme))
            win.overlay = "theme"
        }
        function preview(i) {
            index = i
            const t = win.themeEntries[i]
            if (t && t !== win.currentTheme) win.applyTheme(t)
        }
        function handle(a) {
            const n = win.themeEntries.length
            if (a === "up") preview((index - 1 + n) % n)
            else if (a === "down") preview((index + 1) % n)
            else if (a === "a") { prefs.theme = win.currentTheme ? win.currentTheme.id : ""; win.overlay = "" }
            else if (a === "b" || a === "y") { if (original && original !== win.currentTheme) win.applyTheme(original); win.overlay = "" }
        }
        Rectangle {
            anchors.centerIn: parent
            width: 480; height: tpCol.height + 56; radius: theme.radius + 4
            color: theme.panel; border.color: theme.panelBorder
            Column {
                id: tpCol; x: 28; y: 28; width: parent.width - 56; spacing: 12
                Text { text: qsTr("Theme"); color: theme.fg; font { family: theme.displayFont; pixelSize: 24; bold: true } }
                Menu {
                    width: parent.width; theme: win.theme; currentIndex: themePicker.index
                    items: win.themeEntries.map(t => ({ label: t.name, detail: [t.builtin ? qsTr("built-in") : qsTr("user"), t.layout === "grid" ? qsTr("grid view") : qsTr("detailed view"), t.files.indexOf("Card.qml") >= 0 ? qsTr("custom posters") : ""].filter(x => x).join(" · ") }))
                }
                Text { text: qsTr("Applied in %1 ms (NFR-19 target: < 1000 ms)").arg(win.themeApplyMs); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
                Rectangle {
                    visible: win.themeRejected.length > 0
                    width: parent.width; height: rj.height + 20; radius: 8; color: Qt.rgba(0.97, 0.44, 0.44, 0.12)
                    Column {
                        id: rj; x: 10; y: 10; width: parent.width - 20
                        Text { text: qsTr("Ignored themes"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 13; bold: true } }
                        Repeater {
                            model: win.themeRejected
                            Text { required property var modelData; width: rj.width; wrapMode: Text.WrapAnywhere; maximumLineCount: 3; elide: Text.ElideRight; text: modelData.source + ": " + modelData.reason; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 12 } }
                        }
                    }
                }
                Text { text: qsTr("A  Keep      B  Cancel"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
            }
        }
    }

    // ---------- Diagnostics ----------
    Rectangle {
        id: diag
        visible: win.overlay === "diag"
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.6)
        property int index: 0
        property var diagData: null
        property var report: null
        property string reportPath: ""
        property var vramTest: null
        function refresh() { win.api("GET", "/api/v1/diagnostics", null, function (d) { if (d) diag.diagData = d }) }
        function open() { index = 0; refresh(); win.overlay = "diag" }
        readonly property var items: [
            { id: "bench", label: bench.running ? qsTr("Benchmark running…") : qsTr("Run the automatic benchmark (≈ 40 s)") },
            { id: "vram", label: vramTest && vramTest.running ? qsTr("Game mode test running…") : qsTr("Test game mode (VRAM freed)") },
            { id: "export", label: qsTr("Export the last report"), disabled: !report },
            { id: "trailers", label: win.trailers ? qsTr("Trailers: on") : qsTr("Trailers: off") },
            { id: "fullscreen", label: qsTr("Toggle full screen") },
            { id: "quit", label: qsTr("Quit Borne") },
            { id: "close", label: qsTr("Close") }
        ]
        function handle(a) {
            const n = items.length
            const id = items[index].id
            if (a === "up") index = (index - 1 + n) % n
            else if (a === "down") index = (index + 1) % n
            else if (a === "a") {
                if (id === "bench" && !bench.running) bench.start()
                else if (id === "vram" && !(vramTest && vramTest.running)) gameModeTest.begin()
                else if (id === "export" && report) win.api("POST", "/api/v1/report", JSON.stringify(report, null, 2), function (r) { if (r) diag.reportPath = r.path })
                else if (id === "trailers") win.trailers = !win.trailers
                else if (id === "fullscreen") win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
                else if (id === "quit") Qt.quit()
                else if (id === "close") win.overlay = ""
            } else if (a === "b" || a === "start") win.overlay = ""
        }
        Timer { interval: 3000; repeat: true; running: diag.visible; onTriggered: diag.refresh() }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(1180, parent.width - 60); height: Math.min(parent.height - 40, 680)
            radius: theme.radius + 4; color: theme.panel; border.color: theme.panelBorder
            clip: true
            Text { x: 32; y: 24; text: qsTr("Diagnostics"); color: theme.fg; font { family: theme.displayFont; pixelSize: 24; bold: true } }
            Column {
                x: 32; y: 72; width: parent.width * 0.4 - 32; spacing: 14
                Menu { width: parent.width; theme: win.theme; currentIndex: diag.index; items: diag.items }
                Text { visible: diag.report !== null; text: qsTr("LAST BENCHMARK"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 12; letterSpacing: 1 } }
                KeyValues {
                    visible: diag.report !== null; width: parent.width; theme: win.theme; keyWidth: 200
                    rows: diag.report ? [
                        [qsTr("frames measured"), diag.report.frames.frames], [qsTr("average fps"), diag.report.frames.fps_avg],
                        ["p95 / p99 / max (ms)", diag.report.frames.ms_p95 + " / " + diag.report.frames.ms_p99 + " / " + diag.report.frames.ms_max],
                        [qsTr("stutters > 25 ms"), diag.report.frames.janks], [qsTr("video frames"), diag.report.video_frames],
                        [qsTr("memory (core + UI)"), qsTr("%1 MB").arg(diag.report.rss_mb)],
                        [qsTr("verdict"), diag.report.verdict, diag.report.verdict.indexOf("OK") === 0 ? "ok" : "bad"]
                    ] : []
                }
                Text { visible: diag.reportPath !== ""; width: parent.width; wrapMode: Text.WrapAnywhere; text: qsTr("Saved: %1").arg(diag.reportPath); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 12 } }
                KeyValues {
                    visible: diag.vramTest !== null; width: parent.width; theme: win.theme; keyWidth: 200
                    rows: diag.vramTest ? [[qsTr("VRAM before"), qsTr("%1 MB").arg(diag.vramTest.before)], [qsTr("VRAM in game mode"), qsTr("%1 MB").arg(diag.vramTest.during)], [qsTr("VRAM after"), qsTr("%1 MB").arg(diag.vramTest.after)], [qsTr("freed"), qsTr("%1 MB").arg(diag.vramTest.freed), typeof diag.vramTest.freed === "number" ? "ok" : ""]] : []
                }
            }
            Column {
                x: parent.width * 0.4 + 16; y: 72; width: parent.width * 0.6 - 48; spacing: 6
                Text { text: qsTr("SESSION"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 12; letterSpacing: 1 } }
                KeyValues {
                    width: parent.width; theme: win.theme
                    rows: diag.diagData ? [
                        ["gamescope", diag.diagData.in_gamescope ? qsTr("yes") : qsTr("no"), diag.diagData.in_gamescope ? "ok" : ""],
                        [qsTr("launched by Steam"), diag.diagData.in_steam ? qsTr("yes") : qsTr("no")],
                        ["Qt", qsTr("%1 (platform %2)").arg(win.qtVersion).arg(Qt.platform.pluginName)],
                        ["CPU", diag.diagData.cpu],
                        ["GPU", diag.diagData.gpus.join(" · ") || qsTr("unknown")],
                        ["VRAM", diag.diagData.vram_used_mb !== null ? qsTr("%1 / %2 MB").arg(diag.diagData.vram_used_mb).arg(diag.diagData.vram_total_mb) : qsTr("unreadable (no amdgpu)")],
                        [qsTr("VA-API drivers"), diag.diagData.va_drivers.join(", ") || qsTr("none"), diag.diagData.va_drivers.length ? "ok" : "bad"],
                        [qsTr("render node"), diag.diagData.render_node ? "/dev/dri/renderD128" : qsTr("missing"), diag.diagData.render_node ? "ok" : "bad"],
                        [qsTr("memory"), qsTr("%1 MB (%2 processes)").arg(Math.round(diag.diagData.rss_mb)).arg(diag.diagData.processes)],
                        [qsTr("catalog"), qsTr("%1 games shown (loaded in %2 ms)").arg(libModel.count).arg(win.loadMs)],
                        [qsTr("data"), win.status ? win.status.data_dir : "—"],
                        [qsTr("RomM server"), win.status && win.status.server_url ? win.status.server_url + " (" + (win.status.online ? qsTr("online") : qsTr("offline")) + ")" : qsTr("not configured"), win.status && win.status.online ? "ok" : "bad"],
                        [qsTr("core"), win.coreOnline ? qsTr("connected (WebSocket)") : qsTr("unreachable"), win.coreOnline ? "ok" : "bad"],
                        [qsTr("input"), qsTr("keyboard %1 · gamepad (core) %2").arg(win.inputCounts.keyboard || 0).arg(win.inputCounts.pad || 0)]
                    ] : [["", qsTr("loading…")]]
                }
                Text { topPadding: 8; text: qsTr("ENVIRONMENT"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 12; letterSpacing: 1 } }
                KeyValues { width: parent.width; theme: win.theme; size: 11; keyWidth: 260; rows: diag.diagData ? diag.diagData.env : [] }
            }
        }
    }

    // ---------- Game mode test: VRAM before / during / after ----------
    QtObject {
        id: gameModeTest
        function vram(cb) { win.api("GET", "/api/v1/diagnostics", null, function (d) { cb(d && d.vram_used_mb !== null ? d.vram_used_mb : "n/a") }) }
        function begin() {
            diag.vramTest = { running: true, before: "…", during: "…", after: "…", freed: "…" }
            vram(function (before) {
                win.gameMode = true
                Qt.callLater(function () { win.releaseResources() })
                gmTimer.step = 1; gmTimer.before = before; gmTimer.restart()
            })
        }
    }
    Timer {
        id: gmTimer
        interval: 3500
        property int step: 0
        property var before: 0
        property var during: 0
        onTriggered: {
            if (step === 1) {
                gameModeTest.vram(function (v) { gmTimer.during = v; win.gameMode = false; gmTimer.step = 2; gmTimer.restart() })
            } else if (step === 2) {
                gameModeTest.vram(function (v) {
                    diag.vramTest = { running: false, before: gmTimer.before, during: gmTimer.during, after: v, freed: typeof gmTimer.before === "number" && typeof gmTimer.during === "number" ? gmTimer.before - gmTimer.during : "n/a" }
                })
            }
        }
    }

    // ---------- Automatic benchmark ----------
    QtObject {
        id: bench
        property bool running: false
        property var queue: []
        property int videoStart: 0
        property string prevLayout: "grid"
        function start() {
            running = true
            win.overlay = ""
            prevLayout = win.layoutId
            win.systemIndex = 0; win.loadLibrary(true)
            win.layoutId = "grid"
            const q = [{ wait: 800 }, { record: true }]
            const add = (a, times, every) => { if (!times) q.push({ wait: every }); for (let i = 0; i < times; i++) q.push({ action: a, wait: every }) }
            add("right", 30, 90); add("down", 60, 85); add("right", 5, 300)
            add(null, 0, 4500)
            add("down", 25, 120); add("up", 25, 120)
            add(null, 0, 3500)
            add("rb", 4, 700); add("lb", 4, 700)
            q.push({ layout: "list", wait: 600 })
            add("down", 40, 90)
            add(null, 0, 4000)
            q.push({ finish: true, wait: 0 })
            queue = q
            benchTimer.interval = 10
            benchTimer.start()
        }
        function step() {
            const s = queue.shift()
            if (!s) return
            if (s.record) { frames.recording = []; videoStart = win.videoFrames }
            if (s.action) win.move(s.action === "rb" || s.action === "lb" ? "" : s.action)
            if (s.action === "rb") win.setSystem(1)
            if (s.action === "lb") win.setSystem(-1)
            if (s.layout) win.layoutId = s.layout
            if (s.finish) { finish(); return }
            benchTimer.interval = Math.max(1, s.wait || 1)
            benchTimer.start()
        }
        function finish() {
            const f = frames.summarize(frames.recording || [])
            frames.recording = null
            const videoFrames = win.videoFrames - videoStart
            win.layoutId = prevLayout
            win.api("GET", "/api/v1/diagnostics", null, function (d) {
                const verdict = f.fps_avg >= 58 && f.ms_p99 <= 25 ? "OK — smooth (NFR-16)" : f.fps_avg >= 50 ? "Watch — a few stutters" : "Insufficient"
                diag.report = {
                    when: new Date().toISOString(), frontend: "qml", qt: win.qtVersion, platform: Qt.platform.pluginName,
                    games: libModel.count, theme: win.currentTheme ? win.currentTheme.id : "default", trailers: win.trailers,
                    frames: f, video_frames: videoFrames,
                    rss_mb: d ? Math.round(d.rss_mb) : null, vram_used_mb: d ? d.vram_used_mb : null,
                    verdict: verdict, diagnostics: d, game_mode_test: diag.vramTest
                }
                diag.reportPath = ""
                bench.running = false
                diag.open()
            })
        }
    }
    Timer { id: benchTimer; onTriggered: bench.step() }

    Rectangle {
        visible: bench.running
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
        width: bb.implicitWidth + 28; height: 30; radius: 15; color: theme.accent
        Text { id: bb; anchors.centerIn: parent; text: qsTr("Benchmark running — don't touch anything"); color: theme.accentFg; font { family: theme.fontFamily; pixelSize: 13; bold: true } }
    }

    // Light preferences stored by Qt (~/.config/Borne/Borne.conf).
    Settings {
        id: prefs
        category: "ui"
        property string theme: ""
        property string layout: ""
    }
    onLayoutIdChanged: if (ready && !bench.running) prefs.layout = layoutId

    Component.onCompleted: {
        if (!apiBase) return
        api("GET", "/api/v1/hello", null, function (h, err) {
            if (err || !h) { fatal = qsTr("Borne core unreachable (%1)").arg(err); return }
            if (h.api !== 1) { fatal = qsTr("Incompatible API version: core %1, UI 1").arg(h.api); return }
            loadThemes(function () {
                // Safe mode: ignore the saved theme (it may be what caused the crashes).
                const want = safeMode ? "nocturne" : (prefs.theme || "nocturne")
                const entry = themeEntries.find(t => t.id === want) || themeEntries.find(t => t.id === "nocturne")
                if (entry) { applyTheme(entry); layoutId = prefs.layout || entry.layout }
                refreshStatus(function (s) {
                    if (!s) { fatal = qsTr("Borne core unreachable"); return }
                    if (!s.server_url) showServer()
                    else showProfiles()
                })
            })
        })
    }
}
