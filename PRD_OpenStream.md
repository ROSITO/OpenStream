# PRD.md
# OpenStream – Product Requirements Document

> Version: 1.0
> Statut: Draft
> Cible: Agent de développement (Codex / Claude Code / Cursor)

---

# 1. Vision

OpenStream est une application macOS open source permettant de télécharger des flux vidéo **non protégés par DRM** accessibles à l'utilisateur.

Le logiciel intègre un navigateur WebKit, détecte automatiquement les flux HLS, MPEG-DASH et MP4 progressifs, puis les télécharge avant de les assembler via FFmpeg lorsque cela est nécessaire.

Le projet ne vise pas à contourner des DRM (Widevine, FairPlay, PlayReady), des protections d'accès ou des mécanismes de sécurité.

> **Note développement (D007) :** la *gate* produit (détection + refus des flux chiffrés) est reportée à la fin du parcours (release open source publique). La version de test se concentre sur les flux clairs. Le contournement / déchiffrement reste interdit à tout moment.

---

# 2. Objectifs

- Interface SwiftUI moderne
- Architecture modulaire
- Système de plugins
- Détection automatique des flux
- Téléchargements parallèles
- Gestion des playlists HLS
- Gestion DASH
- Historique
- Reprise après interruption
- Tests automatisés

# 3. Hors périmètre

- Contournement de DRM
- Extraction de contenus chiffrés
- Contournement d'authentification
- Déchiffrement de flux protégés

# 4. Architecture

UI (SwiftUI)

↓

Application Core

↓

Browser Engine (WKWebView)

↓

Network Observer

↓

Media Detector

↓

Manifest Parser

↓

Download Manager

↓

FFmpeg Pipeline

↓

Exporter

# 5. Modules

- UI
- Browser
- Session
- Cookie Manager
- Network Observer
- Extractor Engine
- HLS Parser
- DASH Parser
- Metadata
- Download Queue
- FFmpeg Wrapper
- Preferences
- History
- Logging
- Plugin Manager

# 6. Technologies

- Swift 6
- SwiftUI
- WKWebView
- URLSession
- Async/Await
- SQLite
- FFmpeg
- libavformat
- libavcodec
- os_log

# 7. Roadmap

MVP
- Navigation
- Détection MP4
- Détection HLS
- Téléchargement
- Export

V2
- DASH
- Sous-titres
- Audio multiples
- Plugins

V3
- Historique
- Automatisation
- Batch
- API

# 8. Tests

- Tests unitaires
- Tests d'intégration
- Tests UI
- Tests HLS
- Tests DASH
- Reprise réseau
- Téléchargement parallèle

# 9. Licence

MIT ou GPLv3 selon l'orientation communautaire.

---

## Notes

Ce document constitue la base du développement. Une version complète de niveau industriel comprendrait un développement détaillé de chaque module (API, diagrammes UML, modèles de données, backlog, scénarios UX, spécifications de plugins, matrices de tests, etc.) et dépasserait facilement 80 à 100 pages.
