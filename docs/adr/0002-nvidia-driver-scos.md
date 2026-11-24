# ADR 0002 : driver NVIDIA sur SCOS 10

Le GPU Operator ne compile pas le driver sur SCOS (image `centos10` inexistante). On utilise l'image `rocky10` à la place, avec les RPM du kernel récupérés sur Koji et servis via un `kernel-repo` interne (pas sur les miroirs CentOS Stream).

À faire avant chaque upgrade OKD qui change de kernel : mettre à jour `KERNEL_VERSION`.

Alternative plus propre à terme : builder l'image driver depuis le driver-toolkit de la release OKD.
