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
        "download": "M12 3.5v11M7.5 10.2l4.5 4.5 4.5-4.5M4.5 16.5v2a1.5 1.5 0 0 0 1.5 1.5h12a1.5 1.5 0 0 0 1.5-1.5v-2",
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
        "settings": "M10.39 4.78L10.72 2.49L13.28 2.49L13.61 4.78L15.97 5.75L17.82 4.37L19.63 6.18L18.25 8.03L19.22 10.39L21.51 10.72L21.51 13.28L19.22 13.61L18.25 15.97L19.63 17.82L17.82 19.63L15.97 18.25L13.61 19.22L13.28 21.51L10.72 21.51L10.39 19.22L8.03 18.25L6.18 19.63L4.37 17.82L5.75 15.97L4.78 13.61L2.49 13.28L2.49 10.72L4.78 10.39L5.75 8.03L4.37 6.18L6.18 4.37L8.03 5.75ZM15.2 12a3.2 3.2 0 1 1-6.4 0 3.2 3.2 0 0 1 6.4 0z",
        "home": "M3.5 10.6L11.2 4a1.2 1.2 0 0 1 1.6 0l7.7 6.6V19a1.5 1.5 0 0 1-1.5 1.5H15v-5.5a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v5.5H5a1.5 1.5 0 0 1-1.5-1.5z",
        "store": "M5.2 8h13.6a1 1 0 0 1 1 1.1l-1 10.4a1.5 1.5 0 0 1-1.5 1.4H6.7a1.5 1.5 0 0 1-1.5-1.4l-1-10.4A1 1 0 0 1 5.2 8zM8.5 8V7a3.5 3.5 0 0 1 7 0v1",
        "heart": "M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.3 4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z",
        "power": "M12 3.5v7.5M6.8 6.6a7.6 7.6 0 1 0 10.4 0",
        "grid": "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z",
        "sound": "M4 9h4l5-4v14l-5-4H4zM16 9a4 4 0 0 1 0 6M18.5 6.5a7.5 7.5 0 0 1 0 11",
        "mute": "M4 9h4l5-4v14l-5-4H4zM16 9.5l5 5M21 9.5l-5 5",
        "people": "M9 11.2a3.3 3.3 0 1 0 0-6.6 3.3 3.3 0 0 0 0 6.6zM3.2 19.6a5.8 5.8 0 0 1 11.6 0M15.6 11a2.9 2.9 0 1 0 0-5.8M16.8 13.7a5.1 5.1 0 0 1 4 5",
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
