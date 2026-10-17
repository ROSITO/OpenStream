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

`openstream-cli` est conçu pour être **piloté par un agent** (chat, cron, bot) : l’agent route l’intention NL vers une commande, lit le JSON + exit code, et confirme les chemins à l’utilisateur. Il ne réimplémente pas favoris / RSS / download.

Playbook agentique (contrat, routage NL → commande, boucle digest → pick, règles dures) : **[`OpenStreamCLI/README.md` — Utilisation agentique](OpenStreamCLI/README.md#utilisation-agentique)**.

```bash
CLI="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/OpenStream-*/Build/Products/Release/openstream-cli | head -1)"
# ou: openstream-cli  si installé dans ~/.local/bin

# URL média connue
"$CLI" download 'https://cdn.example/video.mp4' --json --referer 'https://watch.example/ep' --out ~/Downloads/OpenStream

# Page → détecter un flux
"$CLI" fetch 'https://watch.example/ep' --detect-only --json --timeout 60

# Saison par nom (favoris) — l’agent ne demande pas l’URL
"$CLI" season 'Example Show' --season 1 --auto-download --json

# Digest nouveautés → l’utilisateur choisit 1 / 1,3
"$CLI" flix digest --json --mark-seen
"$CLI" flix pick 1 --enqueue --json
```

Exports par défaut : `~/Downloads/OpenStream` (`--out` pour override).

## Docs produit

| Doc | Rôle |
|-----|------|
| [`PRD_OpenStream.md`](PRD_OpenStream.md) | Vision / périmètre |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Modules et frontières |
| [`ROADMAP.md`](ROADMAP.md) | Phases |
| [`MEMORY.md`](MEMORY.md) | Décisions figées (D014 navigateur, D018 CLI, D019 flix…) |
| [`CLAUDE.md`](CLAUDE.md) | Règles agents |

## Contribuer / sécurité

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — build, PRs, règles
- [`SECURITY.md`](SECURITY.md) — signaler une faille (pas de demandes DRM)

## Licence

[MIT](LICENSE). FFmpeg est invoqué comme binaire externe (`Process`), sans liaison libav* (LGPL FFmpeg reste séparée).
