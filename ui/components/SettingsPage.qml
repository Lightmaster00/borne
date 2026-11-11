// Settings: sections on the left, their rows on the right.
// Gamepad: up/down moves in the focused column, right enters a section, left goes back to the
// sections, left/right inside a row of choices, A to choose, B to go back. Mouse: all clickable.
import QtQuick

Item {
    id: page
    property QtObject theme
    property var settings: null          // GET /api/v1/settings
    property var status: null            // GET /api/v1/status
    property bool sounds: true
    property bool trailers: true
    property string homeStyle: "boxes"
    property string backgroundStyle: "video"
    property bool cases3d: true
    property bool pointerActive: false
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

    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }
    function onOff(v) { return [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] }

    readonly property string updateText: {
        if (!upd) return ""
        const st = updState ? updState.state : "idle"
        const manual = upd.unsupported ? qsTr("Borne cannot install it itself here (%1): download it from GitHub.").arg(upd.unsupported) : ""
        if (st === "available") {
            const v = updState.available
            const newer = v.build > upd.current.build
            return (newer ? qsTr("Version %1 is available.").arg(v.version) : qsTr("Latest build of this channel: %1 (the one installed).").arg(v.version)) + (manual ? " " + manual : "")
        }
        if (st === "downloading") return qsTr("Downloading the update… %1%").arg(updState.total > 0 ? Math.round(100 * updState.received / updState.total) : 0)
        if (st === "ready") return qsTr("Downloaded and verified. Borne restarts to install it.")
        if (st === "checking") return qsTr("Checking…")
        if (st === "uptodate") return qsTr("Borne is up to date.")
        if (st === "error") return qsTr("Update failed: %1").arg(updState.error || "")
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
        return t.error ? qsTr("Installation failed: %1").arg(t.error) : ""
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
        if (st.running) return qsTr("Asking ScreenScraper… %1 / %2 games, %3 found").arg(st.done).arg(st.total).arg(st.found)
        if (st.error) return qsTr("Stopped: %1").arg(st.error)
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

    readonly property var sections: [
        { id: "games", name: qsTr("Games"), hint: qsTr("Install, cache") },
        { id: "updates", name: qsTr("Updates"), hint: upd && upd.channel === "dev" ? qsTr("Development") : qsTr("Stable") },
        { id: "interface", name: qsTr("Interface"), hint: qsTr("Sounds, trailers") },
        { id: "emulators", name: qsTr("Emulators"), hint: qsTr("One per console") },
        { id: "screenscraper", name: qsTr("Game images"), hint: ss && ss.configured ? ss.user : qsTr("ScreenScraper") },
        { id: "server", name: qsTr("Server"), hint: qsTr("RomM, profiles") },
        { id: "help", name: qsTr("Help"), hint: qsTr("Diagnostic report") }
    ]
    readonly property var cacheSizes: [5, 10, 20, 50, 100]
    readonly property var rows: {
        const id = sections[section].id
        if (id === "games") return [
            { id: "install", kind: "cards", selected: installMode },
            { id: "cache", kind: "chips", title: qsTr("Mount cache"), desc: qsTr("Space kept for recently played mounted games"),
              selected: settings && settings.stream.cache_limit_mb ? String(Math.round(settings.stream.cache_limit_mb / 1024)) : "20",
              items: cacheSizes.map(g => ({ id: String(g), label: qsTr("%1 GB").arg(g) })) }
        ]
        if (id === "updates") return [
            { id: "channel", kind: "chips", title: qsTr("Update channel"), desc: qsTr("Stable gets tested releases; Development gets every build"),
              selected: upd ? upd.channel : "stable", items: [{ id: "stable", label: qsTr("Stable") }, { id: "dev", label: qsTr("Development") }] },
            { id: "auto", kind: "chips", title: qsTr("Check automatically"), desc: qsTr("Every 6 hours, never while you play"),
              selected: upd && upd.auto_check ? "on" : "off", items: onOff() },
            { id: "update", kind: "buttons", title: qsTr("Borne %1").arg(page.version), desc: updateText, items: updateButtons }
        ]
        if (id === "interface") return [
            { id: "home", kind: "chips", title: qsTr("Home"), desc: qsTr("How the library is shown"), selected: homeStyle,
              items: [{ id: "boxes", label: qsTr("Game boxes") }, { id: "arcade", label: qsTr("Arcade room") }] },
            { id: "background", kind: "chips", title: qsTr("Background"), desc: qsTr("Behind the game boxes"), selected: backgroundStyle,
              items: [{ id: "video", label: qsTr("Gameplay video") }, { id: "pixels", label: qsTr("Pixel mosaic") }, { id: "ribbons", label: qsTr("Console color") }, { id: "game", label: qsTr("The game's art") }, { id: "room", label: qsTr("Game room") }, { id: "light", label: qsTr("Moving light") }] },
            { id: "cases", kind: "chips", title: qsTr("Game cases"), desc: qsTr("3D cases lit in real time, or a lighter flat drawing for slow machines"), selected: cases3d ? "3d" : "2d",
              items: [{ id: "3d", label: qsTr("3D") }, { id: "2d", label: qsTr("Flat") }] },
            { id: "sounds", kind: "chips", title: qsTr("Interface sounds"), desc: qsTr("Short, quiet sounds when moving and choosing"), selected: sounds ? "on" : "off", items: onOff() },
            { id: "trailers", kind: "chips", title: qsTr("Trailers"), desc: qsTr("Play the selected game's trailer, muted, after two seconds"), selected: trailers ? "on" : "off", items: onOff() }
        ]
        if (id === "emulators") return emulatorRows()
        if (id === "screenscraper") return [
            { id: "ss-account", kind: "buttons", title: qsTr("ScreenScraper account"), desc: ssAccountText(),
              items: !(ss && ss.developer_access) ? []
                     : ss.configured ? [{ id: "ss-signin", label: qsTr("Change") }, { id: "ss-signout", label: qsTr("Sign out") }]
                     : [{ id: "ss-signin", label: qsTr("Connect"), primary: true }] },
            { id: "ss-fetch", kind: "buttons", title: qsTr("Case scans, cartridges, logos"), desc: ssFetchText(),
              items: [{ id: "ss-fetch", label: qsTr("Fetch missing"), primary: true, disabled: !(ss && ss.configured) || ssRunning },
                      { id: "ss-again", label: qsTr("Fetch everything again"), disabled: !(ss && ss.configured) || ssRunning }] }
        ]
        if (id === "server") return [
            { id: "media", kind: "buttons", title: qsTr("Game media"), desc: mediaText(),
              items: [{ id: "media-refresh", label: qsTr("Fetch again"), disabled: !!(status && status.sync && status.sync.running) }] },
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
            { id: "diag", kind: "buttons", title: qsTr("Diagnostics and measurements"), desc: qsTr("Graphics session, memory, smoothness benchmark"),
              items: [{ id: "diag", label: qsTr("Open") }] },
            { id: "quit", kind: "buttons", title: qsTr("Quit Borne"), desc: "", items: [{ id: "quit", label: qsTr("Quit") }] }
        ]
    }
    function syncText() {
        const s = status ? status.sync : null
        if (!s) return ""
        if (s.running) return qsTr("Syncing %1 of %2…").arg(s.done).arg(s.total)
        if (s.error) return qsTr("Last sync failed: %1").arg(s.error)
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
    function reset() { inRows = false; selectSection(0) }
    function activate(r, i) {
        const item = itemsOf(r)[i]
        if (!item || item.disabled || item.id === "none") return
        if (r.id === "install") page.action("install", item.id)
        else if (r.id === "cache") page.action("cache", Number(item.id) * 1024)
        else if (r.id === "channel") page.action("channel", item.id)
        else if (r.id === "auto") page.action("auto", item.id === "on")
        else if (r.id === "sounds") page.action("sounds", item.id === "on")
        else if (r.id === "home") page.action("home", item.id)
        else if (r.id === "background") page.action("background", item.id)
        else if (r.id === "cases") page.action("cases", item.id)
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
    function click(id, i) { inRows = true; row = rows.findIndex(r => r.id === id); setCol(id, i); activate(rows[row], i) }

    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (w) => w.accepted = true }

    // ---------- sections ----------
    Rectangle {
        id: side
        width: 480
        height: parent.height
        color: Qt.rgba(1, 1, 1, 0.05)
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.1) }

        Rectangle {
            x: 64; y: 56
            width: backRow.implicitWidth + 24; height: 44
            radius: 22
            color: backMouse.containsMouse ? theme.glassRaised : theme.glass
            border { width: 1; color: theme.glassEdge }
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Back to the library")
            Row {
                id: backRow
                anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                spacing: 10
                Rectangle {
                    width: 32; height: 32; radius: 16; color: theme.glassRaised
                    Text { anchors.centerIn: parent; text: "B"; color: theme.fg; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold } }
                }
                Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Library"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.Medium } }
            }
            MouseArea { id: backMouse; anchors.fill: parent; hoverEnabled: page.pointerActive; cursorShape: Qt.PointingHandCursor; onClicked: page.action("back", null) }
        }
        Text {
            x: 64; y: 128
            text: qsTr("Settings")
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 48; weight: Font.ExtraBold; letterSpacing: -1 }
        }
        Column {
            x: 64; y: 216
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
                    color: current ? Qt.rgba(1, 1, 1, 0.1) : secMouse.containsMouse ? theme.glass : "transparent"
                    border { width: current ? 1 : 0; color: Qt.rgba(1, 1, 1, 0.16) }
                    Accessible.role: Accessible.PageTab
                    Accessible.name: modelData.name
                    Column {
                        x: 20; anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text { text: sec.modelData.name; color: sec.current ? theme.fg : theme.fgMuted; font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold } }
                        Text { text: sec.modelData.hint; color: theme.fgFaint; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium } }
                    }
                    Rectangle {
                        anchors { fill: parent; margins: -(theme.ringGap + 3) }
                        radius: parent.radius + theme.ringGap + 3
                        color: "transparent"
                        border { width: 3; color: theme.focusRing }
                        opacity: sec.current && !page.inRows ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
                    }
                    MouseArea { id: secMouse; anchors.fill: parent; hoverEnabled: page.pointerActive; cursorShape: Qt.PointingHandCursor; onClicked: { page.inRows = false; page.selectSection(sec.index) } }
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
        spacing: 32

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
                height: modelData.kind === "cards" ? cards.height : Math.max(88, line.height + 24)

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
                        pointerActive: page.pointerActive
                        onClicked: page.click("install", 0)
                    }
                    OptionCard {
                        width: (parent.width - 24) / 2
                        theme: page.theme
                        title: qsTr("Mount")
                        badge: page.installMode === "stream" ? qsTr("Current") : page.streamAvailable ? "" : qsTr("Linux only")
                        summary: qsTr("Borne reads the game from RomM while you play. Only games you pick are exposed.")
                        points: [qsTr("Starts in seconds, even for large games"), qsTr("Keeps the disk free; a small cache speeds up replays"), qsTr("Needs the server reachable during play")]
                        note: !page.streamAvailable && page.settings && page.settings.stream.error ? qsTr("Unavailable here: %1").arg(page.settings.stream.error) : ""
                        selected: page.installMode === "stream"
                        disabled: !page.streamAvailable
                        focused: page.focused("install", 1)
                        pointerActive: page.pointerActive
                        onClicked: page.click("install", 1)
                    }
                }

                // A setting: title and explanation, choices or buttons on the right.
                Item {
                    id: line
                    visible: rowItem.modelData.kind !== "cards"
                    width: parent.width
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
                                    pointerActive: page.pointerActive
                                    onClicked: page.click(rowItem.modelData.id, index)
                                }
                                Chip {
                                    id: chip
                                    visible: rowItem.modelData.kind === "chips"
                                    theme: page.theme
                                    text: modelData.label
                                    selected: modelData.id === rowItem.modelData.selected
                                    focused: page.focused(rowItem.modelData.id, index)
                                    pointerActive: page.pointerActive
                                    onClicked: page.click(rowItem.modelData.id, index)
                                }
                            }
                        }
                    }
                }
                Rectangle {
                    visible: rowItem.modelData.kind !== "cards"
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Qt.rgba(1, 1, 1, 0.1)
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
            pointerActive: page.pointerActive
            hints: [["A", qsTr("Choose"), "a"], ["B", qsTr("Back"), "b"], ["◀ ▶", qsTr("Change value"), "right"]]
            onTriggered: (a) => page.handle(a)
        }
    }
}
