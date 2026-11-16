//! Where a pad's buttons are in SDL's raw numbering, from SDL_GameControllerDB (zlib licence,
//! assets/gamecontrollerdb.LICENSE): the emulators of the yuzu family (Eden, Citron) bind raw
//! joystick buttons, axes and hats, which differ from pad to pad (an Xbox pad over Bluetooth has
//! X on button 3, over USB on button 2).

const DB: &str = include_str!("../assets/gamecontrollerdb.txt");

#[derive(Debug, Clone, PartialEq)]
pub enum Bind {
    Button(u32),
    /// An axis; `positive` when the control is its positive half (or the whole axis).
    Axis {
        index: u32,
        positive: bool,
    },
    /// A hat and its direction mask (1 up, 2 right, 4 down, 8 left).
    Hat {
        index: u32,
        mask: u32,
    },
}

fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "Mac OS X"
    } else {
        "Linux"
    }
}

/// The mapping line of a pad by its SDL GUID (32 hex digits): the exact one, else one of the
/// same vendor and product on this system.
fn line(guid: &str) -> Option<&'static str> {
    let guid = guid.to_lowercase();
    if guid.len() != 32 {
        return None;
    }
    let lines = || DB.lines().filter(|l| l.contains(&format!("platform:{},", platform())));
    lines().find(|l| l.starts_with(&guid)).or_else(|| {
        // vendor at hex 8..12, product at 16..20 (SDL's GUID layout)
        lines().find(|l| l.len() > 32 && l[8..12] == guid[8..12] && l[16..20] == guid[16..20])
    })
}

/// The raw control a pad gives for an SDL game-controller name ("a", "leftshoulder",
/// "lefttrigger", "dpup", "leftx"…).
pub fn bind(guid: &str, control: &str) -> Option<Bind> {
    let l = line(guid)?;
    let v = l.split(',').skip(2).find_map(|kv| kv.split_once(':').filter(|(k, _)| *k == control).map(|(_, v)| v))?;
    let (sign, v) = match v.strip_prefix('+') {
        Some(r) => (Some(true), r),
        None => match v.strip_prefix('-') {
            Some(r) => (Some(false), r),
            None => (None, v),
        },
    };
    let v = v.trim_end_matches('~');
    if let Some(n) = v.strip_prefix('b') {
        return n.parse().ok().map(Bind::Button);
    }
    if let Some(n) = v.strip_prefix('a') {
        return n.parse().ok().map(|index| Bind::Axis { index, positive: sign.unwrap_or(true) });
    }
    if let Some(h) = v.strip_prefix('h') {
        let (i, m) = h.split_once('.')?;
        return Some(Bind::Hat { index: i.parse().ok()?, mask: m.parse().ok()? });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_controls_of_known_pads() {
        if cfg!(target_os = "macos") {
            return;
        }
        // Xbox Series X over Bluetooth: X is button 3, the triggers are axes 5 and 4.
        let g = "050000005e040000130b000022050000";
        assert_eq!(bind(g, "x"), Some(Bind::Button(3)));
        assert_eq!(bind(g, "lefttrigger"), Some(Bind::Axis { index: 5, positive: true }));
        assert_eq!(bind(g, "dpup"), Some(Bind::Hat { index: 0, mask: 1 }));
        // Same vendor and product, another version: still found.
        assert_eq!(bind("050000005e040000130b000099990000", "a"), Some(Bind::Button(0)));
        assert_eq!(bind("0300000000000000ffff000000000000", "a"), None);
    }
}
