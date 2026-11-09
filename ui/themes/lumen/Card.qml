// Lumen tile: square cover, the title floating above the focused tile, a thick animated ring.
import QtQuick
import Borne.Theme

Item {
    id: card
    property var game
    property bool focused: false
    property QtObject theme
    property string posterUrl: ""
    property bool hovered: false
    property bool showLabel: true

    width: theme.cardW
    height: theme.cardH

    Text {
        visible: card.focused
        anchors { left: parent.left; bottom: parent.top; bottomMargin: 14 }
        width: Math.max(parent.width, implicitWidth)
        text: card.game ? card.game.name : ""
        color: theme.accent
        font { family: theme.fontFamily; pixelSize: 17; weight: Font.Medium }
    }
    Rectangle {
        anchors.fill: parent
        radius: theme.cardRadius
        color: Qt.hsla(((card.game ? card.game.hue : 200) % 360) / 360, 0.45, 0.55, 1)
        clip: true
        Text {
            anchors { fill: parent; margins: 16 }
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.WordWrap
            text: card.game ? card.game.name : ""
            color: "white"
            font { family: theme.fontFamily; pixelSize: 22; weight: Font.Bold }
        }
        Image {
            anchors.fill: parent
            source: card.posterUrl
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            verticalAlignment: Image.AlignTop
            sourceSize: Qt.size(theme.cardW * 1.3, theme.cardW * 1.8)
        }
        CardStatus { anchors.fill: parent; game: card.game; theme: card.theme }
    }
    // Focus ring: thick, breathing gently while focused.
    Rectangle {
        anchors { fill: parent; margins: -7 }
        radius: theme.cardRadius + 6
        color: "transparent"
        border { width: 5; color: theme.focusRing }
        opacity: card.focused ? 1 : card.hovered ? 0.4 : 0
        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
        SequentialAnimation on border.color {
            running: card.focused
            loops: Animation.Infinite
            ColorAnimation { to: Qt.lighter(theme.focusRing, 1.35); duration: 900; easing.type: Easing.InOutSine }
            ColorAnimation { to: theme.focusRing; duration: 900; easing.type: Easing.InOutSine }
        }
    }
}
