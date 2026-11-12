// Pairing a profile with RomM: a code and a QR code to approve from a phone or a computer.
import QtQuick

Item {
    id: screen
    property QtObject theme
    property var pairing: null          // state returned by the core
    property string profileName: ""
    property string serverUrl: ""
    property string qrUrl: ""
    property int qrRevision: 0
    signal retry()
    signal back()

    readonly property string state_: pairing ? pairing.state : "starting"
    readonly property int remaining: pairing ? Math.max(0, pairing.expires_at - Math.floor(now / 1000)) : 0
    readonly property bool failed: state_ === "expired" || state_ === "denied" || state_ === "error"
    property double now: Date.now()
    Timer { interval: 1000; repeat: true; running: screen.visible; onTriggered: screen.now = Date.now() }

    function handle(a) {
        if (a === "b") back()
        else if (a === "a" && failed) retry()
    }

    Rectangle { anchors.fill: parent; color: theme.bg }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: 72
        spacing: 40

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 14
            Logo { anchors.verticalCenter: parent.verticalCenter; theme: screen.theme; size: 32 }
            Text { text: "Borne"; color: theme.fg; font { family: theme.displayFont; pixelSize: 32; weight: Font.ExtraBold } }
        }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12
            Repeater {
                model: [qsTr("Server"), qsTr("Pair this device"), qsTr("Profile")]
                Rectangle {
                    required property string modelData
                    required property int index
                    width: stepText.implicitWidth + 32; height: 36; radius: 18
                    color: index === 1 ? theme.fg : theme.surface
                    Text {
                        id: stepText
                        anchors.centerIn: parent
                        text: (index === 0 ? "✓ " : (index + 1) + " · ") + modelData
                        color: index === 1 ? theme.bg : index === 0 ? theme.fgMuted : theme.fgFaint
                        font { family: theme.fontFamily; pixelSize: 16; weight: Font.DemiBold }
                    }
                }
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 72
            Column {
                width: 808
                anchors.verticalCenter: parent.verticalCenter
                spacing: 24
                Text {
                    width: parent.width
                    text: qsTr("Approve “%1” from RomM").arg(screen.profileName)
                    wrapMode: Text.WordWrap
                    lineHeight: 1.05
                    color: theme.fg
                    font { family: theme.displayFont; pixelSize: 56; weight: Font.ExtraBold; letterSpacing: -1.5 }
                }
                Text {
                    width: 620
                    wrapMode: Text.WordWrap
                    lineHeight: 1.45
                    text: qsTr("Scan the QR code with your phone, or open the address below and sign in with this profile's RomM account, then confirm the code.")
                    color: theme.fgSoft
                    font { family: theme.fontFamily; pixelSize: 20 }
                }
                Text {
                    visible: screen.state_ === "waiting"
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    text: screen.pairing ? screen.pairing.verification_url : ""
                    color: theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 17 }
                }
                Text {
                    visible: screen.state_ === "waiting"
                    text: screen.pairing ? screen.pairing.user_code : ""
                    color: theme.accent
                    font { family: theme.displayFont; pixelSize: 88; weight: Font.ExtraBold; letterSpacing: 12 }
                    Accessible.name: qsTr("Pairing code %1").arg(text)
                }
                Row {
                    spacing: 12
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10; height: 10; radius: 5
                        color: screen.state_ === "approved" ? theme.status : screen.failed ? theme.bad : theme.accent
                    }
                    Text {
                        width: 760
                        wrapMode: Text.WordWrap
                        text: {
                            switch (screen.state_) {
                            case "starting": return qsTr("Connecting to RomM…")
                            case "waiting": return qsTr("Waiting for approval · the code renews in %1:%2").arg(Math.floor(screen.remaining / 60)).arg(String(screen.remaining % 60).padStart(2, "0"))
                            case "approved": return qsTr("Profile paired")
                            case "denied": return qsTr("Pairing refused in RomM. %1 to start again.").arg(screen.theme.key("a"))
                            case "expired": return qsTr("The code expired. %1 to get a new one.").arg(screen.theme.key("a"))
                            default: return qsTr("Error: %1. %2 to retry.").arg(screen.pairing && screen.pairing.error ? screen.pairing.error : qsTr("unknown")).arg(screen.theme.key("a"))
                            }
                        }
                        color: screen.failed ? theme.bad : theme.fgMuted
                        font { family: theme.fontFamily; pixelSize: 18 }
                    }
                }
            }
            Rectangle {
                width: 400; height: 400; radius: 24
                color: "white"
                opacity: screen.state_ === "waiting" ? 1 : 0.15
                anchors.verticalCenter: parent.verticalCenter
                Image {
                    anchors { fill: parent; margins: 28 }
                    source: screen.state_ === "waiting" ? screen.qrUrl + "?r=" + screen.qrRevision : ""
                    fillMode: Image.PreserveAspectFit
                    smooth: false
                    cache: false
                }
            }
        }

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 1280; height: 72; radius: 16
            color: theme.surface
            Icon { x: 24; anchors.verticalCenter: parent.verticalCenter; name: "info"; size: 24; stroke: 2; color: theme.statusSoft }
            Text {
                x: 68; anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 92
                wrapMode: Text.WordWrap
                text: qsTr("No place to enter the code in RomM? Pairing by code needs a recent RomM: update the server, then try again.")
                color: theme.fgSoft
                font { family: theme.fontFamily; pixelSize: 17 }
            }
        }
    }

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 64
        color: theme.bg
        Rectangle { width: parent.width; height: 1; color: theme.raised }
        HintBar {
            x: 52; anchors.verticalCenter: parent.verticalCenter
            theme: screen.theme
            hints: screen.failed ? [["A", qsTr("Retry"), "a"], ["B", qsTr("Cancel"), "b"]] : [["B", qsTr("Cancel"), "b"]]
        }
        Text {
            anchors { right: parent.right; rightMargin: 64; verticalCenter: parent.verticalCenter }
            text: screen.serverUrl
            color: theme.fgFaint
            font { family: theme.fontFamily; pixelSize: 17 }
        }
    }
}
