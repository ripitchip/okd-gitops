# okd-gitops

Config GitOps du cluster OKD, gérée par Argo CD (app of apps).

Cluster actuel : `sno`, OKD 5.0 (SCOS 10), GPU NVIDIA RTX 2000 Ada.

## Structure

- `bootstrap/` — point d'entrée, appliqué à la main une seule fois
- `clusters/sno/apps/` — liste des Applications Argo CD
- `platform/` — config de chaque composant (base + overlay)
- `docs/adr/` — décisions d'architecture
- `scripts/validate.sh` — à lancer avant de pousser

## Bootstrap (nouvelle install du cluster `sno`)

Prérequis : `oc login` sur le cluster en `cluster-admin`.

```sh
# 1. le namespace argocd doit exister avant que l'Application (root-app) puisse être créée dedans
oc new-project argocd

# 2. point d'entrée unique, à la main, une seule fois
oc apply -f bootstrap/root-app.yaml

# 3. suivre la synchronisation (ordre piloté par sync-wave : project -20, argocd -10, gpu-operator-prereqs 0, gpu-operator 10)
oc get applications -n argocd -w
```

Accès à l'UI Argo CD une fois le sync-wave -10 passé :

```sh
oc get route argocd -n argocd -o jsonpath='{.spec.host}{"\n"}'
oc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

### Vérifs spécifiques au GPU Operator

Le `KERNEL_VERSION` codé dans `platform/gpu-operator/prereqs/overlays/sno/kernel-version.yaml` doit correspondre
exactement au noyau du nœud (sinon `kernel-repo` télécharge les mauvais RPM et le build du driver échoue) :

```sh
oc debug node/<node> -- chroot /host uname -r
```

Si ça ne correspond pas à la valeur du fichier (ex. changement de version OKD → nouveau noyau), mettre à jour
`kernel-version.yaml` **avant** que `gpu-operator-prereqs` ne synchronise (cf. ADR 0002).

```sh
# le kernel-repo doit être Ready et servir son repodata avant que gpu-operator (wave 10) ne démarre
oc get pods -n nvidia-gpu-operator -w

# une fois tout Running : le GPU doit apparaître dans les capacités du nœud
oc get node <node> -o jsonpath='{.status.capacity}' | jq
```

## Opérations courantes

- **Upgrade OKD qui change de noyau** : mettre à jour `KERNEL_VERSION` dans `kernel-version.yaml` (ADR 0002)
  avant l'upgrade, sinon le driver GPU ne rebuild pas.
- **Upgrade du driver NVIDIA** : récupérer le nouveau digest avec
  `skopeo inspect --format '{{.Digest}}' docker://nvcr.io/nvidia/driver:<version>-rocky10` et le mettre dans
  `platform/gpu-operator/operator/values-sno.yaml`.
- **Upgrade Argo CD** : changer le tag dans `platform/argocd/base/kustomization.yaml` (URL `install.yaml`).
- **Upgrade OpenCloud** : changer le tag dans `platform/opencloud/app.yaml` (Deployment + extensions),
  puis re-vérifier `proxy-routes.yaml` contre les routes par défaut de la nouvelle version
  (cf. ADR 0005 : une politique proxy versionnée ne reçoit pas les nouvelles routes).
- Toujours lancer `scripts/validate.sh` avant de pousser.
