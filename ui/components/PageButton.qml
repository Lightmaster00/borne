// Action button. Primary: white with dark text and the game's halo when focused.
// Others: glass. Focus: a ring 5 px outside (accent around the white button, white otherwise).
import QtQuick
import QtQuick.Effects

Item {
    id: btn
    property QtObject theme
    property string text: ""
    property string key: ""            // controller button shown at the start
    property bool primary: false
    property bool disabled: false
    property bool focused: false
    property bool pointerActive: false
    signal clicked()

    implicitWidth: row.implicitWidth + (key !== "" ? 40 : 56)
    implicitHeight: 60
    width: implicitWidth
    height: implicitHeight
    opacity: disabled ? 0.45 : 1
    scale: mouse.pressed && !disabled ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutQuart } }
    Accessible.role: Accessible.Button
    Accessible.name: text

    Rectangle { id: haloSource; anchors.fill: face; radius: face.radius; color: theme.halo; visible: false }
    MultiEffect {
        anchors.fill: haloSource
        source: haloSource
        visible: btn.focused && btn.primary
        autoPaddingEnabled: true
        blurEnabled: true; blur: 1.0; blurMax: 48
    }
    Ink { theme: btn.theme; radius: height / 2 }
    Rectangle {
        id: face
        anchors.fill: parent
        radius: height / 2
        color: btn.primary ? theme.accent : mouse.containsMouse && !btn.disabled ? theme.glassRaised : theme.glass
        border { width: btn.primary ? 0 : 1; color: theme.glassEdge }
        Behavior on color { ColorAnimation { duration: 150 } }
    }
    Row {
        id: row
        anchors { left: parent.left; leftMargin: btn.key !== "" ? 10 : 28; verticalCenter: parent.verticalCenter }
        spacing: 12
        Rectangle {
            visible: btn.key !== ""
            anchors.verticalCenter: parent.verticalCenter
            width: 40; height: 40; radius: 20
            color: btn.primary ? theme.ink : theme.glassRaised
            Text {
                anchors.centerIn: parent
                text: btn.key
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: btn.text
            color: btn.primary ? theme.accentFg : theme.fg
            font { family: theme.fontFamily; pixelSize: btn.primary ? 20 : 18; weight: btn.primary ? Font.Bold : Font.DemiBold }
        }
    }
    Rectangle {
        anchors { fill: parent; margins: -(theme.ringGap + theme.ringWidth) }
        radius: height / 2
        color: "transparent"
        border { width: theme.ringWidth; color: theme.focusRing }
        opacity: btn.focused ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: btn.pointerActive
        cursorShape: btn.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!btn.disabled) btn.clicked()
    }
}
