// Download list: progress, errors, cancellation.
import QtQuick

Rectangle {
    id: panel
    property QtObject theme
    property var downloads: []
    property int index: 0
    signal cancel(var dl)
    signal retry(var dl)

    visible: false
    anchors.fill: parent
    color: Qt.rgba(0, 0, 0, 0.6)

    function fmt(b) {
        return b > 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
                              : qsTr("%1 MB").arg(Number(b / 1048576).toLocaleString(Qt.locale(), "f", 1))
    }
    function stateLabel(d) {
        return ({ queued: qsTr("Queued"), downloading: qsTr("Downloading"), verifying: qsTr("Verifying"), extracting: qsTr("Extracting"),
                  done: qsTr("Installed"), failed: qsTr("Failed"), cancelled: qsTr("Cancelled") })[d.state] || d.state
    }
    function handle(a) {
        const n = downloads.length
        if (a === "up" && n) index = (index - 1 + n) % n
        else if (a === "down" && n) index = (index + 1) % n
        else if (a === "a" && n) {
            const d = downloads[index]
            if (d.state === "failed") retry(d)
            else if (d.state !== "done" && d.state !== "cancelled") cancel(d)
        }
        else if (a === "b" || a === "start") visible = false
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(820, parent.width - 80)
        height: Math.min(parent.height - 80, col.height + 56)
        radius: theme.radius + 4; color: theme.panel; border.color: theme.panelBorder
        clip: true
        Column {
            id: col
            x: 28; y: 28; width: parent.width - 56; spacing: 10
            Text { text: qsTr("Downloads"); color: theme.fg; font { family: theme.displayFont; pixelSize: 24; bold: true } }
            Text { visible: panel.downloads.length === 0; text: qsTr("No recent downloads."); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 15 } }
            Repeater {
                model: panel.downloads
                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === panel.index
                    width: col.width; height: 64; radius: 8
                    color: cur ? Qt.rgba(1, 1, 1, 0.08) : "transparent"
                    border { width: cur ? 2 : 0; color: theme.accent }
                    Column {
                        x: 14; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 28; spacing: 6
                        Row {
                            width: parent.width
                            Text { width: parent.width * 0.6; text: modelData.name; elide: Text.ElideRight; color: theme.fg; font { family: theme.fontFamily; pixelSize: 15; bold: true } }
                            Text {
                                width: parent.width * 0.4; horizontalAlignment: Text.AlignRight
                                text: panel.stateLabel(modelData) + (modelData.total > 0 && modelData.state === "downloading" ? " · " + panel.fmt(modelData.received) + " / " + panel.fmt(modelData.total) : "")
                                color: modelData.state === "failed" ? theme.bad : theme.fgMuted
                                font { family: theme.fontFamily; pixelSize: 13 }
                            }
                        }
                        Rectangle {
                            visible: modelData.state !== "failed"
                            width: parent.width; height: 6; radius: 3; color: Qt.rgba(1, 1, 1, 0.1)
                            Rectangle { height: parent.height; radius: 3; color: modelData.state === "done" ? theme.ok : theme.accent; width: parent.width * (modelData.total > 0 ? Math.min(1, modelData.received / modelData.total) : 0) }
                        }
                        Text { visible: modelData.state === "failed"; width: parent.width; elide: Text.ElideRight; text: modelData.error || ""; color: theme.bad; font { family: theme.fontFamily; pixelSize: 12 } }
                    }
                }
            }
            Text { text: qsTr("A  Cancel / retry      B  Close"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
        }
    }
}
