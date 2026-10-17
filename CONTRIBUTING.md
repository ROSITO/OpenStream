# Contributing to OpenStream

Thanks for your interest. OpenStream is a **macOS** app + headless CLI for downloading **non-DRM** video streams (HLS / MPEG-DASH / progressive MP4).

## Ground rules

- Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- No DRM circumvention, no decryption of protected streams, no auth bypass.
- Prefer small, focused PRs that match `ARCHITECTURE.md` module boundaries.
- Read `MEMORY.md` before non-trivial design changes.

## Setup

```bash
brew install xcodegen   # if needed
./scripts/fetch-bundled-ffmpeg.sh
xcodegen generate
open OpenStream.xcodeproj
```

Build CLI:

```bash
xcodebuild -scheme OpenStreamCLI -configuration Debug -destination 'platform=macOS' build
```

Agent contract: [`OpenStreamCLI/README.md`](OpenStreamCLI/README.md).

## Pull requests

1. Describe *why* (user/agent impact), not only *what*.
2. Include tests when you change Core / parsers / flix / season logic.
3. Keep public docs free of real streaming-site hostnames (use `example` placeholders).

## Licence

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
