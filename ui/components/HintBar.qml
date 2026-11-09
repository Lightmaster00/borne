// Button hints at the bottom of a screen. With the mouse, each hint is a button that does
// what the gamepad button would. hints: [[key, label, action], …]
import QtQuick

Row {
    id: bar
    property QtObject theme
    property var hints: []
    property bool pointerActive: false
    signal triggered(string action)
    spacing: 8

    Repeater {
        model: bar.hints
        Rectangle {
            id: hint
            required property var modelData
            anchors.verticalCenter: parent.verticalCenter
            width: row.implicitWidth + 20
            height: 36
            radius: 18
            color: mouse.containsMouse ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.12) : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 7
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(22, key.implicitWidth + 12); height: 22; radius: 11; color: theme.fg
                    Text { id: key; anchors.centerIn: parent; text: hint.modelData[0]; color: theme.bg; font { family: theme.fontFamily; pixelSize: 11; weight: Font.Bold } }
                }
                Text { anchors.verticalCenter: parent.verticalCenter; text: hint.modelData[1]; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14 } }
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: bar.pointerActive
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.triggered(hint.modelData[2])
            }
        }
    }
}
