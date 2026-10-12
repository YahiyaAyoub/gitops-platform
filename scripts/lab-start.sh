#!/usr/bin/env bash
# Resume the lab after lab-stop.sh or a Mac reboot. Keep Cloudflare WARP OFF.
set -uo pipefail
colima status >/dev/null 2>&1 || colima start
# inotify limits reset on every VM start
colima ssh -- sudo sysctl -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512 >/dev/null
# start clusters one by one (avoids the CPU spike of booting all 4 at once)
for c in hub dev prod dev-2; do
  docker start "$c-control-plane" >/dev/null && echo "started $c, waiting for API..."
  for i in $(seq 1 60); do
    kubectl --context "kind-$c" get --raw /readyz >/dev/null 2>&1 && { echo "  $c ready"; break; }
    sleep 5
  done
done
kubectl --context kind-hub -n argocd rollout status deploy/argocd-server --timeout=180s
echo
echo "Next: run the port-forward in its own tab, then: argocd app list"
