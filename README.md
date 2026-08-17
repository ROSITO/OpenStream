# OpenStream

Application **macOS** native pour télécharger des flux vidéo **non protégés** (HLS, MPEG-DASH, MP4 progressif) depuis un navigateur intégré, puis les assembler en MP4.

> OpenStream **ne contourne pas** le DRM (Widevine, FairPlay, PlayReady) et ne déchiffre pas de flux chiffrés.

## Prérequis

- macOS 14 (Sonoma) ou plus récent
- [FFmpeg](https://ffmpeg.org/) — installé automatiquement par le script ci-dessous, ou via `brew install ffmpeg`
- [Homebrew](https://brew.sh) (pour FFmpeg)
- Xcode 16+ uniquement pour compiler depuis les sources

## Installation automatique

Une commande installe **FFmpeg**, copie **OpenStream.app** dans Applications, et retire la quarantaine Gatekeeper (plus besoin du clic droit → Ouvrir) :

```bash
curl -fsSL https://raw.githubusercontent.com/ROSITO/OpenStream/main/scripts/install.sh | bash
```

Si Homebrew n’est pas encore là : https://brew.sh

L’app peut aussi installer FFmpeg toute seule au premier lancement (bandeau jaune → **Installer FFmpeg**), tant que Homebrew est présent.

## Installation manuelle

La dernière version est dans [Releases](https://github.com/ROSITO/OpenStream/releases).

1. Téléchargez `OpenStream-*-macos.zip`
2. Décompressez et glissez `OpenStream.app` dans Applications
3. Si macOS bloque le lancement : **clic droit → Ouvrir** (signature ad hoc, pas encore notariée)

## Compiler

```bash
brew install ffmpeg
xcodegen generate
xcodebuild -scheme OpenStream -configuration Release -destination 'platform=macOS' build
```

L’app générée se trouve dans DerivedData / `build/`.

## Licence

Pas encore tranchée (MIT ou GPLv3). FFmpeg est invoqué comme binaire externe (`Process`), sans liaison statique.
