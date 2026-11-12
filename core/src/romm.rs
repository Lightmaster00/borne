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
    /// Catalog pages: RomM can take a long time to serialize a page of a large library.
    list: ureq::Agent,
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
        self.files.iter().filter(|f| matches!(f.category.as_deref(), None | Some("game") | Some("dlc") | Some("update"))).collect()
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
    let text = e.to_string();
    let lower = text.to_ascii_lowercase();
    if lower.contains("certificate") || lower.contains("unknownissuer") || lower.contains("invalidcertificate") {
        return RommError::Offline(format!(
            "the server's HTTPS certificate is not trusted by this system; install its certificate authority or use http ({text})"
        ));
    }
    if matches!(e, ureq::Error::Timeout(_)) {
        return RommError::Offline(format!("the server took too long to answer ({text})"));
    }
    RommError::Offline(text)
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

/// HTTPS trust: the system's certificate store, so a RomM server signed by a home CA installed
/// on the machine (or a corporate proxy's) is accepted like in the browser.
pub fn tls() -> ureq::tls::TlsConfig {
    ureq::tls::TlsConfig::builder().root_certs(ureq::tls::RootCerts::PlatformVerifier).build()
}

impl Client {
    pub fn new(base: &str, token: Option<String>) -> Self {
        let api = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(5)))
            .timeout_global(Some(Duration::from_secs(30)))
            .user_agent(concat!("Borne/", env!("CARGO_PKG_VERSION")))
            .tls_config(tls())
            .build()
            .into();
        let list = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_global(Some(Duration::from_secs(180)))
            .user_agent(concat!("Borne/", env!("CARGO_PKG_VERSION")))
            .tls_config(tls())
            .build()
            .into();
        // Long downloads: no global timeout, but bounded connection and first response.
        let dl = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(30)))
            .user_agent(concat!("Borne/", env!("CARGO_PKG_VERSION")))
            .tls_config(tls())
            .build()
            .into();
        Self { base: base.trim_end_matches('/').to_string(), token, api, list, dl }
    }

    fn auth(&self) -> Option<String> {
        self.token.as_ref().map(|t| format!("Bearer {t}"))
    }

    fn get_json(&self, path: &str) -> Result<Value> {
        self.get_json_with(&self.api, path)
    }

    fn get_json_with(&self, agent: &ureq::Agent, path: &str) -> Result<Value> {
        let mut req = agent.get(format!("{}{}", self.base, path));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.call().map_err(map_transport)?;
        let code = resp.status().as_u16();
        let body = resp.body_mut().with_config().limit(200 * 1024 * 1024).read_to_string().map_err(|e| RommError::Parse(e.to_string()))?;
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
        self.device_init_with(identifier, name, SCOPES)
    }

    pub fn device_init_with(&self, identifier: &str, name: &str, scopes: &[&str]) -> Result<DeviceInit> {
        let body = serde_json::json!({
            "client_device_identifier": identifier,
            "name": name,
            "client": "borne",
            "platform": std::env::consts::OS,
            "client_version": env!("CARGO_PKG_VERSION"),
            "requested_scopes": scopes,
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

    /// Approves a pairing code with the account's own name and password (HTTP Basic), as the
    /// user would in RomM's web page. Ok(false): the scopes asked exceed the account's role.
    pub fn device_approve(&self, user_code: &str, username: &str, password: &str, scopes: &[&str], device_name: &str) -> Result<bool> {
        let basic = format!("Basic {}", base64(&format!("{username}:{password}")));
        let body = serde_json::json!({ "user_code": user_code, "approved_scopes": scopes, "device_name": device_name });
        let mut resp = self
            .api
            .post(format!("{}/api/auth/device/approve", self.base))
            .header("Authorization", basic)
            .send_json(&body)
            .map_err(map_transport)?;
        let code = resp.status().as_u16();
        let text = resp.body_mut().read_to_string().unwrap_or_default();
        if (200..300).contains(&code) {
            return Ok(true);
        }
        if code == 401 || code == 403 && !text.contains("exceed") {
            return Err(RommError::Unauthorized);
        }
        if text.contains("exceed") {
            return Ok(false);
        }
        Err(status_error(code, &text))
    }

    /// The server's accounts (needs an administrator's token): id, name, role.
    pub fn users(&self) -> Result<Vec<Value>> {
        let v = self.get_json("/api/users")?;
        Ok(v.as_array().cloned().unwrap_or_default())
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

    /// The firmware (BIOS, keys…) RomM keeps for a platform.
    pub fn firmware(&self, platform_id: i64) -> Result<Vec<Value>> {
        match self.get_json(&format!("/api/firmware?platform_id={platform_id}"))? {
            Value::Array(a) => Ok(a),
            other => Err(RommError::Parse(format!("expected a list of firmware, got {other}"))),
        }
    }

    /// The profile's saves ("saves") or save states ("states") of a game on RomM.
    pub fn assets(&self, kind: &str, rom_id: i64) -> Result<Vec<Value>> {
        match self.get_json(&format!("/api/{kind}?rom_id={rom_id}"))? {
            Value::Array(a) => Ok(a),
            other => Err(RommError::Parse(format!("expected a list of saves, got {other}"))),
        }
    }

    /// Sends a save or a state to RomM (multipart), replacing the one of the same name.
    pub fn upload_asset(&self, kind: &str, rom_id: i64, emulator: &str, file_name: &str, data: &[u8]) -> Result<Value> {
        let field = if kind == "states" { "stateFile" } else { "saveFile" };
        let boundary = format!("borne{:016x}", rand::random::<u64>());
        let safe_name: String = file_name.chars().filter(|c| *c != '"' && *c != '\r' && *c != '\n').collect();
        let mut body = Vec::with_capacity(data.len() + 512);
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{safe_name}\"\r\nContent-Type: application/octet-stream\r\n\r\n").as_bytes());
        body.extend_from_slice(data);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        let url = format!("{}/api/{kind}?rom_id={rom_id}&emulator={}&overwrite=true", self.base, percent_encode(emulator));
        let mut req = self.dl.post(url).header("Content-Type", &format!("multipart/form-data; boundary={boundary}"));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.send(&body[..]).map_err(map_transport)?;
        let code = resp.status().as_u16();
        let text = resp.body_mut().read_to_string().unwrap_or_default();
        if !(200..300).contains(&code) {
            return Err(status_error(code, &text));
        }
        serde_json::from_str(&text).map_err(|e| RommError::Parse(e.to_string()))
    }

    /// One catalog page. Returns (games, total).
    /// Accepts both shapes RomM has used: a page object `{items, total}` and a bare list.
    pub fn roms_page(&self, offset: usize, limit: usize) -> Result<(Vec<Value>, usize)> {
        let v = self.get_json_with(&self.list, &format!("/api/roms?limit={limit}&offset={offset}&order_by=name&order_dir=asc"))?;
        parse_roms_page(v, offset, limit)
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

    /// Downloads a server asset (a trailer…) to `dest`, at most `limit` bytes.
    pub fn fetch_to_file(&self, path: &str, dest: &std::path::Path, limit: u64) -> Result<u64> {
        let url = if path.starts_with("http") { path.to_string() } else { format!("{}{}", self.base, path) };
        let mut req = self.dl.get(encode_url(&url));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.call().map_err(map_transport)?;
        let code = resp.status().as_u16();
        if !(200..300).contains(&code) {
            return Err(status_error(code, ""));
        }
        let mut reader = resp.body_mut().with_config().limit(limit).reader();
        let mut out = std::fs::File::create(dest).map_err(|e| RommError::Parse(e.to_string()))?;
        std::io::copy(&mut reader, &mut out).map_err(|e| RommError::Parse(e.to_string()))
    }

    /// Opens a game file stream starting at byte `from` (resume).
    /// Returns (reader, total file size, resume accepted by the server).
    pub fn open_file(&self, file: &RomFile, from: u64) -> Result<(Box<dyn Read + Send>, u64, bool)> {
        let url = format!("{}/api/roms/{}/files/content/{}", self.base, file.id, percent_encode(&file.file_name));
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

impl Client {
    /// Reads bytes `start..start + len` of a game file (virtual mount). Shorter at the end of the file.
    pub fn fetch_range(&self, file_id: i64, file_name: &str, start: u64, len: u64) -> Result<Vec<u8>> {
        let url = format!("{}/api/roms/{}/files/content/{}", self.base, file_id, percent_encode(file_name));
        let mut req = self.dl.get(url).header("Range", format!("bytes={}-{}", start, start + len.max(1) - 1));
        if let Some(a) = self.auth() {
            req = req.header("Authorization", a);
        }
        let mut resp = req.call().map_err(map_transport)?;
        let code = resp.status().as_u16();
        if code == 416 {
            return Ok(vec![]);
        }
        if !(200..300).contains(&code) {
            return Err(status_error(code, ""));
        }
        let body = resp.body_mut().with_config().limit(len + 1024).read_to_vec();
        let mut data = body.map_err(|e| RommError::Offline(e.to_string()))?;
        if code == 200 {
            // Server ignored the Range header: keep the requested part.
            let s = (start as usize).min(data.len());
            let e = (start as usize + len as usize).min(data.len());
            data = data[s..e].to_vec();
        }
        Ok(data)
    }
}

pub fn parse_roms_page(v: Value, offset: usize, limit: usize) -> Result<(Vec<Value>, usize)> {
    match v {
        Value::Array(items) => {
            // No total given: a full page means there may be more.
            let total = offset + items.len() + usize::from(items.len() >= limit);
            Ok((items, total))
        }
        Value::Object(mut o) => {
            let items = match o.remove("items") {
                Some(Value::Array(a)) => a,
                _ => return Err(RommError::Parse("game list without items".into())),
            };
            let total = o.get("total").and_then(|t| t.as_u64()).map(|t| t as usize).unwrap_or(offset + items.len());
            Ok((items, total))
        }
        other => Err(RommError::Parse(format!("unexpected game list: {}", other.to_string().chars().take(80).collect::<String>()))),
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
    fn roms_page_shapes() {
        let (items, total) = parse_roms_page(serde_json::json!({"items": [{"id": 1}], "total": 9}), 0, 100).unwrap();
        assert_eq!((items.len(), total), (1, 9));
        let (items, total) = parse_roms_page(serde_json::json!([{"id": 1}, {"id": 2}]), 0, 100).unwrap();
        assert_eq!((items.len(), total), (2, 2));
        assert!(parse_roms_page(serde_json::json!({"detail": "x"}), 0, 100).is_err());
    }

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
        assert_eq!(encode_url("http://h/assets/x/big.png?ts=2026-11-08 16:15:31"), "http://h/assets/x/big.png?ts=2026-11-08%2016:15:31");
        assert_eq!(encode_url("http://h/a/é.png"), "http://h/a/%C3%A9.png");
    }

    #[test]
    fn encodes_file_names() {
        assert_eq!(percent_encode("Big Test (World).md"), "Big%20Test%20%28World%29.md");
    }
}

/// Standard base64 (for HTTP Basic credentials).
pub fn base64(s: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let b = s.as_bytes();
    let mut out = String::with_capacity(b.len().div_ceil(3) * 4);
    for c in b.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod base64_tests {
    #[test]
    fn encodes() {
        assert_eq!(super::base64("light:gamehub-dev"), "bGlnaHQ6Z2FtZWh1Yi1kZXY=");
        assert_eq!(super::base64("a"), "YQ==");
        assert_eq!(super::base64("ab"), "YWI=");
    }
}
