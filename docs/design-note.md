# Design note — taking this pattern to 10+ clusters

This repo runs a hub-and-spoke GitOps model: one Argo CD on a hub cluster, one git repo, and
ApplicationSets whose **cluster generators select clusters by labels on their registration secret**
(`env=dev|prod`, `karpenter=enabled`, `monitoring=disabled`). Adding a cluster is a registration, not
a manifest change (proven in Task 2). The same model scales well past 10 clusters, but several lab
shortcuts must become explicit boundaries. Below: what holds, what breaks, and what I would change.

---

## 1. RBAC boundaries between teams

**Today (lab shortcut):** every Application lives in the `default` AppProject and I am the only user.
That is the first thing to change.

**At scale:**

- **One AppProject per team + one `platform` project.** Each project restricts
  `sourceRepos` (the team's paths/repos), `destinations` (allowed clusters *and namespaces*), and
  `clusterResourceWhitelist`. Only `platform` may create cluster-scoped objects — CRDs, NodePools,
  KWOK/EC2 node classes, ClusterRoles, ResourceQuotas. Teams deploy namespaced workloads only.
- **Argo CD RBAC bound to SSO groups**, e.g. `role:team-data-dev` (sync on dev clusters),
  `role:team-data-release` (sync on prod), `role:platform-admin`. Nobody uses the `admin` account.
- **Repo ownership via CODEOWNERS**: platform owns `bootstrap/`, `platform/` and every
  `values/clusters/*`; teams own `apps/<team>/`. Any change under a `prod` values path requires a
  platform + owning-team approval.
- **Cluster credentials**: the lab registers clusters with the kind admin client cert. At scale each
  spoke gets a scoped `argocd-manager` ServiceAccount (or cloud workload identity, e.g. IRSA/Workload
  Identity) with rotation — still never stored in git.
- **Secrets**: the lab already separates age keys per environment (the dev key cannot decrypt prod —
  proven in Task 4). At scale move to **KMS-backed SOPS keys per environment or per cluster**, so key
  access is IAM-controlled and auditable, and rotate with `sops updatekeys`.

## 2. Blast radius of a bad ApplicationSet template

One template renders N Applications, so a bad template change reaches **every matching cluster at
once**. With 10+ clusters that is the biggest risk in this design.

**Guards already in place:** `preserveResourcesOnDeletion: true` on every ApplicationSet (a deleted or
mis-rendered AppSet does not delete running workloads), `goTemplateOptions: missingkey=error` (a typo'd
label fails rendering instead of producing empty values), and no auto-sync on prod-labelled
applications.

**What I would add:**

- **Progressive sync** (`strategy: RollingSync`) with steps keyed on the `env` label —
  `dev → staging → prod-canary → prod` with `maxUpdate` limits — so a bad change halts after the first
  wave goes unhealthy.
- **`syncPolicy.applicationsSync: create-update`** on ApplicationSets so the controller can never
  *delete* Applications because a generator or selector briefly matched nothing.
- **CI that renders before merge**: for every ApplicationSet × every registered cluster, render the
  manifests (`helm template` with the same value layers), validate (kubeconform), run policy checks
  (conftest/Kyverno CLI), and post the per-cluster diff on the PR. Reviewers then see the real blast
  radius before merging.
- **Smaller failure domains**: split ApplicationSets by ownership (platform add-ons vs team apps), and
  run a **separate prod hub** (or at minimum separate controller shards) so a bad change to the
  non-prod hub cannot touch production.

## 3. Who is allowed to promote to a prod-labelled cluster

**Today:** the gate is that prod Applications have no automated sync — a change shows as `OutOfSync`
until someone syncs it (Task 3), and Argo CD records which revision was promoted
(`argocd app history`). But anyone with sync rights can promote.

**At scale:**

- **Promotion is a git change, not a button.** Prod tracks a release tag or a `prod` values path;
  promoting means a PR that moves it. Git history becomes the audit log, and CODEOWNERS enforces who
  approves (owning team + release manager).
- **Argo CD RBAC**: only `role:<team>-release` may run `sync` on `*-prod` Applications; everyone else
  is read-only on prod.
- **Sync windows** on prod projects (deny outside agreed hours) with a documented, audited
  break-glass role for incidents.
- Optional: a promotion tool (e.g. Kargo) once the number of stages and services makes manual PRs
  error-prone.

## 4. Who owns autoscaling limits and cost

Ownership is split along the boundary that already exists in the repo:

| Control | Owner | Where it lives |
| --- | --- | --- |
| NodePool CPU/memory limits, allowed instance sizes, disruption budgets, consolidation | Platform team, budget set with FinOps | `platform/karpenter-config/values/` — common → env → **cluster** layer |
| Namespace `ResourceQuota` (the team's budget contract) | Platform, agreed with each team | platform-owned namespace config |
| KEDA/HPA `min/max` replicas inside that quota | Application team | `apps/<app>/` |

Guardrails already demonstrated: per-cluster NodePool CPU limit (provisioning stopped at the limit in
Task 6), instance-size allow-list (2/4 vCPU only), consolidation of empty/under-used nodes, a 20 %
disruption budget, `expireAfter`, a namespace ResourceQuota, Karpenter only on clusters that opt in
(`karpenter=enabled`), a KEDA `max` replica cap, and an alert at 80 % of a NodePool's limit (Task 7).

At scale: changes to `values/clusters/*` limits need platform + FinOps approval; cost is reported per
team via namespace/team labels (OpenCost or similar); and the near-limit alert goes to platform as a
*capacity* signal, not to application teams.

## 5. Alerts from many clusters reaching the right team without double-paging

**Today:** each cluster runs its own Prometheus + Alertmanager; Prometheus `externalLabels` stamp
`cluster` and `env` on every alert; rules carry a `team` label; everything goes to one Slack channel.
Fine for 3 clusters, noisy for 10+.

**At scale:**

- **Route on ownership, not on cluster.** Every rule and every namespace carries `team`; the
  ApplicationSet template also stamps `team` onto each Application. Alertmanager's route tree matches
  `team` → that team's receiver; `severity=critical` pages (PagerDuty), `warning` goes to the team's
  Slack channel.
- **Central evaluation and routing.** Per-cluster Prometheus remote-writes (or runs in agent mode) to
  a central store (Thanos/Mimir), with rules evaluated centrally and **one HA Alertmanager cluster**.
  HA Alertmanager deduplicates identical alerts, so the same failure is sent once, not once per
  replica.
- **Inhibition to stop symptom storms**: "cluster unreachable" inhibits every per-app alert from that
  cluster; `KarpenterNodePoolNearLimit` inhibits `PodsStuckPending` in the same cluster (root cause
  suppresses symptom). `group_by: [alertname, cluster, team]` keeps one notification per incident.
- **One signal, one channel.** Argo CD Notifications report *delivery* events (sync failed, prod
  drift) to the owning team's deploy channel. Prometheus reports *runtime* health and is the only
  thing that pages. The same failure is not alerted on through both paths. Drift is already scoped
  this way in the repo: self-healing dev drift is not alerted, prod drift is (`selector: env=prod`).
- **Dead-man's switch**: each cluster's always-firing `Watchdog` alert goes to an external heartbeat
  service, so a cluster whose monitoring silently dies is detected — today `Watchdog` goes to a null
  receiver.

---

## What I would change first

1. AppProjects + SSO-backed RBAC (removes the `default` project and shared admin).
2. Progressive sync + `applicationsSync: create-update` + render-and-diff CI (contains template blast radius).
3. Central Alertmanager with team-based routing and inhibition (stops double-paging).
4. KMS-backed SOPS keys and scoped cluster credentials.
5. Argo CD HA with controller sharding, and a separate production hub.
