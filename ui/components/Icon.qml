// Stroke icons drawn from 24 × 24 paths, so no icon font or image is needed.
import QtQuick
import QtQuick.Shapes

Item {
    id: icon
    property string name: ""
    property int size: 24
    property color color: "white"
    property real stroke: 2.2
    property bool filled: false

    readonly property var paths: ({
        "check": "M5 12l5 5 9-10",
        "link": "M10 14a4 4 0 0 0 5.6 0l3-3a4 4 0 0 0-5.6-5.6l-1 1M14 10a4 4 0 0 0-5.6 0l-3 3a4 4 0 0 0 5.6 5.6l1-1",
        "alert": "M12 6v7M12 17.5v.5",
        "download": "M12 4v11M7 10l5 5 5-5M5 20h14",
        "play": "M7 4l13 8-13 8z",
        "info": "M12 11v6M12 7.5v.5M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0",
        "back": "M15 5l-7 7 7 7",
        "chevron": "M9 5l7 7-7 7",
        "close": "M6 6l12 12M18 6L6 18",
        "search": "M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM15.3 15.3L20 20"
    })

    width: size
    height: size

    Shape {
        width: 24
        height: 24
        scale: icon.size / 24
        transformOrigin: Item.TopLeft
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: icon.color
            strokeWidth: icon.stroke
            fillColor: icon.filled ? icon.color : "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: icon.paths[icon.name] || "" }
        }
    }
}
