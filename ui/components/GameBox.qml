// One game box, built as a solid: six faces drawn through BoxShelf.faceMatrix (front, back,
// spine on the left, opening edge on the right, top, bottom), lit by one key light — each face
// darkens as it turns from the light and catches a highlight where the light reflects toward
// the eye, so the box reads as an object as it turns (right stick, Z Q S D).
// Materials: a plastic keep case (colored rim, clear sleeve with a moving sheen, rounded edges),
// a clear CD case (hinge, black tray seen through the lid), a hard clamshell, or a cardboard box
// (matte, sharp folds). Printed faces come from the case scans; nothing is drawn over the art
// but light.
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
    // Rebuilt from ScreenScraper's case scans (RomM): the front scan gives the width, the spine
    // scan the thickness; the console's real case size fills in what is missing.
    function has(k) { return !!(game && game.art_kinds && game.art_kinds.indexOf("," + k + ",") >= 0) }
    readonly property bool frontScan: has("front")
    // The front follows its image exactly (the scan, else the cover): nothing is cropped.
    readonly property real frontAR: frontScan && game.front_ar > 0 ? game.front_ar : (game && game.cover_ar > 0 ? game.cover_ar : 0)
    readonly property real sideAR: has("side") && game.side_ar > 0 ? game.side_ar : 0
    readonly property real bh: (turned ? kind.w : kind.h) * mm
    readonly property real bw: frontAR > 0 ? Math.max(0.5, Math.min(1.6, frontAR)) * (bh - 2 * rim) + rim + (mat === "jewel" ? bh * 0.075 : rim)
                                           : (turned ? kind.h : kind.w) * mm
    readonly property real bd: sideAR > 0 ? Math.max(5, Math.min(bh * 0.3, sideAR * bh)) : Math.max(6, kind.d * mm)
    readonly property string mat: kind.mat
    readonly property bool plastic: mat !== "card"
    readonly property real rim: mat === "keep" ? 7 : mat === "clam" ? 4 : mat === "jewel" ? 2 : 0
    readonly property var dims: ({ w: bw, h: bh, d: bd })

    readonly property real frontFacing: stage.facing(place, "front")
    readonly property real backFacing: stage.facing(place, "back")
    // Highlight strength by material: clear plastic shines, cardboard barely.
    readonly property real gloss: mat === "jewel" ? 0.85 : mat === "card" ? 0.18 : 0.6
    readonly property color plasticEdge: Qt.lighter(kind.color, 1.35)
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
        visible: box.frontFacing > 0.05 && Math.abs(box.place.pitch || 0) < 4
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

    // ---------- light on a face ----------
    component Light: Item {
        id: lt
        property string face: "front"
        property real radius: 0
        readonly property var l: box.stage.lighting(box.place, face)
        anchors.fill: parent
        Rectangle { anchors.fill: parent; radius: lt.radius; color: "black"; opacity: (1 - lt.l.diffuse) * 0.92 }
        Rectangle { anchors.fill: parent; radius: lt.radius; color: "white"; opacity: lt.l.spec * box.gloss * 0.55 }
    }

    // ---------- spine (left), opening edge (right), top and bottom ----------
    component Side: Item {
        id: sd
        property string face: "left"
        readonly property real facingValue: box.stage.facing(box.place, face)
        readonly property bool vertical: face === "left" || face === "right"
        readonly property bool spine: face === "left"
        readonly property bool printed: spine && scan.status === Image.Ready
        // +1: no seam against the front.
        width: vertical ? box.bd + 1 : box.bw
        height: vertical ? box.bh : box.bd + 1
        visible: facingValue > 0.01
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, sd.face, false, box.dims) }
        // Material: plastic in the case's color, or the box's printed cardboard.
        Rectangle {
            anchors.fill: parent
            color: box.mat === "card" ? Qt.darker(box.tone, 1.5) : box.mat === "jewel" ? "#101012" : box.kind.color
        }
        // The spine scan (stored upright and trimmed by the core).
        Image {
            id: scan
            anchors.fill: parent
            visible: sd.spine
            source: sd.spine && box.has("side") ? box.game.art + "side" : ""
            asynchronous: true
            fillMode: Image.Stretch
        }
        Text {
            // The title only when there is no scan (not while it loads: no flash of text).
            visible: sd.spine && (scan.source == "" || scan.status === Image.Error)
            anchors.centerIn: parent
            width: box.bh - 40
            height: box.bd
            rotation: -90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            color: Qt.colorEqual(box.kind.color, "#eceef1") || Qt.colorEqual(box.kind.color, "#dfe2e6") ? "#26282d" : "#e8eaef"
            font { family: box.theme.fontFamily; pixelSize: Math.max(9, Math.min(15, box.bd * 0.42)); weight: Font.Bold; letterSpacing: 0.5 }
        }
        // Keep case: the opening edge, top and bottom are bare plastic with moulded ridges.
        Repeater {
            model: box.mat === "keep" && !sd.spine ? 3 : 0
            Rectangle {
                required property int index
                x: sd.vertical ? (parent.width - width) / 2 : parent.width * (0.2 + index * 0.3)
                y: sd.vertical ? parent.height * (0.2 + index * 0.3) : (parent.height - height) / 2
                width: sd.vertical ? parent.width * 0.4 : parent.width * 0.12
                height: sd.vertical ? parent.height * 0.12 : parent.height * 0.4
                radius: 2
                color: Qt.rgba(0, 0, 0, 0.18)
            }
        }
        // Jewel case: the clear lid's edge over the black tray.
        Rectangle {
            visible: box.mat === "jewel"
            anchors { fill: parent; margins: 1 }
            color: "transparent"
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.35) }
        }
        // Rounded plastic: lighter toward the middle of the edge; cardboard: flat with crisp folds.
        Rectangle {
            anchors.fill: parent
            visible: box.plastic
            gradient: Gradient {
                orientation: sd.vertical ? Gradient.Horizontal : Gradient.Vertical
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.28) }
                GradientStop { position: 0.45; color: Qt.rgba(1, 1, 1, 0.12) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.28) }
            }
        }
        Rectangle { anchors.fill: parent; color: "transparent"; border { width: 1; color: Qt.rgba(1, 1, 1, box.plastic ? 0.14 : 0.22) } }
        Light { face: sd.face }
    }
    Side { face: "left" }
    Side { face: "right" }
    Side { face: "top" }
    Side { face: "bottom" }

    // ---------- back ----------
    Item {
        width: box.bw; height: box.bh
        visible: box.backFacing > 0.01
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, "back", false, box.dims) }
        Rectangle { anchors.fill: parent; radius: box.mat === "keep" ? 6 : 1; color: box.mat === "card" ? Qt.darker(box.tone, 1.5) : box.kind.color }
        Image {
            anchors { fill: parent; margins: box.rim }
            source: box.has("back") && box.backFacing > 0.01 ? box.game.art + "back" : ""
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(500, 720)
        }
        Rectangle { anchors.fill: parent; radius: box.mat === "keep" ? 6 : 1; color: "transparent"; border { width: 1.5; color: Qt.rgba(1, 1, 1, box.plastic ? 0.2 : 0.1) } }
        Light { face: "back"; radius: box.mat === "keep" ? 6 : 1 }
    }

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
                visible: cover.source == "" || cover.status === Image.Error
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
                source: box.frontScan ? box.game.art + "front" : box.game && box.game.cover ? box.game.cover : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(600, 900)
                mipmap: true
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
        // Plastic sleeve over the cover: a soft sheen band that slides as the box turns or tilts,
        // and a faint inner shadow where the sleeve meets the rim.
        Item {
            anchors { fill: parent; margins: box.rim }
            visible: box.plastic
            clip: true
            Rectangle {
                width: parent.width * 0.55; height: parent.height * 1.8
                x: parent.width * (0.5 - (box.place.ang || 0) / 70) - width / 2
                y: parent.height * (-0.4 + (box.place.pitch || 0) / 90)
                rotation: 18
                opacity: box.mat === "jewel" ? 0.22 : 0.13
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.5; color: "white" }
                    GradientStop { position: 1.0; color: "transparent" }
                }
            }
            Rectangle { anchors.fill: parent; color: "transparent"; border { width: 2; color: Qt.rgba(0, 0, 0, 0.22) } }
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
        // Edges: rounded plastic catches a thin light all around; cardboard has crisp folds.
        Rectangle { anchors.fill: parent; radius: box.mat === "keep" ? 6 : 1; color: "transparent"; border { width: box.plastic ? 1.5 : 1; color: Qt.rgba(1, 1, 1, box.plastic ? 0.22 : 0.12) } }

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

        // Light: the face darkens away from the light and catches the highlight.
        Light { face: "front"; radius: box.mat === "keep" ? 6 : 1 }

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
