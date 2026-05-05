# Longhorn Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a standalone Helm chart (`nebari-longhorn-backup-pack` in `nebari-dev`) that schedules hourly Longhorn snapshots and daily Longhorn backups for JupyterHub user PVCs and the shared (RWX) PVC, then cut the test cluster (`tyler-hetzner-dev`) over to it — replacing the existing Velero + helper-pod stack.

**Architecture:** Chart renders three resources (one `StorageClass` + two `RecurringJob`s); volumes provisioned through the SC are auto-enrolled in a recurring-job group via `recurringJobSelector`. The gitops repo (`NIC-argocd-tyler-dev`) consumes the chart via a new ArgoCD app, configures the in-cluster MinIO `BackupTarget`, pins data-science-pack to the new SC, enables shared storage, and deletes the legacy Velero stack — all in one PR. Post-merge, an operator runs an RWO and RWX round-trip smoke test.

**Tech Stack:** Helm 3, GitHub Actions (chart-releaser-style workflow), kubeconform, ArgoCD (declarative GitOps), Longhorn 1.7+, kubectl, k3s on Hetzner.

---

## File Structure

### New repo: `github.com/nebari-dev/nebari-longhorn-backup-pack`

Local clone path during development: `/Users/tylerman/gh/nebari-longhorn-backup-pack`.

```
nebari-longhorn-backup-pack/
├── Chart.yaml                          chart metadata, semver pinned
├── values.yaml                         values surface (Section 4 of the spec)
├── README.md                           usage + restore runbook
├── LICENSE                             BSD-3-Clause (matches nebari-dev)
├── .gitignore                          ignore *.tgz, gh-pages/
├── .helmignore                         standard
├── .github/workflows/
│   ├── lint.yaml                       helm lint + template + kubeconform + render-test.sh
│   └── release.yaml                    on Chart.yaml version bump: package, gh-release, gh-pages
├── docs/
│   └── 2026-05-04-longhorn-backup-design.md   (relocated in Phase E)
├── tests/
│   └── render-test.sh                  bash + yq assertions on `helm template` output
└── templates/
    ├── _helpers.tpl                    fullname, labels, group-name helper
    ├── _validation.tpl                 cron / retain / replicas guards
    ├── storageclass.yaml
    ├── recurringjob-snapshot.yaml
    ├── recurringjob-backup.yaml
    └── NOTES.txt
```

### Existing repo: `~/gh/NIC-argocd-tyler-dev`

Current branch is `main`. All changes go on a feature branch and into one PR.

```
base/
├── apps/
│   ├── data-science-pack.yaml          MODIFY (pin storageClass, enable sharedStorage)
│   ├── longhorn-backup-target.yaml     CREATE (ArgoCD app for BackupTarget + Secret)
│   ├── longhorn-backup.yaml            CREATE (ArgoCD app for the new chart)
│   ├── velero.yaml                     DELETE
│   └── velero-backup.yaml              DELETE
└── manifests/
    ├── longhorn-backup-target/         CREATE
    │   ├── secret.yaml
    │   └── backuptarget.yaml
    └── velero-backup/                  DELETE (entire directory)
```

---

## Phase A — Chart development (local)

All Phase A tasks operate inside `/Users/tylerman/gh/nebari-longhorn-backup-pack`. The repo only exists locally until Phase B.

### Task A1: Scaffold local repo

**Files:**
- Create: `/Users/tylerman/gh/nebari-longhorn-backup-pack/.gitignore`
- Create: `/Users/tylerman/gh/nebari-longhorn-backup-pack/LICENSE`
- Create: `/Users/tylerman/gh/nebari-longhorn-backup-pack/README.md` (placeholder)

- [ ] **Step 1: Create directory and initialize git**

```bash
mkdir -p /Users/tylerman/gh/nebari-longhorn-backup-pack
cd /Users/tylerman/gh/nebari-longhorn-backup-pack
git init -b main
```

- [ ] **Step 2: Write `.gitignore`**

```
# Helm
*.tgz
charts/
.helm/
gh-pages/

# Editor
.vscode/
.idea/
*.swp
*.swo
.DS_Store
```

- [ ] **Step 3: Write `LICENSE` — BSD-3-Clause**

Copy verbatim from https://opensource.org/license/bsd-3-clause and substitute the copyright line:

```
Copyright (c) 2026, Nebari Project. All rights reserved.
```

- [ ] **Step 4: Write placeholder `README.md`**

```markdown
# nebari-longhorn-backup

Longhorn-native snapshot and backup configuration for JupyterHub user volumes.

Status: under construction. Full README populated in Task A12.
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore LICENSE README.md
git commit -m "chore: scaffold repo (license, gitignore, placeholder readme)"
```

---

### Task A2: Chart.yaml, values.yaml, .helmignore

**Files:**
- Create: `Chart.yaml`
- Create: `values.yaml`
- Create: `.helmignore`

- [ ] **Step 1: Write `Chart.yaml`**

```yaml
apiVersion: v2
name: nebari-longhorn-backup
description: Longhorn-native snapshot and backup schedule for JupyterHub user volumes (RWO and RWX). Renders one StorageClass and two RecurringJobs.
type: application
version: 0.1.0
appVersion: "0.1.0"
home: https://github.com/nebari-dev/nebari-longhorn-backup-pack
sources:
  - https://github.com/nebari-dev/nebari-longhorn-backup-pack
keywords:
  - longhorn
  - backup
  - jupyterhub
  - nebari
maintainers:
  - name: Nebari Project
    url: https://nebari.dev
```

- [ ] **Step 2: Write `values.yaml`**

```yaml
# Namespace where Longhorn is installed. RecurringJobs MUST live here;
# StorageClass is cluster-scoped so this only affects the two RecurringJobs.
longhornNamespace: longhorn-system

storageClass:
  name: longhorn-jhub
  numberOfReplicas: 3
  reclaimPolicy: Delete
  fsType: ext4
  groupName: jhub                  # also used as the recurring-job group selector

snapshot:
  enabled: true
  cron: "0 * * * *"                # hourly
  retain: 24                       # 24h rolling window
  concurrency: 5

backup:
  enabled: true
  cron: "0 3 * * *"                # daily 03:00
  retain: 30                       # ~1 month
  concurrency: 3                   # don't saturate node uplink

# Optional: extra labels/annotations applied to all rendered resources.
commonLabels: {}
commonAnnotations: {}
```

- [ ] **Step 3: Write `.helmignore`**

```
# Patterns to ignore when building helm packages
.DS_Store
.git/
.gitignore
.bzr/
.bzrignore
.hg/
.hgignore
.svn/
*.swp
*.bak
*.tmp
*.orig
*~
.project
.idea/
*.tmproj
.vscode/
docs/
tests/
.github/
gh-pages/
```

- [ ] **Step 4: Run `helm lint` to confirm chart skeleton is valid**

```bash
cd /Users/tylerman/gh/nebari-longhorn-backup-pack
helm lint .
```

Expected: `1 chart(s) linted, 0 chart(s) failed`. `[INFO]` warnings about icon are OK.

- [ ] **Step 5: Commit**

```bash
git add Chart.yaml values.yaml .helmignore
git commit -m "feat: chart metadata and values surface"
```

