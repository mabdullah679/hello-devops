#!/usr/bin/env bash
# Put the service into chaos mode: /healthz and /readyz start returning 503 on every task.
set -euo pipefail
source "$(dirname "$0")/_common.sh"
set_chaos break
sleep 4 # the app caches the flag for up to 3s
probe
