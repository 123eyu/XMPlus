#!/usr/bin/env bash
# Linux x64 host; no installation, signing, upload or release side effects.
set -euo pipefail
exec python3 "$(dirname "$0")/windows_native_build.py" "$@"
