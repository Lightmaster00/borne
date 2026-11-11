// One game box, drawn as a physical case: the cover under clear plastic (rim, gloss, a sharp
// light along the top edge), spines in dark plastic with a band in the console's color and the
// title, a soft contact shadow and a faint reflection on the floor. The box takes the shape of
// its cover: portrait for most consoles, wider and lower for landscape boxes.
// Every face is a flat item drawn through BoxShelf.faceMatrix.
import QtQuick
import QtQuick.Shapes
import "Cases.js" as Cases

Item {
    id: box
    property QtObject theme
    property Item stage
    property var game: null
    property var place: ({ x: 0, y: 0, z: 0, ang: 0 })
    property bool current: false
    property bool pointerActive: false
    signal clicked()

    // The case's real size, to scale with the other consoles' cases. Boxes sold both ways
    // (Super Nintendo: wide in America, upright in Europe) follow their cover.
    readonly property var kind: Cases.of(game ? game.platform_slug : "")
    readonly property real coverAspect: cover.status === Image.Ready && cover.implicitHeight > 0 ? cover.implicitWidth / cover.implicitHeight : 0
    readonly property bool turned: !!kind.turns && coverAspect > 0 && coverAspect < 1
    readonly property real mm: stage.boxH / Cases.TALLEST
    readonly property real bw: (turned ? kind.h : kind.w) * mm
    readonly property real bh: (turned ? kind.w : kind.h) * mm
    readonly property real bd: Math.max(6, kind.d * mm)
    readonly property string mat: kind.mat
    readonly property bool plastic: mat !== "card"
    readonly property real rim: mat === "keep" ? 7 : mat === "clam" ? 4 : mat === "jewel" ? 2 : 0
    readonly property var dims: ({ w: bw, h: bh, d: bd })

    readonly property real frontFacing: stage.facing(place, "front")
    readonly property real leftFacing: stage.facing(place, "left")
    readonly property real rightFacing: stage.facing(place, "right")
    readonly property color tone: theme.tone(game ? game.hue : 0)
    readonly property string dl: game && game.dl_state ? game.dl_state : ""
    readonly property bool busy: dl === "queued" || dl === "downloading" || dl === "verifying" || dl === "extracting"
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

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
        opacity: 0.06 * box.frontFacing
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
    // Both sides show the spine (from RomM's scan when there is one, else the case's material with
    // the title), so the boxes turned toward the selection always present their spine.
    component Spine: Item {
        id: sp
        property string side: "left"
        property real facingValue: 0
        readonly property bool printed: scan.status === Image.Ready
        width: box.bd; height: box.bh
        visible: facingValue > 0.02
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, sp.side, false, box.dims) }
        Rectangle {
            anchors.fill: parent
            color: box.mat === "card" ? Qt.darker(box.tone, 1.6) : box.kind.color
        }
        Image {
            id: scan
            anchors.fill: parent
            source: box.game && box.game.art_kinds && box.game.art_kinds.indexOf(",side,") >= 0 ? box.game.art + "side" : ""
            asynchronous: true
            fillMode: Image.Stretch
            sourceSize.height: 420
        }
        Text {
            visible: !sp.printed
            anchors.centerIn: parent
            width: box.bh - 40
            height: box.bd
            rotation: -90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            color: Qt.colorEqual(box.kind.color, "#e9ebee") || Qt.colorEqual(box.kind.color, "#dfe2e6") ? "#26282d" : "#e8eaef"
            font { family: box.theme.fontFamily; pixelSize: Math.max(9, Math.min(15, box.bd * 0.42)); weight: Font.Bold; letterSpacing: 0.5 }
        }
        // Plastic: rounded light along the spine; cardboard: flat with sharp folds.
        Rectangle {
            anchors.fill: parent
            visible: box.plastic
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.35) }
                GradientStop { position: 0.4; color: Qt.rgba(1, 1, 1, 0.10) }
                GradientStop { position: 0.6; color: Qt.rgba(1, 1, 1, 0.04) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.35) }
            }
        }
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: Qt.rgba(1, 1, 1, box.plastic ? 0.18 : 0.3) }
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

        // The case around the printed cover: colored plastic rim (keep case, clamshell), a clear
        // CD case with its hinge, or bare cardboard.
        Rectangle { anchors.fill: parent; radius: box.mat === "keep" ? 6 : box.mat === "card" ? 1 : 3; color: box.kind.color }
        Item {
            id: art
            anchors { fill: parent; margins: box.rim; leftMargin: box.mat === "jewel" ? box.bw * 0.07 : box.rim }
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
        // Jewel case hinge: clear ribbed strip on the left.
        Rectangle {
            visible: box.mat === "jewel"
            width: box.bw * 0.07; height: parent.height
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.22) }
                GradientStop { position: 0.3; color: Qt.rgba(1, 1, 1, 0.06) }
                GradientStop { position: 0.55; color: Qt.rgba(1, 1, 1, 0.18) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.3) }
            }
        }
        // Gloss: a broad soft reflection that slides as the box turns (strong on clear plastic,
        // faint on cardboard), and a sharp light along the top edge.
        Rectangle {
            anchors { fill: parent; margins: box.rim }
            opacity: box.mat === "jewel" ? 0.32 : box.mat === "card" ? 0.07 : 0.22
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: Math.max(0, Math.min(1, 0.05 + box.place.ang / 150)); color: "transparent" }
                GradientStop { position: Math.max(0, Math.min(1, 0.22 + box.place.ang / 150)); color: Qt.rgba(1, 1, 1, 0.55) }
                GradientStop { position: Math.max(0, Math.min(1, 0.42 + box.place.ang / 150)); color: "transparent" }
            }
        }
        Rectangle {
            anchors { fill: parent; margins: box.rim }
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
                GradientStop { position: 0.25; color: "transparent" }
                GradientStop { position: 0.85; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.18) }
            }
        }
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 4; rightMargin: 4 } height: 1; color: Qt.rgba(1, 1, 1, 0.45) }
        Rectangle { anchors.fill: parent; radius: box.mat === "keep" ? 6 : 1; color: "transparent"; border { width: 1; color: Qt.rgba(1, 1, 1, box.plastic ? 0.16 : 0.1) } }

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

        // Hover (mouse): a fine white line around the box. The selected box needs none: it stands forward.
        Rectangle {
            anchors { fill: parent; margins: -8 }
            radius: 12
            color: "transparent"
            border { width: 2.5; color: box.theme.focusRing }
            opacity: !box.current && mouse.containsMouse ? 0.35 : 0
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
