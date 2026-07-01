#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

cmake --preset xcode-macos
cmake --build --preset xcode-macos --config Debug --target IroncladOH
open "$repo_root/build/xcode/bin/Debug/IroncladOH.app"
