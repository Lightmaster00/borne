// Option list navigable with the gamepad or the mouse (used by menus and panels).
import QtQuick

Column {
    id: menu
    property var items: []          // [{ label, detail?, disabled? }]
    property int currentIndex: 0
    property QtObject theme
    property bool pointerActive: false
    signal clicked(int index)
    spacing: 2

    Repeater {
        model: menu.items
        Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool cur: index === menu.currentIndex
            width: menu.width
            height: col.height + 20
            radius: 8
            color: cur ? theme.accent : mouse.containsMouse && !modelData.disabled ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.08) : "transparent"
            opacity: modelData.disabled ? 0.45 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
            Column {
                id: col
                x: 14; y: 10
                width: parent.width - 28
                Text {
                    width: parent.width
                    text: row.modelData.label
                    elide: Text.ElideRight
                    color: row.cur ? theme.accentFg : theme.fg
                    font { family: theme.fontFamily; pixelSize: 16; weight: row.cur ? Font.Medium : Font.Normal }
                }
                Text {
                    visible: !!row.modelData.detail
                    width: parent.width
                    text: row.modelData.detail || ""
                    wrapMode: Text.WordWrap
                    color: row.cur ? theme.accentFg : theme.fgMuted
                    opacity: 0.85
                    font { family: theme.fontFamily; pixelSize: 12 }
                }
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: menu.pointerActive
                cursorShape: row.modelData.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
                onClicked: if (!row.modelData.disabled) menu.clicked(row.index)
            }
        }
    }
}
