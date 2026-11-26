# pasteboard

A tiny shared clipboard for your LAN. Run it on one machine, then open
`http://<that-machine-ip>:9911` on any device on the network. You can paste
text, images or small files, and everyone sees the shared history update live.

- Single ~450 KB binary, written in Rust with `tiny_http`. There's no async
  runtime, no database and no frontend framework.
- About 1 MB private memory at idle and under 2 MB with 200 entries and 5 live
  clients (measured on Windows 11; details in `dev.md`).
- The history survives restarts. It is stored in an append-only
  `data/log.jsonl`, and files go in `data/blobs/`.
- The page is a single ~29 KB HTML file plus the Roboto Mono font (~33 KB),
  both built into the binary. It makes no external requests.

> **No authentication.** Anyone who can reach the port can read, add and
> delete entries. Expose it only on a trusted LAN (the install scripts restrict
> the firewall rule to private networks / your local subnet).

## Quick start (from source)

```sh
cargo run --release
# pasteboard: open http://192.168.x.y:9911
```

Requires Rust (stable). Neither the scripts nor the build install Rust for you.
- **Windows:** `winget install Rustlang.Rustup` plus Visual Studio Build Tools
  with the *Desktop development with C++* workload.
- **Ubuntu:** `sudo apt install -y build-essential curl && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`

## Install as a service (recommended)

`install.sh` is the single entry point. It detects the OS:

| OS | What it does |
|---|---|
| Linux (systemd) | Builds, creates a `pasteboard` system user, installs to `/opt/pasteboard`, installs and enables `pasteboard.service`, and adds a ufw rule for the local subnet if ufw is active |
| Windows (Git Bash) | Hands off to `install.ps1` |
| Windows (PowerShell) | Run `install.ps1` directly: builds a no-console exe, installs to `%LOCALAPPDATA%\Pasteboard`, adds a Private-profile firewall rule, and registers a logon Scheduled Task |

```sh
# Linux
./install.sh --dry-run          # show every action, change nothing
./install.sh                    # build + install (uses sudo for system steps)
./install.sh --port 9911 --prefix /opt/pasteboard
./install.sh --update           # rebuild + swap the binary + restart (after git pull)
./uninstall.sh                  # keeps pasteboard.conf and data/
./uninstall.sh --purge          # also deletes history, config and the service user
```

```powershell
# Windows: from an elevated PowerShell ("Run as Administrator")
.\install.ps1 -DryRun
.\install.ps1                   # or: bash install.sh  (from Git Bash)
.\install.ps1 -Port 9911 -Prefix "$env:LOCALAPPDATA\Pasteboard"
.\install.ps1 -Update           # rebuild + swap the exe + restart (after git pull)
.\uninstall.ps1                 # keeps pasteboard.conf and data\
.\uninstall.ps1 -Purge          # also deletes history and config
```

The PowerShell scripts accept both spellings (`-Update` or `--update`).

| Flag (sh / ps1) | Meaning |
|---|---|
| `--port N` / `-Port N` | Port written into a **new** installed conf (default 9911) |
| `--prefix DIR` / `-Prefix DIR` | Install directory |
| `--build-only` / `-BuildOnly` | Only `cargo build --release` |
| `--dry-run` / `-DryRun` | Print actions without running them |
| `--update` / `-Update` | Rebuild and replace the binary of an existing install, then restart it. Config, firewall and data are untouched, and if the binary is identical (same SHA-256) it isn't restarted |
| `--uninstall` / `-Uninstall` | Remove the service/task, firewall rule and binary (same as `uninstall.sh` / `uninstall.ps1`) |
| `--purge` / `-Purge` | With uninstall: also delete the install dir (history and config), and on Linux the `pasteboard` user. You must type `delete` to confirm |
| `--yes` / `-Yes` | Skip the purge confirmation |

Each step shows a progress bar and prints the exact command before running it.
The cargo build shows a per-crate progress bar. Set `NO_COLOR=1` for plain
output. Before reporting success, the installer checks that the port is free,
and after starting the service it checks that `/` answers HTTP 200. If that
check fails, it prints the service log or task status.

Both scripts are idempotent. Re-running them rebuilds, replaces the binary
and restarts the service/task. An existing installed `pasteboard.conf` is
never overwritten.

## Manual deployment (reference)

### Windows

```powershell
cargo build --release --features no-console   # no console window
# Firewall (elevated, private networks only):
New-NetFirewallRule -DisplayName "Pasteboard" -Direction Inbound -Protocol TCP -LocalPort 9911 -Action Allow -Profile Private
# Run at logon: create a Task Scheduler task that runs
#   pasteboard.exe --config "C:\path\to\pasteboard.conf"
# with "Start in" set to the exe's folder (install.ps1 does exactly this).
```

### Ubuntu

```sh
cargo build --release                      # on the server
# or cross-build elsewhere with a static musl target (install the target yourself):
#   rustup target add x86_64-unknown-linux-musl
#   cargo build --release --target x86_64-unknown-linux-musl
sudo useradd --system --no-create-home --home-dir /opt/pasteboard --shell /usr/sbin/nologin pasteboard
sudo install -d -m 0755 /opt/pasteboard
sudo install -d -m 0750 -o pasteboard -g pasteboard /opt/pasteboard/data
sudo install -m 0755 target/release/pasteboard /opt/pasteboard/
sudo install -m 0644 pasteboard.conf /opt/pasteboard/
sudo install -m 0644 deploy/pasteboard.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pasteboard
sudo ufw allow from 192.168.0.0/16 to any port 9911 proto tcp comment pasteboard
journalctl -u pasteboard -f
```

