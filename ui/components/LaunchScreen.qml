// The passage between Borne and the emulator: shown as soon as a game is chosen to play, under the
// emulator while it runs, and for a moment when the game ends, so the screen never goes blank.
// The game's own art behind, its logo (or name), what is happening, and how to quit.
//
// phase: "" (hidden), "starting", "playing", "ending".
import QtQuick
import QtQuick.Effects

Item {
    id: screen
    property QtObject theme
    property var game: null          // Main.qml's game object (art, art_kinds, name, cover)
    property string phase: ""
    property string emulator: ""
    property string note: ""         // after the game: what happened to the save
    readonly property bool shown: phase !== ""
    readonly property bool keyboard: !!theme && theme.input === "keyboard"

    function has(kind) { return !!game && game.art_kinds && game.art_kinds.indexOf("," + kind + ",") >= 0 }

    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: theme ? Math.round(320 * theme.motion) : 320; easing.type: Easing.OutCubic } }

    Rectangle { anchors.fill: parent; color: "#05060A" }

    // The game's art, blurred and darkened, slowly drifting in.
    Image {
        id: art
        anchors.fill: parent
        source: !screen.game ? "" : screen.has("backdrop") ? screen.game.art + "backdrop"
              : screen.has("steamgrid") ? screen.game.art + "steamgrid" : screen.game.cover || ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize: Qt.size(960, 540)
        visible: false
    }
    MultiEffect {
        anchors.fill: parent
        source: art
        // Under a running game the GPU is the emulator's: no blur then.
        visible: screen.phase !== "playing"
        blurEnabled: true; blur: 0.7; blurMax: 48
        brightness: -0.18
        saturation: 0.1
        opacity: art.status === Image.Ready ? 0.85 : 0
        Behavior on opacity { NumberAnimation { duration: 500 } }
        scale: screen.shown ? 1.0 : 1.06
        Behavior on scale { NumberAnimation { duration: theme ? Math.round(1600 * theme.motion) : 1600; easing.type: Easing.OutCubic } }
    }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: Qt.rgba(0.02, 0.024, 0.04, 0.92) }
            GradientStop { position: 0.55; color: Qt.rgba(0.02, 0.024, 0.04, 0.55) }
            GradientStop { position: 1.0; color: Qt.rgba(0.02, 0.024, 0.04, 0.35) }
        }
    }

    Column {
        id: block
        anchors { left: parent.left; leftMargin: parent.width * 0.09; verticalCenter: parent.verticalCenter }
        width: Math.min(parent.width * 0.5, 760)
        spacing: 26

        Image {
            id: logo
            width: Math.min(block.width, 520); height: 170
            source: screen.has("logo") ? screen.game.art + "logo" : ""
            fillMode: Image.PreserveAspectFit
            horizontalAlignment: Image.AlignLeft
            asynchronous: true
            visible: status === Image.Ready
            sourceSize: Qt.size(1040, 340)
        }
        Text {
            visible: !logo.visible
            width: block.width
            text: screen.game ? screen.game.name : ""
            wrapMode: Text.WordWrap
            color: theme ? theme.fg : "white"
            font { family: theme ? theme.displayFont : "Fredoka"; pixelSize: 58; weight: Font.Bold }
            style: Text.Raised; styleColor: "#05060A"
        }

        Column {
            spacing: 14
            Text {
                text: screen.phase === "ending" ? qsTr("Back to Borne")
                    : screen.phase === "playing" ? qsTr("Playing in %1").arg(screen.emulator)
                    : screen.emulator ? qsTr("Starting %1…").arg(screen.emulator) : qsTr("Starting the game…")
                color: theme ? theme.fg : "white"
                font { family: theme ? theme.fontFamily : "Manrope"; pixelSize: 22; weight: Font.DemiBold }
            }
            // Indeterminate progress while the emulator opens; full once the game runs.
            Rectangle {
                width: Math.min(block.width, 420); height: 6; radius: 3
                color: Qt.rgba(1, 1, 1, 0.12)
                clip: true
                Rectangle {
                    id: runner
                    height: parent.height; radius: 3
                    color: theme ? theme.accent : "#8CCBFF"
                    width: screen.phase === "starting" ? parent.width * 0.32 : parent.width
                    x: screen.phase === "starting" ? sweep.value : 0
                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                }
                QtObject { id: sweep; property real value: 0 }
                NumberAnimation {
                    target: sweep; property: "value"
                    from: -parent.width * 0.32; to: parent.width
                    duration: 1300; loops: Animation.Infinite; easing.type: Easing.InOutSine
                    running: screen.phase === "starting" && screen.visible
                }
            }
            Text {
                visible: screen.note !== "" && screen.phase === "ending"
                text: screen.note
                color: theme ? theme.fgSoft : "#ccc"
                font { family: theme ? theme.fontFamily : "Manrope"; pixelSize: 17 }
            }
        }
    }

    // How to quit, as the hint bar draws it.
    Row {
        visible: screen.phase !== "ending"
        anchors { left: block.left; bottom: parent.bottom; bottomMargin: parent.height * 0.08 }
        spacing: 12
        Repeater {
            model: screen.keyboard ? ["Esc"] : ["Select", "Start"]
            Rectangle {
                required property string modelData
                anchors.verticalCenter: parent.verticalCenter
                height: 30; radius: 15
                width: capText.implicitWidth + 24
                color: Qt.rgba(0.96, 0.95, 1, 0.92)
                Text {
                    id: capText
                    anchors.centerIn: parent
                    text: modelData
                    color: "#0C0D10"
                    font { family: theme ? theme.displayFont : "Fredoka"; pixelSize: 16; weight: Font.Bold }
                }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: screen.keyboard ? qsTr("Pause and quit the game")
                                  : qsTr("Together: pause and quit the game")
            color: theme ? theme.fgSoft : "#ccc"
            font { family: theme ? theme.fontFamily : "Manrope"; pixelSize: 18 }
        }
    }
}
