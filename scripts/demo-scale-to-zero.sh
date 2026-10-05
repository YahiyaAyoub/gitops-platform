#!/usr/bin/env bash
# Task 5 evidence: 0 pods -> cold start -> load scale-out -> idle back to 0
# Usage: scripts/demo-scale-to-zero.sh [cluster]   (default: dev)
set -uo pipefail
CTX="kind-${1:-dev}"; NS=scale-demo; HOST=scale-demo.local; PORT=8081
k()     { kubectl --context "$CTX" "$@"; }
ts()    { date '+%H:%M:%S'; }
want()  { k -n $NS get deploy scale-demo -o jsonpath='{.spec.replicas}'; }
ready() { r=$(k -n $NS get deploy scale-demo -o jsonpath='{.status.readyReplicas}'); echo "${r:-0}"; }

k -n keda port-forward svc/keda-add-ons-http-interceptor-proxy $PORT:8080 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT; sleep 3

echo "[$(ts)] cluster=$CTX  route: curl -> KEDA interceptor -> scale-demo"
echo "[$(ts)] STEP 1: wait for idle scale-to-zero"
until [ "$(want)" = "0" ]; do echo "[$(ts)]   replicas=$(want) ready=$(ready)"; sleep 10; done
k -n $NS get deploy scale-demo; k -n $NS get pods 2>&1

echo "[$(ts)] STEP 2: cold start - one request while at 0 replicas"
curl -s -o /dev/null -w "[$(ts)]   HTTP %{http_code}  cold-start latency %{time_total}s\n" \
  -H "Host: $HOST" http://localhost:$PORT/

echo "[$(ts)] STEP 3: load test 45s, 20 concurrent, 1s handler (/delay/1)"
hey -z 45s -c 20 -host "$HOST" http://localhost:$PORT/delay/1 > /tmp/hey.out &
HEY=$!
while kill -0 $HEY 2>/dev/null; do echo "[$(ts)]   replicas=$(want) ready=$(ready)"; sleep 5; done
grep -E 'Requests/sec|\[[0-9]{3}\]' /tmp/hey.out

echo "[$(ts)] STEP 4: idle - wait for scale back to 0"
until [ "$(want)" = "0" ]; do echo "[$(ts)]   replicas=$(want) ready=$(ready)"; sleep 10; done
echo "[$(ts)]   scaled back to zero"
k -n $NS get deploy scale-demo; k -n $NS get pods 2>&1
