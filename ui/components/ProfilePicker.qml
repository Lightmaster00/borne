// Console-style profile picker at startup.
import QtQuick

Item {
    id: picker
    property QtObject theme
    property var profiles: []
    property string lastUsed: ""
    property int index: 0
    property string serverUrl: ""
    property bool online: false
    property bool pointerActive: false
    signal choose(var profile)
    signal add()
    signal options(var profile)
    signal mainMenu()

    readonly property int count: profiles.length + 1
    function focusLastUsed() {
        const i = profiles.findIndex(p => p.id === lastUsed)
        index = i >= 0 ? i : 0
    }
    function handle(a) {
        if (a === "left") index = Math.max(0, index - 1)
        else if (a === "right") index = Math.min(count - 1, index + 1)
        else if (a === "a") { if (index < profiles.length) choose(profiles[index]); else add() }
        else if (a === "y" && index < profiles.length) options(profiles[index])
        else if (a === "start") mainMenu()
    }

    Column {
        anchors.centerIn: parent
        spacing: 40
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("Who's playing?"); color: theme.fg; font { family: theme.displayFont; pixelSize: 38; bold: true } }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 32
            Repeater {
                model: picker.count
                Item {
                    required property int index
                    readonly property bool isAdd: index >= picker.profiles.length
                    readonly property var p: isAdd ? null : picker.profiles[index]
                    readonly property bool cur: index === picker.index
                    width: 180; height: 250
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        onClicked: (m) => {
                            picker.index = parent.index
                            picker.handle(m.button === Qt.RightButton ? "y" : "a")
                        }
                    }
                    Rectangle {
                        id: avatar
                        width: 160; height: 160; radius: 80
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: parent.isAdd ? "transparent" : Qt.hsla(((parent.p.name.charCodeAt(0) * 37) % 360) / 360, 0.5, 0.42, 1)
                        border { width: parent.cur ? 5 : (parent.isAdd ? 2 : 0); color: parent.cur ? theme.focusRing : theme.fgMuted }
                        scale: parent.cur ? 1.08 : 1
                        Behavior on scale { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutCubic } }
                        Text {
                            anchors.centerIn: parent
                            text: parent.parent.isAdd ? "+" : parent.parent.p.name.charAt(0).toUpperCase()
                            color: parent.parent.isAdd ? theme.fgMuted : "white"
                            font { family: theme.displayFont; pixelSize: 72; bold: true }
                        }
                    }
                    Column {
                        anchors { top: avatar.bottom; topMargin: 18; horizontalCenter: parent.horizontalCenter }
                        spacing: 4
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: parent.parent.isAdd ? qsTr("Add") : parent.parent.p.name
                            color: parent.parent.cur ? theme.fg : theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 20; bold: parent.parent.cur }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: !parent.parent.isAdd
                            text: parent.parent.p ? (parent.parent.p.paired ? qsTr("RomM: %1").arg(parent.parent.p.romm_user) : qsTr("Not paired")) : ""
                            color: parent.parent.p && !parent.parent.p.paired ? theme.bad : theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 13 }
                        }
                    }
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: (picker.serverUrl ? picker.serverUrl + "  ·  " + (picker.online ? qsTr("online") : qsTr("offline")) : "")
            color: picker.online ? theme.fgMuted : theme.bad
            font { family: theme.fontFamily; pixelSize: 13 }
        }
        HintBar {
            anchors.horizontalCenter: parent.horizontalCenter
            theme: picker.theme
            pointerActive: picker.pointerActive
            hints: [["A", qsTr("Choose"), "a"], ["Y", qsTr("Profile options"), "y"], ["Start", qsTr("Menu"), "start"]]
            onTriggered: (a) => picker.handle(a)
        }
    }
}
