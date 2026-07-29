# openstream-cli

Outil en ligne de commande pour enfiler des actions vers OpenStream (app ouverte).

```bash
# Depuis le dépôt, après build :
build/DerivedData/Build/Products/Debug/openstream-cli download 'https://example.com/video.m3u8'
build/DerivedData/Build/Products/Debug/openstream-cli open 'https://example.com/watch'
build/DerivedData/Build/Products/Debug/openstream-cli ping
```

Les commandes JSON sont écrites dans `~/Library/Application Support/OpenStream/inbox/`.  
L’app les consomme via `LocalCommandServer` (poll 1 s).
