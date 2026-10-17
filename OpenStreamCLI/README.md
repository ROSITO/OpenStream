# openstream-cli — contrat agent IA

CLI headless OpenStream : détecter, télécharger et assembler des flux **clairs** (HLS / DASH / MP4) sans GUI.  
Sortie machine : **JSON Lines** sur stdout + **exit code**. FFmpeg embarqué dans `Helpers/` à côté du binaire.

> Pas de contournement DRM, captcha, login, ni déchiffrement. Cookies / referer = rejouer une session déjà accordée à l’utilisateur.

---

## Localiser le binaire

```bash
xcodegen generate   # si project.yml a changé
./scripts/fetch-bundled-ffmpeg.sh   # si Helpers/ffmpeg absents
xcodebuild -scheme OpenStreamCLI -configuration Debug -destination 'platform=macOS' build

CLI="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/OpenStream-*/Build/Products/Debug/openstream-cli | head -1)"
"$CLI" help
```

Produit : `openstream-cli` (`PRODUCT_NAME`). Bundle id : `app.openstream.OpenStreamCLI`.

### Install agent sur ollamac (Mac Mini)

Déployé pour l’utilisateur `rosito` :

| | |
|--|--|
| Binaire + FFmpeg | `~/.local/opt/openstream-cli/` |
| Lien PATH | `~/.local/bin/openstream-cli` |
| Doc | `~/.local/opt/openstream-cli/README.md` |
| Exports défaut | `~/Downloads/OpenStream` **sur ollamac** (`/Users/rosito/Downloads/OpenStream`) |

```bash
ssh MacMiniM4_ext   # ou: ssh rosito@ollamac
export PATH="$HOME/.local/bin:$PATH"
openstream-cli help
```

SSH : user `rosito` (alias `MacMiniM4_ext` / `ollamac` Tailscale).

Redeploy depuis la machine de build :

```bash
xcodebuild -scheme OpenStreamCLI -configuration Release -destination 'platform=macOS' build
PROD="$HOME/Library/Developer/Xcode/DerivedData/OpenStream-*/Build/Products/Release"
rsync -az -e 'ssh -o BatchMode=yes' \
  "$PROD/openstream-cli" "$PROD/Helpers" "$PROD/ffmpeg" "$PROD/ffprobe" \
  OpenStreamCLI/README.md \
  MacMiniM4_ext:~/.local/opt/openstream-cli/
# Helpers/ doit finir dans ~/.local/opt/openstream-cli/Helpers/
```

---

## Quand utiliser quoi

| Besoin | Commande |
|--------|----------|
| URL média déjà connue (`.m3u8` / `.mpd` / `.mp4`) | `download <url>` |
| Page web → découvrir le flux | `fetch <pageURL>` |
| Seulement lister les flux d’une page | `fetch … --detect-only` |
| Page → premier flux → export | `fetch … --auto-download` |
| Lister les épisodes d’une saison | `season <showName\|pageURL>` (défaut list-only) |
| Télécharger toute une saison | `season … --auto-download` |
| Nouveautés des hubs favoris (RSS) | `flix digest` / `flix scan` |
| Choisir une entrée du digest | `flix pick 1` ou `flix pick 1,3 --enqueue` |
| Suivre / attendre / annuler un job | `status` / `wait` / `cancel` |
| Déclencher l’app GUI (si ouverte) | `--via-app` ou `ping` / `open` |

Règle simple : **URL fichier média → `download`**. **URL page HTML → `fetch`**. **Nom de série ou page saison → `season`**. **Hubs / « quoi de neuf ? » → `flix`** (pas `fetch` sur la homepage).

### NL agent (Intendant) — résolution via favoris

`season` **cherche tout seul** : (1) favori page dont le titre matche la série/saison, sinon (2) recherche DLE sur les **sites** favoris (FS26…). L’agent ne doit **pas** demander l’URL à l’utilisateur.

