// The light a selected cover casts round itself, in its console's colour, breathing slowly; and
// the selection's ring over it (a light line, its brightness breathing with it).
import QtQuick
import QtQuick.Effects

Item {
    id: fg
    property bool on: false
    property color tint: "#ffffff"
    property color ringColor: "#F3F1EE"
    property real radius: 14
    property real gap: 11          // between the cover and the ring
    property real line: 5
    property real motion: 1
    property bool ring: true
    anchors.fill: parent
    property real breath: 1
    readonly property real br: fg.on && fg.motion > 0.5 ? fg.breath : 1
    SequentialAnimation {
        loops: Animation.Infinite
        running: fg.on && fg.motion > 0.5
        NumberAnimation { target: fg; property: "breath"; from: 1; to: 0.7; duration: 1400; easing.type: Easing.InOutSine }
        NumberAnimation { target: fg; property: "breath"; from: 0.7; to: 1; duration: 1400; easing.type: Easing.InOutSine }
    }
    Rectangle {
        anchors { fill: parent; margins: -26 }
        radius: fg.radius + 26
        color: fg.tint
        opacity: fg.on ? 0.42 * fg.br : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 300 } }
        layer.enabled: visible
        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48 }
    }
    Rectangle {
        visible: fg.on && fg.ring
        anchors { fill: parent; margins: -fg.gap }
        radius: fg.radius + fg.gap
        color: "transparent"
        border { width: fg.line; color: fg.ringColor }
        opacity: 0.75 + 0.25 * fg.br
    }
}
