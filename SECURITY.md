# Security Policy

## Supported versions

Security fixes target the latest release on [GitHub Releases](https://github.com/ROSITO/OpenStream/releases).

## Scope

OpenStream downloads **clear** media streams the user can already access. It does **not**:

- bypass DRM (Widevine, FairPlay, PlayReady, CENC, `EXT-X-KEY`, …)
- decrypt protected content
- circumvent authentication or captchas

Please do not open issues asking for those capabilities.

## Reporting a vulnerability

Email the maintainer via the address on the [GitHub profile](https://github.com/ROSITO) (or open a **private** security advisory on the repo if enabled).

Include:

- OpenStream version / commit
- macOS version
- Steps to reproduce
- Impact (data leak, local code exec, unexpected network, …)

We aim to acknowledge reports within a few days.
