# Implementation plan — Apache Polaris Iceberg catalog on Onyxia GKE

**Status:** Plan, ready for review
**Branch:** `brainstorm/iceberg-lakehouse`
**Spec:** `docs/superpowers/specs/2026-05-16-iceberg-lakehouse-catalog-design.md` (+ subagent amendment dated 2026-05-16)
**Depends on:** branch `brainstorm/gcs-buckets` — the `gs://<project>-onyxia-warehouse` bucket MUST exist before Polaris starts (Polaris validates the warehouse root at create-time).

## Preamble — decision reversal: Lakekeeper → Apache Polaris

The spec recommended **Lakekeeper** as the v1 catalog (lighter footprint, ~$0.40/day) and parked **Apache Polaris** as the "production migration" target. After review with the user we are **flipping that decision** and going straight to Polaris. Rationale:

1. **Prod-fidelity with SSPCloud.** The reference Onyxia deployment runs `polaris.lab.sspcloud.fr` since Apache Polaris graduated to Apache TLP (2026-02). Shipping the same catalog in the ephemeral GKE example removes a "works on dev, breaks on prod" cliff (RBAC model, REST quirks, vended-cred shape all differ between Lakekeeper and Polaris).
2. **Vended credentials on GCS are first-class in Polaris.** Polaris's `gcp_storage_config` mints downscoped STS OAuth2 tokens scoped to a bucket prefix; Trino 481+ (`fs.native-gcs.enabled=true`), PyIceberg 0.6+, Spark 3.5+ all consume them natively. No HMAC wrapper.
3. **Single auth surface.** Polaris validates Keycloak JWTs directly (same realm as Onyxia + Onyxia-Trino) with an `audience` claim mapper — no OpenFGA sidecar, no second Postgres for an authz store.
4. **Cost delta is small.** ~$0.50/day total (Polaris pod ~$0.30 + dedicated Postgres ~$0.20) vs ~$0.40/day for the Lakekeeper+OpenFGA stack. The +$0.10/day buys prod parity.

The Lakekeeper option remains a valid v2 if footprint becomes the binding constraint on Autopilot; the engine-side wiring (env vars, Trino native-GCS) is catalog-agnostic.

## Goal

After `mode=init` with `enable_polaris=true`, an Onyxia user can run from a Jupyter pod:

```python
from pyiceberg.catalog import load_catalog
c = load_catalog(
    "rest",
    uri="https://polaris.onyxia.<host>/api/catalog",
    warehouse=f"user-{sub}",
    credential=keycloak_token,
)
c.create_namespace(("demo",))
c.create_table(("demo", "events"), schema=...)
```

…and the resulting metadata + parquet show up under `gs://<project>-onyxia-warehouse/user-<sub>/demo/events/`. Trino reads back what PyIceberg wrote, and vice versa.

---

## 1. Polaris Helm release

### What

Deploy `apache/polaris` (chart published on `https://apache.github.io/polaris-helm` since the 2026-02 graduation; if absent on plan-execution day, fall back to a `kustomize` manifest pinned to a published image tag such as `apache/polaris:1.5.0`) in namespace `polaris`, behind ingress-nginx with cert-manager.

### Where

- `helm-chart/examples/gke-ephemeral/terraform/app/main.tf` — new `helm_release.polaris` + `kubernetes_manifest.polaris_ingress`.
- `helm-chart/examples/gke-ephemeral/terraform/app/variables.tf` — `enable_polaris` (bool, default `true` once stable; `false` while landing).
- `helm-chart/examples/gke-ephemeral/polaris-values.yaml.tmpl` — Helm values, templated by Terraform.

### Acceptance criteria

- `kubectl -n polaris get pods` shows `polaris-0` Ready within 5 min of helm install.
- `curl -sf https://polaris.onyxia.<host>/api/catalog/v1/config` returns HTTP 200 with a JSON body containing `"defaults"`.
- The ingress certificate issued by cert-manager is `Ready=True`.
- Resource request on the pod is `500m CPU / 1Gi mem` (matches spec budget).

### Validation steps

```bash
terraform -chdir=helm-chart/examples/gke-ephemeral/terraform/app apply -auto-approve -var enable_polaris=true
kubectl -n polaris wait --for=condition=Ready pod/polaris-0 --timeout=300s
curl -sf https://polaris.onyxia.${PUBLIC_HOSTNAME}/api/catalog/v1/config | jq .defaults
```

