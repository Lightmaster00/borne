// Theme API v1: a game's state badge, to place in a custom card.
//   CardStatus { anchors.fill: <poster>; game: card.game; theme: card.theme }
// Shows: download progress, "installed", or an error. Nothing for a game that is only on RomM.
import QtQuick

Item {
    id: st
    property var game
    property QtObject theme
    readonly property string dl: game && game.dl_state ? game.dl_state : ""
    readonly property bool active: dl === "queued" || dl === "downloading" || dl === "verifying" || dl === "extracting"
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

    // Download in progress: veil + progress bar.
    Rectangle {
        visible: st.active
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 46
        color: Qt.rgba(0, 0, 0, 0.72)
        Text {
            x: 10; y: 6
            text: st.dl === "queued" ? qsTr("Queued") : st.dl === "verifying" ? qsTr("Verifying") : st.dl === "extracting" ? qsTr("Extracting") : qsTr("%1%").arg(Math.round(st.progress * 100))
            color: "white"
            font { family: theme.fontFamily; pixelSize: 13; bold: true }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
            height: 6; radius: 3; color: Qt.rgba(1, 1, 1, 0.2)
            Rectangle { height: parent.height; radius: 3; color: theme.accent; width: parent.width * st.progress
                Behavior on width { NumberAnimation { duration: 250 } } }
        }
    }
    // Installed
    Rectangle {
        visible: !st.active && st.game && st.game.local_state === "local"
        anchors { right: parent.right; bottom: parent.bottom; margins: 8 }
        width: 28; height: 28; radius: 14
        color: theme.ok
        Text { anchors.centerIn: parent; text: "✓"; color: "#0b1a10"; font { pixelSize: 16; bold: true } }
    }
    // Download error or missing files
    Rectangle {
        visible: !st.active && (st.dl === "failed" || (st.game && st.game.local_state === "missing"))
        anchors { right: parent.right; bottom: parent.bottom; margins: 8 }
        width: 28; height: 28; radius: 14
        color: theme.bad
        Text { anchors.centerIn: parent; text: "!"; color: "white"; font { pixelSize: 16; bold: true } }
    }
}
