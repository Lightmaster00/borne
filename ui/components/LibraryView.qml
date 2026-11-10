// Library: the selected game's title over its living background, and the games as boxes standing
// in space below it (BoxShelf). An index of letters on the edge shows where you are in the
// alphabet; LT / RT jump to the previous / next letter.
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
    property var letters: []          // letters present, in order
    property string currentLetter: ""

    signal picked(int index)
    signal action(string id)
    signal jumpTo(string letter)

    readonly property int columns: 10    // up / down jump this many games
    property int revision: 0
    property string homeStyle: "boxes"   // "boxes" or "arcade"
    readonly property bool arcade: homeStyle === "arcade"

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
        if (g.genres) c.push({ text: g.genres.split(",")[0] })
        return c
    }

    // ---------- the selected game ----------
    onGameChanged: if (game) reveal.restart()
    ParallelAnimation {
        id: reveal
        NumberAnimation { target: info; property: "opacity"; from: 0.0; to: 1.0; duration: 320; easing.type: Easing.OutCubic }
        NumberAnimation { target: info; property: "x"; from: 120; to: 96; duration: 420; easing.type: Easing.OutCubic }
    }
    Column {
        id: info
        x: 96; y: root.arcade ? 926 : 130
        width: 900
        spacing: 18
        visible: root.game !== null
        Text {
            width: parent.width
            text: root.game ? [root.game.platform_name, root.game.year > 0 ? root.game.year : ""].filter(x => x).join(" · ").toUpperCase() : ""
            elide: Text.ElideRight
            color: theme.accent
            font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold; letterSpacing: 3 }
        }
        Text {
            width: parent.width
            height: 92
            visible: !root.arcade
            text: root.game ? root.game.name : ""
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 44
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 88; weight: Font.ExtraBold; letterSpacing: -2.5 }
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
            visible: !root.arcade && text !== ""
            text: root.game && root.game.summary ? root.game.summary : ""
            wrapMode: Text.WordWrap
            width: 760
            maximumLineCount: 2
            elide: Text.ElideRight
            lineHeight: 1.4
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 20 }
        }
    }

    // ---------- the boxes ----------
    ArcadeRoom {
        z: -1
        visible: root.arcade
        anchors.fill: parent
        theme: root.theme
        games: root.games
        currentIndex: root.currentIndex
        revision: root.revision
        pointerActive: root.pointerActive
        onPicked: (i) => root.picked(i)
    }
    BoxShelf {
        id: boxes
        visible: !root.arcade
        // Centered in the space between the title block and the hint bar, whatever the aspect ratio.
        x: 0; y: Math.max(330, 300 + (root.height - 300 - 90 - 600) / 2)
        width: parent.width; height: 600
        theme: root.theme
        games: root.games
        currentIndex: root.currentIndex
        revision: root.revision
        pointerActive: root.pointerActive
        onPicked: (i) => root.picked(i)
    }

    // ---------- letters ----------
    Rectangle {
        z: 3
        anchors { fill: letterCol; margins: -10 }
        radius: 22
        visible: letterCol.visible
        color: Qt.rgba(0.07, 0.075, 0.09, 0.92)
        border { width: 1; color: theme.glassEdge }
    }
    Column {
        id: letterCol
        z: 4
        anchors { right: parent.right; rightMargin: 34; verticalCenter: parent.verticalCenter }
        spacing: 3
        visible: root.letters.length > 1
        Repeater {
            model: root.letters
            Text {
                required property string modelData
                readonly property bool cur: modelData === root.currentLetter
                width: 28
                horizontalAlignment: Text.AlignHCenter
                text: modelData
                color: cur ? theme.accent : theme.fgFaint
                font { family: theme.fontFamily; pixelSize: cur ? 19 : 14; weight: cur ? Font.Bold : Font.DemiBold }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.jumpTo(parent.modelData); root.showLetter(parent.modelData) } }
            }
        }
    }

    // Big letter shown briefly when jumping through the alphabet.
    function showLetter(l) {
        bigLetter.text = l
        letterPop.restart()
    }
    Rectangle {
        id: letterBadge
        z: 5
        anchors.centerIn: boxes
        width: 190; height: 190; radius: 32
        color: Qt.rgba(0.08, 0.09, 0.11, 0.86)
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.12) }
        opacity: 0
        scale: 0.9
        Text {
            id: bigLetter
            anchors.centerIn: parent
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 112; weight: Font.ExtraBold }
        }
        SequentialAnimation {
            id: letterPop
            ParallelAnimation {
                NumberAnimation { target: letterBadge; property: "opacity"; to: 1; duration: 110; easing.type: Easing.OutCubic }
                NumberAnimation { target: letterBadge; property: "scale"; from: 0.9; to: 1; duration: 160; easing.type: Easing.OutCubic }
            }
            PauseAnimation { duration: 520 }
            NumberAnimation { target: letterBadge; property: "opacity"; to: 0; duration: 260; easing.type: Easing.InCubic }
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
