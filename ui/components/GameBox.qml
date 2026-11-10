// One game box, drawn as a physical case: the cover under clear plastic (rim, gloss, a sharp
// light along the top edge), spines in dark plastic with a band in the console's color and the
// title, a soft contact shadow and a faint reflection on the floor. The box takes the shape of
// its cover: portrait for most consoles, wider and lower for landscape boxes.
// Every face is a flat item drawn through BoxShelf.faceMatrix.
import QtQuick
import QtQuick.Shapes

Item {
    id: box
    property QtObject theme
    property Item stage
    property var game: null
    property var place: ({ x: 0, y: 0, z: 0, ang: 0 })
    property bool current: false
    property bool pointerActive: false
    signal clicked()

    // Shape from the cover's proportions (portrait 2:3 until the cover is loaded).
    readonly property real aspect: cover.status === Image.Ready && cover.implicitHeight > 0
                                   ? Math.max(0.55, Math.min(1.45, cover.implicitWidth / cover.implicitHeight)) : 0.68
    readonly property real bh: aspect > 1 ? Math.min(stage.boxH, 400 / aspect) : stage.boxH
    readonly property real bw: bh * aspect
    readonly property real bd: stage.boxD
    readonly property var dims: ({ w: bw, h: bh, d: bd })

    readonly property real frontFacing: stage.facing(place, "front")
    readonly property real leftFacing: stage.facing(place, "left")
    readonly property real rightFacing: stage.facing(place, "right")
    readonly property color tone: theme.tone(game ? game.hue : 0)
    readonly property string dl: game && game.dl_state ? game.dl_state : ""
    readonly property bool busy: dl === "queued" || dl === "downloading" || dl === "verifying" || dl === "extracting"
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

    // Console colors for the spine band (the rest of the case is dark plastic).
    readonly property color band: {
        const s = game ? (game.platform_slug || "") : ""
        const map = { "switch": "#e60012", "ngc": "#5b4b8a", "wii": "#d9dde3", "wiiu": "#1e90c8", "n64": "#2b2b30",
                      "snes": "#6d5f8a", "nes": "#b7b7bd", "gb": "#8a8f6a", "gbc": "#7a5cc0", "gba": "#4b3f9a", "nds": "#c0c4cc",
                      "3ds": "#c8102e", "ps": "#2a2a30", "psx": "#2a2a30", "ps2": "#1c3a8a", "ps3": "#202024", "psp": "#1b1b1f",
                      "genesis": "#1a1a1e", "sms": "#c4161c", "saturn": "#2b2b33", "dc": "#e8e8ec", "arcade": "#d4a017" }
        return map[s] || Qt.darker(tone, 1.2)
    }

    // ---------- contact shadow on the floor ----------
    Item {
        width: box.bw + 120; height: box.bd + 140
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, "shadow", false, box.dims) }
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: (box.bw + 120) / 2; centerY: (box.bd + 140) / 2
                    focalX: centerX; focalY: centerY
                    centerRadius: (box.bw + 120) / 2; focalRadius: 0
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
                    GradientStop { position: 0.6; color: Qt.rgba(0, 0, 0, 0.22) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                PathRectangle { x: 0; y: 0; width: box.bw + 120; height: box.bd + 140 }
            }
        }
    }

    // ---------- reflection ----------
    Item {
        width: box.bw; height: box.bh
        visible: box.frontFacing > 0.05
        opacity: 0.08 * box.frontFacing
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, "front", true, box.dims) }
        Image {
            anchors.fill: parent
            source: cover.source
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(240, 360)
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#0c0d10" }
                GradientStop { position: 0.5; color: Qt.rgba(0.047, 0.051, 0.063, 0.85) }
                GradientStop { position: 1.0; color: Qt.rgba(0.047, 0.051, 0.063, 0.2) }
            }
        }
    }

    // ---------- spines ----------
    component Spine: Item {
        id: sp
        property string side: "left"
        property real facingValue: 0
        width: box.bd; height: box.bh
        visible: facingValue > 0.02
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, sp.side, false, box.dims) }
        // Dark plastic, lit along its length.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "#101114" }
                GradientStop { position: 0.45; color: "#1d1f24" }
                GradientStop { position: 1.0; color: "#121317" }
            }
        }
        // Console band at the top.
        Rectangle { width: parent.width; height: Math.min(64, box.bh * 0.16); color: box.band }
        Text {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: Math.min(64, box.bh * 0.16) / 2
            width: box.bh - Math.min(64, box.bh * 0.16) - 30
            height: box.bd
            rotation: sp.side === "left" ? -90 : 90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            color: "#e8eaef"
            font { family: box.theme.fontFamily; pixelSize: Math.min(15, box.bd * 0.45); weight: Font.Bold; letterSpacing: 0.5 }
        }
        // Edges catching the light.
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: Qt.rgba(1, 1, 1, 0.16) }
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Qt.rgba(1, 1, 1, 0.08) }
        // Turned away: darker.
        Rectangle { anchors.fill: parent; color: "black"; opacity: Math.max(0, 0.6 - sp.facingValue * 0.55) }
    }
    Spine { side: "left"; facingValue: box.leftFacing }
    Spine { side: "right"; facingValue: box.rightFacing }

    // ---------- front ----------
    Item {
        id: front
        width: box.bw; height: box.bh
        visible: box.frontFacing > 0.02
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, "front", false, box.dims) }

        // Clear-plastic rim around the printed cover.
        Rectangle { anchors.fill: parent; radius: 5; color: "#1a1c21" }
        Item {
            id: art
            anchors { fill: parent; margins: 3 }
            clip: true
            Rectangle { anchors.fill: parent; color: box.tone }
            Text {
                visible: cover.status !== Image.Ready
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 18 }
                text: box.game ? box.game.name : ""
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
                color: box.theme.fg
                font { family: box.theme.displayFont; pixelSize: 28; weight: Font.ExtraBold }
            }
            Image {
                id: cover
                anchors.fill: parent
                source: box.game && box.game.cover ? box.game.cover : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(420, 620)
            }
        }
        // Plastic gloss: a broad soft reflection that slides as the box turns, and a sharp light
        // along the top edge.
        Rectangle {
            anchors { fill: parent; margins: 3 }
            opacity: 0.22
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: Math.max(0, Math.min(1, 0.05 + box.place.ang / 150)); color: "transparent" }
                GradientStop { position: Math.max(0, Math.min(1, 0.22 + box.place.ang / 150)); color: Qt.rgba(1, 1, 1, 0.55) }
                GradientStop { position: Math.max(0, Math.min(1, 0.42 + box.place.ang / 150)); color: "transparent" }
            }
        }
        Rectangle {
            anchors { fill: parent; margins: 3 }
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
                GradientStop { position: 0.25; color: "transparent" }
                GradientStop { position: 0.85; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.18) }
            }
        }
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 4; rightMargin: 4 } height: 1; color: Qt.rgba(1, 1, 1, 0.45) }
        Rectangle { anchors.fill: parent; radius: 5; color: "transparent"; border { width: 1; color: Qt.rgba(1, 1, 1, 0.14) } }

        // State: downloading bar, installed / mounted / failed mark.
        Rectangle {
            visible: box.busy
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 16 }
            height: 5; radius: 2.5
            color: Qt.rgba(0, 0, 0, 0.45)
            Rectangle { width: parent.width * box.progress; height: parent.height; radius: 2.5; color: box.theme.fg }
        }
        Rectangle {
            readonly property bool installed: !box.busy && box.game && box.game.local_state === "local"
            readonly property bool mounted: !box.busy && box.game && box.game.linked && !installed
            readonly property bool broken: !box.busy && (box.dl === "failed" || (box.game && box.game.local_state === "missing"))
            visible: installed || mounted || broken
            anchors { right: parent.right; top: parent.top; margins: 12 }
            width: 28; height: 28; radius: 14
            color: broken ? box.theme.bad : Qt.rgba(0.05, 0.05, 0.07, 0.75)
            border { width: broken ? 0 : 1; color: Qt.rgba(1, 1, 1, 0.3) }
            Icon { anchors.centerIn: parent; size: 14; stroke: 3.2; name: parent.installed ? "check" : parent.mounted ? "link" : "alert"; color: parent.broken ? box.theme.bg : box.theme.fg }
        }

        // Turned away: darker.
        Rectangle { anchors.fill: parent; color: "black"; opacity: Math.max(0, 0.62 - box.frontFacing * 0.62) }

        // Selection: a fine white line around the box.
        Rectangle {
            anchors { fill: parent; margins: -8 }
            radius: 12
            color: "transparent"
            border { width: 2.5; color: box.theme.focusRing }
            opacity: box.current ? 0.9 : mouse.containsMouse ? 0.35 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: box.pointerActive
            cursorShape: Qt.PointingHandCursor
            onClicked: box.clicked()
        }
    }
}
