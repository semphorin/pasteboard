#![cfg_attr(all(windows, feature = "no-console"), windows_subsystem = "windows")]

mod config;
mod sse;
mod store;

use std::io::{ErrorKind, Read, Seek, SeekFrom};
use std::net::{IpAddr, UdpSocket};
use std::process::ExitCode;
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use tiny_http::{Header, Request, Response, Server, StatusCode};

use config::{Config, Loaded};
use sse::Broadcaster;
use store::{Content, Entry, Limits, Source, Store};

const THREAD_STACK: usize = 128 * 1024;

const INDEX_HTML: &str = include_str!("../static/index.html");
const FONT: &[u8] = include_bytes!("../static/fonts/RobotoMono.woff2");
const CSP: &str = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; \
                   img-src 'self' data:; font-src 'self'; connect-src 'self'; \
                   base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

struct App {
    cfg: Config,
    store: Mutex<Store>,
    bus: Broadcaster,
}

impl App {
    fn store(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Log and announce a new entry plus any entries it evicted.
    fn added(&self, e: &Entry, evicted: &[u64]) {
        let what = match &e.content {
            Content::Text { text } => format!("text {} B", text.len()),
            Content::File { name, size, .. } => format!("file {name:?} {size} B"),
        };
        println!("pasteboard: add #{} {what} from {}", e.id, who(&e.device, &e.ip));
        self.bus.send("add", &serde_json::to_string(e).unwrap_or_default());
        for id in evicted {
            println!("pasteboard: evict #{id} (limits reached)");
            self.deleted(*id);
        }
    }

    fn deleted(&self, id: u64) {
        self.bus.send("delete", &format!("{{\"id\":{id}}}"));
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()));
    let (cfg, conf_path) = match config::load(&args, |k| std::env::var(k).ok(), exe_dir.as_deref())
    {
        Ok(Loaded::Run(c, p)) => (c, p),
        Ok(Loaded::Version) => {
            println!("pasteboard {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Ok(Loaded::Help) => {
            print!("{}", config::USAGE);
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("config error: {e}");
            return ExitCode::FAILURE;
        }
    };

    let limits = Limits {
        max_entries: cfg.max_entries,
        max_text_total: cfg.max_text_total_bytes(),
        max_blob_total: cfg.max_blob_total_bytes(),
    };
    let store = match Store::open(&cfg.data_dir, limits) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("failed to open data dir {}: {e}", cfg.data_dir.display());
            return ExitCode::FAILURE;
        }
    };

    let addr = format!("{}:{}", cfg.bind, cfg.port);
    let Some(server) = listen(&addr) else { return ExitCode::FAILURE };

    match &conf_path {
        Some(p) => println!("pasteboard: config {}", p.display()),
        None => println!("pasteboard: no config file, using defaults"),
    }
    println!("pasteboard: data {}", cfg.data_dir.display());
    println!("pasteboard: listening on {addr}");
    println!("pasteboard: open http://{}:{}", lan_ip(), cfg.port);

    let bus = Broadcaster::new(cfg.max_sse_clients);
    let app = Arc::new(App { cfg, store: Mutex::new(store), bus });
    for req in server.incoming_requests() {
        let app = Arc::clone(&app);
        let spawned = thread::Builder::new()
            .stack_size(THREAD_STACK)
            .spawn(move || handle(&app, req));
        if let Err(e) = spawned {
            eprintln!("pasteboard: failed to spawn handler thread: {e}");
        }
    }
    ExitCode::SUCCESS
}

const BIND_RETRY: Duration = Duration::from_millis(500);
const BIND_ATTEMPTS: u32 = 20;

/// Bind the listener. A port that is still in use (e.g. the previous instance
/// is still exiting after a quick stop/start) is retried for ~10 s.
fn listen(addr: &str) -> Option<Server> {
    for attempt in 1..=BIND_ATTEMPTS {
        match Server::http(addr) {
            Ok(s) => return Some(s),
            Err(e) => {
                let in_use = e
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == ErrorKind::AddrInUse);
                if !in_use || attempt == BIND_ATTEMPTS {
                    eprintln!("failed to listen on {addr}: {e}");
                    return None;
                }
                if attempt == 1 {
                    eprintln!("pasteboard: {addr} is in use, retrying for up to 10s");
                }
                thread::sleep(BIND_RETRY);
            }
        }
    }
    None
}

