//! Configuration: CLI flags > PASTEBOARD_* env vars > conf file > defaults.

use std::path::{Path, PathBuf};

pub const CONF_NAME: &str = "pasteboard.conf";

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub bind: String,
    pub port: u16,
    pub data_dir: PathBuf,
    pub max_entries: usize,
    pub max_text_kb: u64,
    pub max_text_total_mb: u64,
    pub max_file_mb: u64,
    pub max_blob_total_mb: u64,
    pub max_sse_clients: usize,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            bind: "0.0.0.0".into(),
            port: 9911,
            data_dir: PathBuf::from("data"),
            max_entries: 200,
            max_text_kb: 256,
            max_text_total_mb: 8,
            max_file_mb: 10,
            max_blob_total_mb: 200,
            max_sse_clients: 32,
        }
    }
}

pub const KEYS: &[&str] = &[
    "bind",
    "port",
    "data_dir",
    "max_entries",
    "max_text_kb",
    "max_text_total_mb",
    "max_file_mb",
    "max_blob_total_mb",
    "max_sse_clients",
];

fn num<T: std::str::FromStr>(key: &str, v: &str) -> Result<T, String> {
    v.parse().map_err(|_| format!("invalid value for {key}: {v:?}"))
}

impl Config {
    pub fn max_text_bytes(&self) -> u64 {
        self.max_text_kb * 1024
    }
    pub fn max_text_total_bytes(&self) -> u64 {
        self.max_text_total_mb * 1024 * 1024
    }
    pub fn max_file_bytes(&self) -> u64 {
        self.max_file_mb * 1024 * 1024
    }
    pub fn max_blob_total_bytes(&self) -> u64 {
        self.max_blob_total_mb * 1024 * 1024
    }

    /// Set one key. Keys accept `-` or `_` and any case.
    pub fn set(&mut self, key: &str, v: &str) -> Result<(), String> {
        let key = key.trim().to_ascii_lowercase().replace('-', "_");
        let v = v.trim();
        match key.as_str() {
            "bind" => self.bind = v.to_string(),
            "port" => self.port = num(&key, v)?,
            "data_dir" => self.data_dir = PathBuf::from(v),
            "max_entries" => self.max_entries = num(&key, v)?,
            "max_text_kb" => self.max_text_kb = num(&key, v)?,
            "max_text_total_mb" => self.max_text_total_mb = num(&key, v)?,
            "max_file_mb" => self.max_file_mb = num(&key, v)?,
            "max_blob_total_mb" => self.max_blob_total_mb = num(&key, v)?,
            "max_sse_clients" => self.max_sse_clients = num(&key, v)?,
            _ => return Err(format!("unknown config key: {key}")),
        }
        Ok(())
    }

    /// Apply `key = value` lines. `#` starts a comment; blank lines are ignored.
    pub fn apply_conf(&mut self, text: &str) -> Result<(), String> {
        // Windows editors / PowerShell 5.1 often write a UTF-8 BOM.
        let text = text.strip_prefix('\u{feff}').unwrap_or(text);
        for (n, raw) in text.lines().enumerate() {
            let line = raw.split('#').next().unwrap_or("").trim();
            if line.is_empty() {
                continue;
            }
            let (k, v) = line
                .split_once('=')
                .ok_or_else(|| format!("line {}: expected key = value", n + 1))?;
            self.set(k, v).map_err(|e| format!("line {}: {e}", n + 1))?;
        }
        Ok(())
    }
}

pub enum Loaded {
    Run(Config, Option<PathBuf>),
    Help,
    Version,
}

pub const USAGE: &str = "pasteboard - LAN clipboard server

USAGE: pasteboard [--config FILE] [--KEY VALUE ...]
       pasteboard --version