| Message utilisateur | Commande | Comportement |
|---------------------|----------|--------------|
| « Télécharge la saison de Tulsa King » | `season 'Tulsa King' --season 1 --json` | Favoris → page saison → liste / download |
| Lien `…/newsid=…` déjà connu | `season <url> --show 'Tulsa King' --season 1` | Skip résolution, énumère directement |

```bash
# Cas nominal Intendant (pas d’URL)
openstream-cli season 'Tulsa King' --season 1 --json
# équivalent :
openstream-cli season --show 'Tulsa King' --season 1 --json --auto-download
```

Mauvaise commande :

```bash
# --title = phrase NL → ne sert pas à la résolution favoris
openstream-cli season … --title 'Telecharge la saison de Tulsa King'
```

---

## Commandes

```
openstream-cli download <url> [options]
openstream-cli fetch <pageURL> [--detect-only|--auto-download] [options]
openstream-cli season <pageURL|showName> [--list-only|--auto-download] [--show NAME] [--season N] [options]
openstream-cli flix scan|digest|bootstrap|seen|pick … [options]
openstream-cli status [jobId]
openstream-cli list
openstream-cli wait <jobId>
openstream-cli cancel <jobId>
openstream-cli ping | open <url> | inbox | help
```

### Flix — digest nouveautés (hubs favoris)

Scanne le RSS DLE (`/engine/rss.php`) des **homepages** en favoris (ex. FS26). **Propose** un digest numéroté — **n’auto-télécharge pas**.

```
openstream-cli flix scan [--json] [--max N] [--since ISO|Nd]
openstream-cli flix digest [--json] [--max N] [--mark-seen]
openstream-cli flix bootstrap [--json]
openstream-cli flix seen list|clear [--json]
openstream-cli flix pick <n|n,m> [--enqueue] [--json]
```

| Commande | Effet |
|----------|--------|
| `scan` | Liste brute RSS (aucun side-effect `seen`) |
| `digest` | Top N non-vus (défaut **8**) ; écrit `flix_last_digest.json` ; 1er run (`seen` vide) = **bootstrap auto** → `count: 0` |
| `bootstrap` | Marque le head RSS actuel comme vu (évite le dump initial) |
| `seen list\|clear` | Inspecte / remet à zéro `flix_seen.json` |
| `pick 1,3` | Résout depuis le **dernier digest** → `show`/`season` ou `url` |
| `pick … --enqueue` | Sous-processus `season … --auto-download` ou `fetch … --auto-download` |

**Favoris :** homepages uniquement (pages `newsid=` ignorées comme hub, host conservé).  
**Liens RSS :** host réécrit vers le favori (`fs20.lol` → `fs26.lol`).  
**Hubs sans RSS** (Interra, Rizmov…) → warning **stderr**, skip ; exit 0 si au moins un hub OK.  
**État :** `~/Library/Application Support/OpenStream/flix_seen.json` + `flix_last_digest.json`.  
**Piège :** ne pas `fetch https://fs26.lol/` pour lister un catalogue → timeout média (exit 7).

#### JSON Flix (`--json`) — un objet stdout (pas JSON Lines)

`digest` :

```json
{
  "updated": "2026-10-17T14:54:00Z",
  "count": 2,
  "items": {
    "1": {
      "n": 1,
      "id": "https://fs26.lol/index.php?newsid=15140996",
      "url": "https://fs26.lol/index.php?newsid=15140996",
      "title": "Tulsa King - Saison 4",
      "show": "Tulsa King",
      "season": 4,
      "mode": "season",
      "display": "Tulsa King — S4",
      "source": "FS26",
      "pub_date": "Sat, 17 Oct 2026 03:17:57 +0200"
    }
  }
}
```

`scan` : `{ "count", "hubs_ok", "hubs_skipped", "items": [ … ] }`  
`pick` (sans `--enqueue`) : tableau d’items.  
`mode` : `season` si titre `… - Saison N`, sinon `fetch`.

Texte humain (sans `--json`) si `count > 0` :

```text
Flix — 2 nouveautés
1. Tulsa King — S4 (FS26)
2. MobLand — S2 (FS26)
Réponds 1 / 1,3 ou season « Show » --season N
```

