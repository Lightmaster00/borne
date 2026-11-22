// Sort: a short list that drops from its button, each order with what it does; the one in use
// carries a filled dot. Up and down choose, A sorts, B closes.
import QtQuick

Rectangle {
    id: root
    property QtObject theme
    property var sorts: []            // [{ id, label, hint }]
    property string current: ""
    property int index: 0

    width: 440
    height: col.height + 28
    radius: 28
    color: Qt.rgba(0.094, 0.094, 0.118, 0.97)
    border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
    transformOrigin: Item.TopRight
    scale: visible ? 1 : 0.92
    opacity: visible ? 1 : 0
    Behavior on scale { NumberAnimation { duration: 380 * theme.motion; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
    Behavior on opacity { NumberAnimation { duration: 200 } }

    Column {
        id: col
        x: 14; y: 14
        width: parent.width - 28
        Text {
            leftPadding: 16; topPadding: 8; bottomPadding: 12
            text: qsTr("Sort by")
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 15; weight: Font.ExtraBold }
        }
        Repeater {
            model: root.sorts
            Rectangle {
                required property var modelData
                required property int index
                readonly property bool hov: index === root.index
                readonly property bool sel: modelData.id === root.current
                width: col.width; height: 66; radius: 18
                color: hov ? theme.fg : "transparent"
                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.label
                Accessible.checked: sel
                Column {
                    anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
                    spacing: 2
                    Text { text: modelData.label; color: hov ? theme.bg : theme.fg; font { family: theme.fontFamily; pixelSize: 19; weight: Font.ExtraBold } }
                    Text { text: modelData.hint; color: hov ? Qt.rgba(0, 0, 0, 0.6) : theme.fgFaint; font { family: theme.fontFamily; pixelSize: 13; weight: Font.Bold } }
                }
                Rectangle {
                    anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
                    width: 22; height: 22; radius: 11
                    color: "transparent"
                    border { width: sel ? 7 : 2; color: hov ? theme.bg : sel ? theme.fg : Qt.rgba(1, 1, 1, 0.4) }
                }
            }
        }
    }
}
