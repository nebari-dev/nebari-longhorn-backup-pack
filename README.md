# nebari-longhorn-backup

Longhorn-native snapshot and backup schedule for the cluster's default StorageClass. Two `RecurringJob`s, one cluster-wide `Setting` — nothing else.

## What it does

| Resource | Purpose | Schedule (defaults) | Retention |
|---|---|---|---|
| `RecurringJob/default-hourly-snapshot` | In-cluster CoW snapshot. Fast, RPO ≈ 1h, no S3 traffic. | `0 * * * *` | 24 (rolling 24h) |
| `RecurringJob/default-daily-backup` | Snapshot + stream blocks to the BackupTarget S3 bucket. Durable, off-cluster. | `0 3 * * *` | 30 (rolling 30 days) |
| `Setting/allow-recurring-job-while-volume-detached` | Makes RecurringJobs auto-attach detached volumes long enough to take the snapshot/backup. | n/a | n/a |

## Coverage model

The chart's RecurringJobs target Longhorn's built-in `default` recurring-job-group. Longhorn auto-labels every volume `recurring-job-group.longhorn.io/default=enabled` whenever the volume's StorageClass has no `recurringJobSelector` parameter — which is the case for the cluster's default `longhorn` StorageClass and any chart-provided SC that doesn't set its own selector. The result: install this chart and every volume on the cluster's default SC is covered.

Out of scope (intentional): per-workload group targeting and dedicated paired StorageClasses. The chart is deliberately small.

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

## Values

See [`values.yaml`](./values.yaml) for the full surface.

| Path | Default | Notes |
|---|---|---|
| `snapshot.cron` / `snapshot.retain` | `0 * * * *` / `24` | Hourly snapshot. |
| `backup.cron` / `backup.retain` | `0 3 * * *` / `30` | Daily backup. |
| `clusterSettings.allowRecurringJobWhileVolumeDetached` | `true` | Cluster-wide Longhorn setting: snapshots fire on detached volumes (chart auto-attaches). Set to `null` to leave Longhorn's existing value untouched. |
| `longhornNamespace` | `longhorn-system` | Where the RecurringJobs and Setting are placed. |

Validation guards run at render time: invalid cron expressions or non-positive retention cause `helm template` to fail with a clear message.

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
#    Backup → Restore → name=${VOL}-restored → Storage Class=longhorn
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
  storageClassName: longhorn
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
