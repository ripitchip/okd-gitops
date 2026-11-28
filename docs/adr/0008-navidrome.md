# ADR 0008 : Navidrome sur le cluster `sno`

Reprise du déploiement du mainteneur (UID fixe 45249, `fsGroup`) sur OKD, même motif que
l'immich de l'ADR 0007 : SCC `restricted-v2` par défaut rejette un UID fixe hors de la
plage allouée au namespace, exports NFS TrueNAS réutilisés tels quels (ADR 0004).
Périmètre volontairement réduit à Navidrome seul (pas Deemix, pas Subwave) : ce sont des
apps distinctes dans l'ancien repo, à reprendre plus tard si besoin, pas une dépendance de
Navidrome lui-même.

## Récupération des données de l'ancien cluster

* `navidrome-data` et `navidrome-music` : exports NFS confirmés présents sur TrueNAS
  (`10.0.40.10:/mnt/data/k8s-cluster/pvc-volumes/navidrome-{data,music}`), toujours sous
  l'UID `45249` de l'ancien cluster. L'init `fix-permissions` les chown en 1000:1000, rien
  d'autre : aucun fichier de musique n'est touché.
* `ReadWriteOnce`, pas `ReadWriteMany` de l'original : cluster mono-nœud, et le pod
  (navidrome + ses sidecars) est unique de toute façon.
* Pas de SELinux à relabelliser ici (contrairement à l'ADR 0007) : ce sont des exports NFS
  déjà existants, pas un `hostPath` neuf créé par kubelet — seul ce dernier cas a posé
  problème (label `container_var_lib_t` par défaut, que `container_t` ne peut pas peupler).

## UIDs et SCC

Même motif que `immich-anyuid-chown` (ADR 0007) : SCC `navidrome-anyuid-chown` dérivée
d'`anyuid`, UID **1000** pour tous les conteneurs (y compris les sidecars), liée via
`ClusterRole` + `RoleBinding` au SA `navidrome` — `ClusterRole`, pas `Role` : l'ADR 0007 a
mis des heures à découvrir qu'un `Role` namespacé ne suffit pas pour tous les types de pods
(confirmé pour les pods créés par un Job), autant ne pas revivre ça ici même si Navidrome
n'a pas de Job.

## Secrets

Un seul secret, pour le sidecar `lyrics-fetcher` (appelle l'API Subsonic de la même
instance pour forcer la récupération des paroles manquantes) :

| Secret | Clés | Source |
| --- | --- | --- |
| `navidrome-lyrics-fetcher-creds` | `subsonic-user`, `subsonic-pass` | Vault `secret/navidrome-secrets` |

Pas de migration séparée à faire ici, contrairement à la base Postgres d'Immich (ADR
0007) : `navidrome-data` est le **même export NFS** repris tel quel, `navidrome.db`
(SQLite, confirmé présent — 68 Mo, avec `lyrics-fetcher-state.json` et `plugins/` à côté)
y est déjà. `secret/navidrome-secrets` existe aussi depuis l'ancien cluster, avec
`subsonic_user`/`subsonic_pass` déjà valides contre ce fichier (et des clés d'autres apps
de l'ancien bundle — `client_secret`, `cookie_secret`, `gemini_api_key`,
`subwave_admin_*` — hors périmètre ici, sans danger de les laisser dans le secret K8s
résultant, pareil qu'`immich-secrets` avec `redis-password`, ADR 0007). Pas de création de
compte à prévoir : les comptes de l'ancien cluster sont déjà dans la base.

## Première installation

1. Vault : policy `navidrome-policy` (lecture `secret/data/navidrome-secrets` et
   `secret/metadata/navidrome-secrets`), attachée au rôle partagé `external-secrets`
   (même mécanisme que `immich-policy`, ADR 0007) :
   ```sh
   vault policy write navidrome-policy - <<'EOF'
   path "secret/data/navidrome-secrets" { capabilities = ["read"] }
   path "secret/metadata/navidrome-secrets" { capabilities = ["read"] }
   EOF
   vault write auth/kubernetes/role/external-secrets \
     policies=<policies existantes>,navidrome-policy ...
   ```
2. DNS : `music.tomlab.fr`.
3. Sync. `fix-permissions` chown la bibliothèque (potentiellement long, des centaines de
   dossiers d'artistes sur `navidrome-music` — même ordre de grandeur que la bibliothèque
   photo d'Immich, patience) ; `navidrome` démarre sur la base existante, tous les comptes
   et la bibliothèque de l'ancien cluster sont déjà là. Le plugin paroles se télécharge au
   premier démarrage.
4. Se connecter sur `music.tomlab.fr` avec un compte existant pour vérifier.
