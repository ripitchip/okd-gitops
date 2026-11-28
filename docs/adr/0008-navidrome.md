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

Pas de bootstrap admin automatisé (contrairement à Immich) : **le premier compte créé via
l'UI web devient administrateur**. `subsonic-user`/`subsonic-pass` ne sont donc pas
inventés à l'avance : ce sont les identifiants d'un compte Navidrome réel, créés *après*
que l'app tourne, et déposés dans Vault ensuite.

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
   photo d'Immich, patience) ; `navidrome` démarre, le plugin paroles se télécharge au
   premier démarrage.
4. `navidrome-lyrics-fetcher-creds-sync` reste en échec jusqu'à l'étape suivante — normal,
   pas bloquant (`ExternalSecret` seul, pas de wave critique comme `immich-backup-sync`,
   ADR 0007 : le sidecar attend juste le secret).
5. Se connecter sur `music.tomlab.fr`, créer le premier compte (devient admin). Créer un
   compte dédié pour le sidecar (ou réutiliser l'admin), puis :
   ```sh
   vault kv put secret/navidrome-secrets \
     subsonic_user="<compte>" subsonic_pass="<mot de passe>"
   ```
6. `navidrome-lyrics-fetcher-creds-sync` passe au vert (retente toutes les heures, ou
   forcer : `oc -n navidrome annotate externalsecret navidrome-lyrics-fetcher-creds-sync force-sync="$(date +%s)" --overwrite`).
