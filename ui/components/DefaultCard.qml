// Default poster for a game in the grid.
// A theme can provide its own Card.qml exposing the same properties:
//   game (name, platform_name, year, local_state, dl_state, dl_received, dl_total…),
//   focused (bool), theme (ThemeBase), posterUrl (string)
// and optionally hovered (bool, mouse over the card) and showLabel (bool, title under the focused card).
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

    width: theme ? theme.cardW : 180
    height: theme ? theme.cardH + theme.labelH : 286

    Item {
        id: poster
        width: card.width
        height: theme.cardH
        scale: card.focused ? theme.focusScale : 1
        z: card.focused ? 2 : 1
        Behavior on scale { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutCubic } }

        Rectangle {
            id: art
            anchors.fill: parent
            radius: theme.cardRadius
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.hsla(((card.game ? card.game.hue : 200) % 360) / 360, 0.55, 0.42, 1) }
                GradientStop { position: 1; color: Qt.hsla(((card.game ? card.game.hue + 30 : 230) % 360) / 360, 0.6, 0.14, 1) }
            }
            visible: img.status !== Image.Ready

            Text {
                text: card.game ? card.game.platform_name.toUpperCase() : ""
                x: 14; y: 14
                color: "white"; opacity: 0.8
                font { family: theme.fontFamily; pixelSize: 10; bold: true; letterSpacing: 1.2 }
            }
            Text {
                text: card.game ? (theme.uppercaseTitles ? card.game.name.toUpperCase() : card.game.name) : ""
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                wrapMode: Text.WordWrap
                color: "white"
                font { family: theme.displayFont; pixelSize: Math.round(theme.cardW / 8); weight: Font.ExtraBold }
                lineHeight: 0.95
            }
            Text {
                text: card.game && card.game.year > 0 ? card.game.year : ""
                anchors { left: parent.left; bottom: parent.bottom; margins: 14 }
                color: "white"; opacity: 0.75
                font { family: theme.fontFamily; pixelSize: 12 }
            }
        }

        Image {
            id: img
            anchors.fill: parent
            source: card.posterUrl
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(theme.cardW * 1.25, theme.cardH * 1.25)
            visible: status === Image.Ready
        }

        CardStatus { anchors.fill: parent; game: card.game; theme: card.theme }

        Rectangle {
            anchors.fill: parent
            radius: theme.cardRadius
            color: "transparent"
            border { width: card.focused ? 3 : 2; color: card.focused ? theme.focusRing : theme.fgMuted }
            opacity: card.focused ? 1 : card.hovered ? 0.7 : 0
            Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
        }
    }

    Text {
        y: theme.cardH + 12 + (card.focused ? theme.cardH * (theme.focusScale - 1) / 2 : 0)
        width: card.width
        text: card.game ? card.game.name : ""
        elide: Text.ElideRight
        color: theme.fg
        font { family: theme.fontFamily; pixelSize: 13 }
        opacity: card.focused && card.showLabel ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
    }
}
