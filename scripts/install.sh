#!/usr/bin/env bash
# Installe OpenStream.app dans /Applications, FFmpeg via Homebrew, et lève la quarantaine Gatekeeper.
set -euo pipefail

REPO="ROSITO/OpenStream"
DEST="/Applications/OpenStream.app"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "OpenStream est une app macOS." >&2
  exit 1
fi

if ! need_cmd brew; then
  echo "Homebrew est requis pour FFmpeg." >&2
  echo "Installez-le : https://brew.sh" >&2
  echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
  exit 1
fi

if ! need_cmd ffmpeg; then
  echo "→ Installation de FFmpeg…"
  brew install ffmpeg
else
  echo "→ FFmpeg déjà présent : $(command -v ffmpeg)"
fi

if ! need_cmd curl || ! need_cmd python3; then
  echo "curl et python3 sont requis." >&2
  exit 1
fi

echo "→ Téléchargement de la dernière release GitHub…"
API="https://api.github.com/repos/${REPO}/releases/latest"
ZIP_URL="$(curl -fsSL "$API" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assets = data.get("assets") or []
for asset in assets:
    name = asset.get("name") or ""
    if name.endswith(".zip"):
        print(asset["browser_download_url"])
        break
else:
    sys.exit("Aucun zip dans la dernière release.")
')"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/OpenStream.zip"
curl -fL --progress-bar -o "$ZIP" "$ZIP_URL"
ditto -x -k "$ZIP" "$TMP"

APP="$(find "$TMP" -name "OpenStream.app" -type d -maxdepth 3 | head -n 1)"
if [[ -z "$APP" ]]; then
  echo "OpenStream.app introuvable dans l’archive." >&2
  exit 1
fi

echo "→ Copie vers $DEST"
rm -rf "$DEST"
ditto "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

echo "OpenStream est dans Applications. Vous pouvez lancer :"
echo "  open -a OpenStream"
