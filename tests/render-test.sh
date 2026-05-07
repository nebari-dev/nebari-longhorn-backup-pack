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

assert_eq "Chart renders no StorageClass (target is the cluster default SC)" \
  "$(echo "$out" | $YQ ea '[select(.kind == "StorageClass")] | length')" "0"

echo
echo "==> Hourly snapshot RecurringJob"
assert_eq "Exactly one snapshot RecurringJob exists" \
  "$(echo "$out" | $YQ ea '[select(.kind == "RecurringJob" and .spec.task == "snapshot")] | length')" "1"
assert_eq "Snapshot RJ name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.name')" "default-hourly-snapshot"
assert_eq "Snapshot RJ namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.namespace')" "longhorn-system"
assert_eq "Snapshot RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.cron')" "0 * * * *"
assert_eq "Snapshot RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.retain')" "24"
assert_eq "Snapshot RJ targets default group" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.groups[0]')" "default"
assert_eq "Snapshot RJ spec.name == metadata.name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.name')" "default-hourly-snapshot"

echo
echo "==> Daily backup RecurringJob"
assert_eq "Exactly one backup RecurringJob exists" \
  "$(echo "$out" | $YQ ea '[select(.kind == "RecurringJob" and .spec.task == "backup")] | length')" "1"
assert_eq "Backup RJ name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .metadata.name')" "default-daily-backup"
assert_eq "Backup RJ namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .metadata.namespace')" "longhorn-system"
assert_eq "Backup RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.cron')" "0 3 * * *"
assert_eq "Backup RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.retain')" "30"
assert_eq "Backup RJ targets default group" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.groups[0]')" "default"
assert_eq "Backup RJ spec.name == metadata.name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.name')" "default-daily-backup"

echo
echo "==> Setting/allow-recurring-job-while-volume-detached"
assert_eq "Default: Setting CR rendered exactly once" \
  "$(echo "$out" | $YQ ea '[select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached")] | length')" "1"
assert_eq "Default: Setting CR namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached") | .metadata.namespace')" "longhorn-system"
assert_eq "Default: Setting CR value is \"true\"" \
  "$(echo "$out" | $YQ 'select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached") | .value')" "true"

echo
echo "==> Setting opted out via null"
out_null=$(render --set clusterSettings.allowRecurringJobWhileVolumeDetached=null)
assert_eq "Null: no Setting CR rendered" \
  "$(echo "$out_null" | $YQ ea '[select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached")] | length')" "0"

echo
echo "==> Setting explicitly false (Longhorn stock behavior, but managed by chart)"
out_false=$(render --set clusterSettings.allowRecurringJobWhileVolumeDetached=false)
assert_eq "False: Setting CR rendered" \
  "$(echo "$out_false" | $YQ ea '[select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached")] | length')" "1"
assert_eq "False: Setting CR value is \"false\"" \
  "$(echo "$out_false" | $YQ 'select(.kind == "Setting" and .metadata.name == "allow-recurring-job-while-volume-detached") | .value')" "false"

echo
echo "==> Customized schedules and namespace"
out_custom=$(render \
  --set snapshot.cron="*/30 * * * *" \
  --set snapshot.retain=48 \
  --set backup.cron="0 */6 * * *" \
  --set backup.retain=14 \
  --set longhornNamespace=longhorn-other)

assert_eq "Custom: Snapshot RJ namespace overridden" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.namespace')" "longhorn-other"
assert_eq "Custom: Snapshot RJ cron overridden" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.cron')" "*/30 * * * *"
assert_eq "Custom: Snapshot RJ retain overridden" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.retain')" "48"
assert_eq "Custom: Backup RJ cron overridden" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.cron')" "0 */6 * * *"
assert_eq "Custom: Backup RJ retain overridden" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.retain')" "14"
assert_eq "Custom: name still default-* (group not configurable)" \
  "$(echo "$out_custom" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.name')" "default-hourly-snapshot"

echo
echo "Passed: $pass   Failed: $fail"
[[ $fail -eq 0 ]]
