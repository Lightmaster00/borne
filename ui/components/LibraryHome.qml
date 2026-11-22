// The library: two tabs, My library (games ready to play here) and the Store (the server's other
// games). The games in groups the order explains (This week, A – C, the 1990s…), laid out by
// Shelf.js in the layout chosen: a grid of large covers scrolling down, one large row with the
// selected game shown above it, or two rows scrolling sideways. Each cover keeps its own
// proportions at a common height. The Store opens on its consoles, as large cards: A enters one.
import QtQuick
import QtQuick.Effects
import "Cases.js" as Cases

Item {
    id: root
    property QtObject theme
    property var rows: []             // every game (library rows)
    property var layout: ({ tiles: [], groups: [], total: 0, totalH: 0, vertical: false, count: 0 })
    property string layoutKind: "grid" // "grid" | "row" | "rows2"
    property int current: 0           // selected tile
    property string tab: "home"       // "home" | "store"
    property string subtitle: ""
    property string consoleName: ""   // the console filtered, "" for all
    property color consoleTint: "#F3F1EE"
    property string sortLabel: ""
    property string emptyText: ""
    property string clockText: ""
    property string downloadsText: ""  // "" hides the downloads pill
    property real downloadsProgress: -1
    property var keyLabel: function (a) { return a }
    // The Store's consoles: [{ slug, name, logo, count, installed }]; shown instead of the games.
    property bool wallMode: false
    property var wall: []
    property int wallIndex: 0
    // The selected game's group, for the large row's heading.
    property string groupLabel: ""

    readonly property var curTile: layout.tiles[current] || null
    readonly property var curGame: curTile ? rows[curTile.idx] || null : null
    readonly property real topY: 232
    readonly property real bottomRoom: 92
    // The room the covers have (Shelf.js sizes them to it).
    readonly property bool isGrid: layoutKind === "grid"
    // The grid's frame clips: room is left round the covers for the selection's ring.
    readonly property real gridPad: 16
    readonly property real shelfWidth: viewport.width - (isGrid ? 2 * gridPad : 96)
    readonly property real shelfHeight: viewport.height - (isGrid ? 40 : 0)

    // ---------- header ----------
    Item {
        id: header
        x: 96; y: 108
        width: parent.width - 192; height: 100
        Column {
            spacing: 12
            Row {
                spacing: 20
                KeyCap { anchors.verticalCenter: parent.verticalCenter; theme: root.theme; size: 30; text: root.keyLabel("lb") }
                TabTitle { text: qsTr("My library"); on: root.tab === "home" }
                TabTitle { text: qsTr("Store"); on: root.tab === "store" }
                KeyCap { anchors.verticalCenter: parent.verticalCenter; theme: root.theme; size: 30; text: root.keyLabel("rb") }
            }
            Text {
                text: root.subtitle
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.DemiBold }
            }
        }
        Row {
            anchors { right: parent.right; top: parent.top }
            spacing: 12
            // The console chosen, in its colour: the way to every console (X).
            Rectangle {
                id: consoleBtn
                readonly property color fill: root.consoleName ? root.consoleTint : theme.fg
                readonly property color ink: fill.hslLightness > 0.62 ? "#121216" : "#ffffff"
                anchors.verticalCenter: parent.verticalCenter
                width: consoleRow.implicitWidth + 40; height: 68; radius: 34
                color: fill
                Behavior on color { ColorAnimation { duration: 500 * theme.motion } }
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Console: %1").arg(root.consoleName || qsTr("All"))
                Row {
                    id: consoleRow
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    spacing: 14
                    KeyCap { anchors.verticalCenter: parent.verticalCenter; theme: root.theme; size: 42; text: root.keyLabel("x"); inverted: consoleBtn.ink.hslLightness < 0.5 }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        Text { text: qsTr("Console"); color: consoleBtn.ink; opacity: 0.75; font { family: theme.fontFamily; pixelSize: 13; weight: Font.ExtraBold } }
                        Text { text: root.consoleName || qsTr("All"); color: consoleBtn.ink; font { family: theme.displayFont; pixelSize: 23; weight: Font.ExtraBold; letterSpacing: -0.4 } }
                    }
                }
            }
            Pill { key: root.keyLabel("y"); text: root.sortLabel }
            Pill {
                visible: root.downloadsText !== ""
                key: root.keyLabel("r3"); icon: "download"; text: root.downloadsText
                progress: root.downloadsProgress
            }
            Pill { key: root.keyLabel("start"); text: qsTr("Settings") }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.clockText !== ""
                leftPadding: 6
                text: root.clockText
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 22; weight: Font.Bold; features: { "tnum": 1 } }
            }
        }
    }

    // ---------- the large row: the selected game above it ----------
    Column {
        id: info
        visible: root.layoutKind === "row" && !root.wallMode && !!root.curGame
        x: 96; y: root.topY + 8
        width: Math.min(1240, parent.width - 192)
        spacing: 14
        Text {
            text: root.curGame ? root.curGame.platform_short + (root.groupLabel ? " · " + root.groupLabel : "") : ""
            color: Qt.lighter(root.curGame ? Cases.tint(root.curGame.platform_slug) : theme.accent, 1.25)
            font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
        }
        Text {
            width: parent.width
            text: root.curGame ? root.curGame.name : ""
            elide: Text.ElideRight
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 76; weight: Font.ExtraBold; letterSpacing: -2.5 }
        }
        Text {
            text: {
                const g = root.curGame
                if (!g) return ""
                const bits = []
                if (g.year > 0) bits.push(String(g.year))
                if (g.genres) bits.push(g.genres.split(", ").slice(0, 2).join(", "))
                if (root.curTile && root.curTile.sub) bits.push(root.curTile.sub)
                return bits.join(" · ")
            }
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 19; weight: Font.DemiBold }
        }
        Text {
            width: Math.min(parent.width, 1000)
            text: root.curGame ? root.curGame.summary : ""
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            lineHeight: 1.15
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 19 }
        }
    }

    // ---------- the covers ----------
    Item {
        id: viewport
        visible: !root.wallMode
        x: root.isGrid ? 96 - root.gridPad : 96
        y: root.layoutKind === "row" ? Math.max(root.topY + 250, parent.height * 0.45) : root.topY - (root.isGrid ? 12 : 0)
        width: root.isGrid ? parent.width - 192 + 2 * root.gridPad : parent.width - 96
        height: parent.height - y - root.bottomRoom
        // The grid scrolls down inside a frame whose edges fade out.
        clip: root.isGrid
        layer.enabled: root.isGrid
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: fade
            maskThresholdMin: 0.0
            maskSpreadAtMin: 1.0
        }
        // Scrolls only when the selected cover would leave the view (a margin kept), never past
        // the ends; back to the start when the shelf changes.
        property real targetX: 0
        property real targetY: 0
        readonly property real room: width - 96
        function follow() {
            const t = root.curTile
            if (!t) { targetX = 0; targetY = 0; return }
            if (root.layout.vertical) {
                // The grid goes by lines: the selected one at the top (its group's title with it
                // on the group's first line), unless everything below already fits.
                const gr = root.layout.groups[t.group]
                const first = root.layout.tiles.find(x => x.group === t.group)
                const y = first && first.row === t.row && gr ? gr.y : t.y - 28
                targetY = -Math.max(0, Math.min(y, root.layout.totalH + 40 - height))
                targetX = 0
                return
            }
            const pad = Math.min(260, room * 0.2)
            let x = -targetX
            if (t.x + t.w + pad > x + room) x = t.x + t.w + pad - room
            if (t.x - pad < x) x = t.x - pad
            targetX = -Math.max(0, Math.min(x, root.layout.total - room))
            targetY = 0
        }
        Connections {
            target: root
            function onCurTileChanged() { viewport.follow() }
            function onLayoutChanged() { viewport.targetX = 0; viewport.targetY = 0; viewport.follow() }
        }
        Item {
            id: track
            x: viewport.targetX + (root.isGrid ? root.gridPad : 0)
            y: viewport.targetY + (root.isGrid ? 24 : 0)
            Behavior on x { NumberAnimation { duration: 560 * theme.motion; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 480 * theme.motion; easing.type: Easing.OutCubic } }

            Repeater {
                model: root.layout.groups
                Item {
                    required property var modelData
                    x: modelData.x; y: modelData.y
                    width: modelData.w; height: 60
                    visible: x + width + track.x > -200 && x + track.x < viewport.width + 200
                             && y + track.y > -200 && y + track.y < viewport.height + 200
                    Row {
                        id: groupRow
                        spacing: 12
                        Text {
                            id: groupTitle
                            text: modelData.label
                            color: theme.fg
                            font { family: theme.displayFont; pixelSize: 28; weight: Font.ExtraBold; letterSpacing: -0.5 }
                        }
                        Text {
                            anchors.baseline: groupTitle.baseline
                            text: modelData.count
                            color: theme.fgFaint
                            font { family: theme.fontFamily; pixelSize: 17; weight: Font.Bold }
                        }
                    }
                    Rectangle { y: 48; width: parent.width; height: 2; radius: 1; color: Qt.rgba(1, 1, 1, 0.12) }
                }
            }

            Repeater {
                model: root.layout.tiles
                Tile {
                    required property var modelData
                    required property int index
                    t: modelData
                    g: root.rows[modelData.idx] || null
                    cur: index === root.current
                }
            }
        }
        Text {
            visible: root.layout.count === 0 && root.emptyText !== ""
            anchors.centerIn: parent
            width: Math.min(900, parent.width - 200)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.emptyText
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 24; weight: Font.DemiBold }
        }
    }
    // The grid's frame: opaque inside, fading at the top and the bottom.
    Item {
        id: fade
        width: viewport.width; height: viewport.height
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 24 / Math.max(1, fade.height); color: "white" }
                GradientStop { position: 1 - 70 / Math.max(1, fade.height); color: "white" }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    // ---------- the Store's consoles ----------
    Item {
        id: wallView
        visible: root.wallMode
        x: 96; y: root.topY + 12
        width: parent.width - 192
        height: parent.height - y - root.bottomRoom
        clip: true
        readonly property int cols: 4
        readonly property real gap: 40
        readonly property real cardW: (width - (cols - 1) * gap) / cols
        readonly property real cardH: Math.round(Math.min(cardW * 0.8, (height - gap - 20) / 2))
        readonly property int curRow: Math.floor(root.wallIndex / cols)
        property real scrollY: Math.max(0, curRow - 1) * (cardH + gap)
        Behavior on scrollY { NumberAnimation { duration: 480 * theme.motion; easing.type: Easing.OutCubic } }
        Text {
            visible: root.wall.length === 0
            anchors.centerIn: parent
            text: root.emptyText
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 24; weight: Font.DemiBold }
        }
        Repeater {
            model: root.wall
            Item {
                id: card
                required property var modelData
                required property int index
                readonly property bool on: index === root.wallIndex
                readonly property color tint: Cases.tint(modelData.slug)
                readonly property bool light: tint.hslLightness > 0.62
                x: (index % wallView.cols) * (wallView.cardW + wallView.gap)
                y: 14 + Math.floor(index / wallView.cols) * (wallView.cardH + wallView.gap) - wallView.scrollY
                width: wallView.cardW; height: wallView.cardH
                z: on ? 5 : 1
                scale: on ? 1.04 : 1
                Behavior on scale { NumberAnimation { duration: 360 * theme.motion; easing.type: Easing.OutCubic } }
                Accessible.role: Accessible.Button
                Accessible.name: modelData.name
                Rectangle {
                    visible: card.on
                    anchors { fill: parent; margins: -9 }
                    radius: 39
                    color: "transparent"
                    border { width: 4; color: theme.fg }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 30
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: Qt.lighter(card.tint, 1.12) }
                        GradientStop { position: 1; color: Qt.darker(card.tint, 2.3) }
                    }
                    Image {
                        id: wallLogo
                        visible: status === Image.Ready
                        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: parent.height * 0.13 }
                        width: parent.width - 80; height: parent.height * 0.36
                        source: card.modelData.logo || ""
                        sourceSize.height: 240
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        layer.enabled: true
                        layer.effect: MultiEffect { brightness: card.light ? -1.0 : 1.0; saturation: -1.0 }
                    }
                    Text {
                        visible: !wallLogo.visible
                        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: parent.height * 0.1 }
                        width: parent.width - 60
                        height: parent.height * 0.3
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        fontSizeMode: Text.Fit
                        minimumPixelSize: 22
                        text: card.modelData.name
                        color: card.light ? "#121216" : "#ffffff"
                        font { family: theme.displayFont; pixelSize: 52; weight: Font.ExtraBold; letterSpacing: -1.2 }
                    }
                    Column {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 28 }
                        spacing: 4
                        Text {
                            text: qsTr("%n game(s)", "", card.modelData.count)
                            color: card.light ? "#121216" : "#ffffff"
                            font { family: theme.displayFont; pixelSize: 38; weight: Font.ExtraBold }
                        }
                        Text {
                            text: card.modelData.installed > 0 ? qsTr("%n already in your library", "", card.modelData.installed) : qsTr("None in your library yet")
                            color: card.light ? Qt.rgba(0, 0, 0, 0.7) : Qt.rgba(1, 1, 1, 0.85)
                            font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold }
                        }
                    }
                }
            }
        }
    }

    // ---------- a cover ----------
    component Tile: Item {
        id: tile
        property var t
        property var g
        property bool cur: false
        x: t.x; y: t.y
        width: t.w; height: t.h + (t.caption ? 52 : 0)
        z: cur ? 10 : 1
        readonly property bool inView: x + width + track.x > -300 && x + track.x < viewport.width + 300
                                       && y + height + track.y > -300 && y + track.y < viewport.height + 300
        // Covers load as they come near, and stay loaded.
        property bool seen: false
        onInViewChanged: if (inView) seen = true
        Component.onCompleted: if (inView) seen = true
        visible: inView
        readonly property color tint: g ? Cases.tint(g.platform_slug) : theme.accent
        readonly property bool busy: !!g && ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
        transform: Scale {
            origin.x: tile.width / 2; origin.y: tile.t.h / 2
            xScale: tile.cur ? 1.05 : 1
            yScale: xScale
            Behavior on xScale { NumberAnimation { duration: 320 * theme.motion; easing.type: Easing.OutCubic } }
        }
        Accessible.role: Accessible.Button
        Accessible.name: g ? g.name : ""

        // The ring round the selected cover, and a soft shadow under every cover.
        Rectangle {
            x: 0; y: 14; width: tile.width; height: tile.t.h
            radius: art.r
            color: Qt.rgba(0, 0, 0, 0.45)
            layer.enabled: tile.visible
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 32 }
        }
        Rectangle {
            visible: tile.cur
            x: -9; y: -9; width: tile.width + 18; height: tile.t.h + 18
            radius: art.r + 9
            color: "transparent"
            border { width: 4; color: theme.fg }
        }
        Item {
            id: art
            readonly property real r: 20
            width: tile.width; height: tile.t.h
            layer.enabled: tile.visible
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: artMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
            Rectangle { anchors.fill: parent; color: tile.g ? theme.tone(tile.g.hue) : theme.surface }
            // No cover: the title on the console's colour.
            Text {
                visible: cover.status !== Image.Ready
                anchors { fill: parent; margins: 16 }
                text: tile.g ? tile.g.name : ""
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                color: "#ffffff"
                font { family: theme.displayFont; pixelSize: Math.max(18, Math.min(30, tile.t.h / 11)); weight: Font.ExtraBold }
            }
            Image {
                id: cover
                anchors.fill: parent
                source: tile.seen && tile.g ? tile.g.cover : ""
                sourceSize.height: Math.min(900, Math.round(tile.t.h * 1.6))
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }
            // Downloading: its progress along the bottom.
            Rectangle {
                visible: tile.busy
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 8
                color: Qt.rgba(0, 0, 0, 0.55)
                Rectangle {
                    height: parent.height
                    width: tile.g && tile.g.dl_total > 0 ? parent.width * tile.g.dl_received / tile.g.dl_total : parent.width * 0.1
                    color: tile.tint
                }
            }
        }
        Rectangle {
            id: artMask
            width: art.width; height: art.height
            radius: art.r
            visible: false
            layer.enabled: true
        }
        Column {
            visible: tile.t.caption
            y: tile.t.h + 12
            x: 4
            width: Math.max(tile.width, 150) - 8
            spacing: 2
            Text {
                width: parent.width
                text: tile.g ? tile.g.name : ""
                elide: Text.ElideRight
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
            }
            Text {
                width: parent.width
                text: tile.t.sub
                elide: Text.ElideRight
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 14; weight: Font.DemiBold }
            }
        }
    }

    component TabTitle: Text {
        property bool on: false
        color: on ? theme.fg : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.38)
        Behavior on color { ColorAnimation { duration: 300 * theme.motion } }
        font { family: theme.displayFont; pixelSize: 48; weight: Font.ExtraBold; letterSpacing: -1.5 }
        Accessible.role: Accessible.PageTab
        Accessible.name: text
    }

    component Pill: Rectangle {
        id: pill
        property string key: ""
        property string icon: ""
        property real progress: -1
        property alias text: pillText.text
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        width: pillRow.implicitWidth + 32; height: 56; radius: 28
        color: Qt.rgba(1, 1, 1, 0.1)
        Accessible.role: Accessible.Button
        Accessible.name: pillText.text
        Row {
            id: pillRow
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            spacing: 10
            KeyCap { anchors.verticalCenter: parent.verticalCenter; theme: root.theme; size: 36; text: pill.key }
            Icon { visible: pill.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: pill.icon; size: 20; stroke: 2.4; color: theme.fg }
            Text {
                id: pillText
                anchors.verticalCenter: parent.verticalCenter
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
            }
        }
        Rectangle {
            visible: pill.progress >= 0
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14 }
            height: 3; radius: 2
            color: Qt.rgba(1, 1, 1, 0.15)
            Rectangle { width: parent.width * Math.max(0, Math.min(1, pill.progress)); height: parent.height; radius: 2; color: theme.accent }
        }
    }
}
