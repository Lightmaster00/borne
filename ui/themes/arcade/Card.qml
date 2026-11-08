// Custom poster for the Arcade theme: tilted neon frame and system label banner.
// Shows that a QML theme can redefine the card entirely, not just its colors.
import QtQuick
import Borne.Theme

Item {
    id: card
    property var game
    property bool focused: false
    property QtObject theme
    property string posterUrl: ""

    width: theme.cardW
    height: theme.cardH + theme.labelH

    Item {
        width: card.width
        height: theme.cardH
        scale: card.focused ? theme.focusScale : 1
        rotation: card.focused ? -2 : 0
        Behavior on scale { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutBack } }
        Behavior on rotation { NumberAnimation { duration: theme.focusMs } }

        Rectangle {
            anchors.fill: parent
            color: Qt.hsla(((card.game ? card.game.hue : 0) % 360) / 360, 0.7, 0.18, 1)
            border { width: card.focused ? 4 : 1; color: card.focused ? theme.focusRing : Qt.rgba(1, 1, 1, 0.15) }

            Rectangle {
                width: parent.width; height: 30
                color: theme.accent
                Text {
                    anchors.centerIn: parent
                    text: card.game ? card.game.platform_name.toUpperCase() : ""
                    color: theme.accentFg
                    font { family: theme.displayFont; pixelSize: 14; letterSpacing: 2 }
                }
            }
            Image {
                anchors { fill: parent; topMargin: 30 }
                source: card.posterUrl
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(theme.cardW, theme.cardH)
            }
            Text {
                visible: card.posterUrl === ""
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 16 }
                text: card.game ? card.game.name.toUpperCase() : ""
                wrapMode: Text.WordWrap
                color: "white"
                style: Text.Outline
                styleColor: theme.focusRing
                font { family: theme.displayFont; pixelSize: 30; letterSpacing: 1 }
            }
            CardStatus { anchors.fill: parent; game: card.game; theme: card.theme }
        }
    }
}
