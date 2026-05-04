#!/usr/bin/env bash
# Render assertions for nebari-longhorn-backup chart.
# Usage: bash tests/render-test.sh
set -euo pipefail

cd "$(dirname "$(realpath "$0")")/.."

YQ=${YQ:-yq}
HELM=${HELM:-helm}

pass=0
fail=0

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    fail=$((fail + 1))
  fi
}

render() { $HELM template test . "$@"; }

# ---------- Default values ----------
echo "==> Default values"
out=$(render)

assert_eq "StorageClass exists" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .kind' | head -1)" "StorageClass"
assert_eq "StorageClass name" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .metadata.name')" "longhorn-jhub"
assert_eq "StorageClass provisioner" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .provisioner')" "driver.longhorn.io"
assert_eq "StorageClass numberOfReplicas" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .parameters.numberOfReplicas | tag')" "!!str"
assert_eq "StorageClass recurringJobSelector contains group" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .parameters.recurringJobSelector' | grep -c '"name":"jhub"')" "1"

echo
echo "==> Hourly snapshot RecurringJob"
# yq ea is required: default mode evaluates per-document and returns one result per doc
assert_eq "Exactly one snapshot RecurringJob exists" \
  "$(echo "$out" | $YQ ea '[select(.kind == "RecurringJob" and .spec.task == "snapshot")] | length')" "1"
assert_eq "Snapshot RJ name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.name')" "jhub-hourly-snapshot"
assert_eq "Snapshot RJ namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.namespace')" "longhorn-system"
assert_eq "Snapshot RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.cron')" "0 * * * *"
assert_eq "Snapshot RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.retain')" "24"
assert_eq "Snapshot RJ groups[0]" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.groups[0]')" "jhub"

echo
echo "==> Daily backup RecurringJob"
assert_eq "Exactly one backup RecurringJob exists" \
  "$(echo "$out" | $YQ ea '[select(.kind == "RecurringJob" and .spec.task == "backup")] | length')" "1"
assert_eq "Backup RJ name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .metadata.name')" "jhub-daily-backup"
assert_eq "Backup RJ namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .metadata.namespace')" "longhorn-system"
assert_eq "Backup RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.cron')" "0 3 * * *"
assert_eq "Backup RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.retain')" "30"
assert_eq "Backup RJ groups[0]" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.groups[0]')" "jhub"

echo
echo "Passed: $pass   Failed: $fail"
[[ $fail -eq 0 ]]
