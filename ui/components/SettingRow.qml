// One setting: title and explanation on the left, choices (chips) on the right.
import QtQuick

Item {
    id: row
    property QtObject theme
    property string title: ""
    property string description: ""
    property var items: []            // [{ id, label }]
    property string selected: ""
    property int focusIndex: -1       // gamepad cursor in this row, -1 when elsewhere
    property bool pointerActive: false
    signal clicked(int index)

    implicitHeight: Math.max(texts.height, chips.height) + 12
    height: implicitHeight

    Column {
        id: texts
        width: parent.width - chips.width - 32
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3
        Text { width: parent.width; text: row.title; wrapMode: Text.WordWrap; color: theme.fg; font { family: theme.fontFamily; pixelSize: 16; weight: Font.Medium } }
        Text { width: parent.width; text: row.description; visible: text !== ""; wrapMode: Text.WordWrap; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
    }
    Row {
        id: chips
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: 8
        Repeater {
            model: row.items
            Chip {
                required property var modelData
                required property int index
                theme: row.theme
                compact: true
                text: modelData.label
                selected: modelData.id === row.selected
                focused: index === row.focusIndex
                pointerActive: row.pointerActive
                onClicked: row.clicked(index)
            }
        }
    }
}
