// One game case as a real 3D object (Qt Quick 3D), modelled after the retail case of its console
// and lit by the shelf's studio. Real proportions in millimetres (Cases.js), and the small
// details that make each one read as an object you could pick up:
//  keep case  — two plastic halves with the seam groove round the opening edges, rounded
//               corners, the printed insert folded round the spine (creases at the folds) and the
//               clear sleeve over everything, lifting off the bevel at the opening edge;
//  clamshell  — the same build in thicker, matte textured plastic with rounder corners;
//  jewel case — clear lid and base, the black tray inside, the booklet under the lid, the hinge
//               strip with its ribs and the two knuckles, the back insert seen through the base
//               with its two folded spine labels;
//  cardboard  — printed on every face, the corners slightly worn to the board, tuck flaps
//               marked on the top and bottom.
// Printed faces are the ScreenScraper scans (front, spine, back) or the cover; a missing spine is
// drawn as a band in the case's colour with the title. Coordinates: x right, y up, z toward you.
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
    readonly property string mat: kind.mat
    readonly property bool plastic: mat === "keep" || mat === "clam"
    readonly property real mm: boxH / Cases.TALLEST
    readonly property bool frontScan: has("front")
    readonly property real frontAR: frontScan && game.front_ar > 0 ? game.front_ar : (game && game.cover_ar > 0 ? game.cover_ar : 0)
    readonly property real sideAR: has("side") && game.side_ar > 0 ? game.side_ar : 0
    readonly property bool turned: !!kind.turns && frontAR > 0 && frontAR < 1
    // Plastic left visible round the printed insert, and the jewel case's hinge strip.
    readonly property real rim: (mat === "keep" ? 3.2 : mat === "clam" ? 4.2 : mat === "jewel" ? 1.4 : 0) * mm
    readonly property real hinge: mat === "jewel" ? 9 * mm : 0
    readonly property real bh: (turned ? kind.w : kind.h) * mm
    readonly property real bw: frontAR > 0 ? Math.max(0.5, Math.min(1.6, frontAR)) * (bh - 2 * rim) + 2 * rim + hinge
                                           : (turned ? kind.h : kind.w) * mm
    readonly property real bd: sideAR > 0 && mat !== "jewel" ? Math.max(5, Math.min(bh * 0.3, sideAR * bh)) : Math.max(6, kind.d * mm)
    readonly property color tone: theme ? theme.tone(game ? game.hue : 0) : "#444"
    readonly property color shell: mat === "card" ? Qt.darker(tone, 1.6) : kind.color
    readonly property bool lightShell: shell.hslLightness > 0.6
    readonly property string frontUrl: frontScan ? game.art + "front" : (game && game.cover ? game.cover : "")
    readonly property string sideUrl: has("side") ? game.art + "side" : ""
    readonly property string backUrl: has("back") ? game.art + "back" : ""

    // Corner radius seen from the front, and the radius of the edges round the faces.
    readonly property real cornerR: (mat === "keep" ? 4 : mat === "clam" ? 6 : mat === "jewel" ? 1.2 : 0.9) * mm
    readonly property real edgeR: (mat === "keep" ? 1.8 : mat === "clam" ? 2.6 : mat === "jewel" ? 0.5 : 0.7) * mm
    readonly property real eps: 0.14 * mm

    // ---- geometry (recomputed when the case's size changes) ----
    readonly property real seam: 0.35 * mm
    readonly property var shellFrontMesh: plastic ? Mesh.slab(bw, bh, seam, bd / 2, cornerR, edgeR) : null
    readonly property var shellBackMesh: plastic ? Mesh.slab(bw, bh, -bd / 2, -seam, cornerR, edgeR) : null
    readonly property var coreMesh: plastic ? Mesh.slab(bw - 1.4 * mm, bh - 1.4 * mm, -seam - 1.5 * mm, seam + 1.5 * mm, cornerR - 0.7 * mm, 0.2 * mm) : null
    readonly property var insertMesh: plastic ? Mesh.wrap(bw / 2 + eps, bd / 2 + eps, bw / 2 - rim, bh / 2 - rim, edgeR + eps) : null
    readonly property var sleeveMesh: plastic ? Mesh.wrap(bw / 2 + 2 * eps, bd / 2 + 2 * eps, bw / 2 - 0.35 * mm, bh / 2 - 0.25 * mm, edgeR + 2 * eps) : null
    readonly property var solidMesh: mat === "card" || mat === "jewel" ? Mesh.slab(bw, bh, -bd / 2, bd / 2, cornerR, edgeR) : null
    readonly property var trayMesh: mat === "jewel" ? Mesh.slab(bw - 1.8 * mm, bh - 1.6 * mm, -bd / 2 + 0.9 * mm, bd / 2 - 2.4 * mm, 0.8 * mm, 0.3 * mm) : null

    // Bottom on the floor (y = 0 at the shelf's middle line, cases standing on boxH / 2 below).
    position: Qt.vector3d(place.x, -(place.y || 0) - boxH / 2 + bh / 2, place.z)
    eulerRotation.y: place.ang

    // ---- printed pieces ----
    // A scan, or a plain print in the platform's tone with the title until it arrives.
    component Print: Rectangle {
        property string src
        property bool titled: true
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.lighter(box.tone, 1.25) }
            GradientStop { position: 1; color: Qt.darker(box.tone, 1.9) }
        }
        Text {
            visible: parent.titled && img.status !== Image.Ready
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
    // The spine: its scan, else a band in the case's colour with the title.
    component Spine: Rectangle {
        color: box.mat === "card" ? Qt.darker(box.tone, 1.4) : box.shell
        Image {
            id: sImg
            anchors.fill: parent
            source: box.sideUrl
            asynchronous: true
            fillMode: Image.Stretch
            sourceSize: Qt.size(Math.max(32, parent.width), parent.height)
        }
        Text {
            visible: sImg.status !== Image.Ready
            anchors.centerIn: parent
            width: parent.height * 0.86; height: parent.width
            rotation: -90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: box.lightShell && box.mat !== "card" ? "#26282d" : "#eceef2"
            font { family: box.theme ? box.theme.fontFamily : "sans"; pixelSize: Math.max(12, parent.width * 0.42); weight: Font.Bold }
        }
    }
    // A fold in the printed paper: a soft shadow line with a highlight beside it.
    component Crease: Item {
        width: 10
        Rectangle { x: 0; width: 5; height: parent.height; gradient: Gradient { orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#00000000" } GradientStop { position: 1; color: "#38000000" } } }
        Rectangle { x: 5; width: 5; height: parent.height; gradient: Gradient { orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "#24ffffff" } GradientStop { position: 1; color: "#00ffffff" } } }
    }

    component MeshModel: Model {
        property var mesh
        geometry: ProceduralMesh {
            positions: mesh ? mesh.positions : []
            normals: mesh ? mesh.normals : []
            uv0s: mesh ? mesh.uv0s : []
            indexes: mesh ? mesh.indexes : []
        }
    }

    Node {
        eulerRotation.x: -(box.place.pitch || 0)
        // Only the parts of this case's kind exist.
        Loader3D { sourceComponent: box.plastic ? keepBody : box.mat === "jewel" ? jewelBody : cardBody }
    }

    Component {
        id: keepBody
        Node {
            // ================= keep case and clamshell =================
            // Front and back halves, the darker core showing in the seam between them.
            MeshModel {
                mesh: box.shellFrontMesh
                materials: plasticMat
            }
            MeshModel {
                mesh: box.shellBackMesh
                materials: plasticMat
            }
            MeshModel {
                mesh: box.coreMesh
                materials: PrincipledMaterial { baseColor: Qt.darker(box.shell, 2.2); roughness: 0.7 }
            }
            PrincipledMaterial {
                id: plasticMat
                baseColor: box.shell
                // Keep cases are a fine satin plastic; the Mega Drive clamshell a coarser matte grain.
                roughness: box.mat === "clam" ? 0.62 : box.lightShell ? 0.36 : 0.42
                specularAmount: 0.55
                clearcoatAmount: box.mat === "clam" ? 0 : 0.25
                clearcoatRoughnessAmount: 0.35
            }
            // The printed insert: back, spine and front in one sheet folded round the spine.
            MeshModel {
                id: insert
                property int slotIndex: box.slotIndex
                pickable: true
                castsShadows: false
                mesh: box.insertMesh
                materials: PrincipledMaterial {
                    roughness: 0.55
                    specularAmount: 0.3
                    baseColorMap: Texture {
                        generateMipmaps: true
                        mipFilter: Texture.Linear
                        sourceItem: Sheet { }
                    }
                }
            }
            // Clear sleeve over the whole case: thin, glossy, it catches the studio's softboxes.
            MeshModel {
                castsShadows: false
                pickable: false
                mesh: box.sleeveMesh
                materials: clearMat
            }
            PrincipledMaterial {
                id: clearMat
                // Black and screen-blended: only the reflections show, added over the print,
                // stronger at grazing angles as on real clear plastic.
                baseColor: "black"
                blendMode: PrincipledMaterial.Screen
                roughness: 0.04
                specularAmount: 1
                clearcoatAmount: 1
                clearcoatRoughnessAmount: 0.02
                cullMode: Material.NoCulling
            }
        }
    }
    Component {
        id: jewelBody
        Node {
            // ================= jewel case =================
            // Black tray inside the clear case.
            MeshModel {
                mesh: box.trayMesh
                materials: PrincipledMaterial { baseColor: box.shell; roughness: 0.3; specularAmount: 0.6 }
            }
            // The booklet under the lid.
            Model {
                property int slotIndex: box.slotIndex
                pickable: true
                source: "#Rectangle"
                position: Qt.vector3d(box.hinge / 2 - box.rim / 2 + 0.3 * box.mm, 0, box.bd / 2 - 1.0 * box.mm)
                scale: Qt.vector3d((box.bw - box.hinge - box.rim - 0.6 * box.mm) / 100, (box.bh - 2 * box.rim) / 100, 1)
                materials: PrincipledMaterial {
                    roughness: 0.5
                    specularAmount: 0.35
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Print { width: 640; height: 640; src: box.mat === "jewel" ? box.frontUrl : "" } }
                }
            }
            // The lid's hinge strip on the left of the front: ribbed clear plastic over the tray.
            Model {
                source: "#Rectangle"
                position: Qt.vector3d(-box.bw / 2 + box.hinge / 2 + 0.3 * box.mm, 0, box.bd / 2 - 1.1 * box.mm)
                scale: Qt.vector3d((box.hinge - 0.6 * box.mm) / 100, (box.bh - 1.6 * box.mm) / 100, 1)
                materials: PrincipledMaterial {
                    roughness: 0.25
                    specularAmount: 0.8
                    baseColorMap: Texture { sourceItem: Ribs { } }
                }
            }
            // The two hinge knuckles at the ends of the left edge.
            Repeater3D {
                model: 2
                Model {
                    required property int index
                    source: "#Cylinder"
                    position: Qt.vector3d(-box.bw / 2 + 1.7 * box.mm, (index ? -1 : 1) * (box.bh / 2 - 8.5 * box.mm), box.bd / 2 - 2.3 * box.mm)
                    scale: Qt.vector3d(3.0 * box.mm / 100, 13 * box.mm / 100, 3.0 * box.mm / 100)
                    materials: PrincipledMaterial {
                        baseColor: Qt.rgba(0.82, 0.85, 0.88, 0.35)
                        alphaMode: PrincipledMaterial.Blend
                        roughness: 0.08
                        specularAmount: 1
                    }
                }
            }
            // The back insert seen through the base, and its spine labels folded up both sides.
            Model {
                source: "#Rectangle"
                position: Qt.vector3d(0, 0, -box.bd / 2 + 0.6 * box.mm)
                eulerRotation.y: 180
                scale: Qt.vector3d((box.bw - 3 * box.mm) / 100, (box.bh - 2.6 * box.mm) / 100, 1)
                materials: PrincipledMaterial {
                    roughness: 0.55
                    baseColorMap: Texture { generateMipmaps: true; sourceItem: Print { width: 640; height: 560; src: box.mat === "jewel" ? box.backUrl : ""; titled: false } }
                }
            }
            Repeater3D {
                model: 2
                Model {
                    required property int index
                    source: "#Rectangle"
                    position: Qt.vector3d((index ? 1 : -1) * (box.bw / 2 - 0.7 * box.mm), 0, -0.6 * box.mm)
                    eulerRotation.y: index ? 90 : -90
                    scale: Qt.vector3d((box.bd - 2.6 * box.mm) / 100, (box.bh - 2.6 * box.mm) / 100, 1)
                    materials: PrincipledMaterial {
                        roughness: 0.5
                        baseColorMap: Texture { generateMipmaps: true; sourceItem: Spine { width: 48; height: 640 } }
                    }
                }
            }

            // The clear case itself, over everything.
            MeshModel {
                castsShadows: false
                mesh: box.solidMesh
                materials: PrincipledMaterial {
                    // screen-blended reflections and a faint haze: the clear plastic and its edges
                    baseColor: "#0d0f12"
                    blendMode: PrincipledMaterial.Screen
                    roughness: 0.02
                    specularAmount: 1
                    clearcoatAmount: 1
                    clearcoatRoughnessAmount: 0.01
                    cullMode: Material.NoCulling
                }
            }
        }
    }
    Component {
        id: cardBody
        Node {
            // ================= cardboard box =================
            MeshModel {
                mesh: box.solidMesh
                materials: boardMat
            }
            // Board showing at the worn corners and edges: the print's own colour faded toward grey.
            PrincipledMaterial {
                id: boardMat
                baseColor: Qt.tint(Qt.darker(box.tone, 1.3), "#8cc9c2b4")
                roughness: 0.9
            }
            // Printed faces of the box, over the board: front, back, both sides, top and bottom.
            Model {
                property int slotIndex: box.slotIndex
                pickable: true
                source: "#Rectangle"
                position: Qt.vector3d(0, 0, box.bd / 2 + 0.05 * box.mm)
                scale: Qt.vector3d((box.bw - 1.3 * box.mm) / 100, (box.bh - 1.3 * box.mm) / 100, 1)
                materials: PrincipledMaterial {
                    roughness: 0.62; specularAmount: 0.4; clearcoatAmount: 0.12; clearcoatRoughnessAmount: 0.45
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Print { width: 560; height: 800; src: box.mat === "card" ? box.frontUrl : "" } }
                }
            }
            Model {
                source: "#Rectangle"
                position: Qt.vector3d(0, 0, -box.bd / 2 - 0.05 * box.mm)
                eulerRotation.y: 180
                scale: Qt.vector3d((box.bw - 1.3 * box.mm) / 100, (box.bh - 1.3 * box.mm) / 100, 1)
                materials: PrincipledMaterial {
                    roughness: 0.62; specularAmount: 0.4; clearcoatAmount: 0.12; clearcoatRoughnessAmount: 0.45
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Print { width: 560; height: 800; src: box.mat === "card" ? box.backUrl : ""; titled: false } }
                }
            }
            Repeater3D {
                model: 2
                Model {
                    required property int index
                    source: "#Rectangle"
                    position: Qt.vector3d((index ? 1 : -1) * (box.bw / 2 + 0.05 * box.mm), 0, 0)
                    eulerRotation.y: index ? 90 : -90
                    scale: Qt.vector3d((box.bd - 1.3 * box.mm) / 100, (box.bh - 1.3 * box.mm) / 100, 1)
                    materials: PrincipledMaterial {
                    roughness: 0.62; specularAmount: 0.4; clearcoatAmount: 0.12; clearcoatRoughnessAmount: 0.45
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Spine { width: 96; height: 800 } }
                }
                }
            }
            Repeater3D {
                model: 2
                Model {
                    required property int index
                    source: "#Rectangle"
                    position: Qt.vector3d(0, (index ? -1 : 1) * (box.bh / 2 + 0.05 * box.mm), 0)
                    eulerRotation.x: index ? 90 : -90
                    scale: Qt.vector3d((box.bw - 1.3 * box.mm) / 100, (box.bd - 1.3 * box.mm) / 100, 1)
                    materials: PrincipledMaterial {
                    roughness: 0.62; specularAmount: 0.4; clearcoatAmount: 0.12; clearcoatRoughnessAmount: 0.45
                    baseColorMap: Texture { generateMipmaps: true; mipFilter: Texture.Linear; sourceItem: Flap { } }
                }
                }
            }
        }
    }

    // ---- the textures' item trees ----
    // Keep case insert: back | spine | front, as wide as their share of the folded sheet.
    component Sheet: Item {
        id: sheet
        readonly property real share: box.insertMesh ? box.insertMesh.back : 0.45
        readonly property real faceW: 560
        width: Math.round(faceW / Math.max(0.2, share)); height: 800
        Print { x: 0; width: sheet.faceW; height: sheet.height; src: box.backUrl; titled: false }
        Spine { x: sheet.faceW; width: sheet.width - 2 * sheet.faceW; height: sheet.height }
        Print { x: sheet.width - sheet.faceW; width: sheet.faceW; height: sheet.height; src: box.frontUrl }
        Crease { x: sheet.faceW - 5; height: sheet.height }
        Crease { x: sheet.width - sheet.faceW - 5; height: sheet.height }
    }
    // Hinge strip: dark tray seen through clear plastic moulded in fine vertical ribs.
    component Ribs: Canvas {
        width: 64; height: 256
        onPaint: {
            const c = getContext("2d")
            c.fillStyle = "#101114"; c.fillRect(0, 0, width, height)
            for (let x = 3; x < width; x += 6) {
                c.fillStyle = "rgba(255,255,255,0.10)"; c.fillRect(x, 0, 2, height)
                c.fillStyle = "rgba(0,0,0,0.35)"; c.fillRect(x + 2, 0, 1, height)
            }
            // the lid's edge where it meets the booklet
            c.fillStyle = "rgba(255,255,255,0.22)"; c.fillRect(width - 3, 0, 2, height)
        }
    }
    // Top and bottom of the box: the tuck flap's fold and its cut edge.
    component Flap: Rectangle {
        width: 512; height: 96
        color: Qt.darker(box.tone, 1.5)
        Rectangle { y: parent.height * 0.12; width: parent.width; height: 3; color: "#40000000" }
        Rectangle { y: parent.height * 0.12 + 3; width: parent.width; height: 2; color: "#18ffffff" }
        Rectangle { y: parent.height * 0.86; width: parent.width; height: 2; color: "#55000000" }
    }
}