The unit runs as the `pasteboard` user with `MemoryMax=32M`,
`ProtectSystem=strict` and write access to `/opt/pasteboard/data` only.

## Configuration

Settings are resolved in this order: **CLI flags > `PASTEBOARD_<KEY>` env vars > `pasteboard.conf` > defaults.**

The conf file is looked up in this order:
1. `--config FILE`
2. `PASTEBOARD_CONFIG`
3. `./pasteboard.conf`
4. `pasteboard.conf` next to the executable

A relative `data_dir` is resolved against the conf file's folder.

| Key | Default | Notes |
|---|---|---|
| `bind` | `0.0.0.0` | Use `127.0.0.1` for local-only |
| `port` | `9911` | |
| `data_dir` | `./data` | Log + blobs |
| `max_entries` | `200` | Oldest **unpinned** entries are evicted first |
| `max_text_kb` | `256` | Per text paste (413 above) |
| `max_text_total_mb` | `8` | All text kept in memory |
| `max_file_mb` | `10` | Per upload (413 above). Raising it to hundreds of MB is fine: uploads stream to disk |
| `max_blob_total_mb` | `200` | Files on disk. Keep it a few times `max_file_mb`, or one big upload evicts every other unpinned file |
| `max_sse_clients` | `32` | Open pages receiving live updates |

Examples: `pasteboard --port 8080`, `PASTEBOARD_PORT=8080 pasteboard`, `pasteboard --help`.

## Using it

- **Send text:** type or paste, then click **send** or press Ctrl/⌘+Enter.
- **Files and images:** paste them anywhere on the page, drag and drop, or use
  **attach**. PNG/JPEG/GIF/WebP show as thumbnails; other files download.
  - Each upload shows a progress bar with percentage and speed, and a ×
    button to cancel it. Several files upload one after another.
  - Files over the server's `max_file_mb` are refused before uploading.
  - Downloads report their size and can be resumed by the browser's
    download manager (or `curl -C -`) if interrupted.
- **Copy:** copies text to your clipboard. This works over plain `http://` on
  LAN addresses too, through a fallback. PNGs copy as images on HTTPS/localhost;
  other files copy their link.
- **Devices:** every entry records the device that sent it and its IP.
  - Each browser names itself from its OS and browser (e.g. "Windows · Edge").
    Click the name at the top right to rename it (e.g. "Desk PC"); the name
    is kept in that browser.
  - With entries from two or more devices, filter chips appear over the
    history, and **by device** sorting groups entries per device.
  - The server log shows each add, delete and pin with its device and IP
    (e.g. `journalctl -u pasteboard`).
- **Pin:** keeps an entry at the top and protects it from eviction.
  **Delete** needs a second click to confirm.

## HTTP API

| Method | Path | Notes |
|---|---|---|
| GET | `/api/entries` | JSON array, pinned first, then newest first |
| POST | `/api/text` | `text/plain` body → 201 entry JSON (`device`, `ip`, …) |
| POST | `/api/file` | Raw body; `X-Filename` (percent-encoded) + `Content-Type` headers |
| GET, HEAD | `/blob/<id>` | File download. Images inline, all else (incl. SVG) as attachment. Supports `Range` (206/416), `ETag`, `If-Range`, `If-None-Match` |
| GET | `/api/limits` | `{"max_file_bytes":…,"max_text_bytes":…}` |
| DELETE | `/api/entries/<id>` | |
| POST | `/api/entries/<id>/pin` | Body `true` / `false` |
| GET | `/api/events` | Server-sent events: `add`, `delete`, `pin` |

Mutating requests may send `X-Device: <percent-encoded label>` (at most 40
characters). Without it, the entry is recorded as `unknown` plus the client IP.

```sh
curl -H 'X-Device: build-server' -d 'hello' http://HOST:9911/api/text
curl -H 'X-Filename: shot.png' -H 'Content-Type: image/png' --data-binary @shot.png http://HOST:9911/api/file
curl -N http://HOST:9911/api/events
```

## Troubleshooting

- **Other devices can't connect:** check the firewall rule, and that the
  network is set to *Private* on Windows (the rule only applies there).
- **Port in use:** set a different `port` in `pasteboard.conf` or pass
  `--port`, then restart the service or task. On startup the server retries
  a busy port for about 10 s, so a quick stop/start doesn't fail.
- **Applying conf changes on Windows:** restart the task, waiting for the old
  process to exit first:
  `Stop-ScheduledTask Pasteboard; Wait-Process pasteboard -Timeout 10 -ErrorAction SilentlyContinue; Start-ScheduledTask Pasteboard`
- **Windows task logs:** the no-console build has no output. To see logs, run
  the exe from a terminal using a regular `cargo build --release` build.

## Development

`dev.md` is the progress log, covering milestones, verification results and
decisions. Run the unit tests with `cargo test`.

`vendor/tiny_http` is tiny_http 0.12.0 with one fix (wired in through
`[patch.crates-io]` in `Cargo.toml`): discarding an unread request body no
longer allocates the whole claimed body at once, which let a single request
with a huge `Content-Length` crash the server.
