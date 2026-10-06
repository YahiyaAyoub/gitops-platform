#!/usr/bin/env bash
# Task 6 evidence: provision -> hit NodePool CPU limit -> consolidate empty nodes away
# Usage: scripts/demo-karpenter.sh [cluster]   (default: dev)
set -uo pipefail
CTX="kind-${1:-dev}"
k()  { kubectl --context "$CTX" "$@"; }
ts() { date '+%H:%M:%S'; }
show() {
  echo "[$(ts)] --- $1"
  k get nodepool default -o jsonpath='  NodePool limit cpu={.spec.limits.cpu} | provisioned cpu={.status.resources.cpu} | nodes={.status.nodes}{"\n"}'
  k get nodes -l karpenter.sh/nodepool=default -L node.kubernetes.io/instance-type --no-headers 2>&1 | awk '{print "  node:", $1, $NF}'
  echo "  inflate pods: $(k -n inflate get pods --no-headers 2>/dev/null | awk '{print $3}' | sort | uniq -c | xargs)"
}

show "BASELINE"

echo "[$(ts)] STEP 1: scale inflate -> 6 replicas (1 CPU each): expect new nodes"
k -n inflate scale deploy inflate --replicas=6 >/dev/null; sleep 45
show "after scale-up"

echo "[$(ts)] STEP 2: scale inflate -> 20 replicas: demand exceeds NodePool cpu limit (10)"
k -n inflate scale deploy inflate --replicas=20 >/dev/null; sleep 60
show "at the limit"
echo "  Karpenter refusing to exceed the limit:"
k -n kube-system logs deploy/karpenter --since=2m 2>/dev/null | grep -i 'limit' | tail -2 | cut -c1-220 | sed 's/^/    /'
k -n inflate get events --field-selector reason=FailedScheduling --sort-by=.lastTimestamp 2>/dev/null \
  | grep -i limit | tail -2 | cut -c1-220 | sed 's/^/    /'

echo "[$(ts)] STEP 3: scale inflate -> 0: expect empty nodes consolidated away (budget: 20% of nodes at a time)"
k -n inflate scale deploy inflate --replicas=0 >/dev/null
for i in $(seq 1 24); do
  sleep 15
  n=$(k get nodes -l karpenter.sh/nodepool=default --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "[$(ts)]   karpenter nodes=$n"
  [ "$n" = "0" ] && break
done
show "FINAL"
