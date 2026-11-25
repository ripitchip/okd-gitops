# ADR 0004 : gestion des secrets — Vault + External Secrets + cert-manager OVH

Besoin : TLS public pour Argo CD/Vault via Let's Encrypt (DNS-01, provider OVH pour `tomlab.fr`), sans
mettre le token API OVH en clair dans le repo.

## Reprise de l'existant (migration, pas une nouvelle conception)

Ce cluster remplace un cluster précédent sur le même NFS (TrueNAS, `10.0.40.10`, anciennement
`10.0.60.10`). Les exports `pvc-volumes/<app>` existants sont réutilisés tels quels (PV statique,
`storageClassName` sert juste d'étiquette de correspondance PV/PVC — pas de CSI/provisioner sur ce
cluster, d'où `oc get storageclass` vide).

## Chaîne

```
Vault (KV, PV statique NFS) ← ExternalSecret ← ClusterSecretStore (External Secrets Operator)
                                                        ↓
                                        Secret K8s (token API OVH)
                                                        ↓
                                     cert-manager-webhook-ovh (solver DNS-01)
                                                        ↓
                                         ClusterIssuer letsencrypt-prod
                                                        ↓
                                    Certificate → Route Argo CD / Vault (edge/reencrypt)
```

cert-manager est déployé en Helm (pas via l'opérateur OLM) : `releaseName: cert-manager-release`,
pour que `cert-manager-webhook-ovh` s'attache au bon ServiceAccount (`certManager.serviceAccountName`).

## UID : pas de valeurs fixes

Les charts Vault/External Secrets du cluster d'origine fixaient des UID (9058, 4712, 5823, 6934).
Retirés ici : la SCC `restricted-v2` alloue une plage par namespace, propre à ce cluster — un UID fixe
venu d'ailleurs est rejeté (même problème que `argocd-dex-server`, cf. historique du repo).

## Étapes manuelles (non-GitOps, volontairement)

L'initialisation et le déverrouillage de Vault ne sont **pas** automatisés : les clés unseal / le root
token ne doivent transiter par aucun pipeline. Une fois Vault `Running` :

1. `vault operator init` (une fois) → conserver les clés unseal + root token en lieu sûr (password
   manager), jamais dans ce repo.
2. `vault operator unseal` (à chaque redémarrage du pod, tant que l'auto-unseal n'est pas configuré).
3. Activer le moteur KV et y écrire le token API OVH.
4. Activer l'auth Kubernetes, créer une policy + un role lisant ce secret, pour que External Secrets
   Operator (ClusterSecretStore) puisse s'authentifier.
5. Créer le `ClusterSecretStore` (Vault) et l'`ExternalSecret` qui matérialise le secret OVH en Secret K8s.
6. Créer le `ClusterIssuer letsencrypt-prod` référençant ce Secret via `cert-manager-webhook-ovh`.

À faire avant toute reconstruction future du cluster : ADR 0002 s'applique aussi ici — si le noyau change,
`kernel-version.yaml`; si TrueNAS change d'IP, mettre à jour `platform/vault/pvc/pv-pvc.yaml`.
