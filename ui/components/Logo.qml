// Borne's mark: the pictogram (ui/brand/picto.svg), a red tile with a pixel B lying down.
import QtQuick

Image {
    id: logo
    property QtObject theme      // kept for the callers; the mark has its own colour
    property int size: 28
    width: size
    height: size
    source: "../brand/picto.svg"
    sourceSize: Qt.size(size * 2, size * 2)
    smooth: true
    fillMode: Image.PreserveAspectFit
}
