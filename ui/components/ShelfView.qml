// The shelf of game cases: real 3D (Shelf3D, Qt Quick 3D) when available, else the 2D drawing
// (BoxShelf). Both take the same properties; this item forwards them.
import QtQuick

Item {
    id: sv
    property QtObject theme
    property var games
    property int currentIndex: 0
    property int revision: 0
    property bool showSelection: true
    property real userYaw: 0
    property real userPitch: 0
    property real swayAmp: 4
    property int swayPeriod: 3600
    property bool prefer3d: true
    property bool failed3d: false
    readonly property bool is3d: prefer3d && !failed3d

    Loader {
        id: ld
        anchors.fill: parent
        source: sv.is3d ? "Shelf3D.qml" : "BoxShelf.qml"
        onStatusChanged: {
            if (status === Loader.Error && sv.is3d) {
                console.warn("3D cases unavailable here, using the 2D shelf")
                sv.failed3d = true
            }
        }
    }
    Binding { when: ld.item !== null; target: ld.item; property: "theme"; value: sv.theme }
    Binding { when: ld.item !== null; target: ld.item; property: "games"; value: sv.games }
    Binding { when: ld.item !== null; target: ld.item; property: "currentIndex"; value: sv.currentIndex }
    Binding { when: ld.item !== null; target: ld.item; property: "revision"; value: sv.revision }
    Binding { when: ld.item !== null; target: ld.item; property: "showSelection"; value: sv.showSelection }
    Binding { when: ld.item !== null; target: ld.item; property: "userYaw"; value: sv.userYaw }
    Binding { when: ld.item !== null; target: ld.item; property: "userPitch"; value: sv.userPitch }
    Binding { when: ld.item !== null; target: ld.item; property: "swayAmp"; value: sv.swayAmp }
    Binding { when: ld.item !== null; target: ld.item; property: "swayPeriod"; value: sv.swayPeriod }
}