---

### Task A3: `_helpers.tpl`

**Files:**
- Create: `templates/_helpers.tpl`

- [ ] **Step 1: Write `templates/_helpers.tpl`**

```
{{/*
Expand the name of the chart.
*/}}
{{- define "nebari-longhorn-backup.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels applied to every rendered resource.
*/}}
{{- define "nebari-longhorn-backup.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "nebari-longhorn-backup.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Group name shared by both RecurringJobs and the StorageClass selector.
Single source of truth — referenced from values.storageClass.groupName.
*/}}
{{- define "nebari-longhorn-backup.groupName" -}}
{{- required "storageClass.groupName must be set" .Values.storageClass.groupName -}}
{{- end -}}
```

- [ ] **Step 2: Confirm helpers parse**

```bash
helm template test . > /dev/null
```

Expected: no error. (No templates render yet — Helm just parses helpers.)

- [ ] **Step 3: Commit**

```bash
git add templates/_helpers.tpl
git commit -m "feat: helpers (name, labels, groupName)"
```

---

### Task A4: Validation guards

**Files:**
- Create: `templates/_validation.tpl`

- [ ] **Step 1: Write `templates/_validation.tpl`**

```
{{- /*
Validation guards. Rendered first by being included from every resource template.
Fails the render with a clear message instead of producing invalid YAML.
*/ -}}

{{- define "nebari-longhorn-backup.validate" -}}

{{- /* cron expressions */ -}}
{{- $cronRe := "^(\\S+\\s+){4}\\S+$" -}}
{{- if not (regexMatch $cronRe .Values.snapshot.cron) -}}
{{- fail (printf "snapshot.cron is not a valid 5-field cron expression: %q" .Values.snapshot.cron) -}}
{{- end -}}
{{- if not (regexMatch $cronRe .Values.backup.cron) -}}
{{- fail (printf "backup.cron is not a valid 5-field cron expression: %q" .Values.backup.cron) -}}
{{- end -}}

{{- /* retention is a positive integer */ -}}
{{- if le (int .Values.snapshot.retain) 0 -}}
{{- fail (printf "snapshot.retain must be > 0 (got %d)" (int .Values.snapshot.retain)) -}}
{{- end -}}
{{- if le (int .Values.backup.retain) 0 -}}
{{- fail (printf "backup.retain must be > 0 (got %d)" (int .Values.backup.retain)) -}}
{{- end -}}

{{- /* numberOfReplicas in {1,2,3} */ -}}
{{- if not (has (int .Values.storageClass.numberOfReplicas) (list 1 2 3)) -}}
{{- fail (printf "storageClass.numberOfReplicas must be 1, 2, or 3 (got %d)" (int .Values.storageClass.numberOfReplicas)) -}}
{{- end -}}

{{- end -}}
```

- [ ] **Step 2: Verify a default render still parses (validation is dormant until included)**

```bash
helm template test . > /dev/null
```

Expected: no error.

- [ ] **Step 3: Commit**

```bash
git add templates/_validation.tpl
git commit -m "feat: validation guards for cron, retain, replicas"
```

---

### Task A5: StorageClass template (TDD)

**Files:**
- Create: `tests/render-test.sh`
- Create: `templates/storageclass.yaml`

- [ ] **Step 1: Write the failing render test**

```bash
mkdir -p tests
cat > tests/render-test.sh <<'EOF'
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
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .parameters.numberOfReplicas')" '"3"'
assert_eq "StorageClass recurringJobSelector contains group" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .parameters.recurringJobSelector' | grep -c '"name":"jhub"')" "1"

echo
echo "Passed: $pass   Failed: $fail"
[[ $fail -eq 0 ]]
EOF
chmod +x tests/render-test.sh
```

- [ ] **Step 2: Run the test — confirm it fails because no StorageClass renders yet**

```bash
bash tests/render-test.sh
```

Expected: at least the "StorageClass exists" assertion fails (no template yet).

- [ ] **Step 3: Write `templates/storageclass.yaml`**

```yaml
{{- include "nebari-longhorn-backup.validate" . -}}
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: {{ .Values.storageClass.name }}
  labels:
    {{- include "nebari-longhorn-backup.labels" . | nindent 4 }}
  {{- with .Values.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: {{ .Values.storageClass.reclaimPolicy }}
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: {{ .Values.storageClass.numberOfReplicas | quote }}
  staleReplicaTimeout: "30"
  fsType: {{ .Values.storageClass.fsType | quote }}
  recurringJobSelector: |
    [{"name":{{ include "nebari-longhorn-backup.groupName" . | quote }},"isGroup":true}]
```

- [ ] **Step 4: Run the test — confirm it passes**

```bash
bash tests/render-test.sh
```

