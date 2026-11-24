// What stays on screen round the home, a folder and a game's page: the rail on the left (the
// profile, Home, Store, Downloads, Settings, Quit) and, top right, the downloads under way, the
// server's state and the time.
import QtQuick
import QtQuick.Effects

Item {
    id: chrome
    property QtObject theme
    property var items: []              // [{ id, label, icon }] top to bottom
    property int index: 0               // the item selected (when focused)
    property bool focused: false        // the rail has the focus
    property string here: "home"        // the item of the page shown ("home" | "store")
    property string profileName: ""
    property color profileColor: "#D9733F"
    property bool downloading: false    // a dot on Downloads
    property string downloadsText: ""
    property real downloadsProgress: -1
    property bool online: true
    property string serverText: "RomM"
    property string clockText: ""
    readonly property real motion: theme ? theme.motion : 1

    // ---------- the rail ----------
    Rectangle {
        id: rail
        x: 46
        anchors.verticalCenter: parent.verticalCenter
        width: 96
        height: col.implicitHeight + 32
        radius: 48
        color: Qt.rgba(0.047, 0.047, 0.063, 0.42)
        border { width: 1; color: Qt.rgba(1, 1, 1, 0.1) }
        Column {
            id: col
            anchors.centerIn: parent
            spacing: 14
            Repeater {
                model: chrome.items
                Item {
                    id: it
                    required property var modelData
                    required property int index
                    readonly property bool on: chrome.focused && index === chrome.index
                    readonly property bool isHere: modelData.id === chrome.here
                    readonly property bool isProfile: modelData.id === "profile"
                    width: 64; height: 64
                    scale: it.on ? 1.1 : 1
                    Behavior on scale { NumberAnimation { duration: 320 * chrome.motion; easing.type: Easing.OutBack; easing.overshoot: 2.2 } }
                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.label
                    FocusGlow { on: it.on; tint: theme.accent; ringColor: theme.fg; radius: 32; gap: 6; line: 3; motion: chrome.motion }
                    Rectangle {
                        anchors.fill: parent
                        radius: 32
                        color: it.on ? theme.fg : it.isProfile ? chrome.profileColor : it.isHere ? Qt.rgba(1, 1, 1, 0.14) : "transparent"
                        Behavior on color { ColorAnimation { duration: 250 * chrome.motion } }
                    }
                    Text {
                        visible: it.isProfile
                        anchors.centerIn: parent
                        text: chrome.profileName ? chrome.profileName.charAt(0).toUpperCase() : "?"
                        color: it.on ? "#121216" : "#ffffff"
                        font { family: theme.fontFamily; pixelSize: 24; weight: Font.ExtraBold }
                    }
                    Icon {
                        visible: !it.isProfile
                        anchors.centerIn: parent
                        name: it.modelData.icon
                        size: 26
                        stroke: 2.2
                        color: it.on ? "#121216" : theme.fg
                        opacity: it.on || it.isHere ? 1 : 0.6
                        Behavior on opacity { NumberAnimation { duration: 250 * chrome.motion } }
                    }
                    Rectangle {
                        visible: it.modelData.id === "downloads" && chrome.downloading
                        x: parent.width - 16; y: 4
                        width: 12; height: 12; radius: 6
                        color: "#4FD08A"
                    }
                    // Its name, beside it, while selected.
                    Rectangle {
                        x: 82 + (it.on ? 0 : -10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: tipText.implicitWidth + 32; height: 38; radius: 19
                        color: Qt.rgba(0.96, 0.95, 0.94, 0.95)
                        opacity: it.on ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity { NumberAnimation { duration: 200 * chrome.motion } }
                        Behavior on x { NumberAnimation { duration: 250 * chrome.motion; easing.type: Easing.OutCubic } }
                        Text {
                            id: tipText
                            anchors.centerIn: parent
                            text: it.modelData.label
                            color: "#121216"
                            font { family: theme.fontFamily; pixelSize: 16; weight: Font.ExtraBold }
                        }
                    }
                }
            }
        }
    }

    // Borne's logo, top left: its red pictogram and name, present without taking the eye.
    Row {
        x: 58; y: 44
        height: 26
        spacing: 10      // a little more air than the drawn logo between the two
        opacity: 0.92
        Image {
            width: 26; height: 26
            source: "../brand/picto.svg"
            sourceSize: chrome.theme ? Qt.size(chrome.theme.px(26), chrome.theme.px(26)) : Qt.size(104, 104)
            smooth: true
        }
        Brand {
            anchors.verticalCenter: parent.verticalCenter
            lettering: true
            size: Math.round(26 * 250 / 330)
        }
    }

    // ---------- status ----------
    Row {
        anchors { right: parent.right; rightMargin: 120; top: parent.top; topMargin: 56 }
        spacing: 24
        Row {
            visible: chrome.downloadsText !== ""
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Rectangle {
                visible: chrome.downloadsProgress >= 0
                anchors.verticalCenter: parent.verticalCenter
                width: 90; height: 6; radius: 3
                color: Qt.rgba(1, 1, 1, 0.2)
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, chrome.downloadsProgress)); height: parent.height; radius: 3
                    color: theme.fg
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: chrome.downloadsText
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
            }
        }
        // The server: shown only when it cannot be reached.
        Row {
            visible: !chrome.online
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 10; height: 10; radius: 5
                color: chrome.online ? "#4FD08A" : "#E0684F"
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: chrome.serverText
                color: theme.fg
                font { family: theme.fontFamily; pixelSize: 16; weight: Font.Bold }
            }
        }
        Text {
            visible: chrome.clockText !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: chrome.clockText
            color: theme.fg
            font { family: theme.fontFamily; pixelSize: 20; weight: Font.Bold; features: { "tnum": 1 } }
        }
    }
}
