# Pasteboard — dev log

Plan: `C:\Users\Sachi\.claude\plans\plan-out-a-lightweight-zany-lynx.md`
Read this file and the plan before continuing work. Follow the plan's **RULES FOR ALL AGENTS**: no installs, stay in the repo, do milestones in order, and update this file.

## Status
- **Current milestone:** M10 — large uploads (progress, cancel), resumable downloads, robustness.
- **State:** in progress (2026-10-04). See the plan's M10 section for scope.

## Milestone checklist
- [x] M0 — Toolchain check & scaffolding (2026-10-01)
- [x] M1 — Config + minimal server (2026-10-01)
- [x] M2 — Text store + persistence (2026-10-01)
- [x] M3 — Files & images (2026-10-01)
- [x] M4 — SSE live updates (2026-10-01)
- [x] M5 — Frontend (2026-10-01)
- [x] M6 — Memory & robustness pass (2026-10-01)
- [x] M7 — Cross-platform deploy docs + install scripts (2026-10-01)
- [x] M8 — Installer polish (progress/output), 12 behavior fixes, `--update`, uninstall scripts (2026-10-01)
- [x] M9 — Per-device tracking (device label + IP per entry, filter/sort by device) (2026-10-01)
- [ ] M10 — Upload progress/cancel (XHR), resumable downloads (Range), bind retry, tiny_http drain-crash fix, truncated-upload check

## Log
### 2026-10-01 — M0
- Toolchain: cargo 1.99.0, rustc 1.99.0. Installed target: `x86_64-pc-windows-msvc` only.
- Ran `cargo init --name pasteboard`, which also created `.git`.
- Files:
  - `Cargo.toml`: deps tiny_http 0.12, serde, serde_json; `no-console` feature; size-optimized release profile
  - `.gitignore`: `/target`, `/data`
  - `pasteboard.conf`: defaults, port 9911
  - `src/main.rs`: still the cargo hello-world
  - `dev.md`
- Verified: `cargo build` finished OK.

### 2026-10-01 — M1
- `src/config.rs`:
  - Hand-written key=value parser; `#` comments; keys accept `-` or `_`.
  - Precedence: CLI (`--key value` / `--key=value`) > `PASTEBOARD_<KEY>` env > conf > defaults.
  - Conf lookup order: `--config`, then `PASTEBOARD_CONFIG`, then `./pasteboard.conf`, then `<exe dir>/pasteboard.conf`.
  - A relative `data_dir` is anchored to the conf file's folder.
  - `--help` prints usage.
- `src/main.rs`: tiny_http, a thread per request (128 KiB stack), LAN-IP banner via UDP connect, placeholder `GET /`, 404 otherwise. Opt-in `no-console` subsystem attribute.
- Verified:
  - `cargo test`: 6/6 config tests pass.
  - From `target/` with no conf: banner shows "no config file, using defaults", port 9911; `GET /` returns 200 and `/x` returns 404.
  - `--port 9912`: 200 on 9912.
  - `port = 9913` in the conf: 200 on 9913. The conf was restored to 9911.
- Note: `cargo test` does not rebuild `target/debug/pasteboard.exe`. Run `cargo build` before manual runs.

### 2026-10-01 — M2
- `src/store.rs`:
  - `Entry {id, ts(ms), pinned, kind: text{text} | file{name,mime,size}}`, held oldest-first in a `VecDeque`.
  - Ops log `data/log.jsonl`: `seq`, `add`, `del` and `pin`.
  - `open()` replays the log (skipping corrupt lines with a warning), evicts, compacts (tmp + rename, with a `seq` head so IDs are never reused) and removes orphan blobs.
  - `insert()` and `add_text()` return the evicted IDs, ready for SSE in M4.
  - Eviction removes the oldest unpinned entries first and never the entry just added. It triggers on max_entries, text bytes or blob bytes.
  - The File variant and `alloc_id()` / `blob_path()` are prepared for M3.
- `src/main.rs`:
  - `App {cfg, store: Mutex<Store>}`.
  - Routes: `GET /api/entries` (pinned first, then newest first); `POST /api/text` (201; 413 over max_text_kb; 400 if empty or not UTF-8); `DELETE /api/entries/<id>` (200/404); `POST /api/entries/<id>/pin` with body `true`/`false` (200/404/400).
  - `read_body()` caps reads at max+1 bytes.
- Verified:
  - `cargo test`: 12/12 pass. New tests: replay+pins+next_id, compaction, unpinned-only eviction, byte eviction, corrupt lines, unknown IDs.
  - curl (`--data-dir target/m2data`): add x3, pin, delete, 404 on an unknown delete, 400 on empty text, 413 on 300 KB text.
  - After a restart: list is unchanged and pins persist. The next ID is 4 (deleted ID 3 not reused). The log compacted to seq + live adds.
