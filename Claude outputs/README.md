# Multi-Cluster GitOps & Autoscaling Platform

One git repository drives every cluster. Argo CD on a **hub** cluster deploys to all **target** clusters
through ApplicationSets, with no per-cluster copy-paste. Secrets are SOPS-encrypted and only decrypted
inside the target cluster. Pods scale to zero with KEDA, and nodes scale with Karpenter (KWOK provider)
inside cost guardrails. Prometheus alerts and Argo CD Notifications post to Slack, labelled by cluster.

Everything runs locally on kind and is free.

> Design note for 10+ clusters: **[docs/design-note.md](docs/design-note.md)**

---

## Architecture

```
                     GitHub: gitops-platform  (single source of truth)
                                   │ pull
          ┌────────────────────────▼─────────────────────────┐
          │ hub (kind)                                        │
          │  Argo CD ── root app ──► bootstrap/appsets/*      │
          │  ApplicationSets (cluster generator, label-based) │
          │  Argo CD Notifications ──► Slack                  │
          │  sops-secrets-operator (hub age key)              │
          └──────┬──────────────────┬──────────────────┬──────┘
   cluster secret│ env=dev          │ env=dev          │ env=prod
   + labels      │ karpenter=enabled│                  │ (manual sync gate)
          ┌──────▼──────┐    ┌──────▼──────┐    ┌──────▼──────┐
          │ dev         │    │ dev-2       │    │ prod        │
          │ sample-app  │    │ sample-app  │    │ sample-app  │
          │ scale-demo  │    │ scale-demo  │    │ scale-demo  │
          │ KEDA + HTTP │    │ KEDA + HTTP │    │ KEDA + HTTP │
          │ SOPS op.    │    │ SOPS op.    │    │ SOPS op.    │
          │ kube-prom   │    │ kube-prom   │    │ kube-prom   │──► Alertmanager ──► Slack
          │ Karpenter + │    └─────────────┘    └─────────────┘
          │ KWOK        │
          └─────────────┘
```

**Label-driven targeting.** ApplicationSets select clusters by labels on their Argo CD cluster secret:

| Label | Effect |
| --- | --- |
| `env=dev` | Apps auto-sync (prune + self-heal); dev values layer applies |
| `env=prod` | Apps require a **manual sync** (promotion gate); prod values layer applies |
| `karpenter=enabled` | Cluster gets Karpenter, NodePool/KWOKNodeClass and the `inflate` test workload |
| `monitoring=disabled` | Cluster opts out of kube-prometheus-stack |

## Repository layout

```
bootstrap/
  argocd/values.yaml          Argo CD OSS Helm chart values (hub)
  root-app.yaml               app-of-apps: manages everything in bootstrap/appsets/
  appsets/                    one ApplicationSet per app/add-on (+ 2 hub-only Applications)
apps/
  sample-app/chart/           podinfo chart; secrets/<env>.enc.yaml (SOPS)
  sample-app/values/          values-common.yaml → env/values-<env>.yaml → clusters/values-<cluster>.yaml
  scale-demo/                 KEDA HTTP scale-to-zero demo service
  inflate/                    pause-image workload + ResourceQuota for the Karpenter demo
platform/
  sops-secrets-operator/      operator values (age key mount)
  karpenter-config/           NodePool + KWOKNodeClass chart with layered values (per-cluster CPU limit)
  monitoring/values/          kube-prometheus-stack values (layered) incl. Alertmanager → Slack
  monitoring-config/          PrometheusRules + SOPS-encrypted Alertmanager webhook
  hub-notifications/          argocd-notifications-cm + SOPS-encrypted webhook (hub)
scripts/                      register-cluster.sh, bootstrap-age-key.sh, demo-*.sh
docs/                         design-note.md, values-precedence.md, evidence/
.sops.yaml                    per-environment encryption rules
.githooks/pre-commit          blocks unencrypted *.enc.yaml + gitleaks scan
```

## Bootstrap (from an empty laptop)

Prereqs: Docker runtime (Colima: `colima start --cpu 6 --memory 12 --disk 80`), `kind kubectl helm argocd sops age gitleaks hey go ko kwok`.

```bash
# 0. Raise inotify limits for multiple kind clusters (reset on VM restart)
colima ssh -- sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512

# 1. Clusters
for c in hub dev prod dev-2; do kind create cluster --name $c; done

# 2. Argo CD on the hub (OSS Helm chart)
helm upgrade --install argocd argo/argo-cd --kube-context kind-hub -n argocd --create-namespace \
  --version <pinned> -f bootstrap/argocd/values.yaml --wait

# 3. Register targets (in-network address; labels drive everything)
scripts/register-cluster.sh dev dev
scripts/register-cluster.sh prod prod
scripts/register-cluster.sh dev-2 dev
kubectl --context kind-hub -n argocd label secret cluster-dev karpenter=enabled

# 4. Age private keys onto clusters (one-time, out of band, never in git)
scripts/bootstrap-age-key.sh dev dev; scripts/bootstrap-age-key.sh dev-2 dev
scripts/bootstrap-age-key.sh prod prod; scripts/bootstrap-age-key.sh hub hub

# 5. Karpenter KWOK provider on dev (no published image: build from the pinned tag)
git clone --depth 1 --branch v1.14.1 https://github.com/kubernetes-sigs/karpenter.git && cd karpenter
KUBECONFIG=<(kind get kubeconfig --name dev) ./hack/install-kwok.sh
KO_DOCKER_REPO=kind.local KIND_CLUSTER_NAME=dev ko build --platform=linux/arm64 -B -t v1.14.1 sigs.k8s.io/karpenter/kwok

# 6. Hand over to GitOps — everything else comes from git
kubectl --context kind-hub apply -f bootstrap/root-app.yaml
git config core.hooksPath .githooks
```

