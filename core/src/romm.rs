//! RomM API client (tested against RomM 5.4).
//!
//! Authentication: `rmm_…` device token obtained through the pairing flow
//! (/api/auth/device/*), sent as `Authorization: Bearer`.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Read;
use std::time::Duration;

/// Scopes requested at pairing. Write access to "assets" will be used
/// for save sync (stage 2).
pub const SCOPES: &[&str] = &[
    "me.read",
    "roms.read",
    "roms.user.read",
    "roms.user.write",
    "platforms.read",
    "assets.read",
    "assets.write",
    "devices.read",
    "devices.write",
    "firmware.read",
    "collections.read",
];

#[derive(Debug)]
pub enum RommError {
    /// Server unreachable (network, DNS, timeout).
    Offline(String),
    /// Token refused or expired: pairing must be redone.
    Unauthorized,
    /// Unexpected HTTP response.
    Http(u16, String),
    /// Unreadable response.
    Parse(String),
}

impl std::fmt::Display for RommError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RommError::Offline(e) => write!(f, "RomM server unreachable ({e})"),
            RommError::Unauthorized => write!(f, "access denied by RomM: pair again"),
            RommError::Http(c, d) => write!(f, "RomM answered {c}: {d}"),
            RommError::Parse(e) => write!(f, "unreadable RomM response ({e})"),
        }
    }
}

pub type Result<T> = std::result::Result<T, RommError>;

#[derive(Clone)]
pub struct Client {
    pub base: String,
    token: Option<String>,
    api: ureq::Agent,
    dl: ureq::Agent,
}

#[derive(Deserialize, Debug, Clone)]
pub struct DeviceInit {
    pub device_code: String,
    pub user_code: String,
    pub verification_path_complete: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Debug)]
pub enum TokenPoll {
    Pending,
    SlowDown,
    Denied,
    Expired,
    Approved { token: String, device_id: String },
}

#[derive(Deserialize, Debug, Clone, Serialize)]
pub struct RomFile {
    pub id: i64,
    pub file_name: String,
    #[serde(default)]
    pub file_path: String,
    #[serde(default)]
    pub file_size_bytes: i64,
    #[serde(default)]
    pub sha1_hash: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub full_path: String,
    /// For an archive: the files it contains. RomM then computes `sha1_hash` over the content,
    /// not over the archive itself.
    #[serde(default)]
    pub archive_members: Option<Vec<ArchiveMember>>,
}

#[derive(Deserialize, Debug, Clone, Serialize)]
pub struct ArchiveMember {
    pub name: String,
    #[serde(default)]
    pub size: i64,
    #[serde(default)]
    pub sha1_hash: Option<String>,
}

impl RomFile {
    pub fn is_archive(&self) -> bool {
        self.archive_members.as_ref().map(|m| !m.is_empty()).unwrap_or(false)
    }
}

#[derive(Deserialize, Debug, Clone)]
pub struct RomDetail {
    pub fs_name: String,
    #[serde(default)]
    pub fs_path: String,
    #[serde(default)]
    pub files: Vec<RomFile>,
}

impl RomDetail {
    /// Files to install: the game and its related content, not manuals or soundtracks.
    pub fn installable_files(&self) -> Vec<&RomFile> {
        self.files
            .iter()
            .filter(|f| matches!(f.category.as_deref(), None | Some("game") | Some("dlc") | Some("update")))
            .collect()
    }
}

fn status_error(code: u16, body: &str) -> RommError {
    if code == 401 || code == 403 {
        return RommError::Unauthorized;
    }
    let detail = serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get("detail").map(|d| d.as_str().map(String::from).unwrap_or_else(|| d.to_string())))
        .unwrap_or_else(|| body.chars().take(200).collect());
    RommError::Http(code, detail)
}

fn map_transport(e: ureq::Error) -> RommError {
    RommError::Offline(e.to_string())
}

/// Normalizes the address typed by the user: http by default, no trailing /.
pub fn normalize_url(input: &str) -> std::result::Result<String, String> {
    let s = input.trim();
    if s.is_empty() {
        return Err("empty address".into());
    }
    let (scheme, rest) = match s.split_once("://") {
        Some((sc, r)) if sc.eq_ignore_ascii_case("http") || sc.eq_ignore_ascii_case("https") => (sc.to_ascii_lowercase(), r),
        Some(_) => return Err("only http:// and https:// are accepted".into()),
        None => ("http".to_string(), s),
    };
    let rest = rest.trim_end_matches('/');
    let host = rest.split('/').next().unwrap_or("");
    if host.is_empty() || rest.contains(char::is_whitespace) {
        return Err("invalid address".into());
    }
    Ok(format!("{scheme}://{rest}"))
}

