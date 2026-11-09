// Game page: opened from the library before anything is downloaded. Shows the game, lets the
// player choose the version (region / languages) and the language the emulator starts in,
// then download it, play it from the network (Borne virtual mount) or manage the local copy.
//
// Gamepad: up/down between rows (actions, versions, language), left/right inside a row,
// A to activate, B to go back. Mouse: everything is clickable; the back button is top left.
import QtQuick
import Borne.Theme

Item {
    id: page
    property QtObject theme
    property var game: null            // shown version, as a library row (cover, trailer, states…)
    property var versions: []          // every version of the game (raw API rows)
    property string emuLanguage: "auto"
    property var emuLanguages: []
    property string installMode: "download"
    property bool streamAvailable: false
    property string streamError: ""
    property bool pointerActive: false
    property bool trailers: true
    property bool paused: false
    property var options: ({ trailerDelayMs: 1500, trailerVolume: 0, backgroundBlur: false })

    signal action(string id, var payload)

    property int row: 0
    property var col: [0, 0, 0]

    readonly property bool busy: game !== null && ["queued", "downloading", "verifying", "extracting"].indexOf(game.dl_state) >= 0
    readonly property var rows: versions.length > 1 ? ["actions", "versions", "language"] : ["actions", "language"]

    function fmtSize(b) {
        return b >= 1073741824 ? qsTr("%1 GB").arg(Number(b / 1073741824).toLocaleString(Qt.locale(), "f", 1))
             : b >= 1048576 ? qsTr("%1 MB").arg(Math.round(b / 1048576)) : qsTr("%1 KB").arg(Math.max(1, Math.round(b / 1024)))
    }

    // ---------- content ----------
    readonly property var actions: {
        const g = game
        if (!g) return []
        if (busy) return [{ id: "cancel", label: qsTr("Cancel download"), primary: true }]
        if (g.dl_state === "failed") return [{ id: "download", label: qsTr("Retry download"), primary: true }, { id: "cancel", label: qsTr("Give up") }]
        if (g.local_state === "local") return [{ id: "play", label: qsTr("Play"), primary: true }, { id: "delete", label: qsTr("Delete from this device") }]
        if (g.linked) return [{ id: "play", label: qsTr("Play"), primary: true }, { id: "unlink", label: qsTr("Remove from the network mount") }]
        if (g.local_state === "missing") return [{ id: "download", label: qsTr("Download again"), primary: true }, { id: "delete", label: qsTr("Forget the local copy") }]
        const dl = { id: "download", label: qsTr("Download · %1").arg(fmtSize(g.fs_size)) }
        const net = { id: "link", label: qsTr("Play from the network"), disabled: !streamAvailable }
        if (installMode === "stream" && streamAvailable) { net.primary = true; return [net, dl] }
        dl.primary = true
        return [dl, net]
    }
    readonly property var languages: emuLanguages.map(code => ({ id: code, label: languageName(code) }))

    function languageName(code) {
        const names = { en: "English", fr: "Français", de: "Deutsch", es: "Español", it: "Italiano", nl: "Nederlands", pt: "Português", ja: "日本語" }
        if (code === "auto") return qsTr("Automatic")
        return names[code] || code
    }
    function regionName(r) {
        const map = {
            "Europe": qsTr("Europe"), "USA": qsTr("USA"), "Japan": qsTr("Japan"), "World": qsTr("World"),
            "France": qsTr("France"), "Germany": qsTr("Germany"), "Spain": qsTr("Spain"), "Italy": qsTr("Italy"),
            "UK": qsTr("United Kingdom"), "Australia": qsTr("Australia"), "Brazil": qsTr("Brazil"), "Korea": qsTr("Korea"),
            "China": qsTr("China"), "Canada": qsTr("Canada"), "Netherlands": qsTr("Netherlands")
        }
        return map[r] || r
    }
    function langCode(name) {
        const map = { English: "EN", French: "FR", German: "DE", Spanish: "ES", Italian: "IT", Japanese: "JA", Dutch: "NL",
                      Portuguese: "PT", Swedish: "SV", Danish: "DA", Norwegian: "NO", Finnish: "FI", Korean: "KO", Chinese: "ZH", Russian: "RU", Polish: "PL" }
        return map[name] || name.substring(0, 2).toUpperCase()
    }
    function versionTitle(v) {
        const regions = (v.regions || "").split(",").map(x => x.trim()).filter(x => x).map(regionName)
        let t = regions.length ? regions.join(" / ") : qsTr("Version %1").arg(versions.indexOf(v) + 1)
        if (v.revision) t += " · " + qsTr("Rev. %1").arg(v.revision)
        return t
    }
    function versionDetail(v) {
        return (v.langs || []).map(langCode).join(" ")
    }
    function stateText() {
        const g = game
        if (!g) return ""
        const dl = g.dl_state
        if (dl === "queued") return qsTr("Waiting to download")
        if (dl === "downloading") return qsTr("Downloading… %1%").arg(g.dl_total > 0 ? Math.round(100 * g.dl_received / g.dl_total) : 0)
        if (dl === "verifying") return qsTr("Verifying files…")
        if (dl === "extracting") return qsTr("Extracting…")
        if (dl === "failed") return qsTr("Download failed: %1").arg(g.dl_error || "")
        if (g.local_state === "local") return qsTr("Installed on this device")
        if (g.linked) return qsTr("Played from the network: nothing stored on this device")
        if (g.local_state === "missing") return qsTr("Local files not found")
        return qsTr("On RomM · %1").arg(fmtSize(g.fs_size))
    }

    // ---------- input ----------
    function reset() {
        row = 0
        const chosen = Math.max(0, versions.findIndex(v => game && v.rom_id === game.rom_id))
        col = [0, chosen, Math.max(0, emuLanguages.indexOf(emuLanguage))]
    }
    function rowItems(name) { return name === "actions" ? actions : name === "versions" ? versions : languages }
    function setCol(r, c) { const n = col.slice(); n[r] = c; col = n }
    function colOf(name) { return col[name === "actions" ? 0 : name === "versions" ? 1 : 2] }
    function activate(name, i) {
        if (name === "actions") {
            const a = actions[i]
            if (a && !a.disabled) page.action(a.id, null)
        } else if (name === "versions") {
            const v = versions[i]
            if (v) page.action("version", v.rom_id)
        } else {
            const l = emuLanguages[i]
            if (l) page.action("language", l)
        }
    }
    function handle(a) {
        const name = rows[Math.min(row, rows.length - 1)]
        const idx = name === "actions" ? 0 : name === "versions" ? 1 : 2
        const n = rowItems(name).length
        if (a === "up") row = Math.max(0, row - 1)
        else if (a === "down") row = Math.min(rows.length - 1, row + 1)
        else if (a === "left") setCol(idx, Math.max(0, col[idx] - 1))
        else if (a === "right") setCol(idx, Math.min(n - 1, col[idx] + 1))
        else if (a === "a") activate(name, col[idx])
        else if (a === "b") page.action("back", null)
    }
    onActionsChanged: setCol(0, Math.min(col[0], Math.max(0, actions.length - 1)))
    // Keep the focused row on screen when the gamepad moves (the page can be taller than the screen).
    property bool fromMouse: false
    onRowChanged: {
        if (fromMouse) return
        const name = rows[row]
        const target = name === "actions" ? 0 : name === "versions" ? versionsBlock.y - 24 : languageBlock.y - 24
        scrollAnim.to = Math.max(0, Math.min(body.contentHeight - body.height, target))
        scrollAnim.restart()
    }
    NumberAnimation { id: scrollAnim; target: body; property: "contentY"; duration: 200; easing.type: Easing.OutQuart }

    // ---------- background ----------
    TrailerStage {
        anchors.fill: parent
        game: page.game
        theme: page.theme
        delayMs: page.options.trailerDelayMs
        volume: page.options.trailerVolume
        blur: true
        backdropOpacity: 0.55
        video: true
        active: page.trailers
        paused: page.paused
    }
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: Qt.rgba(theme.bg.r, theme.bg.g, theme.bg.b, 0.97) }
            GradientStop { position: 0.55; color: Qt.rgba(theme.bg.r, theme.bg.g, theme.bg.b, theme.heroDim) }
            GradientStop { position: 1; color: Qt.rgba(theme.bg.r, theme.bg.g, theme.bg.b, theme.heroDim * 0.5) }
        }
    }

    // Swallow clicks so the library underneath never receives them.
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: (w) => w.accepted = !body.interactive }

    // ---------- back ----------
    Rectangle {
        id: back
        x: 48; y: 28
        width: backRow.implicitWidth + 28; height: 40
        radius: 20
        color: backMouse.containsMouse ? Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.16) : Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.08)
        Behavior on color { ColorAnimation { duration: 150 } }
        Row {
            id: backRow
            anchors.centerIn: parent
            spacing: 10
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 22; height: 22; radius: 11; color: theme.fg
                Text { anchors.centerIn: parent; text: "B"; color: theme.bg; font { family: theme.fontFamily; pixelSize: 11; weight: Font.Bold } }
            }
            Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Back"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium } }
        }
        MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: page.pointerActive
            cursorShape: Qt.PointingHandCursor
            onClicked: page.action("back", null)
        }
    }

    // ---------- cover ----------
    Item {
        id: coverBox
        anchors { right: parent.right; rightMargin: 72; top: parent.top; topMargin: 96 }
        width: Math.round(Math.min(parent.width * 0.24, (parent.height - 200) * 0.72))
        height: Math.round(width / 0.72)
        Rectangle {
            anchors.fill: parent
            radius: theme.cardRadius
            clip: true
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.hsla(((page.game ? page.game.hue : 200) % 360) / 360, 0.55, 0.42, 1) }
                GradientStop { position: 1; color: Qt.hsla(((page.game ? page.game.hue + 30 : 230) % 360) / 360, 0.6, 0.14, 1) }
            }
            Image {
                anchors.fill: parent
                source: page.game ? page.game.cover : ""
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(coverBox.width * 1.5, coverBox.height * 1.5)
            }
            CardStatus { anchors.fill: parent; game: page.game; theme: page.theme }
        }
    }

    // ---------- details ----------
    Flickable {
        id: body
        anchors { left: parent.left; leftMargin: 72; right: coverBox.left; rightMargin: 56; top: parent.top; topMargin: 96; bottom: parent.bottom; bottomMargin: 32 }
        contentHeight: content.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: page.pointerActive && contentHeight > height

        Column {
            id: content
            width: body.width
            spacing: 0

            Text {
                text: page.game ? [page.game.platform_name, page.game.year > 0 ? page.game.year : ""].filter(x => x).join("  ·  ") : ""
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 15; weight: Font.Medium }
            }
            Item { width: 1; height: 8 }
            Text {
                width: parent.width
                text: page.game ? (theme.uppercaseTitles ? page.game.name.toUpperCase() : page.game.name) : ""
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: theme.fg
                lineHeight: 1.05
                font { family: theme.displayFont; pixelSize: Math.round(theme.titleSize * 1.6); weight: Font.Bold }
            }
            Item { width: 1; height: 10 }
            Text {
                width: parent.width
                visible: text !== ""
                text: page.game ? [page.game.genres, page.game.players ? (/^\d+$/.test(page.game.players) ? qsTr("%n player(s)", "", Number(page.game.players)) : qsTr("%1 players").arg(page.game.players)) : ""].filter(x => x).join("  ·  ") : ""
                elide: Text.ElideRight
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 15 }
            }
            Item { width: 1; height: 22 }

            // State + progress
            Text {
                width: parent.width
                text: page.stateText()
                wrapMode: Text.WordWrap
                color: page.game && page.game.dl_state === "failed" ? theme.bad
                     : page.game && (page.game.local_state === "local" || page.game.linked) ? theme.ok : theme.fg
                font { family: theme.fontFamily; pixelSize: 15; weight: Font.DemiBold }
            }
            Item { width: 1; height: page.busy ? 10 : 0 }
            Rectangle {
                visible: page.busy
                width: Math.min(parent.width, 520); height: 6; radius: 3
                color: Qt.rgba(theme.fg.r, theme.fg.g, theme.fg.b, 0.15)
                Rectangle {
                    height: parent.height; radius: 3; color: theme.accent
                    width: parent.width * (page.game && page.game.dl_total > 0 ? Math.min(1, page.game.dl_received / page.game.dl_total) : 0)
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutQuart } }
                }
            }
            Item { width: 1; height: 18 }

            // Actions
            Row {
                id: actionsRow
                spacing: 14
                Repeater {
                    model: page.actions
                    PageButton {
                        required property var modelData
                        required property int index
                        theme: page.theme
                        text: modelData.label
                        primary: !!modelData.primary
                        disabled: !!modelData.disabled
                        focused: page.rows[page.row] === "actions" && page.col[0] === index
                        pointerActive: page.pointerActive
                        onClicked: { page.fromMouse = true; page.row = 0; page.fromMouse = false; page.setCol(0, index); page.activate("actions", index) }
                    }
                }
            }
            Text {
                visible: !page.streamAvailable && page.streamError !== "" && page.actions.some(a => a.id === "link")
                width: parent.width
                topPadding: 10
                text: qsTr("Playing from the network is unavailable here: %1").arg(page.streamError)
                wrapMode: Text.WordWrap
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 13 }
            }
            Item { width: 1; height: 30 }

            // Versions
            Column {
                id: versionsBlock
                visible: page.versions.length > 1
                width: parent.width
                spacing: 10
                Text { text: qsTr("Version"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold } }
                Flow {
                    width: parent.width
                    spacing: 10
                    Repeater {
                        model: page.versions
                        Chip {
                            required property var modelData
                            required property int index
                            theme: page.theme
                            text: page.versionTitle(modelData)
                            detail: page.versionDetail(modelData)
                            selected: page.game !== null && modelData.rom_id === page.game.rom_id
                            badge: modelData.local_state === "local" || modelData.linked
                            focused: page.rows[page.row] === "versions" && page.col[1] === index
                            pointerActive: page.pointerActive
                            onClicked: { page.fromMouse = true; page.row = page.rows.indexOf("versions"); page.fromMouse = false; page.setCol(1, index); page.activate("versions", index) }
                        }
                    }
                }
                Item { width: 1; height: 20 }
            }

            // Emulator language
            Column {
                id: languageBlock
                width: parent.width
                spacing: 10
                Text { text: qsTr("Game language"); color: theme.fg; font { family: theme.fontFamily; pixelSize: 17; weight: Font.DemiBold } }
                Text {
                    width: parent.width
                    text: qsTr("Used at launch by emulators that let the console language be set (Switch, GameCube, PS2…). Automatic follows Borne's language.")
                    wrapMode: Text.WordWrap
                    color: theme.fgMuted
                    font { family: theme.fontFamily; pixelSize: 13 }
                }
                Flow {
                    width: parent.width
                    spacing: 8
                    Repeater {
                        model: page.languages
                        Chip {
                            required property var modelData
                            required property int index
                            theme: page.theme
                            compact: true
                            text: modelData.label
                            selected: modelData.id === page.emuLanguage
                            focused: page.rows[page.row] === "language" && page.col[2] === index
                            pointerActive: page.pointerActive
                            onClicked: { page.fromMouse = true; page.row = page.rows.indexOf("language"); page.fromMouse = false; page.setCol(2, index); page.activate("language", index) }
                        }
                    }
                }
            }
            Item { width: 1; height: 30 }

            Text {
                width: Math.min(parent.width, 760)
                text: page.game && page.game.summary ? page.game.summary : qsTr("No summary in RomM for this game.")
                wrapMode: Text.WordWrap
                lineHeight: 1.35
                color: theme.fgMuted
                font { family: theme.fontFamily; pixelSize: 15 }
            }
        }
    }
}
