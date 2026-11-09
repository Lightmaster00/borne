// Arcade cabinet carousel ("carousel" layout): a wheel of titles on the right, the selected
// game's cover large on the left, its trailer behind everything (TrailerStage, in Main).
import QtQuick

Item {
    id: root
    property var games
    property int currentIndex: 0
    property QtObject theme
    property string cardUrl: ""
    property string emptyText: qsTr("No games here.")
    property bool pointerActive: false
    property var game: null
    property string stateText: ""

    signal picked(int index)

    readonly property string nav: "column"
    readonly property int columns: 1

    // Selected game's cover, slightly tilted like a cabinet marquee card.
    Item {
        id: art
        x: 64
        width: Math.min(root.width * 0.36, (root.height - 120) * 0.72)
        height: width / 0.72
        anchors.verticalCenter: parent.verticalCenter
        visible: root.game !== null
        rotation: -2
        Rectangle {
            anchors.fill: parent
            anchors.margins: -6
            radius: theme.cardRadius + 6
            color: "transparent"
            border { width: 3; color: theme.focusRing }
        }
        Rectangle {
            anchors.fill: parent
            radius: theme.cardRadius
            color: theme.bg2
            clip: true
            Image {
                id: cover
                anchors.fill: parent
                source: root.game ? root.game.cover : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(art.width * 1.5, art.height * 1.5)
            }
            Text {
                visible: cover.status !== Image.Ready
                anchors { fill: parent; margins: 24 }
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.game ? root.game.name.toUpperCase() : ""
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 44 }
            }
        }
        Text {
            anchors { top: parent.bottom; topMargin: 22; left: parent.left }
            width: root.width * 0.5
            rotation: 2
            text: root.stateText
            elide: Text.ElideRight
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 15 }
        }
    }

    ListView {
        id: wheel
        anchors { right: parent.right; rightMargin: 64; top: parent.top; bottom: parent.bottom }
        width: Math.max(360, root.width * 0.42)
        clip: true
        interactive: false
        model: root.games
        currentIndex: root.currentIndex
        cacheBuffer: theme.wheelRowH * 6
        reuseItems: true
        highlight: Item {}
        highlightFollowsCurrentItem: true
        highlightRangeMode: ListView.StrictlyEnforceRange
        preferredHighlightBegin: height / 2 - theme.wheelRowH / 2
        preferredHighlightEnd: preferredHighlightBegin + theme.wheelRowH
        highlightMoveDuration: theme.scrollMs

        delegate: Item {
            id: rowItem
            required property var model
            required property int index
            readonly property int distance: Math.abs(index - wheel.currentIndex)
            readonly property bool focused: distance === 0
            width: wheel.width
            height: theme.wheelRowH
            opacity: focused ? 1 : Math.max(0.18, 0.75 - distance * 0.16)
            Behavior on opacity { NumberAnimation { duration: theme.focusMs } }

            Text {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: rowItem.model.name.toUpperCase()
                elide: Text.ElideLeft
                color: rowItem.focused ? theme.accent : (mouse.containsMouse ? theme.fg : theme.fgMuted)
                scale: rowItem.focused ? 1 : 0.78
                transformOrigin: Item.Right
                font { family: theme.displayFont; pixelSize: theme.wheelRowH - 14 }
                Behavior on scale { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutQuart } }
            }
            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: root.pointerActive
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picked(rowItem.index)
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
