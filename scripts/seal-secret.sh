#!/usr/bin/env bash
set -euo pipefail

# Generate and seal a real Kubernetes Secret for podinfo using kubeseal.
# Requires: kubectl (pointing at your cluster with sealed-secrets-controller) & kubeseal.
#
# Usage:
#   ./scripts/seal-secret.sh <dev|prod> [jwt-secret]
#
# After generating k8s/overlays/<env>/sealed-secret.yaml, add `- sealed-secret.yaml`
# to resources in k8s/overlays/<env>/kustomization.yaml and commit to Git.

ENV="${1:-}"
if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Usage: $0 <dev|prod> [jwt-secret]" >&2
  exit 1
fi

SECRET_VAL="${2:-$(openssl rand -hex 32)}"
OUT_FILE="k8s/overlays/${ENV}/sealed-secret.yaml"

kubectl create secret generic podinfo-secrets \
  --namespace "podinfo-${ENV}" \
  --from-literal="config.yaml=jwt-secret: ${SECRET_VAL}" \
  --dry-run=client \
  -o yaml \
  | kubeseal \
      --controller-name=sealed-secrets-controller \
      --controller-namespace=kube-system \
      --format yaml \
      > "$OUT_FILE"

echo "Wrote encrypted SealedSecret to ${OUT_FILE}"
