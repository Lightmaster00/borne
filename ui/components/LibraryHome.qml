// The library: two tabs, My library (games ready to play here) and the Store (the server's other
// games), the games in groups the order explains (Resume, This week, A – C, the 1990s…; the Store
// by console), on two rows that scroll sideways to keep the selected cover in view. Each cover
// keeps its own proportions at a common height. Everything is laid out by Shelf.js.
import QtQuick
import QtQuick.Effects
import "Cases.js" as Cases

Item {
    id: root
    property QtObject theme
    property var rows: []             // every game (library rows)
    property var layout: ({ tiles: [], groups: [], total: 0, count: 0 })
    property int current: 0           // selected tile
    property string tab: "home"       // "home" | "store"
    property string subtitle: ""
    property string filterLabel: ""
    property string sortLabel: ""
    property bool filtered: false     // one console shown: no console badge on the covers
    property string emptyText: ""
    property string profileName: ""
    property string clockText: ""
    property string downloadsText: ""  // "" hides the downloads pill
    property real downloadsProgress: -1
    property string heroAction: ""
    property var keyLabel: function (a) { return a }


    readonly property var curTile: layout.tiles[current] || null
    readonly property real shelfTop: 214
    readonly property real headerH: 60          // group title above the covers
    // The height the two rows of covers have (Shelf.js sizes the covers to it).
    readonly property real shelfHeight: viewport.height - headerH

    // ---------- header ----------
    Item {
        id: header
        x: 96; y: 64
        width: parent.width - 192; height: 110
        Column {
            spacing: 12
            Row {
                spacing: 22
                KeyCap { anchors.verticalCenter: parent.verticalCenter; text: root.keyLabel("lb") }
                TabTitle { text: qsTr("My library"); on: root.tab === "home" }
                TabTitle { text: qsTr("Store"); on: root.tab === "store" }
                KeyCap { anchors.verticalCenter: parent.verticalCenter; text: root.keyLabel("rb") }
            }
            Text {
                text: root.subtitle
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.DemiBold }
            }
        }
        Row {
            anchors { right: parent.right; top: parent.top; topMargin: 4 }
            spacing: 12
            Pill { key: root.keyLabel("x"); icon: "filter"; text: root.filterLabel }
            Pill { key: root.keyLabel("y"); icon: "sort"; text: root.sortLabel }
            Pill {
                visible: root.downloadsText !== ""
                key: root.keyLabel("r3"); icon: "download"; text: root.downloadsText
                progress: root.downloadsProgress
            }
            Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 1; height: 32; color: Qt.rgba(1, 1, 1, 0.16) }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 44; height: 44; radius: 22
                color: theme.fg
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Profile: %1").arg(root.profileName)
                Text {
                    anchors.centerIn: parent
                    text: root.profileName.charAt(0).toUpperCase()
                    color: theme.bg
                    font { family: theme.fontFamily; pixelSize: 19; weight: Font.ExtraBold }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.clockText !== ""
                text: root.clockText
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 22; weight: Font.Bold; features: { "tnum": 1 } }
            }
        }
    }

    // ---------- the shelf ----------
    Item {
        id: viewport
        x: 96; y: root.shelfTop
        width: parent.width - 96; height: parent.height - root.shelfTop - 84
        // Scrolls only when the selected cover would leave the view (a margin kept on each side),
        // never past the ends; back to the start when the shelf changes.
        property real target: 0
        readonly property real room: width - 96
        function follow() {
            const t = root.curTile
            if (!t) { target = 0; return }
            const pad = Math.min(260, room * 0.2)
            let x = -target
            if (t.x + t.w + pad > x + room) x = t.x + t.w + pad - room
            if (t.x - pad < x) x = t.x - pad
            target = -Math.max(0, Math.min(x, root.layout.total - room))
        }
        Connections {
            target: root
            function onCurTileChanged() { viewport.follow() }
            function onLayoutChanged() { viewport.target = 0; viewport.follow() }
        }
        Item {
            id: track
            x: viewport.target
            Behavior on x { NumberAnimation { duration: 620 * theme.motion; easing.type: Easing.OutCubic } }

            Repeater {
                model: root.layout.groups
                Item {
                    required property var modelData
                    x: modelData.x; y: 0
                    width: modelData.w; height: root.headerH
                    visible: x + width + track.x > -200 && x + track.x < viewport.width + 200
                    Row {
                        spacing: 12
                        Rectangle {
                            visible: modelData.slug !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18; height: 18; radius: 6
                            color: Cases.tint(modelData.slug)
                        }
                        Text {
                            text: modelData.label
                            color: theme.fg
                            font { family: theme.displayFont; pixelSize: 27; weight: Font.ExtraBold }
                        }
                        Text {
                            anchors.baseline: parent.children[1].baseline
                            text: modelData.count
                            color: theme.fgFaint
                            font { family: theme.fontFamily; pixelSize: 17; weight: Font.Bold }
                        }
                    }
                    Rectangle {
                        y: 46; width: parent.width; height: 2; radius: 1
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0.35) }
                            GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
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

    // ---------- a cover ----------
    component Tile: Item {
        id: tile
        property var t
        property var g
        property bool cur: false
        x: t.x; y: t.y + root.headerH
        width: t.w; height: t.hero ? t.h : t.h + 52
        z: cur ? 10 : 1
        readonly property bool inView: x + width + track.x > -300 && x + track.x < viewport.width + 300
        // Covers load as they come near, and stay loaded.
        property bool seen: false
        onInViewChanged: if (inView) seen = true
        Component.onCompleted: if (inView) seen = true
        visible: inView
        readonly property color tint: g ? Cases.tint(g.platform_slug) : theme.accent
        readonly property bool busy: !!g && ["queued", "downloading", "verifying", "extracting"].indexOf(g.dl_state) >= 0
        transform: [
            Scale {
                origin.x: tile.width / 2; origin.y: tile.t.h
                xScale: tile.cur ? (tile.t.hero ? 1.03 : 1.08) : 1
                yScale: xScale
                Behavior on xScale { NumberAnimation { duration: 460 * theme.motion; easing.type: Easing.OutBack; easing.overshoot: 2.2 } }
            },
            Translate {
                y: tile.cur ? -10 : 0
                Behavior on y { NumberAnimation { duration: 460 * theme.motion; easing.type: Easing.OutBack; easing.overshoot: 2.2 } }
            }
        ]
        Accessible.role: Accessible.Button
        Accessible.name: g ? g.name : ""

        // The selected cover's glow, in its console's colour, breathing slowly.
        Rectangle {
            visible: tile.cur
            x: -20; y: -20; width: tile.width + 40; height: tile.t.h + 40
            radius: height / 2
            color: tile.tint
            layer.enabled: visible
            layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48 }
            SequentialAnimation on opacity {
                running: tile.cur && theme.motion > 0.5
                loops: Animation.Infinite
                NumberAnimation { from: 0.35; to: 0.75; duration: 1700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.75; to: 0.35; duration: 1700; easing.type: Easing.InOutSine }
            }
        }
        // The ring round the selected cover.
        Rectangle {
            visible: tile.cur
            x: -8; y: -8; width: tile.width + 16; height: tile.t.h + 16
            radius: art.r + 8
            color: "transparent"
            border { width: 4; color: theme.fg }
        }
        Item {
            id: art
            readonly property real r: tile.t.hero ? 32 : 22
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
                visible: cover.status !== Image.Ready && !tile.t.hero
                anchors { fill: parent; margins: 14 }
                text: tile.g ? tile.g.name : ""
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignHCenter
                color: "#ffffff"
                font { family: theme.displayFont; pixelSize: 20; weight: Font.ExtraBold }
            }
            Image {
                id: cover
                anchors.fill: parent
                source: tile.seen && tile.g ? (tile.t.hero && tile.g.art_kinds.indexOf(",fanart,") >= 0 ? tile.g.art + "fanart" : tile.g.cover) : ""
                sourceSize.height: tile.t.hero ? 900 : 520
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
            }
            // The console, when several are mixed.
            Rectangle {
                visible: !root.filtered && !tile.t.hero && !!tile.g
                x: 10; y: 10
                width: badge.implicitWidth + 34; height: 28; radius: 14
                color: Qt.rgba(0, 0, 0, 0.55)
                Rectangle { x: 5; y: 5; width: 18; height: 18; radius: 6; color: tile.tint }
                Text {
                    id: badge
                    x: 28; anchors.verticalCenter: parent.verticalCenter
                    text: tile.g ? (tile.g.platform_short || tile.g.platform_name) : ""
                    color: "#ffffff"
                    font { family: theme.fontFamily; pixelSize: 12; weight: Font.ExtraBold }
                }
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
            // The hero: a darkening, what it is, and the button.
            Rectangle {
                visible: tile.t.hero
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: parent.height * 0.62
                gradient: Gradient {
                    GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
                    GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.82) }
                }
            }
            Column {
                visible: tile.t.hero
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 30 }
                spacing: 12
                Text {
                    width: parent.width
                    text: tile.g ? tile.g.name : ""
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    color: "#ffffff"
                    font { family: theme.displayFont; pixelSize: 48; weight: Font.ExtraBold }
                    lineHeight: 0.95
                }
                Text {
                    text: tile.t.sub
                    color: Qt.rgba(1, 1, 1, 0.82)
                    font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
                }
                Rectangle {
                    visible: root.heroAction !== ""
                    width: heroRow.implicitWidth + 30; height: 52; radius: 26
                    color: "#F3F1EE"
                    Row {
                        id: heroRow
                        anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                        spacing: 10
                        Rectangle {
                            width: 36; height: 36; radius: 18; color: "#121216"
                            Text { anchors.centerIn: parent; text: root.keyLabel("a"); color: "#F3F1EE"; font { family: theme.fontFamily; pixelSize: 14; weight: Font.ExtraBold } }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: root.heroAction; color: "#121216"; font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold } }
                    }
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
            visible: !tile.t.hero
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
        font { family: theme.displayFont; pixelSize: 52; weight: Font.ExtraBold; letterSpacing: -1.5 }
        Accessible.role: Accessible.PageTab
        Accessible.name: text
    }

    component KeyCap: Rectangle {
        property string text: ""
        width: capText.implicitWidth + 16; height: 26; radius: 8
        color: "transparent"
        border { width: 1.5; color: Qt.rgba(1, 1, 1, 0.5) }
        Text {
            id: capText
            anchors.centerIn: parent
            text: parent.text
            color: Qt.rgba(1, 1, 1, 0.8)
            font { family: theme.fontFamily; pixelSize: 13; weight: Font.ExtraBold }
        }
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
            Rectangle {
                width: Math.max(36, keyText.implicitWidth + 16); height: 36; radius: 18
                color: theme.fg
                Text { id: keyText; anchors.centerIn: parent; text: pill.key; color: theme.bg; font { family: theme.fontFamily; pixelSize: 14; weight: Font.ExtraBold } }
            }
            Icon { anchors.verticalCenter: parent.verticalCenter; name: pill.icon; size: 20; stroke: 2.4; color: theme.fg }
            Text {
                id: pillText
                anchors.verticalCenter: parent.verticalCenter
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 18; weight: Font.ExtraBold }
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
