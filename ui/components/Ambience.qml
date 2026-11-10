// Background: a dark, quiet stage. A soft light falls behind the selected game, faintly tinted
// with its color, and the edges sink into shadow. Nothing moves except that light, slowly.
import QtQuick
import QtQuick.Shapes

Item {
    id: amb
    property QtObject theme
    property var game: null
    property bool trailers: true      // kept for callers; the stage itself plays no video
    property bool paused: false
    property real dim: 0              // extra darkening for pages drawn over it
    property bool scrims: true
    property real lightY: height * 0.62
    property int framesDecoded: 0
    readonly property string cover: game && game.cover ? game.cover : ""

    // Base: charcoal, a touch lighter at the top.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#14161b" }
            GradientStop { position: 0.6; color: "#0c0d10" }
            GradientStop { position: 1.0; color: "#08090b" }
        }
    }

    // The light behind the selection, breathing very slowly.
    Shape {
        id: light
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        property real breathe: 1
        SequentialAnimation on breathe {
            loops: Animation.Infinite
            running: amb.visible
            NumberAnimation { from: 0.92; to: 1.06; duration: 7000; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1.06; to: 0.92; duration: 7000; easing.type: Easing.InOutSine }
        }
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: amb.width / 2; centerY: amb.lightY
                focalX: centerX; focalY: centerY
                centerRadius: amb.width * 0.42 * light.breathe
                focalRadius: 0
                GradientStop { position: 0.0; color: Qt.rgba(amb.theme.accent.r, amb.theme.accent.g, amb.theme.accent.b, 0.13) }
                GradientStop { position: 0.45; color: Qt.rgba(amb.theme.accent.r, amb.theme.accent.g, amb.theme.accent.b, 0.05) }
                GradientStop { position: 1.0; color: "transparent" }
            }
            PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
        }
    }

    // Edges sink into shadow.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: amb.width / 2; centerY: amb.height * 0.5
                focalX: centerX; focalY: centerY
                centerRadius: Math.max(amb.width, amb.height) * 0.75
                focalRadius: 0
                GradientStop { position: 0.55; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
            }
            PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: amb.theme.bg
        opacity: amb.dim
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }
}
