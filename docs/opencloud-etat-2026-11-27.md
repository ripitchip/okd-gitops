# OpenCloud sur `sno` — état au 27/11/2026 (fin de session)

Document de reprise : à lire en premier à la prochaine session. Il dit où on en est, ce qui
est cassé, ce qui a été fait à la main dans le cluster (et donc **non versionné**), et ce
qu'il reste à faire dans l'ordre.

---

## 1. Vue d'ensemble

| Élément | État |
|---|---|
| Code / manifests | **repo `okd-gitops` propre, tout poussé, HEAD = `origin/main` = `7c3c55c`** |
| Application Argo CD `opencloud` | `Synced` / `Healthy` |
| Pod `opencloud` | `1/1 Running` (mais voir §4 : config régénérée à la main) |
| Pod `opencloud-radicale` | `2/2 Running` |
| Site `https://cloud.tomlab.fr` | `/status.php` **200**, `/config.json` **200**, `/` **200**, login Keycloak OK |
| Login `thomas` (groupe `opencloudAdmin`) | **OK** — compte auto-provisionné dans l'IDM neuf |
| Partages / favoris | **cassés en boucle** (voir §3) — c'est le prochain sujet |
| SSE / notifications temps réel | **KO** (conséquence du même problème) |
| Calendrier (Radicale + calshare) | pods OK, routes proxy OK, **non testé fonctionnellement** |

## 2. Ce qui a été construit (versionné)

Commits (du plus ancien au plus récent) :

```
bdd80e0 feat(opencloud): add opencloud and calendar
14d2ac6 fix(opencloud): render config with sh and document the setup
6c64491 fix(opencloud): substitute placeholders with awk
07bc1f1 fix(opencloud): set the gateway storage users mount id
eeaa04d fix(opencloud): correct the auth-basic and ocm service account keys
03e92e4 fix(opencloud): complete the config required by each service
4768e3f fix(opencloud): proxy service account in the env, init the empty JSON stores
7f79114 fix(opencloud): auth-service service account, harden radicale, groups path
1931550 fix(opencloud): move the stale search index aside
c780e70 fix(opencloud): groups reads drivers.ldap
4946d83 fix(opencloud): retire the stale search index on every start
f593c15 fix(opencloud): load the proxy policy as is
466f2e7 fix(opencloud): write the rendered configs atomically
c14c27a fix(opencloud): move every stale search index aside
7c3c55c fix(opencloud): keep "/" as the first proxy route
```

Fichiers : `platform/opencloud/*` (17 fichiers), `clusters/sno/apps/opencloud.yaml`,
`docs/adr/0005-opencloud.md`, `README.md` (section upgrade OpenCloud).

### Architecture retenue

- Un seul processus `opencloud server` (tous les services dans le pod, comme
  `opencloud-compose`).
- `restricted-v2`, pas d'UID fixe, pas de chown root : les volumes NFS sont chown par un
  initContainer non privilégié (`chown -R $(id -u)`).
- **Pas de `opencloud init`** : `opencloud.yaml` est versionné
  (`platform/opencloud/opencloud-config.yaml`, template avec `__PLACEHOLDER__`) et rendu à
  chaque démarrage par l'initContainer `opencloud-config` (image `mikefarah/yq`, exécuté en
  `/bin/sh`, variables depuis le Secret `opencloud-secrets`).
- Secret `opencloud-secrets` ← Vault (`secret/opencloud-secrets`) via ESO
  (`platform/opencloud/externalsecret.yaml`, 12 clés).
- `proxy.policies` est versionné dans `platform/opencloud/proxy-routes.yaml`, **la route `/`
  doit rester la première** (le fallback racine d'OpenCloud ne lit que le premier élément ;
  sinon : `no rewrite hook found` → 500 sur `/` et `/config.json`).
- Rôles : `role-mapping.yaml` → groupe Keycloak `opencloudAdmin` (ou `/opencloudAdmin`) =
  rôle `admin`, `opencloudUser` = `user`, claim `groups`.

## 3. ✅ Problème en cours (à reprendre ici)

### `sharing` ne peut pas s'initialiser

```
service=sharing  "share manager: metadata storage initialization failed, retrying"
                 error="internal error: error creating space"
                 backoff 2s, 4s, 8s, 16s, 32s… (en boucle infinie)

service=storage-system
  error="node.Xattr /var/lib/opencloud/storage/metadata/spaces/js/oncs3-share-manager-metadata/nodes/js/on/cs/3-/share-manager-metadata user.oc.name: no data available"
```

