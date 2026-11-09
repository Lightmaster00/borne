// Selectable chip (game versions, languages): selected = current choice, focused = gamepad cursor.
import QtQuick

Rectangle {
    id: chip
    property QtObject theme
    property string text: ""
    property string detail: ""
    property bool selected: false
    property bool focused: false
    property bool badge: false          // e.g. this version is installed
    property bool compact: false
    property bool pointerActive: false
    signal clicked()

    width: Math.max(col.implicitWidth + 32 + (badge ? 18 : 0), compact ? 64 : 120)
    height: compact ? 40 : 58
    radius: compact ? 20 : theme.buttonRadius
    color: selected ? Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.22)
         : mouse.containsMouse ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.14)
         : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.07)
    border { width: selected ? 2 : 1; color: selected ? theme.accent : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.14) }
    Behavior on color { ColorAnimation { duration: 150 } }

    Column {
        id: col
        anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
        spacing: 2
        Text {
            text: chip.text
            color: theme.fg
            font { family: theme.fontFamily; pixelSize: chip.compact ? 14 : 15; weight: chip.selected ? Font.DemiBold : Font.Normal }
        }
        Text {
            visible: chip.detail !== ""
            text: chip.detail
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 12; letterSpacing: 0.5 }
        }
    }
    Rectangle {
        visible: chip.badge
        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
        width: 8; height: 8; radius: 4
        color: theme.ok
    }
    Rectangle {
        anchors { fill: parent; margins: -5 }
        radius: chip.radius + 5
        color: "transparent"
        border { width: 3; color: theme.focusRing }
        opacity: chip.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: chip.pointerActive
        cursorShape: Qt.PointingHandCursor
        onClicked: chip.clicked()
    }
}
