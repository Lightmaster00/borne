//! What Borne runs on, as far as the games care: a touch screen, a mouse, pads with motion
//! sensors, a Wii Remote, Bluetooth, the kind of machine (desktop, laptop, handheld, Steam Deck),
//! its processor and memory. Read from the system (Linux: /sys; macOS: sysctl), never asked.
//! Used to warn before a console whose games need what is missing (consoles.rs).

use serde_json::{json, Value};

/// Pads with motion sensors (vendor, product): Switch Pro and Joy-Con, DualShock 4, DualSense,
/// the Steam Deck's controls and the Steam Controller.
const MOTION_PADS: &[(u16, u16)] = &[
    (0x057e, 0x2009),
    (0x057e, 0x2006),
    (0x057e, 0x2007),
    (0x057e, 0x200e),
    (0x054c, 0x05c4),
    (0x054c, 0x09cc),
    (0x054c, 0x0ce6),
    (0x054c, 0x0df2),
    (0x28de, 0x1205),
    (0x28de, 0x1102),
    (0x28de, 0x1142),
];

/// Wii Remotes (and a DolphinBar, which shows them as such).
const WIIMOTES: &[(u16, u16)] = &[(0x057e, 0x0306), (0x057e, 0x0330)];

/// Rhythm game guitars (and drum kits, which play the same games): Guitar Hero and Rock Band for
/// PlayStation 3, Wii and Xbox 360 (their dongles), by maker; their names say the rest.
const GUITARS: &[(u16, u16)] = &[
    (0x12ba, 0x0100),
    (0x12ba, 0x0120),
    (0x12ba, 0x0200),
    (0x12ba, 0x0210),
    (0x1bad, 0x0002),
    (0x1bad, 0x0003),
    (0x1bad, 0x0004),
    (0x1bad, 0x0005),
    (0x1bad, 0x3010),
    (0x1bad, 0x3110),
    (0x1430, 0x4748),
    (0x1430, 0x474b),
    (0x1430, 0x474c),
];
const TURNTABLES: &[(u16, u16)] = &[(0x12ba, 0x0140), (0x1430, 0x4734)];

/// What a device's name says it is: a guitar or drum kit, a DJ turntable.
fn by_name(names: &[String]) -> (bool, bool) {
    let has = |words: &[&str]| {
        names.iter().any(|n| {
            let n = n.to_lowercase();
            words.iter().any(|w| n.contains(w))
        })
    };
    (has(&["guitar", "drum", "rock band", "rockband"]), has(&["turntable", "dj hero"]))
}

#[derive(Default, Debug, Clone)]
pub struct Hardware {
    pub touchscreen: bool,
    pub mouse: bool,
    pub motion_pad: bool,
    pub wiimote: bool,
    /// A rhythm game guitar or drum kit.
    pub guitar: bool,
    /// A DJ Hero turntable.
    pub turntable: bool,
    /// Something to sing into (a sound card's input).
    pub microphone: bool,
    pub bluetooth: bool,
    /// "desktop" | "laptop" | "handheld" | "steamdeck" | "unknown"
    pub machine: String,
    pub threads: usize,
    pub ram_gb: u64,
}

#[cfg(target_os = "linux")]
fn read(p: &str) -> String {
    std::fs::read_to_string(p).unwrap_or_default().trim().to_string()
}

/// A bit of a /sys capabilities line (words of the machine's size, highest first).
#[cfg(target_os = "linux")]
fn has_bit(words: &str, bit: usize) -> bool {
    let words: Vec<u64> = words.split_whitespace().rev().map(|w| u64::from_str_radix(w, 16).unwrap_or(0)).collect();
    words.get(bit / 64).map(|w| w & (1 << (bit % 64)) != 0).unwrap_or(false)
}