- Known warnings: `max_file_bytes` and `Store::get` are unused until M3 (now resolved).

### 2026-10-01 — M3
- `src/main.rs`:
  - `upload()`: `POST /api/file` takes a raw body.
    - The `X-Filename` header is percent-decoded, then sanitized (basename only, no control characters, at most 200 characters, leading dots stripped). `Content-Type` is sanitized to `type/subtype`.
    - It rejects early with 413 when `Content-Length` > max_file_mb. Otherwise it allocates an ID under the lock, then streams the body to `blobs/<id>` with `io::copy(take(max+1))` without holding the lock.
    - 413 if the body is too large, 400 if empty. The file is removed on any failure.
  - `serve_blob()`:
    - Streams the file with `Response::from_file`.
    - Headers: `nosniff`, `CSP: sandbox`, `Cache-Control: private, max-age=86400, immutable` (safe because IDs are never reused), and `Content-Disposition` with both an ASCII fallback and `filename*=UTF-8''`.
    - Only PNG/JPEG/GIF/WebP are served inline; everything else, SVG included, is an attachment.
  - Unit tests for percent encode/decode and filename/MIME sanitizing.
- Fixtures: `tests/fixtures/sample.png` (4x4 PNG generated with Python), `sample.txt` and `evil.svg`.
- Verified (`--data-dir target/m3data --max-file-mb 1 --max-blob-total-mb 2`):
  - `cargo test` 14/14; build has no warnings.
  - PNG and TXT downloads match the uploads byte for byte (`cmp`). The UTF-8 name `héllo.png` round-trips.
  - Headers: PNG is inline; SVG is attachment + nosniff + sandbox.
  - Deleting entry 2 removes `blobs/2`.
  - A 1.1 MB upload returns 413 and leaves no file.
  - Three 900 KB uploads under the 2 MB cap evict the older blobs (ids [6,5] remain; blob files 5 and 6).
  - `/blob/99` returns 404.
  - Junk files `blobs/12345` and `blobs/notanid` are removed on restart.

### 2026-10-01 — M4
- `src/sse.rs`:
  - `Broadcaster` holds `SyncSender<Arc<str>>`s with a queue of 64.
  - A live counter capped at max_sse_clients, incremented with a `compare_exchange` loop.
  - `send()` prunes senders that are disconnected or full; a slow client's stream then ends and the browser reconnects and refetches.
  - `Subscription` decrements the counter on Drop and logs `sse client connected/disconnected (clients=N)`.
  - `stream()` writes the HTTP head, then `retry: 3000` and `: connected`. It loops on `recv_timeout(25s)`, emitting `: ping` on timeout, and flushes after every frame.
- `src/main.rs`:
  - `GET /api/events` (503 when over the cap). `App::added()` broadcasts `add` plus a `delete` per evicted ID; `App::deleted()` broadcasts `delete`; pin broadcasts `{id,pinned}`.
- Verified:
  - `cargo test` 17/17, no warnings. SSE tests cover events + heartbeat, the cap + prune on drop, and slow-client drop ending its stream.
  - Live run (`--max-entries 3`) with `curl -N /api/events`: received add (text), add, pin, add (file), add, delete id 2 (eviction) and delete id 3 (explicit), all immediately.
  - `: ping` arrived after about 25s.
  - After killing curl and sending an event, the server logged `clients=0`.

### 2026-10-01 — M5
- `static/fonts/RobotoMono.woff2`: 32,796 B. Latin subset, variable weight 400–700, downloaded from fonts.gstatic.com (Google Fonts CSS2 API). License: Apache-2.0.
- `static/index.html`: 17,282 B, a single file with inline CSS/JS and no framework.
  - Look:
    - Monochrome tokens on `:root` with a dark override via `prefers-color-scheme`.
    - 14px cards, pill buttons, 760px max-width column.
    - Roboto Mono with a system-mono fallback stack.
    - A 140ms fade-in, disabled under `prefers-reduced-motion`.
  - Composer: Ctrl/⌘+Enter, attach (file input), page-level paste (files are uploaded; text pasted outside the textarea is moved into it) and drag-drop (dashed composer border while dragging).
  - Cards: pinned first, then newest first.
    - Text goes in a `<pre>` via `textContent`, with "show more" past 260px.
    - Images show an inline thumbnail. Other files show a download chip.
    - Copy, Pin and Delete buttons. Delete needs a second click within 2.2s.
  - Copy: `navigator.clipboard` in secure contexts, otherwise the `execCommand('copy')` fallback. PNGs are copied as images in secure contexts; other files copy their link.
  - Live: EventSource with a status dot (live/reconnecting); refetches `/api/entries` on every open; entries upserted by ID so a client's own POST and the SSE echo don't duplicate.
