// A loading ring: a short arc of light turning round a faint circle.
import QtQuick
import QtQuick.Shapes

Item {
    id: sp
    property real size: 32
    property real thickness: 2.5
    property color color: "white"
    property bool running: visible
    width: size; height: size

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: Qt.rgba(sp.color.r, sp.color.g, sp.color.b, 0.14)
            strokeWidth: sp.thickness
            PathAngleArc {
                centerX: sp.size / 2; centerY: sp.size / 2
                radiusX: (sp.size - sp.thickness) / 2; radiusY: radiusX
                startAngle: 0; sweepAngle: 360
            }
        }
    }
    Shape {
        id: arc
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        // The arc breathes as it turns: longer, then shorter.
        property real sweep
        SequentialAnimation on sweep {
            running: sp.running
            loops: Animation.Infinite
            NumberAnimation { from: 70; to: 200; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 70; duration: 700; easing.type: Easing.InOutSine }
        }
        RotationAnimation on rotation {
            running: sp.running
            loops: Animation.Infinite
            from: 0; to: 360; duration: 1100
        }
        ShapePath {
            fillColor: "transparent"
            strokeColor: sp.color
            strokeWidth: sp.thickness
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: sp.size / 2; centerY: sp.size / 2
                radiusX: (sp.size - sp.thickness) / 2; radiusY: radiusX
                startAngle: -90; sweepAngle: arc.sweep
            }
        }
    }
}