#[cfg(target_os = "linux")]
fn input_devices() -> (bool, bool, Vec<(u16, u16)>, Vec<String>) {
    let (mut touch, mut mouse, mut ids, mut names) = (false, false, vec![], vec![]);
    for e in std::fs::read_dir("/sys/class/input").into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !name.starts_with("input") {
            continue;
        }
        let p = e.path().to_string_lossy().into_owned();
        let props = read(&format!("{p}/properties"));
        let abs = read(&format!("{p}/capabilities/abs"));
        let rel = read(&format!("{p}/capabilities/rel"));
        let key = read(&format!("{p}/capabilities/key"));
        // A touch screen: "direct" input (INPUT_PROP_DIRECT) with multi-touch positions (ABS_MT_POSITION_X = 0x35).
        if has_bit(&props, 1) && has_bit(&abs, 0x35) {
            touch = true;
        }
        // A mouse: relative X and Y, and a left button (BTN_LEFT = 0x110).
        if has_bit(&rel, 0) && has_bit(&rel, 1) && has_bit(&key, 0x110) {
            mouse = true;
        }
        let hex = |f: &str| u16::from_str_radix(&read(&format!("{p}/id/{f}")), 16).unwrap_or(0);
        ids.push((hex("vendor"), hex("product")));
        names.push(read(&format!("{p}/name")));
    }
    (touch, mouse, ids, names)
}

/// A sound card that records (ALSA lists its capture devices).
#[cfg(target_os = "linux")]
fn microphone() -> bool {
    read("/proc/asound/pcm").lines().any(|l| l.contains("capture"))
}

#[cfg(target_os = "linux")]
pub fn detect(pads: &[(u16, u16)], pad_names: &[String]) -> Hardware {
    let (touchscreen, mouse, mut ids, mut names) = input_devices();
    ids.extend_from_slice(pads);
    names.extend_from_slice(pad_names);
    let (guitar_named, turntable_named) = by_name(&names);
    let product = read("/sys/class/dmi/id/product_name").to_lowercase();
    let chassis: u32 = read("/sys/class/dmi/id/chassis_type").parse().unwrap_or(0);
    let machine = if product.contains("jupiter") || product.contains("galileo") {
        "steamdeck"
    } else if ["ally", "legion go", "claw", "gpd win", "ayaneo", "onexplayer"].iter().any(|h| product.contains(h)) {
        "handheld"
    } else {
        match chassis {
            3..=7 | 13 | 15 | 16 | 17 | 23 | 24 | 35 | 36 => "desktop",
            8..=10 | 14 | 30 | 31 | 32 => "laptop",
            _ => "unknown",
        }
    };
    let ram_kb: u64 = read("/proc/meminfo")
        .lines()
        .find(|l| l.starts_with("MemTotal:"))
        .and_then(|l| l.split_whitespace().nth(1).and_then(|n| n.parse().ok()))
        .unwrap_or(0);
    Hardware {
        touchscreen,
        mouse,
        motion_pad: ids.iter().any(|i| MOTION_PADS.contains(i)) || machine == "steamdeck",
        wiimote: ids.iter().any(|i| WIIMOTES.contains(i)),
        guitar: guitar_named || ids.iter().any(|i| GUITARS.contains(i)),
        turntable: turntable_named || ids.iter().any(|i| TURNTABLES.contains(i)),
        microphone: microphone(),
        bluetooth: std::fs::read_dir("/sys/class/bluetooth").map(|d| d.count() > 0).unwrap_or(false),
        machine: machine.into(),
        threads: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        ram_gb: (ram_kb + 512 * 1024) / (1024 * 1024),
    }
}

#[cfg(target_os = "macos")]
pub fn detect(pads: &[(u16, u16)], pad_names: &[String]) -> Hardware {
    let (guitar_named, turntable_named) = by_name(pad_names);
    let sysctl = |k: &str| {
        std::process::Command::new("sysctl").arg("-n").arg(k).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
    };
    let model = sysctl("hw.model").unwrap_or_default().to_lowercase();
    let mem: u64 = sysctl("hw.memsize").and_then(|m| m.parse().ok()).unwrap_or(0);
    Hardware {
        touchscreen: false,
        // A Mac has a trackpad or a mouse.
        mouse: true,
        motion_pad: pads.iter().any(|i| MOTION_PADS.contains(i)),
        wiimote: pads.iter().any(|i| WIIMOTES.contains(i)),
        guitar: guitar_named || pads.iter().any(|i| GUITARS.contains(i)),
        turntable: turntable_named || pads.iter().any(|i| TURNTABLES.contains(i)),
        // Every Mac records sound (built in, or the headset's).
        microphone: true,
        bluetooth: true,
        machine: if model.contains("book") { "laptop".into() } else { "desktop".into() },
        threads: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        ram_gb: (mem + (1 << 29)) >> 30,
    }
}