- `src/main.rs`:
  - `/` serves the embedded HTML (`include_str!`) with CSP `default-src 'none'` plus self-only for img/font/connect, inline script/style, `frame-ancestors 'none'`, nosniff and `no-referrer`.
  - `/font.woff2` serves the font (`include_bytes!`) with immutable 1-year caching.
- Verified in Chrome via claude-in-chrome:
  - Total transfer is about 50 KB (< 100 KB). Roboto Mono status is `loaded`. No console errors.
  - Typing plus Ctrl+Enter sends, clears the textarea and shows a "Sent" toast.
  - A synthetic paste event with a PNG File uploaded and rendered a thumbnail. A synthetic drop of notes.txt uploaded and rendered a file chip.
  - Two tabs (localhost and the LAN IP 192.168.0.5) stayed in sync with no reload: a pin from tab 1 and a delete (two clicks) from tab 2 both propagated.
  - On the LAN IP (`isSecureContext=false`), Copy showed "Copied", and `Get-Clipboard` returned the exact text, so the execCommand fallback works.
  - Phone width: `resize_window` had no effect (the window is probably maximized) and `window.open` was popup-blocked. Instead, the page HTML ran in a 375px srcdoc iframe: scrollWidth 371 = viewport (no horizontal scroll), widest element 355px, hint hidden.
  - Dark mode was checked in the main tab (the browser default). Light mode was checked in the iframe with the dark media query neutralized (body `rgb(243,243,242)`) and looks right.
- Not covered by automation: a real OS clipboard image paste (Ctrl+V of a screenshot) and a real drag from Explorer. The synthetic events exercise the same handlers. The user can spot-check these.

### 2026-10-01 — M6
- Release build: `target/release/pasteboard.exe` is 455,168 B (opt-level z, LTO, strip, panic=abort); builds with no warnings.
- Memory on Windows 11 (`Get-Process`), release build:

  | State | WorkingSet | Private | Threads |
  |---|---|---|---|
  | idle, fresh | 5.33 MB | 0.98 MB | 9 |
  | 200 text entries | 5.55 MB | 1.09 MB | 6 |
  | 200 entries + 5 SSE clients | 5.75 MB | 1.46 MB | 13 |
  | after 40 page/API loads | 5.88 MB | 1.65 MB | 13 |
  | after robustness tests | 5.88 MB | 1.73 MB | 13 |
  | SSE clients closed | — | 1.45 MB | 7 |
  | **baseline: do-nothing Rust exe (sleep + TcpListener)** | **4.82 MB** | **0.73 MB** | — |
- Robustness (the server stayed up throughout):

  | Request | Result |
  |---|---|
  | `PUT /api/text`, `GET /api/entries/abc/pin`, `GET /blob/<text id>`, `GET /blob/../log.jsonl` | 404 |
  | `DELETE /api/entries/abc` or an overflowing id, `..%2F` blob id, pin body `maybe`, invalid UTF-8 text, empty file | 400 |
  | Unknown id on pin or delete | 404 |
  | Raw `GARBAGE` request line | tiny_http 400 |
  | Negative Content-Length | ignored, 200 |
  | Binary junk without CRLF, or a truncated body | the connection waits until the client closes, then is freed |
  | Headers of 8 KB, 64 KB and 1 MB | accepted (200); memory returns afterwards |
- Corrupt log: three bad lines appended (non-JSON, wrong type, truncated object). On restart each was skipped with a `warning: log line N` message, all 200 entries were kept, and compaction removed the junk (201 lines = seq + 200).

### 2026-10-01 — M7
- `deploy/pasteboard.service`:
  - Runs as the `pasteboard` user with WorkingDirectory/ExecStart under `/opt/pasteboard` and `--config`.
  - `Restart=on-failure`, `MemoryMax=32M`.
  - Hardening: `ProtectSystem=strict`, `ReadWritePaths=<prefix>/data`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `NoNewPrivileges`, and `RestrictAddressFamilies` limited to UNIX/INET/INET6.
- `install.sh` (LF line endings):
  - Detects the OS with `uname -s`. Linux runs the systemd flow; MINGW/MSYS/CYGWIN execs `powershell -ExecutionPolicy Bypass -File install.ps1` with mapped flags (cygpath for paths); any other OS exits with "unsupported".
  - Flags: `--port`, `--prefix`, `--build-only`, `--dry-run`, `--uninstall`, `-h`. The port is validated as 1–65535.
  - Exits non-zero with Rust install instructions when cargo is missing; never installs tooling.
  - Linux flow:
    - The build runs as the invoking user; `sudo` is used only for system steps, after an explanation and a `sudo -v` prompt.
    - Steps: `useradd --system` if missing, install dirs and binary, write the conf only if absent, write the unit with the prefix substituted, then `daemon-reload` + `enable` + `restart` (idempotent).
    - If ufw is active, it allows the local link subnet (fallback 192.168.0.0/16) on the effective port, with comment `pasteboard`.
    - Prints the LAN URL (`hostname -I`, falling back to `ip route get`).
  - Uninstall removes the unit, binary and the ufw rules commented `pasteboard`; the conf, data and user are kept.