/// Best-effort LAN address: "connecting" a UDP socket sends no packets but
/// makes the OS pick the outbound interface.
fn lan_ip() -> String {
    UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| s.connect("8.8.8.8:80").map(|_| s))
        .and_then(|s| s.local_addr())
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|_| "localhost".into())
}

fn header(k: &str, v: &str) -> Header {
    Header::from_bytes(k.as_bytes(), v.as_bytes()).expect("valid header")
}

fn text(req: Request, status: u16, body: &str) {
    let resp = Response::from_string(body)
        .with_status_code(status)
        .with_header(header("Content-Type", "text/plain; charset=utf-8"));
    let _ = req.respond(resp);
}

fn json(req: Request, status: u16, body: String) {
    let resp = Response::from_string(body)
        .with_status_code(status)
        .with_header(header("Content-Type", "application/json"))
        .with_header(header("Cache-Control", "no-store"));
    let _ = req.respond(resp);
}

/// Read the request body, rejecting anything over `max` bytes.
fn read_body(req: &mut Request, max: u64) -> Result<Vec<u8>, u16> {
    if req.body_length().is_some_and(|n| n as u64 > max) {
        return Err(413);
    }
    let mut buf = Vec::new();
    req.as_reader()
        .take(max + 1)
        .read_to_end(&mut buf)
        .map_err(|_| 400u16)?;
    if buf.len() as u64 > max {
        return Err(413);
    }
    Ok(buf)
}

fn handle(app: &App, mut req: Request) {
    let method = req.method().as_str().to_ascii_uppercase();
    let path = req.url().split('?').next().unwrap_or("").to_string();
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();

    match (method.as_str(), parts.as_slice()) {
        ("GET", [""]) => {
            let resp = Response::from_string(INDEX_HTML)
                .with_header(header("Content-Type", "text/html; charset=utf-8"))
                .with_header(header("Cache-Control", "no-cache"))
                .with_header(header("X-Content-Type-Options", "nosniff"))
                .with_header(header("Referrer-Policy", "no-referrer"))
                .with_header(header("Content-Security-Policy", CSP));
            let _ = req.respond(resp);
        }
        ("GET", ["font.woff2"]) => {
            let resp = Response::from_data(FONT)
                .with_header(header("Content-Type", "font/woff2"))
                .with_header(header("Cache-Control", "public, max-age=31536000, immutable"));
            let _ = req.respond(resp);
        }
        ("GET", ["api", "limits"]) => {
            let body = format!(
                "{{\"max_file_bytes\":{},\"max_text_bytes\":{},\"max_blob_total_bytes\":{}}}",
                app.cfg.max_file_bytes(),
                app.cfg.max_text_bytes(),
                app.cfg.max_blob_total_bytes()
            );
            json(req, 200, body);
        }
        ("GET", ["api", "entries"]) => {
            let body = serde_json::to_string(&app.store().list()).unwrap_or_else(|_| "[]".into());
            json(req, 200, body);
        }
        ("POST", ["api", "text"]) => {
            let body = match read_body(&mut req, app.cfg.max_text_bytes()) {
                Ok(b) => b,
                Err(413) => return text(req, 413, "text too large\n"),
                Err(s) => return text(req, s, "bad request\n"),
            };
            let Ok(s) = String::from_utf8(body) else {
                return text(req, 400, "text must be UTF-8\n");
            };
            if s.trim().is_empty() {
                return text(req, 400, "empty text\n");
            }
            let res = app.store().add_text(s, &source(&req));
            match res {
                Ok((e, evicted)) => {
                    app.added(&e, &evicted);
                    json(req, 201, serde_json::to_string(&e).unwrap_or_default())
                }
                Err(e) => text(req, 500, &format!("store error: {e}\n")),
            }
        }
        ("DELETE", ["api", "entries", id]) => {
            let Ok(id) = id.parse::<u64>() else { return text(req, 400, "bad id\n") };
            let res = app.store().delete(id);
            match res {
                Ok(true) => {
                    let s = source(&req);
                    println!("pasteboard: delete #{id} by {}", who(&s.device, &s.ip));
                    app.deleted(id);
                    text(req, 200, "deleted\n")
                }
                Ok(false) => text(req, 404, "not found\n"),
                Err(e) => text(req, 500, &format!("store error: {e}\n")),
            }
        }
        ("POST", ["api", "entries", id, "pin"]) => {
            let Ok(id) = id.parse::<u64>() else { return text(req, 400, "bad id\n") };
            let v = match read_body(&mut req, 16).ok().as_deref().map(|b| b.trim_ascii()) {
                Some(b"true") => true,
                Some(b"false") => false,
                _ => return text(req, 400, "body must be true or false\n"),
            };
            let res = app.store().set_pin(id, v);
            match res {
                Ok(Some(e)) => {
                    let s = source(&req);
                    println!("pasteboard: pin #{id}={v} by {}", who(&s.device, &s.ip));
                    app.bus.send("pin", &format!("{{\"id\":{id},\"pinned\":{}}}", e.pinned));
                    json(req, 200, serde_json::to_string(&e).unwrap_or_default())
                }
                Ok(None) => text(req, 404, "not found\n"),
                Err(e) => text(req, 500, &format!("store error: {e}\n")),
            }
        }
        ("POST", ["api", "file"]) => upload(app, req),
        ("GET", ["api", "events"]) => match app.bus.subscribe() {
            Some(sub) => {
                let mut w = req.into_writer();
                let _ = sub.stream(&mut *w);
            }
            None => text(req, 503, "too many live clients\n"),
        },
        ("GET" | "HEAD", ["blob", id]) => {
            let Ok(id) = id.parse::<u64>() else { return text(req, 400, "bad id\n") };
            serve_blob(app, req, id)
        }
        _ => text(req, 404, "not found\n"),
    }
}

