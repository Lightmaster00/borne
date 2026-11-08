// Poster grid. GridView is natively virtualized: only visible cards
// (and one spare row) are instantiated, even with thousands of games.
import QtQuick

Item {
    id: root
    property var games          // library ListModel
    property int currentIndex: 0
    property QtObject theme
    property string cardUrl: ""
    property string emptyText: qsTr("No games here.")

    clip: true
    readonly property int columns: Math.max(1, Math.floor((width - 128 + theme.cardGap) / grid.cellWidth))

    GridView {
        id: grid
        width: root.columns * cellWidth
        height: parent.height
        anchors.horizontalCenter: parent.horizontalCenter
        clip: false
        interactive: false
        model: root.games
        currentIndex: root.currentIndex
        cellWidth: theme.cardW + theme.cardGap
        cellHeight: theme.cardH + theme.labelH + theme.cardGap
        topMargin: Math.round(theme.cardH * (theme.focusScale - 1) / 2) + 24
        cacheBuffer: cellHeight
        reuseItems: true

        highlight: Item {}
        highlightFollowsCurrentItem: true
        highlightRangeMode: GridView.ApplyRange
        preferredHighlightBegin: Math.max(topMargin, height * theme.gridAnchor - cellHeight / 2)
        preferredHighlightEnd: preferredHighlightBegin + cellHeight
        highlightMoveDuration: theme.scrollMs

        delegate: Item {
            id: cell
            required property var model
            required property int index
            width: grid.cellWidth
            height: grid.cellHeight
            z: index === grid.currentIndex ? 2 : 1

            Loader {
                id: ld
                x: Math.round(theme.cardGap / 2)
                // Initial properties provided before the card's bindings are evaluated.
                function load() {
                    setSource(root.cardUrl, {
                        theme: root.theme, game: cell.model, focused: cell.index === grid.currentIndex,
                        posterUrl: cell.model.cover
                    })
                }
                Component.onCompleted: load()
                Connections { target: root; function onCardUrlChanged() { ld.load() } }
                onLoaded: {
                    item.theme = Qt.binding(() => root.theme)
                    item.game = Qt.binding(() => cell.model)
                    item.focused = Qt.binding(() => cell.index === grid.currentIndex)
                    item.posterUrl = Qt.binding(() => cell.model.cover)
                }
            }
        }
    }

    Text {
        visible: root.games && root.games.count === 0
        anchors.centerIn: parent
        text: root.emptyText
        color: theme.fgMuted
        font { family: theme.fontFamily; pixelSize: 18 }
    }
}
