# ADR 0009 : Natel sur le cluster `sno`

Repris de `gitops-argocd/infrastructure/03-apps/natel` : éditeur web de contacts CardDAV,
utilisé pour éditer les contacts du Radicale intégré à OpenCloud (celui-ci n'a pas
d'éditeur natif). Se connecte à `http://opencloud.opencloud.svc.cluster.local:9200`
(service interne, port confirmé dans `platform/opencloud/app.yaml`), qui fait la
découverte CardDAV et route en interne vers Radicale.

## Pas de SCC dédiée, contrairement à Immich/Navidrome

Les ADR 0007 et 0008 fixent un UID (via une SCC `anyuid`-dérivée) parce que ces apps ont
des volumes NFS repris de l'ancien cluster, déjà possédés par un UID fixe qu'il faut
reprendre pour une ownership stable dans la durée (chown une fois, puis plus jamais).
Natel n'a **aucun volume, aucun secret, aucun fichier à lui** : rien ne force à fixer un
UID. `runAsUser` n'est volontairement pas précisé — `restricted-v2` (la SCC par défaut)
assigne un UID de la plage allouée au namespace, et l'image (générique, sans état) n'a pas
besoin de plus. Premier test réel du modèle natif d'OKD évoqué dans l'ADR 0007 ("UIDs et
SCC") : si ça fonctionne tel quel, c'est le motif à préférer chaque fois qu'une app n'a pas
de contrainte d'ownership héritée.

## Réseau

Pas de `NetworkPolicy` : `platform/opencloud/radicale.yaml` restreint déjà l'accès à
Radicale au seul pod `opencloud` (commentaire : "Radicale and calshare trust
X-Remote-User"), ce que Natel ne contourne pas (il parle à OpenCloud, pas directement à
Radicale). Rien côté Natel n'a besoin d'être protégé en retour.

## DNS

`contacts.tomlab.fr` (pas de second host `foobarbaz.fr`, même simplification que les ADR
précédents).
