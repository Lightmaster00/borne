// Gamepad-navigable option list (used by the panels).
import QtQuick

Column {
    id: menu
    property var items: []          // [{ label, detail?, disabled? }]
    property int currentIndex: 0
    property QtObject theme
    spacing: 2

    Repeater {
        model: menu.items
        Rectangle {
            required property var modelData
            required property int index
            readonly property bool cur: index === menu.currentIndex
            width: menu.width
            height: col.height + 20
            radius: 8
            color: cur ? theme.accent : "transparent"
            opacity: modelData.disabled ? 0.45 : 1
            Column {
                id: col
                x: 14; y: 10
                width: parent.width - 28
                Text {
                    width: parent.width
                    text: modelData.label
                    elide: Text.ElideRight
                    color: cur ? theme.accentFg : theme.fg
                    font { family: theme.fontFamily; pixelSize: 16 }
                }
                Text {
                    visible: !!modelData.detail
                    text: modelData.detail || ""
                    color: cur ? theme.accentFg : theme.fgMuted
                    opacity: 0.8
                    font { family: theme.fontFamily; pixelSize: 12 }
                }
            }
        }
    }
}