---

## 2. Postgres backend for Polaris

### What

Polaris uses Postgres as its metastore (table metadata pointers, namespace tree, principals). Reuse the `cnpg` pattern already introduced for `keycloak-persist-realm`:

- A `Cluster` CR `polaris-pg` in namespace `polaris` (1 instance, 1Gi storage, postgres 16).
- Connection string injected into the Polaris pod via `secretKeyRef` (`postgresql.connectionString` produced by the `Cluster` CR).
- PVC retained on `mode=stop`, deleted on `mode=down_full`.

### Where

- `helm-chart/examples/gke-ephemeral/terraform/app/main.tf` — new `kubernetes_manifest.cnpg_cluster_polaris`.
- `polaris-values.yaml.tmpl` — `persistence.datasource.url = "jdbc:postgresql://polaris-pg-rw.polaris.svc:5432/polaris"` + `existingSecret: polaris-pg-app`.

### Acceptance criteria

- `kubectl -n polaris get cluster polaris-pg` reports `phase: Cluster in healthy state`.
- The Polaris pod boots without `connection refused` retries (log scan).
- After `mode=stop` then `mode=init`, the previously-created warehouse `user-${sub}` still exists (data survives).

### Validation steps

```bash
kubectl -n polaris exec polaris-pg-1 -- psql -U polaris -d polaris -c '\dt' | grep -i namespace
```

---

## 3. OIDC integration via Keycloak

### What

Polaris validates incoming JWTs against the Onyxia Keycloak realm. We need:

1. A new confidential client `polaris` in realm `onyxia` (created by `scripts/keycloak-init.sh`, using the existing `kc_safe_create` helper).
2. An **audience mapper** on the client so the Onyxia user's access token carries `aud: polaris` (Polaris rejects otherwise — same gotcha called out in the spec's risk list).
3. Polaris config:
   - `authenticator.type = external`
   - `authenticator.external.jwks-uri = https://auth.onyxia.<host>/realms/onyxia/protocol/openid-connect/certs`
   - `authenticator.external.issuer = https://auth.onyxia.<host>/realms/onyxia`
   - `authenticator.external.audience = polaris`
   - principal claim = `preferred_username` (so Polaris principals == Onyxia users).

### Where

