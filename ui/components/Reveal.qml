// What it holds fades in and slides into place each time `key` changes (another game, another
// console selected): the change reads as a movement, not a flicker.
import QtQuick

Item {
    id: rv
    property var key
    property real motion: 1
    property real dx: 0
    property real dy: 16
    implicitWidth: childrenRect.width
    implicitHeight: childrenRect.height
    onKeyChanged: if (motion > 0.5) anim.restart()
    transform: Translate { id: tr }
    SequentialAnimation {
        id: anim
        PropertyAction { target: rv; property: "opacity"; value: 0 }
        PropertyAction { target: tr; property: "x"; value: rv.dx }
        PropertyAction { target: tr; property: "y"; value: rv.dy }
        ParallelAnimation {
            NumberAnimation { target: rv; property: "opacity"; to: 1; duration: 380; easing.type: Easing.OutQuad }
            NumberAnimation { target: tr; property: "x"; to: 0; duration: 560; easing.type: Easing.OutCubic }
            NumberAnimation { target: tr; property: "y"; to: 0; duration: 560; easing.type: Easing.OutCubic }
        }
    }
}
