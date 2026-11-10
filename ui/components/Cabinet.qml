// One arcade cabinet: lit marquee with the game's title, a screen showing its cover, a control
// panel, a coin door; side panels with a stripe in the game's color. Faces drawn through
// ArcadeRoom.faceMatrix.
import QtQuick
import QtQuick.Effects

Item {
    id: cab
    property QtObject theme
    property Item stage
    property var game: null
    property var place: ({ x: 0, y: 0, z: 0, ang: 0 })
    property bool current: false
    property bool pointerActive: false
    signal clicked()

    readonly property real cw: stage.cabW
    readonly property real ch: stage.cabH
    readonly property real cd: stage.cabD
    readonly property color tone: theme.tone(game ? game.hue : 0)
    readonly property color glow: Qt.lighter(tone, 1.9)
    readonly property real frontFacing: stage.facing(place, "front")

    // ---------- side panels ----------
    component Side: Item {
        id: side
        property string which: "left"
        readonly property real facingValue: cab.stage.facing(cab.place, which)
        width: cab.cd; height: cab.ch
        visible: facingValue > 0.02
        transform: Matrix4x4 { matrix: cab.stage.faceMatrix(cab.place, side.which) }
        Rectangle { anchors.fill: parent; color: "#16161d"; border { width: 2; color: "#24242e" } }
        // Side art: a diagonal band in the game's color.
        Item {
            anchors.fill: parent
            clip: true
            Rectangle {
                width: parent.width * 0.55; height: parent.height * 1.4
                x: parent.width * 0.2; y: -parent.height * 0.2
                rotation: 14
                color: cab.tone
                opacity: 0.9
            }
            Rectangle {
                width: 10; height: parent.height * 1.4
                x: parent.width * 0.82; y: -parent.height * 0.2
                rotation: 14
                color: cab.glow
                opacity: 0.6
            }
        }
        Rectangle { anchors.fill: parent; color: "black"; opacity: Math.max(0, 0.65 - side.facingValue * 0.55) }
    }
    Side { which: "left" }
    Side { which: "right" }

    // ---------- front ----------
    Item {
        id: front
        width: cab.cw; height: cab.ch
        visible: cab.frontFacing > 0.02
        transform: Matrix4x4 { matrix: cab.stage.faceMatrix(cab.place, "front") }

        // Body.
        Rectangle { anchors.fill: parent; color: "#121218"; border { width: 2; color: "#24242e" } }

        // Marquee, backlit, with the title.
        Rectangle {
            id: marquee
            x: 10; y: 10; width: parent.width - 20; height: 96
            radius: 6
            color: cab.tone
            Rectangle {
                anchors.fill: parent; radius: 6
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.28) }
                    GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
                }
            }
            Text {
                anchors { fill: parent; margins: 12 }
                text: cab.game ? cab.game.name : ""
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                fontSizeMode: Text.Fit
                minimumPixelSize: 14
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: "white"
                style: Text.Raised
                styleColor: Qt.rgba(0, 0, 0, 0.5)
                font { family: cab.theme.displayFont; pixelSize: 30; weight: Font.ExtraBold }
            }
        }

        // Screen: the cover on a dark tube, scanlines, a glow when selected.
        Rectangle {
            id: bezel
            x: 18; y: 122; width: parent.width - 36; height: 250
            radius: 10
            color: "#050507"
            Rectangle {
                id: screen
                anchors { fill: parent; margins: 14 }
                radius: 14
                color: "#08080c"
                clip: true
                Image {
                    anchors.fill: parent
                    source: cab.game && cab.game.cover ? cab.game.cover : ""
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    verticalAlignment: Image.AlignTop
                    sourceSize: Qt.size(360, 540)
                    opacity: cab.current ? 1 : 0.75
                }
                Column {
                    anchors.fill: parent
                    Repeater {
                        model: Math.ceil(screen.height / 4)
                        Rectangle { width: screen.width; height: 4; color: "transparent"
                            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0, 0, 0, 0.28) } }
                    }
                }
                Rectangle {
                    anchors.fill: parent; radius: 14
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.10) }
                        GradientStop { position: 0.4; color: "transparent" }
                    }
                }
            }
        }

        // Control panel: a stick and six buttons.
        Rectangle {
            x: 10; y: 388; width: parent.width - 20; height: 92
            radius: 6
            color: "#1d1d26"
            border { width: 1; color: "#2c2c38" }
            Rectangle { x: 40; y: 30; width: 34; height: 34; radius: 17; color: "#0b0b0f" }
            Rectangle { x: 49; y: 14; width: 16; height: 34; radius: 8; color: "#3a3a44" }
            Rectangle { x: 45; y: 6; width: 24; height: 24; radius: 12; color: cab.glow }
            Grid {
                x: 128; y: 18
                columns: 3; spacing: 12
                Repeater {
                    model: 6
                    Rectangle {
                        required property int index
                        width: 30; height: 30; radius: 15
                        color: index % 3 === 0 ? cab.glow : index % 3 === 1 ? "#e9e9ee" : cab.tone
                        border { width: 2; color: Qt.rgba(0, 0, 0, 0.35) }
                    }
                }
            }
        }

        // Coin door.
        Rectangle {
            x: parent.width / 2 - 70; y: 540; width: 140; height: 100
            radius: 6
            color: "#0d0d12"
            border { width: 2; color: "#2a2a34" }
            Row {
                anchors.centerIn: parent
                spacing: 26
                Repeater {
                    model: 2
                    Rectangle {
                        width: 18; height: 34; radius: 3
                        color: "#ff7a2f"
                        opacity: cab.current ? 0.95 : 0.55
                    }
                }
            }
        }

        // State mark on the marquee corner: installed / mounted / failed / downloading.
        Rectangle {
            readonly property string dl: cab.game && cab.game.dl_state ? cab.game.dl_state : ""
            readonly property bool busy: dl === "queued" || dl === "downloading" || dl === "verifying" || dl === "extracting"
            readonly property bool installed: !busy && cab.game && cab.game.local_state === "local"
            readonly property bool mounted: !busy && cab.game && cab.game.linked && !installed
            readonly property bool broken: !busy && (dl === "failed" || (cab.game && cab.game.local_state === "missing"))
            visible: installed || mounted || broken || busy
            x: parent.width - 48; y: 128
            width: 30; height: 30; radius: 15
            color: broken ? cab.theme.bad : Qt.rgba(0.02, 0.02, 0.03, 0.75)
            border { width: 1; color: Qt.rgba(1, 1, 1, 0.3) }
            Icon { anchors.centerIn: parent; size: 15; stroke: 3.2; color: parent.broken ? cab.theme.bg : cab.theme.fg
                   name: parent.busy ? "download" : parent.installed ? "check" : parent.mounted ? "link" : "alert" }
        }

        // Shading when turned away, ring when selected.
        Rectangle { anchors.fill: parent; color: "black"; opacity: Math.max(0, 0.7 - cab.frontFacing * 0.7) }
        Rectangle {
            anchors { fill: parent; margins: -10 }
            color: "transparent"
            radius: 8
            border { width: 3; color: cab.theme.focusRing }
            opacity: cab.current ? 1 : mouse.containsMouse ? 0.4 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: cab.pointerActive
            cursorShape: Qt.PointingHandCursor
            onClicked: cab.clicked()
        }
    }

    // Glow of the selected cabinet's screen on the room.
    Rectangle { id: glowSource; x: 0; y: 0; width: cab.cw; height: cab.ch; visible: false; color: "transparent"
        Rectangle { x: 18; y: 122; width: cab.cw - 36; height: 250; radius: 20; color: cab.glow } }
    MultiEffect {
        width: cab.cw; height: cab.ch
        source: glowSource
        visible: cab.current
        opacity: 0.55
        autoPaddingEnabled: true
        blurEnabled: true; blur: 1.0; blurMax: 64
        transform: Matrix4x4 { matrix: cab.stage.faceMatrix(cab.place, "front") }
        z: -1
    }
}
