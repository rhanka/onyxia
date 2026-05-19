# 2026-05-19 — Dataviz catalog blocked by missing LimitRange on user namespaces

## Symptom

- `superset` launcher: `PUT /api/my-lab/app` returns `500` ; Helm release ends `failed: post-install Job ... not ready ... context deadline exceeded`.
- `metabase` launcher: appears to deploy, Helm marks the release `deployed`, but the user-facing URL returns `503` and no Metabase pod ever schedules.

## Root cause

The Onyxia-provisioned user namespace gets a `ResourceQuota` (e.g. `onyxia-quota`) that requires every container to declare both `limits.cpu` and `limits.memory`. No `LimitRange` is configured to supply defaults.

InseeFrLab dataviz charts (`metabase 2.0.3`, `superset 0.1.12`) include init containers / post-install Jobs that do not set explicit resource limits on every container:

- `metabase`: init container `wait-for-postgresql` has no `resources.limits` → main Deployment ReplicaSet hits `FailedCreate: forbidden: failed quota: onyxia-quota: must specify limits.cpu for: wait-for-postgresql; limits.memory for: wait-for-postgresql`.
- `superset`: post-install Job `<release>-init-db` (and downstream Statefulsets `superset-db`, `superset-778707-redis-master`) hit the same wall, so Helm times out waiting for the post-install Job to complete → release `failed`.

The result is misleading: `helm list` reports `metabase-243112` as `deployed` even though `kubectl get deploy metabase-243112` reports `Available=False` with `ReplicaFailure=True`.

## Fix options

### Immediate (per-namespace, manual)

Apply a `LimitRange` to the affected user namespaces so containers without explicit `resources.limits` inherit sane defaults. Minimal proposal:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: onyxia-default-limits
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 500m
        memory: 512Mi
```

This unblocks dataviz launchers without modifying the upstream chart. The launcher must then be retried from the Onyxia UI; the first failed release must have been cleaned via `helm uninstall` (cf. superset cleanup recorded the same day).

### Durable (chart-level, upstream)

Two upstream tracks:

1. **Onyxia chart**: extend `regions[].services` provisioning to include an optional `limitRange` spec next to `quotas`, so every user namespace gets one out of the box. Open issue/PR against `InseeFrLab/onyxia` (chart `inseefrlab/onyxia`).
2. **Dataviz charts**: file PRs against `inseefrlab/helm-charts-datavisualization` so every container (init, hook Jobs, sidecars) declares `resources.limits`. This is the right long-term fix; the LimitRange is a workaround.

## State after immediate cleanup

- `superset-778707` release removed via `helm uninstall`; orphan PVC `data-superset-db-0` and Job `superset-778707-init-db` purged. Namespace `user-74acb16a-54b3-417a-b7be-cf7037e93ee8` is now back to: `metabase-243112` (failed pod) + `metabase-db-0` (Postgres running).
- DNS `polaris.onyxia.sent-tech.ca → 34.135.88.193` confirmed resolved (explicit A-record, not wildcard).

## Next actions

- [ ] Decide: apply the `LimitRange` directly to the affected user namespace as a live patch (needs explicit user approval, it mutates a live workload-related object).
- [ ] Decide: open upstream PR/issue on Onyxia chart for native `namespaceProvisioning.limitRange` support.
- [ ] Re-launch `metabase` and `superset` from the Onyxia UI after the LimitRange is in place; confirm pods schedule.