impl Client {
    pub fn new(base: &str, token: Option<String>) -> Self {
        let api = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(5)))
            .timeout_global(Some(Duration::from_secs(30)))
            .user_agent(concat!("Borne/", env!("CARGO_PKG_VERSION")))
            .build()
            .into();
        // Long downloads: no global timeout, but bounded connection and first response.
        let dl = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(30)))
            .user_agent(concat!("Borne/", env!("CARGO_PKG_VERSION")))
            .build()
            .into();
        Self { base: base.trim_end_matches('/').to_string(), token, api, dl }
    }

    fn auth(&self) -> Option<String> {
        self.token.as_ref().map(|t| format!("Bearer {t}"))
    }

    fn get_json(&self, path: &str) -> Result<Value> {
        let mut req = self.api.get(format!("{}{}", self.base, path));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.call().map_err(map_transport)?;
        let code = resp.status().as_u16();
        let body = resp
            .body_mut()
            .with_config()
            .limit(200 * 1024 * 1024)
            .read_to_string()
            .map_err(|e| RommError::Parse(e.to_string()))?;
        if !(200..300).contains(&code) {
            return Err(status_error(code, &body));
        }
        serde_json::from_str(&body).map_err(|e| RommError::Parse(e.to_string()))
    }

    fn post_json(&self, path: &str, body: &Value) -> Result<(u16, Value)> {
        let mut req = self.api.post(format!("{}{}", self.base, path));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.send_json(body).map_err(map_transport)?;
        let code = resp.status().as_u16();
        let text = resp.body_mut().read_to_string().unwrap_or_default();
        let v = serde_json::from_str(&text).unwrap_or(Value::Null);
        Ok((code, v))
    }

    /// Checks that a RomM server answers and returns its version.
    pub fn heartbeat(&self) -> Result<String> {
        let v = self.get_json("/api/heartbeat")?;
        v.pointer("/SYSTEM/VERSION")
            .and_then(|x| x.as_str())
            .map(String::from)
            .ok_or_else(|| RommError::Parse("this server does not look like RomM".into()))
    }

    // ---------- pairing ----------
    pub fn device_init(&self, identifier: &str, name: &str) -> Result<DeviceInit> {
        let body = serde_json::json!({
            "client_device_identifier": identifier,
            "name": name,
            "client": "borne",
            "platform": std::env::consts::OS,
            "client_version": env!("CARGO_PKG_VERSION"),
            "requested_scopes": SCOPES,
        });
        let (code, v) = self.post_json("/api/auth/device/init", &body)?;
        if code == 404 {
            return Err(RommError::Http(404, "this RomM version does not support device pairing".into()));
        }
        if !(200..300).contains(&code) {
            return Err(status_error(code, &v.to_string()));
        }
        serde_json::from_value(v).map_err(|e| RommError::Parse(e.to_string()))
    }

    pub fn device_poll(&self, device_code: &str) -> Result<TokenPoll> {
        let (code, v) = self.post_json("/api/auth/device/token", &serde_json::json!({ "device_code": device_code }))?;
        if (200..300).contains(&code) {
            let token = v["access_token"].as_str().unwrap_or_default().to_string();
            let device_id = v["device_id"].as_str().unwrap_or_default().to_string();
            if token.is_empty() {
                return Err(RommError::Parse("missing token".into()));
            }
            return Ok(TokenPoll::Approved { token, device_id });
        }
        Ok(match v["detail"].as_str().unwrap_or("") {
            "authorization_pending" => TokenPoll::Pending,
            "slow_down" => TokenPoll::SlowDown,
            "access_denied" => TokenPoll::Denied,
            "expired_token" => TokenPoll::Expired,
            other if code == 429 => {
                let _ = other;
                TokenPoll::SlowDown
            }
            other => return Err(RommError::Http(code, other.to_string())),
        })
    }

    pub fn me(&self) -> Result<(i64, String)> {
        let v = self.get_json("/api/users/me")?;
        Ok((v["id"].as_i64().unwrap_or(0), v["username"].as_str().unwrap_or("").to_string()))
    }

    // ---------- catalog ----------
    pub fn platforms(&self) -> Result<Vec<Value>> {
        match self.get_json("/api/platforms")? {
            Value::Array(a) => Ok(a),
            other => Err(RommError::Parse(format!("expected a list of platforms, got {}", other))),
        }
    }

    /// One catalog page. Returns (games, total).
    pub fn roms_page(&self, offset: usize, limit: usize) -> Result<(Vec<Value>, usize)> {
        let v = self.get_json(&format!("/api/roms?limit={limit}&offset={offset}&order_by=name&order_dir=asc"))?;
        let total = v["total"].as_u64().unwrap_or(0) as usize;
        let items = v["items"].as_array().cloned().unwrap_or_default();
        Ok((items, total))
    }

    pub fn rom(&self, id: i64) -> Result<RomDetail> {
        let v = self.get_json(&format!("/api/roms/{id}"))?;
        serde_json::from_value(v).map_err(|e| RommError::Parse(e.to_string()))
    }

    /// Downloads a server-relative resource (cover…).
    pub fn fetch_bytes(&self, path: &str, limit: u64) -> Result<Vec<u8>> {
        let url = if path.starts_with("http") { path.to_string() } else { format!("{}{}", self.base, path) };
        let mut req = self.api.get(encode_url(&url));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.call().map_err(map_transport)?;
        let code = resp.status().as_u16();
        if !(200..300).contains(&code) {
            return Err(status_error(code, ""));
        }
        resp.body_mut().with_config().limit(limit).read_to_vec().map_err(|e| RommError::Parse(e.to_string()))
    }

    /// Opens a game file stream starting at byte `from` (resume).
    /// Returns (reader, total file size, resume accepted by the server).
    pub fn open_file(&self, file: &RomFile, from: u64) -> Result<(Box<dyn Read + Send>, u64, bool)> {
        let url = format!(
            "{}/api/roms/{}/files/content/{}",
            self.base,
            file.id,
            percent_encode(&file.file_name)
        );
        let mut req = self.dl.get(url);
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        if from > 0 {
            req = req.header("Range", format!("bytes={from}-"));
        }
        let resp = req.call().map_err(map_transport)?;
        let code = resp.status().as_u16();
        if code == 416 {
            // File already complete locally.
            return Ok((Box::new(std::io::empty()), from, true));
        }
        if !(200..300).contains(&code) {
            return Err(status_error(code, ""));
        }
        let resumed = code == 206;
        let total = if resumed {
            resp.headers()
                .get("content-range")
                .and_then(|h| h.to_str().ok())
                .and_then(|s| s.rsplit('/').next())
                .and_then(|s| s.parse().ok())
                .unwrap_or(file.file_size_bytes as u64)
        } else {
            resp.headers()
                .get("content-length")
                .and_then(|h| h.to_str().ok())
                .and_then(|s| s.parse().ok())
                .unwrap_or(file.file_size_bytes as u64)
        };
        let reader = resp.into_body().into_reader();
        Ok((Box::new(reader), total, resumed))
    }
}

