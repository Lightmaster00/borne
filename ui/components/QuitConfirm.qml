// Asked when Select and Start are pressed together during a game: the game is paused (its
// processes stopped by the core) until the player answers. Keep playing is chosen first.
import QtQuick

Item {
    id: ask
    property QtObject theme
    property string game: ""
    property bool shown: false
    property int choice: 0           // 0 keep playing, 1 quit
    signal answered(bool quit)

    function handle(a) {
        if (a === "left" || a === "right" || a === "up" || a === "down") choice = 1 - choice
        else if (a === "a") answered(choice === 1)
        else if (a === "b") answered(false)
        return true
    }
    onShownChanged: if (shown) choice = 0

    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    Rectangle { anchors.fill: parent; color: Qt.rgba(0.02, 0.024, 0.04, 0.78) }

    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 640)
        height: col.implicitHeight + 72
        radius: 28
        color: "#14161C"
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
        scale: ask.shown ? 1 : 0.96
        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
        Ink { z: -1; theme: ask.theme; radius: 28 }

        Column {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 36 }
            spacing: 14
            Text {
                width: parent.width
                text: qsTr("Quit %1?").arg(ask.game)
                wrapMode: Text.WordWrap
                color: theme ? theme.fg : "white"
                font { family: theme ? theme.displayFont : "Fredoka"; pixelSize: 34; weight: Font.Bold }
            }
            Text {
                width: parent.width
                text: qsTr("The game is paused. What was not saved in the game is lost when you quit.")
                wrapMode: Text.WordWrap
                color: theme ? theme.fgSoft : "#ccc"
                font { family: theme ? theme.fontFamily : "Manrope"; pixelSize: 17 }
            }
            Item { width: 1; height: 10 }
            Row {
                spacing: 14
                PageButton {
                    theme: ask.theme
                    text: qsTr("Keep playing")
                    key: "B"
                    focused: ask.choice === 0
                }
                PageButton {
                    theme: ask.theme
                    text: qsTr("Quit the game")
                    primary: true
                    focused: ask.choice === 1
                }
            }
            Text {
                text: qsTr("Select + Start again: quit at once")
                color: theme ? theme.fgSoft : "#ccc"
                opacity: 0.8
                font { family: theme ? theme.fontFamily : "Manrope"; pixelSize: 14 }
            }
        }
    }
}
