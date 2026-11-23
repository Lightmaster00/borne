// Background: a dark room whose only light comes from what is in front (`lightX`): the console's
// photo or the game's cover, blurred until only its colours are left, spread wide and faint; a
// vignette and a fine grain (all tuned in Settings → Developer → Light and cards); or, when chosen (`artShown`), the
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

    // ---------- without art: a dark room taking its light from what is in front ----------
    // Where the light gathers (stage pixels), and the picture it takes its colours from (the
    // console's photo, else the game's cover).
    property real lightX: width * 0.5
    Behavior on lightX { NumberAnimation { duration: 1200; easing.type: Easing.InOutCubic } }
    property string glowSource: ""
    // Settings → Developer → Light and cards (prefs.look*): glow 0–100 (how much colour), soft
    // 0–100 (how diffuse), vignette 0–100, grain 0–100.
    property var look: ({ glow: 60, soft: 100, vignette: 0, grain: 0 })
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(amb.tint.r * 0.10 + 0.020, amb.tint.g * 0.10 + 0.020, amb.tint.b * 0.10 + 0.026, 1) }
            GradientStop { position: 1.0; color: Qt.rgba(amb.tint.r * 0.03 + 0.012, amb.tint.g * 0.03 + 0.012, amb.tint.b * 0.03 + 0.016, 1) }
        }
    }
    Item {
        id: lights
        anchors.fill: parent
        visible: !amb.artShown || stillLayer.shown === ""
        // The picture, tiny and blurred until only its colours are left, spread wide behind
        // what is in front; two layers crossfade when it changes. No picture: the console's colour.
        property bool useA: true
        property string shown: ""
        function swap() {
            const src = amb.glowSource !== "" ? amb.glowSource : (amb.game && amb.game.cover ? amb.game.cover : "")
            if (src === shown) return
            shown = src
            if (useA) glowB.source = src; else glowA.source = src
            useA = !useA
        }
        Timer { id: glowDelay; interval: 180; onTriggered: lights.swap() }
        Connections { target: amb; function onGlowSourceChanged() { glowDelay.restart() } function onGameChanged() { glowDelay.restart() } }
        Component.onCompleted: swap()
        readonly property real spread: 0.75 + 0.5 * amb.look.soft / 100
        Item {
            id: glowBox
            width: lights.width * lights.spread
            height: lights.height * (0.9 + 0.4 * amb.look.soft / 100)
            x: amb.lightX - width / 2
            y: lights.height * 0.42 - height / 2
            opacity: amb.look.glow / 100
            layer.enabled: true
            layer.effect: MultiEffect {
                blurEnabled: true; blur: 1.0; blurMax: 64; blurMultiplier: 1 + amb.look.soft / 50
                saturation: 0.25
                maskEnabled: true; maskSource: glowMask; maskThresholdMin: 0.0; maskSpreadAtMin: 1.0
            }
            // The console's colour, under the picture (and alone when there is none).
            Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.6; height: parent.height * 0.6; radius: width / 2
                color: Qt.rgba(amb.tint.r, amb.tint.g, amb.tint.b, 0.55)
            }
            component Glow: Image {
                property bool front: false
                anchors.centerIn: parent
                width: parent.width * 0.62; height: parent.height * 0.62
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 48
                smooth: true
                asynchronous: true
                opacity: front && status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            }
            Glow { id: glowA; front: lights.useA }
            Glow { id: glowB; front: !lights.useA }
        }
        // The glow fades out softly at its edges.
        Shape {
            id: glowMask
            width: glowBox.width; height: glowBox.height
            visible: false
            layer.enabled: true
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: glowMask.width / 2; centerY: glowMask.height / 2; focalX: centerX; focalY: centerY
                    centerRadius: Math.min(glowMask.width, glowMask.height) * 0.5; focalRadius: 0
                    GradientStop { position: 0; color: "white" }
                    GradientStop { position: 0.6; color: Qt.rgba(1, 1, 1, 0.5) }
                    GradientStop { position: 1; color: "transparent" }
                }
                PathRectangle { x: 0; y: 0; width: glowMask.width; height: glowMask.height }
            }
        }
    }
    // The edges of the room, darker.
    Shape {
        anchors.fill: parent
        visible: lights.visible && amb.look.vignette > 0
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillGradient: RadialGradient {
                centerX: amb.width / 2; centerY: amb.height * 0.45; focalX: centerX; focalY: centerY
                centerRadius: amb.width * 0.75; focalRadius: amb.width * 0.2
                GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
                GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.9 * amb.look.vignette / 100) }
            }
            PathRectangle { x: 0; y: 0; width: amb.width; height: amb.height }
        }
    }
    // A fine grain over it all, against banding in the dark gradients.
    Image {
        anchors.fill: parent
        visible: lights.visible && amb.look.grain > 0
        source: "../brand/grain.png"
        fillMode: Image.Tile
        opacity: 0.12 * amb.look.grain / 100
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