Si `count: 0` : stdout vide (silence), exit 0.

### Options communes

| Flag | Défaut | Rôle |
|------|--------|------|
| `--json` | off | **Obligatoire pour un agent** — JSON Lines (`download`/`fetch`/`season`) ou objet JSON (`flix`) |
| `--cookie <header>` | — | Cookie HTTP brut (`a=1; b=2`) |
| `--referer <url>` | — | Header Referer (souvent la page watch) |
| `--user-agent <ua>` | UA OpenStream | User-Agent |
| `--out <dir>` | `~/Downloads/OpenStream` | Dossier d’export final |
| `--kind hls\|dash\|mp4` | inféré | Forcer le type |
| `--title <name>` | auto | Titre export / events (prioritaire) |
| `--show <name>` | auto | Nom de série (`season`) |
| `--season <n>` | depuis l’URL | Numéro de saison (`season`) |
| `--list-only` | défaut `season` | Lister sans télécharger |
| `--timeout <sec>` | `45` | Timeout détection `fetch` / page |
| `--quality best\|ask` | `best` | Préférence HLS |
| `--shared-db` | off | DB partagée avec l’app GUI |
| `--via-app` | off | Écrit l’inbox GUI au lieu d’exécuter |
| `--max <n>` | `8` (`digest`) | Plafond items (`flix scan` / `digest`) |
| `--since <ISO\|Nd>` | — | Filtre `scan` (ex. `7d`, `2026-10-01T00:00:00Z`) |
| `--mark-seen` | off | `flix digest` : marque les items proposés comme vus |
| `--enqueue` | off | `flix pick` : lance season/fetch auto-download |

---

## Contrat JSON Lines (stdout)

Toujours lancer avec `--json`. **Une ligne = un événement**, clés triées, flush immédiat.  
Parser ligne par ligne ; ignorer les lignes non-JSON (ne devrait pas arriver en `--json`).

### Schéma (`AgentEvent`)

| Champ | Type | Présent quand |
|-------|------|----------------|
| `event` | string | toujours |
| `jobId` | string (UUID) | jobs download |
| `title` | string | souvent |
| `kind` | `hls` \| `dash` \| `progressive` | détection / jobs |
| `progress` | number 0…1 | progress / assembling / completed |
| `completedUnits` | int | segments / épisodes faits |
| `totalUnits` | int | total connu |
| `path` | string | `completed` — fichier export absolu |
| `url` | string | `detected` / `episode` — URL |
| `message` | string | libellé court / erreur |
| `show` | string | `episode` / `season_done` |
| `season` | int | `episode` / `season_done` |
| `episode` | int | `episode` |

### Valeurs de `event`

| `event` | Signification | Action agent typique |
|---------|---------------|----------------------|
| `detected` | Flux trouvé (`fetch`) | Lire `url` + `title` ; décider download |
| `episode` | Page épisode listée (`season`) | Collecter `url` ; download si besoin |
| `season_done` | Fin d’énumération / saison | Lire `completedUnits` / `totalUnits` |
| `queued` | Job enfilé | Garder `jobId` |
| `progress` | Avancement | Afficher / logger ; ne pas timeout trop court |
| `assembling` | FFmpeg en cours | Attendre `completed` / `failed` |
| `completed` | Succès | Lire `path` ; exit attendu `0` |
| `failed` | Échec | Lire `message` ; voir exit code |
| `cancelled` | Annulé | exit `6` |
| `info` | Message hors job | Log |

### Exemples de lignes

```json
{"event":"detected","kind":"hls","message":"detected","title":"Masterplan (2026)","url":"https://cdn.example/a.m3u8"}
{"episode":4,"event":"episode","message":"episode","season":1,"show":"Friends","title":"Friends S01E04","url":"https://movix.example/watch/tv/1668/s/1/e/4"}
{"completedUnits":24,"event":"season_done","message":"listed 24 episodes","season":1,"show":"Friends","totalUnits":24}
{"event":"queued","jobId":"8DC51B08-…","kind":"progressive","message":"queued","title":"Friends S01E04"}
{"completedUnits":12,"event":"progress","jobId":"…","kind":"hls","message":"Téléchargement 1% (12/1590)","progress":0.0075,"title":"…","totalUnits":1590}
{"event":"assembling","jobId":"…","kind":"hls","message":"assembling","progress":0.99,"title":"…"}
{"event":"completed","jobId":"…","kind":"hls","message":"completed","path":"/tmp/out/Friends/Saison 01/S01E04.mp4","progress":1,"title":"…"}
{"event":"failed","jobId":"…","message":"HTTP 403"}
```

