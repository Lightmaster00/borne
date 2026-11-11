// The library as game boxes standing in space: the selected box faces you, a little forward and
// swaying gently; the others turn toward it and show their spines, receding to the sides.
//
// Real 3D without Qt Quick 3D: each face of a box is a flat item drawn through one perspective
// matrix (face → box → world → screen), so boxes stay light (a few textured quads each).
// Only the boxes around the selection exist (13 slots), however large the library.
import QtQuick

Item {
    id: shelf
    property QtObject theme
    property var games                    // library ListModel
    property int currentIndex: 0
    property bool pointerActive: false
    property int revision: 0              // bumps when library rows change (states, progress)
    signal picked(int index)

    // Box size (screen pixels at depth 0) and layout.
    readonly property real boxW: 270
    readonly property real boxH: 420
    readonly property real boxD: 30
    readonly property real focal: 1500    // camera distance: lower = stronger perspective
    readonly property real cx: width / 2
    readonly property real cy: height / 2
    readonly property real baseY: 0       // box centers sit on the shelf's middle line
    readonly property int slots: 13

    // Selection, smoothed: every box derives its place from (index - flow), so moving the
    // selection makes the whole row glide instead of jumping.
    property real flow: currentIndex
    Behavior on flow { NumberAnimation { duration: 460; easing.type: Easing.OutCubic } }

    // Gentle idle sway of the selected box.
    property real sway: 0
    property bool showSelection: true
    property bool trueSides: false        // false: both sides show the spine (shelf); true: a real box
    // Inspect mode (game page): the selected box turns all the way round, pausing on its back.
    property bool inspect: false
    property real spin: 0
    SequentialAnimation on spin {
        loops: Animation.Infinite
        running: shelf.inspect && shelf.visible
        PauseAnimation { duration: 5000 }
        NumberAnimation { from: 0; to: 180; duration: 2600; easing.type: Easing.InOutCubic }
        PauseAnimation { duration: 3500 }
        NumberAnimation { from: 180; to: 360; duration: 2600; easing.type: Easing.InOutCubic }
    }
    property real swayAmp: 4              // degrees
    property int swayPeriod: 3600
    SequentialAnimation on sway {
        loops: Animation.Infinite
        running: shelf.visible
        NumberAnimation { from: -1; to: 1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: -1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
    }

    // Place of a box at offset t from the selection (continuous).
    function placeOf(t) {
        const a = Math.abs(t), s = t < 0 ? -1 : 1
        let x, z, ang
        if (a <= 1) {
            x = t * 340
            z = 210 * (1 - a) - 60 * a
            ang = -t * 64
        } else {
            x = s * (330 + (a - 1) * 76)
            z = -60 - (a - 1) * 18
            ang = -s * 64
        }
        if (a < 0.5) ang += (shelf.inspect ? shelf.spin : shelf.sway * shelf.swayAmp) * (1 - 2 * a)
        return { x: x, y: shelf.baseY + (a < 1 ? -8 * (1 - a) : 0), z: z, ang: ang }
    }

    // Matrix drawing face point (u, v) of a box placed at p. face: "front", "left", "right".
    // dims: { w, h, d } of this box. face "shadow": a patch of floor under the box.
    function faceMatrix(p, face, mirror, dims) {
        const th = p.ang * Math.PI / 180, c = Math.cos(th), s = Math.sin(th)
        const W = dims ? dims.w : boxW, H = dims ? dims.h : boxH, D = dims ? dims.d : boxD
        // Face coordinates → box coordinates: (u, v) ↦ ax·u + bx·v + cx0 (same for y, z).
        let ax, ay, az, bx, by, bz, ox, oy, oz
        if (face === "front") { ax = 1; ay = 0; az = 0; bx = 0; by = 1; bz = 0; ox = -W / 2; oy = -H / 2; oz = D / 2 }
        else if (face === "left") { ax = 0; ay = 0; az = 1; bx = 0; by = 1; bz = 0; ox = -W / 2; oy = -H / 2; oz = -D / 2 }
        else if (face === "back") { ax = -1; ay = 0; az = 0; bx = 0; by = 1; bz = 0; ox = W / 2; oy = -H / 2; oz = -D / 2 }
        else if (face === "right") { ax = 0; ay = 0; az = -1; bx = 0; by = 1; bz = 0; ox = W / 2; oy = -H / 2; oz = D / 2 }
        else { ax = 1; ay = 0; az = 0; bx = 0; by = 0; bz = -1; ox = -W / 2 - 60; oy = shelf.boxH / 2; oz = D / 2 + 70 }
        if (mirror) { by = -1; oy = H / 2 + H + 6 }   // reflection on the floor, just under the box
        // Box rotation about the vertical axis, then its place in the world.
        const rx = (x, z) => x * c + z * s, rz = (x, z) => -x * s + z * c
        const A1 = rx(ax, az), B1 = rx(bx, bz), C1 = rx(ox, oz) + shelf.cx + p.x
        const floorShift = face === "shadow" ? 0 : (shelf.boxH - H) / 2
        const A2 = ay, B2 = by, C2 = oy + shelf.cy + p.y + floorShift
        const A3 = rz(ax, az), B3 = rz(bx, bz), C3 = rz(ox, oz) + p.z
        const f = shelf.focal, X0 = shelf.cx, Y0 = shelf.cy
        // Perspective: x' = X − Z·X0/f, y' = Y − Z·Y0/f, w = 1 − Z/f (the GPU divides by w).
        return Qt.matrix4x4(A1 - A3 * X0 / f, B1 - B3 * X0 / f, 0, C1 - C3 * X0 / f,
                            A2 - A3 * Y0 / f, B2 - B3 * Y0 / f, 0, C2 - C3 * Y0 / f,
                            0, 0, 1, 0,
                            -A3 / f, -B3 / f, 0, 1 - C3 / f)
    }
    // How much a face turns toward the camera (1 = facing it): shading and culling.
    function facing(p, face) {
        const th = p.ang * Math.PI / 180
        const sg = face === "back" ? -1 : 1
        const nx = face === "front" || face === "back" ? sg * Math.sin(th) : face === "left" ? -Math.cos(th) : Math.cos(th)
        const nz = face === "front" || face === "back" ? sg * Math.cos(th) : face === "left" ? Math.sin(th) : -Math.sin(th)
        // Direction from the face toward the camera, roughly from the box center.
        const vx = -p.x, vz = shelf.focal - p.z
        const len = Math.sqrt(vx * vx + vz * vz)
        return (nx * vx + nz * vz) / len
    }

    Repeater {
        model: shelf.slots
        Item {
            id: slot
            required property int index
            anchors.fill: parent
            readonly property int gameIndex: Math.round(shelf.flow) + index - Math.floor(shelf.slots / 2)
            readonly property bool valid: shelf.games && gameIndex >= 0 && gameIndex < shelf.games.count
            readonly property var game: valid ? (shelf.revision, shelf.games.count, shelf.games.get(gameIndex)) : null
            readonly property real t: gameIndex - shelf.flow
            readonly property var p: shelf.placeOf(t)
            readonly property bool current: valid && gameIndex === shelf.currentIndex
            visible: valid && Math.abs(t) < shelf.slots / 2
            z: 100 - Math.abs(t) * 10
            // Boxes fade out toward the edges instead of being cut.
            opacity: Math.max(0, Math.min(1, (5.2 - Math.abs(t)) / 1.8))

            GameBox {
                anchors.fill: parent
                theme: shelf.theme
                stage: shelf
                game: slot.game
                place: slot.p
                current: slot.current
                pointerActive: shelf.pointerActive
                onClicked: shelf.picked(slot.gameIndex)
            }
        }
    }
}
