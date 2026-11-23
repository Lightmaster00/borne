// The Downloads page: a glass panel beside the rail, like a folder of the home. The downloads in
// progress first, then the finished ones; each with its cover, its console, its progress (percent,
// speed) and its buttons (pause / resume / retry, cancel). X clears the finished ones.
// Gamepad: up/down between downloads, left/right between a row's buttons, A to press, B to close.
// The buttons' hints are shown by the app's foot bar (hints).
import QtQuick
import "CoreText.js" as CoreText

Item {
    id: panel
    property QtObject theme
    property var downloads: []
    property var gameOf: function (romId) { return null }   // the library's row of a game, for its cover
    property real motion: 1
    property int index: 0              // in `ordered`
    property int pick: 0               // the button chosen in the row
    property bool shown: false
    signal act(var dl, string what)    // pause, resume, retry, cancel
    signal clear()

    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 320 * panel.motion } }

    function isActive(d) { return ["queued", "downloading", "verifying", "extracting", "paused", "failed"].indexOf(d.state) >= 0 }
    // In progress first (in their order), then the finished ones (the list comes most recent first).
    readonly property var ordered: downloads.filter(d => isActive(d)).concat(downloads.filter(d => !isActive(d)))
    readonly property int activeCount: downloads.filter(d => isActive(d)).length
    readonly property bool finishedAny: activeCount < downloads.length

    // Speed: bytes per second of each download, from the last two refreshes (smoothed).
    property var speeds: ({})
    property var lastSeen: ({})
    onDownloadsChanged: {
        const now = Date.now(), seen = {}, sp = {}
        for (const d of downloads) {
            const prev = lastSeen[d.id]
            if (d.state === "downloading" && prev && now > prev.t && d.received >= prev.r) {
                const v = (d.received - prev.r) * 1000 / (now - prev.t)
                sp[d.id] = speeds[d.id] !== undefined ? speeds[d.id] * 0.6 + v * 0.4 : v
            }
            seen[d.id] = { r: d.received, t: now }
        }
        lastSeen = seen; speeds = sp
        if (index >= ordered.length) index = Math.max(0, ordered.length - 1)
        pick = Math.min(pick, Math.max(0, buttonsOf(ordered[index]).length - 1))
    }
    readonly property real totalSpeed: Object.keys(speeds).reduce((a, k) => a + speeds[k], 0)

    function fmt(b) {
        return b > 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
                              : qsTr("%1 MB").arg(Number(b / 1048576).toLocaleString(Qt.locale(), "f", 1))
    }
    function fmtSpeed(v) { return v > 0 ? qsTr("%1/s").arg(fmt(v)) : "" }
    function stateLabel(d) {
        return ({ queued: qsTr("Queued"), downloading: qsTr("Downloading"), verifying: qsTr("Verifying"), extracting: qsTr("Extracting"),
                  paused: qsTr("Paused"), done: qsTr("Installed"), failed: qsTr("Failed"), cancelled: qsTr("Cancelled") })[d.state] || d.state
    }
    function fraction(d) {
        if (d.state === "done") return 1
        return d.total > 0 ? Math.min(1, d.received / d.total) : 0
    }
    function buttonsOf(d) {
        if (!d) return []
        if (["queued", "downloading", "verifying", "extracting"].indexOf(d.state) >= 0)
            return [{ id: "pause", label: qsTr("Pause") }, { id: "cancel", label: qsTr("Cancel") }]
        if (d.state === "paused") return [{ id: "resume", label: qsTr("Resume") }, { id: "cancel", label: qsTr("Cancel") }]
        if (d.state === "failed") return [{ id: "retry", label: qsTr("Retry") }, { id: "cancel", label: qsTr("Cancel") }]
        return []
    }
    readonly property var hints: {
        const h = []
        const b = buttonsOf(ordered[index])
        if (b.length) h.push(["A", b[Math.min(pick, b.length - 1)].label, "a"])
        if (b.length > 1) h.push(["◀ ▶", qsTr("Choose"), "right"])
        if (finishedAny) h.push(["X", qsTr("Clear finished"), "x"])
        h.push(["B", qsTr("Back"), "b"])
        return h
    }
    function open() { index = 0; pick = 0; shown = true }
    function close() { shown = false }
    function handle(a) {
        const n = ordered.length
        if (a === "b" || a === "start") { close(); return "back" }
        if (a === "x") { if (finishedAny) clear(); return }
        if (a === "up") { if (index > 0) { index--; pick = 0; return "move" } }
        else if (a === "down") { if (index < n - 1) { index++; pick = 0; return "move" } }
        else if (a === "left") { if (pick > 0) { pick--; return "move" } }
        else if (a === "right") { if (pick < buttonsOf(ordered[index]).length - 1) { pick++; return "move" } }
        else if (a === "a") {
            const d = ordered[index], b = buttonsOf(d)[pick]
            if (d && b) act(d, b.id)
        }
    }

    // The room behind the panel, darkened like a folder's.
    Rectangle {
        parent: panel.parent
        anchors.fill: parent
        z: panel.z - 0.01
        color: Qt.rgba(0.024, 0.024, 0.04, 0.55)
        opacity: panel.opacity
        visible: opacity > 0
    }

    Rectangle {
        id: box
        anchors.fill: parent
        radius: 28
        color: Qt.rgba(0.12, 0.12, 0.15, 0.86)
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.14) }
        scale: panel.shown ? 1 : 0.94
        Behavior on scale { NumberAnimation { duration: 500 * panel.motion; easing.type: Easing.OutCubic } }
        clip: true

        // A soft light from the top, the colour of the work going on.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 260; radius: 28
            opacity: panel.activeCount ? 0.5 : 0.2
            Behavior on opacity { NumberAnimation { duration: 600 } }
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0.35, 0.55, 1, 0.22) }
                GradientStop { position: 1; color: "transparent" }
            }
        }

        // The title, what is going on, the count.
        Item {
            id: head
            x: 48; y: 34
            width: parent.width - 96; height: 62
            Row {
                spacing: 18
                Text {
                    id: title
                    text: qsTr("Downloads")
                    color: theme.fg
                    font { family: theme.displayFont; pixelSize: 36; weight: Font.ExtraBold; letterSpacing: -0.7 }
                }
                Rectangle { visible: sub.text !== ""; anchors.verticalCenter: title.verticalCenter; width: 2; height: 28; color: Qt.rgba(1, 1, 1, 0.3) }
                Text {
                    id: sub
                    anchors.baseline: title.baseline
                    text: panel.activeCount ? qsTr("%n in progress", "", panel.activeCount) + (panel.totalSpeed > 0 ? "  ·  " + panel.fmtSpeed(panel.totalSpeed) : "") : ""
                    color: Qt.rgba(1, 1, 1, 0.85)
                    font { family: theme.fontFamily; pixelSize: 22; weight: Font.Bold }
                }
            }
            Text {
                anchors { right: parent.right; top: parent.top; topMargin: 14 }
                text: panel.downloads.length ? qsTr("%n download(s)", "", panel.downloads.length) : ""
                color: Qt.rgba(1, 1, 1, 0.6)
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1.5; color: Qt.rgba(1, 1, 1, 0.18) }
        }

        // Nothing yet.
        Column {
            visible: panel.downloads.length === 0
            anchors.centerIn: parent
            spacing: 18
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 96; height: 96; radius: 48
                color: Qt.rgba(1, 1, 1, 0.06); border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
                Icon { anchors.centerIn: parent; name: "download"; size: 42; color: Qt.rgba(1, 1, 1, 0.7) }
            }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("No downloads"); color: theme.fg; font { family: theme.displayFont; pixelSize: 28; weight: Font.Bold } }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("The games you install from the Store appear here."); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 19 } }
        }

        Flickable {
            id: list
            x: 30; y: 116
            width: parent.width - 60
            height: parent.height - y - 24
            contentHeight: rowsCol.height + 24
            clip: true
            interactive: false
            Behavior on contentY { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            function ensure() {
                const it = rep.itemAt(panel.index)
                if (!it) { contentY = 0; return }
                const top = it.y - (it.headed ? 56 : 12), bottom = it.y + it.height + 12
                if (top < contentY) contentY = Math.max(0, top)
                else if (bottom > contentY + height) contentY = Math.min(Math.max(0, contentHeight - height), bottom - height)
            }
            Connections { target: panel; function onIndexChanged() { list.ensure() } function onShownChanged() { list.contentY = 0 } }
            Column {
                id: rowsCol
                y: 12
                width: parent.width
                spacing: 10
                Repeater {
                    id: rep
                    model: panel.ordered
                    Item {
                        id: rowItem
                        required property var modelData
                        required property int index
                        readonly property bool cur: index === panel.index && panel.shown
                        readonly property bool active: panel.isActive(modelData)
                        // The first of its kind carries the section's name above it.
                        readonly property bool headed: index === 0 || active !== panel.isActive(panel.ordered[index - 1])
                        readonly property var game: panel.gameOf(modelData.rom_id)
                        readonly property var buttons: panel.buttonsOf(modelData)
                        width: rowsCol.width
                        height: card.height + (headed ? 46 : 0)

                        Text {
                            visible: rowItem.headed
                            x: 18; y: 6
                            text: rowItem.active ? qsTr("In progress") : qsTr("Finished")
                            color: Qt.rgba(1, 1, 1, 0.55)
                            font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
                        }

                        Rectangle {
                            id: card
                            y: rowItem.headed ? 46 : 0
                            width: parent.width; height: 120
                            radius: 20
                            color: rowItem.cur ? Qt.rgba(1, 1, 1, 0.1) : Qt.rgba(1, 1, 1, rowItem.active ? 0.035 : 0)
                            border { width: rowItem.cur ? 2 : 0; color: Qt.rgba(1, 1, 1, 0.55) }
                            Behavior on color { ColorAnimation { duration: 160 } }

                            // The cover.
                            Rectangle {
                                id: thumb
                                x: 18; anchors.verticalCenter: parent.verticalCenter
                                width: 64; height: 88; radius: 8
                                color: Qt.hsla(((rowItem.modelData.rom_id * 47) % 360) / 360, 0.3, 0.25, 1)
                                clip: true
                                opacity: rowItem.active || rowItem.modelData.state === "done" ? 1 : 0.5
                                Image {
                                    anchors.fill: parent
                                    source: rowItem.game && rowItem.game.cover ? rowItem.game.cover : ""
                                    sourceSize.height: 176
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                                // Installed: a tick on the cover.
                                Rectangle {
                                    visible: rowItem.modelData.state === "done"
                                    anchors { right: parent.right; bottom: parent.bottom; margins: 5 }
                                    width: 24; height: 24; radius: 12; color: "#5FD38D"
                                    Text { anchors.centerIn: parent; text: "✓"; color: "white"; font { pixelSize: 15; weight: Font.Black } }
                                }
                            }

                            Column {
                                anchors { left: thumb.right; leftMargin: 22; right: btns.left; rightMargin: 24; verticalCenter: parent.verticalCenter }
                                spacing: 9
                                Item {
                                    width: parent.width; height: nameText.height
                                    Text {
                                        id: nameText
                                        width: parent.width - stateText.implicitWidth - 20
                                        text: rowItem.modelData.name
                                        elide: Text.ElideRight
                                        color: theme.fg
                                        font { family: theme.fontFamily; pixelSize: 21; weight: Font.Bold }
                                    }
                                    Text {
                                        id: stateText
                                        anchors { right: parent.right; baseline: nameText.baseline }
                                        text: {
                                            const d = rowItem.modelData
                                            if (d.state === "downloading" && d.total > 0)
                                                return Math.round(panel.fraction(d) * 100) + " %"
                                            return panel.stateLabel(d)
                                        }
                                        color: rowItem.modelData.state === "failed" ? theme.bad : rowItem.modelData.state === "done" ? "#5FD38D" : Qt.rgba(1, 1, 1, 0.8)
                                        font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
                                    }
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: {
                                        const d = rowItem.modelData, g = rowItem.game, bits = []
                                        if (g && g.platform_short) bits.push(g.platform_short)
                                        if (d.state === "failed") bits.push(CoreText.tr(d.error || ""))
                                        else if (d.total > 0 && (d.state === "downloading" || d.state === "paused" || d.state === "queued")) bits.push(panel.fmt(d.received) + " / " + panel.fmt(d.total))
                                        else if (d.total > 0) bits.push(panel.fmt(d.total))
                                        if (d.state === "downloading" && panel.speeds[d.id] > 0) {
                                            bits.push(panel.fmtSpeed(panel.speeds[d.id]))
                                            const left = (d.total - d.received) / panel.speeds[d.id]
                                            if (d.total > 0 && left > 0 && left < 360000)
                                                bits.push(left < 60 ? qsTr("%n s left", "", Math.ceil(left)) : left < 3600 ? qsTr("%n min left", "", Math.ceil(left / 60)) : qsTr("%n h left", "", Math.floor(left / 3600)))
                                        }
                                        return bits.join("  ·  ")
                                    }
                                    color: rowItem.modelData.state === "failed" ? theme.bad : theme.fgMuted
                                    font { family: theme.fontFamily; pixelSize: 17; weight: Font.Medium }
                                }
                                // The progress: a bar that glows while it moves.
                                Rectangle {
                                    visible: rowItem.active && rowItem.modelData.state !== "failed"
                                    width: parent.width; height: 6; radius: 3; color: Qt.rgba(1, 1, 1, 0.12)
                                    Rectangle {
                                        id: fill
                                        height: parent.height; radius: 3
                                        width: Math.max(height, parent.width * panel.fraction(rowItem.modelData))
                                        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                        color: rowItem.modelData.state === "paused" ? Qt.rgba(1, 1, 1, 0.4) : "white"
                                        // Verifying / extracting / queued: a light running along the bar.
                                        Rectangle {
                                            readonly property bool running: ["downloading", "verifying", "extracting", "queued"].indexOf(rowItem.modelData.state) >= 0
                                            visible: running && panel.shown
                                            width: 80; height: parent.height; radius: 3
                                            gradient: Gradient { orientation: Gradient.Horizontal
                                                GradientStop { position: 0; color: "transparent" }
                                                GradientStop { position: 0.5; color: Qt.rgba(0.6, 0.8, 1, 0.9) }
                                                GradientStop { position: 1; color: "transparent" } }
                                            NumberAnimation on x { running: parent.visible; from: -80; to: Math.max(0, fill.width); duration: 1400; loops: Animation.Infinite }
                                        }
                                    }
                                }
                            }

                            Row {
                                id: btns
                                anchors { right: parent.right; rightMargin: 22; verticalCenter: parent.verticalCenter }
                                spacing: 10
                                Repeater {
                                    model: rowItem.buttons
                                    PageButton {
                                        required property var modelData
                                        required property int index
                                        implicitHeight: 48
                                        theme: panel.theme
                                        text: modelData.label
                                        primary: index === 0
                                        focused: rowItem.cur && panel.pick === index
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
