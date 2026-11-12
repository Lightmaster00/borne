// Texts from Borne's core (errors, reasons) in the interface's language. The core writes them in
// English; each known one is here, exact or as a pattern ({} stands for a part that varies:
// a name, a number, a reason). Unknown texts are shown as they are.
.pragma library

let table = null

function entries() {
    return [
        // Games and playing
        ["a game is already running", qsTr("a game is already running")],
        ["a game is running: quit it first", qsTr("a game is running: quit it first")],
        ["the downloaded copy is missing: download the game again", qsTr("the downloaded copy is missing: download the game again")],
        ["download the game or play it from the network first", qsTr("download the game or play it from the network first")],
        ["download the game first: its exact version is read from the file", qsTr("download the game first: its exact version is read from the file")],
        ["Borne cannot run {} games yet", qsTr("Borne cannot run %1 games yet")],
        ["no emulator can run {} games yet", qsTr("no emulator can run %1 games yet")],
        ["unknown emulator for this console", qsTr("unknown emulator for this console")],
        ["unknown emulator", qsTr("unknown emulator")],
        ["the {} core is missing", qsTr("the %1 core is missing")],
        ["{} is missing: add it in Settings → System files", qsTr("%1 is missing: add it in Settings → System files")],
        ["game already installed", qsTr("game already installed")],
        ["game not installed", qsTr("game not installed")],
        ["game not linked", qsTr("game not linked")],
        ["unknown game", qsTr("unknown game")],
        ["unknown game or no profile", qsTr("unknown game or no profile")],
        ["unknown game or no active profile", qsTr("unknown game or no active profile")],
        ["this version belongs to another game", qsTr("this version belongs to another game")],
        ["no game file found", qsTr("no game file found")],
        ["RomM lists no game file for this title", qsTr("RomM lists no game file for this title")],
        ["not enough disk space: {} MB needed, {} MB free", qsTr("not enough disk space: %1 MB needed, %2 MB free")],
        ["corrupted file: {} (SHA-1 mismatch twice)", qsTr("corrupted file: %1 (SHA-1 mismatch twice)")],
        ["download failed (HTTP {})", qsTr("download failed (HTTP %1)")],
        ["download failed ({})", qsTr("download failed (%1)")],
        ["download interrupted ({})", qsTr("download interrupted (%1)")],
        ["transfer interrupted: {}", qsTr("transfer interrupted: %1")],
        ["the virtual mount is only available on Linux", qsTr("the virtual mount is only available on Linux")],
        ["the virtual mount is not available on this system", qsTr("the virtual mount is not available on this system")],
        ["virtual mount unavailable ({}); FUSE (fusermount3) is required", qsTr("network play unavailable (%1); FUSE (fusermount3) is required")],
        ["no trailer in RomM for this game", qsTr("no trailer in RomM for this game")],
        ["no gameplay video on ScreenScraper for this game", qsTr("no gameplay video on ScreenScraper for this game")],
        // Emulators
        ["an installation is already running", qsTr("an installation is already running")],
        ["no installation source for this system", qsTr("no installation source for this system")],
        ["no build for this system in {}'s releases", qsTr("no build for this system in %1's releases")],
        ["no build for this platform", qsTr("no build for this platform")],
        ["the download does not match its published checksum", qsTr("the download does not match its published checksum")],
        ["the archive could not be extracted", qsTr("the archive could not be extracted")],
        ["the archive could not be extracted: {}", qsTr("the archive could not be extracted: %1")],
        ["no program in the download", qsTr("no program in the download")],
        ["no application in the download", qsTr("no application in the download")],
        ["Flatpak is not available on this system", qsTr("Flatpak is not available on this system")],
        ["this path is not a program", qsTr("this path is not a program")],
        ["RPCS3 could not install the PS3 firmware", qsTr("RPCS3 could not install the PS3 firmware")],
        ["RPCS3 could not install the firmware: {}", qsTr("RPCS3 could not install the firmware: %1")],
        // Cheats
        ["install Dolphin first (Settings → Emulators): its own code list is used", qsTr("install Dolphin first (Settings → Emulators): its own code list is used")],
        ["the game ID could not be read from this file", qsTr("the game ID could not be read from this file")],
        ["the game's title id is not in its file name ([0100…])", qsTr("the game's title id is not in its file name ([0100…])")],
        ["the game's CRC could not be read (cheats need an .iso)", qsTr("the game's CRC could not be read (cheats need an .iso)")],
        ["the DS cheat database is not here yet", qsTr("the DS cheat database is not here yet")],
        ["no cheat (patch= line) in this file", qsTr("no cheat (patch= line) in this file")],
        ["not a text file", qsTr("not a text file")],
        ["this file is not a DS game", qsTr("this file is not a DS game")],
        // System files
        ["a file is already being added", qsTr("a file is already being added")],
        ["a file or a link expected", qsTr("a file or a link expected")],
        ["a {} file is expected", qsTr("a %1 file is expected")],
        ["this file cannot be found", qsTr("this file cannot be found")],
        ["this file is too small", qsTr("this file is too small")],
        ["this file is too large for a keys file", qsTr("this file is too large for a keys file")],
        ["this file is {} bytes, {} expected: is it the right file?", qsTr("this file is %1 bytes, %2 expected: is it the right file?")],
        ["this is not a keys file (lines of name = key expected)", qsTr("this is not a keys file (lines of name = key expected)")],
        ["this is not a keys file (text expected)", qsTr("this is not a keys file (text expected)")],
        ["this is not a .zip archive of the firmware", qsTr("this is not a .zip archive of the firmware")],
        ["no .nca file in this archive: it is not a Switch firmware", qsTr("no .nca file in this archive: it is not a Switch firmware")],
        ["this is not a PS3 update file (PS3UPDAT.PUP)", qsTr("this is not a PS3 update file (PS3UPDAT.PUP)")],
        ["the link must start with http:// or https://", qsTr("the link must start with http:// or https://")],
        ["the link answered {}", qsTr("the link answered %1")],
        ["the link cannot be reached: {}", qsTr("the link cannot be reached: %1")],
        ["the file could not be read: {}", qsTr("the file could not be read: %1")],
        ["no file chooser on this system: type the file's path", qsTr("no file chooser on this system: type the file's path")],
        ["no file chosen", qsTr("no file chosen")],
        ["RomM has no such file for this console", qsTr("RomM has no such file for this console")],
        // RomM, profiles
        ["wrong user name or password", qsTr("wrong user name or password")],
        ["user name and password needed", qsTr("user name and password needed")],
        ["this RomM account cannot give Borne the access it needs", qsTr("this RomM account cannot give Borne the access it needs")],
        ["RomM refused the pairing", qsTr("RomM refused the pairing")],
        ["the pairing code expired", qsTr("the pairing code expired")],
        ["RomM did not give the token in time", qsTr("RomM did not give the token in time")],
        ["this RomM version does not support device pairing", qsTr("this RomM version does not support device pairing")],
        ["access denied by RomM: pair again", qsTr("access denied by RomM: pair again")],
        ["no RomM server configured", qsTr("no RomM server configured")],
        ["no paired profile", qsTr("no paired profile")],
        ["no paired profile or server offline", qsTr("no paired profile or server offline")],
        ["RomM server unreachable", qsTr("RomM server unreachable")],
        ["RomM server unreachable ({})", qsTr("RomM server unreachable (%1)")],
        ["RomM unreachable", qsTr("RomM unreachable")],
        ["this server does not look like RomM", qsTr("this server does not look like RomM")],
        ["the server took too long to answer ({})", qsTr("the server took too long to answer (%1)")],
        ["the server's HTTPS certificate is not trusted by this system; install its certificate authority or use http ({})", qsTr("the server's HTTPS certificate is not trusted by this system; install its certificate authority or use http (%1)")],
        ["invalid address", qsTr("invalid address")],
        ["empty address", qsTr("empty address")],
        ["invalid profile name (1 to 40 characters)", qsTr("invalid profile name (1 to 40 characters)")],
        ["unknown profile", qsTr("unknown profile")],
        ["RomM answered {}: {}", qsTr("RomM answered %1: %2")],
        // ScreenScraper
        ["no ScreenScraper account", qsTr("no ScreenScraper account")],
        ["credentials refused: check the account and the developer id", qsTr("credentials refused: check the account and the password")],
        ["ScreenScraper unreachable (network)", qsTr("ScreenScraper unreachable (network)")],
        ["ScreenScraper's API is closed for now", qsTr("ScreenScraper's API is closed for now")],
        ["ScreenScraper is closed to non-members for now (server saturated)", qsTr("ScreenScraper is closed to non-members for now (server saturated)")],
        ["ScreenScraper's daily quota for this account is used up", qsTr("ScreenScraper's daily quota for this account is used up")],
        ["too many unknown games for today on ScreenScraper", qsTr("too many unknown games for today on ScreenScraper")],
        ["this build of Borne has no ScreenScraper developer access", qsTr("this build of Borne has no ScreenScraper developer access")],
        ["this version of the software is refused by ScreenScraper", qsTr("this version of the software is refused by ScreenScraper")],
        ["ScreenScraper answered {}", qsTr("ScreenScraper answered %1")],
        // Updates
        ["an update is already in progress", qsTr("an update is already in progress")],
        ["no update available", qsTr("no update available")],
        ["no update ready to install", qsTr("no update ready to install")],
        ["no version published on this channel yet", qsTr("no version published on this channel yet")],
        ["update server unreachable ({})", qsTr("update server unreachable (%1)")],
        ["the downloaded file is damaged (SHA-256 mismatch)", qsTr("the downloaded file is damaged (SHA-256 mismatch)")],
        ["this copy was built locally; updates come with the builds published on GitHub", qsTr("this copy was built locally; updates come with the builds published on GitHub")],
        ["macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again", qsTr("macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again")],
        ["installed with Flatpak: update it with Flatpak", qsTr("installed with Flatpak: update it with Flatpak")],
        ["installation folder not recognized", qsTr("installation folder not recognized")],
        ["{} is not writable", qsTr("%1 is not writable")],
        // Saves
        ["sent later: {}", qsTr("sent later: %1")],
        ["save sent to RomM", qsTr("save sent to RomM")]
    ]
}

function escape(s) { return s.replace(/[.*+?^$()|[\]\\]/g, "\\$&") }

// tr(text): the text in the interface's language when it is known.
function tr(text) {
    if (typeof text !== "string" || !text.length) return text
    if (!table) {
        table = entries().map(function (e) {
            const parts = e[0].split("{}")
            return { exact: parts.length === 1 ? e[0] : null,
                     re: parts.length > 1 ? new RegExp("^" + parts.map(escape).join("(.+?)") + "$") : null,
                     out: e[1] }
        })
    }
    for (const t of table) {
        if (t.exact !== null && t.exact === text) return t.out
        if (t.re) {
            const m = text.match(t.re)
            if (m) {
                let out = t.out
                for (let i = 1; i < m.length; i++) out = out.replace("%" + i, tr(m[i]))
                return out
            }
        }
    }
    return text
}
