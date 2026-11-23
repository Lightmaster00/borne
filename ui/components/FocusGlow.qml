// The light a selected cover casts round itself, breathing slowly: its own colours (the picture,
// shrunk to a few pixels and blurred: an ambient light, not a picture) when `source` is given,
// else its console's colour; and the selection's ring over it (a light line, breathing with it).
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
    property string source: ""     // the cover: its colours light round it
    anchors.fill: parent
    property real breath: 1
    readonly property real br: fg.on && fg.motion > 0.5 ? fg.breath : 1
    SequentialAnimation {
        loops: Animation.Infinite
        running: fg.on && fg.motion > 0.5
        NumberAnimation { target: fg; property: "breath"; from: 1; to: 0.7; duration: 1400; easing.type: Easing.InOutSine }
        NumberAnimation { target: fg; property: "breath"; from: 0.7; to: 1; duration: 1400; easing.type: Easing.InOutSine }
    }
    Image {
        id: amb
        anchors { fill: parent; margins: -34 }
        source: fg.on ? fg.source : ""
        sourceSize: Qt.size(24, 24)
        fillMode: Image.Stretch
        smooth: true
        asynchronous: true
        opacity: fg.on && status === Image.Ready ? 0.75 * fg.br : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 400 } }
        layer.enabled: visible
        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 64; saturation: 0.4; brightness: 0.1 }
    }
    Rectangle {
        visible: amb.status !== Image.Ready && opacity > 0.01
        anchors { fill: parent; margins: -26 }
        radius: fg.radius + 26
        color: fg.tint
        opacity: fg.on ? 0.42 * fg.br : 0
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
