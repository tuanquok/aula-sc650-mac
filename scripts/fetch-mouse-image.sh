#!/bin/bash
# Optional: shows the real product picture of the mouse in the Buttons tab.
# The picture is the vendor's artwork, so it is not part of this repository. This script extracts it
# from the official "AULA-SC650 Setup.exe" that you downloaded yourself.
#
#   brew install innoextract
#   ./scripts/fetch-mouse-image.sh "/path/to/AULA-SC650 Setup.exe"
#
# Then run ./scripts/package.sh: the image is bundled into your local build only.
set -euo pipefail
cd "$(dirname "$0")/.."
INSTALLER="${1:?usage: $0 \"/path/to/AULA-SC650 Setup.exe\"}"
command -v innoextract >/dev/null || { echo "innoextract not found: brew install innoextract" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
innoextract -s -d "$TMP" "$INSTALLER" >/dev/null
mkdir -p Assets
cp "$TMP/app/res/skins/ms_1/mouse.png" Assets/mouse.png
echo "Saved Assets/mouse.png (personal use only, do not redistribute)."
