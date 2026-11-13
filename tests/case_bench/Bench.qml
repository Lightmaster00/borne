// Case bench: the real 3D shelf (Shelf3D) with synthetic scans; every case faced, then turned left
// and right; each view saved as a picture (run.sh fills in the games and the output folder).
import QtQuick
import QtQuick.Window
import Borne.Theme
import "components"
import "components/Cases.js" as Cases

Window {
    id: win
    width: 1920; height: 1080; visible: true; color: "#202226"
    property string apiBase; property string wsUrl; property bool safeMode; property int uiRestarts; property string uiRoot; property string qtVersion
    property var games: JSON.parse(Qt.atob(GAMES_B64))
    Theme { id: theme }
    ListModel { id: model }
    Component.onCompleted: { for (const g of games) model.append(g); seq.start() }
    Shelf3D {
        id: shelf
        y: 170; width: parent.width; height: 600
        theme: theme; games: model; swayAmp: 0
    }
    property int i: 0
    property int phase: 0
    readonly property var yaws: [0, 55, -55]
    Timer {
        id: seq
        interval: 1800; repeat: true
        onTriggered: {
            const name = OUT_DIR + "/" + String(win.i + 1).padStart(2, "0") + "_" + ["0", "L", "R"][win.phase] + ".png"
            stop()
            win.contentItem.grabToImage(function (r) {
                r.saveToFile(name)
                win.phase++
                if (win.phase >= win.yaws.length) { win.phase = 0; win.i++ }
                if (win.i >= win.games.length) { Qt.quit(); return }
                shelf.currentIndex = win.i
                shelf.userYaw = win.yaws[win.phase]
                seq.start()
            })
        }
    }
}
