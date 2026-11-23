// The border round the screen, in the colour of the console of the game you are on (or of the
// console filtered), with a soft glow inside. The colour changes with a fade as you move from one
// console's game to another's.
import QtQuick

Item {
    id: frame
    property color tint: "#5A6DB0"
    property real margin: 14          // border thickness, window pixels
    property real radius: 34          // the screen's corners
    property real unit: 1             // the scene's scale: the tab follows the interface's size
    property int fadeMs: 650
    Behavior on tint { ColorAnimation { duration: frame.fadeMs } }

    // A rectangle far larger than the window, whose thick border is the frame: its inner edge is
    // the screen's rounded corners.
    readonly property real spill: 400
    Rectangle {
        x: -frame.spill; y: -frame.spill
        width: frame.width + 2 * frame.spill; height: frame.height + 2 * frame.spill
        radius: frame.radius + frame.spill + frame.margin
        color: "transparent"
        border { width: frame.spill + frame.margin; color: frame.tint }
    }
    // The glow: a few rings fading inward.
    Repeater {
        model: 7
        Rectangle {
            required property int index
            readonly property real inset: frame.margin + index * 6 * frame.unit
            x: inset; y: inset
            width: frame.width - 2 * inset; height: frame.height - 2 * inset
            radius: Math.max(0, frame.radius - index * 6 * frame.unit)
            color: "transparent"
            border { width: 6 * frame.unit; color: Qt.rgba(frame.tint.r, frame.tint.g, frame.tint.b, 0.16 * (1 - index / 7)) }
        }
    }
}
