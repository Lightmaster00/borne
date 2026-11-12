// Button hints at the bottom of a screen. hints: [[key, label, action, keyboard key?], …].
// The keycap follows the input in use (theme.input): the gamepad button, or with the keyboard
// the key that does the same action (the optional fourth item overrides it).
import QtQuick

Row {
    id: bar
    property QtObject theme
    property var hints: []
    spacing: 22
    readonly property bool keyboard: !!theme && theme.input === "keyboard"
    // Keys of each action (Main.qml's keyboard map).
    function keyOf(h) {
        if (!keyboard) return h[0]
        if (h.length > 3) return h[3]
        // Pairs (tabs, letters, rows, values) show both keys.
        const pairs = { lb: "Q · E", rb: "Q · E", lt: "R · C", rt: "R · C", up: "↑ ↓", down: "↑ ↓", left: "← →", right: "← →" }
        return pairs[h[2]] || theme.key(h[2])
    }

    Repeater {
        model: bar.hints
        Rectangle {
            id: hint
            required property var modelData
            required property int index
            readonly property string cap: bar.keyOf(modelData)
            readonly property string act: modelData[2] || ""
            readonly property bool round: cap.length === 1
            visible: cap !== ""   // "" as the keyboard key: nothing to press on a keyboard
            anchors.verticalCenter: parent.verticalCenter
            width: row.implicitWidth + 24
            height: 44
            radius: 22
            color: "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
            Row {
                id: row
                anchors.centerIn: parent
                spacing: 10
                // Keycaps in colour: A in the console's colour, B red, X yellow, Y blue, the others light.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: hint.round ? 32 : key.implicitWidth + 22
                    height: 32
                    radius: 16
                    readonly property string act: hint.act
                    color: act === "a" ? bar.theme.accent : act === "b" ? "#FF6B6B" : act === "x" ? "#FFD166" : act === "y" ? "#6FB7FF" : Qt.rgba(0.96, 0.95, 1, 0.92)
                    Ink { z: -1; theme: bar.theme; radius: 16; opacity: 0.9 }
                    Text {
                        id: key
                        anchors.centerIn: parent
                        text: hint.cap
                        color: parent.act === "a" ? bar.theme.accentFg : bar.theme.bg
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
        }
    }
}
