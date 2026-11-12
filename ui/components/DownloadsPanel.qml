// Download list: progress, errors, and per download a pause / resume / retry button and a cancel
// button; X (or the button at the top) clears the finished and cancelled ones.
// Gamepad: up/down between downloads (and the clear button), left/right between a row's buttons,
// A to press, X to clear, B to close.
import QtQuick
import "CoreText.js" as CoreText

Rectangle {
    id: panel
    property QtObject theme
    property var downloads: []
    property int index: 0              // -1: the clear button
    property int pick: 0          // the button chosen in the row
    signal act(var dl, string what)    // pause, resume, retry, cancel
    signal clear()

    visible: false
    anchors.fill: parent
    color: Qt.rgba(0.047, 0.051, 0.063, 0.6)

    readonly property bool finishedAny: downloads.some(d => d.state === "done" || d.state === "cancelled")
    readonly property int firstIndex: finishedAny ? -1 : 0
    onDownloadsChanged: {
        if (index >= downloads.length) index = downloads.length - 1
        if (index < firstIndex) index = firstIndex
        pick = Math.min(pick, Math.max(0, buttonsOf(downloads[index]).length - 1))
    }

    function fmt(b) {
        return b > 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
                              : qsTr("%1 MB").arg(Number(b / 1048576).toLocaleString(Qt.locale(), "f", 1))
    }
    function stateLabel(d) {
        return ({ queued: qsTr("Queued"), downloading: qsTr("Downloading"), verifying: qsTr("Verifying"), extracting: qsTr("Extracting"),
                  paused: qsTr("Paused"), done: qsTr("Installed"), failed: qsTr("Failed"), cancelled: qsTr("Cancelled") })[d.state] || d.state
    }
    function buttonsOf(d) {
        if (!d) return []
        if (["queued", "downloading", "verifying", "extracting"].indexOf(d.state) >= 0)
            return [{ id: "pause", label: qsTr("Pause") }, { id: "cancel", label: qsTr("Cancel") }]
        if (d.state === "paused") return [{ id: "resume", label: qsTr("Resume") }, { id: "cancel", label: qsTr("Cancel") }]
        if (d.state === "failed") return [{ id: "retry", label: qsTr("Retry") }, { id: "cancel", label: qsTr("Cancel") }]
        return []
    }
    function open() { index = downloads.length ? 0 : firstIndex; pick = 0; visible = true }
    function handle(a) {
        const n = downloads.length
        if (a === "b" || a === "start") { visible = false; return }
        if (a === "x") { if (finishedAny) clear(); return }
        if (a === "up") { index = Math.max(firstIndex, index - 1); pick = 0 }
        else if (a === "down") { index = Math.min(n - 1, index + 1); pick = 0 }
        else if (a === "left") pick = Math.max(0, pick - 1)
        else if (a === "right") pick = Math.min(Math.max(0, buttonsOf(downloads[index]).length - 1), pick + 1)
        else if (a === "a") {
            if (index === -1) { clear(); return }
            const d = downloads[index], b = buttonsOf(d)[pick]
            if (d && b) act(d, b.id)
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(1100, parent.width - 80)
        height: Math.min(parent.height - 80, col.height + 72)
        radius: 28; color: theme.panel; border.color: theme.panelBorder
        Ink { z: -1; theme: panel.theme; radius: 28 }
        clip: true
        Column {
            id: col
            x: 36; y: 36; width: parent.width - 72; spacing: 12
            Item {
                width: parent.width; height: 56
                Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Downloads"); color: theme.fg; font { family: theme.displayFont; pixelSize: 34; weight: Font.ExtraBold } }
                PageButton {
                    visible: panel.finishedAny
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    implicitHeight: 48
                    theme: panel.theme
                    text: qsTr("Clear finished")
                    focused: panel.index === -1
                }
            }
            Text { visible: panel.downloads.length === 0; text: qsTr("No recent downloads."); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 19 } }
            Repeater {
                model: panel.downloads
                Rectangle {
                    id: rowItem
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === panel.index
                    readonly property var buttons: panel.buttonsOf(modelData)
                    width: col.width; height: 92; radius: 16
                    color: cur ? theme.glass : "transparent"
                    Column {
                        x: 20; anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 40 - (btns.width > 0 ? btns.width + 24 : 0); spacing: 10
                        Row {
                            width: parent.width
                            Text { width: parent.width * 0.55; text: rowItem.modelData.name; elide: Text.ElideRight; color: theme.fg; font { family: theme.fontFamily; pixelSize: 20; weight: Font.DemiBold } }
                            Text {
                                width: parent.width * 0.45; horizontalAlignment: Text.AlignRight
                                text: panel.stateLabel(rowItem.modelData) + (rowItem.modelData.total > 0 && (rowItem.modelData.state === "downloading" || rowItem.modelData.state === "paused") ? " · " + panel.fmt(rowItem.modelData.received) + " / " + panel.fmt(rowItem.modelData.total) : "")
                                color: rowItem.modelData.state === "failed" ? theme.bad : theme.fgMuted
                                font { family: theme.fontFamily; pixelSize: 16 }
                            }
                        }
                        Rectangle {
                            visible: rowItem.modelData.state !== "failed"
                            width: parent.width; height: 4; radius: 2; color: Qt.rgba(1, 1, 1, 0.16)
                            Rectangle {
                                height: parent.height; radius: 2
                                color: rowItem.modelData.state === "paused" ? theme.fgMuted : theme.fg
                                width: parent.width * (rowItem.modelData.state === "done" ? 1 : rowItem.modelData.total > 0 ? Math.min(1, rowItem.modelData.received / rowItem.modelData.total) : 0)
                            }
                        }
                        Text { visible: rowItem.modelData.state === "failed"; width: parent.width; elide: Text.ElideRight; text: CoreText.tr(rowItem.modelData.error || ""); color: theme.bad; font { family: theme.fontFamily; pixelSize: 16 } }
                    }
                    Row {
                        id: btns
                        anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter }
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
            HintBar {
                theme: panel.theme
                hints: (panel.downloads.length ? [["A", qsTr("Choose"), "a"], ["◀ ▶", qsTr("Pause or cancel"), "right"]] : [])
                       .concat(panel.finishedAny ? [["X", qsTr("Clear finished"), "x"]] : []).concat([["B", qsTr("Close"), "b"]])
            }
        }
    }
}