- `helm-chart/examples/gke-ephemeral/scripts/keycloak-init.sh` — add `kc_safe_create` block for the `polaris` client + audience mapper. Idempotent (already the script's contract).
- `polaris-values.yaml.tmpl` — `authenticator.*` block.

### Acceptance criteria

- `curl -H "Authorization: Bearer <fresh-keycloak-token>" https://polaris.onyxia.<host>/api/management/v1/principals/self` returns the caller's identity, not 401.
- `jq -r .aud` on a decoded Onyxia user access token contains `polaris`.
- A token from the wrong realm returns 401 with `Invalid issuer`.

### Validation steps

```bash
TOKEN=$(./scripts/get-keycloak-token.sh user1)
curl -sf -H "Authorization: Bearer $TOKEN" https://polaris.onyxia.${PUBLIC_HOSTNAME}/api/management/v1/principals/self
```

---

## 4. GCS storage config + vended credentials

### What

Create a Polaris **catalog** named `onyxia` with `storage-config-info`:

```json
{
  "storageType": "GCS",
  "gcsServiceAccount": "polaris-warehouse@<project>.iam.gserviceaccount.com",
  "allowedLocations": ["gs://<project>-onyxia-warehouse/"]
}
```

The GSA `polaris-warehouse` has `roles/storage.objectAdmin` on `gs://<project>-onyxia-warehouse` and `roles/iam.serviceAccountTokenCreator` on itself (so Polaris can mint downscoped STS tokens). The Polaris KSA in the cluster is bound to that GSA via Workload Identity.

Vended credentials are turned on at the catalog level (`credential-vending-enabled: true`); per-request, Polaris returns a 1-hour STS OAuth2 token scoped to the table prefix.

### Where

- `helm-chart/examples/gke-ephemeral/terraform/iam/main.tf` — new GSA + IAM bindings (depends on the bucket from `brainstorm/gcs-buckets`).
- `helm-chart/examples/gke-ephemeral/terraform/app/main.tf` — `kubernetes_service_account.polaris` with `iam.gke.io/gcp-service-account` annotation.
- `helm-chart/examples/gke-ephemeral/scripts/polaris-init.sh` — bootstrap script (Job) that POSTs `POST /api/management/v1/catalogs` after Polaris first comes up.

### Acceptance criteria

- `gcloud iam service-accounts get-iam-policy polaris-warehouse@<project>...` lists the GKE KSA as a `workloadIdentityUser`.
- `curl … /api/catalog/v1/<catalog>/namespaces/<ns>/tables/<t>` with `X-Iceberg-Access-Delegation: vended-credentials` returns a token blob with `gcs.oauth2.token` populated.
- Writing 1 row from PyIceberg lands an object under `gs://<project>-onyxia-warehouse/...` (verified by `gsutil ls`).

### Validation steps

```bash
gcloud storage ls gs://${PROJECT_ID}-onyxia-warehouse/user-${SUB}/
```

---

## 5. Onyxia values — service-launcher env vars

### What

Inject Iceberg-catalog coordinates into every launched service via Helm `extraEnv` on the Onyxia API. The Onyxia API's typed `region.data.S3` schema has **no `iceberg.*` field** (confirmed by a prior subagent + the spec amendment); SSPCloud achieves this via `extraEnv` on the launcher.

Env vars to inject (resolved per-user at launch time):

| Var | Value |
|---|---|
| `ICEBERG_REST_URI` | `https://polaris.onyxia.<host>/api/catalog` |
| `ICEBERG_REST_WAREHOUSE` | `user-${sub}` |
| `ICEBERG_REST_OAUTH2_SERVER_URI` | `https://auth.onyxia.<host>/realms/onyxia/protocol/openid-connect/token` |
| `ICEBERG_REST_SCOPE` | `openid email profile` |
| `ICEBERG_REST_TOKEN` | `${KEYCLOAK_TOKEN}` (already injected by Onyxia init) |

### Where

- `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` — `api.extraEnv` block.
- README — Trino/PyIceberg/Spark usage snippets.

### Acceptance criteria

- `kubectl -n user-${sub} exec <jupyter-pod> -- env | grep ICEBERG_REST_` lists all 5 vars.
- A fresh Jupyter on a freshly-init'd cluster sees the right `<sub>` interpolated into `ICEBERG_REST_WAREHOUSE`.

### Validation steps — Trino

```sql
-- inside the Trino service that Onyxia launches
SHOW CATALOGS;  -- expect "iceberg"
SHOW SCHEMAS FROM iceberg;
```

### Validation steps — Spark

```python
spark = (SparkSession.builder
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.iceberg.type", "rest")
    .config("spark.sql.catalog.iceberg.uri", os.environ["ICEBERG_REST_URI"])
    .config("spark.sql.catalog.iceberg.warehouse", os.environ["ICEBERG_REST_WAREHOUSE"])
    .config("spark.sql.catalog.iceberg.token", os.environ["ICEBERG_REST_TOKEN"])
    .getOrCreate())
```

---

## 6. Per-user warehouse provisioning

### What

A Polaris "warehouse" is the (catalog, principal-role, bucket-prefix) triple. We provision `user-${sub}` on first login.

Two viable triggers — pick **(a)** unless the bridge from §4 is delayed:

**(a)** A small **STS bridge** Deployment in `polaris` namespace exposes `POST /provision`. Onyxia's `serviceLauncher.preStart` hook (or the user's first Jupyter init.sh) calls it with the Keycloak token; the bridge:
1. Decodes the JWT → `sub`.
2. Idempotently creates Polaris principal `user-${sub}`.
3. Idempotently creates warehouse `user-${sub}` with `default-base-location = gs://<project>-onyxia-warehouse/user-${sub}/`.
4. Grants the principal `CATALOG_MANAGE_CONTENT` on its warehouse.

**(b)** A one-shot `Job` per user, triggered by the same hook (heavier, but no long-running pod).

Default: **(a)** — the bridge is ~50 LoC of Python + FastAPI, runs in <100m CPU, and is the same shape SSPCloud uses.

### Where

- `helm-chart/examples/gke-ephemeral/charts/polaris-bridge/` — new tiny chart (Deployment + Service + ConfigMap).
- `helm-chart/examples/gke-ephemeral/onyxia-gke-public-values.yaml` — `serviceLauncher.extraInit` calling the bridge.

### Acceptance criteria

- Two users launching Jupyter back-to-back end up with two distinct Polaris warehouses, each pointing at their own bucket prefix.
- A second launch by the same user does NOT create a duplicate warehouse (idempotency).
- The bridge survives a Polaris restart (re-reads state on next call).

