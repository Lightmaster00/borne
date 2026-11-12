// One game case as a 3D object (Qt Quick 3D): a box to the case's real proportions with slightly
// rounded corners and edges, cel shaded inside a bold ink outline. The front is the cover scan, the
// same spine on the left and the right, the back scan behind, and the console's plastic colour on
// the top and the bottom, all printed flat (unlit). A skin just over the box (toon.frag) multiplies
// them by flat light bands whose dark side takes the console's colour, with a paper or plastic grain;
// a second one (gloss.frag) adds a crisp highlight and a rim of the console's colour on the edges.
// Coordinates: x right, y up, z toward you.
import QtQuick
import QtQuick.Effects
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
    readonly property real round: (card ? 2.2 : 3.6) * mm
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
    readonly property color consoleTint: Cases.tint(game ? game.platform_slug : "")
    readonly property real printSaturation: -0.3
    // A flat print: no lighting of its own, the shading skin does it.
    component Flat: PrincipledMaterial {
        lighting: PrincipledMaterial.NoLighting
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
            // Printed flat and unlit, scans look harsh: their colours toned down like ink on card.
            layer.enabled: true
            layer.effect: MultiEffect { saturation: box.printSaturation }
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
            layer.enabled: true
            layer.effect: MultiEffect { saturation: box.printSaturation }
        }
        // No spine scan: the game's logo turned along the spine (ScreenScraper's wheel), on a band
        // in the console's colour; else its title.
        Image {
            id: sLogo
            visible: (box.sideUrl === "" || sImg.status === Image.Error) && status === Image.Ready
            anchors.centerIn: parent
            width: parent.height * 0.7; height: parent.width * 0.78
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
            readonly property real t: 5.5
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
            materials: Flat {
                baseColorMap: Texture {
                    generateMipmaps: true
                    mipFilter: Texture.Linear
                    sourceItem: Print { width: 560; height: Math.round(560 * box.bh / box.bw); src: box.frontUrl }
                }
            }
        }
        // The same spine on both sides.
        Repeater3D {
            model: ["left", "right"]
            Face {
                required property string modelData
                side: modelData
                materials: Flat {
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Spine { width: 96; height: 800 } }
                }
            }
        }
        // Back: the back scan, else the console's plastic.
        Face {
            side: "back"
            materials: Flat {
                baseColor: box.backUrl !== "" ? "white" : box.plastic
                baseColorMap: box.backUrl !== "" ? backTex : null
            }
            Texture {
                id: backTex
                generateMipmaps: true
                sourceItem: Print { width: 560; height: Math.round(560 * box.bh / box.bw); src: box.backUrl; titled: false }
            }
        }
        // Top and bottom: the console's plastic.
        Repeater3D {
            model: ["top", "bottom"]
            Face {
                required property string modelData
                side: modelData
                materials: Flat { baseColor: box.plastic }
            }
        }

        // The shading skin: the box grown a hair, multiplied onto the flat prints under it.
        Model {
            id: skin
            castsShadows: false
            receivesShadows: true
            pickable: false
            readonly property real e: 0.6
            readonly property var mesh: Mesh.hull(box.bw + 2 * e, box.bh + 2 * e, box.bd + 2 * e, box.round + e, 4)
            geometry: ProceduralMesh {
                positions: skin.mesh.positions
                normals: skin.mesh.normals
                uv0s: skin.mesh.uv0s
                indexes: skin.mesh.indexes
            }
            Texture {
                id: grainTexture
                source: "grain.png"
                tilingModeHorizontal: Texture.Repeat
                tilingModeVertical: Texture.Repeat
            }
            materials: CustomMaterial {
                shadingMode: CustomMaterial.Shaded
                fragmentShader: "toon.frag"
                sourceBlend: CustomMaterial.DstColor
                destinationBlend: CustomMaterial.Zero
                property TextureInput grainTex: TextureInput { texture: grainTexture }
                // Dark side: the console's colour, deep; half tone: a lighter, warmer step.
                property color shadeTint: Qt.rgba(box.consoleTint.r * 0.16 + 0.22, box.consoleTint.g * 0.16 + 0.22, box.consoleTint.b * 0.16 + 0.25, 1)
                property color midTint: Qt.rgba(0.70, 0.70, 0.72, 1)
                property real grainAmount: box.card ? 0.10 : 0.06
                property real grainScale: Math.max(2, box.bh / 30)
            }
        }
        // The gloss skin: highlight and coloured rim, added over the shaded box.
        Model {
            castsShadows: false
            receivesShadows: true
            pickable: false
            geometry: skin.geometry
            scale: Qt.vector3d(1 + 0.8 / box.bw, 1 + 0.8 / box.bh, 1 + 0.8 / box.bd)
            materials: CustomMaterial {
                shadingMode: CustomMaterial.Shaded
                fragmentShader: "gloss.frag"
                sourceBlend: CustomMaterial.One
                destinationBlend: CustomMaterial.One
                property color rimColor: Qt.lighter(box.consoleTint, 1.25)
                property real rimStrength: 0.75
                // Varnished prints and clear plastic glint; cardboard barely.
                property real glint: box.card ? 0.18 : 0.42
            }
        }
    }
}
