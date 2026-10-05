# Helm values precedence (lowest → highest; last wins)

1. `apps/<app>/chart/values.yaml` — chart defaults
2. `apps/<app>/values/values-common.yaml` — shared by every cluster
3. `apps/<app>/values/env/values-<env>.yaml` — per environment (`env` label on the cluster secret)
4. `apps/<app>/values/clusters/values-<cluster>.yaml` — per cluster, only if it differs
5. ApplicationSet `helm.parameters` — identity injected from the generator (`clusterName`, `env`)

Layers 3 and 4 are optional (`ignoreMissingValueFiles: true`): a new cluster needs no file
unless it actually overrides something.
