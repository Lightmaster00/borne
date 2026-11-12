// A choice explained: radio mark, title, a sentence, and what it brings or costs.
// Selected = the current setting (filled radio); focused = ember ring outside the card.
import QtQuick

Rectangle {
    id: card
    property QtObject theme
    property string title: ""
    property string badge: ""
    property string summary: ""
    property var points: []
    property string note: ""
    property bool selected: false
    property bool focused: false
    property bool disabled: false
    property bool pointerActive: false
    signal clicked()

    height: col.height + 64
    radius: 20
    Ink { z: -1; theme: card.theme; radius: card.radius }
    color: selected ? Qt.rgba(1, 1, 1, 0.1) : mouse.containsMouse && !disabled ? theme.glass : Qt.rgba(1, 1, 1, 0.03)
    border { width: 1; color: selected ? Qt.rgba(1, 1, 1, 0.22) : theme.glassEdge }
    opacity: disabled ? 0.6 : 1
    Behavior on color { ColorAnimation { duration: 150 } }
    Accessible.role: Accessible.RadioButton
    Accessible.name: title + ". " + summary
    Accessible.checked: selected

    Column {
        id: col
        x: 32; y: 32
        width: parent.width - 64
        spacing: 18
        Item {
            width: parent.width; height: 32
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 28; height: 28; radius: 14
                color: "transparent"
                border { width: card.selected ? 8 : 2.5; color: card.selected ? theme.accent : theme.fgFaint }
            }
            Text {
                x: 42; anchors.verticalCenter: parent.verticalCenter
                text: card.title
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 26; weight: Font.Bold }
            }
            Rectangle {
                visible: card.badge !== ""
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: bl.implicitWidth + 24; height: 30; radius: 15
                color: card.selected ? theme.accentSoft : theme.glass
                Text {
                    id: bl
                    anchors.centerIn: parent
                    text: card.badge
                    color: card.selected ? theme.accent : theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 14; weight: Font.DemiBold }
                }
            }
        }
        Text {
            width: parent.width
            text: card.summary
            wrapMode: Text.WordWrap
            lineHeight: 1.4
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 18 }
        }
        Column {
            width: parent.width
            spacing: 6
            Repeater {
                model: card.points
                Row {
                    required property string modelData
                    spacing: 12
                    Rectangle { y: 10; width: 6; height: 6; radius: 3; color: theme.fgFaint }
                    Text {
                        width: col.width - 18
                        text: modelData
                        wrapMode: Text.WordWrap
                        color: theme.fgMuted
                        font { family: theme.fontFamily; pixelSize: 17 }
                    }
                }
            }
        }
        Text {
            visible: card.note !== ""
            width: parent.width
            text: card.note
            wrapMode: Text.WordWrap
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 15 }
        }
    }
    Rectangle {
        anchors { fill: parent; margins: -(theme.ringGap + theme.ringWidth) }
        radius: card.radius + theme.ringGap + theme.ringWidth
        color: "transparent"
        border { width: theme.ringWidth; color: theme.focusRing }
        opacity: card.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: card.pointerActive
        cursorShape: card.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!card.disabled) card.clicked()
    }
}
