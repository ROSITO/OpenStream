# ARCHITECTURE.md — OpenStream

Contrats techniques et frontières de modules.  
Complète le PRD §4–§5. En cas de doute sur le *quoi*, voir le PRD ; sur le *comment découper*, ce fichier gagne.

---

## Vue d'ensemble

```
┌─────────────────────────────────────────────────────────┐
│  UI (SwiftUI)                                           │
│  BrowserView · DetectedMediaList · DownloadQueueView    │
│  Preferences · History                                  │
└───────────────────────────┬─────────────────────────────┘
                            │ Observation / Intent
┌───────────────────────────▼─────────────────────────────┐
│  Application Core                                       │
│  AppState · Coordinators · DI container                 │
└─┬───────────────┬───────────────────┬───────────────────┘
  │               │                   │
  ▼               ▼                   ▼
Browser        Session            Preferences
(WKWebView)    Cookie Manager     Logging
  │               │
  └───────┬───────┘
          ▼
   Network Observer  ──►  Media Detector  ──►  Manifest Parser
                                                      │
                         ┌────────────────────────────┤
                         ▼                            ▼
                   HLS Parser                   DASH Parser (V2)
                         │
                         ▼
                 Download Queue / Manager
                         │
                         ▼
                  FFmpeg Wrapper
                         │
                         ▼
                     Exporter
                         │
                         ▼
              History / Metadata (SQLite)
```

Flux de données principal : **navigation → observation réseau → détection → parse manifeste → file de téléchargement → assemblage → export → historique**.

---

## Principes

1. **Dépendances descendantes uniquement.** UI ne connaît pas FFmpeg. Parsers ne connaissent pas SwiftUI.
2. **Protocols aux frontières.** Chaque module expose un protocole public minimal ; l'implémentation est interne au module / target.
3. **Actors pour l'état partagé mutable** (queue, observer, cookie bridge).
4. **Événements plutôt que callbacks croisés.** Le Core agrège des AsyncStream / Combine-like publishers pour l'UI.
5. **DRM (phased).** Version test/MVP : pas de gate DRM (D007) — parsers peuvent ignorer protection. Release publique (Phase 9) : Detector/Parser remontent `MediaProtection.drm` ; le Core refuse et notifie l'UI. Jamais de contournement.

---

## Modules

### UI
- **Rôle :** présentation SwiftUI, navigation, actions utilisateur.
- **Ne fait pas :** parsing, I/O réseau média, appels FFmpeg, SQL.
- **Entrées :** `AppState` / view models injectés.
- **Sorties :** intents (`navigate`, `enqueueDownload`, `cancel`, `export`).

### Application Core
- **Rôle :** orchestration, DI, cycle de vie, règles métier transverses (choix qualité ; refus DRM à partir de la Phase 9).
- **Possède :** coordinators (Browser, Download, Export).

### Browser
- **Rôle :** encapsuler `WKWebView` (navigation, historique page, user agent).
- **Expose :** `BrowserNavigating`, événements de navigation.
- **Ne fait pas :** détection média (délégation à Network Observer / scripts injectés).

### Session / Cookie Manager
- **Rôle :** synchroniser cookies et headers pertinents entre WKWebView et URLSession de téléchargement.
- **Expose :** `CookieProviding`, `SessionCredentialSnapshot`.

### Network Observer
- **Rôle :** capturer les URLs / réponses candidates (m3u8, mpd, mp4, content-type média).
- **Expose :** `AsyncStream<NetworkMediaCandidate>`.
- **Contrainte :** solution technique à valider en Phase 1 (voir MEMORY pièges WebKit).

### Media Detector
- **Rôle :** classifier les candidats (`progressive`, `hls`, `dash`, `unknown`).
- **Phase 9 :** ajouter `protected` / `MediaProtection.drm` quand la gate est réintégrée.
- **Expose :** `MediaDetecting` → `[DetectedMedia]`.

### Manifest Parser
- **Rôle :** façade ; délègue à HLS / DASH.
- **Expose :** `ManifestParsing`.

### HLS Parser
- **Rôle :** master/media playlists, variantes, segments, init map.
- **MVP / test :** pas de gate sur `#EXT-X-KEY` (D007).
- **Phase 9 :** détection `#EXT-X-KEY` → `MediaProtection.drm`.
- **MVP :** VOD avec `#EXT-X-ENDLIST`.

### DASH Parser (V2)
- **Rôle :** MPD, Representations, SegmentTemplate/List.
- **Phase 9 :** `ContentProtection` → refuse.

### Metadata
- **Rôle :** titre, durée estimée, codecs, résolution, source URL, timestamp détection.

### Download Queue
- **Rôle :** file priorisée, parallélisme borné, reprise, progression, annulation.
- **Expose :** `DownloadManaging` (actor recommandé).
- **Persistance :** état job en SQLite pour reprise après interruption.