Expected: all 5 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add tests/render-test.sh templates/storageclass.yaml
git commit -m "feat: StorageClass template + render test"
```

---

### Task A6: Hourly snapshot RecurringJob (TDD)

**Files:**
- Modify: `tests/render-test.sh:end` (add assertions)
- Create: `templates/recurringjob-snapshot.yaml`

- [ ] **Step 1: Append snapshot assertions to `tests/render-test.sh`**

Append before the `echo "Passed:..."` summary line:

```bash
echo
echo "==> Hourly snapshot RecurringJob"
assert_eq "Snapshot RJ kind" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-hourly-snapshot") | .kind')" "RecurringJob"
assert_eq "Snapshot RJ namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-hourly-snapshot") | .metadata.namespace')" "longhorn-system"
assert_eq "Snapshot RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-hourly-snapshot") | .spec.cron')" "0 * * * *"
assert_eq "Snapshot RJ task" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-hourly-snapshot") | .spec.task')" "snapshot"
assert_eq "Snapshot RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-hourly-snapshot") | .spec.retain')" "24"
assert_eq "Snapshot RJ groups" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-hourly-snapshot") | .spec.groups[0]')" "jhub"
```

- [ ] **Step 2: Run test — confirm new assertions fail**

```bash
bash tests/render-test.sh
```

Expected: 6 new failures.

- [ ] **Step 3: Write `templates/recurringjob-snapshot.yaml`**

```yaml
{{- if .Values.snapshot.enabled -}}
{{- include "nebari-longhorn-backup.validate" . -}}
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: {{ include "nebari-longhorn-backup.groupName" . }}-hourly-snapshot
  namespace: {{ .Values.longhornNamespace }}
  labels:
    {{- include "nebari-longhorn-backup.labels" . | nindent 4 }}
  {{- with .Values.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  cron: {{ .Values.snapshot.cron | quote }}
  task: snapshot
  groups:
    - {{ include "nebari-longhorn-backup.groupName" . }}
  retain: {{ .Values.snapshot.retain }}
  concurrency: {{ .Values.snapshot.concurrency }}
{{- end }}
```

- [ ] **Step 4: Run test — confirm it passes**

```bash
bash tests/render-test.sh
```

Expected: all assertions pass.

- [ ] **Step 5: Commit**

```bash
git add tests/render-test.sh templates/recurringjob-snapshot.yaml
git commit -m "feat: hourly snapshot RecurringJob template"
```

---

### Task A7: Daily backup RecurringJob (TDD)

**Files:**
- Modify: `tests/render-test.sh:end`
- Create: `templates/recurringjob-backup.yaml`

- [ ] **Step 1: Append backup assertions to `tests/render-test.sh`**

```bash
echo
echo "==> Daily backup RecurringJob"
assert_eq "Backup RJ kind" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-daily-backup") | .kind')" "RecurringJob"
assert_eq "Backup RJ cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-daily-backup") | .spec.cron')" "0 3 * * *"
assert_eq "Backup RJ task" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-daily-backup") | .spec.task')" "backup"
assert_eq "Backup RJ retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-daily-backup") | .spec.retain')" "30"
assert_eq "Backup RJ groups" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .metadata.name == "jhub-daily-backup") | .spec.groups[0]')" "jhub"
```

- [ ] **Step 2: Run test — confirm fails**

```bash
bash tests/render-test.sh
```

- [ ] **Step 3: Write `templates/recurringjob-backup.yaml`**

```yaml
{{- if .Values.backup.enabled -}}
{{- include "nebari-longhorn-backup.validate" . -}}
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: {{ include "nebari-longhorn-backup.groupName" . }}-daily-backup
  namespace: {{ .Values.longhornNamespace }}
  labels:
    {{- include "nebari-longhorn-backup.labels" . | nindent 4 }}
  {{- with .Values.commonAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  cron: {{ .Values.backup.cron | quote }}
  task: backup
  groups:
    - {{ include "nebari-longhorn-backup.groupName" . }}
  retain: {{ .Values.backup.retain }}
  concurrency: {{ .Values.backup.concurrency }}
{{- end }}
```

- [ ] **Step 4: Run test — confirm passes**

```bash
bash tests/render-test.sh
```

- [ ] **Step 5: Commit**

```bash
git add tests/render-test.sh templates/recurringjob-backup.yaml
git commit -m "feat: daily backup RecurringJob template"
```

---

### Task A8: NOTES.txt + non-default render fixture

**Files:**
- Create: `templates/NOTES.txt`
- Modify: `tests/render-test.sh:end`

- [ ] **Step 1: Write `templates/NOTES.txt`**

```
nebari-longhorn-backup installed.

The chart created:
  - StorageClass/{{ .Values.storageClass.name }}            (cluster-scoped, auto-enrolls volumes in group "{{ include "nebari-longhorn-backup.groupName" . }}")
  - RecurringJob/{{ include "nebari-longhorn-backup.groupName" . }}-hourly-snapshot   in {{ .Values.longhornNamespace }}, cron {{ .Values.snapshot.cron | quote }}, retain {{ .Values.snapshot.retain }}
  - RecurringJob/{{ include "nebari-longhorn-backup.groupName" . }}-daily-backup      in {{ .Values.longhornNamespace }}, cron {{ .Values.backup.cron | quote }},   retain {{ .Values.backup.retain }}

Cluster-side prerequisites that this chart does NOT manage (configure in your gitops repo):
  - Longhorn install in namespace "{{ .Values.longhornNamespace }}"
  - BackupTarget CR with a valid S3 backupTargetURL + credentials secret

Pin downstream charts (e.g., nebari-data-science-pack) to this StorageClass:
  jupyterhub.singleuser.storage.dynamic.storageClass: {{ .Values.storageClass.name }}
  sharedStorage.storageClass:                       {{ .Values.storageClass.name }}

See README.md for the restore runbook.
```

- [ ] **Step 2: Append "all knobs flipped" fixture assertions to `tests/render-test.sh`**

Just before the summary `echo "Passed:..."`:

```bash
echo
echo "==> Non-default values (all knobs flipped)"
out=$(render \
  --set storageClass.name=test-sc \
  --set storageClass.numberOfReplicas=2 \
  --set storageClass.groupName=test-group \
  --set snapshot.cron="*/30 * * * *" \
  --set snapshot.retain=48 \
  --set backup.cron="0 */6 * * *" \
  --set backup.retain=14 \
  --set longhornNamespace=longhorn-other)

assert_eq "Custom SC name" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .metadata.name')" "test-sc"
assert_eq "Custom SC selector references custom group" \
  "$(echo "$out" | $YQ 'select(.kind == "StorageClass") | .parameters.recurringJobSelector' | grep -c '"name":"test-group"')" "1"
assert_eq "Snapshot RJ uses custom group in name" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.name')" "test-group-hourly-snapshot"
assert_eq "Snapshot RJ uses custom namespace" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .metadata.namespace')" "longhorn-other"
assert_eq "Snapshot RJ uses custom cron" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.cron')" "*/30 * * * *"
assert_eq "Backup RJ uses custom retain" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "backup") | .spec.retain')" "14"
assert_eq "Group consistency: SC selector and RJ groups match" \
  "$(echo "$out" | $YQ 'select(.kind == "RecurringJob" and .spec.task == "snapshot") | .spec.groups[0]')" "test-group"
```

- [ ] **Step 3: Run test — confirm all assertions pass**

```bash
bash tests/render-test.sh
```

Expected: all assertions pass (existing default + new flipped fixture).

- [ ] **Step 4: Negative-case validation check (manual, not in script)**

```bash
# Should fail at render time with the cron error message:
helm template test . --set 'snapshot.cron=not-a-cron' 2>&1 | grep "snapshot.cron is not a valid"
# Should exit 0 (grep found the error)
```

- [ ] **Step 5: Commit**

```bash
git add templates/NOTES.txt tests/render-test.sh
git commit -m "feat: NOTES.txt + non-default render fixture + negative validation check"
```

---

### Task A9: CI workflow — lint

**Files:**
- Create: `.github/workflows/lint.yaml`

- [ ] **Step 1: Write `.github/workflows/lint.yaml`**

```yaml
name: Lint

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@8e8c483db84b4bee98b60c0593521ed34d9990e8  # v6.0.1

      - name: Set up Helm
        uses: azure/setup-helm@1a275c3b69536ee54be43f2070a358922e12c8d4  # v4.3.1

      - name: Install yq
        run: |
          sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq

      - name: Helm lint
        run: helm lint .

      - name: Helm template (default values)
        run: helm template test . > /tmp/render-default.yaml

      - name: Render assertions
        run: bash tests/render-test.sh

      - name: Install kubeconform
        run: |
          curl -sSLo /tmp/kc.tgz https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz
          sudo tar -xzf /tmp/kc.tgz -C /usr/local/bin kubeconform

      - name: Validate rendered manifests against Kubernetes + Longhorn schemas
        run: |
          kubeconform -strict -summary \
            -schema-location default \
            -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
            /tmp/render-default.yaml

      - name: Negative-case validation (invalid cron must fail render)
        run: |
          if helm template test . --set 'snapshot.cron=not-a-cron' >/dev/null 2>&1; then
            echo "Validation guard did not fire on invalid cron"; exit 1
          fi
```

- [ ] **Step 2: Smoke-test the workflow locally as far as possible**

```bash
# Lint and render must already work from prior tasks:
helm lint .
bash tests/render-test.sh
# Negative-case must fail:
helm template test . --set 'snapshot.cron=not-a-cron' >/dev/null 2>&1 && echo "BUG" || echo "OK"
# Expected: OK
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lint.yaml
git commit -m "ci: helm lint, render assertions, kubeconform, negative validation"
```

---

### Task A10: CI workflow — release

**Files:**
- Create: `.github/workflows/release.yaml`

This mirrors `nebari-data-science-pack`'s pattern: triggered on push-to-main when `Chart.yaml` changes, packages the chart, creates a GitHub release with the `.tgz`, and force-pushes a single-commit gh-pages branch with the index.

- [ ] **Step 1: Write `.github/workflows/release.yaml`**

```yaml
name: Release Chart

on:
  push:
    branches: [main]
    paths:
      - 'Chart.yaml'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pages: write
    steps:
      - name: Checkout
        uses: actions/checkout@8e8c483db84b4bee98b60c0593521ed34d9990e8  # v6.0.1
        with:
          fetch-depth: 0

      - name: Configure Git
        run: |
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"

      - name: Install Helm
        run: curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

      - name: Get chart version
        id: chart
        run: |
          echo "version=$(grep '^version:' Chart.yaml | awk '{print $2}')" >> $GITHUB_OUTPUT
          echo "name=$(grep '^name:' Chart.yaml | awk '{print $2}')" >> $GITHUB_OUTPUT

      - name: Check if release exists
        id: check
        run: |
          if gh release view "${{ steps.chart.outputs.name }}-${{ steps.chart.outputs.version }}" &>/dev/null; then
            echo "exists=true" >> $GITHUB_OUTPUT
          else
            echo "exists=false" >> $GITHUB_OUTPUT
          fi
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Package chart
        if: steps.check.outputs.exists == 'false'
        run: helm package .

      - name: Create GitHub release
        if: steps.check.outputs.exists == 'false'
        run: |
          gh release create "${{ steps.chart.outputs.name }}-${{ steps.chart.outputs.version }}" \
            --title "${{ steps.chart.outputs.name }}-${{ steps.chart.outputs.version }}" \
            --generate-notes \
            *.tgz
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Update Helm repo index
        if: steps.check.outputs.exists == 'false'
        run: |
          mkdir -p gh-pages
          cp *.tgz gh-pages/
          cd gh-pages
          git init
          git checkout -b gh-pages
          git config user.name "$GITHUB_ACTOR"
          git config user.email "$GITHUB_ACTOR@users.noreply.github.com"
          git remote add origin https://x-access-token:${{ secrets.GITHUB_TOKEN }}@github.com/${{ github.repository }}
          helm repo index . --url https://github.com/${{ github.repository }}/releases/download/${{ steps.chart.outputs.name }}-${{ steps.chart.outputs.version }}
          git add .
          git commit -m "Release ${{ steps.chart.outputs.name }}-${{ steps.chart.outputs.version }}"
          git push origin gh-pages --force
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yaml
git commit -m "ci: chart release workflow (tag + gh-release + gh-pages index)"
```

---

### Task A11: README — usage and restore runbook

**Files:**
- Modify: `README.md` (replace placeholder)

- [ ] **Step 1: Replace `README.md` with the full content below**

```markdown
# nebari-longhorn-backup

Longhorn-native snapshot and backup configuration for JupyterHub user volumes (RWO and RWX). One `StorageClass` and two `RecurringJob`s — nothing else. Designed to be installed alongside any Helm chart that provisions Longhorn PVCs and pinned to this storage class.

## What it does

| Resource | Purpose | Schedule (defaults) | Retention |
|---|---|---|---|
| `StorageClass/longhorn-jhub` | Auto-enrolls every PVC provisioned through it into the recurring-job group `jhub` (via `recurringJobSelector`). | n/a | n/a |
| `RecurringJob/jhub-hourly-snapshot` | In-cluster CoW snapshot. Fast, RPO ≈ 1h, no S3 traffic. | `0 * * * *` | 24 (rolling 24h) |
| `RecurringJob/jhub-daily-backup` | Snapshot + stream blocks to the BackupTarget S3 bucket. Durable, off-cluster. | `0 3 * * *` | 30 (rolling 30 days) |

## Prerequisites (cluster-side, NOT managed by this chart)

- Longhorn installed in `longhorn-system` (or override `longhornNamespace`).
- `BackupTarget/default` configured with a valid `backupTargetURL` (`s3://bucket@region/`) and `credentialSecret`. See https://longhorn.io/docs/latest/snapshots-and-backups/backup-and-restore/set-backup-target/ for the canonical guide.

## Install

```bash
helm repo add nebari-longhorn-backup https://nebari-dev.github.io/nebari-longhorn-backup-pack
helm repo update
helm install backup nebari-longhorn-backup/nebari-longhorn-backup \
  --namespace longhorn-system
```

Or via ArgoCD — see the gitops example in https://github.com/openteams-ai/NIC-argocd-tyler-dev/blob/main/base/apps/longhorn-backup.yaml.

## Pin downstream charts

After installing, configure your stateful charts to use the new StorageClass:

```yaml
# nebari-data-science-pack values
jupyterhub:
  singleuser:
    storage:
      dynamic:
        storageClass: longhorn-jhub
sharedStorage:
  enabled: true
  storageClass: longhorn-jhub
  size: 10Gi
  accessModes: [ReadWriteMany]
```

## Values

See [`values.yaml`](./values.yaml) for the full surface. Key knobs:

| Path | Default | Notes |
|---|---|---|
| `storageClass.name` | `longhorn-jhub` | The StorageClass other charts pin to. |
| `storageClass.groupName` | `jhub` | Single source of truth — referenced by both RecurringJobs and the SC's `recurringJobSelector`. |
| `storageClass.numberOfReplicas` | `3` | Longhorn replication factor. Must be 1, 2, or 3. |
| `snapshot.cron` / `snapshot.retain` | `0 * * * *` / `24` | Hourly snapshot. |
| `backup.cron` / `backup.retain` | `0 3 * * *` / `30` | Daily backup. |
| `longhornNamespace` | `longhorn-system` | Where the RecurringJobs are placed. |

Validation guards run at render time: invalid cron expressions, non-positive retention, or `numberOfReplicas` outside `{1,2,3}` cause `helm template` to fail with a clear message.

## Restore runbook

### Scenario A — restore one user's PVC, same cluster

```bash
USER=tpotts

# 1. Stop the user's server so the PVC can be unbound.
kubectl -n jupyterhub get pod -l hub.jupyter.org/username=$USER -o name | xargs -r kubectl delete --wait=true

# 2. Find the Longhorn volume name for that PVC.
PVC=claim-$USER
VOL=$(kubectl -n jupyterhub get pvc $PVC -o jsonpath='{.spec.volumeName}')

# 3. List backups for the volume, pick a target.
kubectl -n longhorn-system get backups.longhorn.io \
  -l backup-volume=$VOL \
  --sort-by=.metadata.creationTimestamp
BACKUP=<backup-name-from-list>

# 4. Restore from the backup into a new volume via the Longhorn UI:
#    Backup → Restore → name=${VOL}-restored → Storage Class=longhorn-jhub
#    Then repoint the PVC at the restored volume:
kubectl -n jupyterhub patch pvc $PVC --type=merge -p "{\"spec\":{\"volumeName\":\"${VOL}-restored\"}}"

# 5. User restarts server from JupyterHub admin → KubeSpawner re-attaches.
```

### Scenario B — full DR, fresh cluster

A fresh Longhorn install pointed at the same S3 bucket auto-discovers existing backups (pure metadata; no block transfer until restore).

```bash
# 1. New cluster up; Longhorn installed; BackupTarget pointed at SAME bucket as the old cluster.
kubectl -n longhorn-system get backupvolumes.longhorn.io   # should list per-user volumes within one poll cycle (default 5m)

# 2. For each user that needs restore, create a Volume from the latest backup
#    (Longhorn UI: Backup → Restore. Scriptable via the Longhorn API for many users.)

# 3. Bind a PVC to the restored Volume in the JupyterHub namespace:
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: claim-tpotts
  namespace: jupyterhub
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 10Gi } }
  storageClassName: longhorn-jhub
  volumeName: <restored-volume-name>
EOF

# 4. JupyterHub: spawn user servers as normal. (Hub DB is gone if you didn't back it up,
#    so server-state — last-active timestamps, named servers — resets. File data is intact.)
```

### DR gotchas

1. **No automatic PVC re-binding.** Restore creates a Longhorn `Volume`; you still issue PVC manifests with `volumeName: <restored>`.
2. **In-flight backup locks.** If the source cluster died mid-backup, a stale lock in `backupstore/lock/` may persist. Reads work; new writes may complain until the lock is removed (`mc rm`).
3. **Two clusters → one bucket = corruption.** If the "destroyed" cluster comes back to life mid-DR, both clusters writing to the same `backupstore/` will corrupt each other's metadata. Rotate the bucket prefix or credential before declaring the new cluster authoritative.

### RWX-specific gotchas (shared storage)

- The Longhorn share-manager pod is a single-replica Deployment fronting the underlying RWO volume. **No user pod can mount the shared volume until the share-manager is `Ready`.** On restore, restore the RWX volume first, wait for the share-manager pod to come up, then let users spawn.
- Snapshots target the underlying RWO volume, not the NFS export. Active writes through NFS are subject to write-back caching; snapshotting mid-write may miss the last few hundred ms of buffered writes. Quiesce the share-manager first if you need stricter consistency.

## Development

```bash
helm lint .
helm template test . > /tmp/out.yaml
bash tests/render-test.sh

# Negative-case validation check
helm template test . --set 'snapshot.cron=not-a-cron'   # expect: render fails with clear error
```

## License

BSD-3-Clause. See [LICENSE](./LICENSE).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with usage, values, and restore runbook"
```

---

## Phase B — Publish chart

### Task B1: Create remote repo and push main

**Files:** none (remote operation)

- [ ] **Step 1: Confirm gh auth scope includes repo creation in nebari-dev**

```bash
gh api orgs/nebari-dev/members/$(gh api user --jq .login) --silent && echo "member of nebari-dev: YES" || echo "NOT a member — coordinate with maintainers before continuing"
```

If you are not a member, **stop and coordinate** before running the create command.

- [ ] **Step 2: Create the remote repo (PUBLIC, no template, default-branch main)**

This is a public, hard-to-reverse action. Confirm the user has explicitly approved before running.

```bash
cd /Users/tylerman/gh/nebari-longhorn-backup-pack
gh repo create nebari-dev/nebari-longhorn-backup-pack \
  --public \
  --description "Longhorn-native snapshot and backup configuration for JupyterHub user volumes" \
  --homepage "https://nebari.dev" \
  --source . \
  --remote origin \
  --push
```

- [ ] **Step 3: Confirm the repo exists, all commits pushed, default branch is main, lint workflow ran on push**

```bash
gh repo view nebari-dev/nebari-longhorn-backup-pack --json url,defaultBranchRef,visibility
gh run list -R nebari-dev/nebari-longhorn-backup-pack --workflow=Lint --limit 5
```

Wait until the most recent Lint run is `completed/success`. If it fails, fix locally and push.

---

### Task B2: Tag v0.1.0 and verify release

**Files:** none (Chart.yaml is already at 0.1.0; release triggers on Chart.yaml change to main, which already happened on first push)

- [ ] **Step 1: Confirm the release workflow triggered on first main push and produced a release**

```bash
gh run list -R nebari-dev/nebari-longhorn-backup-pack --workflow="Release Chart" --limit 5
gh release list -R nebari-dev/nebari-longhorn-backup-pack
```

Expected: one release `nebari-longhorn-backup-0.1.0` with a `.tgz` asset.

- [ ] **Step 2: Verify gh-pages branch and chart index**

```bash
gh api repos/nebari-dev/nebari-longhorn-backup-pack/branches/gh-pages --jq .name
curl -sS https://nebari-dev.github.io/nebari-longhorn-backup-pack/index.yaml | head -30
```

Expected: `index.yaml` lists `nebari-longhorn-backup` 0.1.0.

- [ ] **Step 3: Smoke-test consumability from the published index**

```bash
helm repo add nebari-longhorn-backup https://nebari-dev.github.io/nebari-longhorn-backup-pack
helm repo update
helm template test nebari-longhorn-backup/nebari-longhorn-backup > /tmp/published.yaml
yq 'select(.kind == "StorageClass") | .metadata.name' /tmp/published.yaml
# expected: longhorn-jhub
```

---

## Phase C — GitOps changes (single PR)

All Phase C tasks operate inside `~/gh/NIC-argocd-tyler-dev`. One feature branch, one PR, one merge.

### Task C1: Create feature branch

**Files:** none (git only)

- [ ] **Step 1: Sync main and create branch**

```bash
cd /Users/tylerman/gh/NIC-argocd-tyler-dev
git switch main
git pull --ff-only origin main
git switch -c feat/longhorn-native-backup
```

---

### Task C2: BackupTarget secret and CR manifests

**Files:**
- Create: `base/manifests/longhorn-backup-target/secret.yaml`
- Create: `base/manifests/longhorn-backup-target/backuptarget.yaml`

The in-cluster MinIO is at `http://minio.minio.svc.cluster.local:9000`. Bucket name `longhorn-backups` is **separate** from the existing `velero` bucket so the two stacks do not collide during cutover. Credentials match the existing minioadmin/minioadmin used by the velero stack (this is a test cluster).

- [ ] **Step 1: Create the bucket on MinIO**

```bash
export KUBECONFIG=/Users/tylerman/Library/Caches/nic/hetzner-k3s/tyler-hetzner-dev/kubeconfig
kubectl -n minio exec -it deploy/minio -- /bin/sh -c \
  'mc alias set local http://localhost:9000 minioadmin minioadmin && mc mb -p local/longhorn-backups || true'
```

Expected: `Bucket created successfully` (or "already exists" — both fine).

- [ ] **Step 2: Write `base/manifests/longhorn-backup-target/secret.yaml`**

```yaml
# Longhorn BackupTarget credentials. Test cluster — credentials are intentionally
# the MinIO defaults (minioadmin/minioadmin). DO NOT copy this pattern to any
# environment with real data.
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-backup-target-credentials
  namespace: longhorn-system
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID:     "minioadmin"
  AWS_SECRET_ACCESS_KEY: "minioadmin"
  AWS_ENDPOINTS:         "http://minio.minio.svc.cluster.local:9000"
```

- [ ] **Step 3: Write `base/manifests/longhorn-backup-target/backuptarget.yaml`**

```yaml
# Configures the cluster's default Longhorn BackupTarget to point at the
# in-cluster MinIO bucket. ArgoCD applies via ServerSideApply so we take
# ownership of the URL, secret, and pollInterval fields without disturbing
# the rest of Longhorn's BackupTarget defaults.
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL:   "s3://longhorn-backups@us-east-1/"
  credentialSecret:  "longhorn-backup-target-credentials"
  pollInterval:      "5m0s"
```

---

### Task C3: ArgoCD app for the BackupTarget manifests

**Files:**
- Create: `base/apps/longhorn-backup-target.yaml`

- [ ] **Step 1: Write `base/apps/longhorn-backup-target.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn-backup-target
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: nebari-foundational
    app.kubernetes.io/managed-by: nebari-infrastructure-core
  annotations:
    # Sync wave: BackupTarget must exist before the chart's RecurringJob/backup
    # tries to fire. Wave 5 places this before data-science-pack (default wave).
    argocd.argoproj.io/sync-wave: "5"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: foundational

  source:
    repoURL: https://github.com/openteams-ai/NIC-argocd-tyler-dev.git
    targetRevision: main
    path: base/manifests/longhorn-backup-target

  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - ServerSideApply=true              # Longhorn already owns BackupTarget/default; we patch fields.
      - CreateNamespace=false             # longhorn-system already exists from out-of-band install.
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

### Task C4: ArgoCD app for the chart

**Files:**
- Create: `base/apps/longhorn-backup.yaml`

- [ ] **Step 1: Write `base/apps/longhorn-backup.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn-backup
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: nebari-foundational
    app.kubernetes.io/managed-by: nebari-infrastructure-core
  annotations:
    # Wave 6: after BackupTarget (wave 5), before data-science-pack (default).
    argocd.argoproj.io/sync-wave: "6"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: foundational

  source:
    chart: nebari-longhorn-backup
    repoURL: https://nebari-dev.github.io/nebari-longhorn-backup-pack
    targetRevision: 0.1.0
    helm:
      releaseName: nebari-longhorn-backup
      values: |
        # Defaults from the chart match the design spec exactly:
        # - StorageClass: longhorn-jhub
        # - Hourly snapshot, retain 24
        # - Daily backup at 03:00, retain 30
        # No overrides needed for the test cluster.

  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

### Task C5: Pin data-science-pack to longhorn-jhub and enable shared storage

**Files:**
- Modify: `base/apps/data-science-pack.yaml`

- [ ] **Step 1: Open the file and locate the helm.values block**

```bash
cd /Users/tylerman/gh/NIC-argocd-tyler-dev
grep -n "helm:\|values:\|jupyterhub:\|sharedStorage:\|storageClass:" base/apps/data-science-pack.yaml
```

- [ ] **Step 2: Add storage pinning under `helm.values`**

Add (or merge into existing) the following keys under the `helm.values` block. The exact insertion point depends on what's already there — the goal is for the rendered chart values to include both blocks:

```yaml
        sharedStorage:
          enabled: true
          storageClass: longhorn-jhub
          size: 10Gi
          accessModes: [ReadWriteMany]
        jupyterhub:
          singleuser:
            storage:
              dynamic:
                storageClass: longhorn-jhub
```

If `jupyterhub.singleuser` already exists in `helm.values`, merge `storage.dynamic.storageClass` into it rather than duplicating.

- [ ] **Step 3: Verify the rendered values block parses as valid YAML**

```bash
yq '.spec.source.helm.values' base/apps/data-science-pack.yaml | yq '.sharedStorage.storageClass + " | " + .jupyterhub.singleuser.storage.dynamic.storageClass'
# expected: longhorn-jhub | longhorn-jhub
```

---

### Task C6: Delete the legacy Velero stack

**Files:**
- Delete: `base/apps/velero.yaml`
- Delete: `base/apps/velero-backup.yaml`
- Delete: `base/manifests/velero-backup/` (entire directory)

- [ ] **Step 1: Remove the files**

```bash
git rm base/apps/velero.yaml base/apps/velero-backup.yaml
git rm -r base/manifests/velero-backup/
```

- [ ] **Step 2: Confirm no remaining references to "velero" in the gitops repo**

```bash
grep -rn "velero" base/ || echo "no references remain"
```

If anything matches, decide whether it should be removed (likely yes — only the longhorn-backup stack should reference S3 going forward).

---

### Task C7: Commit and open PR

**Files:** none (git operations)

- [ ] **Step 1: Stage all changes**

```bash
git add base/manifests/longhorn-backup-target/
git add base/apps/longhorn-backup-target.yaml base/apps/longhorn-backup.yaml
git add base/apps/data-science-pack.yaml
# velero deletions already staged via git rm above
git status
```

Expected: 5 added/modified files + 3 deleted files (or 2 + the directory).

- [ ] **Step 2: Commit**

```bash
git commit -m "feat: cut over from Velero to Longhorn-native backups

Replaces the Velero + helper-pod CronJob stack with a native Longhorn
RecurringJob schedule (hourly snapshots, daily backups to MinIO).
Pins data-science-pack singleuser and shared storage to the new
longhorn-jhub StorageClass; enables sharedStorage (RWX, 10Gi).

Spec: ./2026-05-04-longhorn-backup-design.md
Chart: https://github.com/nebari-dev/nebari-longhorn-backup-pack 0.1.0"
```

- [ ] **Step 3: Push and open PR**

```bash
git push -u origin feat/longhorn-native-backup
gh pr create \
  --title "Cut over from Velero to Longhorn-native backups" \
  --body "$(cat <<'EOF'
## Summary

- Replaces Velero + helper-pod CronJob stack with native Longhorn RecurringJobs (hourly snapshot × 24, daily backup × 30).
- Adds `BackupTarget` and credentials for the in-cluster MinIO at `http://minio.minio.svc.cluster.local:9000`, bucket `longhorn-backups` (distinct from the existing `velero` bucket — no collision).
- Pins `nebari-data-science-pack` singleuser + `sharedStorage` to the new `longhorn-jhub` StorageClass; enables `sharedStorage` (RWX, 10Gi).
- Deletes `base/apps/velero.yaml`, `base/apps/velero-backup.yaml`, and `base/manifests/velero-backup/`.

Chart: https://github.com/nebari-dev/nebari-longhorn-backup-pack@0.1.0
Design spec: [./2026-05-04-longhorn-backup-design.md](./2026-05-04-longhorn-backup-design.md)

## Test plan

Post-merge, run the smoke test in the design spec's "Testing" section against the cluster:

- [ ] StorageClass `longhorn-jhub` exists; both RecurringJobs are listed in `longhorn-system`.
- [ ] BackupTarget is `Available` (`kubectl -n longhorn-system get backuptargets default -o jsonpath='{.status.available}'` → `true`).
- [ ] RWO round-trip: provision PVC on `longhorn-jhub`, write canary, force backup, delete PVC, restore — `cat /data/canary` returns the original.
- [ ] RWX round-trip: same dance against the `shared-data` PVC; verify share-manager pod comes back up before users spawn.
- [ ] Velero Deployment, BackupStorageLocation, and `velero-jhub-backup` CronJob are pruned.
EOF
)"
```

- [ ] **Step 4: Capture the PR URL**

The PR URL is printed by `gh pr create`. Note it for later reference. Do NOT merge yet.

---

### Task C8: Review and merge PR

**Files:** none (GitHub merge)

- [ ] **Step 1: Wait for any CI to pass on the PR**

```bash
gh pr checks <PR_URL>
```

- [ ] **Step 2: Merge (after explicit user approval — this is the destructive cutover)**

```bash
gh pr merge <PR_URL> --squash --delete-branch
```

- [ ] **Step 3: Watch ArgoCD sync the changes**

```bash
export KUBECONFIG=/Users/tylerman/Library/Caches/nic/hetzner-k3s/tyler-hetzner-dev/kubeconfig
kubectl -n argocd get applications --watch
```

Wait until `longhorn-backup-target`, `longhorn-backup`, and `data-science-pack` are all `Synced/Healthy`, and `velero` + `velero-backup` Applications have disappeared (pruned).

---

## Phase D — Post-merge smoke test

All Phase D tasks operate against the live cluster via:

```bash
export KUBECONFIG=/Users/tylerman/Library/Caches/nic/hetzner-k3s/tyler-hetzner-dev/kubeconfig
```

### Task D1: Verify cluster state

- [ ] **Step 1: New StorageClass present**

```bash
kubectl get sc longhorn-jhub
```

Expected: one row, provisioner `driver.longhorn.io`.

- [ ] **Step 2: RecurringJobs present**

```bash
kubectl -n longhorn-system get recurringjobs.longhorn.io
```

Expected: `jhub-hourly-snapshot` and `jhub-daily-backup`.

- [ ] **Step 3: BackupTarget healthy**

```bash
kubectl -n longhorn-system get backuptargets.longhorn.io default \
  -o jsonpath='{.status.available}{"\n"}'
