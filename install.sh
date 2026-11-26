#!/usr/bin/env bash
# Build and install / update / uninstall pasteboard. Detects the OS:
#   Linux                 -> systemd service under --prefix (default /opt/pasteboard)
#   Git Bash/MSYS/Cygwin  -> hands off to install.ps1 (Windows)
# Never installs Rust or other tooling; it tells you what is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=""
PREFIX=""
BUILD_ONLY=0
UPDATE=0
UNINSTALL=0
PURGE=0
YES=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [mode] [options]

Modes (default: install, or upgrade an existing install):
  --update        rebuild and replace the binary of an existing install, then
                  restart it (config, firewall and data are left alone)
  --build-only    only run `cargo build --release`
  --uninstall     remove the service/task, firewall rule and binary
                  (keeps pasteboard.conf and data/ unless --purge)

Options:
  --port N        port written into a NEW pasteboard.conf (default 9911;
                  an existing installed conf is never overwritten)
  --prefix DIR    install dir (Linux default /opt/pasteboard,
                  Windows default %LOCALAPPDATA%\Pasteboard)
  --purge         with --uninstall: also delete the install dir (history and
                  config) and the service user; asks you to type 'delete'
  --yes           with --purge: do not ask for confirmation
  --dry-run       print every action without executing it
  -h, --help      show this help

Set NO_COLOR=1 for plain output.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --port=*) PORT="${1#*=}"; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        --update) UPDATE=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --purge) PURGE=1; shift ;;
        --yes|-y) YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ $((BUILD_ONLY + UPDATE + UNINSTALL)) -gt 1 ]; then
    echo "choose only one of --build-only, --update, --uninstall" >&2; exit 2
fi
if [ "$PURGE" = 1 ] && [ "$UNINSTALL" = 0 ]; then
    echo "--purge only works together with --uninstall" >&2; exit 2
fi
if [ -n "$PORT" ] && ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then
    echo "invalid --port: $PORT" >&2; exit 2
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        ps_args=()
        [ -n "$PORT" ] && ps_args+=(-Port "$PORT")
        if [ -n "$PREFIX" ]; then
            command -v cygpath >/dev/null 2>&1 && PREFIX="$(cygpath -w "$PREFIX")"
            ps_args+=(-Prefix "$PREFIX")
        fi
        [ "$BUILD_ONLY" = 1 ] && ps_args+=(-BuildOnly)
        [ "$UPDATE" = 1 ] && ps_args+=(-Update)
        [ "$UNINSTALL" = 1 ] && ps_args+=(-Uninstall)
        [ "$PURGE" = 1 ] && ps_args+=(-Purge)
        [ "$YES" = 1 ] && ps_args+=(-Yes)
        [ "$DRY_RUN" = 1 ] && ps_args+=(-DryRun)
        ps1="$SCRIPT_DIR/install.ps1"
        command -v cygpath >/dev/null 2>&1 && ps1="$(cygpath -w "$ps1")"
        echo "Windows detected: handing off to install.ps1"
        exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps1" ${ps_args[@]+"${ps_args[@]}"}
        ;;
    Linux) ;;
    *)
        echo "Unsupported OS: $(uname -s). Supported: Linux (systemd) and Windows." >&2
        exit 1
        ;;
esac

# =============================================================== Linux ====
PORT_GIVEN=0
[ -n "$PORT" ] && PORT_GIVEN=1
PORT="${PORT:-9911}"
PREFIX="${PREFIX:-/opt/pasteboard}"
[ "$PREFIX" = / ] || PREFIX="${PREFIX%/}"
UNIT=/etc/systemd/system/pasteboard.service
CONF="$PREFIX/pasteboard.conf"
BIN="$SCRIPT_DIR/target/release/pasteboard"
SVC_USER=pasteboard

