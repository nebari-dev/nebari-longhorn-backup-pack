# Longhorn-native backup for JupyterHub user volumes

- **Date**: 2026-05-04
- **Status**: Implemented
- **Authors**: Tyler Potts (tpotts@openteams.com)
- **Scope**: One Hetzner k3s test cluster (`tyler-hetzner-dev`); chart designed to be reusable.

## Context

The cluster runs JupyterHub via the `nebari-data-science-pack` Helm chart with KubeSpawner. Users get per-user PVCs (`claim-<username>`) and an optional shared (RWX) PVC. Two failure modes need protection:

- **Accidental data loss** — user deletes a notebook, PVC corruption, "oops I `rm`'d." Recovery to the same cluster, RPO ≈ 1h is acceptable.
- **Full cluster disaster recovery** — the Hetzner cluster is destroyed; user data must be recoverable on a fresh cluster.

A prior session shipped a Velero + helper-pod CronJob solution before Longhorn was available. That stack works but only because helper pods exist to mount idle volumes (Velero file-system backup can't read unmounted PVCs). The cluster now runs Longhorn, which backs up volumes regardless of pod state — the helper-pod workaround is no longer needed.

## Goals

- Hourly **snapshots** of user PVCs and the shared PVC for fast in-cluster rollback (RPO ≈ 1h).
- Daily **backups** of the same volumes to S3 (initially in-cluster MinIO, designed to swap to Hetzner Object Storage).
- Cross-cluster restore: a fresh Longhorn install pointed at the same bucket discovers existing backups automatically.
- Replace the Velero + helper-pod CronJob stack — same scope, simpler architecture.
- Distribute the schedule + storage-class definition as a small standalone Helm chart (`nebari-longhorn-backup-pack`) so other Nebari deployments can adopt it.

## Non-goals

- Backing up Hub DB / Keycloak Postgres / MLflow Postgres / MinIO contents / Redis. Out of scope: losing the Hub DB resets server state (named servers, last-active timestamps), which is acceptable for this work.
- Backing up Kubernetes resources (ConfigMaps, Secrets, CRDs) for full platform rebuild — out of scope.
- Bringing Longhorn install under GitOps. Longhorn is currently installed out-of-band; this design assumes that.
- Fixing the cluster's double-default-StorageClass condition. Tracked separately via a review comment on https://github.com/nebari-dev/nebari-infrastructure-core/pull/270.
- Self-service user-facing restore UI. Restores are operator-driven via `kubectl` / Longhorn UI.

## Architecture

```
┌──────────────────── nebari-longhorn-backup-pack chart ─────────────────────┐
│  StorageClass/longhorn-jhub                                                 │
│    parameters.recurringJobSelector: [{name: jhub, isGroup: true}]           │
│  RecurringJob/jhub-hourly-snapshot   cron 0 * * * *  task snapshot retain 24│
│  RecurringJob/jhub-daily-backup      cron 0 3 * * *  task backup   retain 30│
└─────────────────────────────────────────────────────────────────────────────┘
                                     │ ArgoCD Application sources the chart
                                     ▼
┌──────────────────── NIC-argocd-tyler-dev (gitops repo) ────────────────────┐
│  base/apps/longhorn-backup.yaml          ← new ArgoCD app                   │
│  base/manifests/longhorn-backup-target/                                     │
│      backuptarget.yaml                   ← Longhorn BackupTarget CR         │
│      secret.yaml                         ← S3 credentials                   │
│  base/apps/data-science-pack.yaml        ← values pinned to longhorn-jhub,  │
│                                            sharedStorage.enabled: true     │
│  REMOVED: base/apps/velero.yaml,                                            │
│           base/apps/velero-backup.yaml,                                     │
│           base/manifests/velero-backup/                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Boundaries:**

- **Chart** owns "how to schedule snapshots and backups for a class of volumes." Only Longhorn CRDs. No cluster-specific values.
- **Gitops repo** owns "where backups go" (BackupTarget + S3 secret) and "which charts opt in" (the storage-class override). Cluster-specific.

## Chart components

Repo: `github.com/nebari-dev/nebari-longhorn-backup-pack`

```
Chart.yaml
values.yaml
README.md                   usage + restore runbook
.github/workflows/lint.yaml      helm lint, kubeconform on rendered output
.github/workflows/release.yaml   on tag: package + publish chart to gh-pages
templates/
  _helpers.tpl
  storageclass.yaml         Longhorn StorageClass (auto-enrolls volumes in group)
  recurringjob-snapshot.yaml hourly snapshot RecurringJob
  recurringjob-backup.yaml   daily backup RecurringJob
  NOTES.txt                 post-install info
.helmignore
```

### Rendered resources

```yaml
# 1. StorageClass — every PVC provisioned through this class is auto-enrolled in
#    the "jhub" recurring-job group (no labeling step needed).
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-jhub
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "30"
  recurringJobSelector: |
    [{"name":"jhub","isGroup":true}]
  fsType: "ext4"
---
# 2. Hourly snapshot — in-cluster CoW, fast, RPO ≈ 1h.
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: jhub-hourly-snapshot
  namespace: longhorn-system
spec:
  cron: "0 * * * *"
  task: snapshot
  groups: ["jhub"]
  retain: 24
  concurrency: 5
---
# 3. Daily backup — pulls from latest snapshot, streams to BackupTarget S3.
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: jhub-daily-backup
  namespace: longhorn-system
spec:
  cron: "0 3 * * *"
  task: backup
  groups: ["jhub"]
  retain: 30
  concurrency: 3
```

### Values surface

```yaml
longhornNamespace: longhorn-system

storageClass:
  name: longhorn-jhub
  numberOfReplicas: 3
  reclaimPolicy: Delete
  fsType: ext4
  groupName: jhub                    # also the recurring-job group selector

snapshot:
  enabled: true
  cron: "0 * * * *"
  retain: 24
  concurrency: 5

backup:
  enabled: true
  cron: "0 3 * * *"
  retain: 30
  concurrency: 3

commonLabels: {}
commonAnnotations: {}
```

CI validates:

- `snapshot.cron` and `backup.cron` parse as valid cron expressions.
- Retention values are positive integers.
- `numberOfReplicas` ∈ {1, 2, 3}.
- `groupName` is the single source of truth — referenced by both RecurringJobs *and* the SC's `recurringJobSelector`, so they cannot drift.

## Data flow

### Snapshot path (hourly, in-cluster, ~seconds)

```
cron tick → Longhorn manager iterates volumes labeled in group "jhub"
         → for each: marks current head, opens new CoW layer (instant)
         → Snapshot CR created in longhorn-system
         → if count > retain (24): oldest snapshots pruned
         → no network I/O, no pod disruption
```

### Backup path (daily 03:00, off-cluster, minutes per volume)

```
cron tick → Longhorn manager takes a fresh snapshot per volume in group "jhub"
         → reads BackupTarget CR (configured by gitops layer)
         → streams blocks to S3 (first run: full; subsequent: incremental)
         → Backup CR created; metadata in BackupVolume CR
         → if count > retain (30): oldest backups pruned in-bucket
         → concurrency caps to 3 volumes at a time
```

### Restore path — same cluster

Operator workflow (full `kubectl` examples in the chart README):

1. Stop the user's pod so the PVC can be unbound.
2. Find the Longhorn volume name from the PVC.
3. Either revert in-place to a snapshot (fast, no S3 round-trip) or restore from a backup into a new Longhorn Volume.
4. Repoint the PVC at the restored volume (`spec.volumeName`).
5. User restarts server; KubeSpawner re-attaches.

### Restore path — full DR, fresh cluster

A fresh Longhorn install on a new cluster, pointed at the same S3 bucket:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: longhorn-backup-target-credentials
  namespace: longhorn-system
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID:     <key>
  AWS_SECRET_ACCESS_KEY: <secret>
  AWS_ENDPOINTS:         https://fsn1.your-objectstorage.com
---
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL:   s3://longhorn-backups@us-east-1/
  credentialSecret:  longhorn-backup-target-credentials
  pollInterval:      5m0s
```

After one poll cycle, `kubectl -n longhorn-system get backupvolumes` lists every volume from the destroyed cluster — pure metadata discovery, no block transfer until restore. The bucket *is* the source of truth; the cluster is fungible.

**DR gotchas worth knowing:**

1. **No automatic PVC re-binding.** Restore creates a Longhorn `Volume` CR; you still issue PVC manifests with `volumeName: <restored>` to wire them into workloads.
2. **In-flight backup locks.** If the source cluster died mid-backup, a stale lock in `backupstore/lock/` may persist. New cluster reads existing backups fine; writing new backups may complain until the lock is removed (`mc rm`/`s3cmd del`).
3. **Encryption keys.** If volume encryption is enabled, the Kubernetes secret holding the key must be re-created on the new cluster — the bucket alone isn't enough. Not in scope for the POC.
4. **Two-clusters-one-bucket = corruption.** If the "destroyed" cluster comes back to life mid-DR (network partition, not actual death), both clusters writing to the same `backupstore/` will corrupt each other's metadata. DR runbooks should rotate the bucket prefix or the credential before declaring the new cluster authoritative.

### Failure modes the design tolerates

- **MinIO down at backup time** → backup CR transitions to `Error`; next cron tick retries. Snapshots still succeed (in-cluster, independent path).
- **Volume detached at snapshot time** → Longhorn snapshots detached volumes natively (no helper-pod hack required).
- **Cluster destroyed mid-backup** → at most one day of data lost; in-flight blocks orphaned in S3 are reclaimed by Longhorn's bucket cleanup.

### Failure modes NOT covered

- MinIO bucket loss = total backup loss. The POC accepts this; the off-provider migration in Phase 2 fixes it.
- BackupTarget credential rotation isn't automated; rotating the secret requires a Longhorn settings refresh.

## Consumer-side pinning

`base/apps/data-science-pack.yaml` values overlay:

```yaml
helm:
  values: |
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

Existing user PVCs (none on this cluster today) would stay on whichever class they were created with — Kubernetes doesn't move bound PVCs. The new SC only applies to PVCs created after the cutover.

## Rollout / cutover (test cluster)

This is a test cluster; aggressive cutover is acceptable.

**One PR**, all at once:

- New `nebari-longhorn-backup-pack` repo created with chart + CI + first tagged release `v0.1.0`.
- `base/manifests/longhorn-backup-target/{secret.yaml,backuptarget.yaml}` — points at in-cluster MinIO, bucket `longhorn-backups` (separate from existing `velero` bucket).
- `base/apps/longhorn-backup.yaml` — ArgoCD app sourcing the chart.
- `base/apps/data-science-pack.yaml` — values pinned to `longhorn-jhub`, `sharedStorage.enabled: true`.
- **Delete**: `base/apps/velero.yaml`, `base/apps/velero-backup.yaml`, `base/manifests/velero-backup/`. ArgoCD prunes Velero on next sync.

Verification happens **post-merge** by running the smoke test below. If it fails, `git revert` the cutover commit.

> **Note on production rollout (out of scope).** Production clusters with live user data should split this into two PRs: install + verify the new system before deleting Velero. Existing PVCs on the old class would need an explicit migration plan (drain via natural turnover, or clone-and-swap per user). This spec covers only the test-cluster path.

## Phase 2 — promote backup target off-cluster

Out of scope for this work but the design supports it:

- Create Hetzner Object Storage bucket + credentials.
- Update the `BackupTarget` URL + secret. Longhorn re-discovers; no chart changes needed.
- The first backup after cutover is full-not-incremental against the new bucket — expect a one-time bandwidth spike.

## Testing

### Chart-level (CI on the new repo)

- `helm lint` and `helm template` on default values + an "all knobs flipped" fixture.
- `kubeconform` against rendered output (validates Kubernetes API + `longhorn.io` CRD schemas).
- Render-determinism: `helm template … | sort` byte-identical between runs.

### Cluster-level smoke test (post-merge runbook)

```bash
# RWO round-trip (singleuser-style PVC) ----------------------------------------

kubectl get sc longhorn-jhub
kubectl -n longhorn-system get recurringjobs

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
  --overrides='{"spec":{"containers":[{"name":"w","image":"busybox","command":["sh","-c","echo hello > /data/canary && sleep 3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}],"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"backup-test"}}]}}'

VOL=$(kubectl -n default get pvc backup-test -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get volume $VOL \
  -o jsonpath='{.metadata.labels.recurring-job-group\.longhorn\.io/jhub}'
# expected: "enabled"

# Force a backup off-schedule by creating a Snapshot CR then a Backup CR
# referencing it (Longhorn does not expose a "run-now" API on RecurringJobs;
# the K8s-native equivalent is to materialise the resources directly).
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

kubectl -n longhorn-system get backups.longhorn.io --watch     # → Completed

kubectl -n default delete pod writer
kubectl -n default delete pvc backup-test

# Restore-from-backup steps (Longhorn UI or API), then verify "hello" round-trips.

# RWX round-trip (shared storage) ---------------------------------------------

kubectl -n jupyterhub get pvc shared-data \
  -o jsonpath='{.spec.accessModes[0]} {.spec.storageClassName}'
# expected: "ReadWriteMany longhorn-jhub"

SHARED_VOL=$(kubectl -n jupyterhub get pvc shared-data -o jsonpath='{.spec.volumeName}')
kubectl -n longhorn-system get volume $SHARED_VOL \
  -o jsonpath='{.metadata.labels.recurring-job-group\.longhorn\.io/jhub}'
# expected: "enabled"

kubectl -n longhorn-system get pods -l longhorn.io/share-manager=$SHARED_VOL
# expected: 1 share-manager pod Running

# Spawn two user servers, write from user A, read from user B (RWX semantics test).
# Then force backup, delete shared PVC, restore, wait for share-manager, verify data.
kubectl -n longhorn-system get pods -l longhorn.io/share-manager --watch
```

**Exit criterion**: both `cat /data/canary` (RWO) and `cat /shared/canary.txt` (RWX) return their original contents after a full destroy → restore cycle.

### RWX-specific gotchas (in the runbook)

- The share-manager pod is a single-replica Deployment fronting an underlying RWO volume. When the underlying volume goes away, the share-manager crash-loops. **No user pod can mount the shared volume until the share-manager is Ready** — restore order matters: restore the RWX volume first, wait for the share-manager, then let users spawn.
- Snapshots target the underlying RWO volume, not the NFS export. Active writes through NFS are subject to the usual write-back caching; snapshotting mid-write may miss the last few hundred ms of buffered writes. Acceptable for this scope; for stricter consistency, quiesce the share-manager first.

### Cross-cluster (deferred to Phase 2)

Stand up a kind/k3d cluster, install Longhorn, point its `BackupTarget` at the same off-cluster bucket. Verify `BackupVolumes` populate from the existing backups. No restore — just the discovery half. This is the "cluster blew up" rehearsal.

## Open questions / future work

- **Cluster default StorageClass.** Two classes are currently annotated as default; PVCs without an explicit class are bound nondeterministically. Tracked on https://github.com/nebari-dev/nebari-infrastructure-core/pull/270. This spec does not depend on the fix because every consumer of the new SC pins `storageClassName` explicitly.
- **Off-cluster S3 promotion.** Phase 2; design already supports it via a `BackupTarget` URL/secret swap.
- **Production rollout plan.** Verification gate before Velero removal, plus a per-user migration plan for existing PVCs on the old class. Separate spec.
- **BackupTarget credential rotation.** Currently manual. Future work could automate via a Job triggered on Secret update.
- **Self-service restore.** Out of scope. If demand surfaces, a small admin extension on JupyterHub (or a separate operator UI) could expose "restore my volume to T-1h" without operator involvement.

## Implementation

- **Chart repository**: https://github.com/nebari-dev/nebari-longhorn-backup-pack
- **First published version**: 0.1.1 (0.1.0 was published but had a missing `spec.name` field that Longhorn v1.8.1's webhook rejects; 0.1.1 fixes it).
- **Cutover PR (gitops)**: https://github.com/openteams-ai/NIC-argocd-tyler-dev/pull/2 — replaces the Velero + helper-pod CronJob stack with the new chart, configures the in-cluster MinIO `BackupTarget`, and pins the data-science-pack singleuser + shared storage to `longhorn-jhub`.
- **Implementation plan**: [`2026-05-04-longhorn-backup-implementation.md`](./2026-05-04-longhorn-backup-implementation.md).
- **Smoke test outcome (2026-05-05)**:
  - RWO round-trip on `tyler-hetzner-dev`: created PVC on `longhorn-jhub`, wrote canary, force-backed-up via Longhorn manager API, deleted PVC, restored Volume from Backup CR, re-bound PVC to a fresh PV, read canary back. PASS.
  - RWX round-trip: created RWX PVC on `longhorn-jhub`, attached two pods simultaneously, verified cross-pod read-after-write through the Longhorn share-manager NFS frontend, backed up, deleted, restored with `spec.frontend: blockdev` + `spec.accessMode: rwx`, re-bound PVC, read canary back. PASS.

### Operational findings worth folding into a future chart 0.1.2

1. **Forcing a snapshot off-schedule** — direct `kubectl create Snapshot` against an attached volume fails in Longhorn v1.8.1 with `"lost track of the corresponding snapshot info inside volume engine"`. Workaround: call the Longhorn manager HTTP API at `POST /v1/volumes/<vol>?action=snapshotCreate`. The manager listens on its pod IP, not localhost; only `curl` is available in the manager container.
2. **Restoring a Volume from Backup CR** — `spec.frontend: blockdev` is mandatory for both RWO and RWX. Empty/omitted is rejected by the webhook.
3. **RWX requires `nfs-common` on nodes** — Longhorn v1.8.1 deploys a `longhorn-iscsi-installation` DaemonSet but **not** an equivalent `longhorn-nfs-installation`. On Ubuntu/Debian nodes, RWX pods will hang in `ContainerCreating` with `bad option; you might need a /sbin/mount.nfs4 helper program` until `nfs-common` is installed. Tracked as a follow-up in `nebari-infrastructure-core`.

### Known gaps (deferred)

- The release workflow uses `git push --force` to update `gh-pages`, replacing rather than appending the chart index. After 0.1.1 was released, 0.1.0 was no longer listed in `index.yaml`. Inherited pattern from `nebari-data-science-pack`'s release workflow. Future fix: use `helm repo index --merge index.yaml` against the existing branch.
- The `nebari-data-science-pack` chart enables `sharedStorage` (creates a PVC) but does not actually wire `extraVolumes`/`extraVolumeMounts` into the singleuser pod spec, so user pods don't currently see `/shared`. Separate from the backup work; affects RWX usability but not RWX backup mechanics.
- Cluster's double-default StorageClass annotation: addressed manually on the test cluster (annotated `hcloud-volumes` to `is-default-class: false`), with a durable upstream fix proposed via review comment on https://github.com/nebari-dev/nebari-infrastructure-core/pull/270 (`stripPreviousDefaultStorageClasses` helper in `pkg/storage/longhorn/install.go`).
