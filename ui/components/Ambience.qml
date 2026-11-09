// Living background: the selected game's art, blurred, cross-fading when the focus moves and
// drifting a few pixels over twenty seconds; its trailer fades in after a pause. Scrims on the
// left and at the bottom keep the text readable whatever the art.
// The blur is computed at 480 × 270 and scaled up: cheap, and smooth since it is blurred anyway.
import QtQuick
import QtQuick.Effects
import QtMultimedia

Item {
    id: amb
    property QtObject theme
    property var game: null
    property bool trailers: true
    property bool paused: false
    property int delayMs: 2500
    property real dim: 0              // extra darkening for pages drawn over it
    property bool scrims: true
    /// Video frames received (for the benchmark).
    property int framesDecoded: 0
    property bool videoShown: false

    readonly property string cover: game && game.cover ? game.cover : ""
    property bool flip: false

    onCoverChanged: swap()
    onGameChanged: restartVideo()
    onTrailersChanged: restartVideo()
    onPausedChanged: restartVideo()
    Component.onDestruction: stopVideo()

    function swap() {
        const next = flip ? layerA : layerB
        next.source = cover
        next.tone = theme.tone(game ? game.hue : 210)
        flip = !flip
    }
    function stopVideo() {
        delay.stop()
        videoShown = false
        player.stop()
        player.source = ""   // releases the decoder
    }
    function restartVideo() {
        stopVideo()
        if (trailers && !paused && game && game.trailer) delay.restart()
    }

    Rectangle { anchors.fill: parent; color: theme.bg }

    Item {
        id: drift
        width: parent.width * 1.12
        height: parent.height * 1.12
        x: -parent.width * 0.06
        y: -parent.height * 0.06
        SequentialAnimation on x {
            loops: Animation.Infinite
            running: amb.visible
            NumberAnimation { to: -amb.width * 0.03; duration: 20000; easing.type: Easing.InOutSine }
            NumberAnimation { to: -amb.width * 0.09; duration: 20000; easing.type: Easing.InOutSine }
        }
        SequentialAnimation on y {
            loops: Animation.Infinite
            running: amb.visible
            NumberAnimation { to: -amb.height * 0.09; duration: 26000; easing.type: Easing.InOutSine }
            NumberAnimation { to: -amb.height * 0.03; duration: 26000; easing.type: Easing.InOutSine }
        }

        component Layer: Item {
            id: layer
            property string source: ""
            property color tone: "#202838"
            property bool current: false
            anchors.fill: parent
            opacity: current ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: amb.theme.fadeMs; easing.type: Easing.InOutQuad } }
            Rectangle { anchors.fill: parent; color: layer.tone }
            Item {
                width: 480; height: 270
                scale: parent.width / 480
                transformOrigin: Item.TopLeft
                Image {
                    id: art
                    anchors.fill: parent
                    source: layer.source
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize: Qt.size(480, 270)
                    visible: false
                }
                MultiEffect {
                    anchors.fill: parent
                    source: art
                    visible: art.status === Image.Ready
                    blurEnabled: true
                    blur: 1.0
                    blurMax: 32
                    autoPaddingEnabled: false
                    saturation: -0.1
                    brightness: -0.25
                }
            }
        }
        Layer { id: layerA; current: !amb.flip }
        Layer { id: layerB; current: amb.flip }
    }

    VideoOutput {
        id: vo
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: amb.videoShown ? 0.85 : 0
        Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
    }
    Connections {
        target: vo.videoSink
        function onVideoFrameChanged() {
            amb.framesDecoded++
            if (!amb.videoShown && player.source.toString() !== "") amb.videoShown = true
        }
    }
    MediaPlayer {
        id: player
        videoOutput: vo
        audioOutput: AudioOutput { muted: true }
        loops: MediaPlayer.Infinite
    }
    Timer {
        id: delay
        interval: amb.delayMs
        onTriggered: { player.source = amb.game.trailer; player.play() }
    }

    // Readability: dark on the left (text) and at the bottom (the row of games).
    Rectangle {
        visible: amb.scrims
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0.024, 0.027, 0.04, 0.92) }
            GradientStop { position: 0.36; color: Qt.rgba(0.024, 0.027, 0.04, 0.62) }
            GradientStop { position: 0.62; color: Qt.rgba(0.024, 0.027, 0.04, 0.3) }
            GradientStop { position: 1.0; color: Qt.rgba(0.024, 0.027, 0.04, 0.35) }
        }
    }
    Rectangle {
        visible: amb.scrims
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.80; color: Qt.rgba(0.024, 0.027, 0.04, 0.0) }
            GradientStop { position: 1.0; color: Qt.rgba(0.024, 0.027, 0.04, 0.75) }
        }
    }
    Rectangle {
        anchors.fill: parent
        color: theme.bg
        opacity: amb.dim
        Behavior on opacity { NumberAnimation { duration: 300 } }
    }
}
