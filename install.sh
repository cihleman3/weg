#!/usr/bin/env bash
# Installs weg from Git Bash. weg runs on Windows only; this runs install.ps1.
set -euo pipefail
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ;;
  *) echo "weg runs on Windows only." >&2; exit 1 ;;
esac
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$dir/install.ps1")"
