#!/bin/bash
# Runs the Recut CLI, e.g.
#
#   ./Scripts/run.sh --render ~/Movies/Recut/Something.recut out.mp4 1920 60
#   ./Scripts/run.sh --frames ~/Movies/Recut/Something.recut ./frames 1.5,6.3
#
# Use this rather than `swift run Recut`: `swift run` builds debug, and debug
# binaries are denied by Santa on this machine (see Scripts/test.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build -c release --product Recut
BIN="$(swift build -c release --product Recut --show-bin-path 2>/dev/null | tail -1)/Recut"
exec "$BIN" "$@"
