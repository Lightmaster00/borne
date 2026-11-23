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
import "components/Shelf.js" as Shelf
import "components/ConsoleNeeds.js" as ConsoleNeeds
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
    property int focusIndex: 0           // the selected cover on the shelf (layout.tiles)
    property int focusRom: -1            // its game: kept when the shelf is laid out again
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
    property string coreVersion: ""
    property var reportPaths: []
    property double clock: Date.now()

    ListModel { id: libModel }
    // The hints show the keys of the last device used, unless the settings choose one.
    property string inputSeen: "pad"
    Theme {
        id: graphite
        input: prefs.prompts === "auto" ? win.inputSeen : prefs.prompts
        motion: prefs.motion === "reduced" ? 0.4 : 1
        soundVolume: prefs.soundVolume === "low" ? 0.22 : prefs.soundVolume === "high" ? 0.7 : 0.45
    }
    readonly property QtObject theme: graphite

    // ---------- The shelf ----------
    // Every game of the library (one row per game), loaded once; the shelf shows My library (the
    // games ready here) or the Store (the others), filtered, sorted and grouped by Shelf.js.
    property var rows: []
    // The consoles with games: [{ slug, name, logo, ready, total }], RomM's order.
    property var consoles: []
    property string libTab: "home"       // "home" | "store"
    // Where the selection is on the home: "rail" (the menu on the left), "row" (the recent games),
    // "shelf" (the collections); on the Store: "rail" or "wall" (its consoles).
    property string homeZone: "row"
    property int railIndex: 1
    property int rowIndex: 0
    property int shelfIndex: 0
    // A folder open over the home: a collection, every game, or a console of the Store.
    // { kind: "all" | "fav" | "multi" | "console" | "store", slug, name } or null.
    property var folder: null
    readonly property string consoleFilter: folder && folder.slug ? folder.slug : ""
    readonly property var quick: {
        const q = {}
        if (folder && (folder.kind === "fav" || folder.kind === "multi")) q[folder.kind] = true
        return q
    }
    readonly property string sortId: {
        const ids = Shelf.sortsFor(libTab).map(s => s.id)
        const want = libTab === "store" ? prefs.sortStore : prefs.sortHome
        return ids.indexOf(want) >= 0 ? want : ids[0]
    }
    // A folder's grid, laid out again only when what it shows changes (a download's progress
    // changes a row, not the grid): an unchanged grid keeps its covers as they are.
    property var layout: ({ tiles: [], groups: [], total: 0, count: 0 })
    readonly property double hourClock: Math.floor(clock / 3600000) * 3600000
    function relayout() {
        const l = folder ? Shelf.build(rows, { tab: libTab, console: consoleFilter, quick: quick, genre: "", sort: sortId,
                                               layout: "grid", consoles: orderedConsoles, now: hourClock, fmtSize: fmtSize,
                                               width: home.folderWidth, height: home.folderHeight, tileH: home.folderTileH, justify: true })
                         : { tiles: [], groups: [], total: 0, totalH: 0, vertical: true, count: 0 }
        if (JSON.stringify(l) !== JSON.stringify(layout)) layout = l
        refreshHome()
    }
    // The consoles in the order chosen (Y on the home or the Store), and the player's own order.
    readonly property var customOrder: { try { return JSON.parse(prefs.consoleCustom || "[]") } catch (e) { return [] } }
    readonly property var orderedConsoles: Shelf.orderConsoles(consoles, prefs.consoleOrder, rows, libTab, customOrder)
    readonly property var homeConsoles: Shelf.orderConsoles(consoles, prefs.consoleOrder, rows, "home", customOrder)
    readonly property var storeConsoles: Shelf.orderConsoles(consoles, prefs.consoleOrder, rows, "store", customOrder)
    onOrderedConsolesChanged: relayout()
    // The home's row, its collections and the Store's cards: set only when they change, so the
    // covers stay as they are while a download moves.
    property var recents: []
    property var collections: []
    property var wall: []
    function refreshHome() {
        const set = (k, v) => { if (JSON.stringify(v) !== JSON.stringify(win[k])) win[k] = v }
        set("recents", Shelf.recents(rows, 12))
        set("collections", Shelf.collections(rows, homeConsoles))
        set("wall", Shelf.storeCards(rows, storeConsoles))
    }
    readonly property bool wallMode: libTab === "store" && !folder
    property int wallIndex: 0
    onWallChanged: if (wallIndex >= wall.length) wallIndex = Math.max(0, wall.length - 1)
    onRecentsChanged: if (rowIndex > recents.length) rowIndex = recents.length
    onCollectionsChanged: if (shelfIndex >= collections.length) shelfIndex = Math.max(0, collections.length - 1)
    function openFolder(f) {
        if (!f) return
        sfx.play("accept")
        focusRom = -1
        folder = f
        relayout()
    }
    function closeFolder() {
        sfx.play("back")
        folder = null
        relayout()
    }
    function enterConsole(slug) {
        const c = wall.find(x => x.slug === slug)
        if (c) openFolder({ kind: "store", slug: slug, name: c.name })
    }
    function openCollection(c) {
        if (c) openFolder({ kind: c.kind, slug: c.slug, name: c.name })
    }
    onLibTabChanged: relayout()
    onSortIdChanged: relayout()
    onHourClockChanged: relayout()
    onConsolesChanged: relayout()
    readonly property var focusedTile: folder ? layout.tiles[Math.min(focusIndex, layout.tiles.length - 1)] || null : null
    readonly property var rowGame: libTab === "home" && rowIndex < recents.length && indexByRom[recents[rowIndex]] !== undefined ? rows[indexByRom[recents[rowIndex]]] : null
    // The game selected: in a folder, its cover; on the home's row, its cover.
    readonly property var focusedGame: folder ? (focusedTile ? rows[focusedTile.idx] || null : null)
                                              : homeZone === "row" ? rowGame : null
    // The game behind everything: the one selected, else the collection's or the console's first.
    readonly property var ambientGame: {
        if (focusedGame) return focusedGame
        if (folder) return null
        const byRom = r => indexByRom[r] !== undefined ? rows[indexByRom[r]] : null
        if (libTab === "store") return wall[wallIndex] ? byRom(wall[wallIndex].first) : null
        if (homeZone === "shelf") {
            const c = collections[shelfIndex]
            const list = c ? rows.filter(g => Shelf.ready(g) && (c.kind === "fav" ? g.favourite : c.kind === "multi" ? Shelf.maxPlayers(g) >= 2 : Shelf.tabOf(g.platform_slug) === c.slug)) : []
            if (list.length) return list.sort((a, b) => (b.last_played || 0) - (a.last_played || 0))[0]
        }
        return rowGame || (recents.length ? byRom(recents[0]) : null)
    }
    onRowsChanged: relayout()
    // The grid laid out again (other folder or order): the same game stays selected when it is
    // still there, else the first.
    onLayoutChanged: {
        const t = layout.tiles
        const j = focusRom >= 0 ? t.findIndex(x => rows[x.idx] && rows[x.idx].rom_id === focusRom) : -1
        focusIndex = j >= 0 ? j : 0
        if (j < 0) focusRom = t.length ? rows[t[0].idx].rom_id : -1
    }
    function focusTile(j) {
        if (j < 0 || j >= layout.tiles.length) return
        if (j !== focusIndex) sfx.play("move")
        focusIndex = j
        focusRom = rows[layout.tiles[j].idx].rom_id
    }
    readonly property var shortNames: ({ "nes": "NES", "snes": "Super Nintendo", "n64": "Nintendo 64", "gb": "Game Boy", "gbc": "Game Boy Color",
                                         "gba": "Game Boy Advance", "nds": "Nintendo DS", "genesis": "Mega Drive", "sms": "Master System",
                                         "ngc": "GameCube", "wii": "Wii", "wiiu": "Wii U", "switch": "Switch", "ps": "PlayStation", "psx": "PlayStation",
                                         "ps2": "PS2", "ps3": "PS3", "psp": "PSP", "psvita": "PS Vita", "dc": "Dreamcast", "saturn": "Saturn",
                                         "arcade": "Arcade", "3ds": "3DS", "n3ds": "New 3DS" })
    // Videos: the selected game's behind the library (it plays by itself) and those on a game page.
    readonly property bool bgVideos: prefs.bgVideo
    readonly property bool trailers: prefs.pageVideo
    readonly property bool anyVideo: bgVideos || trailers
    readonly property var activeProfile: status ? status.active_profile : null
    readonly property bool textEntry: screen === "server" || nameEntry.visible
    // The interface's language: chosen in Settings → Language, else the system's.
    readonly property string uiLang: prefs.language !== "auto" ? prefs.language : Qt.locale().name.substring(0, 2)
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
        // The cover: ScreenScraper's front scan when there is one (CD cases without their hinge,
        // the whole box), else RomM's; its proportions with it.
        const artBase = apiBase + "/api/v1/games/" + g.rom_id + "/art/" + (artRevs[g.group_key] || 0) + "/"
        const front = (g.art_kinds || []).indexOf("front") >= 0
        const frontAr = g.media_sizes && g.media_sizes.front ? g.media_sizes.front[0] / g.media_sizes.front[1] : 0
        return {
            rom_id: g.rom_id, name: g.name, platform_name: g.platform_name, platform_slug: g.platform_slug,
            platform_short: shortNames[Shelf.tabOf(g.platform_slug)] || g.platform_name,
            play_seconds: g.play_seconds || 0, released: g.released || 0,
            year: g.year || 0, genres: g.genres || "", regions: g.regions || "", players: g.players || "",
            summary: g.summary || "", fs_size: g.fs_size || 0,
            cover: front ? artBase + "front" : g.cover_local ? fileUrl(g.cover_local, g.cover_stamp) : "",
            trailer: g.video_remote && server ? server + encodeURI(g.video_remote) : "",
            local_state: g.local_state, dl_state: g.download_state || "", dl_received: g.download_received || 0,
            dl_total: g.download_total || 0, dl_error: g.download_error || "", hue: (g.rom_id * 47) % 360,
            linked: !!g.linked, version_count: g.version_count || 1, other_installed: !!g.other_installed,
            group_key: g.group_key || "",
            favourite: !!g.favourite, last_played: g.last_played || 0, alt_names: g.alt_names || "",
            // The revision changes when a game's images are corrected, so they are asked again.
            art: apiBase + "/api/v1/games/" + g.rom_id + "/art/" + (artRevs[g.group_key] || 0) + "/",
            art_kinds: "," + (g.art_kinds || []).join(",") + ",",
            // Pixel sizes of the case scans: the box is shaped before the images load.
            front_ar: g.media_sizes && g.media_sizes.front ? g.media_sizes.front[0] / g.media_sizes.front[1] : 0,
            side_ar: g.media_sizes && g.media_sizes.side ? g.media_sizes.side[0] / g.media_sizes.side[1] : 0,
            cover_ar: front && frontAr > 0 ? frontAr : g.cover_ar || 0,
            spine_color: g.spine_color || ""   // the spine scan's dominant colour: the case's top and bottom
        }
    }
    // The console the screen is dressed in: the open game's, else the selected console tab's, else
    // the selected game's. Its colour is the accent; its blank Steam grid frames the screen.
    // The console the screen is dressed in (border, accent): the open game's, else the one
    // previewed in Filter, else the selected game's, else the console filtered.
    readonly property string consoleSlug: {
        if (overlay === "game" && pageGame) return Shelf.tabOf(pageGame.platform_slug)
        if (screen !== "library") return ""
        if (folder) return consoleFilter || (focusedGame ? Shelf.tabOf(focusedGame.platform_slug) : "")
        if (wallMode) return homeZone === "rail" ? "" : wall[wallIndex] ? wall[wallIndex].slug : ""
        if (homeZone === "shelf") { const c = collections[shelfIndex]; return c && c.slug ? c.slug : "" }
        return focusedGame ? Shelf.tabOf(focusedGame.platform_slug) : ""
    }
    readonly property var consoleInfo: consoles.find(c => c.slug === consoleSlug) || null
    readonly property color consoleTint: consoleSlug ? Cases.tint(consoleSlug) : "#8A8C99"
    onConsoleTintChanged: graphite.accent = consoleTint
    readonly property bool framed: !gameMode
    readonly property real frameMargin: framed ? Math.round(Math.min(width, height) * 0.013) : 0
    // Each game's images' revision: bumped when its own arrive, so only its images reload (never
    // the whole shelf).
    property var artRevs: ({})
    property int platformsSeq: 0
    function loadPlatforms() {
        // Only the latest request's answer is used (a profile switch can cross an older one).
        const seq = ++platformsSeq
        api("GET", "/api/v1/platforms", null, function (list) {
            if (!list || seq !== platformsSeq) return
            const out = [], shapes = {}
            for (const p of list) {
                if (p.case_ar) shapes[p.slug] = p.case_ar   // the cases' shapes from their scans
                const kinds = p.art_kinds || []
                const logo = kinds.indexOf("logo-mono") >= 0 ? "logo-mono" : kinds.indexOf("logo") >= 0 ? "logo" : ""
                out.push({ slug: Shelf.tabOf(p.slug), name: shortNames[p.slug] || p.name,
                           logo: logo ? apiBase + "/api/v1/systems/" + p.slug + "/art/" + logo : "",
                           photo: kinds.indexOf("photo") >= 0 ? apiBase + "/api/v1/systems/" + p.slug + "/art/photo?r=" + (p.photo_rev || "") : "",
                           ready: p.ready_count || 0, total: p.rom_count || 0 })
            }
            Cases.setRatios(shapes)
            consoles = out
            // The console filtered went away (hidden in Settings → Consoles): every console again.
            if (consoleFilter && !out.some(c => c.slug === consoleFilter)) consoleFilter = ""
        })
    }
    // First import: an empty library being filled by its first sync is shown once its games and
    // their covers are in, not while boxes appear bare and get dressed one by one. A shows it at
    // once; two minutes at most.
    property bool importing: false
    property int importCovers: 0
    function checkImport() {
        const s = status && status.sync ? status.sync : null
        if (!s) return
        // Only a library truly empty (its list loaded, no game), not one still being read at start.
        if (!importing && s.running && status.games === 0 && libModel.count === 0 && screen === "library") {
            importing = true; importCovers = 0; importCap.restart()
        }
        if (importing) {
            importCovers = Math.max(importCovers, s.covers_pending || 0)
            if (!s.running && !(s.covers_pending > 0)) { importing = false; maybeAskConsoles() }
        }
    }
    onStatusChanged: checkImport()
    onScreenChanged: checkImport()
    Timer { id: importCap; interval: 120000; onTriggered: { win.importing = false; win.maybeAskConsoles() } }
    property int libSeq: 0
    property double libShownAt: 0
    // Loads every game (the shelf sorts and filters them); keeps the selection.
    function loadLibrary(resetFocus) {
        const t0 = Date.now()
        // Only the latest request's answer is shown (answers can cross).
        const seq = ++libSeq
        api("GET", "/api/v1/library?lang=" + uiLang + "&sort=name", null, function (list, err) {
            // A newer request's answer comes later; but while nothing is shown yet, an older one
            // is shown at once (a library being synced asks again and again).
            if (seq !== libSeq && ready) return
            // A refresh landing while the player moves would stall the shelf: it waits until they
            // pause (asked again a moment later).
            if (ready && !resetFocus && Date.now() - lastActivity < 900) { libReload.restart(); return }
            // Unavailable: said, and the (empty) library shown rather than a loading screen forever.
            if (!list) { if (err) toasts.show(qsTr("Library unavailable: %1").arg(err), "error"); ready = true; return }
            const r = list.map(toRow)
            const idx = {}
            r.forEach((x, i) => idx[x.rom_id] = i)
            indexByRom = idx
            const same = r.length === libModel.count && r.every((x, i) => libModel.get(i).rom_id === x.rom_id)
            if (same) {
                for (let i = 0; i < r.length; i++) {
                    const cur = libModel.get(i)
                    if (Object.keys(r[i]).some(k => cur[k] !== r[i][k])) libModel.set(i, r[i])
                }
            } else {
                libModel.clear()
                libModel.append(r)
            }
            // The first shown keeps the place; a later answer doesn't send the player back.
            if (resetFocus && !(libShownAt > t0)) focusRom = -1
            libShownAt = Date.now()
            rows = r
            loadMs = Date.now() - t0
            ready = true
            if (r.length) maybeAskConsoles()
            libRevision++
        })
    }
    Timer { id: libReload; interval: 300; onTriggered: { win.loadPlatforms(); win.loadLibrary(false) } }
    // Images arriving while a game's page is open: the page refreshed once they settle.
    Timer { id: pageMediaReload; interval: 2500; onTriggered: if (win.page && win.overlay === "game") win.reloadGame() }

    function onDownloadEvent(m) {
        const i = indexByRom[m.rom_id]
        if (i !== undefined && i < libModel.count) {
            const patch = { dl_state: m.state === "done" || m.state === "cancelled" ? "" : m.state, dl_received: m.received || 0,
                            dl_total: m.total || 0, dl_error: CoreText.tr(m.error || "") }
            for (const k in patch) libModel.setProperty(i, k, patch[k])
            const r = rows.slice()
            if (r[i]) { r[i] = Object.assign({}, r[i], patch); rows = r }
        }
        // Installed: the game moves from the Store to My library.
        if (m.state === "done") libReload.restart()
        const name = i !== undefined && i < libModel.count ? libModel.get(i).name : qsTr("The game")
        if (m.state === "done") toasts.show(qsTr("%1 is installed.").arg(name), "ok")
        if (m.state === "failed") toasts.show(qsTr("%1: %2").arg(name).arg(m.error ? CoreText.tr(m.error) : qsTr("download failed")), "error")
        if (downloadsPanel.shown) downloadsRefresh.restart()
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
            const d = (list || []).find(x => x.rom_id === g.rom_id && ["queued", "downloading", "verifying", "extracting", "failed", "paused"].indexOf(x.state) >= 0)
            if (d) api("DELETE", "/api/v1/downloads/" + d.id, null, function () { libReload.restart() })
        })
    }
    function deleteLocal(g) {
        menu.open(qsTr("Delete “%1” from this device?").arg(g.name), qsTr("The game stays available on RomM and can be downloaded again."),
                  [{ id: "yes", label: qsTr("Delete from this device") }, { id: "no", label: qsTr("Cancel") }], function (c) {
            if (c !== "yes") return
            api("DELETE", "/api/v1/games/" + g.rom_id + "/local", null, function (r, err) {
                if (err) { toasts.show(CoreText.tr(err), "error"); return }
                toasts.show(qsTr("%1 deleted from this device.").arg(g.name), "ok")
                // Back to the library, where the game was chosen.
                if (gameSettingsPage.visible) gameSettingsPage.close()
                if (overlay === "game") closeGame()
            })
        })
    }
    // ---------- Game page ----------
    function openGame(romId) {
        api("GET", "/api/v1/games/" + romId + "?lang=" + uiLang, null, function (d, err) {
            if (!d) { toasts.show(err, "error"); return }
            const first = page === null || overlay !== "game"
            page = d
            pageGame = toRow(d.game)
            if (first) { pageFacts = null; gamePage.reset(); videoRested = false; overlay = "game"; sfx.play("accept") }
            loadFacts(romId)
            loadTrailer(pageGame)
        })
    }
    // Trailer: the core fetches it once from RomM (with the token) and plays it from disk.
    property string pageTrailer: ""
    property string pageTrailerState: ""   // "", "loading", "ready", "error: …"
    // The game page's video: RomM's trailer, else ScreenScraper's capture of the game being played
    // (both prepared by the core as local files).
    function loadTrailer(g) {
        if (!g) { pageTrailer = ""; pageTrailerState = ""; return }
        if (pageTrailerState === "loading" && pageTrailerFor === g.rom_id) return
        pageTrailerFor = g.rom_id
        pageTrailer = ""
        pageTrailerState = "loading"
        const gameplay = function () {
            api("POST", "/api/v1/games/" + g.rom_id + "/gameplay", {}, function (r, err) {
                if (pageTrailerFor !== g.rom_id) return
                if (r && r.path) { pageTrailer = fileUrl(r.path, 0); pageTrailerState = "ready" }
                else pageTrailerState = "error: " + (err || "")
            })
        }
        if (!g.trailer) { gameplay(); return }
        api("POST", "/api/v1/games/" + g.rom_id + "/trailer", {}, function (r, err) {
            if (pageTrailerFor !== g.rom_id) return
            if (r && r.path) { pageTrailer = fileUrl(r.path, 0); pageTrailerState = "ready" }
            else gameplay()
        })
    }
    property int pageTrailerFor: -1
    // Video background: once the selection rests, the core fetches a video of the game being
    // played (ScreenScraper's gameplay capture, else RomM's trailer) and the library plays it.
    property string bgVideo: ""
    property int bgVideoFor: -1
    readonly property bool bgVideoWanted: win.bgVideos
                                          && win.screen === "library" && win.overlay === ""
    Timer {
        id: bgVideoDelay
        interval: 900
        onTriggered: {
            const g = win.focusedGame
            if (!g || !win.bgVideoWanted || g.rom_id === win.bgVideoFor) return
            win.bgVideoFor = g.rom_id
            win.bgVideo = ""
            api("POST", "/api/v1/games/" + g.rom_id + "/gameplay", {}, function (r, err) {
                if (win.bgVideoFor === g.rom_id && r && r.path) win.bgVideo = fileUrl(r.path, 0)
                if (!r && err) console.log("No video for " + g.name + ": " + err)
                // The neighbours' videos fetched meanwhile, so the next one starts at once.
                for (const n of win.neighbours()) api("POST", "/api/v1/games/" + n + "/gameplay", {}, function () {})
            })
        }
    }
    // The games beside the one selected (rom ids), whose videos are fetched ahead.
    function neighbours() {
        const out = []
        if (folder) {
            for (const d of ["right", "left"]) {
                const n = Shelf.move(layout.tiles, focusIndex, d)
                if (n !== focusIndex && rows[layout.tiles[n].idx]) out.push(rows[layout.tiles[n].idx].rom_id)
            }
        } else if (homeZone === "row") {
            for (const k of [rowIndex + 1, rowIndex - 1]) if (k >= 0 && k < recents.length) out.push(recents[k])
        }
        return out
    }
    onFocusedGameChanged: {
        videoRested = false
        if (focusedGame && focusedGame.rom_id === bgVideoFor) return
        bgVideo = ""; bgVideoFor = -1
        if (bgVideoWanted) bgVideoDelay.restart()
    }
    onBgVideoWantedChanged: if (bgVideoWanted && bgVideoFor === -1) bgVideoDelay.restart()
    // Attract: after a few seconds without input on the library (5 by default, prefs.attractDelay; 0: never), once the selected game's video plays, the
    // library fades out and leaves the video; any input brings it back (that input only wakes it),
    // and so does a minute of it (see videoRested).
    property double lastActivity: Date.now()
    property bool attract: false
    readonly property bool attractAllowed: prefs.attractDelay > 0 && screen === "library" && (overlay === "" || (overlay === "game" && !gameSettingsPage.visible)) && ready && !gameMode
                                           && !menu.visible && !search.visible && !downloadsPanel.shown
                                           && !nameEntry.visible && !sortMenu.visible
                                           && libModel.count > 0 && ambience.videoShown && !videoRested
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
        onTriggered: if (Date.now() - win.lastActivity >= prefs.attractDelay * 1000) win.attract = true
    }
    // After a minute alone on screen (prefs.attractRest; 0: never), the video goes on dimmed and the games
    // come back; it stays paused until another game is selected.
    property bool videoRested: false
    Timer {
        interval: Math.max(1, prefs.attractRest) * 1000
        running: win.attract && prefs.attractRest > 0
        onTriggered: { win.videoRested = true; win.attract = false }
    }
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
            else if (r && r.temporary) toasts.show(qsTr("%1 is downloaded to be played: a temporary copy, removed first when space is needed.").arg(g.name), "info")
            else if (r && r.downloading) toasts.show(qsTr("%1 is compressed on RomM: it is downloaded instead.").arg(g.name), "info")
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
    // Controls, at one of three levels ("all", "console:<slug>", "game:<rom id>"): a setting
    // changed, or a console button given to the pad button pressed next.
    function controlsUrl(scope) {
        if (scope.startsWith("console:")) return "/api/v1/consoles/" + encodeURIComponent(scope.substring(8)) + "/controls"
        if (scope.startsWith("game:")) return "/api/v1/games/" + scope.substring(5) + "/controls"
        return "/api/v1/controls"
    }
    function controlsShow(scope, r) {
        if (scope.startsWith("console:")) { if (settingsPage.consoleSlug === scope.substring(8)) settingsPage.consoleControls = r }
        else if (scope.startsWith("game:")) { if (pageGame && "game:" + pageGame.rom_id === scope) gameSettingsPage.controls = r }
        else settingsPage.controlsAll = r
    }
    function controlsChange(scope, body) {
        api("POST", controlsUrl(scope), body, function (r, err) {
            if (err) { toasts.show(CoreText.tr(err), "error"); return }
            controlsShow(scope, r)
            // The game's page says which controller it gets.
            if (scope.startsWith("game:") && (body.key === "device" || body.key === "*")) reloadGame()
        })
    }
    // "Press the button for…": the core sends the next pad button pressed (a "capture" event)
    // instead of moving in Borne; ten seconds, else nothing changes.
    property var capture: null
    function startCapture(scope, button, name) {
        capture = { scope: scope, button: button, name: name }
        api("POST", "/api/v1/controls/capture", { on: true }, function () {})
        captureTimer.restart()
    }
    function endCapture(pad) {
        const c = capture
        capture = null
        captureTimer.stop()
        if (!c) return
        if (pad) { sfx.play("accept"); controlsChange(c.scope, { button: c.button, pad: pad }) }
        else api("POST", "/api/v1/controls/capture", { on: false }, function () {})
    }
    Timer { id: captureTimer; interval: 10000; onTriggered: { win.endCapture(""); toasts.show(qsTr("No button pressed: nothing changed."), "info") } }

    // Playing: the core starts the emulator; Borne steps aside (game mode) until it quits. The
    // launch screen covers the passage both ways (LaunchScreen.qml).
    property var session: null
    property var launchGame: null
    property string launchPhase: ""
    property string launchNote: ""
    function play(g, anyway) {
        if (session && session.running) return
        sfx.play("accept")
        launchGame = g; launchNote = ""; launchPhase = "starting"
        api("POST", "/api/v1/games/" + g.rom_id + "/play", anyway ? { anyway: true } : {}, function (r, err) {
            if (err) { launchPhase = ""; toasts.show(err, "error"); return }
            // This console's games need what this computer lacks: said before its first game.
            if (r && r.needs) {
                launchPhase = ""
                needsAsk.game = g
                const forGame = r.needs.some(n => n.game)
                needsAsk.title = qsTr("Before playing %1").arg(forGame ? r.game : r.console)
                needsAsk.body = ConsoleNeeds.warnings(r.needs).join("\n\n")
                needsAsk.footer = forGame ? qsTr("Asked once for this game. If Borne is wrong, play anyway: it will not ask again.")
                                          : qsTr("Asked once for this console.")
                needsAsk.shown = true
                return
            }
            if (r && r.downloading) {
                launchPhase = ""
                toasts.show(qsTr("%1 is compressed on RomM: it is downloaded first and starts as soon as it is ready.").arg(r.downloading), "info")
                return
            }
            if (r && r.preparing) {
                launchPhase = ""
                toasts.show(qsTr("Preparing %1: its compressed package (.nsz) is unpacked once for the emulator. The game starts as soon as it is ready.").arg(r.preparing), "info")
                return
            }
            if (r && r.installing) {
                launchPhase = ""
                if (r.after) toasts.show(qsTr("%1 is installed after %2, which is being installed now. The game starts as soon as it is ready.").arg(r.installing).arg(r.after), "info")
                else toasts.show(qsTr("Installing %1… the game starts as soon as it is ready.").arg(r.installing), "info")
                return
            }
            onSession(r)
        })
    }
    // Escape during a game (macOS; Linux catches it in the core): Borne's question, not the
    // emulator's menu. Pressed again while asked, the game goes on.
    // (The launcher's `quitKey`, absent when the page runs elsewhere: connected once loaded.)
    function quitKeyPressed() {
        if (!win.session || !win.session.running) return
        if (win.session.paused) quitAsk.answered(false)
        else win.api("POST", "/api/v1/session/ask", {}, function () {})
    }
    function onSession(s) {
        // The end of another game than the one running is not this one's end.
        if (s && !s.running && session && session.running && s.rom_id !== undefined && s.rom_id !== session.rom_id) return
        session = s
        if (typeof quitKey !== "undefined" && quitKey) quitKey.active = !!(s && s.running)
        if (s && s.running) {
            // The launch screen shows the game that runs, whichever started it.
            if (!launchGame || launchGame.rom_id !== s.rom_id) {
                const i = indexByRom[s.rom_id]
                launchGame = pageGame && pageGame.rom_id === s.rom_id ? pageGame : i !== undefined && rows[i] ? rows[i] : { rom_id: s.rom_id, name: s.name }
            }
            gameMode = true
            launchPhase = "starting"; launchStarted.restart()
        } else {
            gameMode = false
            // The game moves to the other emulator, which must be installed or prepared first.
            if (s && s.waiting) {
                launchPhase = ""
                const w = s.waiting
                if (w.installing) toasts.show(qsTr("Installing %1… the game starts as soon as it is ready.").arg(w.installing), "info")
                else if (w.preparing) toasts.show(qsTr("Preparing %1: its compressed package (.nsz) is unpacked once for the emulator. The game starts as soon as it is ready.").arg(w.preparing), "info")
                return
            }
            // An emulator opened from the Developer settings: back to them.
            if (s && s.tool) {
                launchPhase = ""
                if (s.kept) toasts.show(qsTr("RetroArch: %n setting(s) of your own kept, added on top of Borne's before each game.", "", s.kept), "info")
                loadSettings()
                return
            }
            if (s && s.error) { launchPhase = ""; toasts.show(CoreText.tr(s.error), "error") }
            else {
                launchNote = s && s.saving ? qsTr("Sending the save to RomM…") : ""
                launchPhase = "ending"; launchEnded.restart()
            }
            reloadGame(); libReload.restart()
        }
    }
    function onSaves(note) {
        const text = !note ? "" : note === "save sent to RomM" ? qsTr("Save sent to RomM.") : qsTr("RomM unreachable: the save will be sent later.")
        if (launchPhase === "ending") launchNote = text
        else if (note && note !== "save sent to RomM") toasts.show(text, "info")
    }
    // The emulator's window covers the screen within a few seconds; then "playing".
    Timer { id: launchStarted; interval: 4000; onTriggered: if (win.launchPhase === "starting") win.launchPhase = "playing" }
    Timer { id: launchEnded; interval: 1400; onTriggered: if (win.launchPhase === "ending") win.launchPhase = "" }
    // A game's own settings (GameSettingsPage): emulator and its options, picture, cheats,
    // language, cover, storage. Each part is fetched from the core and refreshed after a change.
    function gameSettings(g) {
        gameSettingsPage.emulator = null; gameSettingsPage.emuOptions = null; gameSettingsPage.display = null
        gameSettingsPage.cheats = null; gameSettingsPage.images = null; gameSettingsPage.controls = null
        gameSettingsPage.open()
        loadGameSettings(g, ["emulator", "emuoptions", "display", "controls", "cheats", "screenscraper"])
    }
    function loadGameSettings(g, parts) {
        const target = { emulator: "emulator", emuoptions: "emuOptions", display: "display", controls: "controls", cheats: "cheats", screenscraper: "images" }
        for (const p of parts) {
            if (p === "cheats" && !(g.local_state === "local" || g.linked)) continue
            api("GET", "/api/v1/games/" + g.rom_id + "/" + p, null, function (r, err) {
                if (!pageGame || pageGame.rom_id !== g.rom_id) return
                if (err && p !== "screenscraper") { toasts.show(CoreText.tr(err), "error"); return }
                gameSettingsPage[target[p]] = r || {}
            })
        }
    }
    function gameSettingsAction(id, payload) {
        const g = pageGame
        if (id === "close") { sfx.play("back"); gameSettingsPage.close(); return }
        if (!g) return
        sfx.play("accept")
        const base = "/api/v1/games/" + g.rom_id + "/"
        const failed = function (err) { if (err) toasts.show(CoreText.tr(err), "error"); return !!err }
        if (id === "engine") api("POST", base + "emulator", { engine: payload === "" ? null : payload }, function (r, err) {
            if (!failed(err)) toasts.show(payload === "" ? qsTr("This game uses its console's emulator.") : qsTr("This game now uses %1.").arg(gameSettingsPage.emulator.choices.find(c => c.id === payload).name), "info")
            loadGameSettings(g, ["emulator", "emuoptions", "controls"])
        })
        else if (id === "opt") api("POST", base + "emuoptions", payload, function (r, err) { if (!failed(err)) gameSettingsPage.emuOptions = r })
        else if (id === "opt-reset") {
            const own = gameSettingsPage.emuOptions.options.filter(o => o.own)
            let left = own.length
            for (const o of own) api("POST", base + "emuoptions", { key: o.key, value: "default" }, function (r, err) {
                failed(err)
                if (--left === 0) loadGameSettings(g, ["emuoptions"])
            })
        }
        else if (id === "display") api("POST", base + "display", payload, function (r, err) { if (!failed(err)) gameSettingsPage.display = r })
        else if (id === "controls") controlsChange("game:" + g.rom_id, payload)
        else if (id === "controls-capture") startCapture("game:" + g.rom_id, payload.button, payload.name)
        else if (id === "cheat" || id === "cheats-off") {
            const list = gameSettingsPage.cheats.cheats
            const on = id === "cheats-off" ? [] : list.filter((x, i) => i === payload.index ? payload.on : x.on).map(x => x.name)
            api("POST", base + "cheats", { on: on }, function (r, err) { failed(err); loadGameSettings(g, ["cheats"]) })
        }
        else if (id.indexOf("pnach-") === 0) {
            const send = function (body) {
                api("POST", base + "cheats/file", body, function (r, err) {
                    if (!failed(err)) toasts.show(qsTr("%n cheat(s) found in the file.", "", r.cheats), "info")
                    loadGameSettings(g, ["cheats"])
                })
            }
            if (id === "pnach-pick") send({ pick: true })
            else if (id === "pnach-path") nameEntry.open(qsTr("Path of the .pnach file"), "", function (t) { send({ path: t }) }, "/home/…/game.pnach")
            else if (id === "pnach-url") nameEntry.open(qsTr("Link to the .pnach file"), "", function (t) { send({ url: t }) }, "https://…")
        }
        else if (id === "lang") pageAction("lang", payload)
        else if (id === "version") pageAction("version", payload)
        else if (id === "region") {
            correctImages(g, { region: payload })
            const im = Object.assign({}, gameSettingsPage.images); im.chosen = payload; gameSettingsPage.images = im
        }
        else if (id === "ss-search") nameEntry.open(qsTr("Search ScreenScraper"), g.name, function (name) { searchScreenScraper(g, name) }, qsTr("Game name"))
        else if (id === "sound") gamePage.sound = payload
        else if (id === "delete") deleteLocal(g)
        else if (id === "unlink") unlink(g)
    }
    // The settings follow the version shown (a language can open another one).
    onPageGameChanged: if (gameSettingsPage.visible) {
        if (pageGame) loadGameSettings(pageGame, ["emulator", "emuoptions", "display", "controls", "cheats", "screenscraper"])
        else gameSettingsPage.close()
    }
    function pageAction(id, payload) {
        const g = pageGame
        if (id === "back") { sfx.play("back"); closeGame(); return }
        if (!g) return
        if (id === "settings") gameSettings(g)
        else if (id === "watch") {
            if (ambience.videoShown) { videoRested = false; attract = true }
            else if (pageTrailerState.indexOf("error") === 0) toasts.show(qsTr("No video for this game: %1").arg(pageTrailerState.slice(7) || qsTr("none found")), "info")
            else toasts.show(qsTr("The video is still loading."), "info")
        }
        else if (id === "download") download(g)
        else if (id === "link") link(g)
        else if (id === "unlink") unlink(g)
        else if (id === "delete") deleteLocal(g)
        else if (id === "cancel") cancelDownload(g)
        else if (id === "play") play(g)
        else if (id === "fav") setFavourite(g, !g.favourite)
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
    // The newest update state seen: a settings answer computed before an "update" event can
    // arrive after it, and must not bring "Checking…" back (it then stayed forever).
    property var lastUpd: null
    function freshUpd(r) {
        if (r && r.update && r.update.update && lastUpd && (r.update.update.seq || 0) < (lastUpd.seq || 0))
            r.update = Object.assign({}, r.update, { update: lastUpd })
        return r
    }
    function loadSettings() { api("GET", "/api/v1/settings", null, function (r) { if (r) { settings = freshUpd(r); emuInstallSeen(r.emulators) } }) }
    // "Update now" / "Install" on an emulator: said when pressed, and its outcome said when done.
    property string emuAsked: ""
    function emuInstallSeen(e) {
        const t = e ? e.task : null
        if (emuAsked === "" || !t || t.id !== emuAsked || t.running) return
        const p = (e.programs || []).find(x => x.id === emuAsked)
        const name = p ? p.name : emuAsked
        emuAsked = ""
        const d = t.done
        if (t.error) toasts.show(qsTr("%1: %2").arg(name).arg(CoreText.tr(t.error)), "error")
        else if (d && d.what === "uptodate") toasts.show(qsTr("%1 is already up to date (version %2).").arg(name).arg(d.version), "ok")
        else if (d && d.what === "updated") toasts.show(d.version === "flatpak" ? qsTr("%1 updated with Flathub.").arg(name) : qsTr("%1 updated to version %2.").arg(name).arg(d.version), "ok")
        else if (d && d.what === "installed") toasts.show(qsTr("%1 installed.").arg(name), "ok")
    }
    function settingsMenu() {
        loadSettings()
        refreshStatus()
        api("GET", "/api/v1/controls", null, function (r) { if (r) settingsPage.controlsAll = r })
        api("GET", "/api/v1/steam", null, function (r) { if (r) settingsPage.steam = r })
        settingsPage.reset()
        overlay = "settings"
    }
    function loadEmuOptions(program) {
        settingsPage.consoleOpts = null
        if (!program) return
        api("GET", "/api/v1/emulators/" + program + "/options", null, function (r) { if (r) settingsPage.consoleOpts = r })
    }
    function settingsAction(id, payload) {
        const post = function (body) {
            api("POST", "/api/v1/settings", body, function (r, err) { if (err) toasts.show(err, "error"); else settings = freshUpd(r) })
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
        else if (id === "needs-forget") api("POST", "/api/v1/needs/forget", {}, function (r, err) {
            if (err) toasts.show(err, "error"); else toasts.show(qsTr("Borne asks again before those games."), "info")
        })
        else if (id === "pref") prefs[payload.key] = payload.value
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
            menu.open(qsTr("Remove this file?"), qsTr("The games that need it will not start until it is added again."),
                      [{ id: "yes", label: qsTr("Remove") }, { id: "no", label: qsTr("Cancel") }], function (c) {
                if (c === "yes") api("DELETE", "/api/v1/system-files/" + k[0] + "/" + k[1], null, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
            })
        }
        else if (id === "display") api("POST", "/api/v1/display", payload, function (r, err) {
            if (err) toasts.show(CoreText.tr(err), "error")
            if (payload.console) { if (r && settingsPage.consoleSlug === payload.console) settingsPage.consoleDisplay = r }
            else loadSettings()
        })
        // A console's page: its picture, and its emulator's options for all games.
        else if (id === "console-open") {
            api("GET", "/api/v1/display?console=" + encodeURIComponent(payload.slug), null, function (r) { if (r && settingsPage.consoleSlug === payload.slug) settingsPage.consoleDisplay = r })
            api("GET", "/api/v1/consoles/" + encodeURIComponent(payload.slug) + "/controls", null, function (r) { if (r && settingsPage.consoleSlug === payload.slug) settingsPage.consoleControls = r })
            loadEmuOptions(payload.program)
        }
        else if (id === "emu-option") api("POST", "/api/v1/emulators/" + payload.program + "/options", { key: payload.key, value: payload.value }, function (r, err) {
            if (err) toasts.show(CoreText.tr(err), "error"); else settingsPage.consoleOpts = r
        })
        else if (id === "emu-options-reset") {
            const own = settingsPage.consoleOpts ? settingsPage.consoleOpts.options.filter(o => o.own) : []
            for (const o of own) api("POST", "/api/v1/emulators/" + payload.program + "/options", { key: o.key, value: "default" }, function (r) { if (r) settingsPage.consoleOpts = r })
        }
        else if (id === "pick-consoles") pickConsoles()
        else if (id === "steam-add") api("POST", "/api/v1/steam", {}, function (r, err) {
            if (err) { toasts.show(CoreText.tr(err), "error"); return }
            settingsPage.steam = r
            toasts.show(r.chimera ? qsTr("Borne shows in Steam after the next Steam session start.") : qsTr("Borne shows in Steam the next time it starts."), "ok")
        })
        else if (id === "steam-remove") api("DELETE", "/api/v1/steam", null, function (r) { if (r) settingsPage.steam = r })
        else if (id === "controls") controlsChange(payload.scope, { key: payload.key, value: payload.value })
        else if (id === "controls-capture") startCapture(payload.scope, payload.button, payload.name)
        else if (id === "console-emu") api("POST", "/api/v1/consoles/" + payload.slug + "/emulator", { engine: payload.engine }, function (r, err) {
            if (err) toasts.show(CoreText.tr(err), "error")
            api("GET", "/api/v1/settings", null, function (r2) {
                if (!r2) return
                settings = freshUpd(r2)
                // The console's page shows the options of the emulator now chosen.
                const c = (r2.emulators.consoles || []).find(x => x.slug === payload.slug)
                const ch = c ? c.choices.find(x => x.id === c.chosen) : null
                if (settingsPage.consoleSlug === payload.slug) loadEmuOptions(ch ? ch.program : "")
            })
        })
        else if (id === "emu-dismiss") api("POST", "/api/v1/emulators/task/dismiss", {}, function () { loadSettings() })
        else if (id === "emu-auto") api("POST", "/api/v1/emulators/auto-update", { on: payload }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        else if (id.startsWith("emu-install:")) {
            const pid = id.substring(12)
            const p = settings && settings.emulators ? (settings.emulators.programs || []).find(x => x.id === pid) : null
            api("POST", "/api/v1/emulators/" + pid + "/install", {}, function (r, err) {
                if (err) { toasts.show(CoreText.tr(err), "error"); return }
                emuAsked = pid
                toasts.show(p && p.managed ? qsTr("Looking for a newer %1…").arg(p.name) : qsTr("Installing %1…").arg(p ? p.name : pid), "info")
                loadSettings()
            })
        }
        else if (id.startsWith("emu-forget:")) api("POST", "/api/v1/emulators/" + id.substring(11) + "/path", { path: "" }, function (r, err) { if (err) toasts.show(err, "error"); loadSettings() })
        // Developer mode (Settings → Help, then Developer).
        else if (id === "dev-mode") api("POST", "/api/v1/dev", { on: payload === "on" }, function (r, err) {
            if (err) toasts.show(err, "error"); else { settings = freshUpd(r); if (payload === "on") toasts.show(qsTr("Developer mode is on: see Settings → Developer."), "info") }
        })
        else if (id === "system-pic") {
            const body = payload.choice === "auto" ? { auto: true } : { n: Number(payload.choice) }
            api("POST", "/api/v1/systems/" + payload.slug + "/picture", body, function (r, err) {
                if (err) toasts.show(CoreText.tr(err), "error"); else { loadSettings(); loadPlatforms() }
            })
        }
        else if (id.startsWith("spic-own:")) {
            const slug = id.substring(9)
            const send = function (p) {
                api("POST", "/api/v1/systems/" + slug + "/picture", { path: p }, function (r, err) {
                    if (err) toasts.show(CoreText.tr(err), "error"); else { loadSettings(); loadPlatforms() }
                })
            }
            api("POST", "/api/v1/systems/pick-picture", {}, function (r, err) {
                if (!err && r && r.path) send(r.path)
                else nameEntry.open(qsTr("Full path of the picture"), "", send, "/home/…/console.png", false, 600)
            })
        }
        else if (id === "dev-tune") { overlay = ""; setTab("store"); homeZone = "wall"; designTuner.open() }
        else if (id.startsWith("dev-open:")) api("POST", "/api/v1/dev/open/" + id.substring(9), {}, function (r, err) { if (err) toasts.show(CoreText.tr(err), "error") })
        else if (id.startsWith("dev-args:")) {
            const prog = id.substring(9)
            const cur = settings && settings.dev ? (settings.dev.programs.find(p => p.id === prog) || {}).args || "" : ""
            nameEntry.open(qsTr("Extra arguments, given before the game"), cur, function (t) {
                api("POST", "/api/v1/dev/args/" + prog, { args: t }, function (r, err) { if (err) toasts.show(err, "error"); else settings = freshUpd(r) })
            }, "--option value", false, 400)
        }
        else if (id.startsWith("dev-undo:")) api("POST", "/api/v1/dev/undo/" + id.substring(9), {}, function (r, err) {
            if (err) toasts.show(err, "error"); else { settings = freshUpd(r.settings); toasts.show(qsTr("Settings put back as they were before it was opened (%n file(s)).", "", r.restored), "info") }
        })
        else if (id === "dev-own-add") devOwnProgram("")
        else if (id.startsWith("dev-own-exe:")) devOwnProgram(id.substring(12))
        else if (id.startsWith("dev-own-name:")) {
            const o = devOwn(id.substring(13))
            nameEntry.open(qsTr("Name of the emulator"), o ? o.name : "", function (t) { devOwnPut({ id: o.id, name: t }) }, qsTr("Name"))
        }
        else if (id.startsWith("dev-own-args:")) {
            const o = devOwn(id.substring(13))
            nameEntry.open(qsTr("Arguments ({rom}: the game's file)"), o ? o.args : "{rom}", function (t) { devOwnPut({ id: o.id, args: t }) }, "-f {rom}", false, 400)
        }
        else if (id.startsWith("dev-own-consoles:")) {
            const o = devOwn(id.substring(17))
            api("GET", "/api/v1/consoles", null, function (d) {
                if (!d) return
                devConsolePicker.ownId = o.id
                devConsolePicker.title = qsTr("Consoles %1 plays").arg(o.name)
                devConsolePicker.open(d, false, o.consoles)
            })
        }
        else if (id.startsWith("dev-own-remove:")) api("DELETE", "/api/v1/dev/own/" + id.substring(15), null, function (r, err) {
            if (err) toasts.show(err, "error"); else settings = freshUpd(r)
        })
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
        else if (id === "update-to-dev") api("POST", "/api/v1/settings", { update_channel: "dev" }, function (r, err) {
            if (err) { toasts.show(err, "error"); return }
            api("POST", "/api/v1/update/check", {}, function () { loadSettings() })
        })
        else if (id === "update-force") api("POST", "/api/v1/update/check", { force: true }, function () { loadSettings() })
        else if (id === "update-github") {
            const u = settingsPage.upd
            const a = u && settingsPage.updState && settingsPage.updState.available ? settingsPage.updState.available.assets[u.current.platform] : null
            const link = a && a.url ? a.url : (u ? u.release_page : "")
            // Only a web page is ever opened (never a file or another program's scheme).
            Qt.openUrlExternally(/^https:\/\//.test(link) ? link : "https://github.com/Lightmaster00/borne/releases")
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
        if (!lastUpd || (u.seq || 0) >= (lastUpd.seq || 0)) lastUpd = u
        else return
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
    // ScreenScraper corrections from the game settings: the box region, or the right game.
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
    // ---------- Library: tabs, filter, order ----------
    function setTab(t) {
        folder = null
        if (t === libTab) { homeZone = t === "store" ? "wall" : "row"; relayout(); return }
        sfx.play("move")
        focusRom = -1
        homeZone = t === "store" ? "wall" : "row"
        if (t === "store") wallIndex = 0
        else rowIndex = 0
        libTab = t
    }
    // The rail: the profile, Home, Store, Downloads, Settings, Quit.
    readonly property var railItems: [
        { id: "profile", label: activeProfile ? qsTr("%1 · change profile").arg(activeProfile.name) : qsTr("Profiles"), icon: "" },
        { id: "home", label: qsTr("Home"), icon: "home" },
        { id: "store", label: qsTr("Store"), icon: "store" },
        { id: "search", label: qsTr("Search"), icon: "search" },
        { id: "downloads", label: qsTr("Downloads"), icon: "download" },
        { id: "settings", label: qsTr("Settings"), icon: "settings" },
        { id: "quit", label: qsTr("Quit Borne"), icon: "power" }
    ]
    function railAction(id) {
        if (id === "home") setTab("home")
        else if (id === "store") setTab("store")
        else if (id === "downloads") { sfx.play("accept"); openDownloads() }
        else if (id === "search") openSearch("", false)
        else if (id === "settings") settingsMenu()
        else if (id === "profile") { sfx.play("back"); showProfiles() }
        else if (id === "quit") menu.open(qsTr("Quit Borne?"), "", [{ id: "yes", label: qsTr("Quit") }, { id: "no", label: qsTr("Cancel") }],
                                          function (c) { if (c === "yes") Qt.quit() })
    }
    // Your order: the Store's console selected one place left (-1) or right (+1).
    function moveConsole(d) {
        const c = wall[wallIndex]
        if (!c) return
        const list = storeConsoles.map(x => x.slug)
        const p = list.indexOf(c.slug)
        // Its neighbour among the cards (consoles without games to discover are skipped).
        const other = wall[wallIndex + d]
        if (p < 0 || !other) return
        const q = list.indexOf(other.slug)
        list[p] = other.slug; list[q] = c.slug
        const rest = customOrder.filter(x => list.indexOf(x) < 0)
        prefs.consoleCustom = JSON.stringify(list.concat(rest))
        prefs.consoleOrder = "custom"
        wallIndex += d
        sfx.play("move")
    }
    // Y: in a folder, the order of its games; on the home and the Store, the consoles' order.
    function sortSections() {
        if (!folder) return [{ title: qsTr("Order of the consoles"), kind: "consoles",
                               items: Shelf.consoleOrders().map(o => ({ id: o.id, label: o.label, hint: o.hint, on: o.id === prefs.consoleOrder })) }]
        return [{ title: qsTr("Sort by"), kind: "sort", items: Shelf.sortsFor(libTab).map(x => ({ id: x.id, label: x.label, hint: x.hint, on: x.id === sortId })) }]
    }
    function openSort() {
        sortMenu.sections = sortSections()
        sortMenu.index = Math.max(0, sortMenu.flat.findIndex(x => sortMenu.sections[x.section].items.find(i => i.id === x.id).on))
        sortMenu.visible = true
        sfx.play("accept")
    }
    function applySort(pick) {
        const kind = sortMenu.sections[pick.section].kind
        if (kind === "consoles") prefs.consoleOrder = pick.id
        else {
            focusRom = -1
            if (libTab === "store") prefs.sortStore = pick.id
            else prefs.sortHome = pick.id
        }
        sortMenu.visible = false
        sfx.play("accept")
    }
    function handleSort(a) {
        const m = sortMenu
        if (a === "b" || a === "y") { sfx.play("back"); m.visible = false }
        else if (a === "up" && m.index > 0) { m.index--; sfx.play("move") }
        else if (a === "down" && m.index < m.flat.length - 1) { m.index++; sfx.play("move") }
        else if (a === "a" && m.picked) applySort(m.picked)
    }
    // A: a game opens its page; "See all", a collection or a console of the Store opens its folder.
    function primaryAction() {
        if (folder) { if (focusedGame) openGame(focusedGame.rom_id); return }
        if (homeZone === "rail") { const r = railItems[railIndex]; if (r) railAction(r.id); return }
        if (libTab === "store") { if (wall[wallIndex]) enterConsole(wall[wallIndex].slug); return }
        if (homeZone === "shelf") { openCollection(collections[shelfIndex]); return }
        if (rowGame) openGame(rowGame.rom_id)
        else if (rowIndex === recents.length) openFolder({ kind: "all", slug: "", name: qsTr("All my games") })
    }
    // The arrows outside a folder.
    function moveHome(a) {
        const step = (cur, d, n) => { const j = cur + d; if (j < 0 || j >= n) return cur; sfx.play("move"); return j }
        if (homeZone === "rail") {
            if (a === "up") railIndex = step(railIndex, -1, railItems.length)
            else if (a === "down") railIndex = step(railIndex, 1, railItems.length)
            else if (a === "right") { sfx.play("move"); homeZone = libTab === "store" ? "wall" : "row" }
            return
        }
        const toRail = () => { sfx.play("move"); railIndex = libTab === "store" ? 2 : 1; homeZone = "rail" }
        if (libTab === "store") {
            if (a === "left") { if (wallIndex === 0) toRail(); else wallIndex = step(wallIndex, -1, wall.length) }
            else if (a === "right") wallIndex = step(wallIndex, 1, wall.length)
            return
        }
        if (homeZone === "row") {
            if (a === "left") { if (rowIndex === 0) toRail(); else rowIndex = step(rowIndex, -1, recents.length + 1) }
            else if (a === "right") rowIndex = step(rowIndex, 1, recents.length + 1)
            else if (a === "down" && collections.length) { sfx.play("move"); homeZone = "shelf" }
        } else if (homeZone === "shelf") {
            if (a === "left") { if (shelfIndex === 0) toRail(); else shelfIndex = step(shelfIndex, -1, collections.length) }
            else if (a === "right") shelfIndex = step(shelfIndex, 1, collections.length)
            else if (a === "up") { sfx.play("move"); homeZone = "row" }
        }
    }
    function openDownloads() {
        downloadsPanel.open()
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
    // The profile chosen on the profiles screen whose library is opening ("" otherwise).
    property string enteringProfile: ""
    onReadyChanged: if (ready) enteringProfile = ""
    // Never held there long: a library slow to answer is shown as it comes.
    onEnteringProfileChanged: if (enteringProfile !== "") enterCap.restart()
    Timer { id: enterCap; interval: 6000; onTriggered: if (win.enteringProfile !== "") { win.ready = true; win.enteringProfile = "" } }
    function enterLibrary(profile) {
        api("POST", "/api/v1/profiles/" + profile.id + "/activate", {}, function (r, err) {
            if (err) { enteringProfile = ""; toasts.show(err, "error"); return }
            refreshStatus()
            loadSettings()
            // A library already loaded shows at once; it is refreshed for this profile behind.
            if (ready) enteringProfile = ""
            screen = "library"
            libTab = "home"; folder = null; homeZone = "row"; rowIndex = 0; shelfIndex = 0; focusRom = -1; wallIndex = 0
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
    function move(a) { if (folder) focusTile(Shelf.move(layout.tiles, focusIndex, a, layout.vertical)); else moveHome(a) }
    function jumpGroup(d) { focusTile(Shelf.jumpGroup(layout.tiles, focusIndex, d)) }
    function openSearch(initial, fromKeyboard) {
        if (!libModel.count) return
        sfx.play("accept")
        search.open(initial, fromKeyboard)
    }
    // A game found by the search: shown in a folder (every game of the library, or its console's
    // in the Store), selected.
    function showGame(romId) {
        const i = indexByRom[romId]
        if (i === undefined || !rows[i]) return
        const tab = Shelf.ready(rows[i]) ? "home" : "store"
        focusRom = romId
        if (libTab !== tab) libTab = tab
        homeZone = tab === "store" ? "wall" : "row"
        const slug = Shelf.tabOf(rows[i].platform_slug)
        if (tab === "store") {
            const c = wall.find(x => x.slug === slug)
            wallIndex = Math.max(0, wall.findIndex(x => x.slug === slug))
            folder = { kind: "store", slug: slug, name: c ? c.name : (shortNames[slug] || slug) }
        } else folder = { kind: "all", slug: "", name: qsTr("All my games") }
        relayout()
        const j = layout.tiles.findIndex(t => t.idx === i)
        if (j >= 0) focusIndex = j
    }

    onFocusIndexChanged: lastActivity = Date.now()

    function dispatch(a, source) {
        inputCounts[source] = (inputCounts[source] || 0) + 1
        if (source === "pad") win.inputSeen = "pad"
        inputCountsChanged()
        lastInput = a + " via " + source
        if (attract && overlay === "game" && a === "x") { prefs.videoMuted = !prefs.videoMuted; lastActivity = Date.now(); return }
        if (touch() && screen === "library" && (overlay === "" || overlay === "game")) return
        // While a game runs the core handles the quit chord (Select and Start, core/src/pad.rs);
        // the question it raises is answered here.
        // Waiting for a pad button: only the keyboard's Escape (B) gives up.
        if (capture) { if (a === "b" && source !== "pad") endCapture(""); return }
        if (needsAsk.shown) return needsAsk.handle(a)
        if (session && session.running) return session.paused ? quitAsk.handle(a) : undefined
        if (bench.running && a !== "start") return
        if (consolePicker.visible) { if (a !== "a" && a !== "start") sfx.play("move"); else sfx.play("accept"); return consolePicker.handle(a) }
        if (devConsolePicker.visible) { if (a !== "a" && a !== "start") sfx.play("move"); else sfx.play("accept"); return devConsolePicker.handle(a) }
        if (importing && screen === "library" && overlay === "") { if (a === "a") { importing = false; maybeAskConsoles() } return }
        if (menu.visible) { if (a === "a") sfx.play("accept"); else if (a === "b") sfx.play("back"); else sfx.play("move"); return menu.handle(a) }
        if (nameEntry.visible) return nameEntry.handle(a)
        if (search.visible) { if (a !== "a" && a !== "b") sfx.play("move"); return search.handle(a) }
        if (designTuner.visible) {
            const r = designTuner.handle(a)
            if (r === "back") sfx.play("back"); else if (r === "move") sfx.play("move")
            return
        }
        if (downloadsPanel.shown) {
            if (a === "r3") { sfx.play("back"); downloadsPanel.close(); return }
            const r = downloadsPanel.handle(a)
            if (r === "back") sfx.play("back"); else if (r === "move") sfx.play("move")
            return
        }
        if (sortMenu.visible) return handleSort(a)
        if (overlay === "diag") return diag.handle(a)
        if (overlay === "launch") { if (a === "b") { overlay = ""; gameMode = false } return }
        if (overlay === "settings") { if (a !== "a" && a !== "b") sfx.play("move"); return settingsPage.handle(a) }
        if (gameSettingsPage.visible) { if (a !== "a" && a !== "b") sfx.play("move"); return gameSettingsPage.handle(a) }
        if (overlay === "game") { if (a !== "a" && a !== "b") sfx.play("move"); return gamePage.handle(a) }
        if (screen === "server") return setup.handle(a)
        if (screen === "profiles") return picker.handle(a)
        if (screen === "pairing") return pairingScreen.handle(a)
        if (screen !== "library") return
        if (a === "a") primaryAction()
        else if (a === "y") openSort()
        else if (a === "select") openSearch("", false)
        else if (a === "start") settingsMenu()
        else if (a === "b" && folder) {
            // Back from a folder, on what opened it.
            const f = folder
            closeFolder()
            if (f.kind === "store") wallIndex = Math.max(0, wall.findIndex(c => c.slug === f.slug))
        }
        // Back: to the menu on the left (and from it, to the games).
        else if (a === "b" && homeZone === "rail") { sfx.play("move"); homeZone = libTab === "store" ? "wall" : "row" }
        else if (a === "b") { sfx.play("back"); railIndex = Math.max(0, railItems.findIndex(r => r.id === libTab)); homeZone = "rail" }
        else if (a === "lb") setTab("home")
        else if (a === "rb") setTab("store")
        else if (a === "r3") openDownloads()
        else if (a === "lt") { if (folder) jumpGroup(-1); else if (wallMode && homeZone === "wall") moveConsole(-1) }
        else if (a === "rt") { if (folder) jumpGroup(1); else if (wallMode && homeZone === "wall") moveConsole(1) }
        else if (a === "x" && !folder && libTab === "store" && homeZone === "wall" && wall.length) nextConsolePicture(wall[wallIndex])
        else move(a)
    }

    // The Store's console: its next picture among ScreenScraper's (X), kept as its choice.
    property bool picBusy: false
    function nextConsolePicture(c) {
        if (!c || picBusy) return
        const pics = settings && settings.system_pics ? settings.system_pics[c.slug] : null
        const list = pics ? pics.choices : []
        if (list.length < 2) { toasts.show(qsTr("ScreenScraper has no other picture of this console."), "info"); return }
        const firstPhoto = Math.max(0, list.findIndex(p => p.type === "photo"))
        const cur = /^[0-9]+$/.test(pics.chosen) ? Number(pics.chosen) : firstPhoto
        const n = (cur + 1) % list.length
        const kinds = { photo: qsTr("Photo"), illustration: qsTr("Illustration"), BoitierConsole3D: qsTr("Its box"), controller: qsTr("Controller") }
        const p = list[n]
        picBusy = true
        sfx.play("move")
        api("POST", "/api/v1/systems/" + c.slug + "/picture", { n: n }, function (r, err) {
            picBusy = false
            if (err) { toasts.show(CoreText.tr(err), "error"); return }
            toasts.show(qsTr("Picture %1 of %2: %3").arg(n + 1).arg(list.length).arg((kinds[p.type] || p.type) + (p.region ? " (" + String(p.region).toUpperCase() + ")" : "")), "info")
            loadSettings(); loadPlatforms()
        })
    }

    // ---------- Library helpers ----------
    readonly property string emptyLibraryText: {
        const st = win.status ? win.status.sync : null
        if (st && st.running) return qsTr("Syncing the library…")
        if (st && st.error && rows.length === 0) return qsTr("The library could not be synced: %1").arg(CoreText.tr(st.error))
        if (folder && folder.kind === "multi") return qsTr("No game for two players here yet.")
        if (libTab === "home") return qsTr("No game installed yet. Open the Store with %1 to download one.").arg(graphite.key("rb"))
        return qsTr("Every game of your server is installed here.")
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
            else if (m.type === "stick") { if (win.overlay === "game") { win.touch(); gamePage.stick(m.x, m.y) } }
            else if (m.type === "download") win.onDownloadEvent(m)
            else if (m.type === "library") libReload.restart()
            else if (m.type === "media") {
                if (m.group_key) { const r = Object.assign({}, win.artRevs); r[m.group_key] = (r[m.group_key] || 0) + 1; win.artRevs = r }
                libReload.restart(); if (win.page && win.overlay === "game") pageMediaReload.restart() }
            else if (m.type === "platforms") win.loadPlatforms()
            else if (m.type === "session") win.onSession(m.session)
            else if (m.type === "capture") win.endCapture(m.button)
            // A game that waited for its file or its emulator could not start: told, nothing else.
            else if (m.type === "play_failed") { if (!win.gameMode) toasts.show(CoreText.tr(m.error), "error") }
            // The save of the game just ended, sent after it (another game can start meanwhile).
            else if (m.type === "saves") win.onSaves(m.note)
            else if (m.type === "emulators" || m.type === "systemfiles") { if (win.overlay === "settings" || win.emuAsked !== "") loadSettings() }
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
            win.libTab = "home"; win.loadLibrary(true)
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
            if (s.action === "rb" || s.action === "lb") win.jumpGroup(s.action === "rb" ? 1 : -1)
            else if (s.action) win.move(s.action)
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
                    games: libModel.count, theme: "graphite", trailers: win.anyVideo,
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

    property bool consolesAsked: false
    // Once the library is in (and its first import over): the player chooses their consoles.
    function maybeAskConsoles() {
        if (consolesAsked || importing || screen !== "library" || overlay !== "" || gameMode) return
        consolesAsked = true
        api("GET", "/api/v1/consoles", null, function (d) {
            if (d && !d.chosen && d.consoles.length > 0) consolePicker.open(d, true)
        })
    }
    // Developer mode: the player's own emulators.
    function devOwn(oid) { return settings && settings.dev ? settings.dev.own.find(o => o.id === oid) || null : null }
    function devOwnPut(body, then) {
        api("POST", "/api/v1/dev/own", body, function (r, err) {
            if (err) { toasts.show(err, "error"); return }
            settings = freshUpd(r.settings); loadPlatforms()
            if (then) then(r.own)
        })
    }
    // Its program: the system's file chooser when there is one, else typed.
    function devOwnProgram(oid) {
        const o = oid ? devOwn(oid) : null
        const typed = function () {
            nameEntry.open(qsTr("Full path of the emulator's program"), o ? o.exe : "", function (p) { devOwnPut(o ? { id: o.id, exe: p } : { exe: p }) }, qsTr("Path"), false, 600)
        }
        api("POST", "/api/v1/dev/pick", {}, function (r, err) {
            if (err || !r || !r.path) { typed(); return }
            devOwnPut(o ? { id: o.id, exe: r.path } : { exe: r.path }, function (own) {
                if (!o) settingsAction("dev-own-consoles:" + own.id)
            })
        })
    }
    function pickConsoles() {
        api("GET", "/api/v1/consoles", null, function (d) { if (d) consolePicker.open(d, false) })
    }

    // ---------- Scene: 1920×1080, scaled to the window ----------
    Item {
        id: scene
        // 1080 logical pixels high; the width follows the screen's shape (16:10, 21:9…) so there
        // are no bars, never narrower than 1360.
        // Inside the border round the screen (ScreenBorder).
        // Interface size (prefs.uiScale, %) enlarges everything, never below 1360 wide.
        readonly property real k: Math.min(Math.min((win.height - 2 * win.frameMargin) / 1080, (win.width - 2 * win.frameMargin) / 1600) * prefs.uiScale / 100,
                                           (win.width - 2 * win.frameMargin) / 1360)
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
            game: win.overlay === "game" && win.pageGame ? win.pageGame : win.ambientGame
            artShown: prefs.background === "art"
            lightX: win.overlay === "game" ? width * 0.72 : home.lightX * stage.s
            glowSource: win.overlay === "game" ? "" : home.glowSource
            look: ({ glow: prefs.lookGlow, soft: prefs.lookSoft, vignette: prefs.lookVignette, grain: prefs.lookGrain })
            // The library's video (off by default), and on a game's page its trailer.
            trailers: win.overlay === "game" ? win.trailers : win.bgVideos && win.screen === "library" && win.overlay === ""
            videoUrl: win.overlay === "game" ? win.pageTrailer : win.bgVideo
            // A game's video in full screen plays with its sound.
            sound: win.overlay === "game" && win.attract && !prefs.videoMuted
            paused: menu.visible || downloadsPanel.shown || bench.running || nameEntry.visible || gameSettingsPage.visible
                    || !!(win.session && win.session.running)
            rest: win.videoRested
            scrims: win.overlay === ""
            attract: win.attract
            dim: win.overlay === "settings" || win.overlay === "diag" ? 0.55 : gameSettingsPage.visible ? 0.45 : 0
        }

    Item {
        id: keys
        anchors.fill: parent
        focus: true
        // On a game's page, W A S D turn its case while held.
        readonly property var tiltKeys: ({ [Qt.Key_W]: "w", [Qt.Key_A]: "a", [Qt.Key_S]: "s", [Qt.Key_D]: "d" })
        Keys.onReleased: (e) => {
            const k = tiltKeys[e.key]
            if (k && !e.isAutoRepeat && win.overlay === "game") { e.accepted = true; gamePage.tiltKey(k, false) }
        }
        Keys.onPressed: (e) => {
            win.inputSeen = "keyboard"   // hints now show keyboard keys
            if (win.overlay === "game" && !menu.visible && !nameEntry.visible && tiltKeys[e.key] && !(e.modifiers & Qt.ControlModifier)) {
                e.accepted = true
                if (!e.isAutoRepeat) { win.touch(); gamePage.tiltKey(tiltKeys[e.key], true) }
                return
            }
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
                else if (e.text && e.text.length === 1 && e.text.charCodeAt(0) >= 32) search.typeText(e.text)
                else if (search.showKeyboard) e.accepted = false
                if (e.accepted) return
            }
            // In the library, Ctrl+F or / open the search (typing elsewhere does nothing).
            if (screen === "library" && overlay === "" && !menu.visible && !nameEntry.visible && !downloadsPanel.shown) {
                const f = e.key === Qt.Key_Slash || (e.key === Qt.Key_F && (e.modifiers & Qt.ControlModifier))
                if (f) { e.accepted = true; openSearch("", true); return }
            }
            const map = {}
            map[Qt.Key_Up] = "up"; map[Qt.Key_Down] = "down"; map[Qt.Key_Left] = "left"; map[Qt.Key_Right] = "right"
            map[Qt.Key_Return] = "a"; map[Qt.Key_Enter] = "a"; map[Qt.Key_Space] = "a"
            map[Qt.Key_Escape] = "b"; map[Qt.Key_Backspace] = "b"
            map[Qt.Key_X] = "x"; map[Qt.Key_T] = "y"; map[Qt.Key_Y] = "y"; map[Qt.Key_F1] = "start"; map[Qt.Key_M] = "start"; map[Qt.Key_F2] = "select"
            map[Qt.Key_PageUp] = "lb"; map[Qt.Key_Q] = "lb"; map[Qt.Key_PageDown] = "rb"; map[Qt.Key_E] = "rb"
            map[Qt.Key_R] = "lt"; map[Qt.Key_C] = "rt"; map[Qt.Key_Tab] = "r3"; map[Qt.Key_I] = "l3"; map[Qt.Key_Home] = "lt"; map[Qt.Key_End] = "rt"
            const a = map[e.key]
            if (a) { e.accepted = true; dispatch(a, "keyboard") }
        }
    }

    // ---------- The home, its folders and the game's page: drawn for a screen 1080 high ----------
    Item {
        id: stage
        readonly property real s: scene.height / 1080
        width: scene.width / s
        height: 1080
        scale: s
        transformOrigin: Item.TopLeft
        z: 20

        // ---------- Library ----------
        LibraryHome {
            id: home
            anchors.fill: parent
            look: ({ card: prefs.lookCard, key: prefs.lookKey, floor: prefs.lookFloor, shadow: prefs.lookShadow })
            motionLook: ({ speed: prefs.moveSpeed, bounce: prefs.moveBounce, delay: prefs.moveDelay })
            // Faded under the Downloads and the Settings, which stand where a folder does.
            opacity: win.attract ? 0 : (downloadsPanel.shown || (glassPanel.shown && glassPanel.besideRail)) ? 0.25 : 1
            Behavior on opacity { NumberAnimation { duration: (win.attract ? 1200 : 350) * graphite.motion; easing.type: Easing.InOutQuad } }
            visible: win.screen === "library" && win.ready && !win.gameMode && win.overlay !== "game" && win.overlay !== "settings"
            theme: win.theme
            rows: win.rows
            indexByRom: win.indexByRom
            tab: win.libTab
            zone: win.homeZone
            recents: win.recents
            rowIndex: win.rowIndex
            collections: win.collections
            shelfIndex: win.shelfIndex
            homeCount: win.rows.filter(g => Shelf.ready(g)).length
            wall: win.wall
            wallIndex: win.wallIndex
            storeLine: {
                const order = (Shelf.consoleOrders().find(x => x.id === prefs.consoleOrder) || { label: "" }).label
                return qsTr("%n game(s) of your server to discover", "", win.wall.reduce((a, c) => a + c.count, 0)) + " · " + qsTr("Consoles: %1").arg(order.toLowerCase())
            }
            folder: win.folder
            layout: win.layout
            current: win.focusIndex
            folderLine: win.libTab === "store" ? qsTr("%n game(s) to discover", "", win.layout.count) : qsTr("%n game(s)", "", win.layout.count)
            folderFoot: qsTr("Sort: %1").arg(((Shelf.sortsFor(win.libTab).find(x => x.id === win.sortId) || { label: "" }).label).toLowerCase())
            emptyText: win.emptyLibraryText
            keyLabel: function (a) { return graphite.key(a) }
            shortName: function (slug) { return win.shortNames[Shelf.tabOf(slug)] || slug }
            agoText: function (secs) { return gamePage.agoText(secs) }
            onFolderHeightChanged: win.relayout()
            onFolderWidthChanged: win.relayout()
        }

        // The rail and the status, round the home, a folder and a game's page.
        HomeChrome {
            id: chrome
            anchors.fill: parent
            z: 21
            // A console's folder open: the rail and the status step back with the rest.
            opacity: win.attract ? 0 : (win.folder && win.overlay === "" && !downloadsPanel.shown) ? 0.28 : 1
            Behavior on opacity { NumberAnimation { duration: (win.attract ? 1200 : 400) * graphite.motion; easing.type: Easing.InOutQuad } }
            visible: win.screen === "library" && win.ready && !win.gameMode
            theme: win.theme
            items: win.railItems
            index: win.railIndex
            focused: win.homeZone === "rail" && !win.folder && win.overlay === "" && !downloadsPanel.shown
            here: win.overlay === "settings" ? "settings" : downloadsPanel.shown ? "downloads" : win.libTab
            profileName: win.activeProfile ? win.activeProfile.name : ""
            profileColor: win.activeProfile && win.activeProfile.name ? Qt.hsla(((win.activeProfile.name.charCodeAt(0) * 37) % 360) / 360, 0.35, 0.36, 1) : "#5A5C66"
            downloading: win.rows.some(g => ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0)
            downloadsText: {
                const s = win.status ? win.status.sync : null
                if (s && s.running) return qsTr("Syncing %1/%2").arg(s.done).arg(s.total)
                const busy = win.rows.filter(g => ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0)
                return busy.length ? qsTr("%n download(s)", "", busy.length) : ""
            }
            downloadsProgress: {
                const busy = win.rows.filter(g => g.dl_state === "downloading" && g.dl_total > 0)
                if (!busy.length) return -1
                return busy.reduce((a, g) => a + g.dl_received, 0) / busy.reduce((a, g) => a + g.dl_total, 0)
            }
            online: !!(win.status && win.status.online)
            serverText: win.status && win.status.online ? "RomM" : qsTr("Offline")
            clockText: prefs.showClock ? win.playTimeText() : ""
        }

        // Where you are and the buttons, at the foot.
        Footer {
            id: footer
            z: 22
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            opacity: win.attract ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: (win.attract ? 1200 : 350) * graphite.motion; easing.type: Easing.InOutQuad } }
            visible: win.screen === "library" && win.ready && !win.gameMode && !designTuner.visible
                     && (win.overlay === "" || win.overlay === "game" || win.overlay === "settings")
            theme: win.theme
            where: {
                if (win.overlay === "settings") return qsTr("Settings") + "  ›  " + settingsPage.where
                if (downloadsPanel.shown) return qsTr("Downloads")
                if (gameSettingsPage.visible) return (win.pageGame ? win.pageGame.name + "  ›  " : "") + qsTr("Game settings")
                const tab = win.libTab === "store" ? qsTr("Store") : qsTr("Home")
                const trail = [tab]
                if (win.folder) trail.push(win.folder.name)
                if (win.overlay === "game" && win.pageGame) trail.push(win.pageGame.name)
                return trail.join("  ›  ")
            }
            hints: {
                if (win.overlay === "settings") return settingsPage.hints
                if (downloadsPanel.shown) return downloadsPanel.hints
                if (gameSettingsPage.visible) return gameSettingsPage.hints
                if (win.overlay === "game") return gamePage.hints
                if (sortMenu.visible) return [["▲ ▼", qsTr("Choose"), "down"], ["A", qsTr("Apply"), "a"], ["B", qsTr("Close"), "b"]]
                if (win.folder) {
                    const h = []
                    if (win.focusedGame) h.push(["A", qsTr("Open"), "a"])
                    h.push(["Y", qsTr("Sort"), "y"])
                    if (win.layout.groups.length > 1) h.push(["LT RT", qsTr("Groups"), "rt"])
                    h.push(["B", qsTr("Back"), "b"])
                    return h
                }
                if (win.homeZone === "rail") return [["A", qsTr("Choose"), "a"], ["▶", qsTr("Games"), "right"], ["LB RB", qsTr("Home / Store"), "lb"]]
                if (win.libTab === "store") {
                    if (!win.wall.length) return [["LB RB", qsTr("Home / Store"), "lb"]]
                    const h = [["A", qsTr("See its games"), "a"], ["X", qsTr("Picture"), "x"], ["Y", qsTr("Order"), "y"]]
                    if (win.wall.length > 1) h.push(["LT RT", qsTr("Move"), "lt"])
                    h.push(["LB RB", qsTr("Home / Store"), "lb"])
                    return h
                }
                if (win.homeZone === "shelf") return [["A", qsTr("Open"), "a"], ["▲", qsTr("Recently played"), "up"], ["Y", qsTr("Order"), "y"], ["B", qsTr("Menu"), "b"]]
                return [["A", qsTr("Open"), "a"], ["▼", qsTr("Collections"), "down"], ["LB RB", qsTr("Home / Store"), "lb"], ["B", qsTr("Menu"), "b"]]
            }
        }

        SortMenu {
            id: sortMenu
            visible: false
            z: 40
            anchors { right: parent.right; rightMargin: 120; top: parent.top; topMargin: 186 }
            theme: win.theme
        }

        GamePage {
            id: gamePage
            anchors.fill: parent
            z: 20
            // Hidden under the game's settings (their glass would show it through).
            visible: win.overlay === "game" && win.pageGame !== null && !gameSettingsPage.visible
            // Its video in full screen: the page steps aside.
            opacity: win.attract ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: (win.attract ? 1200 : 350) * graphite.motion; easing.type: Easing.InOutQuad } }
            videoShown: ambience.videoShown
            theme: win.theme
            game: win.pageGame
            versions: win.page ? win.page.versions : []
            needs: win.page && win.page.warnings ? win.page.warnings : []
            fileNote: win.page && win.page.file_notes && win.pageGame ? (win.page.file_notes[String(win.pageGame.rom_id)] || null) : null
            emuLanguage: win.page ? win.page.emu_language : "auto"
            gameLanguages: win.page && win.page.languages ? win.page.languages : []
            uiLang: win.uiLang
            emulator: win.page && win.page.emulator ? win.page.emulator : ""
            device: win.page && win.page.device ? win.page.device : ""
            deviceWanted: win.page && win.page.device_wanted ? win.page.device_wanted : ""
            installMode: win.page ? win.page.install_mode : "download"
            streamAvailable: win.page ? win.page.stream.available : false
            streamError: win.page && win.page.stream.error ? CoreText.tr(win.page.stream.error) : ""
            trailers: win.trailers
            trailerUrl: win.pageTrailer
            trailerState: win.pageTrailerState
            // Nothing plays while a game runs (its sound would play under the game's).
            paused: menu.visible || downloadsPanel.shown || !visible || win.gameMode || !!(win.session && win.session.running)
            facts: win.pageFacts
            shotBase: win.pageGame ? win.apiBase + "/api/v1/games/" + win.pageGame.rom_id + "/screenshots/" : ""
            readonly property var pageConsole: win.pageGame ? win.consoles.find(c => c.slug === Shelf.tabOf(win.pageGame.platform_slug)) || null : null
            consoleLogo: pageConsole ? pageConsole.logo || "" : ""
            consoleName: pageConsole ? pageConsole.name : win.pageGame ? win.pageGame.platform_short : ""
            crumb: win.folder ? win.folder.name : win.libTab === "store" ? qsTr("Store") : qsTr("Recently played")
            onAction: (id, payload) => win.pageAction(id, payload)
        }

        // A game's video in full screen: its sound, X to turn it off or on.
        Rectangle {
            z: 30
            visible: opacity > 0
            opacity: win.attract && win.overlay === "game" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 600 } }
            anchors { right: parent.right; bottom: parent.bottom; rightMargin: 96; bottomMargin: 72 }
            width: muteRow.implicitWidth + 36; height: 56; radius: 28
            color: Qt.rgba(0.04, 0.04, 0.055, 0.6)
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.16) }
            Row {
                id: muteRow
                anchors.centerIn: parent
                spacing: 12
                KeyCap { anchors.verticalCenter: parent.verticalCenter; theme: win.theme; size: 32; text: graphite.key("x") }
                Icon { anchors.verticalCenter: parent.verticalCenter; name: prefs.videoMuted ? "mute" : "sound"; size: 24; stroke: 2; color: graphite.fg }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: prefs.videoMuted ? qsTr("Sound off") : qsTr("Sound on")
                    color: graphite.fg
                    font { family: graphite.fontFamily; pixelSize: 18; weight: Font.Bold }
                }
            }
        }

        DownloadsPanel {
            id: downloadsPanel
            theme: win.theme
            motion: graphite.motion
            // At a folder's place, beside the rail.
            x: home.panelX; y: 110; width: home.panelW; height: home.panelH
            z: 20.5
            gameOf: function (romId) { return win.rows.find(r => r.rom_id === romId) || null }
            onAct: (d, what) => {
                sfx.play("accept")
                const done = function (r, err) { if (err) toasts.show(CoreText.tr(err), "error"); win.refreshDownloads() }
                if (what === "cancel") win.api("DELETE", "/api/v1/downloads/" + d.id, null, done)
                else if (what === "retry") win.api("POST", "/api/v1/games/" + d.rom_id + "/download", {}, done)
                else win.api("POST", "/api/v1/downloads/" + d.id + "/" + what, {}, done)
            }
            onClear: {
                sfx.play("accept")
                win.api("DELETE", "/api/v1/downloads", null, function (r, err) { if (r) downloadsPanel.downloads = r.downloads; else win.refreshDownloads() })
            }
        }

        // Developer mode: the light and the cards tuned live over the screen they change.
        DesignTuner {
            id: designTuner
            anchors.fill: parent
            z: 45
            theme: win.theme
            prefs: prefs
            onTab: (t) => win.setTab(t)
            onStep: (d) => { if (win.libTab === "store" && win.wall.length) win.wallIndex = Math.max(0, Math.min(win.wall.length - 1, win.wallIndex + d)) }
        }
        // The settings stand in a glass panel over the game's art.
        Rectangle {
            anchors.fill: parent
            z: 20.49
            color: Qt.rgba(0.024, 0.024, 0.04, 0.6)
            opacity: glassPanel.shown && glassPanel.besideRail ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 380 * graphite.motion } }
        }
        Rectangle {
            id: glassPanel
            readonly property bool shown: win.overlay === "settings" || gameSettingsPage.visible
            // Beside the rail, at a folder's place (in the library); else the whole room.
            readonly property bool besideRail: chrome.visible
            x: besideRail ? home.panelX : 120; y: besideRail ? 110 : 96
            width: besideRail ? home.panelW : stage.width - x - 110
            height: besideRail ? home.panelH : stage.height - y - 96
            z: 23
            radius: 28
            color: Qt.rgba(0.07, 0.075, 0.095, 0.9)
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.13) }
            opacity: shown ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 380 * graphite.motion } }
        }
        GameSettingsPage {
            id: gameSettingsPage
            x: glassPanel.x; y: glassPanel.y; width: glassPanel.width; height: glassPanel.height
            clip: true
            z: 24
            theme: win.theme
            advanced: prefs.controlsAdvanced
            game: win.pageGame
            languages: gamePage.gameLanguages
            versions: gamePage.playable
            versionLabel: function (v) { return gamePage.versionLabel(v) }
            versionDetail: function (v) { return gamePage.versionDetail(v) }
            currentLang: gamePage.currentLang
            languageName: function (c) { return gamePage.languageName(c) }
            regionName: function (c) { return win.regionName(c) }
            onAction: (id, payload) => win.gameSettingsAction(id, payload)
        }
        SettingsPage {
            id: settingsPage
            x: glassPanel.x; y: glassPanel.y; width: glassPanel.width; height: glassPanel.height
            clip: true
            z: 25
            visible: win.overlay === "settings"
            theme: win.theme
            settings: win.settings
            status: win.status
            version: win.coreVersion
            reportPaths: win.reportPaths
            prefs: prefs
            onAction: (id, payload) => win.settingsAction(id, payload)
        }

    }

    // ---------- Screens outside the library ----------
    ServerSetup {
        id: setup
        anchors.fill: parent
        visible: win.screen === "server" && win.overlay !== "settings"
        theme: win.theme
        function connect(url) {
            busy = true
            win.api("POST", "/api/v1/server", { url: url }, function (r, err) {
                setup.busy = false
                if (err) { setup.error = err; return }
                toasts.show(qsTr("Connected to RomM (%1).").arg(r.url), "ok")
                win.showProfiles()
            })
        }
        onSubmit: (url) => {
            const current = win.status && win.status.server_url ? win.status.server_url : ""
            const paired = win.status && win.status.profiles ? win.status.profiles.some(p => p.paired) : false
            // Another server: every profile has to be paired again. Asked first.
            if (current && paired && url.replace(/\/+$/, "").toLowerCase() !== current.toLowerCase())
                menu.open(qsTr("Change the RomM server?"), qsTr("Every profile will have to be paired again with the new server."),
                          [{ id: "yes", label: qsTr("Change the server") }, { id: "no", label: qsTr("Cancel") }],
                          function (c) { if (c === "yes") setup.connect(url) })
            else connect(url)
        }
        onCancelled: if (win.status && win.status.server_url) win.showProfiles()
        // First start: RomM looked for on the local network, so its address is already there.
        onVisibleChanged: {
            if (!visible || (win.status && win.status.server_url) || searching) return
            searching = true
            win.api("GET", "/api/v1/server/discover", null, function (r) {
                setup.searching = false
                if (r) setup.offer(r.servers)
            })
        }
    }
    ProfilePicker {
        id: picker
        anchors.fill: parent
        // Stays while the chosen profile's library opens (its avatar ringed by a loading ring),
        // then fades onto it.
        readonly property bool shown: (win.screen === "profiles" || (win.screen === "library" && !win.ready && win.enteringProfile !== ""))
                                      && win.overlay !== "settings"
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 380 * graphite.motion; easing.type: Easing.InOutQuad } }
        loading: win.enteringProfile
        theme: win.theme
        serverUrl: win.status && win.status.server_url ? win.status.server_url : ""
        online: win.status ? win.status.online : false
        onChoose: (p) => { if (p.paired) { win.enteringProfile = p.id; win.enterLibrary(p) } else win.startPairing(p) }
        onAdd: win.addProfile()
        onOptions: (p) => win.profileOptions(p)
        onSettings: win.settingsMenu()
    }
    PairingScreen {
        id: pairingScreen
        anchors.fill: parent
        visible: win.screen === "pairing" && win.overlay !== "settings"
        theme: win.theme
        serverUrl: win.status && win.status.server_url ? win.status.server_url : ""
        pairing: win.pairing
        profileName: win.pairingProfile ? win.pairingProfile.name : ""
        qrUrl: win.apiBase + "/api/v1/pairing/qr.svg"
        qrRevision: win.qrRevision
        onRetry: win.startPairing(win.pairingProfile)
        onBack: { win.api("DELETE", "/api/v1/pairing", null, null); win.showProfiles() }
    }
    BootScreen {
        anchors.fill: parent
        z: 59
        theme: win.theme
        motion: graphite.motion
        shown: win.screen === "boot" || (win.screen === "library" && !win.ready && win.enteringProfile === "")
        toTop: win.screen === "profiles"
        failed: !!win.fatal || !win.apiBase
        message: win.fatal || (win.apiBase ? (win.screen === "library" ? qsTr("Opening your library…") : qsTr("Starting…"))
                                           : qsTr("Start through borne (BORNE_API / BORNE_WS variables missing)."))
    }

    // The first import (see importing).
    Rectangle {
        visible: win.importing && win.screen === "library" && win.overlay === ""
        anchors.fill: parent
        color: theme.bg
        z: 60
        readonly property var s: win.status && win.status.sync ? win.status.sync : null
        readonly property bool games: !!(s && s.running)
        readonly property real progress: !s ? 0
            : games ? (s.total > 0 ? s.done / s.total : 0)
            : (win.importCovers > 0 ? 1 - (s.covers_pending || 0) / win.importCovers : 1)
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width * 0.6, 760)
            spacing: 22
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("Preparing your library")
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 44; weight: Font.Bold }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: !parent.parent.s ? "" : parent.parent.games
                      ? qsTr("Games from RomM: %1 of %2").arg(parent.parent.s.done).arg(parent.parent.s.total)
                      : qsTr("Covers: %1 left").arg(parent.parent.s.covers_pending || 0)
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 22 }
            }
            Rectangle {
                width: parent.width; height: 8; radius: 4
                color: Qt.rgba(1, 1, 1, 0.1)
                Rectangle {
                    height: parent.height; radius: 4; color: theme.accent
                    width: parent.width * Math.max(0.02, Math.min(1, parent.parent.parent.progress))
                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: qsTr("A: see it now")
                color: theme.fgFaint
                font { family: theme.fontFamily; pixelSize: 17 }
            }
        }
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
            Text { text: frames.fps + " fps"; color: frames.fps < 55 ? "#f87171" : "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 18; bold: true } }
            Text { text: "p95 " + frames.p95 + " ms · p99 " + frames.p99 + " ms"; color: "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 15 } }
            Text { text: "stutters >25 ms: " + frames.jank + " / 10 s"; color: frames.jank > 0 ? "#f87171" : "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 15 } }
            Text { text: "video: " + win.videoFrames + " frames"; color: "#e8edf5"; font { family: "DejaVu Sans Mono"; pixelSize: 15 } }
            Text { text: win.lastInput; color: "#8b97ab"; font { family: "DejaVu Sans Mono"; pixelSize: 15 } }
        }
    }

    LaunchScreen {
        anchors.fill: parent
        z: 30
        theme: win.theme
        game: win.launchGame
        phase: win.launchPhase
        emulator: win.session && win.session.emulator ? win.session.emulator : ""
        note: win.launchNote
    }

    // The consoles shown (asked once after the first sync; then Settings → Consoles).
    ConsolePicker {
        id: consolePicker
        anchors.fill: parent
        z: 65
        theme: win.theme
        onDone: (slugs) => {
            win.api("POST", "/api/v1/consoles/chosen", { shown: slugs }, function () {
                win.loadPlatforms(); libReload.restart()
                if (win.overlay === "settings") win.loadSettings()
            })
        }
    }
    // The consoles an emulator of one's own plays (developer mode).
    ConsolePicker {
        id: devConsolePicker
        property string ownId: ""
        anchors.fill: parent
        z: 65
        theme: win.theme
        intro: qsTr("The consoles of your library this emulator plays: it is offered beside Borne's for them, and for each of their games. A to choose, Start to confirm.")
        onDone: (slugs) => win.devOwnPut({ id: ownId, consoles: slugs })
    }
    // Waiting for the pad button that is to do one of the console's buttons.
    Rectangle {
        anchors.fill: parent
        z: 70
        visible: !!win.capture
        color: Qt.rgba(0.02, 0.024, 0.04, 0.82)
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - 160, 900)
            spacing: 22
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: win.capture ? qsTr("Press the button that should do “%1”").arg(win.capture.name) : ""
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 44; weight: Font.Bold }
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: qsTr("On your controller. The button it replaces takes the old place. Nothing pressed in ten seconds: nothing changes.")
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 22 }
            }
        }
    }
    // Before the first game of a console whose games need what this computer lacks.
    QuitConfirm {
        id: needsAsk
        property var game: null
        anchors.fill: parent
        z: 33
        theme: win.theme
        stayText: qsTr("Not now")
        goText: qsTr("Play anyway")
        onAnswered: function (go) {
            shown = false
            sfx.play(go ? "accept" : "back")
            if (go && game) win.play(game, true)
        }
    }
    // Quitting a game: asked when the core paused it on the quit chord or on Escape.
    QuitConfirm {
        id: quitAsk
        anchors.fill: parent
        z: 32
        theme: win.theme
        game: win.session && win.session.name ? win.session.name : ""
        shown: !!(win.session && win.session.running && win.session.paused)
        // Back to the emulator (Escape again, or B): Borne steps behind it (macOS: the core brings it forward).
        onShownChanged: {
            if (shown) { win.raise(); win.requestActivate() }
            else if (win.session && win.session.running && Qt.platform.os !== "osx") win.lower()
        }
        onAnswered: function (quit) {
            sfx.play(quit ? "accept" : "back")
            if (quit) win.api("POST", "/api/v1/session/stop", {}, function () {})
            else win.api("POST", "/api/v1/session/resume", {}, function () {
                // Back to the emulator: Borne steps behind it (macOS: the core brings it forward).
                if (Qt.platform.os !== "osx") win.lower()
            })
        }
    }

    // Simulated game (game mode): used by the diagnostics VRAM test.
    Rectangle {
        visible: win.overlay === "launch"
        anchors.fill: parent
        color: "black"
        z: 31
        Text {
            anchors.centerIn: parent
            text: graphite.input === "keyboard" ? qsTr("Game mode (test) — Esc to go back") : qsTr("Game mode (test) — B to go back")
            color: "#8b97ab"
            font { family: theme.fontFamily; pixelSize: 18 }
        }
    }

    // UI sounds (theme.soundSet), short and quiet; off in the settings.
    QtObject {
        id: sfx
        readonly property string base: win.uiRoot + "/sounds/" + theme.soundSet + "/"
        readonly property bool on: prefs.sounds && theme.soundSet !== "" && !bench.running && !win.gameMode
                                   && !(win.session && win.session.running && !win.session.paused)
        function play(kind) {
            if (!on) return
            const e = kind === "accept" ? sAccept : kind === "back" ? sBack : sMove
            e.play()
        }
    }
    SoundEffect { id: sMove; source: theme.soundSet ? sfx.base + "move.wav" : ""; volume: theme.soundVolume * 0.7 }
    SoundEffect { id: sAccept; source: theme.soundSet ? sfx.base + "accept.wav" : ""; volume: theme.soundVolume }
    SoundEffect { id: sBack; source: theme.soundSet ? sfx.base + "back.wav" : ""; volume: theme.soundVolume }

    SearchOverlay {
        id: search
        anchors.fill: parent
        theme: win.theme
        model: libModel
        z: 60
        onPicked: (i) => { if (win.rows[i]) win.showGame(win.rows[i].rom_id) }
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
                Text { visible: diag.report !== null; text: qsTr("LAST BENCHMARK"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 15; letterSpacing: 1 } }
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
                Text { visible: diag.reportPath !== ""; width: parent.width; wrapMode: Text.WrapAnywhere; text: qsTr("Saved: %1").arg(diag.reportPath); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 15 } }
                KeyValues {
                    visible: diag.vramTest !== null; width: parent.width; theme: win.theme; keyWidth: 200
                    rows: diag.vramTest ? [[qsTr("VRAM before"), qsTr("%1 MB").arg(diag.vramTest.before)], [qsTr("VRAM in game mode"), qsTr("%1 MB").arg(diag.vramTest.during)], [qsTr("VRAM after"), qsTr("%1 MB").arg(diag.vramTest.after)], [qsTr("freed"), qsTr("%1 MB").arg(diag.vramTest.freed), typeof diag.vramTest.freed === "number" ? "ok" : ""]] : []
                }
            }
            Column {
                x: parent.width * 0.4 + 16; y: 72; width: parent.width * 0.6 - 48; spacing: 6
                Text { text: qsTr("SESSION"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 15; letterSpacing: 1 } }
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
                Text { topPadding: 8; text: qsTr("ENVIRONMENT"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 15; letterSpacing: 1 } }
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

    // The border round the screen, in the colour of the console you are on.
    ScreenBorder {
        anchors.fill: parent
        visible: win.framed
        tint: win.consoleTint
        margin: win.frameMargin
        radius: Math.round(34 * scene.k)
        unit: scene.k
        // Not over the settings (theirs or a game's): they fill the screen.
        fadeMs: Math.round(650 * graphite.motion)
    }

    // Light preferences stored by Qt (~/.config/Borne/Borne.conf).
    Settings {
        id: prefs
        category: "ui"
        property bool sounds: true
        property bool trailers: true          // older builds: one switch for every video (copied once to the two below)
        property bool videosSplit: false
        property bool bgVideo: false          // the selected game's video behind the library
        property bool pageVideo: true         // videos on the game page
        property int attractDelay: 5          // s without input before the video fills the screen; 0: never
        property int attractRest: 60          // s of full-screen video before the games come back; 0: never
        property int uiScale: 130             // interface size, %: read from a sofa by default
        property bool controlsAdvanced: false // controls: each button shown and set by pressing it
        property int scaleVersion: 0          // 1: the larger default given once to older settings
        property string language: "auto"      // interface language: "auto" (the system's) | "en" | "fr"
        // Switched at once (the launcher reloads the translation); the library comes back in it.
        onLanguageChanged: {
            if (typeof uiLanguage !== "undefined" && uiLanguage) uiLanguage.set(language)
            libReload.restart()
        }
        property string motion: "normal"      // "normal" | "reduced"
        property string soundVolume: "medium" // "low" | "medium" | "high"
        property string prompts: "auto"       // buttons shown in the hints: "auto" | "pad" | "keyboard"
        property bool showClock: true
        property string consoleOrder: "played" // the consoles' order (Shelf.consoleOrders)
        property string consoleCustom: "[]"   // the player's own order: console slugs, JSON
        property int calmVersion: 0           // 1: the library's video turned off once (a calmer screen)
        property string sortHome: "played"   // My library's order (Shelf.js sorts)
        property string sortStore: "added"   // the Store's
        property string background: "lights"  // behind the home: "lights" (the console's colour) | "art" (the game's)
        property bool videoMuted: false       // a game's video in full screen plays without its sound
        // Light and cards (Settings → Developer → Tune live; DesignTuner): 0–100 but lookCard.
        property int lookGlow: 60
        property int lookSoft: 100
        property int lookVignette: 0
        property int lookGrain: 0
        property string lookCard: "lacquer"    // "studio" | "lacquer" | "glass"
        property int lookKey: 40
        property int lookFloor: 0
        property int lookShadow: 0
        property int moveSpeed: 100            // the move between consoles: speed %, bounce, the console's delay
        property int moveBounce: 30
        property int moveDelay: 40
        property int notifiedBuild: 0
    }

    Component.onCompleted: {
        if (typeof quitKey !== "undefined" && quitKey) quitKey.pressed.connect(win.quitKeyPressed)
        graphite.accent = consoleTint
        if (!apiBase) return
        api("GET", "/api/v1/hello", null, function (h, err) {
            if (err || !h) { fatal = qsTr("Borne core unreachable (%1)").arg(err); return }
            if (h.api !== 1) { fatal = qsTr("Incompatible API version: core %1, UI 1").arg(h.api); return }
            coreVersion = h.core || ""
            // Safe mode: no video and no sound, the likeliest causes of repeated crashes.
            // Older settings kept the small 100 % of earlier builds: the larger default, once.
            if (prefs.scaleVersion < 1) { if (prefs.uiScale <= 100) prefs.uiScale = 130; prefs.scaleVersion = 1 }
            if (!prefs.videosSplit) { prefs.bgVideo = prefs.trailers; prefs.pageVideo = prefs.trailers; prefs.videosSplit = true }
            if (prefs.calmVersion < 1) { prefs.bgVideo = false; prefs.calmVersion = 1 }
            if (safeMode) { prefs.bgVideo = false; prefs.pageVideo = false; prefs.sounds = false }
            refreshStatus(function (s) {
                if (!s) { fatal = qsTr("Borne core unreachable"); return }
                if (!s.server_url) showServer()
                else showProfiles()
            })
        })
    }
}
