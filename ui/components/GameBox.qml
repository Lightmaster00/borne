// One game box of the shelf: front (the cover in a clean plastic case), both spines and a faint
// reflection on the floor. Every face is a flat item drawn through BoxShelf.faceMatrix.
import QtQuick
import QtQuick.Effects

Item {
    id: box
    property QtObject theme
    property Item stage
    property var game: null
    property var place: ({ x: 0, y: 0, z: 0, ang: 0 })
    property bool current: false
    property bool pointerActive: false
    signal clicked()

    readonly property real bw: stage.boxW
    readonly property real bh: stage.boxH
    readonly property real bd: stage.boxD
    readonly property real frontFacing: stage.facing(place, "front")
    readonly property real leftFacing: stage.facing(place, "left")
    readonly property real rightFacing: stage.facing(place, "right")
    readonly property color tone: theme.tone(game ? game.hue : 0)
    readonly property string dl: game && game.dl_state ? game.dl_state : ""
    readonly property bool busy: dl === "queued" || dl === "downloading" || dl === "verifying" || dl === "extracting"
    readonly property real progress: game && game.dl_total > 0 ? Math.min(1, game.dl_received / game.dl_total) : 0

    // ---------- floor reflection ----------
    Item {
        width: box.bw; height: box.bh
        visible: box.frontFacing > 0.05
        opacity: 0.06 * box.frontFacing
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, "front", true) }
        Rectangle { anchors.fill: parent; radius: 8; color: box.tone }
        Image {
            anchors.fill: parent
            source: box.game && box.game.cover ? box.game.cover : ""
            asynchronous: true
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(270, 405)
        }
        // Fades toward the floor.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.024, 0.027, 0.04, 1.0) }
                GradientStop { position: 0.45; color: Qt.rgba(0.024, 0.027, 0.04, 0.85) }
                GradientStop { position: 0.8; color: Qt.rgba(0.024, 0.027, 0.04, 0.3) }
                GradientStop { position: 1.0; color: Qt.rgba(0.024, 0.027, 0.04, 0.0) }
            }
        }
    }

    // ---------- spines ----------
    component Spine: Item {
        id: sp
        property string side: "left"
        property real facingValue: 0
        width: box.bd; height: box.bh
        visible: facingValue > 0.02
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, sp.side, false) }
        Rectangle { anchors.fill: parent; radius: 3; color: Qt.darker(box.tone, 1.35) }
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top } height: 46; color: Qt.rgba(1, 1, 1, 0.1) }
        Text {
            anchors.centerIn: parent
            width: box.bh - 90
            height: box.bd
            rotation: sp.side === "left" ? -90 : 90
            text: box.game ? box.game.name : ""
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            color: box.theme.fg
            font { family: box.theme.displayFont; pixelSize: 15; weight: Font.Bold }
        }
        // Light: faces turned away get darker.
        Rectangle { anchors.fill: parent; radius: 3; color: "black"; opacity: Math.max(0, 0.55 - sp.facingValue * 0.5) }
    }
    Spine { side: "left"; facingValue: box.leftFacing }
    Spine { side: "right"; facingValue: box.rightFacing }

    // ---------- front ----------
    Item {
        id: front
        width: box.bw; height: box.bh
        visible: box.frontFacing > 0.02
        transform: Matrix4x4 { matrix: box.stage.faceMatrix(box.place, "front", false) }

        // Halo in the game's color, behind the selected box.
        Rectangle { id: haloSource; anchors { fill: parent; margins: -10 } radius: 22; color: box.theme.halo; visible: false }
        MultiEffect {
            anchors.fill: haloSource
            source: haloSource
            visible: box.current
            opacity: box.current ? 1 : 0
            autoPaddingEnabled: true
            blurEnabled: true; blur: 1.0; blurMax: 64
            Behavior on opacity { NumberAnimation { duration: 300 } }
        }

        // The case: thin plastic frame, the cover inset.
        Rectangle { anchors.fill: parent; radius: 10; color: "#15171c" }
        Rectangle {
            id: art
            anchors { fill: parent; margins: 5 }
            radius: 6
            color: box.tone
            layer.enabled: cover.status === Image.Ready
            layer.effect: MultiEffect { maskEnabled: true; maskSource: artMask; maskThresholdMin: 0.5; maskSpreadAtMin: 1.0 }
            Text {
                visible: cover.status !== Image.Ready
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 18 }
                text: box.game ? box.game.name : ""
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
                color: box.theme.fg
                font { family: box.theme.displayFont; pixelSize: 30; weight: Font.ExtraBold }
            }
            Image {
                id: cover
                anchors.fill: parent
                source: box.game && box.game.cover ? box.game.cover : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(400, 600)
            }
        }
        Item {
            id: artMask
            anchors.fill: art
            layer.enabled: true
            visible: false
            Rectangle { anchors.fill: parent; radius: 6; color: "black" }
        }
        // Plastic sheen: a soft diagonal light that slides as the box turns.
        Rectangle {
            anchors { fill: parent; margins: 5 }
            radius: 6
            opacity: 0.16
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: Math.max(0, 0.15 + box.place.ang / 200); color: "transparent" }
                GradientStop { position: Math.min(1, 0.32 + box.place.ang / 200); color: "white" }
                GradientStop { position: Math.min(1, 0.5 + box.place.ang / 200); color: "transparent" }
            }
        }
        Rectangle { anchors.fill: parent; radius: 10; color: "transparent"; border { width: 1; color: Qt.rgba(1, 1, 1, 0.22) } }

        // State: downloading bar, installed / mounted / failed mark.
        Rectangle {
            visible: box.busy
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 16 }
            height: 5; radius: 2.5
            color: Qt.rgba(1, 1, 1, 0.25)
            Rectangle { width: parent.width * box.progress; height: parent.height; radius: 2.5; color: box.theme.fg }
        }
        Rectangle {
            readonly property bool installed: !box.busy && box.game && box.game.local_state === "local"
            readonly property bool mounted: !box.busy && box.game && box.game.linked && !installed
            readonly property bool broken: !box.busy && (box.dl === "failed" || (box.game && box.game.local_state === "missing"))
            visible: installed || mounted || broken
            anchors { right: parent.right; top: parent.top; margins: 14 }
            width: 30; height: 30; radius: 15
            color: broken ? box.theme.bad : Qt.rgba(0.024, 0.027, 0.04, 0.65)
            border { width: broken ? 0 : 1; color: Qt.rgba(1, 1, 1, 0.3) }
            Icon { anchors.centerIn: parent; size: 15; stroke: 3.2; name: parent.installed ? "check" : parent.mounted ? "link" : "alert"; color: parent.broken ? box.theme.bg : box.theme.fg }
        }

        // Light: a box turned away from the camera gets darker.
        Rectangle { anchors.fill: parent; radius: 10; color: "black"; opacity: Math.max(0, 0.6 - box.frontFacing * 0.6) }

        // Selection ring.
        Rectangle {
            anchors { fill: parent; margins: -9 }
            radius: 17
            color: "transparent"
            border { width: 3; color: box.theme.focusRing }
            opacity: box.current ? 1 : mouse.containsMouse ? 0.4 : 0
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: box.pointerActive
            cursorShape: Qt.PointingHandCursor
            onClicked: box.clicked()
        }
    }
}
