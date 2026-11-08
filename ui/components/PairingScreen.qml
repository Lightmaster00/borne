// Pairing a profile with RomM: code + QR code to approve from a phone.
import QtQuick

Item {
    id: screen
    property QtObject theme
    property var pairing: null          // state returned by the core
    property string profileName: ""
    property string qrUrl: ""
    property int qrRevision: 0
    signal retry()
    signal back()

    readonly property string state_: pairing ? pairing.state : "starting"
    readonly property int remaining: pairing ? Math.max(0, pairing.expires_at - Math.floor(now / 1000)) : 0
    property double now: Date.now()
    Timer { interval: 1000; repeat: true; running: screen.visible; onTriggered: screen.now = Date.now() }

    function handle(a) {
        if (a === "b") back()
        else if (a === "a" && (state_ === "expired" || state_ === "denied" || state_ === "error")) retry()
    }

    Row {
        anchors.centerIn: parent
        spacing: 64
        Rectangle {
            width: 340; height: 340; radius: 16; color: "white"
            visible: screen.state_ === "waiting"
            Image {
                anchors { fill: parent; margins: 10 }
                source: screen.state_ === "waiting" ? screen.qrUrl + "?r=" + screen.qrRevision : ""
                fillMode: Image.PreserveAspectFit
                smooth: false
                cache: false
            }
        }
        Column {
            width: 560
            spacing: 18
            anchors.verticalCenter: parent.verticalCenter
            Text { text: qsTr("Pair “%1”").arg(screen.profileName); color: theme.fg; font { family: theme.displayFont; pixelSize: 32; bold: true } }
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                visible: screen.state_ === "waiting" || screen.state_ === "starting"
                text: qsTr("Scan the QR code with your phone, or open this address and sign in to RomM with this profile's account:")
                color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 16 }
            }
            Text {
                width: parent.width; wrapMode: Text.WrapAnywhere
                visible: screen.state_ === "waiting"
                text: screen.pairing ? screen.pairing.verification_url : ""
                color: theme.accent; font { family: theme.fontFamily; pixelSize: 15 }
            }
            Text { visible: screen.state_ === "waiting"; text: qsTr("Code to confirm"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 14; letterSpacing: 1 } }
            Text {
                visible: screen.state_ === "waiting"
                text: screen.pairing ? screen.pairing.user_code : ""
                color: theme.fg
                font { family: "DejaVu Sans Mono"; pixelSize: 54; bold: true; letterSpacing: 8 }
            }
            Text {
                width: parent.width; wrapMode: Text.WordWrap
                text: {
                    switch (screen.state_) {
                    case "starting": return qsTr("Connecting to RomM…")
                    case "waiting": return qsTr("Waiting for approval… (the code expires in %1 min %2 s)").arg(Math.floor(screen.remaining / 60)).arg(screen.remaining % 60)
                    case "approved": return qsTr("Profile paired ✓")
                    case "denied": return qsTr("Pairing refused in RomM. A to start again.")
                    case "expired": return qsTr("The code expired. A to get a new one.")
                    default: return qsTr("Error: %1. A to retry.").arg(screen.pairing && screen.pairing.error ? screen.pairing.error : qsTr("unknown"))
                    }
                }
                color: screen.state_ === "approved" ? theme.ok : (screen.state_ === "waiting" || screen.state_ === "starting") ? theme.fgMuted : theme.bad
                font { family: theme.fontFamily; pixelSize: 16 }
            }
            Text { text: qsTr("B  Cancel"); color: theme.fgMuted; font { family: theme.fontFamily; pixelSize: 13 } }
        }
    }
}
