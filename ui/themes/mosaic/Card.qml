// Mosaic tile: the cover cropped into a landscape tile with a solid title strip that turns
// accent-colored when focused.
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

    Item {
        anchors.fill: parent
        scale: card.focused ? theme.focusScale : 1
        Behavior on scale { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutQuart } }

        Rectangle {
            anchors.fill: parent
            radius: theme.cardRadius
            color: Qt.hsla(((card.game ? card.game.hue : 150) % 360) / 360, 0.35, 0.22, 1)
            clip: true
            Image {
                anchors.fill: parent
                source: card.posterUrl
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                verticalAlignment: Image.AlignTop
                sourceSize: Qt.size(theme.cardW * 1.3, theme.cardW * 1.8)
            }
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 38
                color: card.focused ? theme.accent : Qt.rgba(0.06, 0.07, 0.07, 0.88)
                Behavior on color { ColorAnimation { duration: theme.focusMs } }
                Text {
                    anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    text: card.game ? card.game.name : ""
                    elide: Text.ElideRight
                    color: card.focused ? theme.accentFg : theme.fg
                    font { family: theme.fontFamily; pixelSize: 14; weight: Font.DemiBold }
                }
            }
            CardStatus { anchors { fill: parent; bottomMargin: 38 } game: card.game; theme: card.theme }
        }
        Rectangle {
            anchors { fill: parent; margins: -4 }
            radius: theme.cardRadius + 3
            color: "transparent"
            border { width: 3; color: theme.focusRing }
            opacity: card.focused ? 1 : card.hovered ? 0.45 : 0
            Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
        }
    }
}