# ------------------------------------------------------------- terminal UI --
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then TTY=1; else TTY=0; fi
if [ "$TTY" = 1 ]; then
    BOLD=$'\e[1m' DIM=$'\e[2m' RST=$'\e[0m' GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m' CYN=$'\e[36m'
else
    BOLD="" DIM="" RST="" GRN="" YEL="" RED="" CYN=""
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*)
        FULL="█" EMPTY="░" OK_S="✓" WARN_S="!" FAIL_S="✗" SKIP_S="·" ARROW="→"
        TL="┌" BL="└" VL="│" HL="─" ;;
    *)
        FULL="#" EMPTY="-" OK_S="ok" WARN_S="!" FAIL_S="x" SKIP_S="-" ARROW="->"
        TL="+" BL="+" VL="|" HL="-" ;;
esac

STEP=0
TOTAL=1
CURRENT=""
LAST_CMD=""
DIED=0
BUILD_LOG=""
WARNINGS=()

repeat() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }
bar() { # bar CUR TOTAL WIDTH
    local f=$(( $2 > 0 ? $1 * $3 / $2 : $3 ))
    (( f > $3 )) && f=$3
    printf '%s%s%s%s%s' "$CYN" "$(repeat "$FULL" "$f")" "$DIM" "$(repeat "$EMPTY" $(( $3 - f )))" "$RST"
}
step() {
    STEP=$((STEP + 1)); CURRENT="$1"
    printf '\n %s %s%d/%d%s  %s%s%s\n' "$(bar "$STEP" "$TOTAL" 20)" "$DIM" "$STEP" "$TOTAL" "$RST" "$BOLD" "$1" "$RST"
}
info()  { printf '   %s\n' "$*"; }
shown() { printf '   %s$ %s%s\n' "$DIM" "$*" "$RST"; }
ok()    { printf '   %s%s%s %s\n' "$GRN" "$OK_S" "$RST" "$*"; }
# did MSG: result of an action; in dry-run it was not performed.
did()   { if [ "$DRY_RUN" = 1 ]; then printf '   %s%s would: %s%s
' "$DIM" "$SKIP_S" "$*" "$RST"; else ok "$@"; fi; }
skip()  { printf '   %s%s %s%s\n' "$DIM" "$SKIP_S" "$*" "$RST"; }
warn()  { printf '   %s%s %s%s\n' "$YEL" "$WARN_S" "$*" "$RST"; WARNINGS+=("$*"); }
die() {
    DIED=1
    printf '\n   %s%s %s%s\n' "$RED" "$FAIL_S" "$1" "$RST" >&2
    shift
    local l; for l in "$@"; do printf '     %s\n' "$l" >&2; done
    exit 1
}
on_exit() {
    local rc=$?
    [ -n "$BUILD_LOG" ] && rm -f "$BUILD_LOG"
    if [ "$rc" -ne 0 ] && [ "$DIED" = 0 ] && [ -n "$CURRENT" ]; then
        printf '\n   %s%s step %d/%d "%s" failed (exit %d)%s\n' "$RED" "$FAIL_S" "$STEP" "$TOTAL" "$CURRENT" "$rc" "$RST" >&2
        [ -n "$LAST_CMD" ] && printf '     last command: %s\n' "$LAST_CMD" >&2
        printf '     Earlier steps were applied. Fix the cause and re-run; the installer is idempotent.\n' >&2
    fi
}
trap on_exit EXIT

# run CMD...: print the command, then execute it (output indented) unless dry-run.
run() {
    LAST_CMD="$*"
    shown "$*"
    [ "$DRY_RUN" = 1 ] && return 0
    "$@" 2>&1 | sed 's/^/     /'
}
# write_file DEST MODE < content   (as root; dry-run previews the content)
write_file() {
    local dest="$1" mode="$2" content
    content="$(cat)"
    LAST_CMD="write $dest"
    shown "write $dest  (mode $mode, $(printf '%s\n' "$content" | wc -l) lines)"
    if [ "$DRY_RUN" = 1 ]; then
        printf '%s\n' "$content" | sed "s/^/     ${DIM}${VL} /;s/\$/${RST}/"
        return 0
    fi
    printf '%s\n' "$content" | $SUDO tee "$dest" >/dev/null
    $SUDO chmod "$mode" "$dest"
}

banner() {
    local action="$1" os
    os="$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}") || echo Linux)"
    printf '\n %s%s%s pasteboard installer %s%s\n' "$DIM" "$TL" "$(repeat "$HL" 2)" "$(repeat "$HL" 30)" "$RST"
    printf ' %s%s%s %-8s %s\n' "$DIM" "$VL" "$RST" "os" "$os ($(uname -m))"
    printf ' %s%s%s %-8s %s\n' "$DIM" "$VL" "$RST" "action" "$action"
    printf ' %s%s%s %-8s %s\n' "$DIM" "$VL" "$RST" "prefix" "$PREFIX"
    if [ "$UNINSTALL" = 0 ] && [ "$BUILD_ONLY" = 0 ] && [ "$UPDATE" = 0 ]; then
        printf ' %s%s%s %-8s %s\n' "$DIM" "$VL" "$RST" "port" "$PORT$([ "$PORT_GIVEN" = 0 ] && echo ' (default)')"
    fi
    [ "$DRY_RUN" = 1 ] && printf ' %s%s%s %s%-8s nothing will be changed%s\n' "$DIM" "$VL" "$RST" "$YEL" "dry-run" "$RST"
    printf ' %s%s%s%s\n' "$DIM" "$BL" "$(repeat "$HL" 52)" "$RST"
}