Keys (also settable in pasteboard.conf or as PASTEBOARD_<KEY> env vars):
  --bind ADDR               default 0.0.0.0
  --port N                  default 9911
  --data-dir DIR            default ./data (relative to the conf file's folder)
  --max-entries N           default 200
  --max-text-kb N           default 256
  --max-text-total-mb N     default 8
  --max-file-mb N           default 10
  --max-blob-total-mb N     default 200
  --max-sse-clients N       default 32
";

/// Build the config from args (without argv[0]), an env lookup, and the filesystem.
pub fn load(
    args: &[String],
    env: impl Fn(&str) -> Option<String>,
    exe_dir: Option<&Path>,
) -> Result<Loaded, String> {
    // Collect CLI pairs first so --config can be found.
    let mut cli: Vec<(String, String)> = Vec::new();
    let mut conf_path: Option<PathBuf> = None;
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "-h" || a == "--help" {
            return Ok(Loaded::Help);
        }
        if a == "-V" || a == "--version" {
            return Ok(Loaded::Version);
        }
        let flag = a
            .strip_prefix("--")
            .ok_or_else(|| format!("unexpected argument: {a}"))?;
        let (k, v) = match flag.split_once('=') {
            Some((k, v)) => (k.to_string(), v.to_string()),
            None => {
                let v = it.next().ok_or_else(|| format!("missing value for --{flag}"))?;
                (flag.to_string(), v.clone())
            }
        };
        if k == "config" {
            conf_path = Some(PathBuf::from(v));
        } else {
            cli.push((k, v));
        }
    }

    // Conf file: --config, PASTEBOARD_CONFIG, ./pasteboard.conf, <exe dir>/pasteboard.conf.
    if conf_path.is_none() {
        conf_path = env("PASTEBOARD_CONFIG").map(PathBuf::from);
    }
    let explicit = conf_path.is_some();
    if conf_path.is_none() {
        let candidates = std::iter::once(PathBuf::from(CONF_NAME))
            .chain(exe_dir.map(|d| d.join(CONF_NAME)));
        conf_path = candidates.into_iter().find(|p| p.is_file());
    }

    let mut cfg = Config::default();
    if let Some(p) = &conf_path {
        match std::fs::read_to_string(p) {
            Ok(text) => cfg
                .apply_conf(&text)
                .map_err(|e| format!("{}: {e}", p.display()))?,
            Err(e) if explicit => return Err(format!("{}: {e}", p.display())),
            Err(_) => conf_path = None,
        }
    }

    for key in KEYS {
        if let Some(v) = env(&format!("PASTEBOARD_{}", key.to_ascii_uppercase())) {
            cfg.set(key, &v).map_err(|e| format!("env: {e}"))?;
        }
    }
    for (k, v) in &cli {
        cfg.set(k, v)?;
    }

    // Relative data_dir is anchored to the conf file's folder so installed copies
    // work regardless of the working directory.
    if cfg.data_dir.is_relative() {
        if let Some(dir) = conf_path.as_ref().and_then(|p| p.parent()) {
            if !dir.as_os_str().is_empty() {
                cfg.data_dir = dir.join(&cfg.data_dir);
            }
        }
    }
    Ok(Loaded::Run(cfg, conf_path))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> Vec<String> {
        s.iter().map(|x| x.to_string()).collect()
    }

    fn run(l: Loaded) -> Config {
        match l {
            Loaded::Run(c, _) => c,
            Loaded::Help | Loaded::Version => panic!("unexpected help/version"),
        }
    }

    #[test]
    fn parses_conf_with_comments_and_spaces() {
        let mut c = Config::default();
        c.apply_conf("# top\n\n port = 1234 # trailing\nmax-entries=5\nBIND = 127.0.0.1\n")
            .unwrap();
        assert_eq!(c.port, 1234);
        assert_eq!(c.max_entries, 5);
        assert_eq!(c.bind, "127.0.0.1");
    }

    #[test]
    fn accepts_utf8_bom_and_crlf() {
        let mut c = Config::default();
        c.apply_conf("\u{feff}# comment\r\nport = 1234\r\n").unwrap();
        assert_eq!(c.port, 1234);
    }

    #[test]
    fn rejects_bad_lines() {
        let mut c = Config::default();
        assert!(c.apply_conf("port 1234").is_err());
        assert!(c.apply_conf("port = abc").is_err());
        assert!(c.apply_conf("nope = 1").is_err());
    }

    #[test]
    fn defaults_without_anything() {
        let dir = std::env::temp_dir().join("pb-none-does-not-exist");
        let c = run(load(&[], |_| None, Some(&dir)).unwrap());
        assert_eq!(c.port, 9911);
    }

    #[test]
    fn precedence_cli_over_env_over_conf() {
        let dir = PathBuf::from("target").join("test-config-prec");
        std::fs::create_dir_all(&dir).unwrap();
        let conf = dir.join("p.conf");
        std::fs::write(&conf, "port = 1111\nmax_entries = 7\nbind = 1.2.3.4\n").unwrap();
        let conf_s = conf.to_string_lossy().to_string();

        let env = |k: &str| match k {
            "PASTEBOARD_PORT" => Some("2222".to_string()),
            "PASTEBOARD_MAX_ENTRIES" => Some("8".to_string()),
            _ => None,
        };
        let c = run(load(&args(&["--config", &conf_s, "--port", "3333"]), env, None).unwrap());
        assert_eq!(c.port, 3333); // CLI
        assert_eq!(c.max_entries, 8); // env
        assert_eq!(c.bind, "1.2.3.4"); // conf
        assert_eq!(c.data_dir, dir.join("data")); // anchored to conf dir

        let c = run(load(&args(&[&format!("--config={conf_s}")]), |_| None, None).unwrap());
        assert_eq!(c.port, 1111);
    }

    #[test]
    fn exe_dir_conf_fallback() {
        let dir = PathBuf::from("target").join("test-config-exe");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(CONF_NAME), "port = 4444\n").unwrap();
        // Only used when ./pasteboard.conf is absent; the repo has one, so check via cwd-independent path.
        if !PathBuf::from(CONF_NAME).is_file() {
            let c = run(load(&[], |_| None, Some(&dir)).unwrap());
            assert_eq!(c.port, 4444);
        }
    }

    #[test]
    fn missing_explicit_config_errors() {
        assert!(load(&args(&["--config", "nope/missing.conf"]), |_| None, None).is_err());
        assert!(load(&args(&["--port"]), |_| None, None).is_err());
        assert!(load(&args(&["stray"]), |_| None, None).is_err());
        assert!(matches!(load(&args(&["--help"]), |_| None, None), Ok(Loaded::Help)));
        assert!(matches!(load(&args(&["--version"]), |_| None, None), Ok(Loaded::Version)));
    }
}
