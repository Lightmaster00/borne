// Settings: how games are installed (with what each method brings), updates, interface.
// Gamepad: up/down between rows, left/right inside a row, A to choose, B to go back.
// Mouse: everything is clickable.
import QtQuick

Item {
    id: page
    property QtObject theme
    property var settings: null          // GET /api/v1/settings
    property bool sounds: true
    property bool trailers: true
    property bool pointerActive: false

    signal action(string id, var payload)

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

    // ---------- rows ----------
    readonly property var updateButtons: {
        if (!upd || upd.unsupported) return []
        const st = updState ? updState.state : "idle"
        if (st === "available") return [{ id: "update-download", label: qsTr("Download version %1 · %2").arg(updState.available.version).arg(fmtSize(updState.available.assets[upd.current.platform].size)), primary: true }]
        if (st === "downloading") return [{ id: "none", label: qsTr("Downloading… %1%").arg(updState.total > 0 ? Math.round(100 * updState.received / updState.total) : 0), disabled: true }]
        if (st === "ready") return [{ id: "update-apply", label: qsTr("Restart and install"), primary: true }]
        if (st === "checking") return [{ id: "none", label: qsTr("Checking…"), disabled: true }]
        return [{ id: "update-check", label: qsTr("Check for updates") }]
    }
    readonly property var cacheSizes: [5, 10, 20, 50, 100]
    readonly property var rows: [
        { id: "install", kind: "cards", selected: installMode },
        { id: "cache", kind: "chips", selected: settings && settings.stream.cache_limit_mb ? String(Math.round(settings.stream.cache_limit_mb / 1024)) : "20",
          items: cacheSizes.map(g => ({ id: String(g), label: qsTr("%1 GB").arg(g) })) },
        { id: "channel", kind: "chips", selected: upd ? upd.channel : "stable",
          items: [{ id: "stable", label: qsTr("Stable") }, { id: "dev", label: qsTr("Development") }] },
        { id: "auto", kind: "chips", selected: upd && upd.auto_check ? "on" : "off",
          items: [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] },
        { id: "update", kind: "buttons", items: updateButtons },
        { id: "sounds", kind: "chips", selected: sounds ? "on" : "off", items: [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] },
        { id: "trailers", kind: "chips", selected: trailers ? "on" : "off", items: [{ id: "on", label: qsTr("On") }, { id: "off", label: qsTr("Off") }] }
    ].filter(r => r.kind !== "buttons" || r.items.length > 0)
    readonly property var installItems: [{ id: "download" }, { id: "stream" }]

    function itemsOf(r) { return r.kind === "cards" ? installItems : r.items }
    function colOf(id) { return cols[id] !== undefined ? cols[id] : 0 }
    function setCol(id, c) { const n = Object.assign({}, cols); n[id] = c; cols = n }
    function rowIndex(id) { return rows.findIndex(r => r.id === id) }
    function reset() {
        row = 0
        const c = {}
        for (const r of rows) {
            const items = itemsOf(r)
            c[r.id] = Math.max(0, items.findIndex(i => i.id === r.selected))
        }
        cols = c
        body.contentY = 0
    }
    function activate(r, i) {
        const item = itemsOf(r)[i]
        if (!item || item.disabled) return
        if (r.id === "install") page.action("install", item.id)
        else if (r.id === "cache") page.action("cache", Number(item.id) * 1024)
        else if (r.id === "channel") page.action("channel", item.id)
        else if (r.id === "auto") page.action("auto", item.id === "on")
        else if (r.id === "update") page.action(item.id, null)
        else if (r.id === "sounds") page.action("sounds", item.id === "on")
        else if (r.id === "trailers") page.action("trailers", item.id === "on")
    }
    function handle(a) {
        const r = rows[Math.min(row, rows.length - 1)]
        const n = itemsOf(r).length
        if (a === "up") row = Math.max(0, row - 1)
        else if (a === "down") row = Math.min(rows.length - 1, row + 1)
        else if (a === "left") setCol(r.id, Math.max(0, colOf(r.id) - 1))
        else if (a === "right") setCol(r.id, Math.min(n - 1, colOf(r.id) + 1))
        else if (a === "a") activate(r, colOf(r.id))
        else if (a === "b" || a === "start") page.action("back", null)
    }
    function focused(id, i) { return rows[row] && rows[row].id === id && colOf(id) === i }
    // Mouse: no automatic scrolling (the content would move under the pointer).
    property bool fromMouse: false
    function click(id, i) { fromMouse = true; row = rowIndex(id); fromMouse = false; setCol(id, i); activate(rows[row], i) }

    onRowChanged: {
        if (fromMouse) return
        const target = { install: secGames, cache: cacheRow, channel: secUpdates, auto: autoRow, update: updateRow, sounds: secUi, trailers: trailersRow }[rows[row].id]
        if (!target) return
        const y = target.mapToItem(content, 0, 0).y
        scrollAnim.to = Math.max(0, Math.min(body.contentHeight - body.height, y - body.height / 3))
        scrollAnim.restart()
    }
    NumberAnimation { id: scrollAnim; target: body; property: "contentY"; duration: 200; easing.type: Easing.OutQuart }

    Rectangle { anchors.fill: parent; color: theme.bg }
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

    // ---------- header ----------
    Rectangle {
        x: 48; y: 28
        width: backRow.implicitWidth + 28; height: 40
        radius: 20
        color: backMouse.containsMouse ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.16) : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.08)
        Row {
            id: backRow
            anchors.centerIn: parent
            spacing: 10
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 22; height: 22; radius: 11; color: theme.fg
                Text { anchors.centerIn: parent; text: "B"; color: theme.bg; font { family: theme.fontFamily; pixelSize: 11; weight: Font.Bold } }
            }
            Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Back"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium } }
        }
        MouseArea { id: backMouse; anchors.fill: parent; hoverEnabled: page.pointerActive; cursorShape: Qt.PointingHandCursor; onClicked: page.action("back", null) }
    }

    Flickable {
        id: body
        anchors { fill: parent; topMargin: 92; bottomMargin: 24 }
        contentHeight: content.height + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: content
            x: Math.max(72, (body.width - 1000) / 2)
            width: Math.min(1000, body.width - 144)
            spacing: 14

            Text { text: qsTr("Settings"); color: theme.fg; font { family: theme.displayFont; pixelSize: Math.round(theme.titleSize * 1.4); weight: Font.Bold } }
            Item { width: 1; height: 8 }

            // ---------- Games ----------
            Text { id: secGames; text: qsTr("Games"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold } }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: qsTr("What a game page offers first. Both stay available on every game page.")
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 14 }
            }
            Row {
                width: parent.width
                spacing: 18
                Repeater {
                    model: [
                        { id: "download", title: qsTr("Download to this device"),
                          pros: [qsTr("Plays offline, even if the server is off"), qsTr("Fastest loading"), qsTr("Nothing to wait for once installed")],
                          cons: [qsTr("Uses disk space for every game"), qsTr("Wait for the download before playing")] },
                        { id: "stream", title: qsTr("Play from the network"),
                          pros: [qsTr("Uses almost no disk space (bounded cache)"), qsTr("Play almost right away"), qsTr("Only the games you pick are mounted, with your RomM rights")],
                          cons: [qsTr("Needs the network and the RomM server"), qsTr("Loading depends on the network: wired or 5 GHz Wi-Fi for large games"), qsTr("Linux only")] }
                    ]
                    OptionCard {
                        required property var modelData
                        required property int index
                        width: (parent.width - 18) / 2
                        theme: page.theme
                        title: modelData.title
                        pros: modelData.pros
                        cons: modelData.cons
                        selected: page.installMode === modelData.id
                        disabled: modelData.id === "stream" && !page.streamAvailable
                        note: modelData.id === "stream" && !page.streamAvailable && page.settings && page.settings.stream.error
                              ? qsTr("Unavailable here: %1").arg(page.settings.stream.error) : ""
                        focused: page.focused("install", index)
                        pointerActive: page.pointerActive
                        onClicked: page.click("install", index)
                    }
                }
            }
            Item { width: 1; height: 4 }
            SettingRow {
                id: cacheRow
                width: parent.width
                theme: page.theme
                title: qsTr("Network cache")
                description: qsTr("Space kept on this device for games played from the network; the oldest blocks are removed first.")
                items: page.rows[page.rowIndex("cache")].items
                selected: page.rows[page.rowIndex("cache")].selected
                focusIndex: page.rows[page.row].id === "cache" ? page.colOf("cache") : -1
                pointerActive: page.pointerActive
                onClicked: (i) => page.click("cache", i)
            }

            Item { width: 1; height: 18 }
            // ---------- Updates ----------
            Text { id: secUpdates; text: qsTr("Updates"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold } }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.upd ? qsTr("Installed: version %1 (build %2)").arg(page.upd.current.version).arg(page.upd.current.build) : ""
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 14 }
            }
            Text {
                visible: !!page.upd && !!page.upd.unsupported
                width: parent.width
                wrapMode: Text.WordWrap
                text: page.upd && page.upd.unsupported ? qsTr("Automatic updates are not available for this copy: %1").arg(page.upd.unsupported) : ""
                color: theme.bad
                font { family: theme.fontFamily; pixelSize: 14 }
            }
            SettingRow {
                width: parent.width
                theme: page.theme
                title: qsTr("Channel")
                description: qsTr("Stable: published versions. Development: every change, as soon as it is built (may contain bugs).")
                items: page.rows[page.rowIndex("channel")].items
                selected: page.rows[page.rowIndex("channel")].selected
                focusIndex: page.rows[page.row].id === "channel" ? page.colOf("channel") : -1
                pointerActive: page.pointerActive
                onClicked: (i) => page.click("channel", i)
            }
            SettingRow {
                id: autoRow
                width: parent.width
                theme: page.theme
                title: qsTr("Check automatically")
                description: qsTr("At startup and every 6 hours. Nothing is installed without your go-ahead.")
                items: page.rows[page.rowIndex("auto")].items
                selected: page.rows[page.rowIndex("auto")].selected
                focusIndex: page.rows[page.row].id === "auto" ? page.colOf("auto") : -1
                pointerActive: page.pointerActive
                onClicked: (i) => page.click("auto", i)
            }
            Column {
                id: updateRow
                width: parent.width
                spacing: 10
                visible: page.updateButtons.length > 0
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: text !== ""
                    text: {
                        const s = page.updState
                        if (!s) return ""
                        if (s.state === "uptodate") return qsTr("Borne is up to date.")
                        if (s.state === "error") return qsTr("Update failed: %1").arg(s.error || "")
                        if ((s.state === "available" || s.state === "ready") && s.available)
                            return qsTr("Version %1 (build %2): %3").arg(s.available.version).arg(s.available.build).arg(s.available.notes || "")
                        return ""
                    }
                    color: page.updState && page.updState.state === "error" ? theme.bad : theme.fg
                    font { family: theme.fontFamily; pixelSize: 14 }
                }
                Rectangle {
                    visible: page.updState !== null && page.updState.state === "downloading"
                    width: Math.min(parent.width, 520); height: 6; radius: 3
                    color: Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.15)
                    Rectangle {
                        height: parent.height; radius: 3; color: theme.accent
                        width: parent.width * (page.updState && page.updState.total > 0 ? Math.min(1, page.updState.received / page.updState.total) : 0)
                    }
                }
                Row {
                    spacing: 14
                    Repeater {
                        model: page.updateButtons
                        PageButton {
                            required property var modelData
                            required property int index
                            theme: page.theme
                            text: modelData.label
                            primary: !!modelData.primary
                            disabled: !!modelData.disabled
                            focused: page.focused("update", index)
                            pointerActive: page.pointerActive
                            onClicked: page.click("update", index)
                        }
                    }
                }
            }

            Item { width: 1; height: 18 }
            // ---------- Interface ----------
            Text { id: secUi; text: qsTr("Interface"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 21; weight: Font.DemiBold } }
            SettingRow {
                width: parent.width
                theme: page.theme
                title: qsTr("Interface sounds")
                description: qsTr("Short sounds when moving and choosing; each theme has its own.")
                items: page.rows[page.rowIndex("sounds")].items
                selected: page.rows[page.rowIndex("sounds")].selected
                focusIndex: page.rows[page.row].id === "sounds" ? page.colOf("sounds") : -1
                pointerActive: page.pointerActive
                onClicked: (i) => page.click("sounds", i)
            }
            SettingRow {
                id: trailersRow
                width: parent.width
                theme: page.theme
                title: qsTr("Trailers")
                description: qsTr("Video behind the selected game, muted, after a short pause.")
                items: page.rows[page.rowIndex("trailers")].items
                selected: page.rows[page.rowIndex("trailers")].selected
                focusIndex: page.rows[page.row].id === "trailers" ? page.colOf("trailers") : -1
                pointerActive: page.pointerActive
                onClicked: (i) => page.click("trailers", i)
            }
        }
    }
}
