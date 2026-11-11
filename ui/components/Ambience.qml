// Background, in one of four styles (Settings → Interface → Background):
//  "ribbons" — the console's own color, lit from above, with slow ribbons of light across it and
//            a glossy floor under the cases (the default);
//  "game"  — the selected game's artwork (RomM fanart, else a screenshot, else the cover), sharp
//            but darkened, drifting slowly and cross-fading when the selection settles;
//  "room"  — a dim game room: a wall, a neon tube tinted by the game, a shelf the cases stand on,
//            dust floating in the light;
//  "light" — an abstract space: slow beams and veils of light in the game's color, particles.
import QtQuick
import QtQuick.Shapes
import QtQuick.Particles
import "Cases.js" as Cases

Item {
    id: amb
    property QtObject theme
    property var game: null
    property string style: "ribbons"
    property color tint: Cases.tint(game ? game.platform_slug : "")
    Behavior on tint { ColorAnimation { duration: 700 } }
    property bool trailers: true      // kept for callers; no video plays behind the library
    property bool paused: false
    property real dim: 0              // extra darkening for pages drawn over it
    property bool scrims: true
    property int framesDecoded: 0
    readonly property string cover: game && game.cover ? game.cover : ""
    readonly property color accent: theme.accent
    // Where the cases stand (same rule as LibraryView's shelf).
    readonly property real floorY: Math.max(170, (height - 1000) / 2 + 170) + 510

    // ---------- shared base ----------
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#121419" }
            GradientStop { position: 1.0; color: "#07080a" }
        }
    }

    // ---------- "ribbons": the console's color and flowing light ----------
    Item {
        anchors.fill: parent
        visible: amb.style === "ribbons"
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: amb.width / 2; centerY: amb.height * 0.32
                    focalX: centerX; focalY: centerY
                    centerRadius: Math.max(amb.width, amb.height) * 0.85; focalRadius: 0
                    GradientStop { position: 0.0; color: Qt.darker(amb.tint, 1.25) }
                    GradientStop { position: 0.55; color: Qt.darker(amb.tint, 2.6) }
                    GradientStop { position: 1.0; color: Qt.darker(amb.tint, 6) }
                }
                PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
            }
        }
        // Ribbons of light: long curves whose bends drift slowly.
        Repeater {
            model: 4
            Shape {
                id: rib
                required property int index
                property real t: index * 1.7
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                NumberAnimation on t {
                    from: rib.index * 1.7; to: rib.index * 1.7 + Math.PI * 2
                    duration: 30000 + rib.index * 9000; loops: Animation.Infinite
                    running: amb.visible && amb.style === "ribbons" && !amb.paused
                }
                readonly property real baseY: amb.height * (0.16 + rib.index * 0.13)
                ShapePath {
                    strokeWidth: 7
                    strokeColor: Qt.rgba(1, 0.92, 0.92, 0.05 * (1 - rib.index * 0.15))
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: -40; startY: rib.baseY + Math.sin(rib.t) * 60
                    PathCubic {
                        x: amb.width + 40; y: rib.baseY + 120 + Math.cos(rib.t * 0.8) * 70
                        control1X: amb.width * 0.35; control1Y: rib.baseY - 160 + Math.sin(rib.t * 1.3) * 120
                        control2X: amb.width * 0.65; control2Y: rib.baseY + 220 + Math.cos(rib.t * 1.1) * 120
                    }
                }
                ShapePath {
                    strokeWidth: 2
                    strokeColor: Qt.rgba(1, 0.92, 0.92, 0.32 * (1 - rib.index * 0.15))
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    startX: -40; startY: rib.baseY + Math.sin(rib.t) * 60
                    PathCubic {
                        x: amb.width + 40; y: rib.baseY + 120 + Math.cos(rib.t * 0.8) * 70
                        control1X: amb.width * 0.35; control1Y: rib.baseY - 160 + Math.sin(rib.t * 1.3) * 120
                        control2X: amb.width * 0.65; control2Y: rib.baseY + 220 + Math.cos(rib.t * 1.1) * 120
                    }
                }
            }
        }
        // Glossy floor: lighter just under the cases, fading into shadow.
        Rectangle {
            y: amb.floorY - 4; width: amb.width; height: amb.height - amb.floorY + 4
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(amb.tint.r, amb.tint.g, amb.tint.b, 0.22) }
                GradientStop { position: 0.06; color: Qt.rgba(0, 0, 0, 0.12) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
            }
        }
    }

    // ---------- "game": the game's own art ----------
    Item {
        id: art
        anchors.fill: parent
        visible: amb.style === "game"
        property string wanted: amb.game && amb.game.art_kinds && amb.game.art_kinds.indexOf(",backdrop,") >= 0 ? amb.game.art + "backdrop" : ""
        property bool useA: true
        // Wait for the selection to settle before loading (no flicker while scrolling).
        Timer { id: settle; interval: 380; onTriggered: art.show(art.wanted) }
        onWantedChanged: settle.restart()
        Component.onCompleted: show(wanted)
        function show(url) {
            const next = useA ? layerB : layerA
            next.fallback = false
            next.src = url
            useA = !useA
        }
        component Layer: Image {
            property string src: ""
            property bool fallback: false
            property bool front: false
            anchors.fill: parent
            source: fallback || src === "" ? amb.cover : src
            asynchronous: true
            cache: false
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(1280, 720)
            onStatusChanged: if (status === Image.Error && !fallback) fallback = true
            opacity: front && status === Image.Ready ? (fallback || src === "" ? 0.3 : 0.62) : 0
            Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            scale: drift
            property real drift: 1.04
            SequentialAnimation on drift {
                loops: Animation.Infinite
                running: amb.visible && !amb.paused && amb.style === "game"
                NumberAnimation { from: 1.04; to: 1.12; duration: 24000; easing.type: Easing.InOutSine }
                NumberAnimation { from: 1.12; to: 1.04; duration: 24000; easing.type: Easing.InOutSine }
            }
        }
        Layer { id: layerA; front: art.useA }
        Layer { id: layerB; front: !art.useA }
        // Text side and floor stay readable.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0.03, 0.035, 0.045, 0.85) }
                GradientStop { position: 0.55; color: Qt.rgba(0.03, 0.035, 0.045, 0.25) }
                GradientStop { position: 1.0; color: Qt.rgba(0.03, 0.035, 0.045, 0.5) }
            }
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.03, 0.035, 0.045, 0.55) }
                GradientStop { position: 0.35; color: "transparent" }
                GradientStop { position: Math.min(0.99, amb.floorY / amb.height - 0.12); color: Qt.rgba(0.03, 0.035, 0.045, 0.35) }
                GradientStop { position: 1.0; color: Qt.rgba(0.03, 0.035, 0.045, 0.97) }
            }
        }
    }

    // ---------- "room": a dim game room ----------
    Item {
        anchors.fill: parent
        visible: amb.style === "room"
        // Wall: dark panels.
        Row {
            anchors.fill: parent
            Repeater {
                model: Math.ceil(amb.width / 240)
                Rectangle {
                    width: 240; height: amb.height
                    gradient: Gradient {
                        orientation: Gradient.Horizontal
                        GradientStop { position: 0.0; color: "#16181d" }
                        GradientStop { position: 0.97; color: "#121418" }
                        GradientStop { position: 1.0; color: "#0b0c0f" }
                    }
                }
            }
        }
        // Light washing the wall from the neon.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: amb.width / 2; centerY: amb.floorY - 540
                    focalX: centerX; focalY: centerY
                    centerRadius: amb.width * 0.55; focalRadius: 0
                    GradientStop { position: 0.0; color: Qt.rgba(amb.accent.r, amb.accent.g, amb.accent.b, 0.28) }
                    GradientStop { position: 0.4; color: Qt.rgba(amb.accent.r, amb.accent.g, amb.accent.b, 0.08) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
            }
        }
        // Neon tube above the shelf, with a soft halo; it flickers once in a while.
        Item {
            id: neon
            x: amb.width * 0.26; y: amb.floorY - 545
            width: amb.width * 0.48; height: 4
            property real power: 1
            SequentialAnimation on power {
                loops: Animation.Infinite
                running: amb.visible && amb.style === "room" && !amb.paused
                PauseAnimation { duration: 9000 }
                NumberAnimation { to: 0.55; duration: 60 }
                NumberAnimation { to: 1; duration: 90 }
                NumberAnimation { to: 0.7; duration: 50 }
                NumberAnimation { to: 1; duration: 140 }
            }
            Repeater {
                model: [[30, 0.05], [14, 0.1], [5, 0.25]]
                Rectangle {
                    required property var modelData
                    anchors.centerIn: parent
                    width: parent.width + modelData[0] * 2; height: parent.height + modelData[0] * 2
                    radius: height / 2
                    color: Qt.rgba(amb.accent.r, amb.accent.g, amb.accent.b, modelData[1] * neon.power)
                }
            }
            Rectangle { anchors.fill: parent; radius: 4; color: Qt.lighter(amb.accent, 1.5); opacity: 0.4 + 0.6 * neon.power }
        }
        // The shelf the cases stand on: a lit wooden plank and its shadow on the wall.
        Rectangle {
            y: amb.floorY + 4; width: amb.width; height: 30
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#4a3a2c" }
                GradientStop { position: 0.15; color: "#3a2d22" }
                GradientStop { position: 1.0; color: "#1c1612" }
            }
        }
        Rectangle { y: amb.floorY + 3; width: amb.width; height: 1; color: Qt.rgba(1, 0.9, 0.8, 0.25) }
        Rectangle {
            y: amb.floorY + 34; width: amb.width; height: 120
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.7) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
    }

    // ---------- "light": beams and veils ----------
    Item {
        anchors.fill: parent
        visible: amb.style === "light"
        Repeater {
            model: 5
            Rectangle {
                required property int index
                property real sway: 0
                x: amb.width * (0.12 + index * 0.19) - width / 2
                y: -amb.height * 0.3
                width: 150 + (index % 3) * 70
                height: amb.height * 1.5
                rotation: 18 - index * 6 + sway
                transformOrigin: Item.Top
                opacity: 0.55
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.5; color: Qt.rgba(amb.accent.r, amb.accent.g, amb.accent.b, 0.10) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                SequentialAnimation on sway {
                    loops: Animation.Infinite
                    running: amb.visible && amb.style === "light" && !amb.paused
                    NumberAnimation { from: -4; to: 4; duration: 9000 + index * 1700; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 4; to: -4; duration: 9000 + index * 1700; easing.type: Easing.InOutSine }
                }
            }
        }
        // Veils of colored light drifting slowly.
        Repeater {
            model: 3
            Shape {
                required property int index
                property real t: 0
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                NumberAnimation on t {
                    from: 0; to: Math.PI * 2; duration: 26000 + index * 7000; loops: Animation.Infinite
                    running: amb.visible && amb.style === "light" && !amb.paused
                }
                ShapePath {
                    strokeWidth: -1
                    fillGradient: RadialGradient {
                        centerX: amb.width * (0.3 + index * 0.25) + Math.cos(t) * 160
                        centerY: amb.height * (0.35 + 0.15 * (index % 2)) + Math.sin(t) * 90
                        focalX: centerX; focalY: centerY
                        centerRadius: amb.width * 0.32; focalRadius: 0
                        GradientStop { position: 0.0; color: Qt.rgba(amb.accent.r, amb.accent.g, amb.accent.b, 0.12) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
                }
            }
        }
        // Glossy floor line under the cases.
        Rectangle {
            y: amb.floorY; width: amb.width; height: amb.height - amb.floorY
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(amb.accent.r, amb.accent.g, amb.accent.b, 0.08) }
                GradientStop { position: 0.4; color: Qt.rgba(0, 0, 0, 0.35) }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
            }
        }
    }

    // ---------- dust / particles (room and light) ----------
    ParticleSystem {
        id: dust
        anchors.fill: parent
        running: amb.visible && (amb.style === "room" || amb.style === "light") && !amb.paused
    }
    Emitter {
        system: dust
        enabled: dust.running
        x: amb.width * 0.15; width: amb.width * 0.7
        y: amb.style === "room" ? amb.floorY - 460 : 0
        height: amb.style === "room" ? 440 : amb.height
        emitRate: amb.style === "room" ? 4 : 5
        lifeSpan: 9000; lifeSpanVariation: 3000
        size: 3; sizeVariation: 2
        velocity: AngleDirection { angle: -90; angleVariation: 60; magnitude: 10; magnitudeVariation: 8 }
    }
    ItemParticle {
        system: dust
        fade: true
        delegate: Rectangle {
            width: 3; height: 3; radius: 1.5
            color: Qt.lighter(amb.accent, 1.4)
            opacity: 0.35
        }
    }

    // ---------- vignette and page dimming ----------
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: amb.width / 2; centerY: amb.height * 0.5
                focalX: centerX; focalY: centerY
                centerRadius: Math.max(amb.width, amb.height) * 0.75
                focalRadius: 0
                GradientStop { position: 0.55; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
            }
            PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
        }
    }
    Rectangle {
        anchors.fill: parent
        color: amb.theme.bg
        opacity: amb.dim
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }
}