# --------------------------------------------------------------- helpers ----
default_dev() { ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' || true; }
# Subnet of the interface that carries the default route (not docker0 & co).
lan_subnet() {
    local dev; dev="$(default_dev)"
    [ -n "$dev" ] && ip -o -4 route show scope link dev "$dev" 2>/dev/null | awk '$1 ~ /\// { print $1; exit }'
}
lan_ip() {
    local ip
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    echo "${ip:-localhost}"
}
conf_port() { # prints the port set in conf file $1 (nothing if absent)
    [ -r "$1" ] || return 0
    sed -nE 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$1" | tail -1
}
http_ok() { # GET / on 127.0.0.1:PORT returns 200
    ( exec 3<>"/dev/tcp/127.0.0.1/$1" || exit 1
      printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
      IFS= read -r -t 2 line <&3 || exit 1
      [[ "$line" == *" 200 "* ]] ) 2>/dev/null
}
listeners() { # listeners on TCP PORT (with process names when root)
    command -v ss >/dev/null 2>&1 || return 0
    if [ "$DRY_RUN" = 0 ]; then $SUDO ss -Hltnp "sport = :$1" 2>/dev/null; else ss -Hltn "sport = :$1" 2>/dev/null; fi
}
svc_active() { systemctl is-active --quiet pasteboard 2>/dev/null; }
ufw_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    $SUDO ufw status 2>/dev/null | grep -q "Status: active"
}
ufw_delete_ours() {
    local nums n
    nums="$($SUDO ufw status numbered 2>/dev/null | grep '# pasteboard' | sed -E 's/^\[ *([0-9]+)\].*/\1/' | sort -rn || true)"
    if [ -z "$nums" ]; then skip "no existing pasteboard ufw rules"; return 0; fi
    # Highest number first so the remaining numbers stay valid.
    for n in $nums; do run $SUDO ufw --force delete "$n"; done
}
file_hash() { [ -f "$1" ] || return 0; sha256sum "$1" | cut -c1-12; }
unit_content() { sed "s#/opt/pasteboard#$PREFIX#g" "$SCRIPT_DIR/deploy/pasteboard.service"; }

need_root() {
    if [ "$(id -u)" = 0 ]; then
        SUDO=""
        ok "running as root"
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        if [ "$DRY_RUN" = 1 ]; then
            ok "will use sudo for system changes"
        else
            info "System changes need root; sudo may ask for your password once."
            sudo -v || die "sudo authentication failed"
            ok "sudo ready"
        fi
    elif [ "$DRY_RUN" = 1 ]; then
        SUDO="sudo"
        warn "sudo not found; a real run must be started as root"
    else
        die "Root is required." "Re-run as root, or install sudo."
    fi
}