#[cfg(target_os = "windows")]
pub fn detect(pads: &[(u16, u16)], pad_names: &[String]) -> Hardware {
    use windows_sys::Win32::Devices::Bluetooth::{BLUETOOTH_FIND_RADIO_PARAMS, BluetoothFindFirstRadio, BluetoothFindRadioClose};
    use windows_sys::Win32::Media::Audio::waveInGetNumDevs;
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_DIGITIZER, SM_MOUSEPRESENT};

    let (guitar_named, turntable_named) = by_name(pad_names);
    let mut mem: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
    mem.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
    let total_phys = if unsafe { GlobalMemoryStatusEx(&mut mem) } != 0 { mem.ullTotalPhys } else { 0 };
    let touchscreen = unsafe { GetSystemMetrics(SM_DIGITIZER) } & 0xC0 != 0;
    let mouse = unsafe { GetSystemMetrics(SM_MOUSEPRESENT) } != 0;
    let microphone = unsafe { waveInGetNumDevs() } > 0;
    let bluetooth = unsafe {
        let params = BLUETOOTH_FIND_RADIO_PARAMS { dwSize: std::mem::size_of::<BLUETOOTH_FIND_RADIO_PARAMS>() as u32 };
        let mut radio = std::ptr::null_mut();
        let h = BluetoothFindFirstRadio(&params, &mut radio);
        if !h.is_null() {
            if !radio.is_null() {
                windows_sys::Win32::Foundation::CloseHandle(radio);
            }
            BluetoothFindRadioClose(h);
            true
        } else {
            false
        }
    };
    let mut pwr: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    let has_battery = unsafe { GetSystemPowerStatus(&mut pwr) } != 0 && (pwr.BatteryFlag & 128) == 0;
    let machine = if has_battery { "laptop" } else { "desktop" };
    Hardware {
        touchscreen,
        mouse,
        motion_pad: pads.iter().any(|i| MOTION_PADS.contains(i)),
        wiimote: pads.iter().any(|i| WIIMOTES.contains(i)),
        guitar: guitar_named || pads.iter().any(|i| GUITARS.contains(i)),
        turntable: turntable_named || pads.iter().any(|i| TURNTABLES.contains(i)),
        microphone,
        bluetooth,
        machine: machine.into(),
        threads: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        ram_gb: (total_phys + (1 << 29)) >> 30,
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
pub fn detect(pads: &[(u16, u16)], pad_names: &[String]) -> Hardware {
    let (guitar_named, turntable_named) = by_name(pad_names);
    Hardware {
        motion_pad: pads.iter().any(|i| MOTION_PADS.contains(i)),
        wiimote: pads.iter().any(|i| WIIMOTES.contains(i)),
        guitar: guitar_named || pads.iter().any(|i| GUITARS.contains(i)),
        turntable: turntable_named || pads.iter().any(|i| TURNTABLES.contains(i)),
        threads: std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        ..Default::default()
    }
}

pub fn to_json(h: &Hardware) -> Value {
    json!({
        "touchscreen": h.touchscreen, "mouse": h.mouse, "motion_pad": h.motion_pad, "wiimote": h.wiimote,
        "guitar": h.guitar, "turntable": h.turntable, "microphone": h.microphone,
        "bluetooth": h.bluetooth, "machine": h.machine, "threads": h.threads, "ram_gb": h.ram_gb,
    })
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    #[test]
    fn capability_bits() {
        // INPUT_PROP_DIRECT (bit 1); ABS_MT_POSITION_X (0x35) in the first word of 64 bits.
        assert!(super::has_bit("2", 1));
        assert!(super::has_bit("660000000000003", 0x35));
        assert!(!super::has_bit("3", 0x35));
        // Several words: the last one is the lowest.
        assert!(super::has_bit("1 0", 64));
    }
}
