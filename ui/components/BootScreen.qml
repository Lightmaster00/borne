// What Borne shows while it starts: its logo in the dark, a soft light breathing behind it, a slim
// bar of light running under it and a line saying what is going on (or what went wrong).
// progress < 0: no measure (the bar runs); 0..1: the bar fills.
import QtQuick
import QtQuick.Shapes

Rectangle {
    id: boot
    property QtObject theme
    property bool shown: true
    property string message: ""
    property bool failed: false
    property real progress: -1
    property real motion: 1

    color: "#07080C"
    // Shown at least a moment, so a quick start doesn't flash it.
    property bool held: true
    Timer { running: true; interval: 1100; onTriggered: boot.held = false }
    opacity: shown || held ? 1 : 0
    visible: opacity > 0
    Behavior on opacity { NumberAnimation { duration: 600 * boot.motion; easing.type: Easing.InOutQuad } }

    // The light behind the logo.
    Shape {
        id: glow
        readonly property real r: Math.min(boot.width, boot.height) * 0.55
        width: r * 2; height: r * 2
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -40
        preferredRendererType: Shape.CurveRenderer
        SequentialAnimation on opacity {
            running: boot.visible && !boot.failed
            loops: Animation.Infinite
            NumberAnimation { to: 0.85; duration: 2400; easing.type: Easing.InOutSine }
            NumberAnimation { to: 0.5; duration: 2400; easing.type: Easing.InOutSine }
        }
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: glow.r; centerY: glow.r; focalX: glow.r; focalY: glow.r
                centerRadius: glow.r; focalRadius: 0
                GradientStop { position: 0; color: boot.failed ? Qt.rgba(1, 0.35, 0.35, 0.22) : Qt.rgba(0.36, 0.5, 1, 0.26) }
                GradientStop { position: 0.5; color: boot.failed ? Qt.rgba(1, 0.35, 0.35, 0.06) : Qt.rgba(0.5, 0.3, 0.9, 0.08) }
                GradientStop { position: 1; color: "transparent" }
            }
            PathRectangle { x: 0; y: 0; width: glow.width; height: glow.height }
        }
    }

    Column {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -20
        spacing: 46

        Brand {
            id: logo
            anchors.horizontalCenter: parent.horizontalCenter
            size: Math.round(Math.min(boot.height * 0.075, 84))
            opacity: 0
            scale: 0.96
            Component.onCompleted: { opacity = 1; scale = 1 }
            Behavior on opacity { NumberAnimation { duration: 900 * boot.motion; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 1200 * boot.motion; easing.type: Easing.OutCubic } }
        }

        // The bar: a thin line, a light running along it (or filling it).
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: logo.width * 0.55; height: 3
            visible: !boot.failed
            Rectangle { anchors.fill: parent; radius: 1.5; color: Qt.rgba(1, 1, 1, 0.1) }
            Rectangle {
                visible: boot.progress >= 0
                height: parent.height; radius: 1.5; color: "white"
                width: parent.width * Math.max(0, Math.min(1, boot.progress))
                Behavior on width { NumberAnimation { duration: 300 } }
            }
            Item {
                anchors.fill: parent
                clip: true
                visible: boot.progress < 0
                Rectangle {
                    id: runner
                    width: parent.width * 0.35; height: parent.height; radius: 1.5
                    gradient: Gradient { orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 0.5; color: "white" }
                        GradientStop { position: 1; color: "transparent" } }
                    NumberAnimation on x {
                        running: boot.visible && boot.progress < 0
                        from: -runner.width; to: runner.parent.width
                        duration: 1300; loops: Animation.Infinite; easing.type: Easing.InOutQuad
                    }
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(boot.width * 0.6, implicitWidth)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: boot.message
            color: boot.failed ? theme.bad : Qt.rgba(1, 1, 1, 0.5)
            font { family: theme.fontFamily; pixelSize: boot.failed ? 20 : 17; weight: Font.Medium; letterSpacing: 0.3 }
        }
    }
}
