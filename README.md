# OpenStream

Application **macOS** native pour télécharger des flux vidéo **non protégés** (HLS, MPEG-DASH, MP4 progressif) depuis un navigateur intégré, puis les assembler en MP4.

> OpenStream **ne contourne pas** le DRM (Widevine, FairPlay, PlayReady) et ne déchiffre pas de flux chiffrés.

## Prérequis

- macOS 14 (Sonoma) ou plus récent
- [FFmpeg](https://ffmpeg.org/) installé (Homebrew : `brew install ffmpeg`)
- Xcode 16+ pour compiler depuis les sources

## Télécharger

La dernière version est dans [Releases](https://github.com/ROSITO/OpenStream/releases).

1. Téléchargez `OpenStream-*-macos.zip`
2. Décompressez et glissez `OpenStream.app` dans Applications
3. Au premier lancement, ouvrez l’app via **clic droit → Ouvrir** (signature ad hoc, Gatekeeper)

## Compiler

```bash
brew install ffmpeg
xcodegen generate
xcodebuild -scheme OpenStream -configuration Release -destination 'platform=macOS' build
```

L’app générée se trouve dans DerivedData / `build/`.

## Licence

Pas encore tranchée (MIT ou GPLv3). FFmpeg est invoqué comme binaire externe (`Process`), sans liaison statique.
