// The frame round the screen, in the selected console's colours: its blank Steam grid from
// ScreenScraper when there is one, over a gradient of its own colour with diagonal stripes and two
// soft discs. Drawn over the window with a rounded hole where the scene shows, edged in ink.
import QtQuick
import QtQuick.Effects

Item {
    id: frame
    property color tint: "#5A6DB0"
    property string art: ""           // the console's frame image (url), or ""
    property real margin: 40
    property real radius: 40
    property color ink: "#05060A"
    Behavior on tint { ColorAnimation { duration: 600 } }

    // ---------- the artwork, drawn off screen then cut ----------
    Item {
        id: artwork
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.darker(frame.tint, 2.6) }
                GradientStop { position: 1; color: frame.tint }
            }
        }
        Rectangle {
            x: -parent.height * 0.15; y: -parent.height * 0.2
            width: parent.height * 0.6; height: width; radius: width / 2
            color: Qt.lighter(frame.tint, 1.6); opacity: 0.3
        }
        Rectangle {
            x: parent.width - parent.height * 0.5; y: parent.height * 0.55
            width: parent.height * 0.75; height: width; radius: width / 2
            color: frame.tint; opacity: 0.5
        }
        Canvas {
            id: stripes
            anchors.fill: parent
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const c = getContext("2d")
                c.clearRect(0, 0, width, height)
                c.fillStyle = "rgba(255,255,255,0.05)"
                for (let x = -height; x < width + height; x += 60) {
                    c.beginPath()
                    c.moveTo(x, 0); c.lineTo(x + 18, 0); c.lineTo(x + 18 - height, height); c.lineTo(x - height, height)
                    c.closePath(); c.fill()
                }
            }
        }
        // ScreenScraper's art of the console, cross-faded when the console changes.
        property bool useA: true
        Timer { id: swapDelay; interval: 250; onTriggered: artwork.swap() }
        Connections { target: frame; function onArtChanged() { swapDelay.restart() } }
        Component.onCompleted: swap()
        function swap() {
            useA = !useA
            ;(useA ? artA : artB).source = frame.art
        }
        component ArtImage: Image {
            property bool front: false
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 1920
            opacity: front && status === Image.Ready && source != "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
        }
        ArtImage { id: artA; front: artwork.useA }
        ArtImage { id: artB; front: !artwork.useA }
        // A little darker, so the frame never outshines the screen.
        Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.18 }
    }

    // ---------- the hole ----------
    Item {
        id: hole
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle {
            x: frame.margin; y: frame.margin
            width: frame.width - 2 * frame.margin; height: frame.height - 2 * frame.margin
            radius: frame.radius
            color: "black"
        }
    }
    MultiEffect {
        anchors.fill: parent
        source: artwork
        maskEnabled: true
        maskSource: hole
        maskInverted: true
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }
    // Ink edge round the screen.
    Rectangle {
        x: frame.margin - 3; y: frame.margin - 3
        width: frame.width - 2 * frame.margin + 6; height: frame.height - 2 * frame.margin + 6
        radius: frame.radius + 3
        color: "transparent"
        border { width: 5; color: frame.ink }
    }
}
