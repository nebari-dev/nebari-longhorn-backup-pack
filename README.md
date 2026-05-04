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
