# MEMORY.md — OpenStream

Mémoire projet : décisions figées, contraintes, et pièges.  
**À lire avant toute décision d'archi.**  
**À mettre à jour** dès qu'une décision structurante est prise.

---

## État actuel

| Champ | Valeur |
|-------|--------|
| Phase roadmap | Phase 5 ✅ — prochaine : Phase 6 (DASH / audio / subs) |
| Code applicatif | MVP durci + panneau Paramètres (dossier, proxy, qualité) |
| Licence | Non tranchée (MIT vs GPLv3) |
| Bundle ID | `app.openstream.OpenStream` |
| Nom package / target | OpenStream (mono-target) |
| macOS min | 14.0 |
| Génération projet | XcodeGen (`project.yml` → `OpenStream.xcodeproj`) |

---

## Décisions

### D001 — Périmètre DRM (intention produit)
**Décision :** OpenStream ne contourne aucun DRM et ne déchiffre pas de flux protégés. Pour la **release open source publique**, les flux chiffrés seront détectés et refusés avec un message utilisateur.  
**Date :** 2026-07-29  
**Source :** PRD §1, §3  
**Amendement :** voir D007 (report de la gate en version de test)

### D007 — Gate DRM reportée (version de test)
**Décision :** En version de test / MVP interne, on **n'implémente pas** la détection/refus DRM (`EXT-X-KEY`, `ContentProtection`, messaging UI). Objectif : simplicité de mise en œuvre sur flux clairs et fixtures. La gate complète est intégrée **en fin de parcours**, avant déploiement open source public (ROADMAP Phase 9).  
**Toujours interdit :** tout code de contournement ou de déchiffrement DRM.  
**Date :** 2026-07-29  
**Source :** décision produit (session échafaudage)

### D002 — Stack
**Décision :** Swift 6 + SwiftUI + WKWebView + URLSession + SQLite + FFmpeg (libavformat/libavcodec).  
**Date :** 2026-07-29  
**Source :** PRD §6

### D003 — Pipeline unidirectionnel
**Décision :** Architecture en couches descendantes (voir `ARCHITECTURE.md`). Pas de dépendances remontantes.  
**Date :** 2026-07-29  
**Source :** PRD §4

### D004 — Plugins différés
**Décision :** Le Plugin Manager est prévu en V2. Le MVP expose déjà des `protocol` stables (Detector, Parser, Downloader) pour éviter un refactor massif.  
**Date :** 2026-07-29  
**Source :** ROADMAP + anticipation minimale

### D005 — FFmpeg via wrapper isolé
**Décision :** Tout accès FFmpeg passe par un module `FFmpegWrapper` unique. Aucun autre module ne lie directement les libs.  
**Date :** 2026-07-29

### D008 — Technique Network Observer (Phase 1)
**Décision :** observation hybride —
1. `WKNavigationDelegate` (`decidePolicyFor` action/response) pour navigations document / réponses média ;
2. Script JS injecté (`atDocumentStart`) : Resource Timing + hooks `fetch` / `XMLHttpRequest` / éléments `video|audio|source`, relayé via `WKScriptMessageHandler` (`openstreamMedia`).
**Pourquoi :** WKWebView n’expose pas un proxy HTTP complet ; cette approche suffit pour détecter `.m3u8` / `.mp4` sur beaucoup de players web sans API privée.
**Limites :** workers isolés, MediaSource buffered opaque, et certains players obfuscated peuvent échapper — à réévaluer en Phase 2/5 si besoin.
**Date :** 2026-07-29

### D009 — Bundle ID & déploiement
**Décision :** `app.openstream.OpenStream`, macOS 14.0+, Swift 6, génération via XcodeGen.
**Date :** 2026-07-29

### D011 — Paramètres réseau
**Décision :** le navigateur WKWebView suit le VPN/proxy **système**. Un proxy HTTP/SOCKS5 optionnel s’applique uniquement aux `URLSession` de détection/téléchargement.  
**Date :** 2026-07-29

### D012 — Licence (en attente)
**Décision provisoire :** pas de fichier `LICENSE` tant que MIT vs GPLv3 n’est pas tranché. FFmpeg reste un binaire externe (LGPL) invoqué par Process — pas de linking statique (compatible avec MIT ou GPL côté app, selon distribution du binaire).  
**Date :** 2026-07-29

**Décision :** pour le MVP/test, FFmpeg est invoqué via `Process` (`/opt/homebrew/bin/ffmpeg` ou PATH), pas de liaison libavformat/libavcodec. Remux `-c copy` + concat demuxer pour HLS MPEG-TS ; fallback sans `aac_adtstoasc`.  
**Stockage :** segments temporaires dans `~/Downloads/OpenStream/.parts/<jobId>/`, MP4 final dans `~/Downloads/OpenStream/`, **segments supprimés après assemblage réussi**. Pas de dossier Exports séparé.  
**Pourquoi :** simplicité, compatibilité LGPL plus simple (pas de linking statique). XCFramework embarqué possible plus tard.  
**Date :** 2026-07-29