- `install.ps1`:
  - Params: `-Port`, `-Prefix` (default `%LOCALAPPDATA%\Pasteboard`), `-BuildOnly`, `-DryRun`, `-Uninstall`.
  - The real install requires Administrator; dry-run only notes it.
  - Builds with `--features no-console`.
  - Stops the running task/exe, copies the exe, and writes the conf without a BOM only if it's absent.
  - Firewall rule `Pasteboard`: Private profile, the effective port, scoped to the exe (removed and recreated, so it's idempotent).
  - Scheduled Task `Pasteboard`: runs at logon of the current user, no time limit, 3 restarts at 1-minute intervals, `IgnoreNew`. Started immediately.
  - Prints the LAN URL. Uninstall removes the task, rule and exe; the conf and data are kept.
- `README.md`: overview, quick start, install scripts (primary path), manual Windows/Ubuntu commands, config table, usage, HTTP API, troubleshooting.
- `.gitattributes`: LF for `*.sh`, `*.service` and `pasteboard.conf`; CRLF for `*.ps1`; binary for woff2/png.
- `src/config.rs`: `apply_conf` strips a leading UTF-8 BOM (new test `accepts_utf8_bom_and_crlf`).
- Verified:
  - `install.ps1 -BuildOnly`: builds (exit 0). The no-console exe started with `--port 9915` and served `GET /` 200, so no stdout is needed.
  - `install.ps1 -DryRun -Port 9920`: printed the 7 expected Windows actions. Afterwards no task, no firewall rule and no `%LOCALAPPDATA%\Pasteboard` existed (nothing changed).
  - `bash install.sh --dry-run --port 9921 --uninstall` from Git Bash: "Windows detected; handing off", and the flags mapped correctly to the ps1 uninstall dry run.
  - Linux branch dry-run under Git Bash, with PATH shims in `target/linuxshim` (`uname` → Linux, a stub `systemctl`): printed useradd/install/conf (port 9922)/unit (prefix `/opt/pb-test` substituted)/systemctl steps, exit 0.
  - `bash -n install.sh`: OK. Bad flags and `--port 99999` are rejected.
  - `shellcheck`: not installed, skipped.
  - `cargo check --target x86_64-unknown-linux-gnu`: skipped; only the `x86_64-pc-windows-msvc` target is installed (user action).
  - `cargo build --release`: 0 warnings. `cargo test`: 18/18.
- Bugs found and fixed during M7:
  - PS 5.1 aborted on cargo's stderr under redirection, so the build now uses EAP=Continue and checks the exit code.
  - The unit comment got rewritten by the prefix substitution, so it was reworded.
  - The LAN URL was empty without `hostname -I`, so an `ip route` fallback was added.
  - **All files had CRLF line endings** (from how they were written on Windows), which would break `install.sh` on Linux. They were converted to LF in binary mode (Git Bash `sed -i` kept the CRs) and are protected by `.gitattributes`.

### 2026-10-01 — M8 (user request: prettier installers, find and fix questionable behavior, uninstall script, update option)
- **UI, both scripts:**
  - Banner box (os, action, prefix, user/port, dry-run).
  - Per-step progress bar (`[####----] N/M  title`). Every command is printed (`$ ...`) before it runs.
  - The cargo build shows a live per-crate bar (total = `[[package]]` count in Cargo.lock).
  - Glyphs: ✓ ok, ! warn, ✗ fail, · skip.
  - A warning recap at the end. Each failure names the step, the last command and that re-running is safe.
  - Color and redraws only on a TTY; `NO_COLOR` supported. Unicode glyphs fall back to ASCII on a non-UTF-8 locale (sh) or when output is redirected (ps1).
  - The ps1 also drives `Write-Progress` (step bar + nested cargo bar).
  - The ps1 stays **pure ASCII**: glyphs come from `[char]0x2588` etc. A BOM-less non-ASCII script is misread by PowerShell 5.1.
  - In dry-run, results print as "· would: ..." instead of ✓ (sh `did()`; the ps1 guards with `if (-not $DryRun)`).
- **New modes:**
  - `--update` / `-Update`:
    - requires an existing install and shows its version
    - rebuilds, then compares SHA-256 (12 hex) of the installed vs the new binary
    - when they match and the service is running, skips the replace and restart
    - otherwise: stop, replace (Windows: retry while the file is locked), refresh the unit if it changed, restart, health check
    - never touches the conf, user or firewall
  - `--purge` (+ `--yes`) for uninstall. Without `--yes` you must type `delete`; it refuses when stdin isn't a terminal.
  - Mutually exclusive modes are validated.
  - `uninstall.sh` and `uninstall.ps1` are thin wrappers around the install scripts' `--uninstall` / `-Uninstall`.
- `pasteboard --version` / `-V` was added (src/config.rs `Loaded::Version`, src/main.rs).
- **Problems found and fixed:**
  1. **sh, firewall subnet:** ufw used the first link route (often `docker0`). It now uses the subnet of the default-route interface.
  2. **sh, LAN URL:** came from `hostname -I`'s first IP (could be a Docker/bridge IP). It now uses `ip route get` src first.
  3. **sh, builds under sudo:** `sudo ./install.sh` built as root (root-owned target/, or a false "no cargo"). It now builds as `$SUDO_USER` with their `~/.cargo/bin`.
  4. **both, false success:** no port-conflict check and no health check, so a crash-looping service was reported as "Done". There is now a pre-check that the port is free (sh `ss`; ps1 `Get-NetTCPConnection`, ignoring our own exe) and a post-start health check: HTTP 200 on 127.0.0.1, otherwise the journal or the task's last result.
  5. **sh, stale firewall rules:** the old ufw rule stayed open after a port change. Rules commented `pasteboard` are now deleted (`ufw --force delete`, highest number first) before the new rule is added.
  6. **both, ignored `--port`:** silently ignored when an installed conf exists. It now warns.
  7. **sh, prefix:** wasn't validated (spaces, `#`, `&` broke the unit; /home or /tmp conflict with ProtectHome/PrivateTmp). It is now validated, and home/tmp prefixes are refused.
  8. **sh, upgrades:** the binary was replaced while the service was running. The service is now stopped first.
  9. **ps1, re-run hint:** used `$MyInvocation` inside a function (printed the wrong line). It is now built from script-scope `$PSBoundParameters`.
  10. **ps1, locked exe:** only a 300 ms sleep before overwriting the exe. It now uses `Wait-Process` and retries the copy 20 x 250 ms.
  11. **ps1, Public network:** no warning when the network profile is Public, where the Private-only rule doesn't apply. It now warns, with the Settings path; the profile is not changed automatically because it's a system setting.
  12. **ps1, different elevated account:** elevating as another admin installed into that admin's AppData and logon. It now installs for the desktop user (owner of explorer.exe), using their profile's LocalAppData unless `-Prefix` is given, and warns.
  - Also found during verification:
    - `conf_port` and `file_hash` aborted the script under `pipefail` when the file was missing; they now return empty.
    - `ip`/`hostname` pipelines were hardened.
    - `Get-Version` leaked "config error: missing value for --version" from pre-`--version` builds; it now captures stderr, checks the exit code and reports "unknown version".
- Verified (no real install/update/uninstall was run):
  - `bash -n` and the PowerShell AST parser report 0 errors for all 4 scripts. The ps1 files have 0 non-ASCII bytes; the sh files are LF.
  - `install.ps1 -BuildOnly`: builds 17/17 crates with the bar, reads the new exe's version (`pasteboard 0.1.0`), exit 0.
  - `install.ps1 -DryRun -Port 9920`: all 8 steps printed. It detected the **user's existing real install** (`%LOCALAPPDATA%\Pasteboard`, PID 29068, port 9911): warned that `-Port 9920` is ignored, saw the port served by our own exe, network `Network 2` = Private.
  - `-DryRun -Update`: installed version "unknown version" (a pre-`--version` build), sha256 ad4ec94bdaa0 → 1c19ed38130f, stop/copy/start/health steps.
  - `uninstall.ps1 -DryRun -Purge`: 6 steps, "about 3 history entries".
  - Afterwards the real install was intact (exe, task and process all present).
  - Git Bash: `install.sh --dry-run --update` and `uninstall.sh --dry-run --purge --yes` hand off. Mode conflicts (`--update --uninstall`, `--purge` alone) are rejected.
  - Linux branch via `target/linuxshim` (`uname`=Linux, a stub `systemctl`) with `--dry-run`: install (9 steps, conf port 9922), update (5 steps; "no install found" warned), and `uninstall.sh --purge` (6 steps) all complete with exit 0.

### 2026-10-01 — M9 (user request: log which device sent what, sort by device)
- `src/store.rs`:
  - `Entry` gains `device` and `ip` (`#[serde(default)]`, so pre-M9 log lines load with empty values).
  - New `Source {device, ip}` struct; `insert()` and `add_text()` take `&Source`.
  - New test `pre_device_log_lines_still_load_and_new_ones_keep_source`.
- `src/main.rs`:
  - `source(&req)`:
    - `X-Device` is percent-decoded and run through `sanitize_device` (no control characters, trimmed, at most 40 chars). Empty or missing becomes `unknown`.
    - `ip` is `remote_addr` with IPv4-mapped IPv6 shown as IPv4.
  - Used for text and file adds. Log lines:
    - `pasteboard: add #N text|file ... from "device" (ip)`
    - `evict #N (limits reached)`
    - `delete #N by ...`
    - `pin #N=v by ...`
  - Test `device_labels_are_sanitized`.
- `static/index.html` (now 24,484 B):
  - **Device chip in the header:** an icon and the name, guessed from the UA (iPhone/iPad/Android/ChromeOS/Windows/Mac/Linux · Edge/Opera/Firefox/Chrome/Safari). Click to rename inline (Enter saves, Esc cancels); the name is stored in `localStorage` as `pb.device`.
  - **Requests:** every non-GET `api()` call sends `X-Device: encodeURIComponent(name)`.
  - **Card meta:** device (bold + "(this device)" when it matches), IP, time, size. IP and size are hidden under 480px.
  - **Toolbar:** a sort select (newest first / by device), stored as `pb.sort`. Device sort is A–Z, then pinned, then newest, with a group header per device ("name · count").
  - **Filter chips:** "all devices" plus one per device with a count, your own device first. They appear only with 2+ devices or an active filter, are stored as `pb.filter`, and the filter resets once loaded if its device has no entries left. The count shows "N of M" while filtered.
  - All `localStorage` access is wrapped in try/catch (`prefs`).
- Verified (test server on **port 9930**, data `target/m9data`, so the user's live install on 9911 was left alone):
  - `cargo test` 20/20; release build 0 warnings; exe 465,920 B.
  - curl: with `X-Device: Laptop%20%C2%B7%20Firefox`, the device is stored as "Laptop · Firefox". With no header it's "unknown". A file upload records its device. The server log shows add/pin/delete lines with device and IP. Entries in log.jsonl include device/ip.
  - Browser (Edge, via claude-in-chrome):
    - auto name "Windows · Edge"; a sent paste shows "(this device)"
    - real click + typed rename to "Desk PC" was saved, and later pastes carry it
    - sort by device shows group headers in A–Z order
    - clicking the Phone chip shows "1 of 4"
    - a live SSE add from "Phone" appears under the filter, while a "Laptop" add only bumps its chip count
    - after a reload, sort, filter and name are kept
    - 375px srcdoc iframe: no horizontal scroll, header fits (355px), IP hidden, chips scroll horizontally
    - no console errors
- **Incident (no harm):** a test cleanup used `taskkill /IM pasteboard.exe`, which could have killed the user's live install. It survived (same PID 29068 and start time). Test servers are now stopped by path only (`Path -like '*\target\*'`), and this is recorded in agent memory.

### 2026-10-01 — Fix: `.\install.ps1 --update` failed (reported by the user)
- **Cause:** the ps1 only knew `-Update`. With positional binding, `--update` was bound to `-Port` and failed with "Cannot convert value "--update" to type System.Int32".
- **Fix:**
  - `install.ps1` and `uninstall.ps1` use `[CmdletBinding(PositionalBinding = $false)]` with a `ValueFromRemainingArguments` catch-all. It maps install.sh-style flags (`--update`, `--build-only`, `--uninstall`, `--purge`, `--yes`/`-y`, `--dry-run`, `--help`/`-h`/`-?`, `--port N`/`--port=N`, `--prefix DIR`/`--prefix=DIR`) onto the native switches.
  - Unknown arguments print "unknown argument" plus usage (exit 2).
  - `-Port` is untyped and validated by hand, so `-Port`/`--port` errors read the same ("invalid port: abc (expected 1-65535)") instead of PowerShell's type-conversion error.
  - New `-Help`/`--help` usage text. `uninstall.ps1` forwards extra `--flags` to install.ps1.
- **Verified:** an 11-case matrix via `powershell -File` (both styles, `--port=N`, bad/huge ports, unknown flag, a stray word, mode conflict) plus `uninstall.ps1 --purge --dry-run --yes`. All ran as dry runs; the live install was untouched. The file is still ASCII-only and LF.

### 2026-10-04 — M10 (user request: bigger uploads with progress/cancel, resumable downloads) — in progress
- **Live install outage (diagnosed, user action to restore):** the user raised `max_file_mb=500` / `max_blob_total_mb=2000` and ran `Stop-ScheduledTask Pasteboard; Start-ScheduledTask Pasteboard` (as the agent had suggested). The task's last result was `0x1` and nothing listened on 9911.
  - The conf was fine (no BOM). `log.jsonl` was rewritten at the task's start second, so config and store opened. The only exit-1 path after that is the bind.
  - Reproduced on a copy (`target/livecopy-1004`, port 9931): a second instance on a held port exits 1 with `os error 10048`. Stop-ScheduledTask returns before the old exe exits.
  - The user must run `Start-ScheduledTask Pasteboard` (the agent doesn't touch the live task).
- **Found: one request could crash the server (all versions).** tiny_http 0.12.0 `EqualReader::drop` did `vec![0; remaining]` for an unread body. `GET /` with `Content-Length: 100000000000000` aborted the process (`memory allocation of 100000000000000 bytes failed`).
  - Fix (user chose it): `vendor/tiny_http` = tiny_http 0.12.0 copied from the local Cargo cache (no download). The drain uses a fixed 8 KiB stack buffer. A crate-level `#![allow(unused_imports, dead_code)]` hides upstream lints that show up for path deps. Wired in with `[patch.crates-io]`, built `--offline`.
- **Found: downloads ≥ 32 KiB had no Content-Length.** tiny_http switches to chunked at 32 KiB, so browsers showed no size or progress and couldn't resume. Blob responses now use `with_chunked_threshold(usize::MAX)`.
- `src/main.rs`:
  - `listen()`: retries `AddrInUse` every 500 ms for up to 20 attempts (~10 s), logging once.
  - `GET /api/limits` → `{"max_file_bytes","max_text_bytes"}`.
  - `upload()`: when the bytes received ≠ `Content-Length`, the blob is removed and the server returns 400 `incomplete upload` and logs it. Previously a cancelled upload was saved truncated, because the body reader gives a clean EOF on disconnect.
  - `serve_blob()` (now also `HEAD`):
    - `ETag "<id>-<size>"` and `Accept-Ranges: bytes`
    - `If-None-Match` → 304
    - single `Range` → 206 + `Content-Range`; unsatisfiable → 416 `bytes */size`
    - multi-range / malformed → full 200
    - `If-Range` must equal the ETag, otherwise a full 200
  - `parse_range()` plus test `ranges_are_parsed_against_size`.
- `static/index.html` (now 28,748 B):
  - Uploads use `XMLHttpRequest`, one at a time from a queue.
  - Each file gets a row in the composer: name, progress bar (`role=progressbar`), `NN% · speed/s` (smoothed; bytes in the tooltip) and a × cancel button.
  - Cancel works on queued jobs (removed) and the active job (`xhr.abort()`). Rows finish as done / cancelled / error and fade out.
  - Files over `/api/limits` `max_file_bytes` or empty are refused client-side with a toast.
  - `beforeunload` warns while uploads are pending.
- Verified (test servers on 9931–9937, data under `target/`, stopped by path/PID; the live install untouched):
  - `cargo test` 21/21; debug and release builds 0 warnings; release exe 478,208 B.
  - 300 MB random file: upload 201; full download has `Content-Length: 314572800`, same SHA-256.
  - `HEAD` 200 with length/ETag. `Range: bytes=0-99` → 206 with the correct bytes. `-10` → last 10 bytes. Past the end → 416. `If-Range` mismatch → 200 full, match → 206. `If-None-Match` → 304.
  - Resume: a download stopped at 69,865,472 B, then `curl -C -` → 206 and the final SHA-256 matches.
  - Cancelled upload (curl aborted after 2 s): log `upload "cancel.bin" incomplete (41943040 of 314572800 B), discarded`. No entry, no blob.
  - Peak server private memory during a 300 MB upload: 1.1 MB.
  - A huge `Content-Length` on `GET /` and `POST /api/file` → 413; the server stays up.
  - Bind retry: instance B started while A held 9936; A was killed at 3 s, then B bound and served 200. (A first attempt with a .NET `TcpListener` as the blocker was invalid: `Stop()` left the socket listening, owned by the PowerShell process.)
  - The page script passes `node --check` (node v26 was already installed).
- **Storage stat (user request, same day):** the header shows `used / limit MB` (e.g. `50 / 2000 MB`) before the live dot.
  - `/api/limits` gains `max_blob_total_bytes`.
  - `renderUsage()` sums file sizes over all entries (not the filtered view) on every `sync()`, so SSE adds, deletes and evictions update it live. The tooltip shows exact sizes and %, and notes that the oldest unpinned files are evicted when full. It turns bold at ≥ 90%.
  - At ≤ 480px the "live" word is hidden (the dot keeps it as a title) and the device chip can shrink, because logo + usage + status + chip would be ~420px in ~343px.
  - Verified: 21/21 tests, 0 warnings, release exe 479,232 B, index.html 29,908 B. `node --check` OK. The served page includes the span. Seeded data (a 50 MB file + a PNG + text) totals 52,428,886 B, so it should read `50 / 2000 MB`.
- **Not yet verified:** the browser UI (progress rows, cancel, size pre-check, storage stat rendering and phone-width header fit). The claude-in-chrome extension was not connected. A test server was left running on 9937 (`target/m10ui`) for a manual look.

## Decisions / deviations
- **tiny_http is vendored (M10)** at `vendor/tiny_http` with a one-line drain fix, chosen by the user over leaving it unfixed or switching HTTP crates. To upgrade tiny_http later, check whether upstream fixed `EqualReader::drop`, then drop the patch.
- **Uploads stay single-request (M10).** A cancelled or failed upload is discarded, not resumed. Resumable *uploads* would need a chunked upload protocol and are out of scope; *downloads* resume via Range.
- **Device identity = the client-chosen label**, not the IP: DHCP changes IPs, while a label is stable and readable. The IP is still recorded and shown for auditing. Two devices with the same default label (e.g. two "iPhone · Safari") share a filter chip until one is renamed.
- Sorting by device groups entries per device, so pinned entries are first *within* each group, not globally. Newest-first sort still puts pinned entries first.
- The ps1 files are LF on disk (`.gitattributes` converts `*.ps1` to CRLF on checkout); PowerShell accepts both.
- The install scripts never run a real install or uninstall from an agent session; they are verified only through `-BuildOnly`/`-DryRun`, per the rules. The Linux branch was exercised with PATH shims, not a real Ubuntu host.
- **Memory target measured as private bytes on Windows, not working set.** The Windows working set includes shared system-DLL pages: a do-nothing Rust exe that only sleeps on a socket already uses 4.82 MB, so "WS < 3 MB" cannot be met by any process.
  - pasteboard adds about 0.5 MB WS idle and about 1 MB under load over that baseline.
  - Private bytes are 0.98 MB idle (target < 3 MB) and 1.46–1.73 MB with 5 SSE clients and 200 entries (target < 6 MB). Both pass.
  - The Linux RSS check (`ps -o rss= -p <pid>`) is a user action on Ubuntu.
- **Known limitation (accepted for a trusted LAN):** tiny_http does not cap request-header size, and a client that never finishes its request holds a connection thread until it disconnects. Fixing either would need a different HTTP layer or a reverse proxy, which is out of scope for the no-auth LAN design.
- **SSE uses `Request::into_writer()`, not a `ChannelReader` body.** tiny_http's chunked encoder buffers 8 KiB before writing, which would delay events. The raw writer plus a manual head and a flush per frame gives the same behavior with simpler code.
- Avoided `AtomicUsize::fetch_update`, which is deprecated in Rust 1.99 in favor of `try_update`, a name older toolchains lack. A `compare_exchange` loop builds on any toolchain, including Ubuntu's.
- Upload filenames come in the `X-Filename` header, percent-encoded by the client (`encodeURIComponent`), because HTTP header values must be ASCII.
- `cargo init` created a git repo. The user agreed to keep it.
- Crates download into the standard Cargo cache (`~/.cargo/registry`). This is a normal dependency fetch, not a system install. The user approved it.

## Blockers / user actions needed
None of these block anything; they are checks only the user can run.
- **Restore the live install (down since 2026-10-04 17:42):** `Start-ScheduledTask Pasteboard`.
- **M10 browser check:** connect the Claude in Chrome extension so an agent can verify the upload progress rows and cancel, or check by hand by uploading a large file and pressing ×.
- **Update the user's running Windows install** to pick up M8–M10 (it's a pre-`--version` build): `.\install.ps1 -Update` from an elevated PowerShell.
- **Visual check:** the TTY colors and Unicode bars. Agent runs capture output, which takes the plain/ASCII path.
- **Windows real install** (elevated PowerShell): `.\install.ps1`, then open `http://<LAN-IP>:9911` from a phone. Network profile must be *Private*.
- **Ubuntu:** `./install.sh` on the server. Then check:
  - `systemctl status pasteboard`
  - `ps -o rss= -p $(pgrep pasteboard)` (expect a few MB)
  - access from another device
- **Optional checks:**
  - With the Linux target added (`rustup target add x86_64-unknown-linux-gnu`), run `cargo check --target x86_64-unknown-linux-gnu`. A native Ubuntu build covers this anyway.
  - If shellcheck is available: `shellcheck install.sh`.
- **Manual UI spot-check:** a real Ctrl+V of a screenshot and a real drag from Explorer/Finder. Automation used synthetic events that go through the same handlers.
- The repo has a `.git` folder (from `cargo init`) with nothing committed yet.

## Next steps
- **M10:** browser-verify the upload UI and the header storage stat (desktop + 375px, light/dark) on a test port (e.g. `target\debug\pasteboard.exe --port 9937 --data-dir target/m10ui --max-file-mb 600`). Queue a big in-memory `File` plus small ones through `uploadFiles`, then watch progress, cancel the active and a queued job, and try an over-limit file. Check 375px width and dark/light. Then check off M10.
- Possible follow-ups, if the user wants them:
  - commit to git
  - a cap on header size or request timeouts (needs a reverse proxy or a different HTTP layer)
  - an optional shared PIN
  - a light/dark toggle button
