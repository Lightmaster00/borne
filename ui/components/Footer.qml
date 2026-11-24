// The bar at the foot of the home, a folder and a game's page: where you are (Store › Switch),
// then the buttons and what they do.
import QtQuick

Rectangle {
    id: foot
    property QtObject theme
    property string where: ""
    property var hints: []
    height: 84
    radius: 34
    color: Qt.rgba(0.04, 0.04, 0.055, 0.5)
    border { width: 1; color: Qt.rgba(1, 1, 1, 0.08) }
    // Square on top: only the bottom corners follow the screen's.
    Rectangle {
        width: parent.width; height: parent.radius
        color: parent.color
        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
    }
    Text {
        id: whereText
        x: 182
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, parent.width * 0.4)
        elide: Text.ElideRight
        text: foot.where
        color: Qt.rgba(1, 1, 1, 0.8)
        font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
    }
    HintBar {
        id: bar
        anchors { right: parent.right; rightMargin: 56; verticalCenter: parent.verticalCenter }
        theme: foot.theme
        hints: foot.hints
    }
}
