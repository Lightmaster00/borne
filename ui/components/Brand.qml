// Borne's name as drawn: the full logo (pictogram and lettering, ui/brand/logo.svg) or the
// lettering alone (ui/brand/wordmark.svg), white, at a given height.
import QtQuick

Image {
    id: brand
    property bool lettering: false   // the lettering alone
    property int size: 40            // height
    readonly property real ratio: lettering ? 918 / 250 : 1310 / 330
    height: size
    width: Math.round(size * ratio)
    source: lettering ? "../brand/wordmark.svg" : "../brand/logo.svg"
    sourceSize: Qt.size(width * 2, height * 2)
    smooth: true
    fillMode: Image.PreserveAspectFit
}
