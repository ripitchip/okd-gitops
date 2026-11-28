# ADR 0007 : Immich sur le cluster `sno`

Reprise du déploiement fourni par le mainteneur (Kubernetes classique : UID fixes, chowns as root,
Secrets montés en fichiers) sur OKD : SCC `restricted-v2` par défaut, pas de StorageClass CSI, exports
NFS statiques TrueNAS réutilisés (ADR 0004). Règle de base : **rien de ce qui existe sur le NFS n'est
supprimé ni renommé**, les secrets sont ceux du manifeste d'origine.

## Secrets

| Secret | Clés | Source |
| --- | --- | --- |
| `immich-secrets` | `db-password`, `admin-email`, `admin-password` | Vault `secret/immich-secrets` |
| `immich-oidc` | `client-secret` | Vault `secret/immich-oidc` (client `immich` de Keycloak) |
| `immich-backup` | `api-key` | Vault `secret/immich-backup` (CronJob de dump) |

`admin-email` / `admin-password` : le premier compte d'un Immich vierge est son administrateur, créé
à la première installation. `db-password` doit être celui de la base récupérée.

## Récupération des données de l'ancien cluster

* **Bibliothèque** : l'export `/mnt/data/k8s-cluster/pvc-volumes/immich-library` est réutilisé tel
  quel (`immich-library-pvc`). L'init chown à 1000:1000 (UID de la plage comme vaultwarden, ADR 0004)
  et ne touche à rien d'autre : il crée les dossiers Immich s'ils manquent (Immich le fait lui-même),
  restaure un `.immich` manquant seulement si les autres sont là, supprime les `*.tmp` de `backups/`
  (restes de dumps ratés, doc Immich). Jamais un fichier de données.
* **Base** : l'export `/mnt/data/k8s-cluster/pvc-volumes/immich-db` (`immich-db-pvc`) est conservé,
  mais n'est **pas** PGDATA : l'entrypoint immich-postgres refuse un FS réseau (« network shares will
  corrupt your data »). PGDATA est `immich-db-local` (`hostPath /var/lib/immich-db` du nœud), le
  disque de l'ancien cluster ne se déplaçant pas. La reprise est une étape manuelle (ci-dessous),
  elle ne modifie pas l'export.
* **Redis** : `emptyDir`, les files Immich se reconstruisent.

## Ondes de synchronisation

| onde | objet |
| --- | --- |
| -20 | SCC `immich-anyuid-chown`, PV/PVC |
| -15 | Role/RoleBinding donnant l'usage de la SCC aux SA |
| -5 | ConfigMaps (config, OIDC, scripts, défauts) |
| 0 | ExternalSecrets (sauf `immich-backup-sync`, onde 11 : voir plus bas) |
| 7 | ServiceAccounts, Services |
| 8 | `immich-postgres`, `immich-redis`, `immich-machine-learning` |
| 9 | Job `immich-migrate` (migrations du schéma) |
| 10 | `immich-server` |
| 11 | `immich-microservices`, CronJob `immich-db-backup`, `immich-backup-sync` |

