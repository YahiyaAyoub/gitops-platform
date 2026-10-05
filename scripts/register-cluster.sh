#!/usr/bin/env bash
# Register a kind cluster with Argo CD on the hub, using its in-network address.
# Usage: scripts/register-cluster.sh <kind-cluster-name> <env-label>
set -euo pipefail
NAME="$1"; ENV="$2"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
kind get kubeconfig --name "$NAME" --internal > "$TMP"
jp() { kubectl --kubeconfig "$TMP" config view --raw -o jsonpath="$1"; }
SERVER=$(jp '{.clusters[0].cluster.server}')
CA=$(jp '{.clusters[0].cluster.certificate-authority-data}')
CERT=$(jp '{.users[0].user.client-certificate-data}')
KEY=$(jp '{.users[0].user.client-key-data}')
kubectl --context kind-hub apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-${NAME}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    env: ${ENV}
    cluster: ${NAME}
type: Opaque
stringData:
  name: ${NAME}
  server: ${SERVER}
  config: |
    {"tlsClientConfig":{"caData":"${CA}","certData":"${CERT}","keyData":"${KEY}"}}
YAML
echo "Registered ${NAME} (${SERVER}) with env=${ENV}"
