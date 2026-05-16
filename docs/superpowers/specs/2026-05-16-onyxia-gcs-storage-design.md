# Design — Onyxia data storage on Google Cloud Storage

**Status:** Brainstorm, ready for review
**Branch:** `brainstorm/gcs-buckets`
**Related work:** `helm-chart/examples/gke-ephemeral/` (Onyxia on GKE)

## Context

Onyxia's API exposes per-user object storage to launched services (Jupyter, Spark, etc.) via the `api.regions[].data` config block. Out of the box, this block supports `type=S3` (AWS, MinIO, OBC) — there is no `type=GCS`. Our current example runs on GKE, so the natural storage is Google Cloud Storage, not S3.

The user wants users of `https://onyxia.sent-tech.ca` to be able to read/write GCS buckets from their notebooks, with per-user bucket scoping consistent with how Onyxia does it on AWS.

## Goal

- Users see a "my files" namespace in Onyxia backed by GCS, with a bucket per user.
- Launched services (Jupyter, Spark, Trino…) get short-lived credentials and the right env vars (`AWS_*`, `MLFLOW_S3_ENDPOINT_URL`, etc.) injected automatically by Onyxia, no manual config.
- No code change to upstream Onyxia.
- Costs stay in line with the example's ~$4/day target — no MinIO sidecar tax.

## Chosen approach: GCS S3-interop