---

## Ouvert / à trancher

- [ ] Licence MIT vs GPLv3 (impact si FFmpeg lié dynamiquement vs statiquement — vérifier compatibilité LGPL FFmpeg)
- [x] Distribution FFmpeg : Homebrew (script `scripts/install.sh` + bouton in-app) ; pas de binaire embarqué
- [ ] Bundle identifier — **tranché :** `app.openstream.OpenStream` (D009)
- [ ] Stratégie App Sandbox + entitlements réseau / downloads folder — **sandbox ON** (network client + downloads + user-selected R/W) ; à valider en usage réel
- [ ] Format d'export MVP : MP4 uniquement, ou MKV aussi
- [ ] Qualité HLS par défaut : meilleure disponible vs choix utilisateur dès le MVP

---

## Pièges connus

### WebKit / réseau
- `WKWebView` ne expose pas nativement tout le trafic HTTP comme un proxy. Il faudra probablement combiner `WKURLSchemeHandler` (limité), observation via `WKScriptMessageHandler` + hooks JS, et/ou `URLProtocol` / instrumentation côté session custom. **À prototyper tôt (Phase 1).**
- Les cookies de `WKHTTPCookieStore` doivent être synchronisés vers `URLSession` pour que les téléchargements authentifiés fonctionnent.

### HLS
- Playlists master vs media : toujours résoudre la variante choisie avant de télécharger les segments.
- Live vs VOD : le MVP cible **VOD / playlists finies** (`#EXT-X-ENDLIST`). Live en continu est hors MVP.
- `EXT-X-MAP` (init segment fMP4) : à gérer dès le support fMP4 HLS, sinon fichiers incomplets.
- `#EXT-X-KEY` / DRM : **ignoré en version test** (D007) ; **refus obligatoire** avant release publique (D001, Phase 9). Ne pas construire de déchiffrement « en attendant ».

### DASH
- Phase 6 : `DASHParser` (SegmentList / SegmentTemplate / BaseURL). Audio DASH auto-inclus si une seule piste ; sinon sheet. Subs en sidecar `.vtt`. Pas de gate DRM (Phase 9).

### FFmpeg
- Remux (copy) vs re-encode : préférer remux (`-c copy`) quand les codecs sont compatibles conteneur.
- Chemins avec espaces / Unicode : toujours passer des URL file ou arguments correctement quotés via Process API typé, pas de shell string.

### Concurrency
- La download queue et le network observer sont des candidats naturels à `actor`.
- Ne pas bloquer le MainActor avec du parsing ou de l'I/O FFmpeg.

---

## Journal (court)

| Date | Note |
|------|------|
| 2026-07-29 | Création CLAUDE.md, MEMORY.md, ARCHITECTURE.md, ROADMAP.md à partir du PRD draft |
| 2026-07-29 | D007 : gate DRM reportée à la Phase 9 (release publique) ; version test sans détection/refus |
| 2026-07-29 | Phase 0+1 : XcodeGen app, browser, CookieBridge, NetworkObserver (D008), tests heuristics |
| 2026-07-29 | Phase 2 : MediaDetector, HLSParser (master/media/fMP4), MediaCatalog, UI médias classifiés, 11 tests |
| 2026-07-29 | Fix : MediaCatalog branché sur tous les candidats (xhr/fetch), pas seulement navigation |
| 2026-07-29 | Phase 3 : DownloadQueue, SQLite jobs, HLS/progressive download, UI progress/cancel/resume |
| 2026-07-29 | Phase 5 + Settings : dossier, proxy/VPN, retries, choix qualité HLS, cleanup .parts |
| 2026-07-29 | Indicateur VPN système (utun/ipsec/ppp) dans toolbar + réglages |
| 2026-07-29 | Phase 6 : DASHParser, download/assemble DASH, audio/subs optionnels, sheet options, fixtures |
| 2026-07-29 | Favoris sites (BookmarkStore JSON) + Phase 7 PluginManager / ExampleMediaHintPlugin / PLUGIN_AUTHOR.md |
| 2026-07-29 | Phase 8 : historique, batch URLs, auto-enqueue, openstream-cli (inbox locale) |
| 2026-07-29 | Nomenclature export configurable (Jellyfin film/série + custom) + titre/année au download |
| 2026-07-29 | Download : fenêtre glissante segments + réglage concurrence (défaut 8, max 16) |
| 2026-08-17 | Dépôt public + release v0.1.0 ; install.sh + setup FFmpeg in-app via Homebrew |
