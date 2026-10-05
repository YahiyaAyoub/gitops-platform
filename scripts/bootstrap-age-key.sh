#!/usr/bin/env bash
# Place the env's age private key on a cluster as a K8s Secret (never committed).
# Usage: scripts/bootstrap-age-key.sh <kind-cluster> <env>
set -euo pipefail
CLUSTER="$1"; ENV="$2"
kubectl --context "kind-$CLUSTER" create namespace sops-system --dry-run=client -o yaml \
  | kubectl --context "kind-$CLUSTER" apply -f -
kubectl --context "kind-$CLUSTER" -n sops-system create secret generic sops-age-key-file \
  --from-file=key="$HOME/.config/sops/age/$ENV.key" --dry-run=client -o yaml \
  | kubectl --context "kind-$CLUSTER" apply -f -
echo "age key for env=$ENV placed on $CLUSTER"
