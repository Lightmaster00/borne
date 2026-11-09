// Borne's mark: a rounded square frame with a dot, in ember.
import QtQuick

Item {
    id: logo
    property QtObject theme
    property int size: 28
    width: size
    height: size
    Rectangle {
        anchors { fill: parent; margins: logo.size * 3 / 28 }
        radius: logo.size * 6 / 28
        color: "transparent"
        border { width: Math.max(2, Math.round(logo.size * 3 / 28)); color: logo.theme.accent }
    }
    Rectangle {
        anchors.centerIn: parent
        width: logo.size * 8 / 28; height: width; radius: width / 2
        color: logo.theme.accent
    }
}