check_prefix() {
    # The prefix is substituted into the unit file and runs under ProtectHome.
    [[ "$PREFIX" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$PREFIX" != *..* ]] && [ "$PREFIX" != / ] \
        || die "invalid --prefix: '$PREFIX'" "Use an absolute path of letters, digits, '.', '_', '-' and '/' (no spaces)."
    case "$PREFIX/" in
        /home/*|/root/*|/run/user/*|/tmp/*)
            die "--prefix $PREFIX is not supported" \
                "The service runs as user '$SVC_USER' with ProtectHome/PrivateTmp, so it cannot use home or tmp dirs." \
                "Use a system path such as /opt/pasteboard or /srv/pasteboard." ;;
    esac
    ok "prefix $PREFIX"
}

# When started via `sudo ./install.sh`, build as the invoking user: root usually
# has no cargo on PATH, and a root build would leave target/ owned by root.
BUILD_AS=()
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    SUDO_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    BUILD_AS=(sudo -u "$SUDO_USER" -H env "PATH=$SUDO_HOME/.cargo/bin:$PATH")
fi
as_builder() { ${BUILD_AS[@]+"${BUILD_AS[@]}"} "$@"; }

check_cargo() {
    if as_builder sh -c 'command -v cargo' >/dev/null 2>&1; then
        local who=""
        [ ${#BUILD_AS[@]} -gt 0 ] && who=" (building as $SUDO_USER, not root)"
        ok "cargo: $(as_builder cargo --version 2>/dev/null)$who"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then warn "cargo not found (a real run would stop here)"; return 0; fi
    die "cargo (Rust) not found" \
        "This script does not install tooling. Install Rust, then re-run:" \
        "  sudo apt update && sudo apt install -y build-essential curl" \
        "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" \
        "  source \"\$HOME/.cargo/env\""
}

build() {
    local total n=0 start=$SECONDS status size
    total="$(grep -c '^\[\[package\]\]' "$SCRIPT_DIR/Cargo.lock" 2>/dev/null || echo 20)"
    local cmd=(cargo build --release --locked)
    LAST_CMD="${cmd[*]}"
    shown "cd $SCRIPT_DIR && ${cmd[*]}"
    if [ "$DRY_RUN" = 1 ]; then skip "dry-run: build skipped"; return 0; fi
    BUILD_LOG="$(mktemp)"
    set +e
    (cd "$SCRIPT_DIR" && as_builder "${cmd[@]}") 2>&1 | tee "$BUILD_LOG" | while IFS= read -r line; do
        case "$line" in
            *Compiling\ *)
                n=$((n + 1))
                name="$(awk '{print $2, $3}' <<<"$line")"
                if [ "$TTY" = 1 ]; then
                    printf '\r\e[K   %s %s%2d/%d%s  compiling %s' "$(bar "$n" "$total" 24)" "$DIM" "$n" "$total" "$RST" "$name"
                else
                    printf '     compiling %s (%d/%d)\n' "$name" "$n" "$total"
                fi ;;
            *warning:*) [ "$TTY" = 1 ] && printf '\r\e[K'; printf '     %s%s%s\n' "$YEL" "$line" "$RST" ;;
        esac
    done
    status=${PIPESTATUS[0]}
    set -e
    [ "$TTY" = 1 ] && printf '\r\e[K'
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "     --- last 25 lines of cargo output ---" >&2
        tail -n 25 "$BUILD_LOG" | sed 's/^/     /' >&2
        die "cargo build failed (exit $status)"
    fi
    printf '   %s %s%d/%d%s  done\n' "$(bar 1 1 24)" "$DIM" "$total" "$total" "$RST"
    size="$(du -h "$BIN" 2>/dev/null | cut -f1)"
    ok "built target/release/pasteboard (${size:-?}, $("$BIN" --version 2>/dev/null || echo '?')) in $((SECONDS - start))s"
}

# health_check PORT: wait for the unit to be active and answer HTTP 200.
health_check() {
    if [ "$DRY_RUN" = 1 ]; then
        shown "wait for: systemctl is-active pasteboard && GET http://127.0.0.1:$1/ = 200"
        return 0
    fi
    local i
    for i in $(seq 1 20); do
        if svc_active && http_ok "$1"; then
            ok "service active, http://127.0.0.1:$1/ answered 200"
            return 0
        fi
        sleep 0.25
    done
    if svc_active; then
        warn "service is active but did not answer on 127.0.0.1:$1 (is 'bind' set to a specific address?)"
        return 0
    fi
    printf '%s\n' "     --- journalctl -u pasteboard (last 20 lines) ---" >&2
    $SUDO journalctl -u pasteboard -n 20 --no-pager 2>&1 | sed 's/^/     /' >&2 || true
    die "pasteboard failed to start" "See the log above, fix the cause, then re-run this script."
}

summary() { # summary TITLE PORT
    if [ "$DRY_RUN" = 1 ]; then
        printf '\n %s%s%s dry run complete%s: nothing was changed\n' "$GRN" "$OK_S" "$BOLD" "$RST"
    else
        printf '\n %s%s%s %s%s\n' "$GRN" "$OK_S" "$BOLD" "$1" "$RST"
    fi
    if [ -n "${2:-}" ]; then
        info "open     ${BOLD}http://$(lan_ip):$2${RST}"
        info "config   $CONF   (then: sudo systemctl restart pasteboard)"
        info "logs     journalctl -u pasteboard -f"
        info "update   ./install.sh --update      remove   ./uninstall.sh"
    fi
    if [ ${#WARNINGS[@]} -gt 0 ]; then
        printf '\n %s%d warning(s):%s\n' "$YEL" "${#WARNINGS[@]}" "$RST"
        local w; for w in "${WARNINGS[@]}"; do printf '   %s%s %s%s\n' "$YEL" "$WARN_S" "$w" "$RST"; done
    fi
}

# ============================================================== uninstall ==
if [ "$UNINSTALL" = 1 ]; then
    TOTAL=5
    [ "$PURGE" = 1 ] && TOTAL=6
    banner "uninstall$([ "$PURGE" = 1 ] && echo ' + purge (deletes history and config)')"

    step "Checking permissions"
    need_root
    if [ "$PURGE" = 1 ]; then check_prefix; fi

    step "Stopping and disabling the service"
    if [ -f "$UNIT" ] || [ "$DRY_RUN" = 1 ]; then
        run $SUDO systemctl disable --now pasteboard
        did "service stopped and disabled"
    else
        skip "no systemd unit at $UNIT"
    fi

    step "Removing the systemd unit"
    if [ -f "$UNIT" ] || [ "$DRY_RUN" = 1 ]; then
        run $SUDO rm -f "$UNIT"
        run $SUDO systemctl daemon-reload
        did "unit removed"
    else
        skip "nothing to remove"
    fi

    step "Removing the binary"
    run $SUDO rm -f "$PREFIX/pasteboard"
    did "removed $PREFIX/pasteboard"

    step "Removing firewall rules"
    if ! command -v ufw >/dev/null 2>&1; then
        skip "ufw not installed"
    elif [ "$DRY_RUN" = 1 ] && [ "$(id -u)" != 0 ]; then
        shown "$SUDO ufw --force delete <each rule commented 'pasteboard'>"
    else
        ufw_delete_ours
    fi

    if [ "$PURGE" = 1 ]; then
        step "Purging history, config and the service user"
        entries="$( [ -f "$PREFIX/data/log.jsonl" ] && $SUDO grep -c '"op":"add"' "$PREFIX/data/log.jsonl" 2>/dev/null || echo 0)"
        info "this permanently deletes $PREFIX (about $entries history entries + uploaded files) and user '$SVC_USER'"
        if [ "$DRY_RUN" = 0 ] && [ "$YES" = 0 ]; then
            [ -t 0 ] || die "refusing to purge without confirmation" "Re-run in a terminal, or add --yes."
            printf '   %sType "delete" to confirm:%s ' "$YEL" "$RST"
            read -r answer
            [ "$answer" = delete ] || die "purge cancelled; nothing else was removed" "Service, unit, binary and firewall rules were already removed above."
        fi
        run $SUDO rm -rf "$PREFIX"
        if id "$SVC_USER" >/dev/null 2>&1 || [ "$DRY_RUN" = 1 ]; then run $SUDO userdel "$SVC_USER"; fi
        did "purged"
        summary "pasteboard uninstalled and purged"
    else
        summary "pasteboard uninstalled"
        info "kept   $CONF and $PREFIX/data   (delete too: ./uninstall.sh --purge)"
        info "kept   system user '$SVC_USER'"
    fi
    exit 0
fi

# ============================================================= build-only ==
if [ "$BUILD_ONLY" = 1 ]; then
    TOTAL=2
    banner "build only"
    step "Checking prerequisites"
    check_cargo
    step "Building release binary"
    build
    summary "build complete $ARROW $BIN"
    exit 0
fi

# ================================================================= update ==
if [ "$UPDATE" = 1 ]; then
    TOTAL=5
    banner "update existing install"

    step "Checking the existing install"
    check_prefix
    if [ ! -f "$UNIT" ] || [ ! -x "$PREFIX/pasteboard" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            warn "no install found at $PREFIX (a real run would stop here)"
        else
            die "pasteboard is not installed at $PREFIX" "Run ./install.sh first (or pass the --prefix you installed to)."
        fi
    else
        ok "installed: $("$PREFIX/pasteboard" --version 2>/dev/null || echo 'unknown version') at $PREFIX"
    fi
    EFFECTIVE_PORT="$(conf_port "$CONF")"
    EFFECTIVE_PORT="${EFFECTIVE_PORT:-9911}"
    [ "$PORT_GIVEN" = 1 ] && warn "--port is ignored by --update (edit $CONF to change the port)"
    check_cargo
    command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) is required on Linux."
    need_root

    step "Building release binary"
    build

    step "Replacing the binary"
    old_hash="$(file_hash "$PREFIX/pasteboard")"
    new_hash="$(file_hash "$BIN")"
    CHANGED=1
    if [ "$DRY_RUN" = 0 ] && [ -n "$old_hash" ] && [ "$old_hash" = "$new_hash" ]; then
        CHANGED=0
        ok "binary unchanged (sha256 $new_hash); nothing to replace"
    else
        info "sha256 ${old_hash:-none} $ARROW ${new_hash:-new build}"
        if svc_active || [ "$DRY_RUN" = 1 ]; then run $SUDO systemctl stop pasteboard; fi
        run $SUDO install -m 0755 "$BIN" "$PREFIX/pasteboard"
        did "binary replaced"
    fi
    if [ "$DRY_RUN" = 0 ] && [ -f "$UNIT" ] && [ "$(cat "$UNIT")" = "$(unit_content)" ]; then
        ok "systemd unit unchanged"
    else
        unit_content | write_file "$UNIT" 0644
        run $SUDO systemctl daemon-reload
        CHANGED=1
        did "systemd unit refreshed"
    fi

    step "Restarting the service"
    if [ "$CHANGED" = 0 ] && svc_active; then
        skip "nothing changed and the service is running; restart skipped"
    else
        run $SUDO systemctl restart pasteboard
        did "service restarted"
    fi

    step "Checking that it is up"
    health_check "$EFFECTIVE_PORT"
    summary "pasteboard is up to date ($("$PREFIX/pasteboard" --version 2>/dev/null || echo "$new_hash"))" "$EFFECTIVE_PORT"
    exit 0
fi

# ================================================================ install ==
TOTAL=9
banner "install / upgrade"

step "Checking prerequisites"
check_prefix
check_cargo
command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) is required on Linux."
ok "systemd: $(systemctl --version 2>/dev/null | head -1)"
need_root

EFFECTIVE_PORT="$PORT"
if [ -f "$CONF" ]; then
    EFFECTIVE_PORT="$(conf_port "$CONF")"
    EFFECTIVE_PORT="${EFFECTIVE_PORT:-9911}"
    if [ "$PORT_GIVEN" = 1 ] && [ "$EFFECTIVE_PORT" != "$PORT" ]; then
        warn "--port $PORT ignored: existing $CONF sets port $EFFECTIVE_PORT (edit it to change the port)"
    else
        ok "existing config found (port $EFFECTIVE_PORT)"
    fi
fi
in_use="$(listeners "$EFFECTIVE_PORT" || true)"
if [ -n "$in_use" ]; then
    if [[ "$in_use" == *'"pasteboard"'* ]] || { svc_active && [[ "$in_use" != *users:* ]]; }; then
        ok "port $EFFECTIVE_PORT is served by the current pasteboard (it will be restarted)"
    else
        die "port $EFFECTIVE_PORT is already in use" "$in_use" \
            "Stop that program, or install with --port N (or edit $CONF)."
    fi
else
    ok "port $EFFECTIVE_PORT is free"
fi

step "Building release binary"
build

step "Creating the service user"
if id "$SVC_USER" >/dev/null 2>&1; then
    ok "user '$SVC_USER' already exists (uid $(id -u "$SVC_USER"))"
else
    run $SUDO useradd --system --no-create-home --home-dir "$PREFIX" --shell /usr/sbin/nologin "$SVC_USER"
    did "created system user '$SVC_USER' (no login shell, no home)"
fi

step "Installing files"
if svc_active; then
    info "stopping the running service before replacing the binary"
    run $SUDO systemctl stop pasteboard
fi
run $SUDO install -d -m 0755 "$PREFIX"
run $SUDO install -d -m 0750 -o "$SVC_USER" -g "$SVC_USER" "$PREFIX/data"
run $SUDO install -m 0755 "$BIN" "$PREFIX/pasteboard"
did "binary  $PREFIX/pasteboard"
did "data    $PREFIX/data  (owner $SVC_USER, mode 0750)"

step "Writing configuration"
if [ -f "$CONF" ]; then
    ok "keeping existing $CONF (never overwritten)"
else
    sed "s/^port = .*/port = $PORT/" "$SCRIPT_DIR/pasteboard.conf" | write_file "$CONF" 0644
    did "wrote $CONF (port $PORT)"
fi
info "${DIM}note: the service may only write inside $PREFIX/data; keep data_dir there${RST}"

step "Installing the systemd unit"
if [ -f "$UNIT" ] && [ "$(cat "$UNIT")" = "$(unit_content)" ]; then
    ok "$UNIT is up to date"
else
    unit_content | write_file "$UNIT" 0644
    did "installed $UNIT"
fi
run $SUDO systemctl daemon-reload
run $SUDO systemctl enable pasteboard
did "enabled at boot"

step "Configuring the firewall"
SUBNET="$(lan_subnet || true)"
SUBNET="${SUBNET:-192.168.0.0/16}"
if ! command -v ufw >/dev/null 2>&1; then
    skip "ufw not installed; if you use another firewall, allow TCP $EFFECTIVE_PORT from $SUBNET"
elif [ "$DRY_RUN" = 1 ] && [ "$(id -u)" != 0 ]; then
    shown "$SUDO ufw status   (if active:)"
    shown "$SUDO ufw --force delete <old rules commented 'pasteboard'>"
    shown "$SUDO ufw allow from $SUBNET to any port $EFFECTIVE_PORT proto tcp comment pasteboard"
elif ufw_active; then
    info "allowing only the LAN subnet of $(default_dev || echo 'the default interface'): $SUBNET"
    ufw_delete_ours
    run $SUDO ufw allow from "$SUBNET" to any port "$EFFECTIVE_PORT" proto tcp comment pasteboard
    did "ufw: $SUBNET $ARROW tcp/$EFFECTIVE_PORT"
else
    skip "ufw is installed but inactive; no rule needed"
fi

step "Starting the service"
run $SUDO systemctl restart pasteboard
did "service (re)started"

step "Checking that it is up"
health_check "$EFFECTIVE_PORT"

summary "pasteboard is installed and running" "$EFFECTIVE_PORT"
