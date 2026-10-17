#!/usr/bin/env bash
# Télécharge des binaires FFmpeg/ffprobe **statiques** (macOS) et les place
# dans OpenStream/Resources/Helpers/ — indépendants de Homebrew.
#
# Source : https://ffmpeg.martin-riedl.de/ (release, signed)
# Usage  : ./scripts/fetch-bundled-ffmpeg.sh [--force]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/OpenStream/Resources/Helpers"
VENDOR_META="$ROOT/Vendor/ffmpeg"
BASE_URL="https://ffmpeg.martin-riedl.de/redirect/latest/macos"
CHANNEL="release"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "Usage: $0 [--force]" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "manque: $1" >&2; exit 1; }; }
need curl
need ditto
need lipo
need shasum
need codesign

if [[ "$FORCE" -eq 0 && -x "$OUT/ffmpeg" && -x "$OUT/ffprobe" ]]; then
  echo "→ Helpers déjà présents (passe --force pour re-télécharger)"
  "$OUT/ffmpeg" -version 2>&1 | head -1 || true
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch_one() {
  local arch="$1" name="$2" dest="$3"
  local url="$BASE_URL/$arch/$CHANNEL/${name}.zip"
  local zip="$TMP/${name}-${arch}.zip"
  echo "→ $url"
  curl -fL --progress-bar -o "$zip" "$url"
  ditto -x -k "$zip" "$TMP/${name}-${arch}"
  # Le zip contient souvent un binaire à la racine ou dans un sous-dossier.
  local found
  found="$(find "$TMP/${name}-${arch}" -type f -name "$name" | head -n 1)"
  if [[ -z "$found" ]]; then
    echo "binaire $name introuvable dans l’archive $arch" >&2
    exit 1
  fi
  cp "$found" "$dest"
  chmod +x "$dest"
}

mkdir -p "$TMP/arm64" "$TMP/x86_64" "$OUT" "$VENDOR_META"

fetch_one "arm64" "ffmpeg"  "$TMP/arm64/ffmpeg"
fetch_one "arm64" "ffprobe" "$TMP/arm64/ffprobe"
fetch_one "amd64" "ffmpeg"  "$TMP/x86_64/ffmpeg"
fetch_one "amd64" "ffprobe" "$TMP/x86_64/ffprobe"

echo "→ lipo universal…"
lipo -create "$TMP/arm64/ffmpeg"  "$TMP/x86_64/ffmpeg"  -output "$OUT/ffmpeg"
lipo -create "$TMP/arm64/ffprobe" "$TMP/x86_64/ffprobe" -output "$OUT/ffprobe"
chmod +x "$OUT/ffmpeg" "$OUT/ffprobe"

# Lever quarantaine + ad-hoc sign (dev / distribution locale).
xattr -cr "$OUT/ffmpeg" "$OUT/ffprobe" 2>/dev/null || true
codesign -s - --force --timestamp=none "$OUT/ffmpeg"
codesign -s - --force --timestamp=none "$OUT/ffprobe"

VER_LINE="$("$OUT/ffmpeg" -version 2>&1 | head -1)"
SHA_FF="$(shasum -a 256 "$OUT/ffmpeg" | awk '{print $1}')"
SHA_FP="$(shasum -a 256 "$OUT/ffprobe" | awk '{print $1}')"
DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$VENDOR_META/VERSION" <<EOF
source=https://ffmpeg.martin-riedl.de/
channel=${CHANNEL}
fetched_at=${DATE_UTC}
ffmpeg_version_line=${VER_LINE}
ffmpeg_sha256=${SHA_FF}
ffprobe_sha256=${SHA_FP}
universal=arm64+x86_64
EOF

cat > "$VENDOR_META/README.md" <<'EOF'
# FFmpeg embarqué (OpenStream)

Binaires **statiques** universels (`ffmpeg` / `ffprobe`) placés dans
`OpenStream/Resources/Helpers/` par `scripts/fetch-bundled-ffmpeg.sh`.

- Indépendants de Homebrew / du PATH système
- Source des builds : https://ffmpeg.martin-riedl.de/ (release macOS)
- Licence FFmpeg : LGPL/GPL selon codecs du build — voir https://ffmpeg.org/legal.html
  OpenStream invoque ces binaires via `Process` (pas de linking libav*).

Les binaires ne sont **pas** commités (poids). Avant build / release :

```bash
./scripts/fetch-bundled-ffmpeg.sh
```

`VERSION` enregistre le hash SHA-256 du dernier fetch.
EOF

echo "→ OK : $OUT"
echo "   $VER_LINE"
lipo -info "$OUT/ffmpeg"
