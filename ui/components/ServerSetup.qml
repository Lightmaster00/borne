// First launch: RomM server address, typed with the on-screen keyboard.
import QtQuick

Item {
    id: setup
    property QtObject theme
    property bool busy: false
    property string error: ""
    property string initial: "http://"
    property bool pointerActive: false
    signal submit(string url)
    signal cancelled()

    function reset(url) { kb.text = url || initial; error = ""; busy = false }
    function handle(a) { if (!busy) kb.handle(a) }
    function typeText(t) { if (!busy) kb.typeText(t) }
    function backspace() { if (!busy) kb.backspace() }

    Column {
        anchors.centerIn: parent
        spacing: 22
        width: kb.implicitWidth
        Text { text: qsTr("RomM server"); color: theme.fg; font { family: theme.displayFont; pixelSize: 34; bold: true } }
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("Enter the address of your RomM server, for example http://192.168.1.20:8080 or https://romm.home.lan.")
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 16 }
        }
        OnScreenKeyboard {
            id: kb
            width: implicitWidth; height: implicitHeight
            theme: setup.theme
            text: setup.initial
            placeholder: "http://…"
            onAccepted: (t) => { setup.error = ""; setup.submit(t) }
            onCancelled: setup.cancelled()
        }
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: setup.busy ? qsTr("Connecting to the server…") : setup.error
            visible: text !== ""
            color: setup.busy ? theme.fgMuted : theme.bad
            font { family: theme.fontFamily; pixelSize: 15 }
        }
        HintBar {
            theme: setup.theme
            pointerActive: setup.pointerActive
            hints: [["A", qsTr("Key"), "a"], ["B", qsTr("Erase"), "b"], ["X", qsTr("Shift"), "x"], ["Y", qsTr("Space"), "y"], ["Start", qsTr("Confirm"), "start"]]
            onTriggered: (a) => setup.handle(a)
        }
    }
}
