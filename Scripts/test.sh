#!/bin/bash
# Runs the engine test suite.
#
# XCTest ships with Xcode, not with the Command Line Tools this project builds
# against, so `swift test` can't link here. The suites live in the app target
# and run through the same CLI that drives --render and --frames.
#
# Release only, deliberately. This machine runs Santa in Lockdown mode, which
# grants a locally built binary a transitive allow rule only for the release
# link; a debug binary is denied (reason=UNKNOWN) and SIGKILLed on exec — exit
# 137, no output, no crash log. Since `swift build`/`swift run` default to
# debug, running the tests that way looks like a mysterious hang or crash.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
if [[ "$CONFIG" == "debug" ]]; then
    echo "!! Debug binaries are blocked by Santa on this machine and will be" >&2
    echo "!! SIGKILLed on exec (exit 137). Run without CONFIG=debug." >&2
    exit 2
fi

swift build -c "$CONFIG" --product Recut
BIN="$(swift build -c "$CONFIG" --product Recut --show-bin-path 2>/dev/null | tail -1)/Recut"
exec "$BIN" --test
