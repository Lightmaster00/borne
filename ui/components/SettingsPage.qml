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
        if (upd.unsupported) return qsTr("Updates are handled outside Borne here: %1").arg(upd.unsupported)
        const st = updState ? updState.state : "idle"
        if (st === "available") return qsTr("Version %1 is available.").arg(updState.available.version)
        if (st === "downloading") return qsTr("Downloading the update… %1%").arg(updState.total > 0 ? Math.round(100 * updState.received / updState.total) : 0)
        if (st === "ready") return qsTr("Downloaded and verified. Borne restarts to install it.")
        if (st === "checking") return qsTr("Checking…")
        if (st === "uptodate") return qsTr("Borne is up to date.")
        if (st === "error") return qsTr("Update failed: %1").arg(updState.error || "")
        return ""
    }
    readonly property var updateButtons: {
        if (!upd || upd.unsupported) return []
        const st = updState ? updState.state : "idle"
        if (st === "available") return [{ id: "update-download", label: qsTr("Download · %1").arg(fmtSize(updState.available.assets[upd.current.platform].size)), primary: true }]
        if (st === "downloading" || st === "checking") return [{ id: "none", label: qsTr("Please wait…"), disabled: true }]
        if (st === "ready") return [{ id: "update-apply", label: qsTr("Restart and install"), primary: true }]
        return [{ id: "update-check", label: qsTr("Check now") }]
    }

    readonly property var sections: [
        { id: "games", name: qsTr("Games"), hint: qsTr("Install, cache") },
        { id: "updates", name: qsTr("Updates"), hint: upd && upd.channel === "dev" ? qsTr("Development") : qsTr("Stable") },
        { id: "interface", name: qsTr("Interface"), hint: qsTr("Sounds, trailers") },
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
            { id: "sounds", kind: "chips", title: qsTr("Interface sounds"), desc: qsTr("Short, quiet sounds when moving and choosing"), selected: sounds ? "on" : "off", items: onOff() },
            { id: "trailers", kind: "chips", title: qsTr("Trailers"), desc: qsTr("Play the selected game's trailer, muted, after two seconds"), selected: trailers ? "on" : "off", items: onOff() }
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

    // ---------- rows ----------
    Column {
        x: side.width + 80; y: 64
        width: parent.width - x - 96
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