Google Cloud Storage [exposes a fully S3-compatible interop API](https://cloud.google.com/storage/docs/interoperability) at `https://storage.googleapis.com`. We point Onyxia's `region.data.type=S3` at that endpoint and let the existing S3 plumbing handle everything. This is the same pattern Snowflake, Databricks, and DuckDB use when they "support GCS" — they don't, they reuse their S3 client over the interop endpoint.

Trade-offs vs. the rejected alternatives:

| | GCS interop (chosen) | MinIO gateway | Native GCS provider |
|---|---|---|---|
| Onyxia code change | none | none | API + frontend PR |
| Extra runtime cost | 0 | ~1 pod (~0.2 vCPU) | 0 |
| Auth model | static HMAC keys per service account | static HMAC keys | OAuth2 / WIF |
| Per-user bucket | yes (via Onyxia STS flow, see below) | yes | yes |
| Maintenance | Google-owned interop API | MinIO gateway DEPRECATED since 2024 | Onyxia upstream |
| Time to ship | 1–2 h | 1 day | 2–3 weeks |

## Architecture

```
┌────────────────────┐                         ┌──────────────────────┐
│ Onyxia API         │                         │ user-<keycloak-uuid> │
│ region.data.type=S3│ ─── injects env vars ─► │   Jupyter pod        │
│ endpoint=googleapis│   (AWS_*, S3_*)         │ ─── boto3/s3fs ────► │── GCS interop ──► gs://user-<uuid>
└────────────────────┘                         └──────────────────────┘
       ▲
       │ Vault STS / Onyxia-owned credentials store
       │
       └── Google service account, mode "HMAC keys per service account",
           one HMAC pair per user, rotated by Onyxia.
```

### Pieces

1. **GCS interop access** — enable Storage Interoperable mode on the bucket project (one-shot, free).
2. **Service-account-based HMAC keys** — Onyxia API needs to mint HMAC pairs scoped to a per-user GCP service account so that each user's credentials can only read their own bucket. Two sub-options:
   - **Easy path:** one shared GCS service account with HMAC keys, plus IAM Conditions / bucket policy that scopes each key to a single bucket prefix. Onyxia hands the same key to every user but each user's request gets rewritten/scoped on the bucket. Loose isolation.
   - **Strict path:** one service account per Onyxia user, one HMAC key per service account, IAM binding `roles/storage.objectAdmin` on `gs://user-<uuid>` only. Strong isolation, but bumps against a hard GCP quota of 5 HMAC keys per service account and ~100 service accounts per project. Fine up to ~80 users.
3. **Onyxia `region.data.S3` block** —
   ```yaml
   region:
     data:
       type: S3
       defaultDurationSeconds: 86400
       monitoring:
         enabled: false
       S3:
         URL: https://storage.googleapis.com
         region: auto                       # GCS ignores it
         pathStyleAccess: true              # virtual-host style works too, but path is safer
         oidcConfiguration:
           role-arn: ""                     # unused with HMAC
         credentialsType: STATIC            # not STS — GCS interop doesn't speak AssumeRole
         credentials:
           accessKeyId:     <fed from Vault per user>
           secretAccessKey: <fed from Vault per user>
   ```
   The values for `credentials.*` are filled by Onyxia API per request using a Vault path keyed on the user identity (Onyxia already does this on SSP Cloud, just with MinIO STS).
4. **Bucket-per-user lifecycle** — a small controller (CronJob or Job triggered on first login via Onyxia's onboarding hook) provisions `gs://${PROJECT_ID}-onyxia-user-${KEYCLOAK_SUB}` if missing, with a service account + HMAC pair stored back in Vault.

### Terraform / Helm changes for the example

- New layer `terraform/data/` (or extension of `terraform/base/`) that creates:
  - The Onyxia data project + bucket location.
  - The Vault helm release (small dev mode, OK for the ephemeral example).
  - A starter service account `onyxia-storage-bootstrap` with `storage.admin` on the bucket project, to seed Onyxia's bucket-per-user provisioning.
- Update `onyxia-gke-public-values.yaml` to add the `data` block.
- New scripts/`gcs-bootstrap.sh`: creates the project-level Storage Interop enable + a starter HMAC key for the bootstrap SA.

## Open questions

1. **Bucket per user vs. per project namespace?** Onyxia supports both. Pick one: per user (`user-${sub}`) or per Onyxia "project" (`project-${id}`). Default: per user.
2. **Vault deployment.** Onyxia uses Vault to broker creds. Do we deploy a real Vault on the cluster (~1 vCPU + persistence) or live with the simpler "static credentials in values" path until the user count exceeds ~3? Default: skip Vault, single shared service account with IAM bucket-prefix policy, until we hit users > 5.
3. **STS / short-lived tokens.** GCS interop does NOT support AWS STS-style temporary credentials. If we want short-lived creds we have to rotate HMAC keys server-side, which adds a Job. Tolerable for an ephemeral cluster — credentials live ≤ 24 h via HMAC key rotation.
4. **GCS IAM Conditions vs. signed URL gateway.** If we want strict isolation without a service-account-per-user explosion, we can put a tiny signed-URL gateway in front of GCS. Adds 1 pod. Defer unless the user count goes beyond a small team.

## Cost impact

- GCS interop API: same price as standard GCS (storage + ops).
- Onyxia config change: free.
- No extra pod by default.
- If we later add a signed-URL gateway: ~$0.10/day at low traffic.

Expected delta on the example's daily cost: **~$0**.

## Acceptance criteria for the implementation plan

1. From a fresh Onyxia login, "My files" shows `gs://<project>-onyxia-user-<keycloak-sub>` with the user able to upload, list, delete, share.
2. A Jupyter pod launched by the user has `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_ENDPOINT=https://storage.googleapis.com` injected.
3. `boto3.client('s3', endpoint_url='https://storage.googleapis.com')` lists/writes the user's bucket and only that bucket.
4. The GitHub Actions workflow `onyxia-gke-ephemeral.yml` deploys this storage layer in `mode=init` without manual steps.
5. A user with no bucket gets one created on first login (asynchronous OK, ≤ 30s).

## Next step

Once approved, invoke `superpowers:writing-plans` to break this down into a concrete TF + values + script implementation plan, then execute via `subagent-driven-development`.

---

## Amendments — subagent review (2026-05-16)

Verified against onyxia-api Region.java, GCS quotas docs, AWS SDK v2 issues, SSPCloud live config. Three corrections to the spec above.

**Correction 1 — Onyxia v10 has no per-user STATIC HMAC mode.**
The original spec implied `credentialsType: STATIC` would let Onyxia API hand a different HMAC pair per user. It does not: `region.data.S3` only defines an optional `sts` block. Without `sts.URL` Onyxia hands NO creds; the user pastes them in the UI. To inject creds automatically we need either (a) a Vault server + STS, or (b) a tiny **GCS STS bridge pod** that the existing `sts.URL` field points at, that mints HMAC pairs scoped to a per-user GCP service account and returns them in AWS STS XML shape.

**Correction 2 — GCS HMAC quotas.** 10 HMAC keys per service account, 100 service accounts per GCP project (raisable). The strict-isolation path (1 SA per user) caps at ~80 users.

**Correction 3 — AWS SDK v2 ≥ 2.30 default integrity checksums break GCS interop.** Every Jupyter / Spark / Trino we ship must export `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` (or set `request_checksum_calculation=when_required` in `~/.aws/config`). Without it, basic `boto3.put_object` returns `SignatureDoesNotMatch` / `NotImplemented`. This must be in the Onyxia service template env, not the user's notebook.

**Correction 4 — HMAC keys are not in Cloud Audit Logs by default.** Document the gap; v1 is fine for an internal demo, not for prod compliance.

### Updated arbitration

| | Option A — shared SA + IAM Conditions | Option B — GCS STS bridge pod |
|---|---|---|
| Pods | 0 | 1 (~30Mi RAM) |
| $/day | ~$0 | ~$0.05 |
| Isolation | data-plane only (a user can craft outside-prefix calls until IAM denies) | data-plane + auth-plane (token scoped per user) |
| Max users | unlimited | ~80 (GCP SA quota) |
| Audit traceability | weak | full (per-user SA appears in Cloud Audit Logs) |
| Time to ship | 2 h | 1 day (write the bridge) |

Recommendation: A for v1 (sent-tech demo). B becomes interesting when audit / multi-tenant strictness matter.

### Risks (updated)

- `request_checksum_calculation` is the #1 silent breakage. Add it to the Jupyter / VSCode service-templates as part of v1.
- The original "Vault" path stays viable but adds a real pod and is overkill at < 5 users.
