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

# ---------- Default values: targetGroup=default, no StorageClass ----------
echo "==> Default values (targetGroup=default, storageClass.enabled=false)"
out=$(render)

assert_eq "No StorageClass rendered by default" \
  "$(echo "$out" | $YQ ea '[select(.kind == "StorageClass")] | length')" "0"

echo
echo "==> Hourly snapshot RecurringJob (default)"
assert_eq "Exactly one snapshot RecurringJob exists" \
  "$(echo "$out" | $YQ ea '[select(.kind == "RecurringJob" and .spec.task == "snapshot")] | length')" "1"
assert_eq "Snapshot RJ name uses targetGroup" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.name')" "default-hourly-snapshot"
assert_eq "Snapshot RJ namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.namespace')" "longhorn-system"
assert_eq "Snapshot RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.cron')" "0 * * * *"
assert_eq "Snapshot RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.retain')" "24"
assert_eq "Snapshot RJ groups[0] = default" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.groups[0]')" "default"
assert_eq "Snapshot RJ spec.name == metadata.name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.name')" "default-hourly-snapshot"

echo
echo "==> Daily backup RecurringJob (default)"
assert_eq "Exactly one backup RecurringJob exists" \
  "$(echo "$out" | $YQ ea '[select(.kind == "RecurringJob" and .spec.task == "backup")] | length')" "1"
assert_eq "Backup RJ name uses targetGroup" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .metadata.name')" "default-daily-backup"
assert_eq "Backup RJ groups[0] = default" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.groups[0]')" "default"
assert_eq "Backup RJ spec.name == metadata.name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.name')" "default-daily-backup"

echo
echo "==> Setting/allow-recurring-job-while-volume-detached"
assert_eq "Default: Setting CR rendered exactly once" \
  "$(echo "$out" | $YQ ea '[select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached")] | length')" "1"
assert_eq "Default: Setting CR value is \"true\"" \
  "$(echo "$out" | $YQ 'select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached") | .value')" "true"

echo
echo "==> Setting opted out via null"
out_null=$(render --set clusterSettings.allowRecurringJobWhileVolumeDetached=null)
assert_eq "Null: no Setting CR rendered" \
  "$(echo "$out_null" | $YQ ea '[select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached")] | length')" "0"

echo
echo "==> StorageClass enabled with default targetGroup"
out_sc=$(render --set storageClass.enabled=true)
assert_eq "SC rendered when enabled" \
  "$(echo "$out_sc" | $YQ ea '[select(.kind == "StorageClass")] | length')" "1"
assert_eq "SC name" \
  "$(echo "$out_sc" | $YQ 'select(.kind == "StorageClass") | .metadata.name')" "longhorn-jhub"
assert_eq "SC provisioner" \
  "$(echo "$out_sc" | $YQ 'select(.kind == "StorageClass") | .provisioner')" "driver.longhorn.io"
assert_eq "SC numberOfReplicas is string" \
  "$(echo "$out_sc" | $YQ 'select(.kind == "StorageClass") | .parameters.numberOfReplicas | tag')" "!!str"
assert_eq "SC recurringJobSelector references default group" \
  "$(echo "$out_sc" | $YQ 'select(.kind == "StorageClass") | .parameters.recurringJobSelector' | grep -c '"name":"default"')" "1"

echo
echo "==> Custom targetGroup (dedicated group)"
out_custom=$(render \
  --set targetGroup=nebari \
  --set storageClass.enabled=true \
  --set storageClass.name=longhorn-nebari \
  --set storageClass.numberOfReplicas=2 \
  --set snapshot.cron="*/30 * * * *" \
  --set snapshot.retain=48 \
  --set backup.cron="0 */6 * * *" \
  --set backup.retain=14 \
  --set longhornNamespace=longhorn-other)

assert_eq "Custom targetGroup: Snapshot RJ name follows" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.name')" "nebari-hourly-snapshot"
assert_eq "Custom targetGroup: Snapshot RJ groups[0]" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.groups[0]')" "nebari"
assert_eq "Custom targetGroup: Backup RJ name follows" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .metadata.name')" "nebari-daily-backup"
assert_eq "Custom targetGroup: Backup RJ groups[0]" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.groups[0]')" "nebari"
assert_eq "Custom targetGroup: SC name" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "StorageClass") | .metadata.name')" "longhorn-nebari"
assert_eq "Custom targetGroup: SC selector references custom group" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "StorageClass") | .parameters.recurringJobSelector' | grep -c '"name":"nebari"')" "1"
assert_eq "Custom values: Snapshot RJ uses custom namespace" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.namespace')" "longhorn-other"
assert_eq "Custom values: Snapshot RJ cron" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.cron')" "*/30 * * * *"
assert_eq "Custom values: Backup RJ retain" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.retain')" "14"

echo
echo "Passed: $pass   Failed: $fail"
[[ $fail -eq 0 ]]
