// Reads a cover's dominant color: the image is drawn at 24 × 24 and the colorful pixels are
// averaged by hue (weighted by saturation), then lifted to a light, readable accent.
// Games without a cover use their stable tone.
import QtQuick

Canvas {
    id: pal
    property string source: ""
    property real fallbackHue: 210
    property color color: Qt.hsla(fallbackHue / 360, 0.65, 0.74, 1)
    width: 24
    height: 24
    visible: false
    renderStrategy: Canvas.Immediate

    function lift(h, s) {
        return Qt.hsla(h, Math.max(0.45, Math.min(0.85, s * 1.2)), 0.74, 1)
    }
    onSourceChanged: {
        if (!source) { color = Qt.hsla(fallbackHue / 360, 0.55, 0.74, 1); return }
        if (isImageLoaded(source)) requestPaint()
        else loadImage(source)
    }
    onImageLoaded: requestPaint()
    onPaint: {
        if (!source || !isImageLoaded(source)) return
        const c = getContext("2d")
        c.clearRect(0, 0, width, height)
        c.drawImage(source, 0, 0, width, height)
        const d = c.getImageData(0, 0, width, height).data
        let x = 0, y = 0, weight = 0, sat = 0
        for (let i = 0; i < d.length; i += 4) {
            const r = d[i] / 255, g = d[i + 1] / 255, b = d[i + 2] / 255
            const max = Math.max(r, g, b), min = Math.min(r, g, b)
            const l = (max + min) / 2
            const s = max === min ? 0 : (l > 0.5 ? (max - min) / (2 - max - min) : (max - min) / (max + min))
            if (s < 0.15 || l < 0.08 || l > 0.95) continue
            let h
            if (max === r) h = ((g - b) / (max - min)) % 6
            else if (max === g) h = (b - r) / (max - min) + 2
            else h = (r - g) / (max - min) + 4
            h = h * Math.PI / 3
            const w = s * (1 - Math.abs(l - 0.5))
            x += Math.cos(h) * w; y += Math.sin(h) * w; weight += w; sat += s * w
        }
        if (weight < 0.5) { color = Qt.hsla(fallbackHue / 360, 0.3, 0.8, 1); return }
        let hue = Math.atan2(y, x) / (2 * Math.PI)
        if (hue < 0) hue += 1
        color = lift(hue, sat / weight)
    }
}
