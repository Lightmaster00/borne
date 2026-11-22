// The library, as a console's home: over the selected game's art (Ambience), a row of the games
// played lately (the one selected grows, its name and details under the row) and, below, the
// collections as folders (Favourites, Two players, one per console). The Store shows the server's
// consoles as slanted cards: the one selected opens wide on three of its games. A collection, "See
// all" or a console of the Store opens as a glass panel over the home: a grid of its games.
//
// Everything here is drawn from Main's state (zone, indexes, folder); Main handles the input.
import QtQuick
import QtQuick.Effects
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
    readonly property bool folderOpen: folder !== null
    readonly property real motion: theme ? theme.motion : 1

    function gameOf(rom) { const i = indexByRom[rom]; return i === undefined ? null : rows[i] || null }
    readonly property var rowGames: recents.map(r => gameOf(r)).filter(g => !!g)
    readonly property int allIndex: rowGames.length          // the "See all" tile
    readonly property var curGame: rowIndex < rowGames.length ? rowGames[rowIndex] : null
    readonly property var curTile: layout.tiles[current] || null
    readonly property var folderGame: curTile ? rows[curTile.idx] || null : null

    // The folder's room (Main lays its grid out to it).
    readonly property real panelX: 230
    readonly property real panelW: width - panelX - 150
    readonly property real panelH: Math.min(790, height - 150 - 140)
    readonly property real gridPad: 16
    readonly property real folderWidth: panelW - 60 - 2 * gridPad
    readonly property real folderHeight: panelH - 116 - 80
    readonly property int folderTileH: Math.round(Math.max(180, Math.min(270, (folderWidth - 5 * 40) / (6 * 0.72))))

    // ================= the home =================
    Item {
        id: home
        anchors.fill: parent
        opacity: root.onHome ? 1 : 0
        visible: opacity > 0
        x: root.onHome ? 0 : -120
        Behavior on opacity { NumberAnimation { duration: 450 * root.motion; easing.type: Easing.InOutQuad } }
        Behavior on x { NumberAnimation { duration: 600 * root.motion; easing.type: Easing.OutCubic } }

        Item {
            id: homeContent
            width: parent.width; height: parent.height
            // Down to the collections: the page rises, the row stays in sight above.
            y: root.zone === "shelf" ? -300 : 0
            Behavior on y { NumberAnimation { duration: 650 * root.motion; easing.type: Easing.OutCubic } }

            Text {
                x: root.leftX; y: 250
                text: qsTr("Recently played")
                color: Qt.rgba(1, 1, 1, 0.75)
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
            }

            // ---------- the row ----------
            Item {
                id: rowView
                x: 172; y: 286
                width: parent.width - x - 14; height: 460
                clip: true
                opacity: root.zone === "shelf" ? 0.4 : 1
                Behavior on opacity { NumberAnimation { duration: 450 * root.motion } }
                readonly property real coverH: 340
                readonly property bool lit: root.zone === "row" && root.onHome && !root.folderOpen
                // Each tile's place: the selected one large (larger while the row has the focus).
                readonly property var geom: {
                    const out = []
                    let x = 0
                    const n = root.rowGames.length + 1
                    for (let k = 0; k < n; k++) {
                        const g = root.rowGames[k]
                        const ratio = g ? Math.max(0.72, Math.min(1.25, g.cover_ar >= 0.45 && g.cover_ar <= 2.2 ? g.cover_ar : Cases.ratio(g.platform_slug))) : 0.8
                        const hh = k === root.rowIndex ? (lit ? coverH + 40 : coverH) : Math.round(coverH * 0.78)
                        const w = Math.round(hh * ratio)
                        out.push({ x: x, y: Math.round((coverH + 40 - hh) / 2), w: w, h: hh })
                        x += w + 26
                    }
                    return out
                }
                Item {
                    id: rowTrack
                    x: 24 - Math.max(0, (rowView.geom[root.rowIndex] ? rowView.geom[root.rowIndex].x : 0) - 40)
                    y: 10
                    Behavior on x { NumberAnimation { duration: 520 * root.motion; easing.type: Easing.OutCubic } }
                    Repeater {
                        model: root.rowGames.length + 1
                        Cover {
                            required property int index
                            readonly property var r: rowView.geom[index] || { x: 0, y: 0, w: 0, h: 0 }
                            g: index < root.rowGames.length ? root.rowGames[index] : null
                            all: index === root.allIndex
                            x: r.x; y: r.y; width: r.w; height: r.h
                            radius: 26
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
            Column {
                x: root.leftX; y: 716
                width: Math.min(1300, parent.width - root.leftX - 140)
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

            // ---------- the collections ----------
            Text {
                x: root.leftX; y: 896
                text: qsTr("Collections")
                color: Qt.rgba(1, 1, 1, 0.75)
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
            }
            Item {
                x: root.leftX - 20; y: 920
                width: parent.width - x - 14; height: 280
                clip: true
                Row {
                    x: 20 - Math.max(0, (root.shelfIndex + 1) * 276 - (parent.width - 160))
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
            x: root.leftX; y: 226
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
            x: 150; y: 330
            width: parent.width - x - 14; height: 540
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
        Column {
            x: root.leftX; y: 872
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
        x: root.panelX; y: 150
        width: root.panelW; height: root.panelH
        radius: 40
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
                y: viewport.targetY + 20
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

    // ================= pieces =================

    // A cover with rounded corners: the image, else the title on the game's colour; "See all".
    component Cover: Item {
        id: cov
        property var g: null
        property bool all: false
        property bool ring: false
        property real radius: 22
        property string badge: ""
        // Ring: dark gap, then light.
        Rectangle {
            visible: cov.ring
            anchors { fill: parent; margins: -11 }
            radius: cov.radius + 11
            color: "transparent"
            border { width: 5; color: theme.fg }
        }
        Rectangle {
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

    // A collection: four of its covers and its name.
    component Folder: Item {
        id: fo
        property var c
        property bool on: false
        width: 250; height: 214
        scale: on ? 1.06 : 1
        z: on ? 2 : 1
        Behavior on scale { NumberAnimation { duration: 300 * root.motion; easing.type: Easing.OutCubic } }
        Accessible.role: Accessible.Button
        Accessible.name: c.name
        Rectangle {
            visible: fo.on
            anchors { fill: parent; margins: -9 }
            radius: 37
            color: "transparent"
            border { width: 4; color: theme.fg }
        }
        Rectangle {
            anchors.fill: parent
            radius: 28
            color: Qt.rgba(1, 1, 1, fo.on ? 0.16 : 0.1)
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.1) }
        }
        Grid {
            x: 16; y: 16
            columns: 2; spacing: 8
            Repeater {
                model: 4
                Item {
                    required property int index
                    width: 105; height: 59
                    layer.enabled: fo.visible
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: miniMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                    Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.08) }
                    Image {
                        anchors.fill: parent
                        source: fo.c.covers[index] || ""
                        sourceSize.width: 220
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Rectangle { id: miniMask; anchors.fill: parent; radius: 12; visible: false; layer.enabled: true }
                }
            }
        }
        Text {
            x: 18; y: 160
            width: parent.width - 36 - countLabel.implicitWidth - 8
            elide: Text.ElideRight
            text: fo.c.name
            color: theme.fg
            font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
        }
        Text {
            id: countLabel
            anchors { right: parent.right; rightMargin: 18 }
            y: 163
            text: String(fo.c.count)
            color: Qt.rgba(1, 1, 1, 0.65)
            font { family: theme.fontFamily; pixelSize: 14; weight: Font.Bold }
        }
    }

    // A console of the Store: a slanted card in its colour, wide when selected.
    component Card: Item {
        id: card
        property var c
        property bool on: false
        property bool lit: false
        readonly property color tint: Cases.tint(c.slug)
        readonly property real k: 0.158      // tan(9°)
        width: on ? 560 : 150
        height: 470
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
                radius: 36
                color: "transparent"
                border { width: 4; color: theme.fg }
            }
            Rectangle {
                anchors.fill: parent
                radius: 26
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0; color: Qt.lighter(card.tint, 1.1) }
                    GradientStop { position: 1; color: Qt.darker(card.tint, 2.6) }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 26
                    color: "#000000"
                    opacity: card.on ? 0 : 0.28
                    Behavior on opacity { NumberAnimation { duration: 400 * root.motion } }
                }
            }
        }
        // Three of its games, upright.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 40
            spacing: 14
            opacity: card.on ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 400 * root.motion } }
            Repeater {
                model: card.c.covers
                Item {
                    required property string modelData
                    width: 150; height: 210
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: cardMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.25) }
                    Image {
                        anchors.fill: parent
                        source: modelData
                        sourceSize.height: 420
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                    }
                    Rectangle { id: cardMask; anchors.fill: parent; radius: 16; visible: false; layer.enabled: true }
                }
            }
        }
        // The console's logo (white), else its name.
        Item {
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 70 }
            width: card.on ? 380 : 120
            height: 96
            Behavior on width { NumberAnimation { duration: 560 * root.motion; easing.type: Easing.OutCubic } }
            Image {
                id: cardLogo
                anchors.fill: parent
                visible: status === Image.Ready
                source: card.c.logo || ""
                sourceSize.height: 240
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                layer.enabled: visible
                layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
            }
            Text {
                visible: !cardLogo.visible
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                fontSizeMode: Text.Fit
                minimumPixelSize: 16
                wrapMode: Text.WordWrap
                text: card.c.name
                color: "#ffffff"
                font { family: theme.displayFont; pixelSize: card.on ? 54 : 24; weight: Font.ExtraBold; letterSpacing: -1 }
            }
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
            xScale: tile.cur ? 1.08 : 1
            yScale: xScale
            Behavior on xScale { NumberAnimation { duration: 280 * root.motion; easing.type: Easing.OutCubic } }
        }
        Accessible.role: Accessible.Button
        Accessible.name: g ? g.name : ""
        Rectangle {
            visible: tile.cur
            x: -9; y: -9; width: tile.width + 18; height: tile.t.h + 18
            radius: 29
            color: "transparent"
            border { width: 4; color: theme.fg }
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
        Rectangle { id: tileMask; width: tile.width; height: tile.t.h; radius: 20; visible: false; layer.enabled: true }
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
