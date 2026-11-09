// ES-DE-style trailer: a single video decoded at a time, starting muted after a
// delay on the selected game, fading in from the poster, stopping and releasing the decoder
// as soon as the focus moves or a game starts.
import QtQuick
import QtQuick.Effects
import QtMultimedia

Item {
    id: stage
    property var game
    property QtObject theme
    property int delayMs: 1500
    property real volume: 0
    property bool active: true      // trailers enabled
    property bool paused: false     // game running, overlay…
    property bool blur: false
    property bool panel: false      // detailed view thumbnail (no dimming)
    property real backdropOpacity: theme.heroOpacity   // the selected game's cover behind everything
    property bool video: theme.heroVideo
    property string errorText: ""
    property bool shown: false
    /// Video frames received (for the benchmark).
    property int framesDecoded: 0

    clip: true

    function stopVideo() {
        delay.stop()
        shown = false
        player.stop()
        player.source = ""   // releases the decoder
    }
    function restart() {
        stopVideo()
        errorText = ""
        if (active && video && !paused && game && game.trailer)
            delay.restart()
    }
    onGameChanged: restart()
    onActiveChanged: restart()
    onPausedChanged: restart()
    onDelayMsChanged: restart()
    onVideoChanged: restart()
    Component.onDestruction: stopVideo()

    Rectangle { anchors.fill: parent; color: theme.bg; radius: stage.panel ? theme.radius : 0 }
    Rectangle {
        anchors.fill: parent
        radius: stage.panel ? theme.radius : 0
        // Tint from the game's color, unless the theme wants a plain background.
        opacity: stage.panel || stage.backdropOpacity > 0 ? 0.55 : 0
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: Qt.hsla(((stage.game ? stage.game.hue : 220) % 360) / 360, 0.6, 0.3, 1) }
        }
    }

    Image {
        id: backdrop
        anchors.fill: parent
        source: stage.game && stage.game.cover ? stage.game.cover : ""
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        sourceSize: Qt.size(960, 540)
        opacity: stage.backdropOpacity
        visible: !stage.blur && status === Image.Ready
    }
    MultiEffect {
        anchors.fill: backdrop
        source: backdrop
        visible: stage.blur && backdrop.status === Image.Ready
        opacity: Math.min(1, stage.backdropOpacity + 0.05)
        blurEnabled: true
        blur: 1.0
        blurMax: 48
    }

    VideoOutput {
        id: vo
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: stage.shown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: theme.fadeMs; easing.type: Easing.InOutQuad } }
    }
    Connections {
        target: vo.videoSink
        function onVideoFrameChanged() {
            stage.framesDecoded++
            if (!stage.shown && player.source.toString() !== "")
                stage.shown = true
        }
    }

    MediaPlayer {
        id: player
        videoOutput: vo
        audioOutput: AudioOutput { volume: stage.volume; muted: stage.volume === 0 }
        loops: MediaPlayer.Infinite
        onErrorOccurred: (error, errorString) => stage.errorText = errorString
    }

    Timer {
        id: delay
        interval: stage.delayMs
        onTriggered: {
            player.source = stage.game.trailer
            player.play()
        }
    }

    // Dimming behind the grid, to keep the posters readable.
    Rectangle {
        anchors.fill: parent
        visible: !stage.panel
        color: theme.bg
        opacity: theme.stageDim * 0.6
    }
    Rectangle {
        anchors.fill: parent
        visible: !stage.panel
        gradient: Gradient {
            GradientStop { position: 0.0; color: theme.bg }
            GradientStop { position: 0.18; color: "transparent" }
            GradientStop { position: 0.5; color: "transparent" }
            GradientStop { position: 1.0; color: theme.bg }
        }
    }
    Rectangle {
        anchors.fill: parent
        visible: !stage.panel
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.rgba(0, 0, 0, theme.stageDim) }
            GradientStop { position: 0.7; color: "transparent" }
        }
    }

    Text {
        anchors { right: parent.right; bottom: parent.bottom; margins: 10 }
        text: stage.errorText
        color: theme.bad
        font { family: theme.fontFamily; pixelSize: 12 }
    }
}
