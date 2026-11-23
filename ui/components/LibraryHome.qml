// The library, as a console's home: over the selected game's art (Ambience), a row of the games
// played lately (the one selected grows, its name and details under the row) and, below, the
// collections as folders (Favourites, Two players, one per console). The Store shows the server's
// consoles as slanted cards: the one selected opens wide on three of its games. A collection, "See
// all" or a console of the Store opens as a glass panel over the home: a grid of its games.
//
// Everything here is drawn from Main's state (zone, indexes, folder); Main handles the input.
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "Cases.js" as Cases

Item {
    id: root
    property QtObject theme
    property var rows: []
    property var indexByRom: ({})
    property string tab: "home"        // "home" | "store"
    property string zone: "row"        // "rail" | "row" | "shelf" | "wall"
    // Home: the recent games (rom ids), then a "See all" tile; the collections.
    property var recents: []
    property int rowIndex: 0
    property var collections: []
    property int shelfIndex: 0
    property int homeCount: 0
    // Store: the consoles' cards (Shelf.storeCards).
    property var wall: []
    property int wallIndex: 0
    // The way the selection last moved among the Store's consoles: 1 right, -1 left.
    property int wallDir: 1
    property int lastWall: 0
    onWallIndexChanged: { wallDir = wallIndex >= lastWall ? 1 : -1; lastWall = wallIndex }
    property string storeLine: ""
    // A folder open: { kind, slug, name } and its grid (Shelf.build, "grid").
    property var folder: null
    property var layout: ({ tiles: [], groups: [], total: 0, totalH: 0, vertical: true, count: 0 })
    property int current: 0
    property string folderLine: ""
    property string folderFoot: ""
    property string emptyText: ""
    property var keyLabel: function (a) { return a }
    // Short console names (Main.shortNames), for the kicker.
    property var shortName: function (slug) { return slug }
    property var agoText: function (secs) { return "" }

    readonly property real leftX: 196
    readonly property bool onHome: tab === "home"
    readonly property bool onStore: tab === "store"
    // How the cards look (Settings → Developer → Light and cards, prefs.look*): card style
    // ("studio" | "lacquer" | "glass"), key light, floor and shadow strength (0–100).
    property var look: ({ card: "studio", key: 50, floor: 40, shadow: 60 })
    // What the room's light takes its colours from: the console's picture in the Store.
    readonly property string glowSource: onStore && wall[wallIndex] ? (wall[wallIndex].photo || "") : ""
    // Where the room's light falls (Ambience.lightX): over the console chosen in the Store, over
    // the games on the home, over the collections when they have the focus.
    readonly property real lightX: onStore ? 150 + 80 + (wallIndex === 0 ? 0 : 172) + 320
                                 : zone === "shelf" ? width * 0.5 : leftX + 260
    readonly property bool folderOpen: folder !== null
    readonly property real motion: theme ? theme.motion : 1

    function gameOf(rom) { const i = indexByRom[rom]; return i === undefined ? null : rows[i] || null }
    readonly property var rowGames: recents.map(r => gameOf(r)).filter(g => !!g)
    readonly property int allIndex: rowGames.length          // the "See all" tile
    readonly property var curGame: rowIndex < rowGames.length ? rowGames[rowIndex] : null
    readonly property var curTile: layout.tiles[current] || null
    readonly property var folderGame: curTile ? rows[curTile.idx] || null : null

    // The folder's room (Main lays its grid out to it).
    readonly property real panelX: 196
    readonly property real panelW: width - panelX - 110
    readonly property real panelH: Math.min(850, height - 110 - 120)
    readonly property real gridPad: 30
    readonly property real folderWidth: panelW - 60 - 2 * gridPad
    readonly property real folderHeight: panelH - 116 - 80
    readonly property int folderTileH: Math.round(Math.max(200, Math.min(330, (folderWidth - 4 * 40) / (5 * 0.72))))

    // ================= the home =================
    Item {
        id: home
        anchors.fill: parent
        opacity: root.onHome ? 1 : 0
        visible: opacity > 0
        x: root.onHome ? 0 : -120
        Behavior on opacity { NumberAnimation { duration: 450 * root.motion; easing.type: Easing.InOutQuad } }
        Behavior on x { NumberAnimation { duration: 600 * root.motion; easing.type: Easing.OutCubic } }

        // Faded out above the footer, so the collections peeking from below never run under it.
        layer.enabled: visible
        layer.effect: MultiEffect { maskEnabled: true; maskSource: homeFade; maskThresholdMin: 0.0; maskSpreadAtMin: 1.0 }
        Item {
            id: homeContent
            width: parent.width; height: parent.height
            // Down to the collections: the page rises, the row stays in sight above.
            y: root.zone === "shelf" ? -300 : 0
            Behavior on y { NumberAnimation { duration: 650 * root.motion; easing.type: Easing.OutCubic } }

            Text {
                x: root.leftX; y: 186
                text: qsTr("Recently played")
                color: Qt.rgba(1, 1, 1, 0.75)
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
            }

            // ---------- the row ----------
            Item {
                id: rowView
                x: 172; y: 200
                width: parent.width - x - 14; height: 540
                clip: true
                opacity: root.zone === "shelf" ? 0.4 : 1
                Behavior on opacity { NumberAnimation { duration: 450 * root.motion } }
                readonly property real coverH: 420
                readonly property bool lit: root.zone === "row" && root.onHome && !root.folderOpen
                // Each tile's place: the selected one large (larger while the row has the focus).
                readonly property var geom: {
                    const out = []
                    let x = 0
                    const n = root.rowGames.length + 1
                    for (let k = 0; k < n; k++) {
                        const g = root.rowGames[k]
                        const ratio = g ? Math.max(0.55, Math.min(1.5, g.cover_ar >= 0.45 && g.cover_ar <= 2.2 ? g.cover_ar : Cases.ratio(g.platform_slug))) : 0.8
                        const hh = k === root.rowIndex ? (lit ? coverH + 40 : coverH) : Math.round(coverH * 0.8)
                        const w = Math.round(hh * ratio)
                        out.push({ x: x, y: Math.round((coverH + 40 - hh) / 2), w: w, h: hh })
                        x += w + 26
                    }
                    return out
                }
                Item {
                    id: rowTrack
                    x: 24 - Math.max(0, (rowView.geom[root.rowIndex] ? rowView.geom[root.rowIndex].x : 0) - 40)
                    y: 26
                    Behavior on x { NumberAnimation { duration: 520 * root.motion; easing.type: Easing.OutCubic } }
                    Repeater {
                        model: root.rowGames.length + 1
                        Cover {
                            required property int index
                            readonly property var r: rowView.geom[index] || { x: 0, y: 0, w: 0, h: 0 }
                            g: index < root.rowGames.length ? root.rowGames[index] : null
                            all: index === root.allIndex
                            x: r.x; y: r.y; width: r.w; height: r.h
                            radius: 14
                            ring: rowView.lit && index === root.rowIndex
                            badge: index === 0 && !!g && g.last_played > 0 ? qsTr("In progress") : ""
                            Behavior on x { NumberAnimation { duration: 520 * root.motion; easing.type: Easing.OutCubic } }
                            Behavior on y { NumberAnimation { duration: 520 * root.motion; easing.type: Easing.OutCubic } }
                            Behavior on width { NumberAnimation { duration: 520 * root.motion; easing.type: Easing.OutCubic } }
                            Behavior on height { NumberAnimation { duration: 520 * root.motion; easing.type: Easing.OutCubic } }
                        }
                    }
                }
                Text {
                    visible: root.rowGames.length === 0
                    x: 24; y: 150
                    width: Math.min(900, parent.width - 600)
                    wrapMode: Text.WordWrap
                    text: root.emptyText
                    color: theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 24; weight: Font.DemiBold }
                }
            }

            // ---------- the selected game, under the row ----------
            Reveal {
                x: root.leftX; y: 726
                key: root.rowIndex
                motion: root.motion
                dy: 0
                dx: 24
            Column {
                width: Math.min(1300, root.width - root.leftX - 140)
                spacing: 8
                opacity: root.zone === "row" ? 1 : 0.35
                Behavior on opacity { NumberAnimation { duration: 250 * root.motion } }
                Text {
                    text: {
                        const g = root.curGame
                        if (!g) return qsTr("All your games")
                        const c = root.shortName(g.platform_slug)
                        if (root.rowIndex === 0 && g.last_played > 0) return qsTr("In progress · %1").arg(c)
                        return g.last_played > 0 ? qsTr("%1 · played %2").arg(c).arg(root.agoText(g.last_played).toLowerCase()) : qsTr("%1 · never played").arg(c)
                    }
                    color: Qt.lighter(root.curGame ? Cases.tint(root.curGame.platform_slug) : theme.fg, 1.35)
                    font { family: theme.fontFamily; pixelSize: 20; weight: Font.ExtraBold }
                }
                Text {
                    width: parent.width
                    text: root.curGame ? root.curGame.name : qsTr("See all")
                    elide: Text.ElideRight
                    color: theme.fg
                    font { family: theme.displayFont; pixelSize: 66; weight: Font.ExtraBold; letterSpacing: -2.2 }
                }
                Text {
                    text: {
                        const g = root.curGame
                        if (!g) return qsTr("%n game(s) ready to play, the last played first", "", root.homeCount)
                        const bits = []
                        const h = (g.play_seconds || 0) / 3600
                        if (h > 0) bits.push(h >= 1 ? qsTr("%1 h played").arg(Math.round(h * 10) / 10) : qsTr("%1 min played").arg(Math.max(1, Math.round(h * 60))))
                        if (g.genres) bits.push(g.genres.split(", ").slice(0, 2).join(", "))
                        if (g.year > 0) bits.push(String(g.year))
                        return bits.join(" · ")
                    }
                    color: Qt.rgba(1, 1, 1, 0.78)
                    font { family: theme.fontFamily; pixelSize: 19; weight: Font.DemiBold }
                }
            }

            }
            // ---------- the collections ----------
            Text {
                x: root.leftX; y: 886
                text: qsTr("Collections")
                color: Qt.rgba(1, 1, 1, 0.75)
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
            }
            Item {
                x: root.leftX - 20; y: 910
                width: parent.width - x - 14; height: 280
                clip: true
                Row {
                    x: 20 - Math.max(0, (root.shelfIndex + 1) * 326 - (parent.width - 160))
                    y: 20
                    spacing: 26
                    Behavior on x { NumberAnimation { duration: 450 * root.motion; easing.type: Easing.OutCubic } }
                    Repeater {
                        model: root.collections
                        Folder {
                            required property var modelData
                            required property int index
                            c: modelData
                            on: root.zone === "shelf" && root.onHome && !root.folderOpen && index === root.shelfIndex
                        }
                    }
                }
            }
        }
    }

    // ================= the Store =================
    Item {
        id: store
        anchors.fill: parent
        opacity: root.onStore ? 1 : 0
        visible: opacity > 0
        x: root.onStore ? 0 : 120
        Behavior on opacity { NumberAnimation { duration: 450 * root.motion; easing.type: Easing.InOutQuad } }
        Behavior on x { NumberAnimation { duration: 600 * root.motion; easing.type: Easing.OutCubic } }
        Column {
            x: root.leftX; y: 170
            spacing: 6
            Text {
                text: qsTr("Store")
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 52; weight: Font.ExtraBold; letterSpacing: -1.8 }
            }
            Text {
                text: root.storeLine
                color: Qt.rgba(1, 1, 1, 0.75)
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.DemiBold }
            }
        }
        Item {
            x: 150; y: 270
            width: parent.width - x - 14; height: 590
            clip: true
            Row {
                x: 80 - Math.max(0, (root.wallIndex - 1) * 172)
                y: 40
                spacing: 22
                Behavior on x { NumberAnimation { duration: 600 * root.motion; easing.type: Easing.OutCubic } }
                Repeater {
                    model: root.wall
                    Card {
                        required property var modelData
                        required property int index
                        c: modelData
                        on: index === root.wallIndex && root.onStore && !root.folderOpen
                        lit: on && root.zone === "wall"
                    }
                }
            }
        }
        Text {
            visible: root.wall.length === 0
            x: root.leftX; y: 520
            width: Math.min(900, parent.width - 400)
            wrapMode: Text.WordWrap
            text: root.emptyText
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 24; weight: Font.DemiBold }
        }
        Reveal {
            x: root.leftX; y: 862
            key: root.wallIndex
            motion: root.motion
            dx: root.wallDir * 40
            dy: 0
        Column {
            spacing: 8
            readonly property var w: root.wall[root.wallIndex] || null
            Text {
                text: parent.w ? parent.w.name : ""
                color: theme.fg
                font { family: theme.displayFont; pixelSize: 44; weight: Font.ExtraBold; letterSpacing: -1.3 }
            }
            Text {
                text: {
                    const w = parent.w
                    if (!w) return ""
                    const bits = [qsTr("%n game(s) to discover", "", w.count),
                                  w.installed > 0 ? qsTr("%n already in your library", "", w.installed) : qsTr("None in your library yet")]
                    if (w.made) bits.push(w.made)
                    return bits.join(" · ")
                }
                color: Qt.rgba(1, 1, 1, 0.78)
                font { family: theme.fontFamily; pixelSize: 19; weight: Font.DemiBold }
            }
        }
        }
    }

    // ================= a folder =================
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.024, 0.024, 0.04, 0.55)
        opacity: root.folderOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 450 * root.motion } }
    }
    Rectangle {
        id: panel
        x: root.panelX; y: 110
        width: root.panelW; height: root.panelH
        radius: 28
        color: Qt.rgba(0.12, 0.12, 0.15, 0.86)
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.14) }
        opacity: root.folderOpen ? 1 : 0
        visible: opacity > 0
        scale: root.folderOpen ? 1 : 0.94
        Behavior on opacity { NumberAnimation { duration: 380 * root.motion } }
        Behavior on scale { NumberAnimation { duration: 500 * root.motion; easing.type: Easing.OutCubic } }

        // The name, the game selected, the count.
        Item {
            x: 48; y: 34
            width: parent.width - 96; height: 62
            Row {
                spacing: 18
                Text {
                    id: folderName
                    text: root.folder ? root.folder.name : ""
                    color: theme.fg
                    font { family: theme.displayFont; pixelSize: 36; weight: Font.ExtraBold; letterSpacing: -0.7 }
                }
                Rectangle { anchors.verticalCenter: folderName.verticalCenter; width: 2; height: 28; color: Qt.rgba(1, 1, 1, 0.3) }
                Text {
                    anchors.baseline: folderName.baseline
                    width: Math.min(implicitWidth, panel.width - 96 - folderName.width - 80 - countText.implicitWidth)
                    elide: Text.ElideRight
                    text: root.folderGame ? root.folderGame.name : ""
                    color: Qt.rgba(1, 1, 1, 0.85)
                    font { family: theme.fontFamily; pixelSize: 22; weight: Font.Bold }
                }
            }
            Text {
                id: countText
                anchors { right: parent.right; top: parent.top; topMargin: 14 }
                text: root.folderLine
                color: Qt.rgba(1, 1, 1, 0.6)
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1.5; color: Qt.rgba(1, 1, 1, 0.18) }
        }

        // The grid.
        Item {
            id: viewport
            x: 30; y: 116
            width: parent.width - 60; height: root.folderHeight
            clip: true
            property real targetY: 0
            function follow() {
                const t = root.curTile
                if (!t) { targetY = 0; return }
                const gr = root.layout.groups[t.group]
                const first = root.layout.tiles.find(x => x.group === t.group)
                const y = first && first.row === t.row && gr ? gr.y : t.y - 28
                // The line selected near the top, unless what is below already fits.
                const top = Math.max(0, y - 40)
                targetY = -Math.max(0, Math.min(top, root.layout.totalH + 40 - height))
            }
            Connections {
                target: root
                function onCurTileChanged() { viewport.follow() }
                function onLayoutChanged() { viewport.targetY = 0; viewport.follow() }
            }
            Item {
                id: track
                x: root.gridPad
                y: viewport.targetY + root.gridPad
                Behavior on y { NumberAnimation { duration: 480 * root.motion; easing.type: Easing.OutCubic } }
                Repeater {
                    model: root.layout.groups.length > 1 ? root.layout.groups : []
                    Item {
                        required property var modelData
                        x: modelData.x; y: modelData.y
                        width: modelData.w; height: 60
                        visible: y + track.y > -200 && y + track.y < viewport.height + 200
                        Row {
                            spacing: 12
                            Text {
                                id: groupTitle
                                text: modelData.label
                                color: theme.fg
                                font { family: theme.displayFont; pixelSize: 26; weight: Font.ExtraBold; letterSpacing: -0.5 }
                            }
                            Text {
                                anchors.baseline: groupTitle.baseline
                                text: modelData.count
                                color: theme.fgFaint
                                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
                            }
                        }
                    }
                }
                Repeater {
                    model: root.layout.tiles
                    Tile {
                        required property var modelData
                        required property int index
                        t: modelData
                        // Without group titles the grid starts at the top.
                        shift: root.layout.groups.length > 1 ? 0 : -66
                        g: root.rows[modelData.idx] || null
                        cur: index === root.current && root.folderOpen
                    }
                }
            }
            Text {
                visible: root.layout.count === 0
                anchors.centerIn: parent
                width: Math.min(800, parent.width - 120)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: root.folder && root.folder.kind === "fav" ? qsTr("No favourite yet. On a game's page, the heart adds it here.") : root.emptyText
                color: theme.fgSoft
                font { family: theme.fontFamily; pixelSize: 22; weight: Font.DemiBold }
            }
        }
        // The order, at the foot.
        Item {
            x: 48; y: parent.height - 62
            width: parent.width - 96; height: 40
            Rectangle { width: parent.width; height: 1.5; color: Qt.rgba(1, 1, 1, 0.14) }
            Row {
                y: 12
                spacing: 12
                KeyCap { anchors.verticalCenter: parent.verticalCenter; theme: root.theme; size: 28; text: root.keyLabel("y") }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.folderFoot
                    color: Qt.rgba(1, 1, 1, 0.8)
                    font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
                }
            }
        }
    }

    // The home's fade above the footer (its layer's mask).
    Item {
        id: homeFade
        width: root.width; height: root.height
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: "white" }
                GradientStop { position: 930 / Math.max(1, homeFade.height); color: "white" }
                GradientStop { position: 985 / Math.max(1, homeFade.height); color: "transparent" }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    // ================= pieces =================

    // A cover with rounded corners: the image, else the title on the game's colour; "See all".
    component Cover: Item {
        id: cov
        property var g: null
        property bool all: false
        property bool ring: false
        property real radius: 22
        property string badge: ""
        // The light it casts, its ring.
        FocusGlow {
            z: -1
            on: cov.ring
            tint: cov.g ? Cases.tint(cov.g.platform_slug) : theme.fg
            ringColor: theme.fg
            radius: cov.radius
            motion: root.motion
            source: cov.g ? cov.g.cover : ""
        }
        Rectangle {
            z: -2
            x: 0; y: 16; width: parent.width; height: parent.height
            radius: cov.radius
            color: Qt.rgba(0, 0, 0, 0.45)
            layer.enabled: cov.visible
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 32 }
        }
        Item {
            anchors.fill: parent
            layer.enabled: cov.visible
            layer.effect: MultiEffect { maskEnabled: true; maskSource: covMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
            Rectangle { anchors.fill: parent; color: cov.all ? Qt.rgba(1, 1, 1, 0.1) : cov.g ? theme.tone(cov.g.hue) : theme.surface }
            Text {
                visible: !cov.all && covImg.status !== Image.Ready
                anchors { fill: parent; margins: 18 }
                text: cov.g ? cov.g.name : ""
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignBottom
                color: "#ffffff"
                font { family: theme.displayFont; pixelSize: Math.max(18, Math.round(cov.height / 12)); weight: Font.ExtraBold }
            }
            Image {
                id: covImg
                anchors.fill: parent
                visible: !cov.all
                source: cov.g ? cov.g.cover : ""
                sourceSize.height: 640
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }
            Shine { active: cov.ring; motion: root.motion }
            Column {
                visible: cov.all
                anchors.centerIn: parent
                spacing: 14
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "grid"; size: 48; filled: true; stroke: 1; color: theme.fg }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("See all")
                    color: theme.fg
                    font { family: theme.fontFamily; pixelSize: 19; weight: Font.ExtraBold }
                }
            }
            // Downloading: its progress along the bottom.
            Rectangle {
                visible: !!cov.g && ["queued", "downloading", "verifying", "extracting"].indexOf(cov.g.dl_state) >= 0
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 8
                color: Qt.rgba(0, 0, 0, 0.55)
                Rectangle {
                    height: parent.height
                    width: cov.g && cov.g.dl_total > 0 ? parent.width * cov.g.dl_received / cov.g.dl_total : parent.width * 0.1
                    color: theme.fg
                }
            }
        }
        Rectangle { id: covMask; anchors.fill: parent; radius: cov.radius; visible: false; layer.enabled: true }
        Rectangle {
            visible: cov.badge !== ""
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 16 }
            width: badgeText.implicitWidth + 32; height: 32; radius: 16
            color: Qt.rgba(0.04, 0.04, 0.055, 0.6)
            border { width: 1.5; color: Qt.rgba(1, 1, 1, 0.7) }
            Text {
                id: badgeText
                anchors.centerIn: parent
                text: cov.badge
                color: "#ffffff"
                font { family: theme.fontFamily; pixelSize: 14; weight: Font.ExtraBold }
            }
        }
        Accessible.role: Accessible.Button
        Accessible.name: all ? qsTr("See all") : g ? g.name : ""
    }

    // A collection: a card in its colour (the console's; warm for Favourites, cool for Two players),
    // three of its covers fanned out (wider when selected), its sign (heart, two players, the
    // console's logo), its name and count.
    component Folder: Item {
        id: fo
        property var c
        property bool on: false
        width: 300; height: 230
        scale: on ? 1.05 : 1
        z: on ? 2 : 1
        Behavior on scale { NumberAnimation { duration: 320 * root.motion; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
        Accessible.role: Accessible.Button
        Accessible.name: c.name
        readonly property color hue: c.kind === "fav" ? "#C2405E" : c.kind === "multi" ? "#2E8C9A" : Cases.tint(c.slug)
        FocusGlow { on: fo.on; tint: fo.hue; ringColor: theme.fg; radius: 22; gap: 9; line: 4; motion: root.motion }
        Rectangle {
            anchors.fill: parent
            radius: 22
            clip: true
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: Qt.rgba(fo.hue.r, fo.hue.g, fo.hue.b, fo.on ? 0.72 : 0.42) }
                GradientStop { position: 1; color: Qt.rgba(fo.hue.r * 0.25, fo.hue.g * 0.25, fo.hue.b * 0.25, 0.9) }
            }
            border { width: 1; color: Qt.rgba(1, 1, 1, fo.on ? 0.25 : 0.1) }
            // Three covers fanned out.
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                y: 22
                width: 200; height: 130
                Repeater {
                    model: Math.min(3, fo.c.covers.length)
                    Item {
                        id: fan
                        required property int index
                        readonly property int k: index === 0 ? 0 : index === 1 ? -1 : 1   // the first in the middle
                        readonly property real spread: fo.on ? 1 : 0.6
                        width: 88; height: 120
                        x: (parent.width - width) / 2 + k * 62 * spread
                        y: Math.abs(k) * 10 * spread
                        z: 3 - Math.abs(k)
                        rotation: k * 10 * spread
                        transformOrigin: Item.Bottom
                        Behavior on x { NumberAnimation { duration: 380 * root.motion; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
                        Behavior on rotation { NumberAnimation { duration: 380 * root.motion; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
                        Behavior on y { NumberAnimation { duration: 380 * root.motion; easing.type: Easing.OutCubic } }
                        layer.enabled: fo.visible
                        layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000000"; shadowOpacity: 0.55; shadowBlur: 0.6; shadowVerticalOffset: 6 }
                        Item {
                            anchors.fill: parent
                            layer.enabled: fo.visible
                            layer.effect: MultiEffect { maskEnabled: true; maskSource: fanMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                            Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.3) }
                            Image {
                                anchors.fill: parent
                                source: fo.c.covers[fan.index] || ""
                                sourceSize.height: 240
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }
                        Rectangle { id: fanMask; anchors.fill: parent; radius: 8; visible: false; layer.enabled: true }
                    }
                }
                // Empty: its sign, large.
                Icon {
                    visible: fo.c.covers.length === 0
                    anchors.centerIn: parent
                    name: fo.c.kind === "multi" ? "people" : "heart"
                    size: 64
                    stroke: 2
                    color: Qt.rgba(1, 1, 1, 0.5)
                }
            }
            Shine { active: fo.on; motion: root.motion; strength: 0.2 }
        }
        // Its sign, its name, its count.
        Row {
            x: 18; y: 172
            width: parent.width - 36
            spacing: 10
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: fo.c.kind === "console" ? (signLogo.status === Image.Ready ? 0 : 0) : 26
                height: 26
                visible: fo.c.kind !== "console"
                Icon { anchors.centerIn: parent; name: fo.c.kind === "multi" ? "people" : "heart"; size: 22; filled: fo.c.kind === "fav"; stroke: 2; color: "#ffffff" }
            }
            Image {
                id: signLogo
                visible: fo.c.kind === "console" && status === Image.Ready
                anchors.verticalCenter: parent.verticalCenter
                height: 26
                width: Math.min(150, implicitWidth * 26 / Math.max(1, implicitHeight))
                source: fo.c.kind === "console" ? fo.c.logo || "" : ""
                sourceSize.height: 80
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                layer.enabled: visible
                layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
            }
            Text {
                visible: !signLogo.visible
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 36 - countLabel.implicitWidth - 20
                elide: Text.ElideRight
                text: fo.c.name
                color: "#ffffff"
                font { family: theme.fontFamily; pixelSize: 19; weight: Font.ExtraBold }
            }
        }
        Rectangle {
            anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.top; verticalCenterOffset: 185 }
            width: countLabel.implicitWidth + 20; height: 28; radius: 14
            color: Qt.rgba(0, 0, 0, 0.35)
            Text {
                id: countLabel
                anchors.centerIn: parent
                text: String(fo.c.count)
                color: "#ffffff"
                font { family: theme.fontFamily; pixelSize: 14; weight: Font.ExtraBold }
            }
        }
    }

    // A console of the Store: a slanted card in its colour, wide when selected, with a picture of
    // the console (ScreenScraper's), else three of its games; its logo along the card when narrow.
    component Card: Item {
        id: card
        property var c
        property bool on: false
        property bool lit: false
        readonly property color tint: Cases.tint(c.slug)
        readonly property real k: 0.158      // tan(9°)
        readonly property bool hasPhoto: photo.status === Image.Ready
        width: on ? 640 : 150
        height: 520
        y: on ? -14 : 0
        z: on ? 2 : 1
        Behavior on width { NumberAnimation { duration: 560 * root.motion; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 560 * root.motion; easing.type: Easing.OutCubic } }
        Accessible.role: Accessible.Button
        Accessible.name: c.name
        // The slanted shape (skewed round its middle) with the ring.
        Item {
            anchors.fill: parent
            transform: Matrix4x4 { matrix: Qt.matrix4x4(1, -card.k, 0, card.k * card.height / 2, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1) }
            Rectangle {
                visible: card.lit
                anchors { fill: parent; margins: -10 }
                radius: 26
                color: "transparent"
                border { width: 4; color: theme.fg }
            }
            Item {
                id: face
                anchors.fill: parent
                readonly property real kH: card.tint.hslHue
                readonly property real kS: card.tint.hslSaturation
                layer.enabled: true
                layer.effect: MultiEffect { maskEnabled: true; maskSource: faceMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                // Studio: a seamless backdrop in the console's colour, muted, bending from the
                // wall to the floor under one large soft light from the upper left.
                Rectangle {
                    id: studioBack
                    anchors.fill: parent
                    visible: root.look.card === "studio"
                    readonly property real fl: root.look.floor / 100
                    // A studio grey, just warmed or cooled by the console's colour.
                    function tone(l, k) {
                        const g = Qt.rgba(l * 0.97, l, l * 1.06, 1)
                        return Qt.rgba(g.r + (card.tint.r * l * 1.4 - g.r) * k, g.g + (card.tint.g * l * 1.4 - g.g) * k, g.b + (card.tint.b * l * 1.4 - g.b) * k, 1)
                    }
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.00; color: studioBack.tone(0.20, 0.30) }
                        GradientStop { position: 0.60; color: studioBack.tone(0.105, 0.24) }
                        GradientStop { position: 0.70; color: studioBack.tone(0.09 + 0.08 * studioBack.fl, 0.2) }
                        GradientStop { position: 1.00; color: studioBack.tone(0.045, 0.2) }
                    }
                }
                Shape {
                    anchors.fill: parent
                    visible: root.look.card === "studio"
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeWidth: -1
                        fillGradient: RadialGradient {
                            centerX: face.width * 0.28; centerY: -face.height * 0.12; focalX: centerX; focalY: centerY
                            centerRadius: Math.max(320, face.width * 0.95); focalRadius: 0
                            GradientStop { position: 0; color: Qt.rgba(1, 0.98, 0.95, 0.30 * root.look.key / 50) }
                            GradientStop { position: 0.5; color: Qt.rgba(1, 0.98, 0.95, 0.08 * root.look.key / 50) }
                            GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
                        }
                        PathRectangle { x: 0; y: 0; width: face.width; height: face.height }
                    }
                }
                // Lacquer: the console's colour, deep, glazed, lit from above.
                Rectangle {
                    anchors.fill: parent
                    visible: root.look.card === "lacquer"
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0; color: Qt.hsla(face.kH, Math.min(1, face.kS * 0.9), 0.36, 1) }
                        GradientStop { position: 0.55; color: Qt.hsla(face.kH, Math.min(1, face.kS * 0.85), 0.17, 1) }
                        GradientStop { position: 1; color: Qt.hsla(face.kH, face.kS * 0.6, 0.06, 1) }
                    }
                    Shape {
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeWidth: -1
                            fillGradient: RadialGradient {
                                centerX: face.width / 2; centerY: -40; focalX: face.width / 2; focalY: -40
                                centerRadius: Math.max(260, face.width * 0.75); focalRadius: 0
                                GradientStop { position: 0; color: Qt.rgba(1, 0.96, 0.9, 0.34 * root.look.key / 50) }
                                GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
                            }
                            PathRectangle { x: 0; y: 0; width: face.width; height: face.height }
                        }
                    }
                }
                // Glass: a dark, tinted pane the room's colour shows through.
                Rectangle {
                    anchors.fill: parent
                    visible: root.look.card === "glass"
                    color: Qt.hsla(face.kH, face.kS * 0.5, 0.14, 0.55)
                    Rectangle {
                        anchors.fill: parent
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.10 * root.look.key / 50) }
                            GradientStop { position: 0.4; color: Qt.rgba(1, 1, 1, 0) }
                        }
                    }
                }
                // Narrow: in the shade.
                Rectangle {
                    anchors.fill: parent
                    color: "#000000"
                    opacity: card.on ? 0 : 0.42
                    Behavior on opacity { NumberAnimation { duration: 400 * root.motion } }
                }
            }
            Rectangle {
                id: faceMask
                anchors.fill: parent
                radius: 16
                visible: false
                layer.enabled: true
            }
            // Its edge: a hairline, lighter on top where the light comes from.
            Rectangle {
                anchors.fill: parent
                radius: 16
                color: "transparent"
                border { width: 1; color: Qt.rgba(1, 1, 1, root.look.card === "glass" ? 0.22 : 0.09) }
            }
        }
        // Where it stands: a soft shadow on the floor of the card, under the console (a round
        // shade flattened into an ellipse).
        Shape {
            id: standShade
            readonly property real w: Math.max(120, photo.paintedWidth * 0.95)
            anchors.horizontalCenter: parent.horizontalCenter
            y: photo.y + photo.height / 2 + photo.paintedHeight / 2 - 4 - w / 2
            width: w; height: w
            opacity: photo.opacity * (0.8 + 0.3 * (photo.bob / 10)) * root.look.shadow / 60
            visible: opacity > 0.01
            preferredRendererType: Shape.CurveRenderer
            transform: Scale { origin.x: standShade.w / 2; origin.y: standShade.w / 2; yScale: 40 / Math.max(1, standShade.w) }
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: standShade.w / 2; centerY: standShade.w / 2; focalX: centerX; focalY: centerY
                    centerRadius: standShade.w / 2; focalRadius: 0
                    GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.75) }
                    GradientStop { position: 0.6; color: Qt.rgba(0, 0, 0, 0.25) }
                    GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0) }
                }
                PathRectangle { x: 0; y: 0; width: standShade.w; height: standShade.w }
            }
        }
        // The console itself, upright, arriving from the side you come from.
        Image {
            id: photo
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 34 }
            width: 520; height: 300
            source: card.c.photo || ""
            sourceSize.height: 600
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            opacity: card.on && status === Image.Ready ? 1 : 0
            visible: opacity > 0
            scale: card.on ? 1 : 0.85
            Behavior on opacity { NumberAnimation { duration: 450 * root.motion } }
            Behavior on scale { NumberAnimation { duration: 560 * root.motion; easing.type: Easing.OutCubic } }
            layer.enabled: visible
            layer.effect: MultiEffect { shadowEnabled: true; shadowColor: "#000000"; shadowOpacity: 0.4; shadowBlur: 1.0; shadowVerticalOffset: 10 }
            // Floating, slowly.
            property real bob
            SequentialAnimation on bob {
                loops: Animation.Infinite
                running: card.on && root.motion > 0.5
                NumberAnimation { from: 0; to: -10; duration: 2600; easing.type: Easing.InOutSine }
                NumberAnimation { from: -10; to: 0; duration: 2600; easing.type: Easing.InOutSine }
            }
            transform: Translate {
                y: photo.bob
                x: card.on ? 0 : root.wallDir * 90
                Behavior on x { NumberAnimation { duration: 650 * root.motion; easing.type: Easing.OutCubic } }
            }
        }
        // No picture: three of its games.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 50
            spacing: 14
            opacity: card.on && !card.hasPhoto ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 400 * root.motion } }
            Repeater {
                model: card.c.covers
                Item {
                    required property string modelData
                    width: 170; height: 240
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: cardMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.25) }
                    Image {
                        anchors.fill: parent
                        source: modelData
                        sourceSize.height: 480
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Rectangle { id: cardMask; anchors.fill: parent; radius: 10; visible: false; layer.enabled: true }
                }
            }
        }
        // Its logo in white: across the foot when wide, along the card when narrow.
        Item {
            id: wideLogo
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 56 }
            width: 400; height: 92
            opacity: card.on ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 350 * root.motion } }
            Logo { anchors.fill: parent; c: card.c; size: 54 }
        }
        Item {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 20
            width: card.height * 0.62; height: 70
            rotation: -81
            opacity: card.on ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 350 * root.motion } }
            Logo { anchors.fill: parent; c: card.c; size: 30 }
        }
    }
    component Logo: Item {
        id: lg
        property var c
        property real size: 30
        Image {
            id: lgImg
            anchors.fill: parent
            visible: status === Image.Ready
            source: lg.c.logo || ""
            sourceSize.height: 240
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            layer.enabled: visible
            layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
        }
        Text {
            visible: !lgImg.visible
            anchors.fill: parent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            fontSizeMode: Text.Fit
            minimumPixelSize: 14
            text: lg.c.name
            color: "#ffffff"
            font { family: theme.displayFont; pixelSize: lg.size; weight: Font.ExtraBold; letterSpacing: -0.6 }
        }
    }

    // A cover of a folder's grid, its name and a line under it.
    component Tile: Item {
        id: tile
        property var t
        property var g
        property bool cur: false
        property real shift: 0
        x: t.x; y: t.y + shift
        width: t.w; height: t.h + (t.caption ? 52 : 0)
        z: cur ? 10 : 1
        readonly property bool inView: y + height + track.y > -300 && y + track.y < viewport.height + 300
        property bool seen: false
        onInViewChanged: if (inView) seen = true
        Component.onCompleted: if (inView) seen = true
        visible: inView
        transform: Scale {
            origin.x: tile.width / 2; origin.y: tile.t.h / 2
            xScale: tile.cur ? 1.05 : 1
            yScale: xScale
            Behavior on xScale { NumberAnimation { duration: 280 * root.motion; easing.type: Easing.OutCubic } }
        }
        Accessible.role: Accessible.Button
        Accessible.name: g ? g.name : ""
        Item {
            width: tile.width; height: tile.t.h
            FocusGlow { on: tile.cur; tint: tile.g ? Cases.tint(tile.g.platform_slug) : theme.fg; ringColor: theme.fg; radius: 12; gap: 9; line: 4; motion: root.motion; source: tile.g ? tile.g.cover : "" }
        }
        Item {
            width: tile.width; height: tile.t.h
            layer.enabled: tile.visible
            layer.effect: MultiEffect { maskEnabled: true; maskSource: tileMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
            Rectangle { anchors.fill: parent; color: tile.g ? theme.tone(tile.g.hue) : theme.surface }
            Text {
                visible: tileImg.status !== Image.Ready
                anchors { fill: parent; margins: 14 }
                text: tile.g ? tile.g.name : ""
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignBottom
                color: "#ffffff"
                font { family: theme.displayFont; pixelSize: 19; weight: Font.ExtraBold }
            }
            Shine { z: 2; active: tile.cur; motion: root.motion }
            Image {
                id: tileImg
                anchors.fill: parent
                source: tile.seen && tile.g ? tile.g.cover : ""
                sourceSize.height: Math.min(900, Math.round(tile.t.h * 1.6))
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }
            Rectangle {
                visible: !!tile.g && ["queued", "downloading", "verifying", "extracting"].indexOf(tile.g.dl_state) >= 0
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 8
                color: Qt.rgba(0, 0, 0, 0.55)
                Rectangle {
                    height: parent.height
                    width: tile.g && tile.g.dl_total > 0 ? parent.width * tile.g.dl_received / tile.g.dl_total : parent.width * 0.1
                    color: theme.fg
                }
            }
        }
        Rectangle { id: tileMask; width: tile.width; height: tile.t.h; radius: 12; visible: false; layer.enabled: true }
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
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.ExtraBold }
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
}
