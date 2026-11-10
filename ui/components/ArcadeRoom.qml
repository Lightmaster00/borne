// The library as an arcade room: one cabinet per game, standing in a curved row on a lit floor.
// The selected cabinet faces you; its neighbors turn toward it and recede into the dark.
//
// Same technique as BoxShelf: every face is a flat item drawn through one perspective matrix,
// and only the cabinets around the selection exist.
import QtQuick

Item {
    id: room
    property QtObject theme
    property var games
    property int currentIndex: 0
    property int revision: 0
    property bool pointerActive: false
    signal picked(int index)

    readonly property real cabW: 330
    readonly property real cabH: 700
    readonly property real cabD: 240
    readonly property real focal: 1500
    readonly property real cx: width / 2
    readonly property real cy: height / 2 - 10
    readonly property int slots: 11

    property real flow: currentIndex
    Behavior on flow { NumberAnimation { duration: 520; easing.type: Easing.OutCubic } }

    function placeOf(t) {
        const a = Math.abs(t), s = t < 0 ? -1 : 1
        let x, z, ang
        if (a <= 1) { x = t * 450; z = -170 * a; ang = -t * 26 }
        else { x = s * (450 + (a - 1) * 330); z = -170 - (a - 1) * 150; ang = -s * (26 + Math.min(1, a - 1) * 6) }
        // The selected cabinet steps forward a little.
        return { x: x, y: 0, z: z - 330 + 110 * Math.max(0, 1 - a), ang: ang }
    }

    // face: "front", "left", "right" (cabinet), or "floor" (a horizontal plane under everything).
    function faceMatrix(p, face) {
        const th = p.ang * Math.PI / 180, c = Math.cos(th), s = Math.sin(th)
        const W = cabW, H = cabH, D = cabD
        let ax, ay, az, bx, by, bz, ox, oy, oz
        if (face === "front") { ax = 1; ay = 0; az = 0; bx = 0; by = 1; bz = 0; ox = -W / 2; oy = -H / 2; oz = D / 2 }
        else if (face === "left") { ax = 0; ay = 0; az = 1; bx = 0; by = 1; bz = 0; ox = -W / 2; oy = -H / 2; oz = -D / 2 }
        else if (face === "right") { ax = 0; ay = 0; az = -1; bx = 0; by = 1; bz = 0; ox = W / 2; oy = -H / 2; oz = D / 2 }
        else { ax = 1; ay = 0; az = 0; bx = 0; by = 0; bz = -1; ox = -3000; oy = H / 2; oz = 900 }
        const rx = (x, z) => x * c + z * s, rz = (x, z) => -x * s + z * c
        const A1 = rx(ax, az), B1 = rx(bx, bz), C1 = rx(ox, oz) + cx + p.x
        const A2 = ay, B2 = by, C2 = oy + cy + p.y
        const A3 = rz(ax, az), B3 = rz(bx, bz), C3 = rz(ox, oz) + p.z
        const f = focal, X0 = cx, Y0 = cy
        return Qt.matrix4x4(A1 - A3 * X0 / f, B1 - B3 * X0 / f, 0, C1 - C3 * X0 / f,
                            A2 - A3 * Y0 / f, B2 - B3 * Y0 / f, 0, C2 - C3 * Y0 / f,
                            0, 0, 1, 0,
                            -A3 / f, -B3 / f, 0, 1 - C3 / f)
    }
    function facing(p, face) {
        const th = p.ang * Math.PI / 180
        const nx = face === "front" ? Math.sin(th) : face === "left" ? -Math.cos(th) : Math.cos(th)
        const nz = face === "front" ? Math.cos(th) : face === "left" ? Math.sin(th) : -Math.sin(th)
        const vx = -p.x, vz = focal - p.z
        return (nx * vx + nz * vz) / Math.sqrt(vx * vx + vz * vz)
    }

    // ---------- the room: dark, a lit floor with a grid ----------
    Rectangle { anchors.fill: parent; color: Qt.rgba(0.02, 0.02, 0.035, 0.72) }
    Item {
        width: 6000; height: 2600
        transform: Matrix4x4 { matrix: room.faceMatrix({ x: 0, y: 0, z: 0, ang: 0 }, "floor") }
        Rectangle { anchors.fill: parent; color: "#0b0b12" }
        Repeater {
            model: 31
            Rectangle { x: index * 200; width: 3; height: parent.height; color: room.theme.accent; opacity: 0.16 }
        }
        Repeater {
            model: 14
            Rectangle { y: index * 200; width: parent.width; height: 3; color: room.theme.accent; opacity: 0.16 }
        }
        // Light pooling in front of the selected cabinet.
        Rectangle {
            x: 3000 - 500; y: 400; width: 1000; height: 900; radius: 500
            color: room.theme.accent; opacity: 0.12
        }
        // Fades into the dark far away.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 0.55; color: "transparent" }
                GradientStop { position: 1.0; color: "#05050a" }
            }
        }
    }

    Repeater {
        model: room.slots
        Item {
            id: slot
            required property int index
            anchors.fill: parent
            readonly property int gameIndex: Math.round(room.flow) + index - Math.floor(room.slots / 2)
            readonly property bool valid: room.games && gameIndex >= 0 && gameIndex < room.games.count
            readonly property var game: valid ? (room.revision, room.games.count, room.games.get(gameIndex)) : null
            readonly property real t: gameIndex - room.flow
            visible: valid && Math.abs(t) < 4.6
            z: 100 - Math.abs(t) * 10
            opacity: Math.max(0, Math.min(1, (4.4 - Math.abs(t)) / 1.4))
            Cabinet {
                anchors.fill: parent
                theme: room.theme
                stage: room
                game: slot.game
                place: room.placeOf(slot.t)
                current: slot.valid && slot.gameIndex === room.currentIndex
                pointerActive: room.pointerActive
                onClicked: room.picked(slot.gameIndex)
            }
        }
    }
}
