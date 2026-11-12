// Selectable chip (game versions, languages): chosen = filled light, otherwise outlined.
// Focus: ember ring outside the chip.
import QtQuick

Rectangle {
    id: chip
    property QtObject theme
    property string text: ""
    property string detail: ""
    property bool selected: false
    property bool focused: false
    property bool badge: false          // e.g. this version is on this device
    property bool compact: false

    width: content.implicitWidth + 44
    height: 52
    radius: 26
    color: selected ? theme.fg : Qt.rgba(1, 1, 1, 0.05)
    border { width: selected ? 0 : 1; color: theme.glassEdge }
    Behavior on color { ColorAnimation { duration: 150 } }
    Ink { z: -1; theme: chip.theme; radius: chip.radius }
    Accessible.role: Accessible.RadioButton
    Accessible.name: text + (detail ? " " + detail : "")
    Accessible.checked: selected

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 10
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: chip.text
            color: chip.selected ? theme.bg : theme.fg
            font { family: theme.fontFamily; pixelSize: 18; weight: Font.DemiBold }
        }
        Text {
            visible: chip.detail !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: chip.detail
            color: chip.selected ? "#4A4F5C" : theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium }
        }
        Rectangle {
            visible: chip.badge
            anchors.verticalCenter: parent.verticalCenter
            width: 10; height: 10; radius: 5
            color: chip.selected ? theme.bg : theme.accent
        }
    }
    Rectangle {
        anchors { fill: parent; margins: -(theme.ringGap + theme.ringWidth) }
        radius: height / 2
        color: "transparent"
        border { width: theme.ringWidth; color: chip.selected ? theme.accent : theme.focusRing }
        opacity: chip.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
    }
}