UI: `kubectl --context kind-hub -n argocd port-forward svc/argocd-server 8080:80` →
http://localhost:8080. CLI: `argocd login localhost:8080 --plaintext --skip-test-tls` (see Known issues).

---

## Task-by-task

### 1. Basics — Argo CD on a hub, two targets, one app each
Argo CD is installed on `hub` from the OSS Helm chart. `dev` and `prod` are registered declaratively with
`scripts/register-cluster.sh`, which uses the kind-internal API address (`https://<name>-control-plane:6443`).
`127.0.0.1` would point at the Argo CD pod itself. The plain per-cluster Applications are preserved at git
tag `task1-per-cluster-apps`.
Evidence: `docs/evidence/task1-synced-healthy.png`, `task1-app-list.txt`.

### 2. No copy-paste — one ApplicationSet, layered values
`bootstrap/appsets/sample-app.yaml` uses a **cluster generator** (`env In [dev, prod]`). Values precedence,
lowest to highest ([docs/values-precedence.md](docs/values-precedence.md)):

1. `chart/values.yaml` (defaults)
2. `values/values-common.yaml` (all clusters)
3. `values/env/values-<env>.yaml` (from the cluster's `env` label)
4. `values/clusters/values-<cluster>.yaml` (only if this cluster differs)
5. ApplicationSet `helm.parameters` (cluster identity)

`ignoreMissingValueFiles: true` means a new cluster needs no file. **Proof:** `dev-2` was created and
registered with **no commit**, and `sample-app-dev-2` appeared Synced and Healthy. Then a single file
`values/clusters/values-dev-2.yaml` overrode the message for dev-2 only.
Evidence: `task2-third-cluster.png`, `task2-git-log.txt`, `task2-single-cluster-override.txt`.

### 3. Per-cluster differences + promotion flow
The env layer gives dev a feature flag and colour and gives prod 2 replicas. The cluster layer gives dev-2
its own message. **Promotion:** a `templatePatch` enables automated sync only when `env=dev`. A change to
the common layer auto-deployed to dev, prod showed **OutOfSync** with the pending diff, and it reached prod
only after a manual `argocd app sync`. `argocd app history` records the promoted revision.
Evidence: `task3-prod-gated.png` (dev Synced while prod is OutOfSync), `task3-per-cluster-values.txt`,
`task3-after-commit.txt`, `task3-prod-pending-diff.txt`, `task3-prod-history.txt`.

### 4. Secrets — SOPS + age, decrypted only in the cluster
- **sops-secrets-operator** runs on every target. It reads an age private key mounted from a Kubernetes
  Secret (placed out of band by `scripts/bootstrap-age-key.sh`) and turns an encrypted `SopsSecret` into a
  native Secret. Argo CD only ever handles ciphertext, and no Argo CD plugin is needed.
- **Per-environment keys** (`.sops.yaml`): dev files are readable by the admin and dev keys, prod files by
  the admin and prod keys. The dev key cannot decrypt prod.
- Plaintext only ever existed in a deleted temp file. The repo's `.githooks/pre-commit` refuses any
  `*.enc.yaml` without SOPS metadata and runs gitleaks on staged changes.

Proof (`task4-secrets-proof.txt`): the cluster-side Secret hash matches the original, **0 plaintext
occurrences in `git log -p --all`**, the dev key fails on prod's file, and a gitleaks full-history scan
finds no leaks.

### 5. Scale to zero with KEDA
KEDA and the HTTP add-on go to every target via ApplicationSets. `scale-demo` has no `replicas` field, so
KEDA owns it. Its HTTPScaledObject sets `min 0 / max 5`, `scaledownPeriod: 60`, and concurrency target 2.
Results from `task5-scale-to-zero.log`:

| Step | Result |
| --- | --- |
| Idle | 0 pods |
| One request at 0 replicas | **HTTP 200, cold start 1.07 s** (image already cached on the node) |
| `hey -c 20` for 45 s on a 1 s handler | 1 → 4 → **5 replicas** (capped by `max`), **900/900 requests returned 200** |
| Idle again | Back to **0** after about 60 s |

### 6. Node autoscaling with Karpenter (KWOK)
The Karpenter controller comes from the upstream chart (`kwok/charts` at the pinned tag) with a
locally built image. The NodePool and KWOKNodeClass come from `platform/karpenter-config`, with the CPU
limit layered common 50 → dev 20 → **cluster `dev` 10**. The `inflate` workload targets only Karpenter
nodes, so no other app lands on simulated nodes. The controller, config and workload apps are shown in
`task6-argocd-karpenter-apps.png`. Results from `task6-karpenter.log`:
- **Scale to 6:** 3 new nodes, c-2x and c-4x only (the allow-list).
- **Scale to 20:** provisioning stops below the 10-CPU limit, 12 pods stay Pending, and Karpenter reports
  *"all available instance types exceed limits for nodepool"*.
- **Scale to 0:** nodes are consolidated away 6 → 4 → 3 → 2 → 1 → 0 in about 2 minutes, paced by the
  disruption budget.

**Cost guardrails:**
- Per-cluster NodePool CPU and memory limits
- Instance-size allow-list (2 or 4 vCPU)
- `WhenEmptyOrUnderutilized` consolidation after 30 s
- Disruption budget of 20 % of nodes at a time
- `expireAfter: 720h`
- Namespace ResourceQuota
- Karpenter only on clusters with `karpenter=enabled`
- KEDA `max` replicas
- `KarpenterNodePoolNearLimit` alert at 80 % of the limit

### 7. Runtime alerting with Prometheus
kube-prometheus-stack goes to every target via an ApplicationSet (lean settings for kind, control-plane
scrapes disabled). `externalLabels` stamp **`cluster` and `env` on every alert**. PrometheusRules in
`platform/monitoring-config`:

| Rule | Signal |
| --- | --- |
| `AppPodCrashLooping` | A pod is in CrashLoopBackOff |
| `PodsStuckPending` | Pods Pending for more than 2 minutes |
| `KedaScalerErrors` | KEDA scaler is erroring (`keda_scaler_detail_errors_total`) |
| `KarpenterNodePoolNearLimit` | NodePool above 80 % of its CPU limit |

Alertmanager routes to Slack through `slack_api_url_file`. The webhook is a SOPS-encrypted `SopsSecret`
per env and appears **0 times in git history**. Alerts were triggered for real on two clusters:
`KarpenterNodePoolNearLimit` (84 % of the limit) and `PodsStuckPending` (12 pods) on **dev**, and
`KedaScalerErrors` on **prod**. Both dev alerts are shown firing and then resolved. Every message carries
`cluster=` and `env=`.
Evidence: `task7-firing.png`, `task7-resolved.png`, `task7-webhook-not-in-git.txt`, `task7-monitoring-rollout.png`.

### 8. Argo CD Notifications
`argocd-notifications-cm` and its secret are managed from git (`platform/hub-notifications`). The
Argo CD chart is set to not create them, and the webhook is decrypted on the hub with a hub-only age key.
Global subscriptions mean no per-app annotations are needed:
- `on-sync-failed` covers every app.
- `on-drift-detected` covers only `env=prod`. Dev drift is self-healed within seconds and isn't worth an
  alert, while prod drift stays until someone acts.

Demonstrated with a manual `kubectl scale` on prod (drift), and with a deliberately invalid manifest
rendered only for dev, which made the sync fail, followed by a revert.
Evidence: `task8-drift.png`, `task8-prod-drift-diff.txt`, `task8-sync-failed.png`, `task8-sync-failed.txt`.

---

## Known issues and decisions

- **Karpenter KWOK chart v1.14.1 bug.** The deployment template sets four feature gates, but the chart's
  `values.yaml` only defines two. The controller then panics with
  `invalid value of StaticCapacity: ""`. Workaround: all four are pinned explicitly in
  `bootstrap/appsets/karpenter.yaml`.
- **KWOK node capacity accounting.** Simulated nodes report less allocatable CPU than their nominal size,
  so NodePool usage showed 8.6 / 10. Karpenter checks a new node's nominal size against the remaining
  budget (1.4 is less than 2 vCPU), so it correctly refused to add another node.
- **`argocd login` through `kubectl port-forward`.** The CLI's TLS probe resets the forward against an
  insecure server. Use `--plaintext --skip-test-tls`.
- **Corporate TLS interception (Cloudflare WARP).** The VM didn't trust the inspecting CA, so image pulls
  failed with `x509`. WARP was paused for the lab.
- **kube-prometheus-stack on a loaded laptop.** On one cluster, Prometheus wasn't reconciled after a load
  spike (load average 13 on 6 vCPUs), as `task7-monitoring-rollout.png` shows. Restarting the operator
  fixed it.
- **The hub isn't monitored by Prometheus.** Its delivery health is covered by Argo CD Notifications. In
  production the hub would run the same monitoring stack.
- **Lab shortcuts** that production would replace: the `default` AppProject, admin client certs for
  cluster registration, and one Slack channel for everything. See [the design note](docs/design-note.md).

## Pinned versions

All chart versions are pinned in `bootstrap/appsets/*.yaml` (`targetRevision`) and `bootstrap/argocd/values.yaml`.
The main ones: Argo CD v3.5.x, kube-prometheus-stack 91.9.0, sops-secrets-operator chart 0.28.1,
Karpenter v1.14.1 (KWOK provider, KWOK v0.8.0), podinfo 6.7.1, Kubernetes 1.37 (kind 0.33).