---

## Exit codes

| Code | Constante | Signification | Retry ? |
|------|-----------|---------------|---------|
| 0 | success | OK | — |
| 2 | usage | Args invalides | Non — corriger la commande |
| 3 | network | Réseau / générique | Oui (backoff) si transitoire |
| 4 | assemble | Échec FFmpeg | Rare — vérifier Helpers/ffmpeg |
| 5 | notFound | `jobId` inconnu | Non |
| 6 | cancelled | Annulé | — |
| 7 | detectTimeout | `fetch` : aucun média avant timeout | Oui — ↑ `--timeout`, vérifier URL page / lecture auto |

`download` / `fetch --auto-download` sont **synchrones** : le process ne se termine qu’à l’état terminal (completed / failed / cancelled). Pas besoin de `wait` dans ce cas.

---

## Titres

Ordre de priorité :

1. `--title <name>` (gagne toujours sur les events + nom de fichier)
2. Titre page nettoyé (`document.title` / décorations site retirées) via `PageTitleResolver`
3. Fallback path URL **non opaque**
4. Jamais l’ID CDN du `.m3u8` (tokens alphanum longs rejetés)

Pour un agent : passer `--title` dès que le nom contenu est connu (ex. depuis favoris / recherche).

---

## Credentials & pages protégées

- `--referer` : pour `download` d’une URL CDN, mettre l’URL de la page watch.
- `fetch --auto-download` pose automatiquement le referer = `pageURL` si absent.
- `--cookie` : header Cookie brut de la session navigateur si le CDN l’exige.
- Les favoris app sont dans  
  `~/Library/Application Support/OpenStream/bookmarks.json`  
  (titre + url) — utile pour trouver une page puis `fetch`.

---

## Stockage / où vont les fichiers

| Chemin | Contenu |
|--------|---------|
| `--out <dir>` | **Prioritaire** — dossier d’export final |
| `~/Downloads/OpenStream` | Défaut si `--out` omis (home de l’user qui lance le CLI) |
| `~/Library/Application Support/OpenStream/cli-store/` | DB jobs CLI (défaut) |
| `~/Library/Application Support/OpenStream/downloads.sqlite` | DB app (`--shared-db`) |
| `~/Library/Application Support/OpenStream/inbox/` | Commandes `--via-app` |
| prefs `parts/` | Segments temporaires avant assemble |

Sous-dossier d’export selon nomenclature :
- plat / titre : `{title}/{title}.mp4`
- série (`season --auto-download`) : `{show}/Saison {season}/S{season}E{episode}.mp4`

Exemple test Tulsa King (machine de build, `--out` forcé) :  
`/tmp/openstream-tulsa-s1b/Tulsa King S01E01/Tulsa King S01E01.mp4`

Ne pas mélanger CLI et GUI sans `--shared-db`.

---

## Workflows agent (recettes)

### A — URL média connue

```bash
"$CLI" download "$MEDIA_URL" \
  --json \
  --kind mp4 \
  --referer "$PAGE_URL" \
  --title "Show S01E04" \
  --out /tmp/openstream-out
# exit 0 → dernière ligne event=completed + path
```

### B — Page → détection seule

```bash
"$CLI" fetch "$PAGE_URL" --detect-only --json --timeout 60
# exit 0 → une ou plusieurs lignes event=detected (url, kind, title)
# exit 7 → rien trouvé
```

### C — Page → download auto

