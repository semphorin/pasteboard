//! History store: in-memory ring of entries, persisted as an append-only JSONL op log.

use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Content {
    Text { text: String },
    File { name: String, mime: String, size: u64 },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub id: u64,
    pub ts: u64,
    #[serde(default)]
    pub pinned: bool,
    /// Label chosen by the sending client (empty for entries from before M9).
    #[serde(default)]
    pub device: String,
    /// Remote address the server saw for the request.
    #[serde(default)]
    pub ip: String,
    #[serde(flatten)]
    pub content: Content,
}

/// Who sent an entry.
#[derive(Debug, Clone, Default)]
pub struct Source {
    pub device: String,
    pub ip: String,
}

impl Entry {
    fn text_len(&self) -> u64 {
        match &self.content {
            Content::Text { text } => text.len() as u64,
            Content::File { .. } => 0,
        }
    }
    fn blob_len(&self) -> u64 {
        match &self.content {
            Content::File { size, .. } => *size,
            Content::Text { .. } => 0,
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
enum Op {
    /// Written at the head of a compacted log so ids are never reused.
    Seq { next: u64 },
    Add(Entry),
    Del { id: u64 },
    Pin { id: u64, v: bool },
}

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_entries: usize,
    pub max_text_total: u64,
    pub max_blob_total: u64,
}

pub struct Store {
    dir: PathBuf,
    entries: VecDeque<Entry>, // ascending id (oldest first)
    next_id: u64,
    log: File,
    limits: Limits,
    text_bytes: u64,
    blob_bytes: u64,
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

const LOG: &str = "log.jsonl";

impl Store {
    /// Open (or create) the store in `dir`: replay the log, apply limits, compact,
    /// and remove orphaned blob files.
    pub fn open(dir: &Path, limits: Limits) -> io::Result<Store> {
        fs::create_dir_all(dir.join("blobs"))?;
        let log_path = dir.join(LOG);

        let mut entries: VecDeque<Entry> = VecDeque::new();
        let mut next_id = 1u64;
        if let Ok(f) = File::open(&log_path) {
            for (n, line) in BufReader::new(f).lines().enumerate() {
                let line = match line {
                    Ok(l) => l,
                    Err(e) => {
                        eprintln!("pasteboard: warning: log line {}: {e}; skipped", n + 1);
                        continue;
                    }
                };
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<Op>(&line) {
                    Ok(Op::Seq { next }) => next_id = next_id.max(next),
                    Ok(Op::Add(e)) => {
                        next_id = next_id.max(e.id + 1);
                        entries.retain(|x| x.id != e.id);
                        entries.push_back(e);
                    }
                    Ok(Op::Del { id }) => entries.retain(|x| x.id != id),
                    Ok(Op::Pin { id, v }) => {
                        if let Some(e) = entries.iter_mut().find(|x| x.id == id) {
                            e.pinned = v;
                        }
                    }
                    Err(e) => {
                        eprintln!("pasteboard: warning: log line {}: {e}; skipped", n + 1)
                    }
                }
            }
        }
        entries.make_contiguous().sort_by_key(|e| e.id);

        let text_bytes = entries.iter().map(Entry::text_len).sum();
        let blob_bytes = entries.iter().map(Entry::blob_len).sum();
        // Placeholder handle; replaced by compact() below.
        let log = OpenOptions::new().create(true).append(true).open(&log_path)?;
        let mut store = Store {
            dir: dir.to_path_buf(),
            entries,
            next_id,
            log,
            limits,
            text_bytes,
            blob_bytes,
        };
        store.evict_inner(None);
        store.compact()?;
        store.remove_orphan_blobs();
        Ok(store)
    }

    /// Rewrite the log as just the live entries (tmp file + rename).
    fn compact(&mut self) -> io::Result<()> {
        let path = self.dir.join(LOG);
        let tmp = self.dir.join("log.jsonl.tmp");
        {
            let mut w = io::BufWriter::new(File::create(&tmp)?);
            let seq = serde_json::to_string(&Op::Seq { next: self.next_id })?;
            writeln!(w, "{seq}")?;
            for e in &self.entries {
                writeln!(w, "{}", serde_json::to_string(&Op::Add(e.clone()))?)?;
            }
            w.flush()?;
        }
        fs::rename(&tmp, &path)?;
        self.log = OpenOptions::new().append(true).open(&path)?;
        Ok(())
    }

    fn remove_orphan_blobs(&self) {
        let Ok(rd) = fs::read_dir(self.dir.join("blobs")) else { return };
        for f in rd.flatten() {
            let name = f.file_name();
            let id = name.to_str().and_then(|s| s.parse::<u64>().ok());
            let live = id.is_some_and(|id| {
                self.entries
                    .iter()
                    .any(|e| e.id == id && matches!(e.content, Content::File { .. }))
            });
            if !live {
                let _ = fs::remove_file(f.path());
            }
        }
    }

    fn append(&mut self, op: &Op) -> io::Result<()> {
        let line = serde_json::to_string(op)?;
        writeln!(self.log, "{line}")
    }

    pub fn blob_path(&self, id: u64) -> PathBuf {
        self.dir.join("blobs").join(id.to_string())
    }

    /// Entries for display: pinned first, then newest first.
    pub fn list(&self) -> Vec<&Entry> {
        let mut v: Vec<&Entry> = self.entries.iter().rev().collect();
        v.sort_by_key(|e| !e.pinned); // stable: keeps newest-first within groups
        v
    }

    pub fn get(&self, id: u64) -> Option<&Entry> {
        self.entries.iter().find(|e| e.id == id)
    }

    /// Reserve an id (used before streaming a blob to disk).
    pub fn alloc_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Insert a new entry with a pre-allocated id. Returns the entry and evicted ids.
    pub fn insert(&mut self, id: u64, content: Content, src: &Source) -> io::Result<(Entry, Vec<u64>)> {
        let e = Entry {
            id,
            ts: now_ms(),
            pinned: false,
            device: src.device.clone(),
            ip: src.ip.clone(),
            content,
        };
        self.append(&Op::Add(e.clone()))?;
        self.text_bytes += e.text_len();
        self.blob_bytes += e.blob_len();
        self.entries.push_back(e.clone());
        let evicted = self.evict_inner(Some(id));
        for id in &evicted {
            self.append(&Op::Del { id: *id })?;
        }
        Ok((e, evicted))
    }

    pub fn add_text(&mut self, text: String, src: &Source) -> io::Result<(Entry, Vec<u64>)> {
        let id = self.alloc_id();
        self.insert(id, Content::Text { text }, src)
    }

    /// Drop oldest unpinned entries (never `keep`) until all limits hold.
    fn evict_inner(&mut self, keep: Option<u64>) -> Vec<u64> {
        let mut evicted = Vec::new();
        while self.entries.len() > self.limits.max_entries
            || self.text_bytes > self.limits.max_text_total
            || self.blob_bytes > self.limits.max_blob_total
        {
            let Some(pos) = self
                .entries
                .iter()
                .position(|e| !e.pinned && Some(e.id) != keep)
            else {
                break;
            };
            let e = self.entries.remove(pos).expect("valid index");
            self.forget(&e);
            evicted.push(e.id);
        }
        evicted
    }

    fn forget(&mut self, e: &Entry) {
        self.text_bytes -= e.text_len();
        self.blob_bytes -= e.blob_len();
        if matches!(e.content, Content::File { .. }) {
            let _ = fs::remove_file(self.blob_path(e.id));
        }
    }

    pub fn delete(&mut self, id: u64) -> io::Result<bool> {
        let Some(pos) = self.entries.iter().position(|e| e.id == id) else {
            return Ok(false);
        };
        let e = self.entries.remove(pos).expect("valid index");
        self.forget(&e);
        self.append(&Op::Del { id })?;
        Ok(true)
    }

    pub fn set_pin(&mut self, id: u64, v: bool) -> io::Result<Option<Entry>> {
        let Some(e) = self.entries.iter_mut().find(|e| e.id == id) else {
            return Ok(None);
        };
        e.pinned = v;
        let e = e.clone();
        self.append(&Op::Pin { id, v })?;
        Ok(Some(e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tdir(name: &str) -> PathBuf {
        let d = PathBuf::from("target").join("test-store").join(name);
        let _ = fs::remove_dir_all(&d);
        d
    }

    fn src() -> Source {
        Source { device: "test".into(), ip: "127.0.0.1".into() }
    }

    fn limits(n: usize) -> Limits {
        Limits { max_entries: n, max_text_total: 1 << 20, max_blob_total: 1 << 20 }
    }

    fn texts(s: &Store) -> Vec<String> {
        s.list()
            .iter()
            .map(|e| match &e.content {
                Content::Text { text } => text.clone(),
                Content::File { name, .. } => name.clone(),
            })
            .collect()
    }

    #[test]
    fn replay_restores_entries_pins_and_next_id() {
        let d = tdir("replay");
        {
            let mut s = Store::open(&d, limits(10)).unwrap();
            s.add_text("a".into(), &src()).unwrap();
            let (b, _) = s.add_text("b".into(), &src()).unwrap();
            let (c, _) = s.add_text("c".into(), &src()).unwrap();
            s.set_pin(b.id, true).unwrap();
            s.delete(c.id).unwrap(); // highest id deleted: must not be reused
        }
        let mut s = Store::open(&d, limits(10)).unwrap();
        assert_eq!(texts(&s), vec!["b", "a"]); // pinned first
        let (e, _) = s.add_text("d".into(), &src()).unwrap();
        assert_eq!(e.id, 4);
        assert_eq!(texts(&s), vec!["b", "d", "a"]);
    }

    #[test]
    fn compaction_rewrites_log_to_live_entries() {
        let d = tdir("compact");
        {
            let mut s = Store::open(&d, limits(10)).unwrap();
            for i in 0..5 {
                s.add_text(format!("t{i}"), &src()).unwrap();
            }
            for id in 1..=3 {
                s.delete(id).unwrap();
            }
            s.set_pin(5, true).unwrap();
        }
        let before = fs::read_to_string(d.join(LOG)).unwrap().lines().count();
        assert_eq!(before, 10); // seq + 5 adds + 3 dels + 1 pin
        let _s = Store::open(&d, limits(10)).unwrap();
        let log = fs::read_to_string(d.join(LOG)).unwrap();
        assert_eq!(log.lines().count(), 3); // seq + 2 adds
        assert!(log.lines().next().unwrap().contains("\"op\":\"seq\""));
        assert!(!d.join("log.jsonl.tmp").exists());
    }

    #[test]
    fn eviction_drops_oldest_unpinned_only() {
        let d = tdir("evict");
        let mut s = Store::open(&d, limits(3)).unwrap();
        s.add_text("1".into(), &src()).unwrap();
        s.add_text("2".into(), &src()).unwrap();
        s.set_pin(1, true).unwrap();
        s.add_text("3".into(), &src()).unwrap();
        let (_, ev) = s.add_text("4".into(), &src()).unwrap();
        assert_eq!(ev, vec![2]);
        let (_, ev) = s.add_text("5".into(), &src()).unwrap();
        assert_eq!(ev, vec![3]);
        assert_eq!(texts(&s), vec!["1", "5", "4"]);
        drop(s);
        let s = Store::open(&d, limits(3)).unwrap();
        assert_eq!(texts(&s), vec!["1", "5", "4"]);
    }

    #[test]
    fn eviction_by_text_bytes_keeps_newest() {
        let d = tdir("evict-bytes");
        let mut s = Store::open(
            &d,
            Limits { max_entries: 100, max_text_total: 10, max_blob_total: 0 },
        )
        .unwrap();
        s.add_text("aaaaaa".into(), &src()).unwrap();
        let (_, ev) = s.add_text("bbbbbb".into(), &src()).unwrap();
        assert_eq!(ev, vec![1]);
        assert_eq!(texts(&s), vec!["bbbbbb"]);
    }

    #[test]
    fn corrupt_log_lines_are_skipped() {
        let d = tdir("corrupt");
        fs::create_dir_all(&d).unwrap();
        fs::write(
            d.join(LOG),
            "{\"op\":\"add\",\"id\":1,\"ts\":0,\"kind\":\"text\",\"text\":\"ok\"}\nnot json\n{\"op\":\"zzz\"}\n",
        )
        .unwrap();
        let s = Store::open(&d, limits(10)).unwrap();
        assert_eq!(texts(&s), vec!["ok"]);
    }

    #[test]
    fn pre_device_log_lines_still_load_and_new_ones_keep_source() {
        let d = tdir("device");
        fs::create_dir_all(&d).unwrap();
        fs::write(
            d.join(LOG),
            "{\"op\":\"add\",\"id\":1,\"ts\":5,\"pinned\":true,\"kind\":\"text\",\"text\":\"old\"}\n",
        )
        .unwrap();
        {
            let mut s = Store::open(&d, limits(10)).unwrap();
            let old = s.get(1).unwrap();
            assert_eq!((old.device.as_str(), old.ip.as_str(), old.pinned), ("", "", true));
            let src = Source { device: "Pixel · Chrome".into(), ip: "192.168.0.9".into() };
            s.add_text("new".into(), &src).unwrap();
        }
        let s = Store::open(&d, limits(10)).unwrap();
        let e = s.get(2).unwrap();
        assert_eq!((e.device.as_str(), e.ip.as_str()), ("Pixel · Chrome", "192.168.0.9"));
    }

    #[test]
    fn unknown_ids_are_harmless() {
        let d = tdir("unknown");
        let mut s = Store::open(&d, limits(10)).unwrap();
        assert!(!s.delete(42).unwrap());
        assert!(s.set_pin(42, true).unwrap().is_none());
    }
}
