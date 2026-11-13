// A game's video that never hides the game: close to the screen's proportions (within 18 %) it
// fills the screen; otherwise (a handheld's tall or square picture: the DS's two screens, a Game
// Boy, a 4:3 capture on a wide screen) it is shown whole, over a blurred, darker copy of itself
// filling the rest. Give `output` to the MediaPlayer's videoOutput.
import QtQuick
import QtQuick.Effects
import QtMultimedia

Item {
    id: gv
    property alias output: out
    readonly property alias videoSink: out.videoSink
    // The video's own proportions, known once a frame was decoded (0 before).
    readonly property real videoAR: out.sourceRect.height > 0 ? out.sourceRect.width / out.sourceRect.height : 0
    readonly property bool fills: videoAR <= 0 || height <= 0 || Math.abs(Math.log(videoAR / (width / height))) < Math.log(1.18)

    // The blurred copy, cropped to fill.
    Item {
        anchors.fill: parent
        clip: true
        visible: !gv.fills
        ShaderEffectSource {
            sourceItem: out
            sourceRect: out.contentRect
            live: true
            anchors.centerIn: parent
            readonly property real k: Math.max(gv.width / Math.max(1, out.contentRect.width), gv.height / Math.max(1, out.contentRect.height))
            width: out.contentRect.width * k
            height: out.contentRect.height * k
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 1; blurMax: 48; blurMultiplier: 1.2; brightness: -0.3; saturation: -0.2 }
        }
    }
    VideoOutput {
        id: out
        anchors.fill: parent
        fillMode: gv.fills ? VideoOutput.PreserveAspectCrop : VideoOutput.PreserveAspectFit
    }
}
