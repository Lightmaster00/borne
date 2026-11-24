// A game's case in 3D, drawn with Qt Quick alone: six faces, each an item placed by a projected
// 4 × 4 matrix (perspective, then flattened like Qt's own 3D rotations), the faces turned away
// hidden. The front is the cover scan (else RomM's cover), the back its back scan, the spines its
// spine scan (else the case's colour with the game's logo or name), the top and bottom the spine's
// colour. Proportions: the front scan's, its thickness the real case's (Cases.js).
// yaw / pitch turn it (degrees); light shades the faces by how much they face the viewer.
import QtQuick
import QtQuick.Effects
import "Cases.js" as Cases

Item {
    id: box
    property QtObject theme
    property var game: null
    property real yaw: -24
    property real pitch: 6
    property real boxH: 440               // the case's height on screen
    // Its pictures decoded for the case's size on screen (the scene's scale, Retina), at least 1000 px.
    readonly property int texH: theme ? Math.max(1000, theme.px(boxH * 1.25, 2400)) : 1000
    property real distance: 1600          // the eye's distance (perspective)

    function has(k) { return !!(game && game.art_kinds && game.art_kinds.indexOf("," + k + ",") >= 0) }
    readonly property var kind: Cases.of(game ? game.platform_slug : "")
    readonly property real ar: {
        const g = game
        const a = g && has("front") && g.front_ar > 0 ? g.front_ar : g && g.cover_ar > 0 ? g.cover_ar : Cases.ratio(g ? g.platform_slug : "")
        return Math.max(0.5, Math.min(1.8, a))
    }
    // The longest side at boxH.
    readonly property real bh: ar <= 1 ? boxH : boxH / ar
    readonly property real bw: ar <= 1 ? boxH * ar : boxH
    readonly property real bd: Math.max(bh * 0.06, Math.max(bw, bh) * (kind.d || 14) / Math.max(kind.w, kind.h))
    readonly property color plastic: kind.color || "#141416"
    readonly property color capColor: game && game.spine_color ? game.spine_color : plastic
    readonly property string frontUrl: has("front") ? game.art + "front" : game && game.cover ? game.cover : ""
    readonly property string backUrl: has("back") ? game.art + "back" : ""
    readonly property string sideUrl: has("side") ? game.art + "side" : ""
    readonly property bool sideLying: has("side") && game.side_ar > 1

    // ---------- matrices (rows × columns, column vectors) ----------
    function mul(a, b) {
        const r = []
        for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) {
            let v = 0
            for (let k = 0; k < 4; k++) v += a[i * 4 + k] * b[k * 4 + j]
            r.push(v)
        }
        return r
    }
    function tr3(x, y, z) { return [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1] }
    function rotY(d) { const a = d * Math.PI / 180, c = Math.cos(a), s = Math.sin(a); return [c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1] }
    function rotX(d) { const a = d * Math.PI / 180, c = Math.cos(a), s = Math.sin(a); return [1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1] }
    // The view: turned, then seen in perspective from `distance`, flattened (z dropped, w kept).
    readonly property var view: mul(rotX(pitch), rotY(yaw))
    function placed(faceM, fw, fh) {
        const m = mul(mul(view, faceM), tr3(-fw / 2, -fh / 2, 0))
        const p = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, -1 / distance, 1]
        const f = mul(p, m)
        const c = mul(tr3(width / 2, height / 2, 0), f)
        return Qt.matrix4x4(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12], c[13], c[14], c[15])
    }
    // How much a face looks at the viewer (its normal's z once turned), 0 to 1.
    function facing(faceM) {
        const m = mul(view, faceM)
        return m[10]   // the turned (0, 0, 1)'s z
    }

    // Each face: where it sits, its size.
    readonly property var faces: ({
        front: { m: tr3(0, 0, bd / 2), w: bw, h: bh },
        back: { m: mul(rotY(180), tr3(0, 0, bd / 2)), w: bw, h: bh },
        right: { m: mul(rotY(90), tr3(0, 0, bw / 2)), w: bd, h: bh },
        left: { m: mul(rotY(-90), tr3(0, 0, bw / 2)), w: bd, h: bh },
        top: { m: mul(rotX(90), tr3(0, 0, bh / 2)), w: bw, h: bd },
        bottom: { m: mul(rotX(-90), tr3(0, 0, bh / 2)), w: bw, h: bd }
    })

    component Face: Item {
        id: face
        property string side
        readonly property var f: box.faces[side]
        readonly property real lit: box.facing(f.m)
        width: f.w; height: f.h
        visible: lit > 0.02
        antialiasing: true
        transform: Matrix4x4 { matrix: box.placed(face.f.m, face.f.w, face.f.h) }
        default property alias content: inner.data
        Item { id: inner; anchors.fill: parent }
        // Shade: the more it turns away, the darker.
        Rectangle { anchors.fill: parent; color: "#000000"; opacity: (1 - face.lit) * 0.55; antialiasing: true }
    }

    Face {
        side: "back"
        Rectangle { anchors.fill: parent; color: box.capColor; antialiasing: true }
        Image { anchors.fill: parent; source: box.backUrl; fillMode: Image.Stretch; asynchronous: true; sourceSize.height: box.texH; smooth: true }
    }
    Face {
        side: "top"
        Rectangle { anchors.fill: parent; color: Qt.lighter(box.capColor, 1.1); antialiasing: true }
    }
    Face {
        side: "bottom"
        Rectangle { anchors.fill: parent; color: Qt.darker(box.capColor, 1.2); antialiasing: true }
    }
    component Spine: Item {
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: box.capColor; antialiasing: true }
        Image {
            id: sImg
            anchors.centerIn: parent
            width: box.sideLying ? parent.height : parent.width
            height: box.sideLying ? parent.width : parent.height
            rotation: box.sideLying ? 90 : 0
            source: box.sideUrl
            fillMode: Image.Stretch
            asynchronous: true
            sourceSize.height: box.texH
            smooth: true
        }
        Image {
            id: sLogo
            visible: (box.sideUrl === "" || sImg.status === Image.Error) && status === Image.Ready
            anchors.centerIn: parent
            width: parent.height * 0.7; height: parent.width * 0.72
            rotation: -90
            source: box.has("logo") ? box.game.art + "logo" : ""
            sourceSize.width: 512
            fillMode: Image.PreserveAspectFit
            asynchronous: true
        }
        Text {
            visible: (box.sideUrl === "" || sImg.status === Image.Error) && !sLogo.visible
            anchors.centerIn: parent
            width: parent.height * 0.86; height: parent.width
            rotation: -90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: box.capColor.hslLightness > 0.6 ? "#26282d" : "#eceef2"
            font { family: box.theme ? box.theme.fontFamily : "sans"; pixelSize: Math.max(10, parent.width * 0.4); weight: Font.Bold }
        }
    }
    Face { side: "left"; Spine {} }
    Face { side: "right"; Spine {} }
    Face {
        side: "front"
        Rectangle {
            anchors.fill: parent
            color: box.game && box.theme ? box.theme.tone(box.game.hue) : "#333"
            antialiasing: true
            Text {
                visible: frontImg.status !== Image.Ready
                anchors { fill: parent; margins: 20 }
                text: box.game ? box.game.name : ""
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignBottom
                color: "#ffffff"
                font { family: box.theme ? box.theme.displayFont : "sans"; pixelSize: 30; weight: Font.ExtraBold }
            }
        }
        Image { id: frontImg; anchors.fill: parent; source: box.frontUrl; fillMode: Image.Stretch; asynchronous: true; sourceSize.height: box.texH; smooth: true }
        // A gloss across the plastic.
        Rectangle {
            anchors.fill: parent
            antialiasing: true
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.0) }
                GradientStop { position: Math.max(0.05, Math.min(0.9, 0.45 + box.yaw / 120)); color: Qt.rgba(1, 1, 1, 0.12) }
                GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
            }
        }
    }
}
