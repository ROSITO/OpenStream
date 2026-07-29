# ROADMAP.md — OpenStream

Plan d'exécution ordonné.  
Une phase = un incrément livrable avec critères de done.  
Ne pas démarrer la phase N+1 tant que les critères bloquants de N ne sont pas verts.

Références : `PRD_OpenStream.md`, `ARCHITECTURE.md`, `MEMORY.md`, `CLAUDE.md`.

---

## Légende

- **Bloquant** : empêche la phase suivante
- **Souhaitable** : peut glisser d'une phase sans casser le chemin critique
- Cases à cocher : mettre à jour au fil de l'eau

---

## Phase 0 — Fondations dépôt

**Objectif :** squelette Xcode + docs + conventions prêts pour coder.

- [x] Projet Xcode macOS (SwiftUI App) `OpenStream`
- [x] Structure dossiers alignée `ARCHITECTURE.md` (même en mono-target au début)
- [x] Découpage dossiers prêt pour extraction future de targets (pas de Package.swift actif)
- [x] `.gitignore` (DerivedData, `.DS_Store`, secrets, binaires locaux)
- [x] Décision provisoire bundle ID + macOS deployment target notée dans `MEMORY.md`
- [x] Schéma de logging `os.Logger` minimal
- [x] Suite de tests qui compile (`MediaURLHeuristicsTests`)

**Done quand :** l'app lance une fenêtre vide ; les tests tournent (0 tests OK) ; docs présentes.  
**Statut :** ✅ livré 2026-07-29 (app navigateur Phase 1 incluse dans le même incrément)

---

## Phase 1 — Navigateur intégré + observation réseau

**Objectif :** naviguer le web et **voir** des candidats média.

- [x] Wrapper `WKWebView` (barre URL, back/forward, loading)
- [x] Pont cookies `WKHTTPCookieStore` → snapshot session
- [x] Prototype Network Observer (valider la technique — noter le choix dans `MEMORY.md`)
- [x] Émission de `NetworkMediaCandidate` (URL, content-type, status)
- [x] UI : liste live des candidats bruts (debug OK)

**Done quand :** sur une page de test locale ou publique **sans DRM**, on voit apparaître les URLs `.m3u8` / `.mp4` candidates.  
**Bloquant :** technique d'observation validée et documentée.  
**Statut :** ✅ livré 2026-07-29 — technique D008 (JS hooks + navigation delegate)

---

## Phase 2 — Détection & parse HLS + MP4 progressif

**Objectif :** transformer les candidats en `DetectedMedia` actionnables.

- [x] `MediaDetector` (classification progressive / hls / unknown)
- [x] `HLSParser` : master + media, variantes, segments, `#EXT-X-ENDLIST`
- [x] Support MP4 progressif (URL directe, content-length si dispo)
- [x] Modèles `DetectedMedia` / `MediaVariant` dans Core (`MediaProtection` stub OK, toujours `.none` en test)
- [x] Fixtures m3u8 + tests unitaires parsers
- [x] UI : liste des médias détectés (titre, type, résolution/bandwidth)

**Done quand :** fixtures HLS VOD + MP4 passent en tests ; UI affiche des médias classifiés.  
**Note (D007) :** pas de détection/refus DRM dans cette phase.  
**Statut :** ✅ livré 2026-07-29 — segments `.ts` exclus de la liste principale ; variante préférée = plus haut bandwidth

---

## Phase 3 — Download Manager (MVP)

**Objectif :** télécharger segments / fichiers avec progression et annulation.

- [x] `DownloadQueue` (actor) : enqueue, cancel, parallélisme borné
- [x] Downloader URLSession avec cookies/headers de session
- [x] HLS : téléchargement ordonné des segments (+ `EXT-X-MAP` si fMP4)
- [x] Progressive : téléchargement fichier unique
- [x] Progression agrégée + états `DownloadState`
- [x] Persistance minimale des jobs pour reprise après crash (SQLite)
- [x] Tests : queue, annulation, reprise simulée

**Done quand :** un job HLS VOD et un MP4 se téléchargent jusqu'au bout avec progress UI ; cancel fonctionne ; reprise après relance app pour un job interrompu.  
**Statut :** ✅ livré 2026-07-29 — fichiers dans `~/Downloads/OpenStream/` ; assemblage MP4 = Phase 4

---

## Phase 4 — FFmpeg + Export (fin MVP)

**Objectif :** produire un fichier regardable sur disque.

- [x] Intégration FFmpeg isolée (`FFmpegWrapper`) — méthode choisie documentée dans `MEMORY.md`
- [x] Remux / concat segments → MP4 (`-c copy` quand possible)
- [x] `Exporter` : MP4 dans `~/Downloads/OpenStream/` ; segments `.parts/` puis cleanup
- [x] Gestion d'erreurs codecs / remux (message UI clair)
- [x] Préférences : dossier destination (`AppPreferences`), concurrence
- [x] Tests integration sur fixtures locales

