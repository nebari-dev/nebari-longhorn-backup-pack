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
echo "Passed: $pass   Failed: $fail"
[[ $fail -eq 0 ]]
