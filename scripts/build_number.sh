#!/usr/bin/env bash
set -euo pipefail

# iOS CFBundleVersion accepts integers; keep it monotonic and short enough to
# also be valid as an Android versionCode if this script is reused later.
epoch_seconds="$(date +%s)"
day_index=$(((epoch_seconds - 1577836800) / 86400))
hour="$(date +%H)"
minute="$(date +%M)"

echo $((day_index * 10000 + 10#$hour * 100 + 10#$minute))
