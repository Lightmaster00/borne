// Button for page actions: filled when primary, outlined otherwise. Focus ring for the gamepad,
// hover and press states for the mouse.
import QtQuick

Rectangle {
    id: btn
    property QtObject theme
    property string text: ""
    property bool primary: false
    property bool disabled: false
    property bool focused: false
    property bool pointerActive: false
    signal clicked()

    implicitWidth: label.implicitWidth + 44
    implicitHeight: 52
    width: implicitWidth
    height: implicitHeight
    radius: theme.buttonRadius
    opacity: disabled ? 0.45 : 1
    scale: mouse.pressed && !disabled ? 0.97 : 1
    color: primary ? theme.accent
         : mouse.containsMouse && !disabled ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.16)
         : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.08)
    border { width: primary ? 0 : 1; color: Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.18) }
    Behavior on color { ColorAnimation { duration: 150 } }
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutQuart } }

    Text {
        id: label
        anchors.centerIn: parent
        text: btn.text
        color: btn.primary ? theme.accentFg : theme.fg
        font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
    }
    // Focus ring, outside the button so it reads on every background.
    Rectangle {
        anchors { fill: parent; margins: -5 }
        radius: btn.radius + 5
        color: "transparent"
        border { width: 3; color: theme.focusRing }
        opacity: btn.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: btn.pointerActive
        cursorShape: btn.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!btn.disabled) btn.clicked()
    }
}
