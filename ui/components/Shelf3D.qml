// The library as real 3D game cases (Qt Quick 3D): the selected case faces you, a little forward;
// the others turn toward it and recede to the sides. A key light from above left casts soft
// shadows on a dark floor, a fill light from the right and a rim light from behind shape the
// edges, and the clear plastic of the cases catches them as they move.
// Same interface and layout as BoxShelf (its 2D fallback); only the 7 cases around the
// selection exist, however large the library.
import QtQuick
import "Cases.js" as Cases
import QtQuick3D

Item {
    id: shelf
    property QtObject theme
    property var games
    property int currentIndex: 0
    property int revision: 0
    property bool showSelection: true
    property real userYaw: 0
    property real userPitch: 0
    property real swayAmp: 4
    property int swayPeriod: 3600

    readonly property real boxH: 420 * Math.min(1, height / 600)   // smaller on a shorter shelf (interface size)
    readonly property real focal: 1500
    readonly property int slots: 7
    property real probeYaw: 0
    readonly property bool userTurned: Math.abs(userYaw) > 0.5 || Math.abs(userPitch) > 0.5

    property real flow: currentIndex
    Behavior on flow { NumberAnimation { duration: 460; easing.type: Easing.OutCubic } }
    property real sway        // driven by the animation below (0 when it does not run)
    SequentialAnimation on sway {
        loops: Animation.Infinite
        running: shelf.visible
        NumberAnimation { from: -1; to: 1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: -1; duration: shelf.swayPeriod; easing.type: Easing.InOutSine }
    }

    // Same placement as BoxShelf (y down there; Case3D turns it up).
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
        return { x: p.x, y: -p.lift, z: p.z, ang: ang, pitch: pitch }
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
            // The photo studio (scripts/gen-case-assets.py): its softboxes and strips are what
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
            brightness: 1.0
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
            brightness: 0.35
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
                            // fades out before the view's bottom edge, so shadows never end on a hard line
                            const g = c.createRadialGradient(128, 104, 0, 128, 104, 104)
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
                // Each slot keeps its game while that game stays in the window (slot = index modulo
                // the slot count): moving by one changes one case, the others keep their prints.
                readonly property int first: Math.round(shelf.flow) - Math.floor(shelf.slots / 2)
                readonly property int gameIndex: first + ((index - first) % shelf.slots + shelf.slots) % shelf.slots
                readonly property bool valid: shelf.games && gameIndex >= 0 && gameIndex < shelf.games.count
                readonly property var game: valid ? (shelf.revision, shelf.games.count, shelf.games.get(gameIndex)) : null
                readonly property real t: gameIndex - shelf.flow
                visible: valid && Math.abs(t) < shelf.slots / 2
                opacity: Cases.presence(t)
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

}