fn req_header(req: &Request, name: &str) -> Option<String> {
    req.headers()
        .iter()
        .find(|h| h.field.as_str().as_str().eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str().to_string())
}

/// Stream a raw request body to `data/blobs/<id>` and record it.
fn upload(app: &App, mut req: Request) {
    let max = app.cfg.max_file_bytes();
    let expected = req.body_length().map(|n| n as u64);
    if expected.is_some_and(|n| n > max) {
        return text(req, 413, "file too large\n");
    }
    let name = req_header(&req, "X-Filename")
        .map(|n| sanitize_filename(&percent_decode(&n)))
        .unwrap_or_else(|| "file".into());
    let mime = req_header(&req, "Content-Type")
        .map(|m| sanitize_mime(&m))
        .unwrap_or_else(|| "application/octet-stream".into());

    let (id, path) = {
        let mut s = app.store();
        let id = s.alloc_id();
        (id, s.blob_path(id))
    };
    let written = std::fs::File::create(&path)
        .and_then(|mut f| std::io::copy(&mut req.as_reader().take(max + 1), &mut f));
    let size = match written {
        Ok(n) if n > max => {
            let _ = std::fs::remove_file(&path);
            return text(req, 413, "file too large\n");
        }
        Ok(0) => {
            let _ = std::fs::remove_file(&path);
            return text(req, 400, "empty file\n");
        }
        // The client went away mid-upload (e.g. cancelled): the body reader
        // reports a clean EOF, so compare against the announced length.
        Ok(n) if expected.is_some_and(|len| len != n) => {
            let _ = std::fs::remove_file(&path);
            println!("pasteboard: upload {name:?} incomplete ({n} of {} B), discarded", expected.unwrap_or(0));
            return text(req, 400, "incomplete upload\n");
        }
        Ok(n) => n,
        Err(e) => {
            let _ = std::fs::remove_file(&path);
            return text(req, 500, &format!("write error: {e}\n"));
        }
    };
    let res = app.store().insert(id, Content::File { name, mime, size }, &source(&req));
    match res {
        Ok((e, evicted)) => {
            app.added(&e, &evicted);
            json(req, 201, serde_json::to_string(&e).unwrap_or_default())
        }
        Err(e) => {
            let _ = std::fs::remove_file(&path);
            text(req, 500, &format!("store error: {e}\n"))
        }
    }
}

