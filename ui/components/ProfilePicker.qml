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
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("Who's playing?"); color: theme.fg; font { family: theme.displayFont; pixelSize: 64; weight: Font.ExtraBold; letterSpacing: -1.5 } }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 48
            Repeater {
                model: picker.count
                Item {
                    required property int index
                    readonly property bool isAdd: index >= picker.profiles.length
                    readonly property var p: isAdd ? null : picker.profiles[index]
                    readonly property bool cur: index === picker.index
                    width: 240; height: 320
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
                        width: 200; height: 200; radius: 100
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: parent.isAdd ? theme.glass : Qt.hsla(((parent.p.name.charCodeAt(0) * 37) % 360) / 360, 0.35, 0.36, 1)
                        border { width: parent.cur ? 4 : 1; color: parent.cur ? theme.focusRing : theme.glassEdge }
                        scale: parent.cur ? 1.08 : 1
                        Behavior on scale { NumberAnimation { duration: theme.focusMs; easing.type: Easing.OutCubic } }
                        Text {
                            anchors.centerIn: parent
                            text: parent.parent.isAdd ? "+" : parent.parent.p.name.charAt(0).toUpperCase()
                            color: parent.parent.isAdd ? theme.fgMuted : "white"
                            font { family: theme.displayFont; pixelSize: 84; weight: Font.ExtraBold }
                        }
                    }
                    Column {
                        anchors { top: avatar.bottom; topMargin: 18; horizontalCenter: parent.horizontalCenter }
                        spacing: 4
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: parent.parent.isAdd ? qsTr("Add") : parent.parent.p.name
                            color: parent.parent.cur ? theme.fg : theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 24; weight: parent.parent.cur ? Font.DemiBold : Font.Normal }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: !parent.parent.isAdd
                            text: parent.parent.p ? (parent.parent.p.paired ? qsTr("RomM: %1").arg(parent.parent.p.romm_user) : qsTr("Not paired")) : ""
                            color: parent.parent.p && !parent.parent.p.paired ? theme.bad : theme.fgMuted
                            font { family: theme.fontFamily; pixelSize: 16 }
                        }
                    }
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: (picker.serverUrl ? picker.serverUrl + "  ·  " + (picker.online ? qsTr("online") : qsTr("offline")) : "")
            color: picker.online ? theme.fgFaint : theme.bad
            font { family: theme.fontFamily; pixelSize: 16 }
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