/// Encodes characters not allowed in an already structured URL (RomM returns for instance
/// `…/big.png?ts=2026-11-08 16:15:31`, with a space) without touching the separators.
pub fn encode_url(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~:/?#[]@!$&'()*+,;=%".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_normalization() {
        assert_eq!(normalize_url("192.168.1.10:8080/").unwrap(), "http://192.168.1.10:8080");
        assert_eq!(normalize_url(" https://romm.local ").unwrap(), "https://romm.local");
        assert!(normalize_url("").is_err());
        assert!(normalize_url("http://").is_err());
        assert!(normalize_url("ftp://x").is_err());
        assert_eq!(normalize_url("HTTP://Romm.lan/romm/").unwrap(), "http://Romm.lan/romm");
    }

    #[test]
    fn encodes_romm_asset_urls() {
        assert_eq!(
            encode_url("http://h/assets/x/big.png?ts=2026-11-08 16:15:31"),
            "http://h/assets/x/big.png?ts=2026-11-08%2016:15:31"
        );
        assert_eq!(encode_url("http://h/a/é.png"), "http://h/a/%C3%A9.png");
    }

    #[test]
    fn encodes_file_names() {
        assert_eq!(percent_encode("Big Test (World).md"), "Big%20Test%20%28World%29.md");
    }
}