### FFmpeg Wrapper
- **Rôle :** remux / concat segments → conteneur de sortie ; unique point de liaison libav*.
- **Expose :** `MediaProcessing` (async, progress, cancellation).

### Exporter
- **Rôle :** destination fichier, nommage, conflit de noms, révélation dans Finder.
- **Formats MVP :** MP4 (remux privilégié).

### Preferences
- **Rôle :** dossier de téléchargement, concurrence max, qualité par défaut, user agent.

### Bookmarks (favoris)
- **Rôle :** mémoriser des pages / sites utiles pour retélécharger (`BookmarkStore`, JSON Application Support).
- **UI :** étoile barre d’adresse + menu + sheet gestion.

### History
- **Rôle :** enregistrements des exports réussis / échecs (`DownloadHistoryStore`, JSON). Recherche + re-download.
- **UI :** sheet Historique (toolbar).

### Productivity (Phase 8)
- **Batch :** sheet multi-URLs — médias enfilés, pages ouvertes en séquence.
- **Automation :** toggles réglages auto-enqueue par `ManifestKind`.
- **CLI :** outil `openstream-cli` → `Application Support/OpenStream/inbox/` ; `LocalCommandServer` dans l’app.

### Logging
- **Rôle :** `os.Logger`, catégories par module (`browser`, `network`, `hls`, `download`, `ffmpeg`).

### Plugin Manager (V2)
- **Rôle :** registre de plugins conformes à `OpenStreamPluginAPI` (v1) ; `MediaURLHintPlugin` étend les heuristiques URL.
- **Livré :** `PluginManager` + `ExampleMediaHintPlugin` + validation `*.openstreamplugin` (Info.plist). Chargement de code tiers dynamique limité par sandbox.

---

## Modèles de domaine (contrats MVP)

```swift
enum ManifestKind: Sendable { case progressive, hls, dash }

enum MediaProtection: Sendable {
    case none
    case drm(reason: String) // Phase 9 : refuse download ; optionnel / stub en version test
}

struct DetectedMedia: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let kind: ManifestKind
    let protection: MediaProtection // MVP test : toujours `.none` suffit
    let suggestedTitle: String?
    let pageURL: URL?
}

struct MediaVariant: Identifiable, Sendable {
    let id: UUID
    let bandwidth: Int?
    let resolution: CGSize?
    let codecs: String?
    let playlistURL: URL // or progressive media URL
}

struct DownloadJob: Identifiable, Sendable {
    let id: UUID
    var media: DetectedMedia
    var selectedVariant: MediaVariant
    var state: DownloadState
    var destination: URL?
}

enum DownloadState: Sendable {
    case queued
    case downloading(progress: Double)
    case processing // ffmpeg
    case completed(URL)
    case failed(message: String)
    case cancelled
}
```

*(Signatures indicatives — à placer dans un target `OpenStreamCore`.)*

---

## Découpage targets (proposition)

| Target | Contenu |
|--------|---------|
| `OpenStream` | App SwiftUI, entry point |
| `OpenStreamCore` | Protocols, modèles, coordinators |
| `OpenStreamBrowser` | WKWebView wrapper, cookie bridge |
| `OpenStreamMedia` | Detector, HLS/DASH parsers |
| `OpenStreamDownload` | Queue, URLSession downloaders |
| `OpenStreamFFmpeg` | Wrapper isolé |
| `OpenStreamPersistence` | SQLite history / job store |
| `OpenStreamTests` | Unit + integration |

Le monolithe single-target est acceptable **uniquement** le temps de la Phase 0–1 ; migrer vers ces targets avant la fin du MVP.

---

## Stratégie tests

| Couche | Quoi |
|--------|------|
| Unit | Parsers HLS (fixtures m3u8), Detector classification, Queue ordering / resume |
| Integration | Cookie sync Browser→Session, download segments mock HTTP, FFmpeg remux sample |
| UI | Navigation basique, enqueue depuis liste détectée (snapshots / UI tests ciblés) |

Fixtures : `Tests/Fixtures/hls/…`, `dash/…`, `progressive/…`.  
Aucun test ne doit nécessiter un vrai service DRM ou un contournement.

---

## Sécurité & sandbox

- App Sandbox macOS : network client, read/write user-selected downloads folder (ou bookmark sécurité).
- Pas d'exécution de scripts shell arbitraires ; FFmpeg via API Process contrôlée ou liaison native.
- Validation des URLs (http/https uniquement pour médias).

---

## Évolutivité plugins (V2)

Un plugin conforme doit implémenter au moins :

- `MediaDetecting` et/ou
- `ManifestParsing`

Chargement : à définir (in-process bundles signés). Pas de plugins non sandboxed au runtime.
