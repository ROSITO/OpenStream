# OpenStream

Application **macOS** native pour télécharger des flux vidéo **non protégés** (HLS, MPEG-DASH, MP4 progressif) depuis un navigateur intégré, puis les assembler en MP4.

CLI headless **`openstream-cli`** pour agents IA : détection, saison, digest **flix**, download/assemble — contrat dans [`OpenStreamCLI/README.md`](OpenStreamCLI/README.md).

> OpenStream **ne contourne pas** le DRM (Widevine, FairPlay, PlayReady) et ne déchiffre pas de flux chiffrés.

## Prérequis

- macOS 14 (Sonoma) ou plus récent
- Xcode 16+ pour compiler depuis les sources
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- FFmpeg **embarqué** (recommandé) via `./scripts/fetch-bundled-ffmpeg.sh` — Homebrew uniquement en secours

## Installation automatique (app)

```bash
curl -fsSL https://raw.githubusercontent.com/ROSITO/OpenStream/main/scripts/install.sh | bash
```

Installe la dernière release GitHub dans Applications (FFmpeg embarqué dans le bundle si présent dans la release).

## Installation manuelle (app)

La dernière version est dans [Releases](https://github.com/ROSITO/OpenStream/releases).

1. Téléchargez `OpenStream-*-macos.zip`
2. Décompressez et glissez `OpenStream.app` dans Applications
3. Si macOS bloque le lancement : **clic droit → Ouvrir** (signature ad hoc, pas encore notariée)

## Compiler

```bash
./scripts/fetch-bundled-ffmpeg.sh   # Helpers ffmpeg/ffprobe (non commités)
xcodegen generate
xcodebuild -scheme OpenStream -configuration Release -destination 'platform=macOS' build
xcodebuild -scheme OpenStreamCLI -configuration Release -destination 'platform=macOS' build
```

- App : DerivedData / `OpenStream.app`
- CLI : DerivedData / `openstream-cli` (+ `Helpers/` à côté)

## Navigateur intégré

Paramètres → **Navigateur** (défaut ON) : popups / pubs / alertes JS bloqués ; redirections auto **cross-site** silencieuses (bandeau, pas de modal). Voir D014 dans [`MEMORY.md`](MEMORY.md).

## CLI / agent IA

```bash
CLI="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/OpenStream-*/Build/Products/Release/openstream-cli | head -1)"

# URL média connue
"$CLI" download 'https://…/video.mp4' --json --referer 'https://…/watch' --out ~/Downloads/OpenStream

# Page → détecter un flux
"$CLI" fetch 'https://…/watch' --detect-only --json --timeout 60

# Saison par nom (favoris) ou URL page
"$CLI" season 'Tulsa King' --season 1 --json
"$CLI" season 'https://fs26.lol/index.php?newsid=…' --json --show 'Tulsa King' --season 1

# Digest nouveautés (RSS hubs favoris) — pas de download auto
"$CLI" flix bootstrap --json
"$CLI" flix digest --json --mark-seen
"$CLI" flix pick 1 --enqueue --json
```

Exports par défaut : `~/Downloads/OpenStream` (override avec `--out`).  
Playbook agent (JSON Lines, `flix`, `season`, exit codes) : **[`OpenStreamCLI/README.md`](OpenStreamCLI/README.md)**.

## Docs produit

| Doc | Rôle |
|-----|------|
| [`PRD_OpenStream.md`](PRD_OpenStream.md) | Vision / périmètre |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Modules et frontières |
| [`ROADMAP.md`](ROADMAP.md) | Phases |
| [`MEMORY.md`](MEMORY.md) | Décisions figées (D014 navigateur, D018 CLI, D019 flix…) |
| [`CLAUDE.md`](CLAUDE.md) | Règles agents |

## Licence

Pas encore tranchée (MIT ou GPLv3). FFmpeg est invoqué comme binaire externe (`Process`), sans liaison libav*.
