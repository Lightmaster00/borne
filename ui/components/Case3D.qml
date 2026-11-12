// One game case as a 3D object (Qt Quick 3D): a box to the case's real proportions with slightly
// rounded corners and edges, lit by the shelf's studio, with a thin ink outline (Borne's touch of
// cel shading). The front is the cover scan, the same spine on the left and the right, the back
// scan behind, and the console's plastic colour on the top and the bottom. Prints have a fine
// grain and a varnish (cardboard: matte paper), the plastic a satin grain.
// Coordinates: x right, y up, z toward you.
import QtQuick
import QtQuick3D
import QtQuick3D.Helpers
import "Cases.js" as Cases
import "CaseMesh.js" as Mesh

Node {
    id: box
    property QtObject theme
    property var game: null
    property var place: ({ x: 0, y: 0, z: 0, ang: 0, pitch: 0 })
    property real boxH: 420               // height of the tallest case, in scene units
    property int slotIndex: -1            // for picking

    function has(k) { return !!(game && game.art_kinds && game.art_kinds.indexOf("," + k + ",") >= 0) }
    readonly property var kind: Cases.of(game ? game.platform_slug : "")
    readonly property bool card: kind.mat === "card"
    readonly property real mm: boxH / Cases.TALLEST
    readonly property bool frontScan: has("front")
    readonly property real frontAR: frontScan && game.front_ar > 0 ? game.front_ar : (game && game.cover_ar > 0 ? game.cover_ar : 0)
    readonly property real sideAR: has("side") && game.side_ar > 0 ? game.side_ar : 0
    readonly property bool turned: !!kind.turns && frontAR > 0 && frontAR < 1
    readonly property real bh: (turned ? kind.w : kind.h) * mm
    readonly property real bw: frontAR > 0 ? Math.max(0.5, Math.min(1.6, frontAR)) * bh : (turned ? kind.h : kind.w) * mm
    readonly property real bd: sideAR > 0 ? Math.max(5, Math.min(bh * 0.3, sideAR * bh)) : Math.max(6, kind.d * mm)
    // Slightly rounded: a little more on plastic than on cardboard.
    readonly property real round: (card ? 0.9 : 1.8) * mm
    readonly property color plastic: kind.color
    readonly property bool lightPlastic: plastic.hslLightness > 0.6
    readonly property color tone: theme ? theme.tone(game ? game.hue : 0) : "#444"
    readonly property color ink: theme && theme.ink ? theme.ink : "#06070a"
    readonly property string frontUrl: frontScan ? game.art + "front" : (game && game.cover ? game.cover : "")
    readonly property string sideUrl: has("side") ? game.art + "side" : ""
    readonly property string backUrl: has("back") ? game.art + "back" : ""

    // Bottom on the floor (y = 0 at the shelf's middle line, cases standing on boxH / 2 below).
    position: Qt.vector3d(place.x, -(place.y || 0) - boxH / 2 + bh / 2, place.z)
    eulerRotation.y: place.ang

    // A face of the box with its material.
    component Face: Model {
        property string side
        property var mesh: Mesh.face(side, box.bw, box.bh, box.bd, box.round, 4)
        geometry: ProceduralMesh {
            positions: mesh.positions
            normals: mesh.normals
            uv0s: mesh.uv0s
            indexes: mesh.indexes
        }
    }
    // The fine grain of the prints and the plastic (a tiling normal map).
    component Grain: Texture {
        source: "grain.png"
        scaleU: box.bw / 40
        scaleV: box.bh / 40
        tilingModeHorizontal: Texture.Repeat
        tilingModeVertical: Texture.Repeat
    }
    // A print: the scan over the game's tone; the title only when there is no scan to show.
    component Print: Rectangle {
        property string src
        property bool titled: true
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.lighter(box.tone, 1.25) }
            GradientStop { position: 1; color: Qt.darker(box.tone, 1.9) }
        }
        Text {
            visible: parent.titled && (parent.src === "" || img.status === Image.Error)
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: parent.width * 0.07 }
            text: box.game ? box.game.name : ""
            color: "white"; font.pixelSize: parent.width / 8; font.bold: true
            wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight
        }
        Image {
            id: img
            anchors.fill: parent
            source: parent.src
            sourceSize: Qt.size(parent.width, parent.height)
            fillMode: Image.Stretch
            asynchronous: true
        }
    }
    // The spine: its scan, else a band in the console's colour with the title.
    component Spine: Rectangle {
        color: box.plastic
        Image {
            id: sImg
            anchors.fill: parent
            source: box.sideUrl
            asynchronous: true
            fillMode: Image.Stretch
            sourceSize: Qt.size(Math.max(32, parent.width), parent.height)
        }
        Text {
            visible: box.sideUrl === "" || sImg.status === Image.Error
            anchors.centerIn: parent
            width: parent.height * 0.86; height: parent.width
            rotation: -90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: box.lightPlastic ? "#26282d" : "#eceef2"
            font { family: box.theme ? box.theme.fontFamily : "sans"; pixelSize: Math.max(12, parent.width * 0.42); weight: Font.Bold }
        }
    }

    Node {
        eulerRotation.x: -(box.place.pitch || 0)

        // Ink outline: the box grown a little and drawn inside out, flat dark.
        Model {
            id: outline
            castsShadows: false
            pickable: false
            readonly property real t: 2.2
            readonly property var mesh: Mesh.hull(box.bw + 2 * t, box.bh + 2 * t, box.bd + 2 * t, box.round + t, 2)
            geometry: ProceduralMesh {
                positions: outline.mesh.positions
                normals: outline.mesh.normals
                uv0s: outline.mesh.uv0s
                indexes: outline.mesh.indexes
            }
            materials: PrincipledMaterial {
                lighting: PrincipledMaterial.NoLighting
                baseColor: box.ink
                cullMode: Material.FrontFaceCulling
            }
        }

        // Front: the cover, varnished (or under the keep case's sleeve).
        Face {
            side: "front"
            property int slotIndex: box.slotIndex
            pickable: true
            materials: PrincipledMaterial {
                baseColorMap: Texture {
                    generateMipmaps: true
                    mipFilter: Texture.Linear
                    sourceItem: Print { width: 560; height: Math.round(560 * box.bh / box.bw); src: box.frontUrl }
                }
                roughness: box.card ? 0.62 : 0.45
                specularAmount: 0.35
                clearcoatAmount: box.card ? 0.15 : 0.6
                clearcoatRoughnessAmount: box.card ? 0.4 : 0.06
                normalMap: Grain { }
                normalStrength: box.card ? 0.22 : 0.1
            }
        }
        // The same spine on both sides.
        Repeater3D {
            model: ["left", "right"]
            Face {
                required property string modelData
                side: modelData
                materials: PrincipledMaterial {
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Spine { width: 96; height: 800 } }
                    roughness: box.card ? 0.62 : 0.45
                    specularAmount: 0.35
                    clearcoatAmount: box.card ? 0.15 : 0.6
                    clearcoatRoughnessAmount: box.card ? 0.4 : 0.06
                }
            }
        }
        // Back: the back scan, else the console's plastic.
        Face {
            side: "back"
            materials: PrincipledMaterial {
                baseColor: box.backUrl !== "" ? "white" : box.plastic
                baseColorMap: box.backUrl !== "" ? backTex : null
                roughness: box.card ? 0.62 : 0.45
                specularAmount: 0.35
                clearcoatAmount: box.card ? 0.15 : 0.5
                clearcoatRoughnessAmount: box.card ? 0.4 : 0.08
            }
            Texture {
                id: backTex
                generateMipmaps: true
                sourceItem: Print { width: 560; height: Math.round(560 * box.bh / box.bw); src: box.backUrl; titled: false }
            }
        }
        // Top and bottom: the console's plastic, satin with a grain.
        Repeater3D {
            model: ["top", "bottom"]
            Face {
                required property string modelData
                side: modelData
                materials: PrincipledMaterial {
                    baseColor: box.plastic
                    roughness: box.lightPlastic ? 0.34 : 0.4
                    specularAmount: 0.5
                    clearcoatAmount: 0.2
                    clearcoatRoughnessAmount: 0.3
                    normalMap: Grain { }
                    normalStrength: 0.35
                }
            }
        }
    }
}