```bash
"$CLI" fetch "$PAGE_URL" \
  --auto-download --json \
  --title "Masterplan" \
  --out /tmp/openstream-out \
  --timeout 60
# detected → queued → progress… → assembling → completed
```

### D — Saison (liste)

```bash
# Via favoris (Intendant) — pas d’URL
"$CLI" season 'Tulsa King' --season 1 --json
# → info (resolved) → 9× episode → season_done

# URL page saison déjà connue
"$CLI" season 'https://fs26.lol/index.php?newsid=15112864' \
  --json --show 'Tulsa King' --season 1

# MOVIX-like
"$CLI" season 'https://movix.example/watch/tv/1668/s/1/e/1' \
  --json --show Friends --season 1
```

Énumération (dans l’ordre) :
1. catalogue French Stream `/data/eps_{newsid}.txt` (embeds ; ordre lecteurs : `vidzy` → `premium` → …)
2. pattern URL `…/tv/{id}/s/{S}/e/{E}` (HEAD jusqu’à 2 misses)
3. liens DOM si rien trouvé

Défaut = list-only.  
`fetch` / `season --auto-download` préfèrent une variante HLS **vidéo** (`index-v1…`) à l’audio-only (`index-a1`).

### E — Saison (téléchargement séquentiel)

```bash
"$CLI" season 'Tulsa King' --season 1 \
  --auto-download --json \
  --out ~/Downloads/OpenStream \
  --timeout 90
# info → episode → fetch embed → detected → queued → … → season_done
# Fichiers : ~/Downloads/OpenStream/Tulsa King/Saison 01/S01E0x.mp4
```

### F — Pseudo-code agent

```
if url looks like media (.m3u8|.mpd|.mp4|…):
    run download --json [--referer] [--title] [--cookie]
else if intent is "what's new" / digest / nouveautés:
    run flix digest --json [--mark-seen]
    # user replies 1 / 1,3 → flix pick 1,3 [--enqueue --json]
else if intent is whole season:
    run season SHOW_NAME --json --season N                  # list via favoris
    # or: season SHOW_NAME --auto-download --json --season N
else:
    run fetch --detect-only --json --timeout 60
    if exit == 7: retry with larger timeout or ask user
    pick first (or best) detected.url
    run download detected.url --json --referer page --title (flags.title or detected.title)
parse stdout (JSON Lines for download/fetch/season ; single object for flix)
on completed: return path
on failed: surface message + exit code
```

### G — Flix (digest)

```bash
# Premier déploiement / nouveau Mac : seed without spam
"$CLI" flix bootstrap --json
# → {"marked":10}

# Cron agent (ex. mar/ven) — nouveautés seulement
"$CLI" flix digest --json --mark-seen
# → {"count":0,...}  ou  items 1..N

# L’utilisateur répond « 1 » ou « 1,3 »
"$CLI" flix pick 1 --json
# → [{"mode":"season","show":"Tulsa King","season":4,"url":"…"}]

"$CLI" flix pick 1 --enqueue --json
# → season 'Tulsa King' --season 4 --auto-download --json
```

---

## Limites (ne pas demander au CLI)

- DRM (`EXT-X-KEY`, Widevine, FairPlay, CENC…) — hors scope MVP ; ne pas tenter de bypass
- Captcha / Cloudflare interactif
- Choix multi-qualité interactif (`--quality ask` peu utile headless → rester sur `best`)
- iOS / remote control hors machine locale

---

## Fichiers code (référence)

| Fichier | Rôle |
|---------|------|
| `OpenStreamCLI/CLI.swift` | Parsing args, orchestration |
| `OpenStreamCore/AgentJSON.swift` | `AgentEvent` + exit codes |
| `OpenStreamCore/EpisodeEnumerator.swift` | Pattern URL + parse liens DOM |
| `OpenStreamCore/HeadlessDownloadService.swift` | Queue download sans UI |
| `OpenStreamCore/HeadlessBrowserSession.swift` | WKWebView offscreen + titres / liens épisode |
| `OpenStream/Browser/PageTitleResolver.swift` | Nettoyage titres |

Décision figée : **MEMORY.md → D018**.
