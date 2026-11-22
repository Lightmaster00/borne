// The border round the screen, in the colour of the console of the game you are on (or of the
// console filtered), with a soft glow inside. A tab hangs from its top edge with the console's
// logo, large (ScreenScraper's, in white), its name when there is none. The colour and the logo change
// with a fade as you move from one console's game to another's.
import QtQuick
import QtQuick.Effects

Item {
    id: frame
    property color tint: "#5A6DB0"
    property real margin: 14          // border thickness, window pixels
    property real radius: 34          // the screen's corners
    property real unit: 1             // the scene's scale: the tab follows the interface's size
    property string logo: ""          // the console's logo (url), or ""
    property string name: ""          // its name, shown without a logo; "" hides the tab
    property int fadeMs: 650
    readonly property bool light: tint.hslLightness > 0.62
    readonly property color ink: light ? "#121216" : "#ffffff"
    Behavior on tint { ColorAnimation { duration: frame.fadeMs } }

    // A rectangle far larger than the window, whose thick border is the frame: its inner edge is
    // the screen's rounded corners.
    readonly property real spill: 400
    Rectangle {
        x: -frame.spill; y: -frame.spill
        width: frame.width + 2 * frame.spill; height: frame.height + 2 * frame.spill
        radius: frame.radius + frame.spill + frame.margin
        color: "transparent"
        border { width: frame.spill + frame.margin; color: frame.tint }
    }
    // The glow: a few rings fading inward.
    Repeater {
        model: 7
        Rectangle {
            required property int index
            readonly property real inset: frame.margin + index * 6 * frame.unit
            x: inset; y: inset
            width: frame.width - 2 * inset; height: frame.height - 2 * inset
            radius: Math.max(0, frame.radius - index * 6 * frame.unit)
            color: "transparent"
            border { width: 6 * frame.unit; color: Qt.rgba(frame.tint.r, frame.tint.g, frame.tint.b, 0.16 * (1 - index / 7)) }
        }
    }

    // ---------- the tab ----------
    Rectangle {
        id: tab
        visible: frame.name !== ""
        readonly property real r: 30 * frame.unit
        width: 520 * frame.unit
        height: 88 * frame.unit + r
        x: (frame.width - width) / 2
        y: -r
        radius: r
        color: frame.tint
        // Its contents cross-fade when the console changes.
        property bool useA: true
        property string shownName: ""
        property string shownLogo: ""
        Component.onCompleted: swap()
        function swap() {
            useA = !useA
            const t = useA ? a : b
            t.logo = frame.logo
            t.label = frame.name
        }
        Connections {
            target: frame
            function onNameChanged() { swapDelay.restart() }
            function onLogoChanged() { swapDelay.restart() }
        }
        Timer { id: swapDelay; interval: 40; onTriggered: tab.swap() }
        TabFace { id: a; front: tab.useA }
        TabFace { id: b; front: !tab.useA }
    }

    component TabFace: Item {
        id: face
        property bool front: false
        property string logo: ""
        property string label: ""
        x: 0; y: tab.r
        width: tab.width; height: tab.height - tab.r
        opacity: front ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: frame.fadeMs * 0.6; easing.type: Easing.InOutQuad } }
        Image {
            id: logoImg
            anchors.centerIn: parent
            visible: status === Image.Ready && face.logo !== ""
            source: face.logo
            height: 58 * frame.unit
            width: Math.min(face.width - 80 * frame.unit, implicitWidth * height / Math.max(1, implicitHeight))
            sourceSize.height: 160
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            // In white on the console's colour (black on a light one).
            layer.enabled: true
            layer.effect: MultiEffect { brightness: frame.light ? -1.0 : 1.0; saturation: -1.0 }
        }
        Text {
            anchors.centerIn: parent
            visible: !logoImg.visible
            text: face.label
            color: frame.ink
            font { family: "Bricolage Grotesque"; pixelSize: 38 * frame.unit; weight: Font.ExtraBold; letterSpacing: -0.8 * frame.unit }
        }
    }
}
