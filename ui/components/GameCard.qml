// A game in the row: its cover, growing when focused (white ring, the game's halo behind).
// States: small glass check (installed), glass link (mounted), thin white bar (downloading),
// red mark (failed or files missing). No cover: the game's tone with its title set large.
import QtQuick
import QtQuick.Effects

Item {
    id: card
    property QtObject theme
    property var game
    property bool focused: false
    property bool hovered: false
    property real fade: 1            // dimming toward the edge of the row

    width: focused ? theme.tileFocusW : theme.tileW
    height: theme.tileFocusH
    Behavior on width { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutCubic } }

    readonly property string dl: game && game.dl_state ? game.dl_state : ""
    readonly property bool busy: dl === "queued" || dl === "downloading" || dl === "verifying" || dl === "extracting"
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0
    readonly property bool installed: !busy && game && game.local_state === "local"
    readonly property bool mounted: !busy && !installed && game && game.linked
    readonly property bool broken: !busy && (dl === "failed" || (game && game.local_state === "missing"))

    Item {
        id: tile
        anchors.bottom: parent.bottom
        width: card.width
        height: card.focused ? theme.tileFocusH : theme.tileH
        opacity: card.focused ? 1 : (card.hovered ? 1 : 0.82) * card.fade
        Behavior on height { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: theme.focusMs } }

        // Halo: the game's color, behind the focused tile.
        Rectangle { id: haloSource; anchors.fill: parent; radius: theme.tileRadius; color: theme.halo; visible: false }
        MultiEffect {
            anchors.fill: haloSource
            source: haloSource
            visible: card.focused
            autoPaddingEnabled: true
            blurEnabled: true
            blur: 1.0
            blurMax: 64
        }
        Rectangle {
            anchors { fill: parent; margins: -(theme.ringGap + theme.ringWidth) }
            radius: theme.tileRadius + theme.ringGap + theme.ringWidth
            color: "transparent"
            border { width: theme.ringWidth; color: theme.focusRing }
            opacity: card.focused ? 1 : card.hovered ? 0.45 : 0
            Behavior on opacity { NumberAnimation { duration: theme.focusMs } }
        }

        Rectangle {
            id: art
            anchors.fill: parent
            radius: theme.tileRadius
            color: theme.tone(card.game ? card.game.hue : 0)
            layer.enabled: img.status === Image.Ready
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: mask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
            Text {
                visible: img.status !== Image.Ready
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 12 }
                text: card.game ? card.game.name : ""
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
                color: theme.fg
                font { family: theme.displayFont; pixelSize: card.focused ? 24 : 18; weight: Font.ExtraBold }
            }
            Image {
                id: img
                anchors.fill: parent
                source: card.game && card.game.cover ? card.game.cover : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(theme.tileFocusW * 1.5, theme.tileFocusH * 1.5)
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }
        }
        Item {
            id: mask
            anchors.fill: parent
            layer.enabled: true
            visible: false
            Rectangle { anchors.fill: parent; radius: theme.tileRadius; color: "black" }
        }

        // Downloading: thin white bar inside the tile.
        Rectangle {
            visible: card.busy
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 10 }
            height: 4; radius: 2
            color: Qt.rgba(1, 1, 1, 0.22)
            Rectangle {
                width: parent.width * card.progress
                height: parent.height; radius: 2
                color: theme.fg
                Behavior on width { NumberAnimation { duration: 250 } }
            }
        }
        // State badge, top right.
        Rectangle {
            visible: card.installed || card.mounted || card.broken
            anchors { right: parent.right; top: parent.top; margins: 8 }
            width: 26; height: 26; radius: 13
            color: card.broken ? theme.bad : Qt.rgba(0.024, 0.027, 0.04, 0.6)
            border { width: card.broken ? 0 : 1; color: Qt.rgba(1, 1, 1, 0.3) }
            Icon {
                anchors.centerIn: parent
                size: 13
                name: card.installed ? "check" : card.mounted ? "link" : "alert"
                color: card.broken ? theme.bg : theme.fg
                stroke: 3.2
            }
        }
    }
}
