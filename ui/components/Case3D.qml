// One game case as a real 3D object (Qt Quick 3D), lit by the shelf's lights and casting a
// shadow on its floor. Built per material, to the case's real proportions:
//  keep case  — coloured plastic shell, the printed insert under a clear glossy sleeve;
//  jewel case — black tray, the booklet under a clear lid with its hinge;
//  clamshell  — hard plastic shell around the printed insert;
//  cardboard  — printed all over, matte.
// Printed faces are the ScreenScraper scans (front, spine, back) or the cover; a missing spine is
// drawn as a band in the case's colour with the title. Coordinates: x right, y up, z toward you.
import QtQuick
import QtQuick3D
import "Cases.js" as Cases

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
    readonly property real mm: boxH / Cases.TALLEST
    readonly property bool frontScan: has("front")
    readonly property real frontAR: frontScan && game.front_ar > 0 ? game.front_ar : (game && game.cover_ar > 0 ? game.cover_ar : 0)
    readonly property real sideAR: has("side") && game.side_ar > 0 ? game.side_ar : 0
    readonly property bool turned: !!kind.turns && frontAR > 0 && frontAR < 1
    readonly property real rim: mat === "keep" ? 6 : mat === "clam" ? 4 : mat === "jewel" ? 2 : 0
    readonly property real hinge: mat === "jewel" ? bh * 0.075 : 0
    readonly property real bh: (turned ? kind.w : kind.h) * mm
    readonly property real bw: frontAR > 0 ? Math.max(0.5, Math.min(1.6, frontAR)) * (bh - 2 * rim) + 2 * rim + hinge
                                           : (turned ? kind.h : kind.w) * mm
    readonly property real bd: sideAR > 0 ? Math.max(5, Math.min(bh * 0.3, sideAR * bh)) : Math.max(6, kind.d * mm)
    readonly property color tone: theme ? theme.tone(game ? game.hue : 0) : "#444"
    readonly property color shell: mat === "card" ? Qt.darker(tone, 1.6) : kind.color
    readonly property string frontUrl: frontScan ? game.art + "front" : (game && game.cover ? game.cover : "")

    // Bottom on the floor (y = 0 at the shelf's middle line, cases standing on boxH / 2 below).
    position: Qt.vector3d(place.x, -(place.y || 0) - boxH / 2 + bh / 2, place.z)
    eulerRotation.y: place.ang

    Node {
        eulerRotation.x: -(box.place.pitch || 0)

        // ---------- the shell (plastic or cardboard): a block slightly smaller than the faces ----------
        Model {
            source: "#Cube"
            scale: Qt.vector3d((box.bw - 0.6) / 100, (box.bh - 0.6) / 100, (box.bd - 0.6) / 100)
            materials: PrincipledMaterial {
                baseColor: box.shell
                roughness: box.mat === "card" ? 0.8 : 0.32
                clearcoatAmount: box.mat === "card" ? 0 : 0.6
                clearcoatRoughnessAmount: 0.2
            }
        }

        // ---------- front: the printed cover ----------
        Model {
            id: frontFace
            property int slotIndex: box.slotIndex
            pickable: true
            source: "#Rectangle"
            position: Qt.vector3d(box.hinge / 2, 0, box.bd / 2 + 0.25)
            scale: Qt.vector3d((box.bw - 2 * box.rim - box.hinge) / 100, (box.bh - 2 * box.rim) / 100, 1)
            materials: PrincipledMaterial {
                baseColorMap: Texture {
                    // An item tree, not a bare Image: the texture is redrawn when the scan
                    // arrives, and a plain cover in the platform's tone shows until then.
                    sourceItem: Rectangle {
                        width: 512; height: 768
                        gradient: Gradient {
                            GradientStop { position: 0; color: Qt.lighter(box.tone, 1.25) }
                            GradientStop { position: 1; color: Qt.darker(box.tone, 1.9) }
                        }
                        Text {
                            visible: frontImg.status !== Image.Ready
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 36 }
                            text: box.game ? box.game.name : ""
                            color: "white"; font.pixelSize: 64; font.bold: true
                            wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight
                        }
                        Image {
                            id: frontImg
                            anchors.fill: parent
                            source: box.frontUrl
                            sourceSize: Qt.size(512, 768)
                            fillMode: Image.Stretch
                            asynchronous: true
                        }
                    }
                }
                roughness: box.mat === "card" ? 0.75 : 0.5
            }
        }
        // Clear sleeve or lid over the cover: catches the lights as the case turns.
        Model {
            visible: box.mat !== "card"
            source: "#Rectangle"
            position: Qt.vector3d(0, 0, box.bd / 2 + 0.6)
            scale: Qt.vector3d(box.bw / 100, box.bh / 100, 1)
            materials: PrincipledMaterial {
                baseColor: Qt.rgba(1, 1, 1, box.mat === "jewel" ? 0.07 : 0.04)
                alphaMode: PrincipledMaterial.Blend
                roughness: 0.06
                specularAmount: 1
                clearcoatAmount: 1
                clearcoatRoughnessAmount: 0.02
            }
        }
        // Jewel case hinge: a clear ribbed strip on the left of the lid.
        Model {
            visible: box.mat === "jewel"
            source: "#Cube"
            position: Qt.vector3d(-box.bw / 2 + box.hinge / 2, 0, box.bd / 2 - 0.4)
            scale: Qt.vector3d(box.hinge / 100, box.bh / 100, 1.2 / 100)
            materials: PrincipledMaterial { baseColor: "#2a2c31"; roughness: 0.15; clearcoatAmount: 1 }
        }

        // ---------- spine (left) ----------
        Model {
            source: "#Rectangle"
            position: Qt.vector3d(-box.bw / 2 - 0.25, 0, 0)
            eulerRotation.y: -90
            scale: Qt.vector3d((box.bd - 2) / 100, (box.bh - 2) / 100, 1)
            materials: PrincipledMaterial {
                baseColorMap: Texture {
                    sourceItem: Item {
                        id: spineItem
                        width: 64; height: 640
                        Rectangle { anchors.fill: parent; color: box.shell }
                        Image {
                            id: spineScan
                            anchors.fill: parent
                            source: box.has("side") ? box.game.art + "side" : ""
                            asynchronous: true
                            fillMode: Image.Stretch
                            sourceSize: Qt.size(96, 900)
                        }
                        Text {
                            visible: spineScan.status !== Image.Ready
                            anchors.centerIn: parent
                            width: parent.height - 60; height: parent.width
                            rotation: -90
                            text: box.game ? box.game.name : ""
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            color: Qt.colorEqual(box.kind.color, "#eceef1") || Qt.colorEqual(box.kind.color, "#dfe2e6") ? "#26282d" : "#eceef2"
                            font { family: box.theme ? box.theme.fontFamily : "sans"; pixelSize: 30; weight: Font.Bold }
                        }
                    }
                }
                roughness: box.mat === "card" ? 0.75 : 0.4
                clearcoatAmount: box.mat === "card" ? 0 : 0.5
            }
        }
        // ---------- back ----------
        Model {
            visible: box.has("back")
            source: "#Rectangle"
            position: Qt.vector3d(0, 0, -box.bd / 2 - 0.25)
            eulerRotation.y: 180
            scale: Qt.vector3d((box.bw - 2 * box.rim) / 100, (box.bh - 2 * box.rim) / 100, 1)
            materials: PrincipledMaterial {
                roughness: 0.6
                baseColorMap: Texture {
                    sourceItem: Image {
                        source: box.has("back") ? box.game.art + "back" : ""
                        width: 512; height: 768
                        sourceSize: Qt.size(512, 768)
                        fillMode: Image.Stretch
                        asynchronous: true
                    }
                }
            }
        }
    }
}
