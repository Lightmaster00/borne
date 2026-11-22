// A button or key, as drawn everywhere in Borne (hints, buttons, the library's header): light,
// its letter dark; round for a single letter (A, B, X, Y), a rounded tag for the others (LB,
// Start, ← →).
import QtQuick

Rectangle {
    id: cap
    property QtObject theme
    property string text: ""
    property real size: 32
    property bool inverted: false     // dark on a light button
    readonly property bool round: text.length <= 1
    width: round ? size : label.implicitWidth + size * 0.62
    height: size
    radius: round ? size / 2 : size * 0.28
    color: inverted ? "#16161B" : Qt.rgba(0.96, 0.95, 0.93, 0.94)
    Text {
        id: label
        anchors.centerIn: parent
        text: cap.text
        color: cap.inverted ? "#F3F1EE" : "#16161B"
        font { family: cap.theme ? cap.theme.fontFamily : "Manrope"; pixelSize: Math.round(cap.size * (/[←→↑↓▲▼◀▶]/.test(cap.text) ? 0.56 : 0.44)); weight: Font.ExtraBold }
    }
}
