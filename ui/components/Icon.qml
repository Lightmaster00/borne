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
        "search": "M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13zM15.3 15.3L20 20",
        "filter": "M3 5h18l-7 8v6l-4-2v-4z",
        "sort": "M7 4v16M3 16l4 4 4-4M17 20V4M13 8l4-4 4 4",
        "save": "M5 4h11l3 3v13H5zM8 4v5h7V4",
        "load": "M3 12a9 9 0 1 0 3-6.7M3 4v5h5",
        "settings": "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1",
        "home": "M4 11l8-7 8 7M6 9.5V20h4.5v-6h3v6H18V9.5",
        "store": "M5 8h14l-1 12H6zM9 8V6.5a3 3 0 0 1 6 0V8",
        "heart": "M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.3 4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z",
        "power": "M12 3v8M7.2 6.2a7.5 7.5 0 1 0 9.6 0",
        "grid": "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
        "sound": "M4 9h4l5-4v14l-5-4H4zM16 9a4 4 0 0 1 0 6M18.5 6.5a7.5 7.5 0 0 1 0 11",
        "mute": "M4 9h4l5-4v14l-5-4H4zM16 9.5l5 5M21 9.5l-5 5",
        "exit": "M15 4h4v16h-4M10 8l-4 4 4 4M6 12h10"
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
