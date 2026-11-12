// The library as game boxes standing in space: the selected box faces you, a little forward and
// swaying gently; the others turn toward it and show their spines, receding to the sides.
//
// Real 3D without Qt Quick 3D: each face of a box is a flat item drawn through one perspective
// matrix (face → box → world → screen), so boxes stay light (a few textured quads each).
// Only the boxes around the selection exist (7 slots), however large the library.
import QtQuick
import "Cases.js" as Cases

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
    readonly property int slots: 7

    // Selection, smoothed: every box derives its place from (index - flow), so moving the
    // selection makes the whole row glide instead of jumping.
    property real flow: currentIndex
    Behavior on flow { NumberAnimation { duration: 460; easing.type: Easing.OutCubic } }

    // Gentle idle sway of the selected box.
    property real sway: 0
    property bool showSelection: true
    // Turned by the player (right stick, Z Q S D): applied to the selected box.
    property real userYaw: 0
    property real userPitch: 0
    readonly property bool userTurned: Math.abs(userYaw) > 0.5 || Math.abs(userPitch) > 0.5
    property real swayAmp: 4              // degrees
    property int swayPeriod: 3600
    SequentialAnimation on sway {
        loops: Animation.Infinite
        running: shelf.visible
        NumberAnimation { from: -1; to: 1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: -1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
    }

    // Place of a box at offset t from the selection (continuous).
    // Same placement as the other shelf (Cases.place); the selected case sways gently, or turns with
    // the right stick.
    readonly property real step: Cases.step(shelf.games && shelf.games.count > shelf.currentIndex && shelf.currentIndex >= 0
                                            ? (shelf.revision, shelf.games.get(shelf.currentIndex).platform_slug) : "", shelf.boxH)
    function placeOf(t) {
        const p = Cases.place(t, shelf.step)
        const a = Math.abs(t)
        let ang = p.ang, pitch = 0
        if (a < 0.5) {
            const k = 1 - 2 * a
            ang += (shelf.userTurned ? shelf.userYaw : shelf.sway * shelf.swayAmp) * k
            pitch = shelf.userPitch * k
        }
        return { x: p.x, y: shelf.baseY - p.lift, z: p.z, ang: ang, pitch: pitch }
    }

    // Rotation of a box: pitch (about its horizontal axis) then yaw (about the vertical one).
    // Box coordinates: x right, y down, z toward the viewer.
    function rot(p, x, y, z) {
        const ph = (p.pitch || 0) * Math.PI / 180, cp = Math.cos(ph), sp = Math.sin(ph)
        const y1 = y * cp - z * sp, z1 = y * sp + z * cp
        const th = p.ang * Math.PI / 180, c = Math.cos(th), s = Math.sin(th)
        return [x * c + z1 * s, y1, -x * s + z1 * c]
    }
    // Each face: u axis, v axis and origin in box coordinates, and its outward normal.
    function faceDef(face, W, H, D) {
        switch (face) {
        case "front": return { a: [1, 0, 0], b: [0, 1, 0], o: [-W / 2, -H / 2, D / 2], n: [0, 0, 1] }
        case "back": return { a: [-1, 0, 0], b: [0, 1, 0], o: [W / 2, -H / 2, -D / 2], n: [0, 0, -1] }
        case "left": return { a: [0, 0, 1], b: [0, 1, 0], o: [-W / 2, -H / 2, -D / 2], n: [-1, 0, 0] }
        case "right": return { a: [0, 0, -1], b: [0, 1, 0], o: [W / 2, -H / 2, D / 2], n: [1, 0, 0] }
        case "top": return { a: [1, 0, 0], b: [0, 0, 1], o: [-W / 2, -H / 2, -D / 2], n: [0, -1, 0] }
        case "bottom": return { a: [1, 0, 0], b: [0, 0, -1], o: [-W / 2, H / 2, D / 2], n: [0, 1, 0] }
        }
        return null
    }

    // Matrix drawing face point (u, v) of a box placed at p. face: front, back, left, right, top,
    // bottom; "shadow": a patch of floor under the box. mirror: the front reflected on the floor.
    function faceMatrix(p, face, mirror, dims) {
        const W = dims ? dims.w : boxW, H = dims ? dims.h : boxH, D = dims ? dims.d : boxD
        let A, B, O
        if (face === "shadow" || mirror) {
            // On the floor: follows the turn only (a tilted box keeps its shadow and reflection flat).
            const q = { ang: p.ang, pitch: 0 }
            if (face === "shadow") {
                A = rot(q, 1, 0, 0); B = rot(q, 0, 0, -1); O = rot(q, -W / 2 - 60, 0, D / 2 + 70)
                O[1] = shelf.boxH / 2
            } else {
                A = rot(q, 1, 0, 0); B = rot(q, 0, -1, 0); O = rot(q, -W / 2, 0, D / 2)
                O[1] = H / 2 + H + 6
            }
        } else {
            const d = faceDef(face, W, H, D)
            A = rot(p, d.a[0], d.a[1], d.a[2]); B = rot(p, d.b[0], d.b[1], d.b[2]); O = rot(p, d.o[0], d.o[1], d.o[2])
        }
        const floorShift = face === "shadow" ? 0 : (shelf.boxH - H) / 2
        const C1 = O[0] + shelf.cx + p.x, C2 = O[1] + shelf.cy + p.y + floorShift, C3 = O[2] + p.z
        const f = shelf.focal, X0 = shelf.cx, Y0 = shelf.cy
        // Perspective: x' = X − Z·X0/f, y' = Y − Z·Y0/f, w = 1 − Z/f (the GPU divides by w).
        return Qt.matrix4x4(A[0] - A[2] * X0 / f, B[0] - B[2] * X0 / f, 0, C1 - C3 * X0 / f,
                            A[1] - A[2] * Y0 / f, B[1] - B[2] * Y0 / f, 0, C2 - C3 * Y0 / f,
                            0, 0, 1, 0,
                            -A[2] / f, -B[2] / f, 0, 1 - C3 / f)
    }
    // Direction from the box toward the camera.
    function viewDir(p) {
        const vx = -p.x, vy = -p.y, vz = shelf.focal - p.z
        const l = Math.sqrt(vx * vx + vy * vy + vz * vz)
        return [vx / l, vy / l, vz / l]
    }
    function normalOf(p, face) {
        const d = faceDef(face, 1, 1, 1)
        return rot(p, d.n[0], d.n[1], d.n[2])
    }
    // How much a face turns toward the camera (1 = facing it): culling.
    function facing(p, face) {
        const n = normalOf(p, face), v = viewDir(p)
        return n[0] * v[0] + n[1] * v[1] + n[2] * v[2]
    }
    // Light: a key light above, left and in front of the boxes. Returns { diffuse, spec }:
    // diffuse 0.4 … 1 (how lit the face is), spec 0 … 1 (a highlight where the light reflects
    // toward the eye; it slides across the faces as the box turns).
    readonly property var lightDir: { const l = [-0.42, -0.62, 0.66], n = Math.sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]); return [l[0] / n, l[1] / n, l[2] / n] }
    function lighting(p, face) {
        const n = normalOf(p, face), v = viewDir(p), L = lightDir
        const nl = Math.max(0, n[0] * L[0] + n[1] * L[1] + n[2] * L[2])
        const h = [L[0] + v[0], L[1] + v[1], L[2] + v[2]]
        const hl = Math.sqrt(h[0] * h[0] + h[1] * h[1] + h[2] * h[2])
        const nh = Math.max(0, (n[0] * h[0] + n[1] * h[1] + n[2] * h[2]) / hl)
        // Scaled so a box facing you at rest is fully lit (covers keep their true colors).
        return { diffuse: Math.max(0.4, Math.min(1, 0.4 + 0.6 * nl / L[2])), spec: Math.pow(nh, 24) }
    }

    Repeater {
        model: shelf.slots
        Item {
            id: slot
            required property int index
            anchors.fill: parent
            // Each slot keeps its game while it stays in the window (see Shelf3D).
            readonly property int first: Math.round(shelf.flow) - Math.floor(shelf.slots / 2)
            readonly property int gameIndex: first + ((index - first) % shelf.slots + shelf.slots) % shelf.slots
            readonly property bool valid: shelf.games && gameIndex >= 0 && gameIndex < shelf.games.count
            readonly property var game: valid ? (shelf.revision, shelf.games.count, shelf.games.get(gameIndex)) : null
            readonly property real t: gameIndex - shelf.flow
            readonly property var p: shelf.placeOf(t)
            readonly property bool current: valid && gameIndex === shelf.currentIndex
            visible: valid && Math.abs(t) < shelf.slots / 2
            z: 100 - Math.abs(t) * 10
            // Boxes fade out toward the edges instead of being cut.
            opacity: Cases.presence(t)

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