**Cause** : sur l'ancien volume NFS, le nœud de l'espace système interne
`jsoncs3-share-manager-metadata` existe mais est **incomplet** (pas d'xattr `user.oc.name`),
reste de l'instance précédente. `sharing` ne peut ni l'ouvrir ni le créer, et réessaie.

**Conséquences vues côté navigateur** :
- compteurs de partages / favoris jamais disponibles → le web **poll en boucle** (« shares et
  favorites tournent fou ») ;
- **SSE** `connection error, reconnecting...` (les notifications passent par le même chemin).

**À faire** (validé par l'utilisateur, pas encore exécuté) :

1. `oc -n opencloud scale deploy/opencloud --replicas=0`
2. inspecter le nœud (`pod jetable` monté sur `opencloud-data`, chemin
   `storage/metadata/spaces/jsoncs3-share-manager-metadata`), vérifier qu'il ne contient pas
   de données utilisateur ;
3. le **renommer** en `<nom>.bak-<date>` (ne rien supprimer) ;
4. `oc -n opencloud scale deploy/opencloud --replicas=1` → `sharing` recrée l'espace
   proprement ;
5. vérifier : plus de `backoff` dans les logs `sharing`, `/shares` répond, la SSE se connecte.

## 4. ⚠️ Réparations faites à la main dans le cluster (non reproductibles)

Ces actions ne sont **pas** dans le repo : elles ont servi à débloquer. Un sync Argo CD +
redémarrage les rejouera normalement **si** la config du volume est régénérée par
l'initContainer (ce qui est le cas aujourd'hui).

| Action | Détail |
|---|---|
| Index search déplacé | `search/bleve-v5.old-*` (12 dossiers, caches, jetables) |
| Base IDM supprimée | ancienne base déplacée en `/var/lib/opencloud/idm.boltdb.bak-20261126224628` ; nouvelle base recréée (131 072 octets) → login OK |
| `config/opencloud.yaml` régénéré | supprimé puis recréé par l'initContainer avec le script corrigé (route `/` en tête) |
| CM `opencloud-config-script` | réappliqué à la main (`oc apply`) avec la version du repo |
| Erreur Argo `env[26]` | causée par un `oc set env` manuel (secret en clair) → remis en `valueFrom` |
| SA `vault-auth` + `system:auth-delegator` | créés dans `opencloud` (désormais versionnés dans `rbac.yaml`) |

**Vérifier à la reprise** que `config/opencloud.yaml` contient bien `- endpoint: /` **avant**
`- endpoint: /caldav/` :

```sh
P=$(oc -n opencloud get pods -l app=opencloud -o name | head -1)
oc -n opencloud exec $P -c opencloud -- grep -n 'endpoint: /$\|endpoint: /caldav/' /var/lib/opencloud/config/opencloud.yaml
```

## 5. Points connus restants (après §3)

1. **Keycloak** : client public `web` (PKCE), redirect URIs
   `https://cloud.tomlab.fr/` et `https://cloud.tomlab.fr/oidc-callback.html`, mapper
   `groups` avec scope `profile`. Issuer `https://auth.tomlab.fr/realms/foobarbaz`.
2. **Vault** : `secret/opencloud-secrets` doit contenir les 12 clés (dont `wopi-secret`), et
   la policy `opencloud-policy` doit autoriser **`secret/data/...` ET `secret/metadata/...`**.
   Le rôle Vault `external-secrets` doit lister `opencloud-policy` (en plus de
   `cert-manager-policy`, `keycloak-policy`).
3. **Collabora / OnlyOffice** : non configuré → édition de documents indisponible
   (`collaboration` démarre avec un secret WOPI, sans app).
4. **Calendrier** : tester `/calendar` dans le web et un client CalDAV
   (`https://cloud.tomlab.fr/caldav/`). Radicale n'écoute que sur `127.0.0.1` ; la gate
   calshare (5233) vérifie `X-Calshare-Secret`.
5. **OCM** : stores `storage/ocm/*.json` initialisés à `{}` par l'initContainer.
6. **Ingress/Route** : `cloud.tomlab.fr` → Route TLS Let's Encrypt (cert-manager OVH).
7. **Doc** : `docs/adr/0005-opencloud.md` à mettre à jour si des choix changent.

## 6. Commandes utiles (reprise)

```sh
cd ~/projects/okd-gitops && git status && git log --oneline -3   # doit être propre, 7c3c55c

# état
oc -n argocd get app opencloud
oc -n opencloud get pods
oc -n opencloud get externalsecret opencloud-secrets

# logs utiles (le bruit NATS est filtré)
P=$(oc -n opencloud get pods -l app=opencloud -o name | head -1)
oc -n opencloud logs $P -c opencloud | grep -v '"service":"nats"' | tail -50
oc -n opencloud logs $P -c opencloud | grep -E 'no rewrite hook|policy is not|metadata missing|Autoprovisioning' | tail

# redémarrage propre (le déploiement est en Recreate)
oc -n opencloud rollout restart deploy/opencloud

# test HTTP externe
for p in /status.php /config.json / /index.php/login; do
  printf '%s -> ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "https://cloud.tomlab.fr$p"
done
```

## 7. Pièges rencontrés (pour ne pas les refaire)

- **Ne jamais** mettre une route calendrier avant `/` dans `proxy.policies[0].routes` :
  le routeur n'utilise `/` que via le *fallback* sur le premier élément → 500 partout.
- **Ne jamais** supprimer/`rm` `config/opencloud.yaml` pendant que le process tourne : le
  process relit le fichier, s'il manque le routeur perd `/`. Écriture atomique obligatoire
  (tmp + `mv`, c'est ce que fait le script).
- L'image `mikefarah/yq` : pas de `bash`, pas d'`envsubst`, pas de `perl` → `sh` + `awk`.
- `yq` : `eval-all` avec deux fichiers écrit deux documents ; `load()` est la bonne méthode.
- Les pods d'init `oc-*` créés pour le debug doivent être supprimés après usage.
- Le déploiement est en `Recreate` : toujours `scale --replicas=0` avant de toucher au PVC.
- L'ancienne arborescence `/var/lib/opencloud/data/` (instance précédente) **n'est pas
  utilisée** par la nouvelle (`storage/`, `idm/`, `nats/`, … à la racine) : ne pas la
  confondre avec les données actuelles.
