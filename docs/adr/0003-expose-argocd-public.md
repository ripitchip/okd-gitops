# ADR 0003 : exposition publique d'Argo CD

Besoin : Argo CD joignable depuis internet via port-forward sur la box.

## CNI : pas de changement

Le cluster tourne sur OVN-Kubernetes (choisi à l'installation, non modifiable en day-2 sans réinstaller).
Cilium a été envisagé mais écarté : les besoins réels (NetworkPolicy, IP exposée) ne le nécessitent pas.
`NetworkPolicy` standard est déjà supporté nativement par OVN-Kubernetes.

## Pas de MetalLB

MetalLB apporte une IP flottante indépendante d'un nœud précis — utile en multi-nœud, inutile sur un SNO
(un seul nœud possible de toute façon). L'opérateur n'est de plus pas présent dans le catalogue
`community-operators` de ce cluster (ajouter un CatalogSource externe pour zéro bénéfice réel).

L'`IngressController` par défaut utilise déjà `endpointPublishingStrategy: HostNetwork` : le routeur
écoute directement sur l'IP du nœud (`10.0.50.10:80/443`). C'est donc cette IP qu'on NAT depuis la box —
pas de composant supplémentaire à déployer.

## TLS : cert-manager

La Route Argo CD est en `passthrough` (le navigateur voit le certificat auto-signé d'Argo CD). Pour un
accès public propre, cert-manager (opérateur OLM, `platform/cert-manager/`) émettra un certificat via
ACME ; le solver (HTTP-01 vs DNS-01) et le `ClusterIssuer` restent à définir selon le provider DNS de
`tomlab.fr`.

## À faire (hors de ce repo, côté box/DNS)

- NAT box : IP publique → `10.0.50.10` ports 80/443.
- DNS public : `argocd-argocd.apps.okd.tomlab.fr` (ou domaine dédié) → IP publique.
