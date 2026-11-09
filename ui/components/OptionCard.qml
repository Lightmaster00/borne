// A choice explained: title, what it brings (+), what it costs (−). Selected = current setting.
import QtQuick

Rectangle {
    id: card
    property QtObject theme
    property string title: ""
    property var pros: []
    property var cons: []
    property string note: ""
    property bool selected: false
    property bool focused: false
    property bool disabled: false
    property bool pointerActive: false
    signal clicked()

    height: col.height + 40
    radius: theme.buttonRadius + 4
    color: selected ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.14)
         : mouse.containsMouse && !disabled ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.09)
         : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.05)
    border { width: selected ? 2 : 1; color: selected ? theme.accent : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.12) }
    opacity: disabled ? 0.6 : 1
    Behavior on color { ColorAnimation { duration: 150 } }

    Column {
        id: col
        x: 22; y: 20
        width: parent.width - 44
        spacing: 8
        Row {
            spacing: 10
            // Radio mark
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 20; height: 20; radius: 10
                color: "transparent"
                border { width: 2; color: card.selected ? theme.accent : theme.fgMuted }
                Rectangle { anchors.centerIn: parent; width: 10; height: 10; radius: 5; color: theme.accent; visible: card.selected }
            }
            Text { text: card.title; color: theme.fg; font { family: theme.fontFamily; pixelSize: 18; weight: Font.DemiBold } }
        }
        Item { width: 1; height: 2 }
        Repeater {
            model: card.pros
            Row {
                required property var modelData
                spacing: 10
                Text { text: "+"; color: theme.ok; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold } }
                Text { width: col.width - 24; text: modelData; wrapMode: Text.WordWrap; color: theme.fg; font { family: theme.fontFamily; pixelSize: 14 } }
            }
        }
        Repeater {
            model: card.cons
            Row {
                required property var modelData
                spacing: 10
                Text { text: "−"; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold } }
                Text { width: col.width - 24; text: modelData; wrapMode: Text.WordWrap; color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14 } }
            }
        }
        Text {
            visible: card.note !== ""
            width: parent.width
            topPadding: 4
            text: card.note
            wrapMode: Text.WordWrap
            color: theme.bad
            font { family: theme.fontFamily; pixelSize: 13 }
        }
    }
    Rectangle {
        anchors { fill: parent; margins: -5 }
        radius: card.radius + 5
        color: "transparent"
        border { width: 3; color: theme.focusRing }
        opacity: card.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: card.pointerActive
        cursorShape: card.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!card.disabled) card.clicked()
    }
}
