# okd-gitops

Config GitOps du cluster OKD, gérée par Argo CD (app of apps).

Cluster actuel : `sno`, OKD 5.0 (SCOS 10), GPU NVIDIA RTX 2000 Ada.

## Structure

- `bootstrap/` — point d'entrée, appliqué à la main une seule fois
- `clusters/sno/apps/` — liste des Applications Argo CD
- `platform/` — config de chaque composant (base + overlay)
- `docs/adr/` — décisions d'architecture
- `scripts/validate.sh` — à lancer avant de pousser

TODO: bootstrap (commandes `oc`)
TODO: opérations courantes (upgrade Argo CD, GPU operator, kernel)
TODO: ADR