---

## 7. README — "Lakehouse Iceberg via Polaris"

### What

Add a section to `helm-chart/examples/gke-ephemeral/README.md`:

- What Polaris is + why (catalog, REST, multi-engine).
- The decision-reversal note (Lakekeeper considered, Polaris chosen for SSPCloud parity).
- A short comparison table (Polaris ~$0.50/day, prod-fidelity / Lakekeeper ~$0.40/day, lighter — link to spec).
- Copy-paste snippets for PyIceberg, Trino, Spark.
- How to disable (`enable_polaris=false`) for users who don't care.

### Acceptance criteria

- Section renders correctly on GitHub.
- `enable_polaris=false` path documented and known to work.

---

## 8. GitHub Actions workflow

### What

Extend `.github/workflows/gke-ephemeral.yml` (or equivalent) with a **phase 2.5 — Polaris** between the existing "phase 2 — apps" and "phase 3 — Onyxia":

1. `terraform apply` with `enable_polaris=true` (idempotent if already applied in phase 2).
2. Wait for `polaris-0` Ready.
3. Run `scripts/keycloak-init.sh` (or its Polaris-specific tail) to register the OIDC client.
4. Run `scripts/polaris-init.sh` to create the `onyxia` catalog + storage config.
5. Smoke-test: `curl /api/catalog/v1/config` → 200.

### Acceptance criteria

- The job is **idempotent** on resume (matches the existing `keycloak-persist-realm` pattern fixed in commit `16376205`).
- On a cold `mode=init`, the workflow reaches "Polaris ready" in <8 min.

---

## 9. End-to-end tests

### What

Two automated smoke tests in a new `tests/iceberg/` directory, run by the GHA workflow after Onyxia is up:

### Test A — PyIceberg round-trip

```python
import os, pyarrow as pa
from pyiceberg.catalog import load_catalog

c = load_catalog(
    "rest",
    uri=os.environ["ICEBERG_REST_URI"],
    warehouse=os.environ["ICEBERG_REST_WAREHOUSE"],
    credential=os.environ["KEYCLOAK_TOKEN"],
)
c.create_namespace(("demo",))
t = c.create_table(("demo", "events"),
                   schema=pa.schema([("id", pa.int64()), ("v", pa.string())]))
t.append(pa.table({"id": [1, 2], "v": ["a", "b"]}))
assert t.scan().to_arrow().num_rows == 2
```

### Test B — Trino reads PyIceberg writes

From the Trino service launched by Onyxia:

```sql
SELECT count(*) FROM iceberg.demo.events;  -- expect 2
```

### Acceptance criteria

- Both tests green on a fresh `mode=init`.
- `gsutil ls gs://<project>-onyxia-warehouse/user-<sub>/demo/events/metadata/` lists `>=2` JSON files (one per snapshot).
- `mode=down_full` removes everything (catalogs, principals, warehouses, bucket prefix).

---

## Cost & timeline

| Item | $/day (est.) |
|---|---|
| Polaris pod (500m / 1Gi) | ~$0.30 |
| Polaris-pg cnpg (200m / 256Mi + 1Gi PVC) | ~$0.20 |
| Ingress (reuses existing LB) | $0 |
| **Total delta** | **~$0.50/day** |

Dev effort: **~3 days** for one engineer:
- Day 1 — §1+§2 (Helm release + Postgres) and §3 (Keycloak client + audience mapper).
- Day 2 — §4+§6 (GCS storage + STS bridge + warehouse provisioning).
- Day 3 — §5+§7+§8+§9 (Onyxia env wiring, README, GHA, E2E tests).

---

## Review checkpoint

**Before merging**, the following must be green and demonstrated to the reviewer:

1. `terraform apply` clean, idempotent on second run.
2. `mode=stop` → `mode=init` preserves warehouses (Postgres PVC retained).
3. `mode=down_full` leaves zero residual GCS objects and zero Polaris namespace.
4. Tests A and B both pass on a cold cluster.
5. README section reviewed by a non-author for clarity (target reader: an Onyxia user new to Iceberg).
6. A side-by-side cost report (`mode=init` with vs. without `enable_polaris`) confirms the +$0.50/day budget.

If any of the six fails: stop, raise a `brainstorm/iceberg-followups` branch with the new spec amendment, do **not** ship.
