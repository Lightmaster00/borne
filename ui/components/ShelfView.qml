// Console home row ("shelf" layout): the games in one row of tiles over the selected game's
// artwork. The focused tile either stays at the left margin (theme.shelfAlign "left") or in
// the center ("center"). ListView is virtualized: only visible tiles exist.
import QtQuick

Item {
    id: root
    property var games
    property int currentIndex: 0
    property QtObject theme
    property string cardUrl: ""
    property string emptyText: qsTr("No games here.")
    property bool pointerActive: false
    property var game: null                 // focused game (for the caption)
    property string stateText: ""           // provided by Main ("Installed", "512 KB to download"…)

    signal picked(int index)

    readonly property string nav: "row"
    readonly property int columns: 1
    readonly property int margin: 64
    readonly property real lift: theme.cardH * (theme.focusScale - 1)

    ListView {
        id: row
        y: Math.round(root.height * theme.shelfY)
        width: root.width
        height: theme.cardH + root.lift + 24
        orientation: ListView.Horizontal
        interactive: false
        model: root.games
        currentIndex: root.currentIndex
        spacing: theme.cardGap
        cacheBuffer: theme.cardW * 3
        reuseItems: true
        highlight: Item {}
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: theme.shelfAlign === "center" ? (width - theme.cardW * theme.focusScale) / 2 : root.margin
        preferredHighlightEnd: preferredHighlightBegin + theme.cardW * theme.focusScale
        highlightMoveDuration: theme.scrollMs

        delegate: Item {
            id: cell
            required property var model
            required property int index
            readonly property bool focused: index === row.currentIndex
            // The focused tile takes the room its zoom needs: neighbours move aside instead of being covered.
            width: focused ? Math.round(theme.cardW * theme.focusScale) : theme.cardW
            height: row.height
            z: focused ? 2 : 1
            // Left-aligned rows start at the selection, like a console home: earlier tiles slide out.
            opacity: theme.shelfAlign === "left" && index < row.currentIndex ? 0 : 1
            Behavior on width { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutQuart } }
            Behavior on opacity { NumberAnimation { duration: theme.focusMs } }

            Loader {
                id: ld
                x: Math.round((cell.width - theme.cardW) / 2)
                y: Math.round(root.lift / 2) + 12
                function load() {
                    setSource(root.cardUrl, {
                        theme: root.theme, game: cell.model, focused: cell.focused, posterUrl: cell.model.cover
                    })
                }
                Component.onCompleted: load()
                Connections { target: root; function onCardUrlChanged() { ld.load() } }
                onLoaded: {
                    item.theme = Qt.binding(() => root.theme)
                    item.game = Qt.binding(() => cell.model)
                    item.focused = Qt.binding(() => cell.focused)
                    item.posterUrl = Qt.binding(() => cell.model.cover)
                    // Optional card properties (custom cards may not have them).
                    if ("showLabel" in item) item.showLabel = false
                    if ("hovered" in item) item.hovered = Qt.binding(() => mouse.containsMouse)
                }
            }
            MouseArea {
                id: mouse
                x: ld.x
                width: theme.cardW
                height: theme.cardH
                y: ld.y
                hoverEnabled: root.pointerActive
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(cell.index)
            }
        }
    }

    // Caption of the focused game, under the row (or under the focused tile when centered).
    Column {
        visible: theme.shelfLabels && root.game !== null
        x: theme.shelfAlign === "center" ? (root.width - width) / 2 : root.margin
        y: row.y + row.height + 12
        width: theme.shelfAlign === "center" ? Math.min(root.width - 2 * root.margin, 900) : root.width * 0.5
        spacing: 6
        Text {
            width: parent.width
            horizontalAlignment: theme.shelfAlign === "center" ? Text.AlignHCenter : Text.AlignLeft
            text: root.game ? (theme.uppercaseTitles ? root.game.name.toUpperCase() : root.game.name) : ""
            elide: Text.ElideRight
            color: theme.fg
            font { family: theme.displayFont; pixelSize: theme.titleSize; weight: Font.DemiBold }
        }
        Text {
            width: parent.width
            horizontalAlignment: theme.shelfAlign === "center" ? Text.AlignHCenter : Text.AlignLeft
            text: root.stateText
            elide: Text.ElideRight
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 15 }
        }
    }

    Text {
        visible: root.games && root.games.count === 0
        anchors.centerIn: parent
        width: parent.width - 2 * root.margin
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.emptyText
        color: theme.fgMuted
        font { family: theme.fontFamily; pixelSize: 18 }
    }
}