Argo CD bloque bel et bien entre ondes (attend que l'onde précédente soit saine avant la suivante) :
constaté en déployant pour la première fois, le Job `immich-migrate` échouait avec `ECONNREFUSED` sur
postgres et redis tant qu'il tournait avant eux (ancienne onde 5, avant leur onde 8) — l'onde 9
corrige ça. Pour la même raison, `immich-backup-sync` était à l'onde 0 avec les deux ExternalSecrets
nécessaires au démarrage : son échec volontaire (avant le premier démarrage) bloquait tout le reste
du déploiement, d'où son onde 11, après tout ce qui en dépend.

## UIDs et SCC

Les UID 15432-15435 du cluster d'origine sont hors plage ici. UID **1000** pour tous les conteneurs
Immich (postgres, redis, server, microservices, machine-learning, migrate) ; leurs init
`fix-permissions` tournent en UID **0** avec `capabilities.add: [CHOWN, FOWNER]`, même motif que le
`fix-permissions` de la bibliothèque dans `immich-server` : `anyuid` interdit tout ajout de capacité
(`allowedCapabilities: null`), d'où la SCC dédiée `immich-anyuid-chown`, dérivée d'anyuid (comme
`openldap-anyuid-netbind`). Elle est liée à chaque SA qui fixe `runAsUser: 1000` — toutes sauf
`immich-db-backup`, qui n'en a pas besoin — car `restricted-v2` (la SCC par défaut du SA) rejette un
UID fixe hors de la plage allouée au namespace.

## Base de données

* Migrations par le Job `immich-migrate` (image `immich-server`, `immich-admin schema-check`),
  pas par l'image postgres (pas de node). Le serveur garde `DB_SKIP_MIGRATIONS=false` : c'est lui qui
  pose le `search_path`.
* `DB_STORAGE_TYPE=HDD`, `IGNORE_DATABASE_FSTYPE=true` (l'entrypoint ne connaît que ext2/3/4, xfs,
  btrfs, zfs, f2fs, tmpfs), `/dev/shm` en `emptyDir`, `PGDATA=data/pgdata`.
* `immich-db-pvc` (export de l'ancien cluster) n'est monté que pour la reprise manuelle.

## Migration en place (depuis l'ancien cluster)

1. Stopper les anciens pods Immich (autre cluster) : la base de l'export devient cohérente.
2. Dumper l'ancienne base **en lecture**, sans rien supprimer dans l'export :
   ```sh
   # là où l'export immich-db est lisible (shell TrueNAS, Linux ISO…) :
   mkdir -p /mnt/.../pvc-volumes/immich-db/backups
   chgrp -R 1000 /mnt/.../pvc-volumes/immich-db          # lisible par le pod (UID 1000)
   (umask 007; /usr/lib/postgresql/<majeure>/bin/pg_dump -U immich -d immich -Fc \
      -f /mnt/.../pvc-volumes/immich-db/backups/immich-restore-$(date +%Y%m%d).dump)
   ```
   Le tag `-upgrade` de l'image postgres ne sert que si le PGDATA peut être local : impossible ici
   (le disque est par nœud), d'où le dump.
3. Laisser l'initdb de `immich-postgres` finir (`oc -n immich wait --for=condition=Ready pod …`).
4. Charger le dump dans la base locale : la base est sur le disque du nœud, visible par
   `oc debug node/... -- chroot /host` (`/var/lib/immich-db/pgdata`) ; `pg_restore`/`psql` avec les
   clients de l'image `immich-server` (toutes les versions majeures), ou une image `postgres:17`.
5. Laisser `immich-migrate` migrer le schéma (sync), se connecter, vérifier les photos. La
   bibliothèque reste à sa place : rien à déplacer.

## Première installation (base vierge)

1. Vault : `secret/immich-secrets` (`db-password` hex 32, `admin-email`, `admin-password`),
   `secret/immich-oidc` (`client-secret`), `secret/immich-backup` (`api-key` provisoire).
2. TrueNAS : export `immich-library` ; nœud : `/var/lib/immich-db`, labellisé `container_file_t`
   (sinon AVC `denied { create }` du `fix-permissions` de `immich-postgres`, confirmé en direct —
   un `hostPath` neuf hérite de `container_var_lib_t`, que la politique SELinux ne laisse pas un
   conteneur peupler) :
   ```sh
   semanage fcontext -a -t container_file_t "/var/lib/immich-db(/.*)?"
   restorecon -Rv /var/lib/immich-db
   ```
   DNS `photos.tomlab.fr`.
3. Keycloak : client confidentiel `immich`, redirect URIs `https://photos.tomlab.fr/auth/login`,
   `https://photos.tomlab.fr/user-settings`, `app.immich:///oauth-callback`.
4. Sync. `immich-migrate` passe, `immich-server` démarre, `api-key.sh` crée le compte admin et la clé.
5. Copier `/run/secrets/key.txt` (`oc exec -c api-key -- cat`) dans `secret/immich-backup`, puis
   `oc -n immich create job --from=cronjob/immich-db-backup dump-manual`.
6. Se connecter (web : compte local `admin-email`, app mobile : Keycloak) et donner le rôle admin
   aux comptes OIDC dans Administration > Users.

## Images

v3.4.2 partout (v3.4.1 / v3.0.2 de l'original alignés ; l'image ML `-openvino` n'existe plus, l'image
CPU est utilisée). `immich microservices` est déprécié : `IMMICH_WORKERS_INCLUDE`.

## Sauvegardes

CronJob `immich-db-backup` (03:00) → `POST /api/jobs {"name":"databaseBackup"}` avec la clé de
`immich-backup`, dump dans `backups/` du volume. La restauration UI exige aussi `library/`, `upload/`,
`profile/`, `thumbs/`, `encoded-video/` : snapshots du NFS à organiser.

## Limites connues

* `api-key.sh` fait tourner la clé à chaque redémarrage du pod tant que `secret/immich-backup` ne la
  contient pas : copier la clé dans Vault après la première installation.
* Une base récupérée garde ses comptes : `admin-email` ne crée rien dessus, la clé se fait depuis le
  web (Compte > Clés API) et se dépose dans Vault.
