// Detailed view: list on the left, trailer + cover + metadata + state on the right.
import QtQuick
import Borne.Theme

Item {
    id: root
    property var games                 // library ListModel
    property int currentIndex: 0
    property var game: null            // selected game (provided by Main)
    property QtObject theme
    property var options
    property bool trailers: true
    property bool paused: false
    property bool pointerActive: false
    readonly property alias stage: stage

    signal picked(int index)

    readonly property string nav: "column"
    readonly property int columns: 1

    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }
    function stateText(g) {
        if (!g) return ""
        const dl = g.dl_state
        if (dl === "queued") return qsTr("Waiting to download")
        if (dl === "downloading") return qsTr("Downloading… %1%").arg(g.dl_total > 0 ? Math.round(100 * g.dl_received / g.dl_total) : 0)
        if (dl === "verifying") return qsTr("Verifying files…")
        if (dl === "extracting") return qsTr("Extracting…")
        if (dl === "failed") return qsTr("Download failed: %1").arg(g.dl_error || "")
        if (g.local_state === "local") return qsTr("Installed on this device")
        if (g.linked) return qsTr("Played from the network")
        if (g.local_state === "missing") return qsTr("Local files not found")
        return qsTr("On RomM · %1 to download").arg(fmtSize(g.fs_size))
    }
    function actionText(g) {
        return g ? qsTr("A  Open      Y  Options") : ""
    }

    ListView {
        id: list
        x: 64
        width: Math.max(320, root.width * 0.34)
        height: parent.height
        clip: true
        interactive: false
        model: root.games
        currentIndex: root.currentIndex
        cacheBuffer: theme.listRowH * 4
        reuseItems: true
        highlight: Rectangle { color: theme.accent; radius: 8 }
        highlightFollowsCurrentItem: true
        highlightMoveDuration: theme.scrollMs
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: height / 2 - theme.listRowH / 2
        preferredHighlightEnd: preferredHighlightBegin + theme.listRowH

        delegate: Item {
            required property var model
            required property int index
            width: list.width
            height: theme.listRowH
            readonly property bool cur: index === list.currentIndex
            Rectangle {
                anchors.fill: parent
                radius: 8
                color: theme.fg
                opacity: rowMouse.containsMouse && !parent.cur ? 0.06 : 0
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: root.pointerActive
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(parent.index)
            }
            Text {
                anchors { left: parent.left; leftMargin: 14; right: sys.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                text: (parent.model.local_state === "local" || parent.model.linked ? "✓  " : "") + parent.model.name
                elide: Text.ElideRight
                color: parent.cur ? theme.accentFg : theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 16; bold: parent.cur }
            }
            Text {
                id: sys
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                text: parent.model.platform_name
                color: parent.cur ? theme.accentFg : theme.fgMuted
                opacity: 0.75
                font { family: theme.fontFamily; pixelSize: 12 }
            }
        }
    }

    Item {
        id: detail
        anchors { left: list.right; leftMargin: 32; right: parent.right; rightMargin: 64; top: parent.top; bottom: parent.bottom }

        TrailerStage {
            id: stage
            panel: true
            width: Math.min(detail.width, (detail.height - 250) * 16 / 9)
            height: width * 9 / 16
            game: root.game
            theme: root.theme
            delayMs: root.options ? root.options.trailerDelayMs : 1500
            volume: root.options ? root.options.trailerVolume : 0
            active: root.trailers
            paused: root.paused
        }

        Row {
            anchors { top: stage.bottom; topMargin: 20; left: parent.left; right: parent.right }
            spacing: 24
            Rectangle {
                width: 150; height: 210
                radius: theme.cardRadius
                clip: true
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.hsla(((root.game ? root.game.hue : 200) % 360) / 360, 0.55, 0.42, 1) }
                    GradientStop { position: 1; color: Qt.hsla(((root.game ? root.game.hue + 30 : 230) % 360) / 360, 0.6, 0.14, 1) }
                }
                Image {
                    anchors.fill: parent
                    source: root.game && root.game.cover ? root.game.cover : ""
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(300, 420)
                }
                CardStatus { anchors.fill: parent; game: root.game; theme: root.theme }
            }
            Column {
                width: detail.width - 174
                spacing: 10
                Text {
                    width: parent.width
                    text: root.game ? (theme.uppercaseTitles ? root.game.name.toUpperCase() : root.game.name) : ""
                    elide: Text.ElideRight
                    color: theme.fg
                    font { family: theme.displayFont; pixelSize: 26; bold: true }
                }
                Row {
                    spacing: 22
                    Repeater {
                        model: root.game ? [
                            [qsTr("System"), root.game.platform_name],
                            [qsTr("Year"), root.game.year > 0 ? root.game.year : "—"],
                            [qsTr("Genre"), root.game.genres || "—"],
                            [qsTr("Players"), root.game.players || "—"],
                            [qsTr("Region"), root.game.regions || "—"]
                        ] : []
                        Column {
                            required property var modelData
                            Text { text: modelData[0].toUpperCase(); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 11; letterSpacing: 1 } }
                            Text { text: modelData[1]; color: theme.fg; font { family: theme.fontFamily; pixelSize: 16 } }
                        }
                    }
                }
                Text {
                    width: parent.width
                    text: root.stateText(root.game)
                    color: root.game && root.game.dl_state === "failed" ? theme.bad : root.game && root.game.local_state === "local" ? theme.ok : theme.accent
                    wrapMode: Text.WordWrap
                    font { family: theme.fontFamily; pixelSize: 15; bold: true }
                }
                Text {
                    width: parent.width
                    text: root.game && root.game.summary ? root.game.summary : qsTr("No summary in RomM for this game.")
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    lineHeight: 1.3
                    color: theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 15 }
                }
                Text { text: root.actionText(root.game); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
            }
        }
    }
}
