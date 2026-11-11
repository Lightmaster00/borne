// Background: a video of the selected game being played (ScreenScraper's gameplay capture, else
// RomM's trailer), muted, darkened and looping once the selection rests, over Borne's pixel
// mosaic (the selected game's cover rebuilt as a wall of large dark pixels that re-colour one by
// one, with a slow light wave), which shows while the video loads or when a game has none.
import QtQuick
import QtQuick.Shapes
import QtMultimedia
import "Cases.js" as Cases

Item {
    id: amb
    property QtObject theme
    property var game: null
    property string style: "video"
    property color tint: Cases.tint(game ? game.platform_slug : "")
    Behavior on tint { ColorAnimation { duration: 700 } }
    property bool trailers: true      // videos may play (the library is on top, trailers allowed)
    property string videoUrl: ""      // "video" style: local file of the game being played
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

    // ---------- "pixels": the cover as a wall of large pixels ----------
    Item {
        id: mosaic
        anchors.fill: parent
        visible: gameplay.opacity < 1
        readonly property int tile: 56
        readonly property int cols: Math.ceil(width / tile)
        readonly property int rows: Math.ceil(height / tile)
        property real phase: 0
        Timer {
            interval: 50; repeat: true
            running: mosaic.visible && amb.visible && !amb.paused
            onTriggered: mosaic.phase += 0.05
        }
        Rectangle { anchors.fill: parent; color: "#07080a" }
        // The cover decoded at one pixel per tile and drawn without smoothing: each pixel becomes
        // a tile. Two layers cross-fade when the selection settles.
        property bool useA: true
        Timer { id: settlePix; interval: 300; onTriggered: { mosaic.useA = !mosaic.useA; (mosaic.useA ? pixA : pixB).src = amb.cover; reshuffle.restart() } }
        Connections { target: amb; function onCoverChanged() { settlePix.restart() } }
        Component.onCompleted: pixA.src = amb.cover
        component PixLayer: Image {
            property string src: ""
            property bool front: false
            anchors.fill: parent
            source: src
            sourceSize: Qt.size(mosaic.cols, mosaic.rows)
            fillMode: Image.PreserveAspectCrop
            smooth: false
            mipmap: false
            asynchronous: true
            cache: false
            opacity: front && status === Image.Ready ? 0.42 : 0
            Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
        }
        PixLayer { id: pixA; front: mosaic.useA }
        PixLayer { id: pixB; front: !mosaic.useA }
        // Re-colouring: each tile flashes dark at its own moment, so the wall seems to rebuild
        // itself tile by tile; then a slow diagonal wave of light runs across it.
        property real shuffle: 2
        NumberAnimation { id: reshuffle; target: mosaic; property: "shuffle"; from: -0.3; to: 1.3; duration: 1100; easing.type: Easing.InOutSine }
        Repeater {
            model: mosaic.cols * mosaic.rows
            Rectangle {
                id: px
                required property int index
                readonly property int cx: index % mosaic.cols
                readonly property int cy: Math.floor(index / mosaic.cols)
                readonly property real seed: ((cx * 73 + cy * 151) % 97) / 97
                x: cx * mosaic.tile; y: cy * mosaic.tile
                width: mosaic.tile; height: mosaic.tile
                color: "transparent"
                // Gaps between tiles.
                border { width: 2; color: "#07080a" }
                Rectangle {
                    anchors { fill: parent; margins: 2 }
                    radius: 3
                    color: "black"
                    opacity: Math.max(0, 0.75 - Math.abs(mosaic.shuffle - px.seed) * 5)
                             + 0.14 * (1 - Math.sin(mosaic.phase - (px.cx + px.cy) * 0.28)) / 2
                }
            }
        }
        // Readability: darker toward the edges and on the floor under the cases.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.02, 0.025, 0.03, 0.55) }
                GradientStop { position: 0.3; color: Qt.rgba(0.02, 0.025, 0.03, 0.1) }
                GradientStop { position: Math.min(0.99, amb.floorY / amb.height - 0.02); color: Qt.rgba(0.02, 0.025, 0.03, 0.2) }
                GradientStop { position: Math.min(1, amb.floorY / amb.height + 0.01); color: Qt.rgba(0.02, 0.025, 0.03, 0.82) }
                GradientStop { position: 1.0; color: Qt.rgba(0.02, 0.025, 0.03, 0.97) }
            }
        }
        // Glossy floor edge.
        Rectangle { y: amb.floorY; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }
    }

    // ---------- "video": the game being played ----------
    Item {
        id: gameplay
        anchors.fill: parent
        readonly property bool live: amb.trailers && amb.visible && !amb.paused
                                     && amb.videoUrl !== ""
        readonly property bool shown: live && gpPlayer.playbackState === MediaPlayer.PlayingState
                                      && amb.framesDecoded > 0
        visible: opacity > 0
        opacity: shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
        onLiveChanged: sync()
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
            audioOutput: null
            videoOutput: gpOut
        }
        VideoOutput {
            id: gpOut
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
        }
        Connections {
            target: gpOut.videoSink
            function onVideoFrameChanged() { if (amb.framesDecoded < 3) amb.framesDecoded++ }
        }
        // Dark enough for the cases and the text to stay the subject.
        Rectangle { anchors.fill: parent; color: "#07080a"; opacity: 0.5 }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: parent.height * 0.45
            gradient: Gradient {
                GradientStop { position: 0; color: "transparent" }
                GradientStop { position: 1; color: Qt.rgba(0.027, 0.031, 0.039, 0.92) }
            }
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
