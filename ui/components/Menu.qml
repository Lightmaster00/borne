// Option list navigable with the gamepad or the keyboard (used by menus and panels).
import QtQuick

Column {
    id: menu
    property var items: []          // [{ label, detail?, disabled? }]
    property int currentIndex: 0
    property QtObject theme
    spacing: 4
    function rowAt(i) { return rows.itemAt(i) }

    Repeater {
        id: rows
        model: menu.items
        Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool cur: index === menu.currentIndex
            width: menu.width
            height: col.height + 28
            radius: 14
            color: cur ? theme.fg : "transparent"
            opacity: modelData.disabled ? 0.45 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
            Ink { z: -1; theme: menu.theme; radius: 14; visible: row.cur }
            Column {
                id: col
                x: 20; y: 14
                width: parent.width - 40
                Text {
                    width: parent.width
                    text: row.modelData.label
                    elide: Text.ElideRight
                    color: row.cur ? theme.bg : theme.fg
                    font { family: theme.fontFamily; pixelSize: 20; weight: row.cur ? Font.DemiBold : Font.Normal }
                }
                Text {
                    visible: !!row.modelData.detail
                    width: parent.width
                    text: row.modelData.detail || ""
                    wrapMode: Text.WordWrap
                    color: row.cur ? "#4A4F5C" : theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 15 }
                }
            }
        }
    }
}
