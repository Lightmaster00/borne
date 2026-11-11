// The library as real 3D game cases (Qt Quick 3D): the selected case faces you, a little forward;
// the others turn toward it and recede to the sides. A key light from above left casts soft
// shadows on a dark floor, a fill light from the right and a rim light from behind shape the
// edges, and the clear plastic of the cases catches them as they move.
// Same interface and layout as BoxShelf (its 2D fallback); only the 13 cases around the
// selection exist, however large the library.
import QtQuick
import QtQuick3D

Item {
    id: shelf
    property QtObject theme
    property var games
    property int currentIndex: 0
    property bool pointerActive: false
    property int revision: 0
    property bool showSelection: true
    property real userYaw: 0
    property real userPitch: 0
    property real swayAmp: 4
    property int swayPeriod: 3600
    signal picked(int index)

    readonly property real boxH: 420
    readonly property real focal: 1500
    readonly property int slots: 13
    property real probeYaw: 0
    readonly property bool userTurned: Math.abs(userYaw) > 0.5 || Math.abs(userPitch) > 0.5

    property real flow: currentIndex
    Behavior on flow { NumberAnimation { duration: 460; easing.type: Easing.OutCubic } }
    property real sway: 0
    SequentialAnimation on sway {
        loops: Animation.Infinite
        running: shelf.visible
        NumberAnimation { from: -1; to: 1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: -1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
    }

    // Same placement as BoxShelf (y down there; Case3D turns it up).
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
        let pitch = 0
        if (a < 0.5) {
            const k = 1 - 2 * a
            ang += (shelf.userTurned ? shelf.userYaw : shelf.sway * shelf.swayAmp) * k
            pitch = shelf.userPitch * k
        }
        return { x: x, y: a < 1 ? -8 * (1 - a) : 0, z: z, ang: ang, pitch: pitch }
    }

    View3D {
        id: view
        anchors.fill: parent
        renderMode: View3D.Offscreen
        environment: SceneEnvironment {
            backgroundMode: SceneEnvironment.Transparent
            antialiasingMode: SceneEnvironment.MSAA
            antialiasingQuality: SceneEnvironment.High
            tonemapMode: SceneEnvironment.TonemapModeNone
            aoEnabled: true
            aoStrength: 40
            aoDistance: 18
            aoSoftness: 40
            // The photo studio (scripts/gen-studio-hdr.py): its softboxes and strips are what
            // the clear sleeves, jewel cases and plastic reflect.
            lightProbe: Texture { source: "studio.hdr"; mappingMode: Texture.LightProbe }
            probeExposure: 0.9
            probeOrientation: Qt.vector3d(0, shelf.probeYaw, 0)
        }

        PerspectiveCamera {
            position: Qt.vector3d(0, 0, shelf.focal)
            fieldOfViewOrientation: PerspectiveCamera.Vertical
            fieldOfView: 2 * Math.atan(shelf.height / 2 / shelf.focal) * 180 / Math.PI
            clipNear: 10
            clipFar: 6000
        }

        // Key light: above, left and in front; soft shadows on the floor.
        DirectionalLight {
            eulerRotation: Qt.vector3d(-38, -28, 0)
            brightness: 1.25
            color: "#fff6ea"
            castsShadow: true
            shadowMapQuality: Light.ShadowMapQualityHigh
            shadowFactor: 55
            softShadowQuality: Light.PCF16
            pcfFactor: 6
            shadowBias: 8
        }
        // Fill from the right, cooler and weaker.
        DirectionalLight {
            eulerRotation: Qt.vector3d(-12, 48, 0)
            brightness: 0.45
            color: "#dfe8ff"
        }
        // Rim light from behind, to separate the edges from the background.
        DirectionalLight {
            eulerRotation: Qt.vector3d(-20, 170, 0)
            brightness: 0.6
        }

        // Floor: dark, faintly glossy, fading out toward the edges so it has no visible border;
        // it receives the cases' shadows and a soft reflection of the light.
        Model {
            source: "#Rectangle"
            position: Qt.vector3d(0, -shelf.boxH / 2 - 0.5, -120)
            eulerRotation.x: -90
            scale: Qt.vector3d(36, 16, 1)
            // Only on the shelf: the game page's view is too narrow for it to fade out unseen.
            visible: shelf.showSelection
            receivesShadows: true
            castsShadows: false
            pickable: false
            materials: PrincipledMaterial {
                baseColor: Qt.rgba(0.02, 0.022, 0.03, 1)
                alphaMode: PrincipledMaterial.Blend
                opacityMap: Texture {
                    sourceItem: Canvas {
                        width: 256; height: 256
                        onPaint: {
                            const c = getContext("2d")
                            c.clearRect(0, 0, width, height)
                            const g = c.createRadialGradient(128, 150, 0, 128, 150, 128)
                            g.addColorStop(0, "rgba(255,255,255,0.78)")
                            g.addColorStop(0.55, "rgba(255,255,255,0.45)")
                            g.addColorStop(1, "rgba(255,255,255,0)")
                            c.fillStyle = g
                            c.fillRect(0, 0, width, height)
                        }
                    }
                }
                opacityChannel: Material.A
                roughness: 0.55
                specularAmount: 0.12
            }
        }

        Repeater3D {
            model: shelf.slots
            Node {
                id: slot
                required property int index
                readonly property int gameIndex: Math.round(shelf.flow) + index - Math.floor(shelf.slots / 2)
                readonly property bool valid: shelf.games && gameIndex >= 0 && gameIndex < shelf.games.count
                readonly property var game: valid ? (shelf.revision, shelf.games.count, shelf.games.get(gameIndex)) : null
                readonly property real t: gameIndex - shelf.flow
                visible: valid && Math.abs(t) < shelf.slots / 2
                opacity: Math.max(0, Math.min(1, (5.2 - Math.abs(t)) / 1.8))
                Case3D {
                    theme: shelf.theme
                    game: slot.game
                    place: shelf.placeOf(slot.t)
                    boxH: shelf.boxH
                    slotIndex: slot.gameIndex
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: shelf.pointerActive
        onClicked: (m) => {
            const r = view.pick(m.x, m.y)
            if (r.objectHit && r.objectHit.slotIndex !== undefined && r.objectHit.slotIndex >= 0)
                shelf.picked(r.objectHit.slotIndex)
        }
    }
}
