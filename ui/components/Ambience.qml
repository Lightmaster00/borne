// Background: a video of the selected game being played (ScreenScraper's gameplay capture, else
// RomM's trailer), muted and looping once the selection rests, over the game's art without text
// (ScreenScraper's blank Steam grid, else its blank marquee), else the game's cover, blurred,
// enlarged and drifting slowly, which shows while the video loads or when a game has none.
// One dark filter over all of it keeps the cases and the text the subject; in attract mode (the
// library faded out to show the video) it lightens.
import QtQuick
import QtQuick.Shapes
import QtMultimedia
import QtQuick.Effects
import "Cases.js" as Cases

Item {
    id: amb
    property QtObject theme
    property var game: null
    property color tint: Cases.tint(game ? game.platform_slug : "")
    Behavior on tint { ColorAnimation { duration: 700 } }
    property bool trailers: true      // videos may play (the library is on top, trailers allowed)
    property string videoUrl: ""      // "video" style: local file of the game being played
    property bool paused: false
    property bool rest: false         // the video holds still on its current frame (attract over)
    property real dim: 0              // extra darkening for pages drawn over it
    property bool scrims: true
    property bool attract: false      // the library has faded out: the video is the subject
    readonly property bool videoShown: gameplay.shown
    property int framesDecoded: 0
    readonly property string cover: game && game.cover ? game.cover : ""
    readonly property color accent: theme.accent

    // ---------- shared base ----------
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#121419" }
            GradientStop { position: 1.0; color: "#07080a" }
        }
    }

    // ---------- the game's art without text (ScreenScraper's blank Steam grid or marquee) ----------
    function hasArt(k) { return !!(game && game.art_kinds && game.art_kinds.indexOf("," + k + ",") >= 0) }
    readonly property string still: hasArt("steamgrid") ? game.art + "steamgrid" : hasArt("marquee") ? game.art + "marquee" : ""
    Item {
        id: stillLayer
        anchors.fill: parent
        visible: gameplay.opacity < 1 && amb.still !== ""
        property bool useA: true
        property string shown: ""
        Timer { id: stillDelay; interval: 350; onTriggered: stillLayer.swap() }
        Connections { target: amb; function onStillChanged() { stillDelay.restart() } }
        Component.onCompleted: swap()
        function swap() {
            if (amb.still === shown) return
            shown = amb.still
            if (useA) stillB.source = amb.still; else stillA.source = amb.still
            useA = !useA
        }
        Image { id: stillA; anchors.fill: parent; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: 1920
                opacity: stillLayer.useA && status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 600 } } }
        Image { id: stillB; anchors.fill: parent; fillMode: Image.PreserveAspectCrop; asynchronous: true; sourceSize.width: 1920
                opacity: !stillLayer.useA && status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 600 } } }
    }

    // ---------- the cover, blurred and enlarged, drifting slowly ----------
    Item {
        id: glow
        anchors.fill: parent
        visible: gameplay.opacity < 1 && amb.still === ""
        property bool useA: true
        property string shown: ""
        Timer { id: glowDelay; interval: 300; onTriggered: glow.swap() }
        Connections { target: amb; function onCoverChanged() { glowDelay.restart() } }
        Component.onCompleted: swap()
        function swap() {
            if (amb.cover === shown) return
            shown = amb.cover
            if (useA) glowB.source = amb.cover; else glowA.source = amb.cover
            useA = !useA
        }
        // A slow push in and out, so the still background breathes.
        property real drift       // driven by the animation below
        SequentialAnimation on drift {
            loops: Animation.Infinite
            running: glow.visible && amb.visible && !amb.paused
            NumberAnimation { from: 0; to: 1; duration: 16000; easing.type: Easing.InOutSine }
            NumberAnimation { from: 1; to: 0; duration: 16000; easing.type: Easing.InOutSine }
        }
        Item {
            id: glowSrc
            anchors.fill: parent
            visible: false
            component GlowImage: Image {
                property bool front: false
                anchors.centerIn: parent
                width: parent.width * (1.15 + 0.08 * glow.drift); height: parent.height * (1.15 + 0.08 * glow.drift)
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 72
                asynchronous: true
                opacity: front && status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
            }
            GlowImage { id: glowA; front: glow.useA }
            GlowImage { id: glowB; front: !glow.useA }
        }
        MultiEffect {
            anchors.fill: parent
            source: glowSrc
            autoPaddingEnabled: false
            blurEnabled: true
            blur: 1
            blurMax: 64
            blurMultiplier: 1.5
            saturation: 0.25
            brightness: -0.08
        }
    }

    // ---------- "video": the game being played ----------
    Item {
        id: gameplay
        anchors.fill: parent
        readonly property bool live: amb.trailers && amb.visible && !amb.paused
                                     && amb.videoUrl !== ""
        readonly property bool shown: live && (gpPlayer.playbackState === MediaPlayer.PlayingState
                                               || amb.rest && gpPlayer.playbackState === MediaPlayer.PausedState)
                                      && amb.framesDecoded > 0
        visible: opacity > 0
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
        onLiveChanged: sync()
        Connections { target: amb; function onRestChanged() { gameplay.sync() } }
        Connections { target: amb; function onVideoUrlChanged() { gameplay.sync() } }
        function sync() {
            if (live) {
                if (gpPlayer.source.toString() !== amb.videoUrl) {
                    amb.framesDecoded = 0
                    gpPlayer.source = amb.videoUrl
                }
                if (amb.rest) gpPlayer.pause()
                else gpPlayer.play()
            } else {
                gpPlayer.stop()
                if (amb.videoUrl === "") gpPlayer.source = ""
            }
        }
        MediaPlayer {
            id: gpPlayer
            loops: MediaPlayer.Infinite
            audioOutput: null
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

    // ---------- the dark filter, vignette and page dimming ----------
    Rectangle {
        anchors.fill: parent
        color: "#07080a"
        opacity: amb.attract ? 0.12 : 0.58
        Behavior on opacity { NumberAnimation { duration: amb.attract ? 1200 : 350; easing.type: Easing.InOutQuad } }
    }
    // Darker toward the floor, under the cases and the game's name.
    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.5
        opacity: amb.attract ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: amb.attract ? 1200 : 350; easing.type: Easing.InOutQuad } }
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 0.55; color: Qt.rgba(0.027, 0.031, 0.039, 0.6) }
            GradientStop { position: 1; color: Qt.rgba(0.027, 0.031, 0.039, 0.92) }
        }
    }
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
