// Gamepad-driven on-screen keyboard (RomM server address, profile names).
// D-pad: move · A: key · B: erase · X: shift · Y: space · Start: confirm.
// A physical keyboard works too (see typeText / Main.qml).
// Letter layout follows the system language: AZERTY for French, QWERTY otherwise.
import QtQuick

Item {
    id: kb
    property QtObject theme
    property string text: ""
    property string placeholder: ""
    property int maxLength: 200
    property bool shift: false
    property int row: 1
    property int col: 0
    signal accepted(string text)
    signal cancelled()

    readonly property bool azerty: Qt.locale().name.startsWith("fr")
    readonly property var letters: [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ...(azerty ? [["a", "z", "e", "r", "t", "y", "u", "i", "o", "p"],
                      ["q", "s", "d", "f", "g", "h", "j", "k", "l", "m"],
                      ["w", "x", "c", "v", "b", "n", ".", ":", "/", "-"]]
                   : [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                      ["a", "s", "d", "f", "g", "h", "j", "k", "l", "-"],
                      ["z", "x", "c", "v", "b", "n", "m", ".", ":", "/"]]),
        ["_", "@", "?", "=", "&", "%", "#", "~", "é", "è"],
        [qsTr("⇧ Shift"), qsTr("Space"), qsTr("⌫ Erase"), qsTr("Confirm ✓")]
    ]
    readonly property int keyW: 64
    readonly property int keyH: 54
    readonly property int gap: 8

    implicitWidth: 10 * keyW + 9 * gap
    implicitHeight: field.height + 24 + 6 * keyH + 5 * gap

    function label(r, c) {
        const k = letters[r][c]
        return (r < 5 && shift) ? k.toUpperCase() : k
    }
    function typeText(t) {
        if (text.length + t.length <= maxLength) text += t
    }
    function backspace() { text = text.slice(0, -1) }
    function press() {
        if (row === 5) {
            if (col === 0) shift = !shift
            else if (col === 1) typeText(" ")
            else if (col === 2) backspace()
            else accepted(text)
            return
        }
        typeText(label(row, col))
        if (shift) shift = false
    }
    function handle(a) {
        const n = letters[row].length
        if (a === "left") col = (col - 1 + n) % n
        else if (a === "right") col = (col + 1) % n
        else if (a === "up" || a === "down") {
            const next = a === "up" ? Math.max(0, row - 1) : Math.min(5, row + 1)
            // Keep the horizontal position between the action row (4 keys) and the others (10).
            const ratio = (col + 0.5) / letters[row].length
            row = next
            col = Math.min(letters[row].length - 1, Math.floor(ratio * letters[row].length))
        }
        else if (a === "a") press()
        else if (a === "b") { if (text.length) backspace(); else cancelled() }
        else if (a === "x") shift = !shift
        else if (a === "y") typeText(" ")
        else if (a === "start") accepted(text)
        else if (a === "select") cancelled()
    }

    Rectangle {
        id: field
        width: parent.width; height: 56; radius: 10
        color: theme.bg2
        border { color: theme.accent; width: 2 }
        Text {
            id: fieldText
            anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
            text: kb.text.length ? kb.text : kb.placeholder
            color: kb.text.length ? theme.fg : theme.fgMuted
            elide: Text.ElideLeft
            font { family: theme.fontFamily; pixelSize: 22 }
        }
        Rectangle {
            visible: kb.text.length > 0
            x: Math.min(fieldText.x + fieldText.contentWidth + 2, parent.width - 14)
            anchors.verticalCenter: parent.verticalCenter
            width: 2; height: 28; color: theme.accent
            SequentialAnimation on opacity { loops: Animation.Infinite; NumberAnimation { to: 0; duration: 500 } NumberAnimation { to: 1; duration: 500 } }
        }
    }

    Column {
        y: field.height + 24
        spacing: kb.gap
        Repeater {
            model: kb.letters.length
            Row {
                id: keyRow
                required property int index
                readonly property int r: index
                spacing: kb.gap
                Repeater {
                    model: kb.letters[keyRow.r].length
                    Rectangle {
                        required property int index
                        readonly property bool cur: keyRow.r === kb.row && index === kb.col
                        readonly property bool wide: keyRow.r === 5
                        width: wide ? (kb.width - 3 * kb.gap) / 4 : kb.keyW
                        height: kb.keyH
                        radius: 8
                        color: cur ? theme.accent : (wide ? theme.bg2 : Qt.rgba(1, 1, 1, 0.06))
                        border { width: keyRow.r === 5 && index === 0 && kb.shift ? 2 : 0; color: theme.accent }
                        scale: cur ? 1.06 : 1
                        Behavior on scale { NumberAnimation { duration: 90 } }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { kb.row = keyRow.r; kb.col = parent.index; kb.press() }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: kb.label(keyRow.r, index)
                            color: parent.cur ? theme.accentFg : theme.fg
                            font { family: theme.fontFamily; pixelSize: parent.wide ? 16 : 22; bold: parent.cur }
                        }
                    }
                }
            }
        }
    }
}