```

Expected: `true`. If `false`, inspect `kubectl -n longhorn-system describe backuptargets default` and check the credentials secret + MinIO reachability.

- [ ] **Step 4: Velero stack is gone**

```bash
kubectl -n velero get all 2>&1 | head
kubectl -n argocd get application velero velero-backup 2>&1 | head
```

Expected: NotFound for both.

---

### Task D2: RWO round-trip smoke test

- [ ] **Step 1: Provision a test PVC on longhorn-jhub and write a canary**

```bash
kubectl -n default apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: backup-test }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-jhub
  resources: { requests: { storage: 1Gi } }
EOF

kubectl -n default run writer --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"w","image":"busybox","command":["sh","-c","echo hello > /data/canary && sync && sleep 3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"backup-test"}}]}}'

kubectl -n default wait pod/writer --for=condition=Ready --timeout=120s
```

- [ ] **Step 2: Confirm auto-enrollment in the jhub group**

```bash
VOL=$(kubectl -n default get pvc backup-test -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get volume $VOL \
  -o jsonpath='{.metadata.labels.recurring-job-group\.longhorn\.io/jhub}{"\n"}'
```

Expected: `enabled`.

- [ ] **Step 3: Force a backup off-schedule by creating Snapshot + Backup CRs**

```bash
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: smoke-test-snap
spec:
  volume: $VOL
EOF

kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: smoke-test-backup
  labels:
    backup-volume: $VOL
spec:
  snapshotName: smoke-test-snap
EOF
```

- [ ] **Step 4: Wait for backup to complete**

```bash
kubectl -n longhorn-system wait backup/smoke-test-backup --for=jsonpath='{.status.state}'=Completed --timeout=300s
```

If the wait times out, inspect: `kubectl -n longhorn-system describe backup smoke-test-backup`.

- [ ] **Step 5: Disaster sim — delete pod and PVC**

```bash
kubectl -n default delete pod writer
kubectl -n default delete pvc backup-test
```

- [ ] **Step 6: Restore the volume from the backup**

```bash
BACKUP_URL=$(kubectl -n longhorn-system get backup smoke-test-backup -o jsonpath='{.status.url}')

kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: backup-test-restored
spec:
  fromBackup: "$BACKUP_URL"
  numberOfReplicas: 3
  size: "1073741824"
EOF
kubectl -n longhorn-system wait volume/backup-test-restored --for=jsonpath='{.status.state}'=detached --timeout=300s
```

- [ ] **Step 7: Re-create PVC bound to the restored volume**

```bash
kubectl -n default apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: backup-test-restored }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-jhub
  resources: { requests: { storage: 1Gi } }
  volumeName: backup-test-restored
EOF
```

- [ ] **Step 8: Read the canary back**

```bash
kubectl -n default run reader --image=busybox --restart=Never --rm -it \
  --overrides='{"spec":{"containers":[{"name":"r","image":"busybox","stdin":true,"tty":true,"command":["sh","-c","cat /data/canary"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"backup-test-restored"}}]}}'
```

Expected output: `hello`. If so, RWO round-trip passes.

- [ ] **Step 9: Cleanup**

```bash
kubectl -n default delete pvc backup-test-restored
kubectl -n longhorn-system delete backup smoke-test-backup
kubectl -n longhorn-system delete snapshot smoke-test-snap || true
```

---

### Task D3: RWX round-trip smoke test

The shared PVC was created by data-science-pack post-merge.

- [ ] **Step 1: Confirm shared PVC is RWX on the new SC**

```bash
kubectl -n jupyterhub get pvc | grep -i shared
kubectl -n jupyterhub get pvc shared-data \
  -o jsonpath='{.spec.accessModes[0]} {.spec.storageClassName}{"\n"}' || true
```

Expected: `ReadWriteMany longhorn-jhub`. If the PVC name differs, find it via `kubectl -n jupyterhub get pvc` and adjust the variable below.

- [ ] **Step 2: Confirm auto-enrollment + share-manager pod**

```bash
SHARED_VOL=$(kubectl -n jupyterhub get pvc shared-data -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get volume $SHARED_VOL \
  -o jsonpath='{.metadata.labels.recurring-job-group\.longhorn\.io/jhub}{"\n"}'
# expected: enabled

kubectl -n longhorn-system get pods -l longhorn.io/share-manager=$SHARED_VOL
# expected: 1 share-manager pod Running
```

- [ ] **Step 3: Spawn two user pods, write from A, read from B**

```bash
# Spawn both users via JupyterHub UI (or via the JupyterHub API). For each user,
# verify their pod mounts /shared. Then, in user A's terminal:
#   echo "shared-canary" > /shared/canary.txt
# In user B's terminal:
#   cat /shared/canary.txt
# Expected: "shared-canary"
```

This step is operator-driven (UI). If JupyterHub admin tokens are scripted in your environment, automate; otherwise document manually.

- [ ] **Step 4: Force backup of the shared volume**

```bash
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: shared-smoke-snap
spec:
  volume: $SHARED_VOL
EOF
kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: shared-smoke-backup
  labels:
    backup-volume: $SHARED_VOL
spec:
  snapshotName: shared-smoke-snap
EOF
kubectl -n longhorn-system wait backup/shared-smoke-backup --for=jsonpath='{.status.state}'=Completed --timeout=600s
```

- [ ] **Step 5: Disaster sim for RWX — stop ALL user servers, delete shared PVC**

```bash
# Via JupyterHub admin UI or API: stop every running server.
# Once verified no pods are mounting shared-data:
kubectl -n jupyterhub delete pvc shared-data
```

ArgoCD's `selfHeal` will recreate the PVC fresh and empty after a sync — that's fine; we're about to overwrite the volume binding manually.

- [ ] **Step 6: Restore the shared volume from backup**

```bash
SHARED_BACKUP_URL=$(kubectl -n longhorn-system get backup shared-smoke-backup -o jsonpath='{.status.url}')

kubectl -n longhorn-system create -f - <<EOF
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: shared-data-restored
spec:
  fromBackup: "$SHARED_BACKUP_URL"
  numberOfReplicas: 3
  accessMode: rwx
  size: "10737418240"
EOF
kubectl -n longhorn-system wait volume/shared-data-restored --for=jsonpath='{.status.state}'=detached --timeout=600s

# Wait for share-manager to come up
kubectl -n longhorn-system get pods -l longhorn.io/share-manager=shared-data-restored --watch
```

- [ ] **Step 7: Repoint shared-data PVC at the restored volume**

```bash
kubectl -n jupyterhub apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data
  namespace: jupyterhub
spec:
  accessModes: [ReadWriteMany]
  resources: { requests: { storage: 10Gi } }
  storageClassName: longhorn-jhub
  volumeName: shared-data-restored
EOF
```

- [ ] **Step 8: Spawn a user, read the canary**

```bash
# Via JupyterHub UI: user A starts server. In their terminal:
#   cat /shared/canary.txt
# Expected: "shared-canary"
```

If the read succeeds, RWX round-trip passes. **Exit criterion** (per spec) for the smoke test: both `cat /data/canary` (RWO) and `cat /shared/canary.txt` (RWX) returned their original contents.

- [ ] **Step 9: Cleanup**

```bash
kubectl -n longhorn-system delete backup shared-smoke-backup
kubectl -n longhorn-system delete snapshot shared-smoke-snap || true
```

---

## Phase E — Wrap-up

### Task E1: Relocate spec into the new chart repo

**Files:**
- Moved from: `/Users/tylerman/gh/nebari-data-science-pack/docs/superpowers/specs/2026-05-04-longhorn-backup-design.md`
- To: `/Users/tylerman/gh/nebari-longhorn-backup-pack/docs/2026-05-04-longhorn-backup-design.md` (i.e., `./2026-05-04-longhorn-backup-design.md` relative to this plan)

- [ ] **Step 1: Move the file**

```bash
mkdir -p /Users/tylerman/gh/nebari-longhorn-backup-pack/docs
git -C /Users/tylerman/gh/nebari-data-science-pack mv \
  docs/superpowers/specs/2026-05-04-longhorn-backup-design.md \
  /Users/tylerman/gh/nebari-longhorn-backup-pack/docs/
# (git mv across repos doesn't track history; if history matters, do it as a
# plain `mv` in each repo and accept the loss.)
```

`git mv` across repos isn't actually a thing — perform two operations:

```bash
# In nebari-data-science-pack:
cd /Users/tylerman/gh/nebari-data-science-pack
git rm docs/superpowers/specs/2026-05-04-longhorn-backup-design.md  # was untracked; use plain rm instead
git commit -m "chore: relocate longhorn-backup spec to new chart repo"

# In nebari-longhorn-backup-pack:
cd /Users/tylerman/gh/nebari-longhorn-backup-pack
mkdir -p docs
# (paste the spec contents here, or copy from the original location before deleting)
git add docs/2026-05-04-longhorn-backup-design.md
git commit -m "docs: import design spec from nebari-data-science-pack"
git push origin main
```

To preserve content during the move: `cp` the file from the data-science-pack docs path before running `git rm`, then place it under the new chart repo.

- [ ] **Step 2: Update the spec's frontmatter**

In the relocated copy, change `Status: Proposed` to `Status: Implemented` and append a "Implementation" section linking to:

- The chart repo: `https://github.com/nebari-dev/nebari-longhorn-backup-pack`
- The cutover PR in the gitops repo: `https://github.com/openteams-ai/NIC-argocd-tyler-dev/pull/<PR_NUMBER>` (the merged PR from Phase C7)
- The smoke-test session date and outcome.

- [ ] **Step 3: Push the spec update**

```bash
cd /Users/tylerman/gh/nebari-longhorn-backup-pack
git add docs/2026-05-04-longhorn-backup-design.md
git commit -m "docs: mark spec Implemented; link to chart repo and cutover PR"
git push origin main
```

---

## Self-review (post-write)

**Spec coverage:**

| Spec section | Implemented in tasks |
|---|---|
| Architecture diagram | A2 (values), A5–A7 (templates), C2–C5 (gitops glue) |
| Chart components / file layout | A1 (skeleton), A2–A8 (templates + tests), A9–A10 (CI) |
| Rendered resources (SC, snapshot RJ, backup RJ) | A5, A6, A7 |
| Values surface | A2 (values.yaml), A4 (validation), A8 (flipped fixture) |
| Snapshot path (data flow) | tested via render assertions in A6; confirmed live in D2/D3 |
| Backup path (data flow) | tested via render assertions in A7; live force-backup in D2/D3 |
| Restore path (same cluster) | A11 (README runbook), D2 (RWO smoke), D3 (RWX smoke) |
| Restore path (full DR) | A11 (README runbook); chart design supports it but no live DR drill in this plan |
| Failure modes | A11 (README), validation in A4 |
| Consumer-side pinning | C5 |
| Test-cluster rollout (single PR, aggressive) | C1–C8 |
| Phase 2 off-cluster S3 promotion | not in plan (explicitly out of scope per spec) |
| RWX-specific gotchas | A11 (README), D3 |
| Open questions | tracked in spec; PR comment on https://github.com/nebari-dev/nebari-infrastructure-core/pull/270 already filed |

No spec sections lack a task.

**Placeholder scan:** Searched the plan for "TBD", "TODO", "FIXME", "implement later". The only `<placeholder>`-style tokens are intentional shell variable substitutions in code blocks (`<PR_URL>`, `<PR_NUMBER>`, `<backup-name-from-list>`, `<restored-volume-name>`) — these are explicit cues for the executor.

**Type/identifier consistency:** `longhorn-jhub` (StorageClass), `jhub` (group name), `jhub-hourly-snapshot` / `jhub-daily-backup` (RecurringJob names) used consistently across A2 (values), A5–A7 (templates), C2–C5 (gitops), D1–D3 (smoke tests). The value `storageClass.groupName` is the single source of truth — both RecurringJob templates and the StorageClass `recurringJobSelector` derive from it via `nebari-longhorn-backup.groupName`, so they cannot drift.

**Gates worth knowing:** Phase B1 (creating the public repo on `nebari-dev`), Phase C7/C8 (opening and merging the cutover PR), and Phase D5 (disaster sim — deleting shared PVC) all require explicit user approval before the executor proceeds. They are visible, public, or destructive cluster-state changes.
