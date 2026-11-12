//! WebSocket event channel (gamepads, downloads, sync, pairing).
//!
//!   ws://127.0.0.1:<port>/<token>
//!
//! The core pushes JSON messages `{"type": "...", ...}` to every connected client.

use std::net::TcpListener;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use tungstenite::handshake::server::{Request, Response};
use tungstenite::http::StatusCode;
use tungstenite::Message;

#[derive(Clone, Default)]
pub struct Broadcaster {
    clients: Arc<Mutex<Vec<Sender<String>>>>,
}

impl Broadcaster {
    pub fn send(&self, msg: String) {
        let mut clients = self.clients.lock().unwrap();
        clients.retain(|c| c.send(msg.clone()).is_ok());
    }
}

/// Starts the WebSocket server and returns its port.
pub fn start(token: String, hub: Broadcaster) -> std::io::Result<u16> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    std::thread::Builder::new().name("borne-ws".into()).spawn(move || {
        for stream in listener.incoming().flatten() {
            let token = token.clone();
            let hub = hub.clone();
            std::thread::spawn(move || {
                let expected = format!("/{token}");
                #[allow(clippy::result_large_err)] // tungstenite's handshake callback signature
                let check = |req: &Request, resp: Response| {
                    if req.uri().path() == expected {
                        Ok(resp)
                    } else {
                        let mut r = tungstenite::handshake::server::ErrorResponse::new(None);
                        *r.status_mut() = StatusCode::FORBIDDEN;
                        Err(r)
                    }
                };
                // A client that never finishes the handshake must not hold a thread forever.
                let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(5)));
                let Ok(mut ws) = tungstenite::accept_hdr(stream, check) else {
                    return;
                };
                let _ = ws.get_ref().set_read_timeout(None);
                let (tx, rx) = channel::<String>();
                hub.clients.lock().unwrap().push(tx);
                let _ = ws.send(Message::text(r#"{"type":"hello","api":1}"#));
                // Send only: the client has nothing to tell the core on this channel.
                for msg in rx {
                    if ws.send(Message::text(msg)).is_err() {
                        break;
                    }
                }
            });
        }
    })?;
    Ok(port)
}
