// Background: lights in the selected game's console's colour drifting slowly over a deep ground
// (three soft glows and a beam that sweeps by now and then), or, when chosen (`artShown`), the
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
    Behavior on tint { ColorAnimation { duration: 700 } }
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

    // ---------- without art: the console's colour, deep ----------
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Qt.rgba(amb.tint.r * 0.32, amb.tint.g * 0.32, amb.tint.b * 0.32, 1) }
            GradientStop { position: 0.65; color: Qt.rgba(amb.tint.r * 0.1 + 0.02, amb.tint.g * 0.1 + 0.02, amb.tint.b * 0.1 + 0.025, 1) }
            GradientStop { position: 1.0; color: "#050608" }
        }
    }
    // ---------- the lights ----------
    Item {
        id: lights
        anchors.fill: parent
        // One slow cycle (four minutes), each glow on its own path.
        property real t
        NumberAnimation on t {
            from: 0; to: Math.PI * 2; duration: 240000; loops: Animation.Infinite
            running: amb.visible && !amb.paused
        }
        readonly property color warm: Qt.hsla((amb.tint.hslHue + 0.07) % 1, Math.min(1, amb.tint.hslSaturation * 0.9), 0.5, 1)
        readonly property color cool: Qt.hsla((amb.tint.hslHue + 0.92) % 1, Math.min(1, amb.tint.hslSaturation * 0.8), 0.45, 1)
        component Glow: Shape {
            id: gl
            property color c
            property real r: 600
            property real a: 0.5
            width: r * 2; height: r * 2
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: -1
                fillGradient: RadialGradient {
                    centerX: gl.r; centerY: gl.r; focalX: gl.r; focalY: gl.r
                    centerRadius: gl.r; focalRadius: 0
                    GradientStop { position: 0; color: Qt.rgba(gl.c.r, gl.c.g, gl.c.b, gl.a) }
                    GradientStop { position: 0.45; color: Qt.rgba(gl.c.r, gl.c.g, gl.c.b, gl.a * 0.35) }
                    GradientStop { position: 1; color: Qt.rgba(gl.c.r, gl.c.g, gl.c.b, 0) }
                }
                PathRectangle { x: 0; y: 0; width: gl.r * 2; height: gl.r * 2 }
            }
        }
        Glow {
            c: amb.tint; r: lights.width * 0.42; a: 0.42
            x: lights.width * (0.72 + 0.12 * Math.sin(lights.t * 3)) - r
            y: lights.height * (0.12 + 0.1 * Math.cos(lights.t * 2)) - r
        }
        Glow {
            c: lights.warm; r: lights.width * 0.3; a: 0.28
            x: lights.width * (0.3 + 0.18 * Math.cos(lights.t * 2)) - r
            y: lights.height * (0.78 + 0.08 * Math.sin(lights.t * 4)) - r
        }
        Glow {
            c: lights.cool; r: lights.width * 0.26; a: 0.24
            x: lights.width * (0.08 + 0.1 * Math.sin(lights.t * 5)) - r
            y: lights.height * (0.2 + 0.15 * Math.sin(lights.t * 3 + 1)) - r
        }
        // A beam that sweeps across now and then.
        Rectangle {
            id: beam
            width: lights.width * 0.22; height: lights.height * 2.2
            y: -lights.height * 0.6
            rotation: 22
            x: -width * 2
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0) }
                GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.045) }
                GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
            }
            SequentialAnimation on x {
                loops: Animation.Infinite
                running: amb.visible && !amb.paused && amb.theme && amb.theme.motion > 0.5
                PauseAnimation { duration: 9000 }
                NumberAnimation { from: -beam.width * 2; to: lights.width + beam.width; duration: 5200; easing.type: Easing.InOutSine }
            }
        }
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
