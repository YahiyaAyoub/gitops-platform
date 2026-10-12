#!/usr/bin/env bash
# Pause the whole lab (state is kept on the Colima VM disk).
set -uo pipefail
for c in dev-2 dev prod hub; do
  docker stop "$c-control-plane" >/dev/null 2>&1 && echo "stopped $c"
done
colima stop
