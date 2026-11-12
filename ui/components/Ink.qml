// Borne's touch of cel shading: a hard shadow in ink, unblurred, offset down and to the right,
// behind a shape (buttons, chips, cards, panels, toasts). As the 3D cases' ink outline, it gives
// every element the same drawn edge. Put it inside the shape with z: -1, or just before it.
import QtQuick

Rectangle {
    property QtObject theme
    readonly property real offset: theme ? theme.inkOffset : 4
    anchors {
        fill: parent
        leftMargin: offset; topMargin: offset
        rightMargin: -offset; bottomMargin: -offset
    }
    color: theme ? theme.ink : "#05060A"
    opacity: 0.8
}
