// Background: a dark room lit from above, over the console or the game in front (`lightX`): a
// lamp in the console's colour washed toward warm white, shafts of light swaying through haze,
// dust drifting in them, a pool of light on the floor, a fine grain; or, when chosen (`artShown`), the
// game's art, sharp, drifting very slowly (its fan art, else a screenshot, else ScreenScraper's
// blank Steam grid or marquee), under scrims that darken the left side and the floor where the text
// stands.
// Over it, once the selection rests, a video of the game (its trailer or ScreenScraper's gameplay
// capture), muted unless `sound`; in attract mode (the page faded out to show the video) the scrims
// lift.
import QtQuick
import QtQuick.Shapes
import QtMultimedia
import QtQuick.Effects
import "Cases.js" as Cases

Item {
    id: amb
    property QtObject theme
    property var game: null
    property string override: ""      // a picture shown instead of the game's art
    property bool artShown: false     // the game's art rather than the lights
    property color tint: Cases.tint(game ? game.platform_slug : "")
    Behavior on tint { ColorAnimation { duration: 1400; easing.type: Easing.InOutSine } }
    // Another console: the lights swell a moment as their colour changes.
    readonly property color goal: Cases.tint(game ? game.platform_slug : "")
    property real flash: 0
    onGoalChanged: if (theme && theme.motion > 0.5) swell.restart()
    SequentialAnimation {
        id: swell
        NumberAnimation { target: amb; property: "flash"; to: 1; duration: 700; easing.type: Easing.InOutSine }
        NumberAnimation { target: amb; property: "flash"; to: 0; duration: 1800; easing.type: Easing.InOutSine }
    }
    property bool trailers: true      // videos may play
    property string videoUrl: ""      // local file of the game's video
    property bool sound: false        // the video's sound
    property bool paused: false
    property bool rest: false         // attract over: the video goes on, dimmed behind the games (economy)
    property real dim: 0              // extra darkening for pages drawn over it
    property bool scrims: true
    property bool attract: false      // the page has faded out: the video is the subject
    readonly property bool videoShown: gameplay.shown
    property int framesDecoded: 0
    readonly property color accent: theme.accent

    // ---------- without art: a dark room lit from above ----------
    // Where the light falls (stage pixels): over the console or the game in front.
    property real lightX: width * 0.5
    Behavior on lightX { NumberAnimation { duration: 1400; easing.type: Easing.InOutCubic } }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(amb.tint.r * 0.16 + 0.012, amb.tint.g * 0.16 + 0.012, amb.tint.b * 0.16 + 0.016, 1) }
            GradientStop { position: 0.6; color: Qt.rgba(amb.tint.r * 0.05 + 0.014, amb.tint.g * 0.05 + 0.014, amb.tint.b * 0.05 + 0.018, 1) }
            GradientStop { position: 1.0; color: "#040406" }
        }
    }
    Item {
        id: lights
        anchors.fill: parent
        visible: !amb.artShown || stillLayer.shown === ""
        readonly property bool moving: amb.visible && !amb.paused && amb.theme && amb.theme.motion > 0.5
        // The light's colour: the console's, washed toward a warm white, as a lamp through tinted glass.
        readonly property color lamp: Qt.rgba(0.62 + amb.tint.r * 0.38, 0.58 + amb.tint.g * 0.38, 0.52 + amb.tint.b * 0.38, 1)
        readonly property real cx: amb.lightX
        readonly property real cy: -height * 0.18

        // The haze the light passes through: a tall soft cone.
        Shape {
            id: haze
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: 0.55 + 0.25 * amb.flash
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: lights.cx; centerY: lights.height * 0.1; focalX: lights.cx; focalY: lights.cy
                    centerRadius: lights.height * 0.95; focalRadius: 0
                    GradientStop { position: 0; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 0.20) }
                    GradientStop { position: 0.5; color: Qt.rgba(amb.tint.r, amb.tint.g, amb.tint.b, 0.07) }
                    GradientStop { position: 1; color: Qt.rgba(amb.tint.r, amb.tint.g, amb.tint.b, 0) }
                }
                PathRectangle { x: 0; y: 0; width: lights.width; height: lights.height }
            }
        }
        // Shafts of light: thin uneven wedges fanning down from the lamp, fading as they go, in two
        // sets swaying slowly at different paces, so they shimmer like light through dust.
        readonly property var rays: {
            const out = []
            let r = 7
            const rnd = () => { r = (r * 16807) % 2147483647; return (r % 10000) / 10000 }
            for (let i = 0; i < 22; i++)
                out.push({ a: -34 + 68 * rnd(), w: 14 + 70 * rnd() * rnd(), k: 0.35 + 0.65 * rnd(), set: i % 2 })
            return out
        }
        property real sway0
        property real sway1
        SequentialAnimation on sway0 {
            loops: Animation.Infinite; running: lights.moving
            NumberAnimation { from: -2.2; to: 2.2; duration: 23000; easing.type: Easing.InOutSine }
            NumberAnimation { from: 2.2; to: -2.2; duration: 23000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on sway1 {
            loops: Animation.Infinite; running: lights.moving
            NumberAnimation { from: 2.6; to: -1.6; duration: 31000; easing.type: Easing.InOutSine }
            NumberAnimation { from: -1.6; to: 2.6; duration: 31000; easing.type: Easing.InOutSine }
        }
        Repeater {
            model: lights.rays
            Shape {
                id: ray
                required property var modelData
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                readonly property real ang: (modelData.a + (modelData.set ? lights.sway1 : lights.sway0)) * Math.PI / 180
                readonly property real len: lights.height * 1.25
                readonly property real ex: lights.cx + Math.sin(ang) * len
                readonly property real ey: lights.cy + Math.cos(ang) * len
                readonly property real px: Math.cos(ang) * modelData.w / 2
                readonly property real py: -Math.sin(ang) * modelData.w / 2
                opacity: (0.095 + 0.045 * amb.flash) * modelData.k
                ShapePath {
                    strokeWidth: -1
                    fillGradient: LinearGradient {
                        x1: lights.cx; y1: lights.cy; x2: ray.ex; y2: ray.ey
                        GradientStop { position: 0.1; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 1) }
                        GradientStop { position: 0.55; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 0.45) }
                        GradientStop { position: 1; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 0) }
                    }
                    startX: lights.cx; startY: lights.cy
                    PathLine { x: ray.ex + ray.px; y: ray.ey + ray.py }
                    PathLine { x: ray.ex - ray.px; y: ray.ey - ray.py }
                    PathLine { x: lights.cx; y: lights.cy }
                }
            }
        }
        // The lamp itself, just above the screen: a bright bloom where the rays start.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: 0.85 + 0.15 * amb.flash
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: lights.cx; centerY: -20; focalX: lights.cx; focalY: -20
                    centerRadius: 300; focalRadius: 0
                    GradientStop { position: 0; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 0.30) }
                    GradientStop { position: 0.4; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 0.08) }
                    GradientStop { position: 1; color: Qt.rgba(lights.lamp.r, lights.lamp.g, lights.lamp.b, 0) }
                }
                PathRectangle { x: lights.cx - 300; y: 0; width: 600; height: 300 }
            }
        }
        // Where the light lands: a soft pool on the floor.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: lights.cx; centerY: lights.height * 0.86; focalX: lights.cx; focalY: lights.height * 0.86
                    centerRadius: lights.width * 0.34; focalRadius: 0
                    GradientStop { position: 0; color: Qt.rgba(amb.tint.r, amb.tint.g, amb.tint.b, 0.16 + 0.08 * amb.flash) }
                    GradientStop { position: 1; color: Qt.rgba(amb.tint.r, amb.tint.g, amb.tint.b, 0) }
                }
                PathRectangle { x: 0; y: lights.height * 0.6; width: lights.width; height: lights.height * 0.4 }
            }
        }
        // Dust in the light: a few motes rising slowly, catching it as they pass.
        Repeater {
            model: lights.moving ? 22 : 0
            Rectangle {
                id: mote
                required property int index
                readonly property real seed: ((index * 7919) % 1000) / 1000
                readonly property real seed2: ((index * 104729) % 1000) / 1000
                width: 2 + seed2 * 3; height: width; radius: width / 2
                color: lights.lamp
                property real p: seed
                NumberAnimation on p {
                    from: mote.seed; to: mote.seed + 1; duration: 26000 + mote.seed2 * 22000
                    loops: Animation.Infinite; running: lights.moving
                }
                readonly property real f: p % 1
                // Inside the cone, spread with height, drifting sideways a little.
                x: lights.cx + (seed - 0.5) * (120 + (1 - f) * lights.width * 0.42) + Math.sin(f * 6.28 * (1 + seed2)) * 22
                y: lights.height * (0.95 - f * 0.85)
                opacity: Math.sin(f * Math.PI) * (0.25 + 0.45 * seed2) * (0.6 + 0.4 * Math.sin(f * 40 * (0.5 + seed)))
            }
        }
    }
    // The edges of the room, darker.
    Shape {
        anchors.fill: parent
        visible: lights.visible
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: amb.width / 2; centerY: amb.height * 0.45; focalX: centerX; focalY: centerY
                centerRadius: amb.width * 0.75; focalRadius: amb.width * 0.25
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.55) }
            }
            PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
        }
    }
    // A fine grain over it all, against banding in the dark gradients.
    Image {
        anchors.fill: parent
        visible: lights.visible
        source: "../brand/grain.png"
        fillMode: Image.Tile
        opacity: 0.05
        smooth: false
    }

    // ---------- the art ----------
    function hasArt(k) { return !!(game && game.art_kinds && game.art_kinds.indexOf("," + k + ",") >= 0) }
    readonly property string still: override !== "" ? override
                                  : hasArt("backdrop") ? game.art + "backdrop" : hasArt("steamgrid") ? game.art + "steamgrid"
                                  : hasArt("marquee") ? game.art + "marquee" : ""
    Item {
        id: stillLayer
        anchors.fill: parent
        visible: gameplay.opacity < 1 && amb.artShown
        property bool useA: true
        property string shown: ""
        Timer { id: stillDelay; interval: 250; onTriggered: stillLayer.swap() }
        Connections { target: amb; function onStillChanged() { stillDelay.restart() } }
        Component.onCompleted: swap()
        function swap() {
            if (amb.still === shown) return
            shown = amb.still
            if (useA) stillB.source = amb.still; else stillA.source = amb.still
            useA = !useA
        }
        // A slow push in and out, so the picture breathes.
        property real drift
        SequentialAnimation on drift {
            loops: Animation.Infinite
            running: stillLayer.visible && amb.visible && !amb.paused
            NumberAnimation { from: 0; to: 1; duration: 24000; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1; to: 0; duration: 24000; easing.type: Easing.InOutSine }
        }
        component Still: Image {
            property bool front: false
            anchors.centerIn: parent
            width: parent.width * (1.04 + 0.04 * stillLayer.drift); height: parent.height * (1.04 + 0.04 * stillLayer.drift)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 1920
            opacity: front && status === Image.Ready && source.toString() !== "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 800; easing.type: Easing.InOutQuad } }
        }
        Still { id: stillA; front: stillLayer.useA }
        Still { id: stillB; front: !stillLayer.useA }
    }

    // ---------- the video ----------
    Item {
        id: gameplay
        anchors.fill: parent
        readonly property bool live: amb.trailers && amb.visible && !amb.paused && amb.videoUrl !== ""
        readonly property bool shown: live && gpPlayer.playbackState === MediaPlayer.PlayingState && amb.framesDecoded > 0
        visible: opacity > 0
        opacity: shown ? (amb.rest ? 0.45 : 1) : 0
        Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
        onLiveChanged: sync()
        Connections { target: amb; function onRestChanged() { gameplay.sync() } }
        Connections { target: amb; function onVideoUrlChanged() { gameplay.sync() } }
        function sync() {
            if (live) {
                if (gpPlayer.source.toString() !== amb.videoUrl) {
                    amb.framesDecoded = 0
                    gpPlayer.source = amb.videoUrl
                }
                gpPlayer.play()
            } else {
                gpPlayer.stop()
                if (amb.videoUrl === "") gpPlayer.source = ""
            }
        }
        MediaPlayer {
            id: gpPlayer
            loops: MediaPlayer.Infinite
            audioOutput: AudioOutput { muted: !amb.sound; volume: 0.8 }
            videoOutput: gpOut.output
        }
        // Whole when its proportions are far from the screen's (handhelds), never cut to nothing.
        GameVideo {
            id: gpOut
            anchors.fill: parent
        }
        Connections {
            target: gpOut.videoSink
            function onVideoFrameChanged() { if (amb.framesDecoded < 3) amb.framesDecoded++ }
        }
    }

    // ---------- scrims: the left side and the floor, where the text stands ----------
    Item {
        anchors.fill: parent
        opacity: amb.attract ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: amb.attract ? 1200 : 350; easing.type: Easing.InOutQuad } }
        Rectangle {
            anchors.fill: parent
            color: "#06070a"
            opacity: amb.artShown ? (amb.scrims ? 0.22 : 0.12) : 0
        }
        Rectangle {
            anchors.fill: parent
            opacity: amb.artShown || amb.videoShown ? 1 : 0.4
            Behavior on opacity { NumberAnimation { duration: 600 } }
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Qt.rgba(0.02, 0.024, 0.035, 0.88) }
                GradientStop { position: 0.38; color: Qt.rgba(0.02, 0.024, 0.035, 0.55) }
                GradientStop { position: 0.7; color: Qt.rgba(0.02, 0.024, 0.035, 0.08) }
                GradientStop { position: 1.0; color: Qt.rgba(0.02, 0.024, 0.035, 0.0) }
            }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.height * 0.62
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 0.5; color: Qt.rgba(0.02, 0.024, 0.035, 0.6) }
                GradientStop { position: 1; color: Qt.rgba(0.02, 0.024, 0.035, 0.96) }
            }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: parent.height * 0.22
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0.02, 0.024, 0.035, 0.6) }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }
    Rectangle {
        anchors.fill: parent
        color: amb.theme.bg
        opacity: amb.dim
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }
}
