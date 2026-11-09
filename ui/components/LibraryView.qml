// Library: the selected game large on the left (over the living background), and one row of
// games at the bottom; the focused game stays at the start of the row. ListView is virtualized:
// only the visible tiles exist, even with thousands of games.
import QtQuick

Item {
    id: root
    property QtObject theme
    property var games                // library ListModel
    property var game: null           // selected game (library row)
    property int currentIndex: 0
    property string sectionTitle: ""
    property string emptyText: qsTr("No games here.")
    property bool pointerActive: false

    signal picked(int index)
    signal action(string id)

    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }
    readonly property var chips: {
        const g = game
        if (!g) return []
        const c = []
        const busy = ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
        if (busy) c.push({ text: g.dl_state === "downloading" && g.dl_total > 0 ? qsTr("Downloading %1%").arg(Math.round(100 * g.dl_received / g.dl_total)) : qsTr("Downloading"), icon: "download" })
        else if (g.dl_state === "failed") c.push({ text: qsTr("Download failed"), bad: true })
        else if (g.local_state === "local") c.push({ text: qsTr("Installed"), icon: "check" })
        else if (g.linked) c.push({ text: qsTr("Mounted"), icon: "link" })
        else if (g.local_state === "missing") c.push({ text: qsTr("Files missing"), bad: true })
        else c.push({ text: qsTr("On RomM · %1").arg(fmtSize(g.fs_size)) })
        if (g.version_count > 1) c.push({ text: qsTr("%n version(s)", "", g.version_count) })
        if (g.players) c.push({ text: /^\d+$/.test(g.players) ? qsTr("%n player(s)", "", Number(g.players)) : qsTr("%1 players").arg(g.players) })
        return c
    }

    // ---------- the selected game ----------
    Column {
        x: 96; y: 162
        width: 980
        spacing: 22
        visible: root.game !== null
        Text {
            width: parent.width
            text: root.game ? [root.game.platform_name, root.game.year > 0 ? root.game.year : "", root.game.genres.split(",")[0]].filter(x => x).join(" · ").toUpperCase() : ""
            elide: Text.ElideRight
            color: theme.accent
            font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold; letterSpacing: 3 }
        }
        Text {
            width: parent.width
            height: 104
            text: root.game ? root.game.name : ""
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 56
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 104; weight: Font.ExtraBold; letterSpacing: -3 }
        }
        Flow {
            width: parent.width
            spacing: 10
            Repeater {
                model: root.chips
                Rectangle {
                    required property var modelData
                    height: 36
                    width: chipRow.implicitWidth + 32
                    radius: 18
                    color: modelData.bad ? theme.badTint : theme.glass
                    border { width: 1; color: theme.glassEdge }
                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 8
                        Icon {
                            visible: !!modelData.icon
                            anchors.verticalCenter: parent.verticalCenter
                            name: modelData.icon || ""
                            size: 14; stroke: 3
                            color: theme.accent
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.text
                            color: modelData.bad ? theme.badSoft : theme.fg
                            font { family: theme.fontFamily; pixelSize: 15; weight: modelData.icon ? Font.DemiBold : Font.Medium }
                        }
                    }
                }
            }
        }
        Text {
            width: 700
            text: root.game && root.game.summary ? root.game.summary : ""
            visible: text !== ""
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
            lineHeight: 1.45
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 21 }
        }
        Row {
            spacing: 14
            topPadding: 8
            PageButton { theme: root.theme; key: "A"; text: qsTr("Open"); primary: true; pointerActive: root.pointerActive; onClicked: root.action("a") }
            PageButton { theme: root.theme; key: "X"; text: qsTr("Play"); pointerActive: root.pointerActive; onClicked: root.action("x") }
        }
    }

    // ---------- the row ----------
    Row {
        x: 96; y: 666
        spacing: 14
        Text {
            text: root.sectionTitle
            color: theme.fg
            font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold; letterSpacing: 1 }
        }
        Text {
            text: root.games && root.games.count ? qsTr("%1 of %2").arg(root.currentIndex + 1).arg(root.games.count) : ""
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 16 }
        }
    }
    ListView {
        id: row
        x: 96; y: 700
        width: parent.width - 96
        height: theme.tileFocusH + 24
        orientation: ListView.Horizontal
        spacing: theme.tileGap
        interactive: false
        model: root.games
        currentIndex: root.currentIndex
        cacheBuffer: 400
        reuseItems: true
        highlight: Item {}
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: 0
        preferredHighlightEnd: theme.tileFocusW
        highlightMoveDuration: theme.scrollMs
        highlightResizeDuration: 0
        delegate: GameCard {
            id: tile
            required property var model
            required property int index
            theme: root.theme
            game: model
            focused: index === row.currentIndex
            hovered: mouse.containsMouse
            fade: Math.max(0.3, Math.min(1, (row.width - 260 - (x - row.contentX)) / 420))
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: root.pointerActive
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(tile.index)
            }
        }
    }

    Text {
        visible: root.games && root.games.count === 0
        x: 96; y: 300
        width: 1000
        wrapMode: Text.WordWrap
        text: root.emptyText
        color: theme.fgSoft
        font { family: theme.displayFont; pixelSize: 34; weight: Font.Bold }
    }
}
