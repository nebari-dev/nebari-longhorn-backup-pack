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

Or via ArgoCD, with a standard Application pointing at this chart's published Helm repo.

## Values

See [`values.yaml`](./values.yaml) for the full surface.

| Path | Default | Notes |
|---|---|---|
| `snapshot.cron` / `snapshot.retain` | `0 * * * *` / `24` | Hourly snapshot. |
| `backup.cron` / `backup.retain` | `0 3 * * *` / `30` | Daily backup. |
| `clusterSettings.allowRecurringJobWhileVolumeDetached` | `true` | Cluster-wide Longhorn setting: snapshots fire on detached volumes (chart auto-attaches). Set to `null` to leave Longhorn's existing value untouched. |
| `longhornNamespace` | `longhorn-system` | Where the RecurringJobs and Setting are placed. |

Validation guards run at render time: invalid cron expressions or non-positive retention cause `helm template` to fail with a clear message.

## Restoring from a backup

This pack only schedules backups — restore is a Longhorn operation. The steps below use the Longhorn UI for both RWO (e.g. user home directories, hub DB) and RWX (shared storage) volumes.

### Open the Longhorn UI

The UI is ClusterIP-only by default. Port-forward in a separate terminal:

```bash
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
# → http://localhost:8080
```

### Restoring an RWO volume

Example: `claim-tpotts` (a user home directory) in namespace `jupyterhub`.

1. **Stop the workload** so the PVC can be released cleanly.
   ```bash
   kubectl -n jupyterhub get pod -l hub.jupyter.org/username=tpotts -o name | xargs -r kubectl delete
   ```

2. **Delete the PVC.** With the default `Delete` reclaim policy on the `longhorn` StorageClass, this cascades to the PV and the underlying Longhorn Volume.
   ```bash
   kubectl -n jupyterhub delete pvc claim-tpotts
   ```
   If a chart or ArgoCD Application declares this PVC with `selfHeal: true`, temporarily disable auto-sync for that release first — otherwise the PVC will be recreated blank within the next reconcile.

3. **Restore in the Longhorn UI.**
   - **Backup** in the left sidebar → find the row for the deleted source volume (named `pvc-<UUID>`); expand it.
   - Click the **timestamp** of the backup you want.
   - Click **Restore Latest Backup** (or, in the dropdown of an older row, **Restore**).
   - Fill in:
     - **Name**: any new identifier, e.g. `claim-tpotts-restored`. This becomes the new Longhorn Volume name.
     - **Number of Replicas**: typically `3`.
     - **Access Mode**: **`ReadWriteOnce`**.
     - Other fields: leave at defaults.
   - **OK**. Wait for the new volume to reach **`Detached`** in the **Volume** tab (seconds to minutes, depending on backup size).

4. **Re-expose the restored volume as a PV/PVC.**
   - Open the restored volume's detail page (click its name in **Volume**).
   - Click **Create PV/PVC** in the top-right.
   - **PV Name**: any identifier, e.g. `pv-claim-tpotts-restored`.
   - **PVC Name**: `claim-tpotts` — **must exactly match the original PVC name**.
   - **Namespace**: `jupyterhub` — **must exactly match the original namespace**.
   - **Access Mode**: ReadWriteOnce.
   - **OK**.

5. **Verify and restart the workload.**
   ```bash
   kubectl -n jupyterhub get pvc claim-tpotts             # STATUS=Bound
   ```
   Spawn the user's server from the JupyterHub UI — KubeSpawner re-attaches the (now restored) PVC.

### Restoring an RWX volume (shared storage)

Same overall flow as RWO, with two differences:

- **Access Mode** in both the restore dialog and the Create PV/PVC dialog must be **`ReadWriteMany`**.
- A Longhorn **share-manager** pod (NFS frontend) must reach `Ready` before any consumer pod can mount the volume.

Example: `shared-storage` PVC in `jupyterhub`.

1. **Stop every workload using the shared volume** (e.g. all singleuser pods).
2. **Delete the PVC:**
   ```bash
   kubectl -n jupyterhub delete pvc shared-storage
   ```
3. **Restore in the Longhorn UI** (same as RWO step 3), with **Access Mode = `ReadWriteMany`**.
4. **Create PV/PVC** (same as RWO step 4):
   - **PVC Name**: `shared-storage`
   - **Namespace**: `jupyterhub`
   - **Access Mode**: ReadWriteMany
5. **Wait for the share-manager** to come up (30–60 seconds typically):
   ```bash
   kubectl -n longhorn-system get sharemanagers.longhorn.io
   # Wait until the entry for the restored volume shows STATE=running
   ```
6. **Spawn a consumer workload to verify.** Inside the pod:
   ```bash
   mount | grep nfs    # should show the NFS mount on /shared/<...>
   ```

### Full DR — fresh cluster, same S3 bucket

A fresh Longhorn install pointed at the same `backupTargetURL` and credentials auto-discovers existing backups within one poll cycle (default 5 min). Then:

1. Confirm discovery:
   ```bash
   kubectl -n longhorn-system get backupvolumes.longhorn.io
   ```
2. For each volume to restore, follow the RWO or RWX flow above. Re-use the same PVC name and namespace from the original cluster so workloads bind without manual intervention.
3. JupyterHub: spawn user servers as normal. File data is intact; the hub DB resets unless it was also backed up.

### Gotchas

- **Stop the workload first.** Deleting a PVC while a pod still mounts it hangs on `pvc-protection` until the consumer is gone.
- **PVC name + namespace must match exactly.** Kubernetes binds PVCs to PVs by `(name, namespace)`, not UUID — any mismatch orphans the new PV.
- **ArgoCD `selfHeal` vs PVC delete.** If the PVC is declared in a chart that ArgoCD manages with `selfHeal: true`, ArgoCD will recreate it blank within ~3 min. Either disable auto-sync on that Application during the restore, or race ArgoCD by completing steps 3–4 quickly.
- **In-flight backup locks.** If the source cluster died mid-backup, a stale lock in `backupstore/lock/` may persist. Reads work; new writes complain until the lock is removed (`mc rm`).
- **Two clusters → one bucket = corruption.** If the "destroyed" cluster comes back to life mid-DR, both clusters writing to the same `backupstore/` will corrupt each other's metadata. Rotate the bucket prefix or credential before declaring the new cluster authoritative.

### RWX-specific notes

- The Longhorn share-manager pod is a single-replica Deployment fronting the underlying RWO volume. Snapshots target the underlying RWO volume, not the NFS export — active writes through NFS are subject to write-back caching, so snapshotting mid-write may miss the last few hundred ms of buffered writes. Quiesce the share-manager first if you need stricter consistency.
- **Node prerequisites for RWX consumers**: each Kubernetes node that runs a pod mounting an RWX volume needs `nfs-common` (or the equivalent for your distro) installed, with the `nfs`/`nfsv4` kernel modules loadable. If you see `mount: bad option; for several filesystems (e.g. nfs, cifs) you might need a /sbin/mount.<type> helper program` in pod events, the node is missing the NFS client.

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
