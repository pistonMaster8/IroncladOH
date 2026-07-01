#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cmake --preset server-debug
cmake --build --preset server-debug --target IroncladOHServer
"$repo_root/build/server-debug/bin/IroncladOHServer" --port 7777 --dev --verbose
