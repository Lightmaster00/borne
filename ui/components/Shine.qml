// A band of light crossing its parent once, when `active` turns on (a cover, a card or a folder
// just selected). Put it inside the parent's rounded mask so it follows its corners.
import QtQuick

Item {
    id: sh
    property bool active: false
    property real motion: 1
    property real strength: 0.3
    anchors.fill: parent
    Rectangle {
        id: band
        width: Math.max(60, sh.width * 0.45)
        height: sh.height * 2
        y: -sh.height * 0.5
        rotation: 18
        x: -width * 1.5
        opacity: 0
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
            GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, sh.strength) }
            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
        }
    }
    onActiveChanged: if (active && motion > 0.5) sweep.restart()
    SequentialAnimation {
        id: sweep
        PauseAnimation { duration: 120 }
        PropertyAction { target: band; property: "opacity"; value: 1 }
        NumberAnimation { target: band; property: "x"; from: -band.width * 1.5; to: sh.width + band.width * 0.5; duration: 900; easing.type: Easing.InOutQuad }
        PropertyAction { target: band; property: "opacity"; value: 0 }
    }
}
