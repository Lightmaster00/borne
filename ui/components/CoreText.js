// Texts from Borne's core (errors, reasons) in the interface's language. The core writes them in
// English; each known one is here, exact or as a pattern ({} stands for a part that varies:
// a name, a number, a reason). Unknown texts are shown as they are.
.pragma library

let table = null

function entries() {
    return [
        // Games and playing
        ["a game is already running", qsTr("a game is already running")],
        ["the Switch keys (prod.keys) cannot read this game: their header_key is wrong or damaged; take prod.keys again from your Switch", qsTr("the Switch keys (prod.keys) cannot read this game: their header_key is wrong or damaged; take prod.keys again from your Switch")],
        ["this game needs newer Switch keys (master key {}; yours stop at {}): take prod.keys and the firmware again from a Switch updated since the game came out", qsTr("this game needs newer Switch keys (master key %1; yours stop at %2): take prod.keys and the firmware again from a Switch updated since the game came out")],
        ["this file holds an update, not the game itself: add the base game to this game on RomM", qsTr("this file holds an update, not the game itself: add the base game to this game on RomM")],
        ["this file holds a DLC, not the game itself: add the base game to this game on RomM", qsTr("this file holds a DLC, not the game itself: add the base game to this game on RomM")],
        ["this file holds no game, not the game itself: add the base game to this game on RomM", qsTr("this file holds no game, not the game itself: add the base game to this game on RomM")],
        ["the game cannot be read: the Switch keys (prod.keys) and firmware are older than the game; take them again from an up-to-date Switch", qsTr("the game cannot be read: the Switch keys (prod.keys) and firmware are older than the game; take them again from an up-to-date Switch")],
        ["the game stopped on a 3DS error: it needs the 3DS system files (in Azahar: File → Set Up System Files, from a 3DS), or the game file is damaged or still encrypted", qsTr("the game stopped on a 3DS error: it needs the 3DS system files (in Azahar: File → Set Up System Files, from a 3DS), or the game file is damaged or still encrypted")],
        ["the Switch firmware is missing: add it in Settings → Consoles → Switch", qsTr("the Switch firmware is missing: add it in Settings → Consoles → Switch")],
        ["this file is an update of the game, not the game: add the base game to this game on RomM", qsTr("this file is an update of the game, not the game: add the base game to this game on RomM")],
        ["this file is a DLC of the game, not the game: add the base game to this game on RomM", qsTr("this file is a DLC of the game, not the game: add the base game to this game on RomM")],
        ["the game is compressed on RomM: it is downloaded to be played", qsTr("the game is compressed on RomM: it is downloaded to be played")],
        ["a game is running: quit it first", qsTr("a game is running: quit it first")],
        ["the downloaded copy is missing: download the game again", qsTr("the downloaded copy is missing: download the game again")],
        ["download the game or play it from the network first", qsTr("download the game or play it from the network first")],
        ["download the game first: its exact version is read from the file", qsTr("download the game first: its exact version is read from the file")],
        ["Borne cannot run {} games yet", qsTr("Borne cannot run %1 games yet")],
        ["no emulator can run {} games yet", qsTr("no emulator can run %1 games yet")],
        ["{} could not start the game: {}", qsTr("%1 could not start the game: %2")],
        ["{} stopped at once: {}", qsTr("%1 stopped at once: %2")],
        ["{} stopped at once ({})", qsTr("%1 stopped at once (%2)")],
        ["{} could not start: {}", qsTr("%1 could not start: %2")],
        ["Azahar could not start: {}", qsTr("Azahar could not start: %1")],
        ["could not prepare the game file: {}", qsTr("could not prepare the game file: %1")],
        ["{} is not available for this computer: choose its program in Settings → Emulators", qsTr("%1 is not available for this computer: choose its program in Settings → Emulators")],
        ["{} cannot be installed by Borne: choose its program", qsTr("%1 cannot be installed by Borne: choose its program")],
        ["download failed: {}", qsTr("download failed: %1")],
        ["download interrupted: {}", qsTr("download interrupted: %1")],
        ["download answered {}", qsTr("download answered %1")],
        ["unreadable archive: {}", qsTr("unreadable archive: %1")],
        ["corrupted file in the archive: {}", qsTr("corrupted file in the archive: %1")],
        ["wrong size for {} ({} instead of {})", qsTr("wrong size for %1 (%2 instead of %3)")],
        ["{} missing from the archive: {}", qsTr("%1 missing from the archive: %2")],
        ["no game file found after install", qsTr("no game file found after install")],
        ["cannot write: {}", qsTr("cannot write: %1")],
        ["{}: no core in the archive", qsTr("%1: no core in the archive")],
        ["no RetroArch version on the buildbot", qsTr("no RetroArch version on the buildbot")],
        ["disk images only open on macOS", qsTr("disk images only open on macOS")],
        ["no application in the disk image", qsTr("no application in the disk image")],
        ["cannot copy the installed version", qsTr("cannot copy the installed version")],
        ["cannot extract the update", qsTr("cannot extract the update")],
        ["cannot install the update ({})", qsTr("cannot install the update (%1)")],
        ["cannot move the current version aside ({})", qsTr("cannot move the current version aside (%1)")],
        ["unreadable update information ({})", qsTr("unreadable update information (%1)")],
        ["update server answered {}", qsTr("update server answered %1")],
        ["update refused: its signature is missing or wrong", qsTr("update refused: its signature is missing or wrong")],
        ["unreadable image ({})", qsTr("unreadable image (%1)")],
        ["short read from RomM ({} of {} bytes)", qsTr("short read from RomM (%1 of %2 bytes)")],
        ["no gameplay video known for this game", qsTr("no gameplay video known for this game")],
        ["no tool to open RAR archives (bsdtar, unrar or 7z) on this system", qsTr("no tool to open RAR archives (bsdtar, unrar or 7z) on this system")],
        ["offline", qsTr("offline")],
        ["{} could not install the game: {}", qsTr("%1 could not install the game: %2")],
        ["the .cia file is not readable", qsTr("the .cia file is not readable")],
        ["this arcade game is not in the version the emulator expects (a ROM is missing or different): use a set made for FinalBurn Neo", qsTr("this arcade game is not in the version the emulator expects (a ROM is missing or different): use a set made for FinalBurn Neo")],
        ["the file holds no playable program: the Switch keys (prod.keys) are older than the game, or the file is an update or a DLC", qsTr("the file holds no playable program: the Switch keys (prod.keys) are older than the game, or the file is an update or a DLC")],
        ["the Switch keys (prod.keys) are missing", qsTr("the Switch keys (prod.keys) are missing")],
        ["the emulator does not take this file (a .cia must be installed first: a .3ds or .cci copy starts directly)", qsTr("the emulator does not take this file (a .cia must be installed first: a .3ds or .cci copy starts directly)")],
        ["the game file is encrypted: the emulator needs a decrypted copy", qsTr("the game file is encrypted: the emulator needs a decrypted copy")],
        ["RomM cannot find {} on its disk: scan the library in RomM", qsTr("RomM cannot find %1 on its disk: scan the library in RomM")],
        ["the game's file on RomM is empty", qsTr("the game's file on RomM is empty")],
        ["the game's file cannot be read from RomM ({})", qsTr("the game's file cannot be read from RomM (%1)")],
        ["RomM does not answer: the game cannot be played from the network now", qsTr("RomM does not answer: the game cannot be played from the network now")],
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
        ["Steam is not installed for this user", qsTr("Steam is not installed for this user")],
        ["close Steam first: it rewrites its shortcuts when it quits", qsTr("close Steam first: it rewrites its shortcuts when it quits")],
        ["Steam's shortcuts file could not be read", qsTr("Steam's shortcuts file could not be read")],
        ["no Steam account on this computer yet: open Steam and sign in once", qsTr("no Steam account on this computer yet: open Steam and sign in once")],
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
        ["this is not a keys file (lines of name = key, or of 32-digit keys, expected)", qsTr("this is not a keys file (lines of name = key, or of 32-digit keys, expected)")],
        ["the .nsz package could not be unpacked: {}", qsTr("the .nsz package could not be unpacked: %1")],
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
        ["no stable version published yet: choose the dev channel", qsTr("no stable version published yet: choose the dev channel")],
        ["update server unreachable ({})", qsTr("update server unreachable (%1)")],
        ["the downloaded file is damaged (SHA-256 mismatch)", qsTr("the downloaded file is damaged (SHA-256 mismatch)")],
        ["this copy was built locally; updates come with the builds published on GitHub", qsTr("this copy was built locally; updates come with the builds published on GitHub")],
        ["macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again", qsTr("macOS runs Borne from a temporary read-only copy: move Borne.app to Applications and open it again")],
        ["installed with Flatpak: update it with Flatpak", qsTr("installed with Flatpak: update it with Flatpak")],
        ["installation folder not recognized", qsTr("installation folder not recognized")],
        ["{} is not writable", qsTr("%1 is not writable")],
        // Saves
        ["sent later: {}", qsTr("sent later: %1")],
        ["save sent to RomM", qsTr("save sent to RomM")],
        // Last: the general form after the particular ones ("update server answered…").
        ["{} answered {}", qsTr("%1 answered %2")]
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
