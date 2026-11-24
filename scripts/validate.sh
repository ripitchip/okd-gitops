#!/usr/bin/env bash
# Valide le rendu de tous les overlays Kustomize (à lancer en local ou en CI).
# Prérequis : kustomize (ou oc), et optionnellement kubeconform pour valider les schémas.
set -euo pipefail

cd "$(dirname "$0")/.."

if command -v kustomize >/dev/null; then
  BUILD="kustomize build"
elif command -v oc >/dev/null; then
  BUILD="oc kustomize"
else
  echo "kustomize ou oc requis" >&2
  exit 1
fi

status=0
while IFS= read -r dir; do
  printf '%-55s' "$dir"
  if out=$($BUILD "$dir" 2>&1); then
    if command -v kubeconform >/dev/null; then
      if echo "$out" | kubeconform -strict -summary -ignore-missing-schemas >/dev/null; then
        echo "OK"
      else
        echo "SCHÉMA INVALIDE"; status=1
      fi
    else
      echo "OK (rendu)"
    fi
  else
    echo "ÉCHEC"; echo "$out" | sed 's/^/    /'; status=1
  fi
done < <(find clusters platform -name kustomization.yaml -printf '%h\n' | sort)

exit $status