const INLINE_MIMES: &[&str] = &["image/png", "image/jpeg", "image/gif", "image/webp"];

fn serve_blob(app: &App, req: Request, id: u64) {
    let found = {
        let s = app.store();
        match s.get(id).map(|e| &e.content) {
            Some(Content::File { name, mime, .. }) => Some((name.clone(), mime.clone(), s.blob_path(id))),
            _ => None,
        }
    };
    let Some((name, mime, path)) = found else { return text(req, 404, "not found\n") };
    let Ok(mut file) = std::fs::File::open(&path) else { return text(req, 404, "not found\n") };
    let Ok(size) = file.metadata().map(|m| m.len()) else { return text(req, 404, "not found\n") };

    // Ids are never reused and blobs never change, so id + size is a strong validator.
    let etag = format!("\"{id}-{size}\"");
    if req_header(&req, "If-None-Match").is_some_and(|v| v.split(',').any(|t| t.trim() == etag)) {
        let resp = Response::empty(304).with_header(header("ETag", &etag));
        let _ = req.respond(resp);
        return;
    }
    // A Range is honoured only if If-Range (when sent) still names this blob.
    let range = req_header(&req, "Range")
        .filter(|_| req_header(&req, "If-Range").map_or(true, |v| v.trim() == etag))
        .and_then(|r| parse_range(&r, size));

    let inline = INLINE_MIMES.contains(&mime.as_str());
    let ascii: String = name
        .chars()
        .map(|c| if (c.is_ascii_graphic() && c != '"' && c != '\\') || c == ' ' { c } else { '_' })
        .collect();
    let disposition = format!(
        "{}; filename=\"{ascii}\"; filename*=UTF-8''{}",
        if inline { "inline" } else { "attachment" },
        percent_encode(&name)
    );
    fn with_blob_headers<R: Read>(r: Response<R>, mime: &str, disposition: &str, etag: &str) -> Response<R> {
        r.with_header(header("Content-Type", mime))
            .with_header(header("Content-Disposition", disposition))
            .with_header(header("X-Content-Type-Options", "nosniff"))
            .with_header(header("Content-Security-Policy", "sandbox"))
            .with_header(header("Cache-Control", "private, max-age=86400, immutable"))
            .with_header(header("Accept-Ranges", "bytes"))
            .with_header(header("ETag", etag))
            // Always send Content-Length: tiny_http would otherwise switch to
            // chunked at 32 KiB, which hides the size and prevents resuming.
            .with_chunked_threshold(usize::MAX)
    }
    match range {
        Some(Some((start, end))) => {
            if file.seek(SeekFrom::Start(start)).is_err() {
                return text(req, 500, "seek failed\n");
            }
            let len = end - start + 1;
            let resp = Response::new(StatusCode(206), vec![], file.take(len), Some(len as usize), None);
            let resp = with_blob_headers(resp, &mime, &disposition, &etag)
                .with_header(header("Content-Range", &format!("bytes {start}-{end}/{size}")));
            let _ = req.respond(resp);
        }
        Some(None) => {
            let resp = Response::empty(416)
                .with_header(header("Content-Range", &format!("bytes */{size}")));
            let _ = req.respond(resp);
        }
        None => {
            let resp = Response::new(StatusCode(200), vec![], file, Some(size as usize), None);
            let _ = req.respond(with_blob_headers(resp, &mime, &disposition, &etag));
        }
    }
}

/// Parse a `Range` header against a blob of `size` bytes.
/// `Some(Some((start, end)))` = serve that inclusive range, `Some(None)` = 416,
/// `None` = ignore the header and send the whole file (multiple ranges, other
/// units or malformed values, which RFC 9110 lets a server ignore).
fn parse_range(h: &str, size: u64) -> Option<Option<(u64, u64)>> {
    let spec = h.trim().strip_prefix("bytes=")?.trim();
    if spec.contains(',') {
        return None;
    }
    let (a, b) = spec.split_once('-')?;
    let (a, b) = (a.trim(), b.trim());
    if a.is_empty() {
        // Suffix range: the last `n` bytes.
        let n: u64 = b.parse().ok()?;
        return Some((n > 0 && size > 0).then(|| (size - n.min(size), size - 1)));
    }
    let start: u64 = a.parse().ok()?;
    let end = if b.is_empty() { u64::MAX } else { b.parse().ok()? };
    if end < start {
        return None;
    }
    Some((start < size).then(|| (start, end.min(size - 1))))
}

