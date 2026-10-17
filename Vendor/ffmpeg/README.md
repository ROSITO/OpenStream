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
