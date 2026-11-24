# ADR 0001 : mono-repo pour la plateforme

Un seul cluster, une seule équipe pour l'instant → un seul dépôt (`platform/` = comment, `clusters/` = quoi/où).

On repassera en multi-repo si : des équipes appli veulent déployer leurs propres apps, des droits d'accès différents sont nécessaires, ou le volume devient trop gros pour Argo CD.