fn sanitize_filename(n: &str) -> String {
    let base = n.rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = base
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect();
    let clean = clean.trim().trim_start_matches('.').to_string();
    if clean.is_empty() { "file".into() } else { clean }
}

/// Who sent a request: the client's `X-Device` label (percent-encoded by the
/// page) and the remote IP, with IPv4-mapped IPv6 shown as plain IPv4.
fn source(req: &Request) -> Source {
    let device = req_header(req, "X-Device")
        .map(|d| sanitize_device(&percent_decode(&d)))
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "unknown".into());
    let ip = req
        .remote_addr()
        .map(|a| match a.ip() {
            IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
            ip => ip,
        })
        .map(|ip| ip.to_string())
        .unwrap_or_default();
    Source { device, ip }
}

fn sanitize_device(d: &str) -> String {
    let clean: String = d.chars().filter(|c| !c.is_control()).take(40).collect();
    clean.trim().to_string()
}

fn who(device: &str, ip: &str) -> String {
    let device = if device.is_empty() { "unknown" } else { device };
    if ip.is_empty() { format!("{device:?}") } else { format!("{device:?} ({ip})") }
}

fn sanitize_mime(m: &str) -> String {
    let m = m.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    let ok = m.len() <= 100
        && m.split('/').count() == 2
        && m.chars().all(|c| c.is_ascii_alphanumeric() || "/.+-_".contains(c));
    if ok { m } else { "application/octet-stream".into() }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_roundtrip() {
        let n = "héllo wörld (1).png";
        assert_eq!(percent_decode(&percent_encode(n)), n);
        assert_eq!(percent_decode("a%2"), "a%2");
        assert_eq!(percent_decode("%zz"), "%zz");
    }

    #[test]
    fn filenames_and_mimes_are_sanitized() {
        assert_eq!(sanitize_filename("../../etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("C:\\x\\..\\.hidden"), "hidden");
        assert_eq!(sanitize_filename("\u{0}"), "file");
        assert_eq!(sanitize_mime("image/png; charset=x"), "image/png");
        assert_eq!(sanitize_mime("text/html\r\nX: y"), "application/octet-stream");
    }

    #[test]
    fn ranges_are_parsed_against_size() {
        let r = |h| parse_range(h, 100);
        assert_eq!(r("bytes=0-9"), Some(Some((0, 9))));
        assert_eq!(r("bytes=90-"), Some(Some((90, 99))));
        assert_eq!(r("bytes=90-500"), Some(Some((90, 99))));
        assert_eq!(r("bytes=-10"), Some(Some((90, 99))));
        assert_eq!(r("bytes=-500"), Some(Some((0, 99))));
        assert_eq!(r("bytes=100-"), Some(None)); // past the end: 416
        assert_eq!(r("bytes=-0"), Some(None));
        assert_eq!(r("bytes=0-1,5-6"), None); // multiple ranges: whole file
        assert_eq!(r("bytes=9-3"), None);
        assert_eq!(r("items=0-1"), None);
        assert_eq!(r("bytes=abc"), None);
    }

    #[test]
    fn device_labels_are_sanitized() {
        assert_eq!(sanitize_device("  Pixel · Chrome  "), "Pixel · Chrome");
        assert_eq!(sanitize_device("a\u{0}b\r\nc"), "abc");
        assert_eq!(sanitize_device(&"x".repeat(100)).len(), 40);
        assert_eq!(sanitize_device(&percent_decode("Windows%20%C2%B7%20Edge")), "Windows · Edge");
        assert_eq!(who("", ""), "\"unknown\"");
        assert_eq!(who("Mac", "10.0.0.2"), "\"Mac\" (10.0.0.2)");
    }
}
