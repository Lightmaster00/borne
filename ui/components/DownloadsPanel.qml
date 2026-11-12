// Download list: progress, errors, cancellation.
import QtQuick

Rectangle {
    id: panel
    property QtObject theme
    property var downloads: []
    property int index: 0
    signal cancel(var dl)
    signal retry(var dl)
    property bool pointerActive: false

    visible: false
    anchors.fill: parent
    color: Qt.rgba(0.047, 0.051, 0.063, 0.6)

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

    MouseArea { anchors.fill: parent; onClicked: panel.visible = false; onWheel: (w) => w.accepted = true }
    Rectangle {
        anchors.centerIn: parent
        width: Math.min(1100, parent.width - 80)
        height: Math.min(parent.height - 80, col.height + 72)
        radius: 28; color: theme.panel; border.color: theme.panelBorder
        Ink { z: -1; theme: panel.theme; radius: 28 }
        clip: true
        MouseArea { anchors.fill: parent }
        Column {
            id: col
            x: 36; y: 36; width: parent.width - 72; spacing: 12
            Text { text: qsTr("Downloads"); color: theme.fg; font { family: theme.displayFont; pixelSize: 34; weight: Font.ExtraBold } }
            Text { visible: panel.downloads.length === 0; text: qsTr("No recent downloads."); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 19 } }
            Repeater {
                model: panel.downloads
                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool cur: index === panel.index
                    width: col.width; height: 84; radius: 16
                    color: cur ? theme.glass : "transparent"
                    border { width: cur ? 3 : 0; color: theme.focusRing }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { panel.index = parent.index; panel.handle("a") }
                    }
                    Column {
                        x: 20; anchors.verticalCenter: parent.verticalCenter; width: parent.width - 40; spacing: 10
                        Row {
                            width: parent.width
                            Text { width: parent.width * 0.6; text: modelData.name; elide: Text.ElideRight; color: theme.fg; font { family: theme.fontFamily; pixelSize: 20; weight: Font.DemiBold } }
                            Text {
                                width: parent.width * 0.4; horizontalAlignment: Text.AlignRight
                                text: panel.stateLabel(modelData) + (modelData.total > 0 && modelData.state === "downloading" ? " · " + panel.fmt(modelData.received) + " / " + panel.fmt(modelData.total) : "")
                                color: modelData.state === "failed" ? theme.bad : theme.fgMuted
                                font { family: theme.fontFamily; pixelSize: 16 }
                            }
                        }
                        Rectangle {
                            visible: modelData.state !== "failed"
                            width: parent.width; height: 4; radius: 2; color: Qt.rgba(1, 1, 1, 0.16)
                            Rectangle { height: parent.height; radius: 2; color: theme.fg; width: parent.width * (modelData.total > 0 ? Math.min(1, modelData.received / modelData.total) : 0) }
                        }
                        Text { visible: modelData.state === "failed"; width: parent.width; elide: Text.ElideRight; text: modelData.error || ""; color: theme.bad; font { family: theme.fontFamily; pixelSize: 16 } }
                    }
                }
            }
            HintBar {
                theme: panel.theme
                pointerActive: panel.pointerActive
                hints: [["A", qsTr("Cancel / retry"), "a"], ["B", qsTr("Close"), "b"]]
                onTriggered: (a) => panel.handle(a)
            }
        }
    }
}
