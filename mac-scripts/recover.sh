#!/usr/bin/env bash
# Clear chaos mode: health returns to 200 (tasks that were replaced come back healthy).
set -euo pipefail
source "$(dirname "$0")/_common.sh"
set_chaos recover
sleep 4
probe
