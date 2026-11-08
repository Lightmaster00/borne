//! Pairing a profile with RomM (RomM's "device" flow, in the style of RFC 8628).
//!
//! 1. Borne asks RomM for a code and shows it on screen (text + QR code).
//! 2. The user approves it from their phone in RomM's web interface.
//! 3. Borne polls RomM until it receives the token, bound to a RomM "device".

use crate::paths::{hostname, machine_id};
use crate::romm::TokenPoll;
use crate::state::{PairingState, Shared};
use crate::{db, secrets};
use std::sync::atomic::Ordering;
use std::time::Duration;

pub fn start(app: &Shared, profile_id: &str) -> Result<PairingState, String> {
    let profile = app.db.profile(profile_id).ok_or("unknown profile")?;
    let client = app.anonymous_client().ok_or("no RomM server configured")?;
    let identifier = format!("borne:{}:{}", machine_id(&app.paths), profile.id);
    let name = format!("Borne – {} ({})", hostname(), profile.name);
    let init = client.device_init(&identifier, &name).map_err(|e| e.to_string())?;

    let state = PairingState {
        profile_id: profile.id.clone(),
        state: "waiting".into(),
        user_code: init.user_code.clone(),
        verification_url: format!("{}{}", client.base, init.verification_path_complete),
        expires_at: db::now() + init.expires_in as i64,
        error: None,
    };
    *app.pairing.lock().unwrap() = Some(state.clone());
    let generation = app.pairing_gen.fetch_add(1, Ordering::SeqCst) + 1;
    app.emit(serde_json::json!({ "type": "pairing", "pairing": state }));
    app.db.log("pairing", &format!("code shown for profile \"{}\"", profile.name));

    let app2 = app.clone();
    std::thread::Builder::new()
        .name("borne-pairing".into())
        .spawn(move || poll(app2, client, init.device_code, init.interval.max(2), generation))
        .map_err(|e| e.to_string())?;
    Ok(state)
}

pub fn cancel(app: &Shared) {
    app.pairing_gen.fetch_add(1, Ordering::SeqCst);
    *app.pairing.lock().unwrap() = None;
    app.emit(serde_json::json!({ "type": "pairing", "pairing": null }));
}

fn finish(app: &Shared, generation: u64, state: &str, error: Option<String>) {
    if app.pairing_gen.load(Ordering::SeqCst) != generation {
        return;
    }
    let mut guard = app.pairing.lock().unwrap();
    if let Some(p) = guard.as_mut() {
        p.state = state.into();
        p.error = error;
        app.emit(serde_json::json!({ "type": "pairing", "pairing": p.clone() }));
    }
}

fn poll(app: Shared, client: crate::romm::Client, device_code: String, interval: u64, generation: u64) {
    let mut wait = interval;
    loop {
        std::thread::sleep(Duration::from_secs(wait));
        if app.pairing_gen.load(Ordering::SeqCst) != generation {
            return; // cancelled or replaced
        }
        let profile_id = match app.pairing.lock().unwrap().as_ref() {
            Some(p) => p.profile_id.clone(),
            None => return,
        };
        match client.device_poll(&device_code) {
            Ok(TokenPoll::Pending) => {}
            Ok(TokenPoll::SlowDown) => wait += 2,
            Ok(TokenPoll::Denied) => return finish(&app, generation, "denied", None),
            Ok(TokenPoll::Expired) => return finish(&app, generation, "expired", None),
            Ok(TokenPoll::Approved { token, device_id }) => {
                let authed = crate::romm::Client::new(&client.base, Some(token.clone()));
                let (user_id, username) = match authed.me() {
                    Ok(me) => me,
                    Err(e) => return finish(&app, generation, "error", Some(e.to_string())),
                };
                if let Err(e) = secrets::store(&app.paths, &profile_id, &token) {
                    return finish(&app, generation, "error", Some(format!("token not saved: {e}")));
                }
                app.db.set_paired(&profile_id, &username, user_id, &device_id);
                app.db.log("pairing", &format!("profile paired with RomM account \"{username}\""));
                // First paired profile: it becomes the active profile and the library fills up.
                if app.active_profile().map(|p| !p.paired).unwrap_or(true) {
                    app.db.set_setting("active_profile", &profile_id);
                }
                app.set_online(true);
                finish(&app, generation, "approved", None);
                app.emit(serde_json::json!({ "type": "profiles", "profiles": app.db.profiles() }));
                crate::catalog::start_sync(&app);
                return;
            }
            Err(crate::romm::RommError::Offline(e)) => {
                // Transient outage: keep polling until the code expires.
                eprintln!("[borne] pairing: {e}");
            }
            Err(e) => return finish(&app, generation, "error", Some(e.to_string())),
        }
        let expired = app.pairing.lock().unwrap().as_ref().map(|p| db::now() > p.expires_at).unwrap_or(true);
        if expired {
            return finish(&app, generation, "expired", None);
        }
    }
}

/// SVG QR code of the approval address (scanned with the phone).
pub fn qr_svg(url: &str) -> Option<String> {
    use qrcode::render::svg;
    let code = qrcode::QrCode::new(url.as_bytes()).ok()?;
    Some(
        code.render::<svg::Color>()
            .min_dimensions(320, 320)
            .quiet_zone(true)
            .dark_color(svg::Color("#000000"))
            .light_color(svg::Color("#ffffff"))
            .build(),
    )
}