**Done quand :** parcours bout-en-bout : ouvrir URL → détecter → télécharger → obtenir un MP4 jouable.  
**= MVP livrable.**  
**Statut :** ✅ livré 2026-07-29 — FFmpeg via Process/Homebrew (D010) ; auto-assemblage après download

---

## Phase 5 — Durcissement MVP

**Objectif :** qualité avant features V2.

- [x] Gestion offline / erreur réseau avec retry borné
- [x] Choix manuel de variante HLS (qualité) — réglage « demander » + sheet
- [x] Titre / metadata de base (page title, filename sanitizé)
- [x] Logging structuré + catégories (`AppLog`)
- [x] Nettoyage fichiers temporaires (`.parts` orphelins au lancement + bouton réglages)
- [x] UI non-debug (paramètres, empty states, sheet qualité)
- [x] Décision licence + stratégie FFmpeg/LGPL **notées** dans MEMORY (licence produit encore ouverte)

**Done quand :** utilisable par un tiers sans console debug ; pas de fuites de temp évidentes.  
**Statut :** ✅ livré 2026-07-29 — panneau Paramètres (dossier, proxy/VPN, retries, qualité HLS)

---

## Phase 6 — V2 médias avancés

**Objectif :** DASH + pistes annexes.

- [x] `DASHParser` (MPD clair ; pas de gate ContentProtection ici — Phase 9)
- [x] Sous-titres (WebVTT sidecar ; playlists HLS / Representation DASH)
- [x] Pistes audio multiples (sélection UI + auto DASH)
- [x] Tests fixtures DASH non protégés + HLS `#EXT-X-MEDIA`
- [x] UI sélection audio / subs / qualité

**Done quand :** au moins un flux DASH clair + HLS avec audio/subs optionnels exportés correctement.  
**Statut :** ✅ livré 2026-07-29 — chemin HLS/MP4 inchangé sans pistes sélectionnées ; DASH → fMP4 remux

---

## Phase 7 — V2 plugins

**Objectif :** extensibilité sans forker le core.

- [x] Protocols stables versionnés (`OpenStreamPluginAPI` = 1, `MediaURLHintPlugin`)
- [x] `PluginManager` (registre + validation bundles `.openstreamplugin`)
- [x] Plugin exemple (`ExampleMediaHintPlugin` — marqueurs `#openstream-media` / `/__openstream_media__/`)
- [x] Sandbox / validation des plugins (API version + Info.plist ; chargement code tiers limité sandbox)
- [x] Doc auteur de plugin (`OpenStream/Plugins/PLUGIN_AUTHOR.md`)

**Done quand :** un plugin exemple détecte un cas que le core ignore, sans modification du core.  
**Statut :** ✅ livré 2026-07-29

**Bonus (hors Phase 7, demandé produit) :** favoris de sites — `BookmarkStore` + étoile / menu / gestionnaire.

---

## Phase 8 — V3 productivité

**Objectif :** historique, batch, automatisation, API.

- [x] History UI complète (recherche, re-download si URL encore valide)
- [x] Batch : file multi-URLs (médias + pages séquentielles)
- [x] Règles d'automatisation simples (auto-enqueue HLS / DASH / MP4)
- [x] API locale CLI (`openstream-cli` → inbox Application Support)
- [x] Tests unitaires productivité (history / batch / rules / command JSON)

**Done quand :** un utilisateur power-user peut enchaîner plusieurs téléchargements et rejouer l'historique.  
**Statut :** ✅ livré 2026-07-29

---

## Phase 9 — Gate DRM (release open source publique)

**Objectif :** réintégrer la politique produit avant publication. Bloquant pour le tag / release publique.

- [ ] Détection HLS `#EXT-X-KEY` → `MediaProtection.drm` + refus UI
- [ ] Détection DASH `ContentProtection` / CENC → refus UI
- [ ] Message utilisateur clair (pas de contournement, pas de déchiffrement)
- [ ] Tests : fixtures « protégées » → enqueue impossible / état failed explicite
- [ ] Vérifier qu’aucun chemin de code ne tente de déchiffrer
- [ ] Doc utilisateur / README : périmètre « flux non DRM uniquement »

**Done quand :** un manifeste chiffré est systématiquement refusé ; le README public l’affirme ; prêt déploiement OSS.  
**Source :** D001 + D007.

---

## Hors roadmap (backlog non planifié)

- Live HLS (fenêtre glissante)
- iOS / iPadOS
- Re-encode qualité custom (transcode lourd)
- Thèmes UI avancés / localisation complète
- CI GitHub Actions (xcodebuild) — à placer idéalement dès Phase 4/5

---

## Ordre de travail recommandé (agents)

```
Phase 0 → 1 → 2 → 3 → 4  = MVP (test, sans gate DRM)
         ↘ documenter chaque décision dans MEMORY.md
Phase 5 (durcissement) → 6 → 7 → 8 → 9 (gate DRM, release publique)
```

Ne pas implémenter DASH, plugins, ou API tant que le chemin Phase 1→4 n'est pas vert.  
Ne pas publier en open source tant que la Phase 9 n'est pas verte.
