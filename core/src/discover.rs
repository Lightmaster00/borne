//! Finding the RomM server on the local network at first start, so its address need not be
//! typed: the machines of this computer's own network (its /24), on RomM's usual ports, asked
//! for RomM's heartbeat. Only when the interface asks (the server screen), a few seconds at most.

use serde_json::{json, Value};
use std::net::{IpAddr, Ipv4Addr, SocketAddr, TcpStream, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const PORTS: [u16; 3] = [8080, 80, 8443];

/// This computer's address on its network (the one a packet to the outside would leave from;
/// nothing is sent).
fn local_ipv4() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.0.2.1:80").ok()?;
    match s.local_addr().ok()?.ip() {
        IpAddr::V4(ip) if ip.is_private() => Some(ip),
        _ => None,
    }
}

/// RomM's version when `url` is a RomM server.
fn heartbeat(url: &str) -> Option<String> {
    let agent: ureq::Agent =
        ureq::Agent::config_builder().timeout_global(Some(Duration::from_millis(1500))).http_status_as_error(false).build().into();
    let mut r = agent.get(&format!("{url}/api/heartbeat")).call().ok()?;
    if r.status() != 200 {
        return None;
    }
    let v: Value = r.body_mut().read_json().ok()?;
    let sys = v.get("SYSTEM").or_else(|| v.get("system"))?;
    Some(sys.get("VERSION").or_else(|| sys.get("version")).and_then(|x| x.as_str()).unwrap_or("").to_string())
}

/// The RomM servers found: [{url, version}].
pub fn scan() -> Value {
    // BORNE_DISCOVER_NET=a.b.c: that network instead (tests).
    let forced = std::env::var("BORNE_DISCOVER_NET").ok().and_then(|n| format!("{n}.1").parse::<Ipv4Addr>().ok());
    let Some(me) = forced.or_else(local_ipv4) else { return json!({ "servers": [] }) };
    let [a, b, c, _] = me.octets();
    let targets: Vec<(Ipv4Addr, u16)> = (1..=254u8).flat_map(|d| PORTS.iter().map(move |p| (Ipv4Addr::new(a, b, c, d), *p))).collect();
    let queue = Arc::new(Mutex::new(targets));
    let found = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
    let workers: Vec<_> = (0..64)
        .map(|_| {
            let (queue, found) = (queue.clone(), found.clone());
            std::thread::spawn(move || loop {
                let Some((ip, port)) = queue.lock().unwrap_or_else(|e| e.into_inner()).pop() else { return };
                if TcpStream::connect_timeout(&SocketAddr::new(IpAddr::V4(ip), port), Duration::from_millis(300)).is_err() {
                    continue;
                }
                let scheme = if port == 8443 { "https" } else { "http" };
                let url = if (port == 80 && scheme == "http") || port == 443 {
                    format!("{scheme}://{ip}")
                } else {
                    format!("{scheme}://{ip}:{port}")
                };
                if let Some(v) = heartbeat(&url) {
                    found.lock().unwrap_or_else(|e| e.into_inner()).push((url, v));
                }
            })
        })
        .collect();
    for w in workers {
        let _ = w.join();
    }
    let mut list = found.lock().unwrap_or_else(|e| e.into_inner()).clone();
    list.sort();
    json!({ "servers": list.into_iter().map(|(url, version)| json!({ "url": url, "version": version })).collect::<Vec<_>>() })
}
