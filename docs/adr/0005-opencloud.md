# ADR 0005 : OpenCloud 9.1.0 sur le cluster `sno`

Reprise d'un déploiement existant (fichier passé par le mainteneur), adapté aux contraintes du cluster :
Keycloak externe, NFS TrueNAS, SCC `restricted-v2`, secrets Vault.

## Fichiers

- `platform/opencloud/app.yaml` — Deployment `opencloud` : un seul processus `opencloud server`
  (tous les services dans le pod, comme `opencloud-compose`), Service, Ingress → Route.
- `platform/opencloud/radicale.yaml` — pod calendrier : Radicale + sidecar calshare
  (`opencloud-calendar-share` v0.5.0), NetworkPolicy.
- `platform/opencloud/opencloud-config.yaml` — `opencloud.yaml.tmpl` versionné (une clé par service,
  placeholders de secrets).
- `platform/opencloud/proxy-routes.yaml` — politique proxy `default` complète + routes calendrier.
- `platform/opencloud/role-mapping.yaml` — rôle OpenCloud selon le claim `groups` de Keycloak.
- `platform/opencloud/web-config.yaml`, `csp.yaml` — `config.json` de l'UI web et CSP du proxy.
- `platform/opencloud/externalsecret.yaml` — Secret `opencloud-secrets` (Vault `secret/opencloud-secrets`).
- `platform/opencloud/pv-pvc.yaml` — PV/PVC statiques NFS (exports existants).

## Pas de `opencloud init`

`opencloud init` génère des secrets aléatoires (JWT, service account, mots de passe IDM) et ne s'exécute
qu'une fois par volume. Sur un volume vide ou un pod recréé, c'est une nouvelle base IDM et de nouveaux
secrets : sessions, clients de sync et admin local cassés, et boucle d'init si le fichier n'est pas écrit.

À la place, un initContainer (`opencloud-config`, image `mikefarah/yq`) rend `opencloud.yaml` à chaque
démarrage : template versionné + secrets Vault (`envsubst`) + fusion des routes proxy. Les identifiants
générés par init qui doivent rester stables (`system_user_id`, `admin_user_id`, `mount_id`, id du service
account) sont des UUID fixes, non secrets, dans le template.

## Proxy : `proxy: {}` d'init écrase toutes les routes

Dans OpenCloud 9, une section `proxy:` du YAML (même vide) remplace intégralement la config par défaut :
il ne reste qu'une route `/` → web (pas de `/graph`, `/dav`, `/ocs`... : login et sync cassés). La
politique `default` complète de l'image v9.1.0 est donc versionnée dans `proxy-routes.yaml`. À revoir à
chaque montée de version (nouvelles routes par défaut).

## Keycloak

- Issuer `https://auth.tomlab.fr/realms/foobarbaz`, client public `web` (PKCE), redirect URIs
  `https://cloud.tomlab.fr/` et `https://cloud.tomlab.fr/oidc-callback.html`, claim `groups` exposé.
- `OC_EXCLUDE_RUN_SERVICES=idp` : l'IDP intégré est désactivé, l'IDM (LDAP interne) reste pour les
  comptes (auto-provisioning au premier login, `PROXY_AUTOPROVISION_ACCOUNTS=true`).
- Le compte `admin` créé par l'IDM n'existe pas dans Keycloak : l'admin OpenCloud vient du claim
  `groups` (groupe Keycloak `opencloudAdmin` → rôle `admin`, voir `role-mapping.yaml`).

## NFS, SCC et propriétaires de fichiers

`restricted-v2` (SCC par défaut) : pas d'UID fixe, pas de chown as root. Les conteneurs tournent donc avec
l'UID de la plage du namespace, et les volumes NFS (créés par un ancien cluster, propriétaire inconnu)
sont chownés par un initContainer non privilégié (`chown -R $(id -u):$(id -g)`), pas par root.

## Calendrier

Radicale n'écoute que sur `127.0.0.1` dans son pod ; le proxy passe par la gate calshare (5233), qui
vérifie `X-Calshare-Secret` (Secret `opencloud-secrets`, clé `CALSHARE_PROXY_SECRET`) avant de transmettre
`X-Remote-User`. L'app web `calendar` (v0.5.0, sha256 vérifié) utilise `/calshare/v1` (sidecar, port 8080)
pour le partage et les invitations.

## Étapes manuelles

1. Vault : `secret/opencloud-secrets` doit contenir les 11 clés de `externalsecret.yaml` (commande
   `vault kv put` en tête de ce fichier), et la policy `opencloud-policy` doit autoriser `secret/data/...`
   **et** `secret/metadata/...` (sinon « could not get secret data from provider »). Les mots de passe
   `idm-*` sont hachés dans la base IDM à sa première initialisation ; les changer ensuite n'a pas d'effet.
2. Keycloak : vérifier le client `web`, les redirect URIs, et le groupe `opencloudAdmin`.
3. DNS public `cloud.tomlab.fr` → IP publique (NAT box → routeur du cluster), comme `auth`/`vault`.

## À savoir

- NFS : pas d'inotify/xattrs fiables, d'où `STORAGE_USERS_DRIVER=decomposed` (les fichiers sont stockés
  dans le volume, pas d'index incrémental comme le driver `posix`).
- `storage-system` (base des espaces et des métadonnées) n'a pas d'option documentée pour sortir du
  `$OC_BASE_DATA_PATH` : ses données vivent dans `storage/metadata` du même volume.
- L'extension `draw-io` est conservée ; la CSP autorise déjà `embed.diagrams.net`.
- Collabora/OnlyOffice (`collaboration`) n'est pas configuré : l'édition web de documents n'est pas active.
