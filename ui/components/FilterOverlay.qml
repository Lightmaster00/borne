// Filter: the consoles as cards fanned out like a hand, the chosen one standing up in front (and
// the screen's border already in its colour); below, quick filters and genres to add. Left and
// right pick a console, down reaches the filters, A applies, B closes.
import QtQuick
import QtQuick.Effects
import "Cases.js" as Cases

Rectangle {
    id: root
    property QtObject theme
    property var consoles: []         // [{ slug ("" for all), name, logo, home, store }]
    property int index: 0
    property var chips: []            // [{ label, on }]
    property int chipIndex: 0
    property bool chipsFocused: false
    property string line: ""
    property var keyLabel: function (a) { return a }

    color: Qt.rgba(0.024, 0.024, 0.04, 0.9)
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 300 } }

    Column {
        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Math.round(root.height * 0.09) }
        spacing: 10
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Filter")
            color: theme.fg
            font { family: theme.displayFont; pixelSize: 60; weight: Font.ExtraBold; letterSpacing: -1.5 }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: qsTr("Choose a console, then narrow down if you like.")
            color: theme.fgMuted
            font { family: theme.fontFamily; pixelSize: 19; weight: Font.DemiBold }
        }
    }

    // The fan: cards around the chosen one, which stands up in front.
    Item {
        id: fan
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(root.height * 0.33); width: 0; height: 400
        // The cards smaller in a short scene (a large interface, a small window).
        scale: Math.min(1, root.height / 1000)
        transformOrigin: Item.Top
        Repeater {
            model: root.consoles
            Item {
                id: card
                required property var modelData
                required property int index
                readonly property int d: index - root.index
                readonly property bool on: d === 0
                readonly property color tint: modelData.slug ? Cases.tint(modelData.slug) : "#2A2B33"
                visible: Math.abs(d) <= 5
                width: 240; height: 336
                x: d * 214 - width / 2
                y: on ? -40 : d * d * 8
                z: 20 - Math.abs(d)
                rotation: on ? 0 : d * 4.5
                scale: on ? 1.12 : 0.94
                opacity: on ? 1 : Math.max(0, 0.66 - (Math.abs(d) - 1) * 0.12) * (root.chipsFocused ? 0.6 : 1)
                Behavior on x { NumberAnimation { duration: 520 * theme.motion; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
                Behavior on y { NumberAnimation { duration: 520 * theme.motion; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
                Behavior on rotation { NumberAnimation { duration: 520 * theme.motion; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 520 * theme.motion; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                Behavior on opacity { NumberAnimation { duration: 300 } }
                Accessible.role: Accessible.Button
                Accessible.name: modelData.name

                Rectangle {
                    visible: card.on && !root.chipsFocused
                    anchors { fill: face; margins: -8 }
                    radius: face.radius + 8
                    color: "transparent"
                    border { width: 4; color: theme.fg }
                }
                Rectangle {
                    id: face
                    anchors.fill: parent
                    radius: 30
                    clip: true
                    gradient: Gradient {
                        GradientStop { position: 0; color: card.modelData.slug ? Qt.lighter(card.tint, 1.15) : "#34353F" }
                        GradientStop { position: 1; color: card.modelData.slug ? Qt.darker(card.tint, 2.4) : "#16171C" }
                    }
                    // The consoles' colours in a ring, for "every console".
                    Repeater {
                        model: card.modelData.slug ? [] : root.consoles.slice(1, 9)
                        Rectangle {
                            required property var modelData
                            required property int index
                            readonly property real a: index / Math.max(1, Math.min(8, root.consoles.length - 1)) * 2 * Math.PI - Math.PI / 2
                            width: 38; height: 38; radius: 19
                            x: face.width / 2 - 19 + Math.cos(a) * 52
                            y: 92 - 19 + Math.sin(a) * 52
                            color: Cases.tint(modelData.slug)
                        }
                    }
                    Image {
                        id: logo
                        visible: card.modelData.slug !== "" && status === Image.Ready
                        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 50 }
                        source: card.modelData.logo || ""
                        width: parent.width - 52; height: 82
                        sourceSize.height: 164
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        layer.enabled: true
                        layer.effect: MultiEffect { brightness: 1.0; saturation: -1.0 }
                    }
                    Text {
                        visible: card.modelData.slug !== "" && !logo.visible
                        anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 56 }
                        width: parent.width - 40
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        text: card.modelData.name
                        color: "#ffffff"
                        font { family: theme.displayFont; pixelSize: 32; weight: Font.ExtraBold }
                    }
                    Column {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 24 }
                        spacing: 4
                        Text {
                            visible: card.modelData.slug === ""
                            text: card.modelData.name
                            color: "#ffffff"
                            font { family: theme.displayFont; pixelSize: 30; weight: Font.ExtraBold }
                        }
                        Text {
                            text: String(card.modelData.home)
                            color: "#ffffff"
                            font { family: theme.displayFont; pixelSize: 54; weight: Font.ExtraBold }
                        }
                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: qsTr("installed · %1 in the store").arg(card.modelData.store)
                            color: Qt.rgba(1, 1, 1, 0.85)
                            font { family: theme.fontFamily; pixelSize: 15; weight: Font.Bold }
                        }
                    }
                }
            }
        }
    }

    Column {
        anchors { horizontalCenter: parent.horizontalCenter; top: fan.top; topMargin: 420 * fan.scale + 20 }
        width: Math.min(parent.width - 240, 1500)
        spacing: 18
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.line
            color: theme.fgSoft
            font { family: theme.fontFamily; pixelSize: 19; weight: Font.Bold }
        }
        Flow {
            width: parent.width
            spacing: 12
            // Centred: the Flow's rows as wide as their chips.
            leftPadding: Math.max(0, (width - chipsWidth) / 2)
            readonly property real chipsWidth: {
                let w = 0
                for (let i = 0; i < chipRep.count; i++) { const c = chipRep.itemAt(i); if (c) w += c.width + 12 }
                return Math.min(width, w - 12)
            }
            Repeater {
                id: chipRep
                model: root.chips
                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool sel: root.chipsFocused && index === root.chipIndex
                    width: chipText.implicitWidth + 44; height: 52; radius: 26
                    color: modelData.on ? theme.fg : Qt.rgba(1, 1, 1, 0.06)
                    border { width: 2; color: modelData.on ? theme.fg : Qt.rgba(1, 1, 1, 0.25) }
                    Accessible.role: Accessible.CheckBox
                    Accessible.name: modelData.label
                    Accessible.checked: modelData.on
                    Rectangle {
                        visible: parent.sel
                        anchors { fill: parent; margins: -7 }
                        radius: parent.radius + 7
                        color: "transparent"
                        border { width: 3; color: theme.fg }
                    }
                    Text {
                        id: chipText
                        anchors.centerIn: parent
                        text: modelData.label
                        color: modelData.on ? theme.bg : theme.fg
                        font { family: theme.fontFamily; pixelSize: 17; weight: Font.ExtraBold }
                    }
                }
            }
        }
    }
}
