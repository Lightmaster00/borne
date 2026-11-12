// Borne — QML UI.
// All data comes from the Rust core through the local API (HTTP); events
// (gamepads, pairing, sync, downloads) through the WebSocket. No business logic here.
// The scene is laid out at 1920×1080 and scaled to the window.
import QtQuick
import QtQuick.Window
import QtCore
import QtWebSockets
import QtMultimedia
import QtQuick.Effects
import Borne.Theme
import "components"
import "components/Display.js" as Display
import "components/Cases.js" as Cases
import "components/CoreText.js" as CoreText

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
    property var systems: []
    property int systemIndex: 0
    property int focusIndex: 0
    property string overlay: ""          // "", "diag", "launch", "game", "settings"
    property bool hud: false
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
    property var letters: []             // first letters present in the list, in order
    property var letterStart: ({})       // letter -> index of its first game
    property string coreVersion: ""
    property var reportPaths: []
    property double clock: Date.now()

    ListModel { id: libModel }
    Theme { id: graphite }
    readonly property QtObject theme: graphite

    readonly property var focusedGame: {
        libRevision
        return libModel.count ? libModel.get(Math.min(focusIndex, libModel.count - 1)) : null
    }
    readonly property bool trailers: prefs.trailers
    readonly property var activeProfile: status ? status.active_profile : null
    readonly property bool textEntry: screen === "server" || nameEntry.visible
    readonly property string uiLang: Qt.locale().name.substring(0, 2)
    property var settings: ({ install_mode: "download", stream: { available: false, error: "" } })
    // Game page
    property var page: null              // API answer for the open game
    property var pageGame: null          // its shown version, as a library row

    // ---------- Local API ----------
    function api(method, path, body, cb) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            let data = null
            try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null } catch (e) { data = null }
            if (xhr.status >= 200 && xhr.status < 300) cb && cb(data, null)
            else cb && cb(null, data && data.error ? CoreText.tr(data.error) : (xhr.status === 0 ? qsTr("core unreachable") : qsTr("error %1").arg(xhr.status)))
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
            dl_total: g.download_total || 0, dl_error: g.download_error || "", hue: (g.rom_id * 47) % 360,
            linked: !!g.linked, version_count: g.version_count || 1, other_installed: !!g.other_installed,
            group_key: g.group_key || "",
            favourite: !!g.favourite, last_played: g.last_played || 0, alt_names: g.alt_names || "",
            // The revision changes when a game's images are corrected, so they are asked again.
            art: apiBase + "/api/v1/games/" + g.rom_id + "/art/" + artRev + "/",
            art_kinds: "," + (g.art_kinds || []).join(",") + ",",
            // Pixel sizes of the case scans: the box is shaped before the images load.
            front_ar: g.media_sizes && g.media_sizes.front ? g.media_sizes.front[0] / g.media_sizes.front[1] : 0,
            side_ar: g.media_sizes && g.media_sizes.side ? g.media_sizes.side[0] / g.media_sizes.side[1] : 0,
            cover_ar: g.cover_ar || 0
        }
    }
    // The console the screen is dressed in: the open game's, else the selected console tab's, else
    // the selected game's. Its colour is the accent; its blank Steam grid frames the screen.
    property var consoleFrames: ({})
    readonly property string consoleSlug: {
        if (overlay === "game" && pageGame) return pageGame.platform_slug || ""
        const s = systems[systemIndex]
        if (s && ["local", "fav", "recent"].indexOf(s.id) < 0) return s.id
        return focusedGame ? focusedGame.platform_slug || "" : ""
    }
    readonly property color consoleTint: Cases.tint(consoleSlug)
    onConsoleTintChanged: graphite.accent = consoleTint
    readonly property bool framed: !gameMode
    readonly property real frameMargin: framed ? Math.round(Math.min(width, height) * 0.036) : 0
    property int artRev: 0
    property int platformsSeq: 0
    function loadPlatforms() {
        // Only the latest request's answer is used (a profile switch can cross an older one).
        const seq = ++platformsSeq
        api("GET", "/api/v1/library/tabs", null, function (tabs) {
          api("GET", "/api/v1/platforms", null, function (list) {
            if (!list || seq !== platformsSeq) return
            const current = systems[systemIndex] ? systems[systemIndex].id : ""
            // The player's own tabs, only when they hold something; then one tab per console.
            const sys = []
            if (tabs && tabs.local > 0) sys.push({ id: "local", name: qsTr("Installed", "systems bar") })
            if (tabs && tabs.fav > 0) sys.push({ id: "fav", name: qsTr("Favourites") })
            if (tabs && tabs.recent > 0) sys.push({ id: "recent", name: qsTr("Recent") })
            // Short names for the systems bar (RomM returns full names).
            const shortNames = { "nes": "NES", "snes": "Super Nintendo", "n64": "Nintendo 64", "gb": "Game Boy", "gbc": "Game Boy Color",
                            "gba": "Game Boy Advance", "nds": "Nintendo DS", "genesis": "Mega Drive", "sms": "Master System",
                            "ngc": "GameCube", "wii": "Wii", "wiiu": "Wii U", "switch": "Switch", "ps": "PlayStation", "psx": "PlayStation",
                            "ps2": "PS2", "ps3": "PS3", "psp": "PSP", "dc": "Dreamcast", "saturn": "Saturn", "arcade": "Arcade" }
            const frames = {}
            for (const p of list) {
                sys.push({ id: p.slug, name: shortNames[p.slug] || p.name })
                if (p.art_kinds && p.art_kinds.indexOf("frame") >= 0) frames[p.slug] = apiBase + "/api/v1/systems/" + p.slug + "/art/frame"
            }
            consoleFrames = frames
            systems = sys
            systemIndex = Math.max(0, sys.findIndex(s => s.id === current))
            // The open tab went away (emptied) or this is the first list: show the one now open.
            if (sys.length && sys[systemIndex].id !== current) loadLibrary(true)
          })
        })
    }
    property int libSeq: 0
    // Reloads the list keeping the selection; updates in place if the list did not change.
    function loadLibrary(resetFocus) {
        const s = systems[systemIndex] || systems[0]
        if (!s) { libModel.clear(); return }
        const tab = s.id === "local" ? "&local=1" : s.id === "fav" ? "&fav=1" : s.id === "recent" ? "&recent=1" : "&platform=" + encodeURIComponent(s.id)
        // The Recent tab is always newest first; the others follow the chosen order and genre.
        const order = s.id === "recent" ? "played" : prefs.librarySort
        const q = "?lang=" + uiLang + tab + "&sort=" + order + (prefs.libraryGenre ? "&genre=" + encodeURIComponent(prefs.libraryGenre) : "")
        const keep = !resetFocus && focusedGame ? focusedGame.rom_id : -1
        const t0 = Date.now()
        // Tabs switched quickly: only the latest request's answer is shown (answers can cross).
        const seq = ++libSeq
        api("GET", "/api/v1/library" + q, null, function (list, err) {
            if (seq !== libSeq) return
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
            const starts = {}, order = []
            rows.forEach((r, i) => { const l = letterOf(r.name); if (starts[l] === undefined) { starts[l] = i; order.push(l) } })
            letterStart = starts
            letters = order
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
            libModel.setProperty(i, "dl_error", CoreText.tr(m.error || ""))
            libRevision++
        }
        const name = i !== undefined && i < libModel.count ? libModel.get(i).name : qsTr("The game")
        if (m.state === "done") toasts.show(qsTr("%1 is installed.").arg(name), "ok")
        if (m.state === "failed") toasts.show(qsTr("%1: %2").arg(name).arg(m.error ? CoreText.tr(m.error) : qsTr("download failed")), "error")
        if (downloadsPanel.visible) downloadsRefresh.restart()
        if (page && page.versions.some(v => v.rom_id === m.rom_id)) pageReload.restart()
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
        if (focusedGame) openGame(focusedGame.rom_id)
    }
    // ---------- Game page ----------
    function openGame(romId) {
        api("GET", "/api/v1/games/" + romId + "?lang=" + uiLang, null, function (d, err) {
            if (!d) { toasts.show(err, "error"); return }
            const first = page === null || overlay !== "game"
            page = d
            pageGame = toRow(d.game)
            if (first) { pageFacts = null; gamePage.reset(); resetTurn(); overlay = "game"; sfx.play("accept") }
            loadFacts(romId)
            loadTrailer(pageGame)
        })
    }
    // Trailer: the core fetches it once from RomM (with the token) and plays it from disk.
    property string pageTrailer: ""
    property string pageTrailerState: ""   // "", "loading", "ready", "error: …"
    function loadTrailer(g) {
        if (!g || !g.trailer) { pageTrailer = ""; pageTrailerState = ""; return }
        if (pageTrailerState === "loading" && pageTrailerFor === g.rom_id) return
        pageTrailerFor = g.rom_id
        pageTrailer = ""
        pageTrailerState = "loading"
        api("POST", "/api/v1/games/" + g.rom_id + "/trailer", {}, function (r, err) {
            if (pageTrailerFor !== g.rom_id) return
            if (r && r.path) { pageTrailer = fileUrl(r.path, 0); pageTrailerState = "ready" }
            else pageTrailerState = "error: " + (err || "")
        })
    }
    property int pageTrailerFor: -1
    // Video background: once the selection rests, the core fetches a video of the game being
    // played (ScreenScraper's gameplay capture, else RomM's trailer) and the library plays it.
    property string bgVideo: ""
    property int bgVideoFor: -1
    readonly property bool bgVideoWanted: win.trailers
                                          && win.screen === "library" && win.overlay === ""
    Timer {
        id: bgVideoDelay
        interval: 900
        onTriggered: {
            const g = win.focusedGame
            if (!g || !win.bgVideoWanted || g.rom_id === win.bgVideoFor) return
            win.bgVideoFor = g.rom_id
            win.bgVideo = ""
            api("POST", "/api/v1/games/" + g.rom_id + "/gameplay", {}, function (r) {
                if (win.bgVideoFor === g.rom_id && r && r.path) win.bgVideo = fileUrl(r.path, 0)
            })
        }
    }
    onFocusedGameChanged: {
        if (focusedGame && focusedGame.rom_id === bgVideoFor) return
        bgVideo = ""; bgVideoFor = -1
        if (bgVideoWanted) bgVideoDelay.restart()
    }
    onBgVideoWantedChanged: if (bgVideoWanted && bgVideoFor === -1) bgVideoDelay.restart()
    // Attract: after 5 s without input on the library, once the selected game's video plays, the
    // library fades out and leaves the video; any input brings it back (that input only wakes it).
    // Turning the box (stick or W A S D) counts as input.
    property double lastActivity: Date.now()
    property bool attract: false
    readonly property bool attractAllowed: screen === "library" && overlay === "" && ready && !gameMode
                                           && !menu.visible && !search.visible && !downloadsPanel.visible
                                           && !nameEntry.visible && !turning
                                           && libModel.count > 0 && ambience.videoShown
    onAttractAllowedChanged: if (!attractAllowed) attract = false
    function touch() {
        lastActivity = Date.now()
        if (!attract) return false
        attract = false
        return true
    }
    Timer {
        interval: 250; repeat: true
        running: win.attractAllowed && !win.attract
        onTriggered: if (Date.now() - win.lastActivity >= 5000) win.attract = true
    }
    onTurnXChanged: touch()
    onTurnYChanged: touch()
    // Studios, series and screenshots (RomM).
    property var pageFacts: null
    function loadFacts(romId) {
        api("GET", "/api/v1/games/" + romId + "/facts?lang=" + uiLang, null, function (f) {
            if (f && page && page.versions.some(v => v.rom_id === romId)) pageFacts = f
        })
    }
    function reloadGame() { if (page && overlay === "game") openGame(page.game.rom_id) }
    Timer { id: pageReload; interval: 250; onTriggered: win.reloadGame() }
    function closeGame() {
        overlay = ""
        page = null
        pageGame = null
        pageFacts = null
        pageTrailer = ""; pageTrailerState = ""; pageTrailerFor = -1
        libReload.restart()
    }
    function link(g) {
        api("POST", "/api/v1/games/" + g.rom_id + "/link", {}, function (r, err) {
            if (err) toasts.show(err, "error")
            else toasts.show(qsTr("%1 is ready to play from the network.").arg(g.name), "ok")
            reloadGame(); libReload.restart()
        })
    }
    function unlink(g) {
        api("DELETE", "/api/v1/games/" + g.rom_id + "/link", null, function (r, err) {
            if (err) toasts.show(err, "error")
            reloadGame(); libReload.restart()
        })
    }
    // Playing: the core starts the emulator; Borne steps aside (game mode) until it quits.
    property var session: null
    function play(g) {
        if (session && session.running) return
        sfx.play("accept")
        api("POST", "/api/v1/games/" + g.rom_id + "/play", {}, function (r, err) {
            if (err) { toasts.show(err, "error"); return }
            if (r && r.installing) { toasts.show(qsTr("Installing %1… the game starts as soon as it is ready.").arg(r.installing), "info"); return }
            onSession(r)
        })
    }
    function onSession(s) {
        session = s
        if (s && s.running) { gameMode = true; quitChord.armed = false }
        else {
            gameMode = false
            if (s && s.error) toasts.show(CoreText.tr(s.error), "error")
            else if (s && s.saves) toasts.show(s.saves === "save sent to RomM" ? qsTr("Save sent to RomM.") : qsTr("RomM unreachable: the save will be sent later."), "info")
            reloadGame(); libReload.restart()
        }
    }
    // While a game runs, Select then Start (within half a second) quits it.
    QtObject {
        id: quitChord
        property bool armed: false
        property double at: 0
        function feed(a) {
            if (a === "select") { armed = true; at = Date.now(); return }
            if (a === "start" && armed && Date.now() - at < 500) {
                armed = false
                api("POST", "/api/v1/session/stop", {}, function () {})
                return
            }
            armed = false
        }
    }
    // Cheats of the shown version: a list to turn them on and off (kept per profile).
    function cheatsMenu(g, at) {
        api("GET", "/api/v1/games/" + g.rom_id + "/cheats", null, function (c, err) {
            if (err || !c) { toasts.show(err || qsTr("Cheats unavailable"), "error"); return }
            // PS2: no public database; the player gives a .pnach for the game.
            const ps2 = g.platform_slug === "ps2"
            const pnachItems = ps2 ? [{ id: "pnach-pick", label: qsTr("Add a .pnach file…"), detail: qsTr("From this computer") },
                                      { id: "pnach-path", label: qsTr("Type the file's path…") },
                                      { id: "pnach-url", label: qsTr("From a link…") }] : []
            function pnach(id) {
                const send = function (body) {
                    api("POST", "/api/v1/games/" + g.rom_id + "/cheats/file", body, function (r, err) {
                        if (err) toasts.show(err, "error")
                        else { toasts.show(qsTr("%n cheat(s) found in the file.", "", r.cheats), "info"); cheatsMenu(g) }
                    })
                }
                if (id === "pnach-pick") send({ pick: true })
                else if (id === "pnach-path") nameEntry.open(qsTr("Path of the .pnach file"), "", function (t) { send({ path: t }) }, "/home/…/game.pnach")
                else if (id === "pnach-url") nameEntry.open(qsTr("Link to the .pnach file"), "", function (t) { send({ url: t }) }, "https://…")
            }
            if (!c.cheats.length) {
                const why = ps2 ? qsTr("PS2 cheats come from a .pnach file you give for this game (PCSX2's format).")
                          : c.updating ? qsTr("Downloading the cheat databases… try again in a moment.")
                          : c.error ? CoreText.tr(c.error) : qsTr("No cheats for this version of the game in the public databases.")
                menu.open(qsTr("Cheats"), why, pnachItems.concat([{ id: "close", label: qsTr("Close") }]), function (id) { pnach(id) })
                return
            }
            const on = c.cheats.filter(x => x.on).map(x => x.name)
            const items = c.cheats.map((x, i) => ({ id: String(i), label: (x.on ? "● " : "○ ") + x.name }))
            items.push({ id: "none", label: qsTr("Turn all off"), disabled: on.length === 0 })
            for (const p of pnachItems) items.push(p)
            items.push({ id: "close", label: qsTr("Close") })
            const sub = qsTr("%n cheat(s) on. They apply the next time the game starts.", "", on.length)
            menu.open(qsTr("Cheats · %1").arg(g.name), sub, items, function (id) {
                if (id === "close") return
                if (id.indexOf("pnach-") === 0) { pnach(id); return }
                let next = on.slice()
                let idx = items.findIndex(x => x.id === id)
                if (id === "none") next = []
                else {
                    const name = c.cheats[Number(id)].name
                    next = next.indexOf(name) >= 0 ? next.filter(n => n !== name) : next.concat([name])
                }
                api("POST", "/api/v1/games/" + g.rom_id + "/cheats", { on: next }, function (r, err2) {
                    if (err2) toasts.show(err2, "error")
                    cheatsMenu(g, idx)
                })
            }, at)
        })
    }
    // A game's own display settings: each line cycles through the values, then back to the one
    // for all games.
    function displayMenu(g, at) {
        api("GET", "/api/v1/games/" + g.rom_id + "/display", null, function (d, err) {
            if (err || !d) { toasts.show(err || "", "error"); return }
            const items = Display.KEYS.map(k => ({ id: k, label: qsTr("%1: %2").arg(Display.title(k)).arg(Display.label(k, d.effective[k])),
                detail: d.own[k] !== undefined ? qsTr("This game only") : qsTr("As for its console") }))
            items.push({ id: "close", label: qsTr("Close") })
            menu.open(qsTr("Display · %1").arg(g.name), qsTr("Applied the next time the game starts."), items, function (k) {
                if (k === "close") return
                const vals = Display.values(k)
                const own = d.own[k]
                // as for all games → the next value → … → the last value → as for all games
                const next = own === undefined ? vals[(vals.indexOf(d.effective[k]) + 1) % vals.length]
                           : vals.indexOf(own) + 1 < vals.length ? vals[vals.indexOf(own) + 1] : "default"
                api("POST", "/api/v1/games/" + g.rom_id + "/display", { key: k, value: next }, function (r, e2) {
                    if (e2) toasts.show(e2, "error")
                    displayMenu(g, Display.KEYS.indexOf(k))
                })
            }, at)
        })
    }
    function pageAction(id, payload) {
        const g = pageGame
        if (id === "back") { sfx.play("back"); closeGame(); return }
        if (!g) return
        if (id === "more") {
            menu.open(g.name, "", payload.concat([{ id: "close", label: qsTr("Close") }]), function (c) {
                if (c === "sound") gamePage.sound = !gamePage.sound
                else if (c !== "close") pageAction(c, null)
            })
        }
        else if (id === "download") download(g)
        else if (id === "link") link(g)
        else if (id === "unlink") unlink(g)
        else if (id === "delete") deleteLocal(g)
        else if (id === "cancel") cancelDownload(g)
        else if (id === "play") play(g)
        else if (id === "cheats") cheatsMenu(g)
        else if (id === "display") displayMenu(g)
        else if (id === "fav") setFavourite(g, !g.favourite)
        else if (id === "images") imagesMenu(g)
        else if (id === "lang") {
            // A language picks the version launched for it.
            api("POST", "/api/v1/games/" + g.rom_id + "/prefs", { version: payload.version, emu_language: payload.code }, function (r, err) {
                if (err) { toasts.show(err, "error"); return }
                if (payload.version !== g.rom_id) openGame(payload.version); else reloadGame()
            })
        }
        else if (id === "version" || id === "language") {
            const body = id === "version" ? { version: payload } : { emu_language: payload }
            api("POST", "/api/v1/games/" + g.rom_id + "/prefs", body, function (r, err) {
                if (err) { toasts.show(err, "error"); return }
                if (id === "version") openGame(payload); else reloadGame()
            })
        }
    }
    // ScreenScraper account: user name then password; the core checks them with ScreenScraper.
    function ssSignIn() {
        nameEntry.open(qsTr("ScreenScraper user name"), "", function (u) {
            nameEntry.open(qsTr("ScreenScraper password"), "", function (p) {
                api("POST", "/api/v1/screenscraper", { user: u, password: p }, function (r, err) {
                    if (err) toasts.show(qsTr("ScreenScraper: %1").arg(err), "error")
                    else toasts.show(qsTr("ScreenScraper connected. Fetching the games' media…"), "info")
                    loadSettings()
                })
            }, qsTr("Password"), true)
        }, qsTr("User name"))
    }
    // Quick menu (Y) on the library: the most common actions without opening the page.
    function gameMenu() {
        const g = focusedGame
        if (!g) return
        const active = ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
        let items = [{ id: "open", label: qsTr("Open the game page") }]
        if (active) items.push({ id: "cancel", label: qsTr("Cancel download") })
        else if (g.local_state === "local") items.push({ id: "delete", label: qsTr("Delete from this device") })
        else if (g.linked) items.push({ id: "unlink", label: qsTr("Remove from the network mount") })
        else {
            items.push({ id: "download", label: qsTr("Download"), detail: fmtSize(g.fs_size) })
            items.push({ id: "link", label: qsTr("Play from the network"), disabled: !settings.stream.available, detail: settings.stream.available ? "" : CoreText.tr(settings.stream.error || "") })
        }
        items.push({ id: "close", label: qsTr("Close") })
        menu.open(g.name, g.platform_name + (g.year > 0 ? " · " + g.year : "") + (g.version_count > 1 ? " · " + qsTr("%n version(s)", "", g.version_count) : ""), items, function (c) {
            if (c === "open") openGame(g.rom_id)
            else if (c === "download") download(g)
            else if (c === "link") link(g)
            else if (c === "unlink") unlink(g)
            else if (c === "cancel") cancelDownload(g)
            else if (c === "delete") deleteLocal(g)
        })
    }
    function loadSettings() { api("GET", "/api/v1/settings", null, function (r) { if (r) settings = r }) }
    function settingsMenu() {
        loadSettings()
        refreshStatus()
        settingsPage.reset()
        overlay = "settings"
    }
    function settingsAction(id, payload) {
        const post = function (body) {
            api("POST", "/api/v1/settings", body, function (r, err) { if (err) toasts.show(err, "error"); else settings = r })
        }
        if (id === "back") { sfx.play("back"); overlay = ""; return }
        sfx.play("accept")
        if (id === "install") {
            if (payload === "stream" && !settings.stream.available) {
                toasts.show(qsTr("Playing from the network is unavailable here: %1").arg(CoreText.tr(settings.stream.error || "")), "error")
                return
            }
            post({ install_mode: payload })
        }
        else if (id === "cache") post({ stream_cache_mb: payload })
        else if (id === "channel") post({ update_channel: payload })
        else if (id === "auto") post({ update_auto: payload })
        else if (id === "savesync") post({ save_sync: payload })
        else if (id === "sounds") prefs.sounds = payload
        else if (id === "trailers") prefs.trailers = payload
        else if (id === "sf-all") api("POST", "/api/v1/system-files/from-romm", {}, function (r, err) {
            if (err) toasts.show(err, "error")
            else toasts.show(r.added > 0 ? qsTr("%n file(s) taken from RomM.", "", r.added) : qsTr("Nothing new to take from RomM."), "info")
            loadSettings()
        })
        else if (id.startsWith("sf-romm:")) {
            const k = id.substring(8).split("/")
            api("GET", "/api/v1/system-files/" + k[0] + "/romm", null, function (c, err) {
                if (err) { toasts.show(err, "error"); return }
                const list = c[k[1]] || []
                if (!list.length) { toasts.show(qsTr("RomM has no file that fits for this console: add it to RomM's BIOS for the platform, or give it here."), "info"); return }
                const items = list.map(f => ({ id: String(f.id), label: f.file_name, detail: fmtSize(f.size) }))
                items.push({ id: "close", label: qsTr("Close") })
                menu.open(qsTr("From RomM"), qsTr("Files RomM keeps for this console"), items, function (fid) {
                    if (fid === "close") return
                    api("POST", "/api/v1/system-files/" + k[0] + "/" + k[1], { romm: Number(fid) }, function (r, err2) { if (err2) toasts.show(err2, "error"); loadSettings() })
                })
            })
        }
        else if (id.startsWith("sf-pick:")) {
            const k = id.substring(8).split("/")
            api("POST", "/api/v1/system-files/" + k[0] + "/" + k[1], { pick: true, title: "Borne" }, function (r, err) {
                if (!err) { loadSettings(); return }
                if (err.indexOf("no file chosen") >= 0) return
                // No file chooser here (game mode…): the path is typed.
                nameEntry.open(qsTr("Full path of the file"), "", function (p) {
                    api("POST", "/api/v1/system-files/" + k[0] + "/" + k[1], { path: p }, function (r2, err2) { if (err2) toasts.show(err2, "error"); loadSettings() })
                }, qsTr("Path"), false, 600)
            })
        }
        else if (id.startsWith("sf-url:")) {
            const k = id.substring(7).split("/")
            nameEntry.open(qsTr("Link to the file (http or https)"), "https://", function (u) {
                api("POST", "/api/v1/system-files/" + k[0] + "/" + k[1], { url: u }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
            }, qsTr("Link"), false, 1000)
        }
        else if (id.startsWith("sf-remove:")) {
            const k = id.substring(10).split("/")
            api("DELETE", "/api/v1/system-files/" + k[0] + "/" + k[1], null, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        }
        else if (id === "display") api("POST", "/api/v1/display", payload, function (r, err) {
            if (err) toasts.show(err, "error")
            if (payload.console) settingsPage.displayView = r; else loadSettings()
        })
        else if (id === "display-scope-menu") {
            const consoles = settings && settings.emulators ? settings.emulators.consoles : []
            const items = [{ id: "", label: qsTr("All games") }].concat(consoles.map(c => ({ id: c.slug, label: c.name })))
            menu.open(qsTr("Display settings for"), "", items, function (slug) { settingsAction("display-scope", slug) },
                      Math.max(0, items.findIndex(i => i.id === settingsPage.displayScope)))
        }
        else if (id === "display-scope") {
            settingsPage.displayScope = payload
            settingsPage.displayView = null
            if (payload) api("GET", "/api/v1/display?console=" + encodeURIComponent(payload), null, function (r) { if (settingsPage.displayScope === payload) settingsPage.displayView = r })
        }
        else if (id === "console-emu") api("POST", "/api/v1/consoles/" + payload.slug + "/emulator", { engine: payload.engine }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id === "emu-auto") api("POST", "/api/v1/emulators/auto-update", { on: payload }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id.startsWith("emu-install:")) api("POST", "/api/v1/emulators/" + id.substring(12) + "/install", {}, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id.startsWith("emu-forget:")) api("POST", "/api/v1/emulators/" + id.substring(11) + "/path", { path: "" }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id.startsWith("emu-path:")) {
            const emu = id.substring(9)
            nameEntry.open(qsTr("Full path of the emulator's program"), "", function (p) {
                api("POST", "/api/v1/emulators/" + emu + "/path", { path: p }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
            }, qsTr("Path"), false, 600)
        }
        else if (id === "ss-pause" || id === "ss-resume") api("POST", "/api/v1/screenscraper/pause", { paused: id === "ss-pause" }, function () { loadSettings() })
        else if (id === "ss-stop") api("POST", "/api/v1/screenscraper/stop", {}, function () { loadSettings() })
        else if (id === "ss-signin") ssSignIn()
        else if (id === "ss-signout") api("DELETE", "/api/v1/screenscraper", null, function () { loadSettings() })
        else if (id === "ss-report") ssReport()
        else if (id === "ss-fetch" || id === "ss-again") api("POST", "/api/v1/screenscraper/fetch", { again: id === "ss-again" }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id === "media-refresh") api("POST", "/api/v1/media/refresh", {}, function (r, err) { if (err) toasts.show(err, "error"); else { toasts.show(qsTr("Fetching the game media again."), "info"); refreshStatus() } })
        else if (id === "sync") api("POST", "/api/v1/sync", {}, function (r, err) { if (err) toasts.show(err, "error"); else { toasts.show(qsTr("Sync started."), "info"); refreshStatus() } })
        else if (id === "server") { overlay = ""; showServer() }
        else if (id === "profile") { overlay = ""; showProfiles() }
        else if (id === "diag") diag.open()
        else if (id === "quit") Qt.quit()
        else if (id === "report") {
            toasts.show(qsTr("Writing the diagnostic report…"), "info")
            api("POST", "/api/v1/diagnostic-report", {}, function (r, err) {
                if (err) { toasts.show(err, "error"); return }
                reportPaths = r.paths
                toasts.show(qsTr("Report saved: %1").arg(r.paths[r.paths.length - 1]), "ok")
            })
        }
        else if (id === "update-check") api("POST", "/api/v1/update/check", {}, function () { loadSettings() })
        else if (id === "update-force") api("POST", "/api/v1/update/check", { force: true }, function () { loadSettings() })
        else if (id === "update-github") {
            const u = settingsPage.upd
            const a = u && settingsPage.updState && settingsPage.updState.available ? settingsPage.updState.available.assets[u.current.platform] : null
            Qt.openUrlExternally(a && a.url ? a.url : (u ? u.release_page : "https://github.com/Lightmaster00/borne/releases"))
        }
        else if (id === "update-download") api("POST", "/api/v1/update/download", {}, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id === "update-apply") {
            api("POST", "/api/v1/update/apply", {}, function (r, err) {
                if (err) { toasts.show(err, "error"); return }
                toasts.show(qsTr("Installing the update: Borne restarts…"), "info")
                quitForUpdate.start()
            })
        }
    }
    // The core restarts on the new version once the UI has quit.
    Timer { id: quitForUpdate; interval: 800; onTriggered: Qt.quit() }
    function onUpdateEvent(u) {
        if (settings && settings.update) {
            const s = Object.assign({}, settings)
            s.update = Object.assign({}, s.update, { update: u })
            settings = s
        }
        if (u.state === "available" && u.available && prefs.notifiedBuild !== u.available.build) {
            prefs.notifiedBuild = u.available.build
            toasts.show(qsTr("Version %1 is available: Settings → Updates.").arg(u.available.version), "info")
        }
    }
    // ScreenScraper corrections from the game page: the box region, or the right game.
    function imagesMenu(g) {
        api("GET", "/api/v1/games/" + g.rom_id + "/screenscraper", null, function (r) {
            const items = []
            const regions = r && r.regions ? r.regions : []
            if (regions.length > 1) {
                items.push({ id: "region:", label: qsTr("Box: automatic"), detail: !r.chosen ? qsTr("Current · follows the interface language") : qsTr("Follows the interface language") })
                for (const x of regions) items.push({ id: "region:" + x, label: qsTr("Box: %1").arg(regionName(x)), detail: r.chosen === x ? qsTr("Current") : "" })
            }
            items.push({ id: "search", label: qsTr("Not the right game?"), detail: qsTr("Search ScreenScraper by name") })
            items.push({ id: "close", label: qsTr("Close") })
            menu.open(qsTr("Images · %1").arg(g.name), qsTr("From ScreenScraper"), items, function (c) {
                if (c.indexOf("region:") === 0) correctImages(g, { region: c.slice(7) })
                else if (c === "search") nameEntry.open(qsTr("Search ScreenScraper"), g.name, function (name) { searchScreenScraper(g, name) }, qsTr("Game name"))
            })
        })
    }
    function regionName(code) {
        const names = { eu: qsTr("Europe"), us: qsTr("USA"), jp: qsTr("Japan"), wor: qsTr("World"), fr: qsTr("France"), de: qsTr("Germany"),
                        uk: qsTr("United Kingdom"), es: qsTr("Spain"), it: qsTr("Italy"), au: qsTr("Australia"), kr: qsTr("Korea"), br: qsTr("Brazil"), ss: qsTr("ScreenScraper") }
        return names[code] || code.toUpperCase()
    }
    function searchScreenScraper(g, name) {
        toasts.show(qsTr("Searching ScreenScraper…"), "info")
        api("GET", "/api/v1/screenscraper/search?q=" + encodeURIComponent(name) + "&platform=" + encodeURIComponent(g.platform_slug || ""), null, function (list, err) {
            if (err) { toasts.show(qsTr("ScreenScraper: %1").arg(err), "error"); return }
            if (!list || !list.length) { toasts.show(qsTr("Nothing found for “%1”.").arg(name), "error"); return }
            menu.open(qsTr("Which game is it?"), qsTr("%n result(s) for “%1”", "", list.length).arg(name),
                      list.map(x => ({ id: "ss:" + x.id, label: x.name, detail: [x.year, x.system, x.publisher].filter(v => v).join(" · ") }))
                          .concat([{ id: "close", label: qsTr("Cancel") }]), function (c) {
                if (c.indexOf("ss:") === 0) correctImages(g, { ss_id: parseInt(c.slice(3)) })
            })
        })
    }
    function correctImages(g, body) {
        api("POST", "/api/v1/games/" + g.rom_id + "/screenscraper", body, function (r, err) {
            if (err) toasts.show(qsTr("ScreenScraper: %1").arg(err), "error")
            else toasts.show(qsTr("Fetching the images again…"), "info")
        })
    }
    // ScreenScraper's report: per console, then the games it did not recognise.
    function ssReport() {
        api("GET", "/api/v1/screenscraper/report", null, function (list, err) {
            if (err || !list) { toasts.show(err || qsTr("No report"), "error"); return }
            menu.open(qsTr("Games found, per console"), qsTr("Choose a console to see the games not found"),
                      list.map(c => ({ id: c.slug, label: c.name, detail: qsTr("%1 found · %2 not found · %3 not looked up").arg(c.found).arg(c.not_found).arg(c.pending), disabled: c.not_found === 0 }))
                          .concat([{ id: "close", label: qsTr("Close") }]), function (slug) {
                const c = list.find(x => x.slug === slug)
                if (!c) return
                menu.open(qsTr("Not found · %1").arg(c.name), qsTr("Open a game to search ScreenScraper for it"),
                          c.missing.map(m => ({ id: "g:" + m.rom_id, label: m.name })).concat([{ id: "close", label: qsTr("Close") }]), function (k) {
                    if (k.indexOf("g:") === 0) { overlay = ""; openGame(parseInt(k.slice(2))) }
                })
            })
        })
    }
    // Favourites (per profile): from the game page or the menu.
    function setFavourite(g, on) {
        api("POST", "/api/v1/games/" + g.rom_id + "/favourite", { on: on }, function (r, err) {
            if (err) { toasts.show(err, "error"); return }
            toasts.show(on ? qsTr("%1 added to your favourites.").arg(g.name) : qsTr("%1 removed from your favourites.").arg(g.name), "info")
            if (page && pageGame && pageGame.rom_id === g.rom_id) reloadGame()
            libReload.restart()
        })
    }
    // Order and genre of the library (kept between sessions).
    function sortMenu() {
        const sorts = [["name", qsTr("By name")], ["played", qsTr("Recently played")], ["added", qsTr("Recently added")], ["time", qsTr("Most played")]]
        const genres = {}
        for (let i = 0; i < libModel.count; i++)
            for (const x of (libModel.get(i).genres || "").split(", ")) if (x) genres[x] = (genres[x] || 0) + 1
        const items = sorts.map(s => ({ id: "sort:" + s[0], label: s[1], detail: prefs.librarySort === s[0] ? qsTr("Current") : "" }))
        items.push({ id: "genre:", label: qsTr("Every genre"), detail: prefs.libraryGenre === "" ? qsTr("Current") : "" })
        for (const k of Object.keys(genres).sort())
            items.push({ id: "genre:" + k, label: k, detail: prefs.libraryGenre === k ? qsTr("Current") : qsTr("%n game(s)", "", genres[k]) })
        if (prefs.libraryGenre && !genres[prefs.libraryGenre]) items.push({ id: "genre:" + prefs.libraryGenre, label: prefs.libraryGenre, detail: qsTr("Current") })
        menu.open(qsTr("Sort and filter"), qsTr("Order of the games, and one genre"), items, function (c) {
            if (c.indexOf("sort:") === 0) prefs.librarySort = c.slice(5)
            else if (c.indexOf("genre:") === 0) prefs.libraryGenre = c.slice(6)
            else return
            loadLibrary(true)
        })
    }
    function mainMenu() {
        const inLib = screen === "library"
        const sync = status ? status.sync : null
        let items = []
        if (inLib) {
            items.push({ id: "sync", label: qsTr("Sync library"), detail: sync && sync.running ? qsTr("In progress…") : (sync && sync.last_sync ? qsTr("Last: %1").arg(new Date(sync.last_sync * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)) : ""), disabled: sync && sync.running })
            items.push({ id: "sort", label: qsTr("Sort and filter"), detail: [{ name: qsTr("by name"), played: qsTr("recently played"), added: qsTr("recently added"), time: qsTr("most played") }[prefs.librarySort] || "", prefs.libraryGenre].filter(x => x).join(" · ") })
            if (focusedGame) items.push({ id: "fav", label: focusedGame.favourite ? qsTr("Remove from favourites") : qsTr("Add to favourites"), detail: focusedGame.name })
            items.push({ id: "downloads", label: qsTr("Downloads") })
            items.push({ id: "profile", label: qsTr("Switch profile"), detail: activeProfile ? activeProfile.name : "" })
        }
        items.push({ id: "settings", label: qsTr("Settings") })
        items.push({ id: "server", label: qsTr("RomM server"), detail: status && status.server_url ? status.server_url : qsTr("not configured") })
        items.push({ id: "diag", label: qsTr("Diagnostics and measurements") })
        items.push({ id: "quit", label: qsTr("Quit Borne") })
        menu.open(qsTr("Menu"), activeProfile && inLib ? qsTr("Profile: %1").arg(activeProfile.name) : "", items, function (c) {
            if (c === "sync") api("POST", "/api/v1/sync", {}, function (r, err) { if (err) toasts.show(err, "error"); else toasts.show(qsTr("Sync started."), "info") })
            else if (c === "downloads") openDownloads()
            else if (c === "sort") sortMenu()
            else if (c === "fav") setFavourite(focusedGame, !focusedGame.favourite)
            else if (c === "settings") settingsMenu()
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
            loadSettings()
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
                  [{ id: "login", label: qsTr("Sign in with the password"), detail: p.romm_user ? p.romm_user : "" },
                   { id: "pair", label: p.paired ? qsTr("Pair with RomM again") : qsTr("Pair with RomM"), detail: qsTr("With a code, from the phone") },
                   { id: "rename", label: qsTr("Rename") },
                   { id: "delete", label: qsTr("Delete profile"), detail: qsTr("Its saves stay on disk") },
                   { id: "close", label: qsTr("Close") }], function (c) {
            if (c === "login") {
                if (p.romm_user) profileLogin(p.romm_user, p.id)
                else nameEntry.open(qsTr("RomM user name"), "", function (u) { profileLogin(u, p.id) }, qsTr("User name"))
            }
            else if (c === "pair") startPairing(p)
            else if (c === "rename") nameEntry.open(qsTr("Rename profile"), p.name, function (name) {
                api("PUT", "/api/v1/profiles/" + p.id, { name: name }, function (r, err) { if (err) toasts.show(err, "error"); showProfiles() })
            })
            else if (c === "delete") menu.open(qsTr("Delete profile “%1”?").arg(p.name), qsTr("Its RomM pairing will be forgotten on this device."),
                                               [{ id: "yes", label: qsTr("Delete") }, { id: "no", label: qsTr("Cancel") }], function (c2) {
                if (c2 === "yes") api("DELETE", "/api/v1/profiles/" + p.id, null, function () { showProfiles() })
            })
        })
    }
    // Adding a profile: pick the RomM account in the server's list (when a profile of an
    // administrator may read it), type its password, done. Otherwise type the account's name; or
    // approve a code from the phone as before.
    function addProfile() {
        api("GET", "/api/v1/romm/accounts", null, function (r) {
            const accounts = r && r.accounts ? r.accounts.filter(a => !a.profile) : null
            const items = []
            if (accounts) for (const a of accounts)
                items.push({ id: "acc:" + a.username, label: a.username, detail: a.role === "admin" ? qsTr("Administrator") : a.role === "viewer" ? qsTr("Viewer") : qsTr("Player") })
            items.push({ id: "other", label: accounts ? qsTr("Another account…") : qsTr("Sign in with name and password"), detail: qsTr("Type the RomM account's name") })
            items.push({ id: "phone", label: qsTr("Approve from the phone"), detail: qsTr("A code to confirm in RomM, no password typed here") })
            items.push({ id: "close", label: qsTr("Cancel") })
            menu.open(qsTr("Add a profile"), accounts && accounts.length ? qsTr("Choose your RomM account") : qsTr("How to connect the RomM account"), items, function (c) {
                if (c.indexOf("acc:") === 0) profileLogin(c.slice(4), "")
                else if (c === "other") nameEntry.open(qsTr("RomM user name"), "", function (u) { profileLogin(u, "") }, qsTr("User name"))
                else if (c === "phone") nameEntry.open(qsTr("New profile"), "", function (name) {
                    api("POST", "/api/v1/profiles", { name: name }, function (p, err) {
                        if (err) { toasts.show(err, "error"); showProfiles(); return }
                        startPairing(p)
                    })
                })
            })
        })
    }
    // Signs a RomM account in with its password (not kept by Borne) and opens its library.
    function profileLogin(username, profileId) {
        nameEntry.open(qsTr("Password for %1").arg(username), "", function (pw) {
            toasts.show(qsTr("Connecting %1…").arg(username), "info")
            api("POST", "/api/v1/profiles/login", { username: username, password: pw, profile_id: profileId }, function (p, err) {
                if (err) {
                    toasts.show(err === "wrong user name or password" ? qsTr("Wrong user name or password.") : qsTr("RomM: %1").arg(err), "error")
                    showProfiles()
                    return
                }
                enterLibrary(p)
            })
        }, qsTr("Password"), true)
    }

    // ---------- Input ----------
    function move(a) {
        const n = libModel.count
        if (!n) return
        let i = focusIndex
        if (a === "left") i -= 1
        else if (a === "right") i += 1
        else if (a === "up") { if (i - libraryView.columns >= 0) i -= libraryView.columns }
        else if (a === "down") {
            const cols = libraryView.columns
            if (Math.floor(i / cols) < Math.floor((n - 1) / cols)) i = Math.min(n - 1, i + cols)
        }
        i = Math.max(0, Math.min(n - 1, i))
        if (i !== focusIndex) sfx.play("move")
        focusIndex = i
    }
    function letterOf(name) {
        const c = (name || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").charAt(0).toUpperCase()
        return c >= "A" && c <= "Z" ? c : "#"
    }
    function openSearch(initial, fromKeyboard) {
        if (!libModel.count) return
        searchReturn = focusIndex
        sfx.play("accept")
        search.open(initial, fromKeyboard)
    }
    property int searchReturn: 0
    function jumpLetter(d) {
        if (!focusedGame || letters.length < 2) return
        const k = letters.indexOf(letterOf(focusedGame.name))
        const next = letters[Math.max(0, Math.min(letters.length - 1, k + d))]
        if (next !== undefined && letterStart[next] !== undefined && letterStart[next] !== focusIndex) {
            focusIndex = letterStart[next]
            sfx.play("move")
            libraryView.showLetter(next)
        }
    }
    function setSystem(d) {
        systemIndex = (systemIndex + d + systems.length) % systems.length
        sfx.play("move")
        loadLibrary(true)
    }

    // ---------- turning the selected box (right stick, or W A S D) ----------
    property real padTurnX: 0
    property real padTurnY: 0
    property var turnKeys: ({})
    readonly property real turnX: Math.max(-1, Math.min(1, padTurnX + (turnKeys.d ? 1 : 0) - (turnKeys.a ? 1 : 0)))
    readonly property real turnY: Math.max(-1, Math.min(1, padTurnY + (turnKeys.s ? 1 : 0) - (turnKeys.w ? 1 : 0)))
    // The stick sets the angle directly (not a speed): the box turns toward where you push, far
    // enough to show its spine well (never its back), and comes back as soon as you let go.
    readonly property real maxYaw: 60
    readonly property real maxPitch: 40
    property real boxYaw: turnX * maxYaw
    property real boxPitch: turnY * maxPitch
    Behavior on boxYaw { SmoothedAnimation { velocity: 160; reversingMode: SmoothedAnimation.Immediate } }
    Behavior on boxPitch { SmoothedAnimation { velocity: 110; reversingMode: SmoothedAnimation.Immediate } }
    readonly property bool turning: turnActive || Math.abs(boxYaw) > 0.5 || Math.abs(boxPitch) > 0.5
    readonly property bool turnActive: Math.abs(turnX) > 0.01 || Math.abs(turnY) > 0.01
    function setTurnKey(k, down) { const t = Object.assign({}, turnKeys); t[k] = down; turnKeys = t }
    function resetTurn() { turnKeys = ({}) }
    onFocusIndexChanged: { resetTurn(); lastActivity = Date.now() }

    function dispatch(a, source) {
        inputCounts[source] = (inputCounts[source] || 0) + 1
        if (source === "pad") graphite.input = "pad"
        inputCountsChanged()
        lastInput = a + " via " + source
        if (touch() && screen === "library" && overlay === "") return
        if (session && session.running) { quitChord.feed(a); return }
        if (bench.running && a !== "start") return
        if (menu.visible) { if (a === "a") sfx.play("accept"); else if (a === "b") sfx.play("back"); else sfx.play("move"); return menu.handle(a) }
        if (nameEntry.visible) return nameEntry.handle(a)
        if (search.visible) { if (a !== "a" && a !== "b") sfx.play("move"); return search.handle(a) }
        if (downloadsPanel.visible) return a === "r3" ? (downloadsPanel.visible = false) : downloadsPanel.handle(a)
        if (overlay === "diag") return diag.handle(a)
        if (overlay === "launch") { if (a === "b") { overlay = ""; gameMode = false } return }
        if (overlay === "settings") { if (a !== "a" && a !== "b") sfx.play("move"); return settingsPage.handle(a) }
        if (overlay === "game") { if (a !== "a" && a !== "b") sfx.play("move"); return gamePage.handle(a) }
        if (screen === "server") return setup.handle(a)
        if (screen === "profiles") return picker.handle(a)
        if (screen === "pairing") return pairingScreen.handle(a)
        if (screen !== "library") return
        if (a === "a") primaryAction()
        else if (a === "y") openSearch("", false)
        else if (a === "x") { if (focusedGame) play(focusedGame) }
        else if (a === "start") settingsMenu()
        else if (a === "select") mainMenu()
        else if (a === "b") { /* root: nothing to close */ }
        else if (a === "lb") setSystem(-1)
        else if (a === "rb") setSystem(1)
        else if (a === "r3") openDownloads()
        else if (a === "lt") jumpLetter(-1)
        else if (a === "rt") jumpLetter(1)
        else move(a)
    }

    // ---------- Library helpers ----------
    readonly property string emptyLibraryText: {
        const st = win.status ? win.status.sync : null
        if (st && st.running) return qsTr("Syncing the library…")
        if (st && st.error && libModel.count === 0) return qsTr("The library could not be synced: %1").arg(CoreText.tr(st.error))
        const tabId = win.systems[win.systemIndex] ? win.systems[win.systemIndex].id : ""
        if (tabId === "fav") return qsTr("No favourites yet. On a game, choose “Add to favourites” (%1 menu or game page).").arg(graphite.key("select"))
        if (tabId === "recent") return qsTr("No game played yet on this profile.")
        if (prefs.libraryGenre) return qsTr("No “%1” game here. Change the genre in %2 → Sort and filter.").arg(prefs.libraryGenre).arg(graphite.key("select"))
        if (win.systems[win.systemIndex] && win.systems[win.systemIndex].id === "local")
            return qsTr("No game installed yet. Open a game in its console’s tab to download it or play it from the network.")
        return qsTr("No games here.")
    }
    function playTimeText() {
        const d = new Date(clock)
        return d.toLocaleTimeString(Qt.locale(), Locale.ShortFormat)
    }
    Timer { interval: 15000; repeat: true; running: true; onTriggered: win.clock = Date.now() }

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
            else if (m.type === "stick") { win.padTurnX = m.x; win.padTurnY = m.y }
            else if (m.type === "download") win.onDownloadEvent(m)
            else if (m.type === "library") libReload.restart()
            else if (m.type === "media") { win.artRev++; libReload.restart(); if (win.page && win.overlay === "game") win.reloadGame() }
            else if (m.type === "platforms") win.loadPlatforms()
            else if (m.type === "session") win.onSession(m.session)
            else if (m.type === "emulators" || m.type === "systemfiles") { if (win.overlay === "settings") loadSettings() }
            else if (m.type === "facts") { if (win.page && win.overlay === "game") win.loadFacts(win.page.game.rom_id) }
            else if (m.type === "update") win.onUpdateEvent(m.update)
            else if (m.type === "screenscraper") { if (win.overlay === "settings") loadSettings() }
            else if (m.type === "sync") {
                if (win.status) { const s = win.status; s.sync = m.sync; win.status = s; win.statusChanged() }
                if (!m.sync.running && m.sync.error) toasts.show(qsTr("Sync: %1").arg(CoreText.tr(m.sync.error)), "error")
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
            acc += frameTime
            if (acc > 0.5) {
                acc = 0
                const s = frames.summarize(frames.ring)
                frames.fps = Math.round(s.fps_avg); frames.p95 = s.ms_p95; frames.p99 = s.ms_p99; frames.jank = s.janks
            }
        }
    }
    readonly property int videoFrames: ambience.framesDecoded

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
        function start() {
            running = true
            win.overlay = ""
            win.systemIndex = 0; win.loadLibrary(true)
            const q = [{ wait: 800 }, { record: true }]
            const add = (a, times, every) => { if (!times) q.push({ wait: every }); for (let i = 0; i < times; i++) q.push({ action: a, wait: every }) }
            add("right", 30, 90); add("down", 60, 85); add("right", 5, 300)
            add(null, 0, 4500)
            add("down", 25, 120); add("up", 25, 120)
            add(null, 0, 3500)
            add("rb", 4, 700); add("lb", 4, 700)
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
            if (s.finish) { finish(); return }
            benchTimer.interval = Math.max(1, s.wait || 1)
            benchTimer.start()
        }
        function finish() {
            const f = frames.summarize(frames.recording || [])
            frames.recording = null
            const videoFrames = win.videoFrames - videoStart
            win.api("GET", "/api/v1/diagnostics", null, function (d) {
                const verdict = f.fps_avg >= 58 && f.ms_p99 <= 25 ? "OK — smooth (NFR-16)" : f.fps_avg >= 50 ? "Watch — a few stutters" : "Insufficient"
                diag.report = {
                    when: new Date().toISOString(), frontend: "qml", qt: win.qtVersion, platform: Qt.platform.pluginName,
                    games: libModel.count, theme: "graphite", trailers: win.trailers,
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

    // ---------- Scene: 1920×1080, scaled to the window ----------
    Item {
        id: scene
        // 1080 logical pixels high; the width follows the screen's shape (16:10, 21:9…) so there
        // are no bars, never narrower than 1600.
        // Inside the console's frame (ConsoleFrame).
        readonly property real k: Math.min((win.height - 2 * win.frameMargin) / 1080, (win.width - 2 * win.frameMargin) / 1600)
        width: (win.width - 2 * win.frameMargin) / k
        height: (win.height - 2 * win.frameMargin) / k
        anchors.centerIn: parent
        scale: k

        // Living background, shared by the library, the game page and the settings.
        Ambience {
            id: ambience
            anchors.fill: parent
            theme: win.theme
            visible: !win.gameMode && (win.screen === "library" || win.overlay !== "")
            game: win.overlay === "game" && win.pageGame ? win.pageGame : win.focusedGame
            trailers: win.trailers && win.screen === "library" && win.overlay === ""
            videoUrl: win.bgVideo
            paused: menu.visible || downloadsPanel.visible || bench.running || nameEntry.visible
            scrims: win.overlay === ""
            attract: win.attract
            dim: win.overlay === "settings" || win.overlay === "diag" ? 0.5 : win.overlay === "game" ? 0.55 : 0
        }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            graphite.input = "keyboard"   // hints now show keyboard keys
            // Text entry: the physical keyboard types directly.
            if (win.textEntry && !menu.visible) {
                const target = nameEntry.visible ? nameEntry : setup
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { e.accepted = true; target.handle("start"); return }
                if (e.key === Qt.Key_Escape) { e.accepted = true; target.handle("select"); return }
                if (e.key === Qt.Key_Backspace) { e.accepted = true; target.backspace(); return }
                if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 32) { e.accepted = true; target.typeText(e.text); return }
            }
            // Search: typing goes into the field; Enter lands on the game, Esc closes.
            if (search.visible && !menu.visible) {
                e.accepted = true
                if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) search.confirm()
                else if (e.key === Qt.Key_Escape) search.close()
                else if (e.key === Qt.Key_Backspace) search.backspace()
                else if (e.key === Qt.Key_Up) search.step(-1)
                else if (e.key === Qt.Key_Down) search.step(1)
                else if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 32) { search.showKeyboard = false; search.typeText(e.text) }
                else if (search.showKeyboard) e.accepted = false
                if (e.accepted) return
            }
            // In the library, Ctrl+F, F or / open the search; other letters start it with that letter.
            if (screen === "library" && overlay === "" && !menu.visible && !nameEntry.visible && !downloadsPanel.visible) {
                const f = e.key === Qt.Key_Slash || (e.key === Qt.Key_F && (e.modifiers & Qt.ControlModifier))
                if (f) { e.accepted = true; openSearch("", true); return }
                const shortcut = [Qt.Key_X, Qt.Key_T, Qt.Key_Y, Qt.Key_M, Qt.Key_Q, Qt.Key_E, Qt.Key_R, Qt.Key_C, Qt.Key_W, Qt.Key_A, Qt.Key_S, Qt.Key_D].indexOf(e.key) >= 0
                if (!shortcut && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier)) && e.text && e.text.length === 1 && (e.text.toLowerCase() !== e.text.toUpperCase() || /[0-9]/.test(e.text))) {
                    e.accepted = true; openSearch(e.text, true); return
                }
            }
            // W A S D turn the selected box (held keys, like a stick).
            const turnKey = { [Qt.Key_W]: "w", [Qt.Key_A]: "a", [Qt.Key_S]: "s", [Qt.Key_D]: "d" }[e.key]
            if (turnKey && !search.visible && !menu.visible && (win.screen === "library" || win.overlay === "game")) {
                e.accepted = true
                if (!e.isAutoRepeat) setTurnKey(turnKey, true)
                return
            }
            const map = {}
            map[Qt.Key_Up] = "up"; map[Qt.Key_Down] = "down"; map[Qt.Key_Left] = "left"; map[Qt.Key_Right] = "right"
            map[Qt.Key_Return] = "a"; map[Qt.Key_Enter] = "a"; map[Qt.Key_Space] = "a"
            map[Qt.Key_Escape] = "b"; map[Qt.Key_Backspace] = "b"
            map[Qt.Key_X] = "x"; map[Qt.Key_T] = "y"; map[Qt.Key_Y] = "y"; map[Qt.Key_F1] = "start"; map[Qt.Key_M] = "start"; map[Qt.Key_F2] = "select"
            map[Qt.Key_PageUp] = "lb"; map[Qt.Key_Q] = "lb"; map[Qt.Key_PageDown] = "rb"; map[Qt.Key_E] = "rb"
            map[Qt.Key_R] = "lt"; map[Qt.Key_C] = "rt"; map[Qt.Key_Tab] = "r3"; map[Qt.Key_Home] = "lt"; map[Qt.Key_End] = "rt"
            const a = map[e.key]
            if (a) { e.accepted = true; dispatch(a, "keyboard") }
        }
        Keys.onReleased: (e) => {
            const turnKey = { [Qt.Key_W]: "w", [Qt.Key_A]: "a", [Qt.Key_S]: "s", [Qt.Key_D]: "d" }[e.key]
            if (turnKey && !e.isAutoRepeat) { e.accepted = true; setTurnKey(turnKey, false) }
        }
    }

    // ---------- Library ----------
    Item {
        id: topbar
        opacity: win.attract ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: win.attract ? 1200 : 350; easing.type: Easing.InOutQuad } }
        y: 40
        width: parent.width; height: 56
        visible: win.screen === "library" && !win.gameMode && win.overlay !== "game" && win.overlay !== "settings"
        // Systems: scrolls to keep the active system visible, without overflowing.
        ListView {
            id: sysBar
            x: 96
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(contentWidth, rightGroup.x - x - 40)
            height: 56
            orientation: ListView.Horizontal
            spacing: 14
            clip: true
            interactive: false
            model: win.systems
            currentIndex: win.systemIndex
            highlightFollowsCurrentItem: true
            highlightRangeMode: ListView.ApplyRange
            preferredHighlightBegin: width * 0.2
            preferredHighlightEnd: width * 0.8
            highlightMoveDuration: theme.scrollMs
            delegate: Item {
                required property var modelData
                required property int index
                readonly property bool cur: index === win.systemIndex
                // A pill: filled with the console's colour when it is the open tab.
                width: (sysLogo.visible ? sysLogo.width : lbl.implicitWidth) + 44; height: 48
                y: 2
                Ink { theme: win.theme; radius: 24; visible: parent.cur }
                Rectangle {
                    anchors.fill: parent
                    radius: 24
                    color: parent.cur ? theme.accent : Qt.rgba(1, 1, 1, 0.06)
                    Behavior on color { ColorAnimation { duration: theme.focusMs } }
                }
                Accessible.role: Accessible.PageTab
                Accessible.name: modelData.name
                Image {
                    id: sysLogo
                    anchors.centerIn: parent
                    visible: status === Image.Ready
                    source: modelData.logo || ""
                    height: 28; width: Math.min(150, implicitWidth * 28 / Math.max(1, implicitHeight))
                    sourceSize.height: 56
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    opacity: parent.cur ? 1 : 0.6
                    Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
                    // On the console's colour, the logo in white.
                    layer.enabled: parent.cur
                    layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
                }
                Text {
                    id: lbl; anchors.centerIn: parent
                    visible: !sysLogo.visible
                    text: modelData.name
                    color: parent.cur ? theme.accentFg : theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 18; weight: Font.Bold }
                }
            }
        }
        Row {
            id: rightGroup
            anchors { right: parent.right; rightMargin: 96; verticalCenter: parent.verticalCenter }
            spacing: 20
            // Sync or downloads in progress: a pill that opens the downloads panel.
            Rectangle {
                readonly property var s: win.status ? win.status.sync : null
                readonly property bool syncing: !!(s && (s.running || s.covers_pending > 0))
                visible: syncing || !win.status || !win.status.online
                anchors.verticalCenter: parent.verticalCenter
                width: pillText.implicitWidth + 32; height: 44; radius: 22
                color: theme.glass
                border { width: 1; color: theme.glassEdge }
                Text {
                    id: pillText
                    anchors.centerIn: parent
                    text: !win.status || !win.status.online ? qsTr("Offline")
                        : !parent.s ? "" : parent.s.running ? qsTr("Syncing %1/%2").arg(parent.s.done).arg(parent.s.total)
                        : qsTr("Covers… %1").arg(parent.s.covers_pending)
                    color: !win.status || !win.status.online ? theme.bad : theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 16 }
                }
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: dlRow.implicitWidth + 20; height: 48; radius: 24
                color: theme.glass
                Ink { z: -1; theme: win.theme; radius: 24; opacity: 0.5 }
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Downloads")
                // Its own button: R3 (right stick click), Tab on the keyboard.
                Row {
                    id: dlRow
                    anchors.centerIn: parent
                    spacing: 2
                    Icon { anchors.verticalCenter: parent.verticalCenter; name: "download"; size: 18; stroke: 2.2; color: theme.fg }
                    HintBar { anchors.verticalCenter: parent.verticalCenter; theme: win.theme; hints: [["R3", qsTr("Downloads"), "r3"]] }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: win.playTimeText()
                color: theme.fgSoft
                font { family: theme.fontFamily; pixelSize: 20; features: { "tnum": 1 } }
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 48; height: 48; radius: 24
                color: theme.accent
                Ink { z: -1; theme: win.theme; radius: 24 }
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Profile: %1").arg(win.activeProfile ? win.activeProfile.name : "")
                Text {
                    anchors.centerIn: parent
                    text: win.activeProfile ? win.activeProfile.name.charAt(0).toUpperCase() : ""
                    color: theme.accentFg
                    font { family: theme.displayFont; pixelSize: 22; weight: Font.Bold }
                }
            }
        }
    }

    LibraryView {
        id: libraryView
        opacity: win.attract ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: win.attract ? 1200 : 350; easing.type: Easing.InOutQuad } }
        anchors.fill: parent
        boxYaw: win.boxYaw
        boxPitch: win.boxPitch
        visible: win.screen === "library" && win.ready && !win.gameMode && win.overlay !== "game" && win.overlay !== "settings"
        theme: win.theme
        games: libModel
        game: win.focusedGame
        currentIndex: win.focusIndex
        sectionTitle: win.systems[win.systemIndex] ? win.systems[win.systemIndex].name : ""
        emptyText: win.emptyLibraryText
        letters: win.letters
        revision: win.libRevision
        currentLetter: win.focusedGame ? win.letterOf(win.focusedGame.name) : ""
    }

    Rectangle {
        id: hintsBar
        opacity: win.attract ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: win.attract ? 1200 : 350; easing.type: Easing.InOutQuad } }
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 20 }
        height: 48
        color: "transparent"
        visible: win.screen === "library" && !win.gameMode && win.overlay !== "game" && win.overlay !== "settings"
        HintBar {
            id: hints
            x: 84; anchors.verticalCenter: parent.verticalCenter
            theme: win.theme
            hints: {
                const g = win.focusedGame
                const h = []
                if (g) h.push(["A", qsTr("Open"), "a"])
                if (g) h.push(["X", qsTr("Play"), "x"])
                h.push(["Y", qsTr("Search"), "y"])
                h.push(["LB RB", qsTr("Systems"), "rb"])
                if (win.letters.length > 1) h.push(["LT RT", qsTr("Letters"), "rt"])
                h.push(["Start", qsTr("Settings"), "start"])
                h.push(["Select", qsTr("Menu"), "select"])
                return h
            }
        }
        Text {
            anchors { right: parent.right; rightMargin: 96; verticalCenter: parent.verticalCenter }
            readonly property var s: win.status ? win.status.sync : null
            text: s && s.last_sync ? qsTr("Synced at %1 · %n game(s)", "", libModel.count).arg(new Date(s.last_sync * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat)) : ""
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 17 }
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
        serverUrl: win.status && win.status.server_url ? win.status.server_url : ""
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
        property string placeholder: qsTr("Profile name")
        property bool secret: false
        property int limit: 80
        function open(t, initial, cb, hint, hidden, limit) {
            title = t; nameKb.text = initial; callback = cb; nameEntry.limit = limit || 80
            placeholder = hint || qsTr("Profile name"); secret = !!hidden
            visible = true
        }
        function handle(a) { nameKb.handle(a) }
        function typeText(t) { nameKb.typeText(t) }
        function backspace() { nameKb.backspace() }
        Column {
            anchors.centerIn: parent
            scale: 1.4
            spacing: 20
            Text { text: nameEntry.title; color: theme.fg; font { family: theme.displayFont; pixelSize: 28; weight: Font.ExtraBold } }
            OnScreenKeyboard {
                id: nameKb
                width: implicitWidth; height: implicitHeight
                theme: win.theme
                maxLength: nameEntry.limit
                placeholder: nameEntry.placeholder
                secret: nameEntry.secret
                onAccepted: (t) => {
                    const name = t.trim()
                    if (!name) return
                    const cb = nameEntry.callback
                    nameEntry.visible = false
                    if (cb) cb(name)
                }
                onCancelled: nameEntry.visible = false
            }
            HintBar {
                theme: win.theme
                hints: [["A", qsTr("Key"), "a", ""], ["B", qsTr("Erase"), "b", "⌫"], ["Start", qsTr("Confirm"), "start", qsTr("Enter")], ["Select", qsTr("Cancel"), "select", qsTr("Esc")]]
            }
        }
    }

    // Status banners
    Rectangle {
        visible: !win.coreOnline && win.screen !== "boot"
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
        width: rc.implicitWidth + 36; height: 40; radius: 20; color: theme.bad
        z: 50
        Text { id: rc; anchors.centerIn: parent; text: qsTr("Borne core unreachable — reconnecting…"); color: "white"; font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold } }
    }
    Rectangle {
        visible: win.safeMode
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 60 }
        width: sm.implicitWidth + 36; height: 40; radius: 20; color: theme.accent
        z: 50
        Text { id: sm; anchors.centerIn: parent; text: qsTr("Safe mode: trailers and sounds off (the UI crashed %n time(s))", "", win.uiRestarts); color: theme.accentFg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold } }
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
        visible: win.overlay === "launch" || !!(win.session && win.session.running)
        anchors.fill: parent
        color: "black"
        z: 30
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: win.session && win.session.running
                  ? qsTr("%1 is running in %2").arg(win.session.name).arg(win.session.emulator) + "\n" + (graphite.input === "keyboard" ? qsTr("Quit the game from the emulator (usually Esc, or its menu)") : qsTr("Select then Start: quit the game"))
                  : (graphite.input === "keyboard" ? qsTr("Game mode (test) — Esc to go back") : qsTr("Game mode (test) — B to go back"))
            color: "#8b97ab"; lineHeight: 1.4
            font { family: theme.fontFamily; pixelSize: 16 }
        }
    }

    GamePage {
        id: gamePage
        anchors.fill: parent
        z: 20
        visible: win.overlay === "game" && win.pageGame !== null
        theme: win.theme
        game: win.pageGame
        versions: win.page ? win.page.versions : []
        emuLanguage: win.page ? win.page.emu_language : "auto"
        gameLanguages: win.page && win.page.languages ? win.page.languages : []
        boxYaw: win.boxYaw
        boxPitch: win.boxPitch
        boxTurning: win.turning
        uiLang: win.uiLang
        installMode: win.page ? win.page.install_mode : "download"
        streamAvailable: win.page ? win.page.stream.available : false
        streamError: win.page && win.page.stream.error ? CoreText.tr(win.page.stream.error) : ""
        trailers: win.trailers
        trailerUrl: win.pageTrailer
        trailerState: win.pageTrailerState
        paused: menu.visible || downloadsPanel.visible || !visible
        facts: win.pageFacts
        shotBase: win.pageGame ? win.apiBase + "/api/v1/games/" + win.pageGame.rom_id + "/screenshots/" : ""
        onAction: (id, payload) => win.pageAction(id, payload)
    }

    SettingsPage {
        id: settingsPage
        anchors.fill: parent
        z: 25
        visible: win.overlay === "settings"
        theme: win.theme
        settings: win.settings
        status: win.status
        version: win.coreVersion
        reportPaths: win.reportPaths
        sounds: prefs.sounds
        trailers: win.trailers
        onAction: (id, payload) => win.settingsAction(id, payload)
    }

    // UI sounds (theme.soundSet), short and quiet; off in the settings.
    QtObject {
        id: sfx
        readonly property string base: win.uiRoot + "/sounds/" + theme.soundSet + "/"
        readonly property bool on: prefs.sounds && theme.soundSet !== "" && !bench.running
        function play(kind) {
            if (!on) return
            const e = kind === "accept" ? sAccept : kind === "back" ? sBack : sMove
            e.play()
        }
    }
    SoundEffect { id: sMove; source: theme.soundSet ? sfx.base + "move.wav" : ""; volume: theme.soundVolume * 0.7 }
    SoundEffect { id: sAccept; source: theme.soundSet ? sfx.base + "accept.wav" : ""; volume: theme.soundVolume }
    SoundEffect { id: sBack; source: theme.soundSet ? sfx.base + "back.wav" : ""; volume: theme.soundVolume }

    DownloadsPanel {
        id: downloadsPanel
        theme: win.theme
        z: 60
        onCancel: (d) => win.api("DELETE", "/api/v1/downloads/" + d.id, null, function () { win.refreshDownloads() })
        onRetry: (d) => win.api("POST", "/api/v1/games/" + d.rom_id + "/download", {}, function (r, err) { if (err) toasts.show(err, "error"); win.refreshDownloads() })
    }
    SearchOverlay {
        id: search
        anchors.fill: parent
        theme: win.theme
        model: libModel
        z: 60
        onPicked: (i) => { if (win.focusIndex !== i) win.focusIndex = i }
    }
    ActionMenu { id: menu; theme: win.theme; z: 80 }
    Toasts {
        id: toasts
        theme: win.theme
        z: 90
        anchors { right: parent.right; rightMargin: 64; bottom: parent.bottom; bottomMargin: 88 }
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
                else if (id === "fullscreen") win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen
                else if (id === "quit") Qt.quit()
                else if (id === "close") win.overlay = ""
            } else if (a === "b" || a === "start") win.overlay = ""
        }
        Timer { interval: 3000; repeat: true; running: diag.visible; onTriggered: diag.refresh() }

        Rectangle {
            anchors.centerIn: parent
            scale: 1.4
            width: 1180; height: 680
            radius: 24; color: theme.panel; border.color: theme.panelBorder
            clip: true
            Text { x: 32; y: 24; text: qsTr("Diagnostics"); color: theme.fg; font { family: theme.displayFont; pixelSize: 24; weight: Font.ExtraBold } }
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

    Rectangle {
        visible: bench.running
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 12 }
        width: bb.implicitWidth + 36; height: 40; radius: 20; color: theme.accent
        Text { id: bb; anchors.centerIn: parent; text: qsTr("Benchmark running — don't touch anything"); color: theme.accentFg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold } }
    }
    }

    // The console's frame round the screen, over everything.
    ConsoleFrame {
        anchors.fill: parent
        visible: win.framed
        tint: win.consoleTint
        art: win.consoleFrames[win.consoleSlug] || ""
        margin: win.frameMargin
        radius: win.frameMargin * 1.1
        ink: graphite.ink
    }

    // Light preferences stored by Qt (~/.config/Borne/Borne.conf).
    Settings {
        id: prefs
        category: "ui"
        property bool sounds: true
        property bool trailers: true
        property string librarySort: "name"
        property string libraryGenre: ""
        property int notifiedBuild: 0
    }

    Component.onCompleted: {
        graphite.accent = consoleTint
        if (!apiBase) return
        api("GET", "/api/v1/hello", null, function (h, err) {
            if (err || !h) { fatal = qsTr("Borne core unreachable (%1)").arg(err); return }
            if (h.api !== 1) { fatal = qsTr("Incompatible API version: core %1, UI 1").arg(h.api); return }
            coreVersion = h.core || ""
            // Safe mode: no video and no sound, the likeliest causes of repeated crashes.
            if (safeMode) { prefs.trailers = false; prefs.sounds = false }
            refreshStatus(function (s) {
                if (!s) { fatal = qsTr("Borne core unreachable"); return }
                if (!s.server_url) showServer()
                else showProfiles()
            })
        })
    }
}
