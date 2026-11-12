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
    spacing: 22

    Repeater {
        model: bar.hints
        Rectangle {
            id: hint
            required property var modelData
            required property int index
            readonly property bool round: modelData[0].length === 1
            anchors.verticalCenter: parent.verticalCenter
            width: row.implicitWidth + 24
            height: 44
            radius: 22
            color: mouse.containsMouse ? bar.theme.glass : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 10
                // Keycaps in colour: A in the console's colour, B red, X yellow, Y blue, the others light.
                Rectangle {
                    readonly property string k: hint.modelData[0]
                    anchors.verticalCenter: parent.verticalCenter
                    width: hint.round ? 32 : key.implicitWidth + 22
                    height: 32
                    radius: 16
                    color: k === "A" ? bar.theme.accent : k === "B" ? "#FF6B6B" : k === "X" ? "#FFD166" : k === "Y" ? "#6FB7FF" : Qt.rgba(0.96, 0.95, 1, 0.92)
                    Ink { z: -1; theme: bar.theme; radius: 16; opacity: 0.9 }
                    Text {
                        id: key
                        anchors.centerIn: parent
                        text: parent.k
                        color: parent.k === "A" ? bar.theme.accentFg : bar.theme.bg
                        font { family: bar.theme.displayFont; pixelSize: 15; weight: Font.Bold }
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: hint.modelData[1]
                    color: bar.theme.fgSoft
                    font { family: bar.theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
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
