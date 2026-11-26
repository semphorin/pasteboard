//! Server-sent events: fan out add/delete/pin notifications to open pages.
//!
//! tiny_http's chunked encoder buffers 8 KiB before writing, so SSE streams take
//! the raw socket writer (`Request::into_writer`) and flush after every frame.

use std::io::{self, Write};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const QUEUE: usize = 64;
pub const HEARTBEAT: Duration = Duration::from_secs(25);

pub struct Broadcaster {
    subs: Mutex<Vec<SyncSender<Arc<str>>>>,
    live: AtomicUsize,
    max: usize,
}

/// One connected client. Dropping it frees its slot.
pub struct Subscription<'a> {
    rx: Receiver<Arc<str>>,
    bus: &'a Broadcaster,
}

impl Drop for Subscription<'_> {
    fn drop(&mut self) {
        let n = self.bus.live.fetch_sub(1, Ordering::SeqCst) - 1;
        eprintln!("pasteboard: sse client disconnected (clients={n})");
    }
}

impl Broadcaster {
    pub fn new(max: usize) -> Self {
        Broadcaster { subs: Mutex::new(Vec::new()), live: AtomicUsize::new(0), max }
    }

    pub fn live(&self) -> usize {
        self.live.load(Ordering::SeqCst)
    }

    /// Register a client, or `None` when `max` clients are already connected.
    pub fn subscribe(&self) -> Option<Subscription<'_>> {
        let mut n = self.live.load(Ordering::SeqCst);
        loop {
            if n >= self.max {
                return None;
            }
            match self.live.compare_exchange(n, n + 1, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => break,
                Err(cur) => n = cur,
            }
        }
        let (tx, rx) = sync_channel(QUEUE);
        self.subs.lock().unwrap_or_else(|e| e.into_inner()).push(tx);
        eprintln!("pasteboard: sse client connected (clients={})", self.live());
        Some(Subscription { rx, bus: self })
    }

    /// Send one event to every client; drop clients that are gone or too slow
    /// (a dropped slow client sees its stream end and reconnects with a refetch).
    pub fn send(&self, event: &str, data: &str) {
        let frame: Arc<str> = format!("event: {event}\ndata: {data}\n\n").into();
        let mut subs = self.subs.lock().unwrap_or_else(|e| e.into_inner());
        subs.retain(|tx| match tx.try_send(Arc::clone(&frame)) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => false,
        });
    }

    #[cfg(test)]
    fn senders(&self) -> usize {
        self.subs.lock().unwrap().len()
    }
}

impl Subscription<'_> {
    /// Next frame to write: an event, a heartbeat comment, or `None` once the
    /// broadcaster has dropped this client.
    fn next_frame(&self, timeout: Duration) -> Option<Arc<str>> {
        match self.rx.recv_timeout(timeout) {
            Ok(f) => Some(f),
            Err(RecvTimeoutError::Timeout) => Some(Arc::from(": ping\n\n")),
            Err(RecvTimeoutError::Disconnected) => None,
        }
    }

    /// Write the response head, then stream frames until the client goes away.
    pub fn stream(self, w: &mut dyn Write) -> io::Result<()> {
        w.write_all(
            b"HTTP/1.1 200 OK\r\n\
              Content-Type: text/event-stream; charset=utf-8\r\n\
              Cache-Control: no-store\r\n\
              X-Accel-Buffering: no\r\n\
              Connection: close\r\n\r\n\
              retry: 3000\n: connected\n\n",
        )?;
        w.flush()?;
        while let Some(frame) = self.next_frame(HEARTBEAT) {
            w.write_all(frame.as_bytes())?;
            w.flush()?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHORT: Duration = Duration::from_millis(10);

    #[test]
    fn delivers_events_and_heartbeats() {
        let bus = Broadcaster::new(4);
        let sub = bus.subscribe().unwrap();
        bus.send("add", "{\"id\":1}");
        assert_eq!(&*sub.next_frame(SHORT).unwrap(), "event: add\ndata: {\"id\":1}\n\n");
        assert_eq!(&*sub.next_frame(SHORT).unwrap(), ": ping\n\n");
    }

    #[test]
    fn caps_clients_and_prunes_dropped_ones() {
        let bus = Broadcaster::new(2);
        let a = bus.subscribe().unwrap();
        let b = bus.subscribe().unwrap();
        assert!(bus.subscribe().is_none());
        assert_eq!(bus.live(), 2);
        drop(b);
        assert_eq!(bus.live(), 1);
        bus.send("delete", "{\"id\":1}"); // prunes b's sender
        assert_eq!(bus.senders(), 1);
        let _c = bus.subscribe().unwrap();
        assert_eq!(bus.live(), 2);
        drop(a);
    }

    #[test]
    fn slow_client_is_dropped_and_its_stream_ends() {
        let bus = Broadcaster::new(2);
        let sub = bus.subscribe().unwrap();
        for _ in 0..=QUEUE {
            bus.send("add", "{}");
        }
        assert_eq!(bus.senders(), 0);
        for _ in 0..QUEUE {
            assert!(sub.next_frame(SHORT).unwrap().starts_with("event: add"));
        }
        assert!(sub.next_frame(SHORT).is_none());
    }
}
