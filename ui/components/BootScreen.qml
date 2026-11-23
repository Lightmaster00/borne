// What Borne shows while it starts. The same dark room as the rest of the app, its logo in the
// middle with a hairline of light under it, and one quiet line saying what is going on (or what
// went wrong). When the profiles come next, the logo glides up to the place it holds on that
// screen and the rest fades, so the start runs on into the first screen without a cut.
// progress < 0: no measure (the light runs along the line); 0..1: the line fills.
import QtQuick

Item {
    id: boot
    property QtObject theme
    property bool shown: true
    property string message: ""
    property bool failed: false
    property real progress: -1
    property real motion: 1
    // The screen that follows has the logo at its top (the profiles).
    property bool toTop: false

    // Shown at least a moment, so a quick start doesn't flash it.
    property bool held: true
    Timer { running: true; interval: 1100; onTriggered: boot.held = false }
    readonly property bool on: shown || held
    // Leaving: the logo moves first, the room goes after it.
    opacity: on ? 1 : 0
    visible: opacity > 0
    Behavior on opacity {
        SequentialAnimation {
            // To the profiles: the room stays until the logo has reached its place.
            PauseAnimation { duration: boot.toTop && !boot.on ? 500 * boot.motion : 0 }
            NumberAnimation { duration: (boot.toTop ? 320 : 520) * boot.motion; easing.type: Easing.InOutQuad }
        }
    }

    // ---------- the room: Ambience's ground, lit softly from above ----------
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0.040, 0.042, 0.052, 1) }
            GradientStop { position: 1.0; color: Qt.rgba(0.016, 0.017, 0.022, 1) }
        }
        // A wide pool of light where the logo stands, barely there.
        Rectangle {
            readonly property real d: Math.max(boot.width, boot.height) * 1.1
            width: d; height: d * 0.62; radius: height / 2
            anchors.horizontalCenter: parent.horizontalCenter
            y: boot.height * 0.46 - height / 2
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 0.5; color: boot.failed ? Qt.rgba(1, 0.4, 0.35, 0.06) : Qt.rgba(1, 0.97, 0.92, 0.045) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    // ---------- the logo: centred, then at the profiles' place ----------
    readonly property real topY: height < 900 ? 48 : 80
    Brand {
        id: logo
        size: 52
        anchors.horizontalCenter: parent.horizontalCenter
        transformOrigin: Item.Top
        // Its place on the profiles screen, or the middle of this one.
        y: boot.on || !boot.toTop ? boot.height * 0.46 - height * scale / 2 - 18 : boot.topY
        scale: boot.on || !boot.toTop ? 1.35 : 1
        opacity: 0
        Component.onCompleted: opacity = 1
        Behavior on opacity { NumberAnimation { duration: 900 * boot.motion; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 520 * boot.motion; easing.type: Easing.InOutCubic } }
        Behavior on scale { NumberAnimation { duration: 520 * boot.motion; easing.type: Easing.InOutCubic } }
    }

    // ---------- the hairline and the line of text ----------
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: logo.y + logo.height * logo.scale + 34
        spacing: 22
        opacity: boot.on ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 240 * boot.motion } }

        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 180; height: 1
            visible: !boot.failed
            Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.09) }
            Rectangle {
                visible: boot.progress >= 0
                height: parent.height; color: Qt.rgba(1, 1, 1, 0.7)
                width: parent.width * Math.max(0, Math.min(1, boot.progress))
                Behavior on width { NumberAnimation { duration: 300 } }
            }
            Item {
                anchors.fill: parent
                clip: true
                visible: boot.progress < 0
                Rectangle {
                    id: runner
                    width: parent.width * 0.4; height: parent.height
                    gradient: Gradient { orientation: Gradient.Horizontal
                        GradientStop { position: 0; color: "transparent" }
                        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.75) }
                        GradientStop { position: 1; color: "transparent" } }
                    NumberAnimation on x {
                        running: boot.visible && boot.progress < 0
                        from: -runner.width; to: runner.parent.width
                        duration: 1600; loops: Animation.Infinite; easing.type: Easing.InOutSine
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
            color: boot.failed ? boot.theme.bad : Qt.rgba(1, 1, 1, 0.42)
            font { family: boot.theme.fontFamily; pixelSize: boot.failed ? 20 : 16; weight: Font.Medium; letterSpacing: 0.2 }
        }
    }
}
