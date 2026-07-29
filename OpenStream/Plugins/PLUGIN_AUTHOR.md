# Guide auteur de plugin OpenStream

API version courante : **1** (`OpenStreamPluginAPI.version`).

## Contrat

Tout plugin expose au minimum :

| Champ | Rôle |
|-------|------|
| `id` | Identifiant stable (`reverse-DNS`) |
| `name` / `version` | Affichage / debug |
| `apiVersion` | Doit égaler `1` sinon refus au registre |

Extension utile aujourd’hui :

- `MediaURLHintPlugin` — `shouldAcceptMediaURL(_:mimeType:)` pour faire accepter une URL que les heuristiques core ignorent.

## Intégration built-in (recommandé en sandbox)

1. Ajouter un type conforme à `MediaURLHintPlugin` dans la cible OpenStream (ou un framework lié).
2. L’enregistrer au démarrage : `try PluginManager.shared.register(MonPlugin())`.
3. Ne pas modifier le core : brancher uniquement via `PluginManager`.

Exemple livré : `ExampleMediaHintPlugin` — accepte `#openstream-media` ou le chemin `/__openstream_media__/`.

## Bundles `.openstreamplugin`

Dossier scanné : `~/Library/Application Support/OpenStream/Plugins/`.

`Info.plist` minimal :

```xml
<key>CFBundleIdentifier</key>
<string>app.example.openstream.plugin</string>
<key>OpenStreamPluginAPIVersion</key>
<integer>1</integer>
```

La Phase 7 valide le manifeste. Le chargement dynamique de code tiers reste limité par le sandbox macOS (signature / même équipe) — préférer un plugin compilé avec l’app pour l’instant.

## Règles

- Pas de contournement DRM / déchiffrement.
- Pas d’accès hors des APIs documentées.
- Un `id` dupliqué est refusé.
