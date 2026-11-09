// Button hints at the bottom of a screen. With the mouse, each hint is a button that does
// what the gamepad button would. hints: [[key, label, action], …]; the first key is the
// confirm button, drawn light.
import QtQuick

Row {
    id: bar
    property QtObject theme
    property var hints: []
    property bool pointerActive: false
    signal triggered(string action)
    spacing: 12

    Repeater {
        model: bar.hints
        Rectangle {
            id: hint
            required property var modelData
            required property int index
            readonly property bool round: modelData[0].length === 1
            anchors.verticalCenter: parent.verticalCenter
            width: row.implicitWidth + 24
            height: 40
            radius: 20
            color: mouse.containsMouse ? bar.theme.glass : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 10
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: hint.round ? 28 : key.implicitWidth + 18
                    height: 28
                    radius: hint.round ? 14 : 8
                    color: hint.modelData[0] === "A" ? bar.theme.fg : bar.theme.glassRaised
                    Text {
                        id: key
                        anchors.centerIn: parent
                        text: hint.modelData[0]
                        color: hint.modelData[0] === "A" ? bar.theme.bg : bar.theme.fg
                        font { family: bar.theme.fontFamily; pixelSize: 14; weight: Font.Bold }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: hint.modelData[1]
                    color: bar.theme.fgMuted
                    font { family: bar.theme.fontFamily; pixelSize: 16 }
                }
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
