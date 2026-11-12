// Settings: sections on the left, their rows on the right.
// Gamepad: up/down moves in the focused column, right enters a section, left goes back to the
// sections, left/right inside a row of choices, A to choose, B to go back.
import QtQuick
import "CoreText.js" as CoreText
import "Display.js" as Display

Item {
    id: page
    property QtObject theme
    property var settings: null          // GET /api/v1/settings
    property var status: null            // GET /api/v1/status
    property bool sounds: true
    property bool trailers: true
    property string version: ""
    property var reportPaths: []

    signal action(string id, var payload)

    property int section: 0
    property bool inRows: false
    property int row: 0
    property var cols: ({})

    readonly property var upd: settings && settings.update ? settings.update : null
    readonly property var updState: upd && upd.update ? upd.update : null
    readonly property bool streamAvailable: settings ? settings.stream.available : false
    readonly property string installMode: settings ? settings.install_mode : "download"

    // The system files' names (Borne's list, in English) in the interface's language.
    function fileName(n) {
        const t = {
            "DS ARM7 BIOS": qsTr("DS ARM7 BIOS"), "DS ARM9 BIOS": qsTr("DS ARM9 BIOS"), "DS firmware": qsTr("DS firmware"),
            "Game Boy Advance BIOS": qsTr("Game Boy Advance BIOS"), "Mega-CD / Sega CD BIOS": qsTr("Mega-CD / Sega CD BIOS"),
            "PS3 firmware (PS3UPDAT.PUP)": qsTr("PS3 firmware (PS3UPDAT.PUP)"), "PS4 system modules (.sprx)": qsTr("PS4 system modules (.sprx)"),
            "PlayStation 2 BIOS": qsTr("PlayStation 2 BIOS"), "PlayStation BIOS": qsTr("PlayStation BIOS"), "Saturn BIOS": qsTr("Saturn BIOS"),
            "Switch firmware (archive of .nca files)": qsTr("Switch firmware (archive of .nca files)"),
            "Switch keys (prod.keys)": qsTr("Switch keys (prod.keys)"), "Switch title keys (title.keys)": qsTr("Switch title keys (title.keys)")
        }
        return t[n] || n
    }
    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }
    function onOff(v) { return [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] }

    readonly property string updateText: {
        if (!upd) return ""
        const st = updState ? updState.state : "idle"
        // The core says why in English; the known reasons are said in the interface's language.
        const reasons = {
            "this copy was built locally; updates come with the builds published on GitHub": qsTr("this copy was built locally; updates come with the builds published on GitHub"),
            "macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again": qsTr("macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again"),
            "installed with Flatpak: update it with Flatpak": qsTr("installed with Flatpak: update it with Flatpak"),
            "installation folder not recognized": qsTr("installation folder not recognized")
        }
        const why = upd.unsupported ? (reasons[upd.unsupported] || upd.unsupported.replace(/ is not writable$/, qsTr(" is not writable"))) : ""
        const manual = upd.unsupported ? qsTr("Borne cannot install it itself here (%1): download it from GitHub.").arg(why) : ""
        if (st === "available") {
            const v = updState.available
            const newer = v.build > upd.current.build
            return (newer ? qsTr("Version %1 is available.").arg(v.version) : qsTr("Latest build of this channel: %1 (the one installed).").arg(v.version)) + (manual ? " " + manual : "")
        }
        if (st === "downloading") return qsTr("Downloading the update… %1%").arg(updState.total > 0 ? Math.round(100 * updState.received / updState.total) : 0)
        if (st === "ready") return qsTr("Downloaded and verified. Borne restarts to install it.")
        if (st === "checking") return qsTr("Checking…")
        if (st === "uptodate") return qsTr("Borne is up to date.")
        if (st === "error") return qsTr("Update failed: %1").arg(CoreText.tr(updState.error || ""))
        return manual
    }
    readonly property var ss: settings && settings.screenscraper ? settings.screenscraper : null
    readonly property var emus: settings && settings.emulators ? settings.emulators : null
    function emuTaskText(id) {
        const t = emus ? emus.task : null
        if (!t || t.id !== id) return ""
        if (t.running) {
            if (t.step === "download" && t.total > 0) return qsTr("Downloading… %1%").arg(Math.round(100 * t.received / t.total))
            if (t.step === "core") return qsTr("Adding the %1 core…").arg(t.core)
            if (t.step === "unpack") return qsTr("Installing…")
            return qsTr("Preparing…")
        }
        return t.error ? qsTr("Installation failed: %1").arg(CoreText.tr(t.error)) : ""
    }
    function programText(p) {
        const t = emuTaskText(p.id)
        if (t) return t
        if (p.managed) return p.version === "flatpak" ? qsTr("Installed by Borne (Flathub), kept up to date") : qsTr("Version %1, installed by Borne and kept up to date").arg(p.version)
        if (p.found) return qsTr("Found: %1").arg(p.found)
        if (p.user_provided) return qsTr("Not found: choose its program (Borne does not download it)")
        return qsTr("Downloaded by Borne when a console needs it")
    }
    function programButtons(p) {
        const busy = !!(emus && emus.task && emus.task.running)
        const b = []
        if (p.installable) b.push({ id: "emu-install:" + p.id, label: p.managed ? qsTr("Update now") : qsTr("Install"), primary: !p.found, disabled: busy })
        if (p.user_provided || p.user_path) b.push({ id: "emu-path:" + p.id, label: p.user_path ? qsTr("Change program") : qsTr("Choose program"), primary: !p.found && !p.installable })
        if (p.user_path) b.push({ id: "emu-forget:" + p.id, label: qsTr("Forget this program") })
        return b
    }
    function emulatorRows() {
        if (!emus) return []
        const rows = emus.consoles.map(c => ({ id: "console:" + c.slug, kind: "chips", title: c.name,
            desc: c.choices.length === 0 ? (c.known ? qsTr("No emulator can run these games yet") : qsTr("Not supported by Borne yet"))
                  : !c.available ? qsTr("No build of this emulator for this computer") : qsTr("Emulator used for this console"),
            selected: c.chosen,
            items: c.choices.map(x => ({ id: x.id, label: x.name })) }))
        rows.push({ id: "emu-auto", kind: "chips", title: qsTr("Emulator updates"), desc: qsTr("Borne installs new versions by itself, never during a game"),
                    selected: emus.auto_update ? "on" : "off", items: onOff() })
        const used = {}
        emus.consoles.forEach(c => c.choices.forEach(x => { if (x.id === c.chosen) used[x.program] = true }))
        emus.programs.filter(p => used[p.id] || p.managed || p.user_path).forEach(p =>
            rows.push({ id: "prog:" + p.id, kind: "buttons", title: p.name, desc: programText(p), items: programButtons(p) }))
        return rows
    }

    readonly property bool ssRunning: !!(ss && ss.state && ss.state.running)
    function ssAccountText() {
        if (ss && !ss.developer_access)
            return qsTr("This build of Borne has no ScreenScraper developer access: the official builds include it. Images still come from RomM.")
        if (!ss || !ss.configured)
            return qsTr("Borne asks ScreenScraper itself for each game's case (front, spine, back), cartridge, logo and artwork, without going through RomM. Connect your ScreenScraper account (free on screenscraper.fr).")
        const st = ss.state || {}
        let t = qsTr("Connected as %1").arg(ss.user)
        if (st.max_requests) t += " · " + qsTr("%1 / %2 requests today").arg(st.requests_today || 0).arg(st.max_requests)
        return t
    }
    function ssFetchText() {
        const st = ss && ss.state ? ss.state : null
        if (!st) return ""
        if (st.running && st.paused) return qsTr("Paused: %1 / %2 games, %3 found").arg(st.done).arg(st.total).arg(st.found)
        if (st.running) return qsTr("Asking ScreenScraper… %1 / %2 games, %3 found").arg(st.done).arg(st.total).arg(st.found)
               + (st.threads > 1 ? " · " + qsTr("%1 at a time").arg(st.threads) : "")
        if (st.error) return qsTr("Stopped: %1").arg(CoreText.tr(st.error))
        if (ss.asked) return qsTr("%1 of %2 games found on ScreenScraper (%3 not asked yet). Their images take precedence over RomM's; new games are fetched after each sync.").arg(ss.found).arg(ss.asked).arg(Math.max(0, ss.games - ss.asked))
        return qsTr("Fetched after each sync for new games.")
    }
    // Case scans, cartridges and logos on this device, against the games of the library.
    function mediaText() {
        const m = settings && settings.media ? settings.media : null
        if (!m || !m.platforms.length) return ""
        let games = 0
        const have = { front: 0, side: 0, back: 0, physical: 0, logo: 0 }
        const gaps = []
        for (const p of m.platforms) {
            games += p.games
            for (const k in have) have[k] += p.have[k] || 0
            const missing = p.games - Math.min(p.games, p.have.side || 0)
            if (missing > 0) gaps.push(qsTr("%1: %2 without spine").arg(p.name).arg(missing))
        }
        if (status && status.sync && status.sync.media_pending > 0) return qsTr("Fetching… %1 image(s) left").arg(status.sync.media_pending)
        let t = qsTr("Front %1/%6 · spine %2/%6 · back %3/%6 · cartridge %4/%6 · logo %5/%6")
                .arg(have.front).arg(have.side).arg(have.back).arg(have.physical).arg(have.logo).arg(games)
        if (gaps.length) t += "\n" + gaps.slice(0, 4).join(" · ") + (gaps.length > 4 ? " …" : "")
              + "\n" + qsTr("Missing scans are not in RomM: add box2d, box2d_side, box2d_back, physical and logo to scan.media in RomM's ScreenScraper settings, then rescan.")
        return t
    }
    readonly property var updateButtons: {
        if (!upd) return []
        const st = updState ? updState.state : "idle"
        const github = { id: "update-github", label: qsTr("Open on GitHub") }
        if (st === "downloading" || st === "checking") return [{ id: "none", label: qsTr("Please wait…"), disabled: true }]
        if (st === "ready") return [{ id: "update-apply", label: qsTr("Restart and install"), primary: true }]
        if (st === "available") {
            const a = updState.available.assets[upd.current.platform]
            if (upd.unsupported) return [{ id: "update-github", label: qsTr("Download from GitHub"), primary: true }]
            return [{ id: "update-download", label: qsTr("Install · %1").arg(fmtSize(a ? a.size : 0)), primary: true }, github]
        }
        return [{ id: "update-check", label: qsTr("Check now"), primary: true },
                { id: "update-force", label: qsTr("Reinstall the latest build") }, github]
    }

    readonly property var sysFiles: settings && settings.system_files ? settings.system_files : null
    function sysFileRows() {
        if (!sysFiles) return []
        const rows = []
        const t = sysFiles.task
        sysFiles.consoles.forEach(c => c.items.forEach(i => {
            const busy = t && t.running && t.console === c.slug && t.item === i.id
            const failed = t && !t.running && t.error && t.console === c.slug && t.item === i.id
            let desc = busy ? qsTr("Adding…")
                     : i.files.length ? qsTr("Here: %1").arg(i.files.join(", "))
                     : i.required ? qsTr("Missing — needed to play") : qsTr("Optional")
            if (failed) desc = qsTr("Not added: %1").arg(CoreText.tr(t.error))
            const key = c.slug + "/" + i.id
            // A valid file is in place: only Remove (another file can be added once it is gone).
            const b = i.valid ? []
                    : [{ id: "sf-romm:" + key, label: qsTr("From RomM"), primary: !i.files.length && i.required, disabled: !!(t && t.running) },
                       { id: "sf-pick:" + key, label: qsTr("Choose a file"), disabled: !!(t && t.running) },
                       { id: "sf-url:" + key, label: qsTr("From a link"), disabled: !!(t && t.running) }]
            if (i.files.length) b.push({ id: "sf-remove:" + key, label: qsTr("Remove") })
            rows.push({ id: "sf:" + key, kind: "buttons", title: c.name + " · " + fileName(i.name), desc: desc, items: b })
        }))
        if (rows.length) rows.unshift({ id: "sf-all", kind: "buttons", title: qsTr("From RomM"),
            desc: qsTr("Borne takes the missing files from RomM's BIOS and firmware for each console, after each sync and when you ask."),
            items: [{ id: "sf-all", label: qsTr("Take them now"), primary: true, disabled: !!(t && t.running) }] })
        if (!rows.length) rows.push({ id: "sf-none", kind: "buttons", title: qsTr("Nothing needed"), desc: qsTr("No console of the library needs a BIOS, keys or firmware."), items: [] })
        return rows
    }
    // Display: for all games, or for one console (its own values over those for all games).
    property string displayScope: ""
    property var displayView: null       // GET /api/v1/display?console=… for the console shown
    readonly property var displayData: displayScope !== "" && displayView ? displayView : (settings && settings.display ? settings.display : null)
    function displayRows() {
        if (!displayData) return []
        const consoles = settings && settings.emulators ? settings.emulators.consoles : []
        const cur = consoles.find(c => c.slug === displayScope)
        const rows = [{ id: "disp-scope", kind: "buttons", title: cur ? cur.name : qsTr("All games"),
            desc: displayScope ? qsTr("This console's own values; the others follow all games") : qsTr("Every game, unless its console or the game has its own"),
            items: [{ id: "display-scope-menu", label: qsTr("Change console"), primary: false }] }]
        return rows.concat(Display.KEYS.map(k => {
            const items = Display.values(k).map(v => ({ id: v, label: Display.label(k, v) }))
            if (displayScope) items.unshift({ id: "default", label: qsTr("As for all games") })
            const own = displayData.own ? displayData.own[k] : undefined
            return { id: "disp:" + k, kind: "chips", title: Display.title(k), desc: Display.desc(k),
                     selected: displayScope ? (own !== undefined ? own : "default") : displayData.effective[k], items: items }
        }))
    }
    readonly property var sections: [
        { id: "games", name: qsTr("Games"), hint: qsTr("Installation, saves") },
        { id: "updates", name: qsTr("Updates"), hint: upd && upd.channel === "dev" ? qsTr("Development") : qsTr("Stable") },
        { id: "interface", name: qsTr("Interface"), hint: qsTr("Sounds, videos") },
        { id: "display", name: qsTr("Display"), hint: qsTr("Picture, ratio, filters") },
        { id: "emulators", name: qsTr("Emulators"), hint: qsTr("One per console") },
        { id: "systemfiles", name: qsTr("System files"), hint: qsTr("BIOS, keys, firmware") },
        { id: "screenscraper", name: qsTr("Game images"), hint: qsTr("ScreenScraper") },
        { id: "server", name: qsTr("Server"), hint: qsTr("RomM, sync, profile") },
        { id: "help", name: qsTr("Help"), hint: qsTr("Diagnostics, quit") }
    ]
    readonly property var cacheSizes: [5, 10, 20, 50, 100]
    readonly property var rows: {
        const id = sections[section].id
        if (id === "games") return [
            { id: "install", kind: "cards", selected: installMode },
            { id: "savesync", kind: "chips", title: qsTr("Saves on RomM"), desc: qsTr("Each profile's saves follow it: taken from RomM before a game when newer, sent after it. Replaced saves are archived."),
              selected: settings && settings.save_sync === false ? "off" : "on", items: onOff() },
            { id: "cache", kind: "chips", title: qsTr("Space for network play"), desc: qsTr("Disk space Borne keeps for games played from the network (without downloading them), so they start faster next time"),
              selected: settings && settings.stream.cache_limit_mb ? String(Math.round(settings.stream.cache_limit_mb / 1024)) : "20",
              items: cacheSizes.map(g => ({ id: String(g), label: qsTr("%1 GB").arg(g) })) }
        ].filter(r => r.id !== "cache" || installMode === "stream")   // network play only
        if (id === "updates") return [
            { id: "channel", kind: "chips", title: qsTr("Update channel"), desc: qsTr("Stable gets tested releases; Development gets every build"),
              selected: upd ? upd.channel : "stable", items: [{ id: "stable", label: qsTr("Stable") }, { id: "dev", label: qsTr("Development") }] },
            { id: "auto", kind: "chips", title: qsTr("Check automatically"), desc: qsTr("Every 6 hours, never while you play"),
              selected: upd && upd.auto_check ? "on" : "off", items: onOff() },
            { id: "update", kind: "buttons", title: qsTr("Installed version: %1").arg(page.version), desc: updateText, items: updateButtons }
        ]
        if (id === "interface") return [
            { id: "sounds", kind: "chips", title: qsTr("Interface sounds"), desc: qsTr("Short, quiet sounds when moving and choosing"), selected: sounds ? "on" : "off", items: onOff() },
            { id: "trailers", kind: "chips", title: qsTr("Game videos"), desc: qsTr("Videos of the games, muted: behind the library and on the game page"), selected: trailers ? "on" : "off", items: onOff() }
        ]
        if (id === "display") return displayRows()
        if (id === "emulators") return emulatorRows()
        if (id === "systemfiles") return sysFileRows()
        if (id === "screenscraper") return [
            { id: "ss-account", kind: "buttons", title: qsTr("ScreenScraper account"), desc: ssAccountText(),
              items: !(ss && ss.developer_access) ? []
                     : ss.configured ? [{ id: "ss-signin", label: qsTr("Change") }, { id: "ss-signout", label: qsTr("Sign out") }]
                     : [{ id: "ss-signin", label: qsTr("Connect"), primary: true }] },
            { id: "ss-fetch", kind: "buttons", title: qsTr("Case scans, cartridges, logos"), desc: ssFetchText(),
              items: ssRunning
                     ? [{ id: ss.state.paused ? "ss-resume" : "ss-pause", label: ss.state.paused ? qsTr("Resume") : qsTr("Pause"), primary: true },
                        { id: "ss-stop", label: qsTr("Stop") }]
                     : [{ id: "ss-fetch", label: qsTr("Fetch missing"), primary: true, disabled: !(ss && ss.configured) },
                        { id: "ss-again", label: qsTr("Fetch everything again"), disabled: !(ss && ss.configured) }] },
            { id: "ss-report", kind: "buttons", title: qsTr("Games found, per console"), desc: qsTr("Which games ScreenScraper recognised, and those it did not: open one to correct its match"),
              items: [{ id: "ss-report", label: qsTr("See the report"), disabled: !(ss && ss.configured) }] }
        ]
        if (id === "server") return [
            { id: "sync", kind: "buttons", title: qsTr("Library"), desc: syncText(), items: [{ id: "sync", label: qsTr("Sync now"), disabled: !!(status && status.sync && status.sync.running) }] },
            { id: "server", kind: "buttons", title: qsTr("RomM server"), desc: status && status.server_url ? status.server_url + (status.online ? "" : " · " + qsTr("offline")) : qsTr("not configured"),
              items: [{ id: "server", label: qsTr("Change server") }] },
            { id: "profile", kind: "buttons", title: qsTr("Profile"), desc: status && status.active_profile ? status.active_profile.name : "",
              items: [{ id: "profile", label: qsTr("Switch profile") }] }
        ]
        return [
            { id: "report", kind: "buttons", title: qsTr("Diagnostic report"),
              desc: reportPaths.length ? qsTr("Saved: %1").arg(reportPaths[reportPaths.length - 1]) : qsTr("Saves the log and settings, without passwords or tokens, to share when something goes wrong"),
              items: [{ id: "report", label: qsTr("Export the report") }] },
            { id: "diag", kind: "buttons", title: qsTr("Measurements"), desc: qsTr("Graphics, memory and disk speed of this device, to understand a slow game"),
              items: [{ id: "diag", label: qsTr("Open") }] },
            { id: "quit", kind: "buttons", title: qsTr("Quit Borne"), desc: qsTr("Back to the system"), items: [{ id: "quit", label: qsTr("Quit") }] }
        ]
    }
    function syncText() {
        const s = status ? status.sync : null
        if (!s) return ""
        if (s.running) return qsTr("Syncing %1 of %2…").arg(s.done).arg(s.total)
        if (s.error) return qsTr("Last sync failed: %1").arg(CoreText.tr(s.error))
        if (s.last_sync) return qsTr("Synced at %1").arg(new Date(s.last_sync * 1000).toLocaleTimeString(Qt.locale(), Locale.ShortFormat))
        return ""
    }
    readonly property var installItems: [{ id: "download" }, { id: "stream", disabled: !streamAvailable }]

    function itemsOf(r) { return r.kind === "cards" ? installItems : r.items }
    function colOf(id) { return cols[id] !== undefined ? cols[id] : 0 }
    function setCol(id, c) { const n = Object.assign({}, cols); n[id] = c; cols = n }
    function selectSection(i) {
        section = i
        row = 0
        const c = {}
        for (const r of rows) c[r.id] = Math.max(0, itemsOf(r).findIndex(x => x.id === r.selected))
        cols = c
    }
    function reset() { displayScope = ""; displayView = null; inRows = false; selectSection(0) }
    function activate(r, i) {
        const item = itemsOf(r)[i]
        if (!item || item.disabled || item.id === "none") return
        if (r.id === "install") page.action("install", item.id)
        else if (r.id === "cache") page.action("cache", Number(item.id) * 1024)
        else if (r.id === "channel") page.action("channel", item.id)
        else if (r.id === "auto") page.action("auto", item.id === "on")
        else if (r.id === "savesync") page.action("savesync", item.id === "on")
        else if (r.id === "sounds") page.action("sounds", item.id === "on")
        else if (r.id.startsWith("disp:")) page.action("display", { console: page.displayScope, key: r.id.substring(5), value: item.id })
        else if (r.id.startsWith("console:")) page.action("console-emu", { slug: r.id.substring(8), engine: item.id })
        else if (r.id === "emu-auto") page.action("emu-auto", item.id === "on")
        else if (r.id === "lb") page.action("lb-enabled", item.id === "on")
        else if (r.id === "trailers") page.action("trailers", item.id === "on")
        else page.action(item.id, null)
    }
    function handle(a) {
        if (a === "b" || a === "start") {
            if (inRows && a === "b") { inRows = false; return }
            page.action("back", null)
            return
        }
        if (!inRows) {
            if (a === "up") selectSection(Math.max(0, section - 1))
            else if (a === "down") selectSection(Math.min(sections.length - 1, section + 1))
            else if (a === "right" || a === "a") { inRows = true; row = 0 }
            return
        }
        const r = rows[Math.min(row, rows.length - 1)]
        const n = itemsOf(r).length
        if (a === "up") row = Math.max(0, row - 1)
        else if (a === "down") row = Math.min(rows.length - 1, row + 1)
        else if (a === "left") { if (colOf(r.id) === 0) inRows = false; else setCol(r.id, colOf(r.id) - 1) }
        else if (a === "right") setCol(r.id, Math.min(n - 1, colOf(r.id) + 1))
        else if (a === "a") activate(r, colOf(r.id))
    }
    function focused(id, i) { return inRows && rows[row] && rows[row].id === id && colOf(id) === i }


    // ---------- sections ----------
    Rectangle {
        id: side
        width: 480
        height: parent.height
        color: Qt.rgba(1, 1, 1, 0.05)
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.1) }

        Text {
            x: 64; y: 72
            text: qsTr("Settings")
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 48; weight: Font.ExtraBold; letterSpacing: -1 }
        }
        Column {
            x: 64; y: 160
            width: parent.width - 104
            spacing: 8
            Repeater {
                model: page.sections
                Rectangle {
                    id: sec
                    required property var modelData
                    required property int index
                    readonly property bool current: page.section === index
                    width: parent.width; height: 72
                    radius: 14
                    // The open section: a soft fill and a bar in the accent colour; brighter while the
                    // focus is on the list (no ring: the bar says it).
                    readonly property bool focusedHere: current && !page.inRows
                    color: focusedHere ? Qt.rgba(1, 1, 1, 0.14) : current ? Qt.rgba(1, 1, 1, 0.06) : "transparent"
                    Behavior on color { ColorAnimation { duration: theme.focusMs } }
                    Rectangle {
                        x: 0; anchors.verticalCenter: parent.verticalCenter
                        width: 4; height: parent.height - 24; radius: 2
                        color: theme.accent
                        opacity: sec.focusedHere ? 1 : sec.current ? 0.45 : 0
                    }
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.name
                    Column {
                        x: 20; anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: sec.modelData.name; color: sec.current ? theme.fg : theme.fgMuted; font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold } }
                        Text { text: sec.modelData.hint; color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium } }
                    }
                }
            }
        }
        Text {
            x: 64; anchors { bottom: parent.bottom; bottomMargin: 32 }
            width: parent.width - 104
            text: qsTr("Borne %1").arg(page.version) + (page.status && page.status.server_url ? "\n" + page.status.server_url : "")
            wrapMode: Text.WrapAnywhere
            lineHeight: 1.5
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 15 }
        }
    }

    // ---------- rows (scroll to follow the selection when there are many) ----------
    Flickable {
        id: rowsView
        x: side.width + 80; y: 64
        width: Math.min(1500, parent.width - x - 96)
        height: parent.height - y - 110
        contentHeight: rowsCol.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Behavior on contentY { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
        function ensure(item) {
            const top = item.y, bottom = item.y + item.height
            if (top - 24 < contentY) contentY = Math.max(0, top - 24)
            else if (bottom + 24 > contentY + height) contentY = Math.min(contentHeight - height, bottom + 24 - height)
        }
        Connections { target: page; function onSectionChanged() { rowsView.contentY = 0 } }
    Column {
        id: rowsCol
        width: parent.width
        spacing: 18

        Column {
            visible: page.sections[page.section].id === "games"
            width: parent.width
            spacing: 10
            Text { text: qsTr("How games are installed"); color: theme.fg; font { family: theme.displayFont; pixelSize: 34; weight: Font.Bold } }
            Text { width: parent.width; wrapMode: Text.WordWrap; text: qsTr("Choose once; you can switch at any time. Games already on this device stay where they are."); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 18 } }
        }
        Text {
            visible: page.sections[page.section].id !== "games"
            text: page.sections[page.section].name
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 34; weight: Font.Bold }
        }

        Repeater {
            model: page.rows
            Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool current: page.row === index
                onCurrentChanged: if (current) rowsView.ensure(rowItem)
                width: parent.width
                height: modelData.kind === "cards" ? cards.height : Math.max(96, line.height + 52)

                // Install method: two explained cards.
                Row {
                    id: cards
                    visible: rowItem.modelData.kind === "cards"
                    width: parent.width
                    spacing: 24
                    OptionCard {
                        width: (parent.width - 24) / 2
                        theme: page.theme
                        title: qsTr("Download")
                        badge: page.installMode === "download" ? qsTr("Current") : ""
                        summary: qsTr("The whole game is copied to this device before you play.")
                        points: [qsTr("Plays offline, even if the server is down"), qsTr("Fastest loading, no network during play"), qsTr("Uses disk space for every installed game")]
                        selected: page.installMode === "download"
                        focused: page.focused("install", 0)
                    }
                    OptionCard {
                        width: (parent.width - 24) / 2
                        theme: page.theme
                        title: qsTr("Mount")
                        badge: page.installMode === "stream" ? qsTr("Current") : page.streamAvailable ? "" : qsTr("Linux only")
                        summary: qsTr("Borne reads the game from RomM while you play. Only games you pick are exposed.")
                        points: [qsTr("Starts in seconds, even for large games"), qsTr("Keeps the disk free; a small cache speeds up replays"), qsTr("Needs the server reachable during play")]
                        note: !page.streamAvailable && page.settings && page.settings.stream.error ? qsTr("Unavailable here: %1").arg(CoreText.tr(page.settings.stream.error)) : ""
                        selected: page.installMode === "stream"
                        disabled: !page.streamAvailable
                        focused: page.focused("install", 1)
                    }
                }

                // Each setting is a card, as in the redesign; the current one stands out.
                Rectangle {
                    visible: rowItem.modelData.kind !== "cards"
                    anchors.fill: parent
                    radius: 26
                    color: rowItem.current ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(1, 1, 1, 0.045)
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
                // A setting: title and explanation, choices or buttons on the right.
                Item {
                    id: line
                    visible: rowItem.modelData.kind !== "cards"
                    x: 32
                    width: parent.width - 64
                    height: Math.max(texts.height, choices.height)
                    anchors.verticalCenter: parent.verticalCenter
                    Column {
                        id: texts
                        width: parent.width - choices.width - 32
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 4
                        Text { text: rowItem.modelData.title || ""; color: theme.fg; font { family: theme.fontFamily; pixelSize: 20; weight: Font.DemiBold } }
                        Text {
                            visible: text !== ""
                            width: parent.width
                            text: rowItem.modelData.desc || ""
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            color: theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 16 }
                        }
                    }
                    Row {
                        id: choices
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: 10
                        Repeater {
                            model: rowItem.modelData.kind === "cards" ? [] : rowItem.modelData.items
                            Item {
                                required property var modelData
                                required property int index
                                width: rowItem.modelData.kind === "buttons" ? btn.width : chip.width
                                height: rowItem.modelData.kind === "buttons" ? btn.height : chip.height
                                PageButton {
                                    id: btn
                                    visible: rowItem.modelData.kind === "buttons"
                                    implicitHeight: 52
                                    theme: page.theme
                                    text: modelData.label
                                    primary: !!modelData.primary
                                    disabled: !!modelData.disabled
                                    focused: page.focused(rowItem.modelData.id, index)
                                }
                                Chip {
                                    id: chip
                                    visible: rowItem.modelData.kind === "chips"
                                    theme: page.theme
                                    text: modelData.label
                                    selected: modelData.id === rowItem.modelData.selected
                                    focused: page.focused(rowItem.modelData.id, index)
                                }
                            }
                        }
                    }
                }

            }
        }
    }
    }

    // ---------- hints ----------
    Item {
        anchors { left: side.right; right: parent.right; bottom: parent.bottom; bottomMargin: 20 }
        height: 48
        HintBar {
            x: 64; anchors.verticalCenter: parent.verticalCenter
            theme: page.theme
            hints: [["A", qsTr("Choose"), "a"], ["B", qsTr("Back"), "b"], ["◀ ▶", qsTr("Change value"), "right"]]
        }
    }
}
