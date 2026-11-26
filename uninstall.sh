#!/usr/bin/env bash
# Uninstall pasteboard (Linux, or Windows via Git Bash). Wrapper around
# `install.sh --uninstall`; accepts --purge, --yes, --prefix DIR, --dry-run.
#   ./uninstall.sh            remove service, firewall rule and binary; keep history
#   ./uninstall.sh --purge    also delete history, config and the service user
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" --uninstall "$@"
